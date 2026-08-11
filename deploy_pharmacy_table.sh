#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed (disc already exists on
# invoice_line_items).

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/actions.js" << 'FILEEOF_app__main__pharmacy_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';
import { plainFrequency } from '@/lib/prescriptionFormatting';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function istDayBoundsUTC(dateStr) {
  const d = dateStr || todayIST();
  return {
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

// ── DASHBOARD ──
// Today's prescriptions grouped by visit, with a purchase-status read
// on each item -- some patients buy elsewhere or just don't come
// back, and front office/pharmacy need to see that at a glance rather
// than everything looking like an open, forgotten queue forever.
function purchaseStatus(rx) {
  if (rx.status === 'Dispensed') return 'Purchased';
  if (rx.billing_status === 'Denied') return 'Declined / Bought Elsewhere';
  if (rx.billing_status === 'Deferred') return 'Deferred';
  return 'Pending';
}

export async function getPharmacyDashboard() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .gte('created_at', startUTC).lte('created_at', endUTC)
    .order('created_at', { ascending: true });

  if (error) return { groups: [], stats: { totalPatients: 0, pendingItems: 0, purchasedItems: 0, declinedOrDeferred: 0 } };

  const groups = {};
  (data || []).forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    const visit = rx.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push({ ...rx, purchaseStatus: purchaseStatus(rx) });
  });

  const groupList = Object.values(groups).map((g) => ({
    ...g,
    allPurchased: g.items.every((i) => i.purchaseStatus === 'Purchased'),
    anyPending: g.items.some((i) => i.purchaseStatus === 'Pending'),
  }));

  const allItems = groupList.flatMap((g) => g.items);
  const stats = {
    totalPatients: groupList.length,
    pendingItems: allItems.filter((i) => i.purchaseStatus === 'Pending').length,
    purchasedItems: allItems.filter((i) => i.purchaseStatus === 'Purchased').length,
    declinedOrDeferred: allItems.filter((i) => i.purchaseStatus === 'Deferred' || i.purchaseStatus === 'Declined / Bought Elsewhere').length,
  };

  return { groups: groupList, stats };
}

// ── WORKSPACE ──
export async function getPharmacyWorkspace(visitId) {
  const supabase = await createClient();

  const [{ data: visit }, { data: prescriptions }, { data: drugCatalog }] = await Promise.all([
    supabase.from('visits').select('id, visit_number, patients(id, first_name, last_name, uhid, mobile)').eq('id', visitId).single(),
    supabase
      .from('prescriptions')
      .select('*, invoice_line_items(qty, rate, disc, gst_pct, net), encounters!inner(visit_id)')
      .eq('encounters.visit_id', visitId)
      .order('created_at', { ascending: true }),
    supabase.from('master_drugs').select('*').eq('status', 'Active').order('generic'),
  ]);

  // Suggest the closest catalog match per prescription so the
  // pharmacist isn't hunting through the whole drug list for every
  // line -- same ilike logic the auto-bill RPC already uses, just
  // surfaced here before billing instead of silently applied after.
  // Also carries the doctor's exact instructions in plain language
  // (same translation used on patient-facing prints) so the
  // pharmacist sees precisely what to explain at the counter, not
  // just the medical shorthand.
  const items = (prescriptions || []).map((rx) => {
    const match = (drugCatalog || []).find(
      (d) => rx.drug_name?.toLowerCase().includes(d.generic?.toLowerCase()) ||
             (d.brand && rx.drug_name?.toLowerCase().includes(d.brand.toLowerCase()))
    );
    return { ...rx, suggestedDrugId: match?.id || null, plainFrequency: plainFrequency(rx.frequency) };
  });

  return {
    visit,
    items,
    drugCatalog: drugCatalog || [],
  };
}

// Bills a chosen set of prescriptions in one go -- one invoice for
// this batch, purpose 'Pharmacy', matching the app's existing
// convention that every invoice creation is deliberate (see
// billing/actions.js createInvoiceForVisit) rather than trying to
// merge into whatever invoice might already exist on the visit.
export async function billPharmacyItems(visitId, items) {
  const supabase = await createClient();
  if (!items || items.length === 0) return { error: 'No items to bill.' };

  const { data: visit } = await supabase.from('visits').select('patient_id').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };

  const { data: invoice, error: invError } = await supabase.rpc('create_invoice_for_visit', {
    p_patient_id: visit.patient_id,
    p_visit_id: visitId,
    p_purpose: 'Pharmacy',
  });
  if (invError) return { error: invError.message };

  for (const item of items) {
    const gross = item.rate * item.qty;
    // Same math as billing/new/new-invoice-tab.js's computeLine(): GST
    // is computed on the post-discount (taxable) amount, not the raw
    // gross -- keeping this identical to the rest of the app so a
    // pharmacy-billed line behaves exactly like one entered from the
    // main Billing screen.
    const discPct = Math.min(100, Math.max(0, item.discPct || 0));
    const disc = Math.round((gross * discPct / 100) * 100) / 100;
    const taxable = gross - disc;
    const gstAmount = Math.round((taxable * item.gstPct / 100) * 100) / 100;
    const net = Math.round((taxable + gstAmount) * 100) / 100;

    const { data: line, error: lineError } = await supabase
      .from('invoice_line_items')
      .insert({
        invoice_id: invoice.id,
        service_code: item.serviceCode || null,
        service_name: item.drugName,
        dept: 'Pharmacy',
        qty: item.qty,
        rate: item.rate,
        gst_pct: item.gstPct,
        disc,
        gross,
        gst_amount: gstAmount,
        net,
      })
      .select()
      .single();
    if (lineError) return { error: lineError.message };

    await supabase
      .from('prescriptions')
      .update({
        billing_status: 'Billed',
        qty: item.qty,
        invoice_id: invoice.id,
        invoice_line_item_id: line.id,
        billing_updated_at: new Date().toISOString(),
      })
      .eq('id', item.prescriptionId);
  }

  await supabase.rpc('recompute_invoice_totals', { p_invoice_id: invoice.id });

  return { success: true, invoiceId: invoice.id };
}

// ── HISTORY ──
export async function getPharmacyHistory(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { startUTC, endUTC } = istDayBoundsUTC(targetDate);

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, invoice_line_items(net), encounters(visit_id, visits(visit_number, patients(first_name, last_name, uhid)))')
    .eq('status', 'Dispensed')
    .gte('dispensed_at', startUTC).lte('dispensed_at', endUTC)
    .order('dispensed_at', { ascending: false });

  if (error) return [];

  const groups = {};
  (data || []).forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    const visit = rx.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [], invoiceId: rx.invoice_id, total: 0 };
    }
    const net = Number(rx.invoice_line_items?.net || 0);
    groups[visitId].items.push({ ...rx, net });
    groups[visitId].total += net;
  });

  return Object.values(groups);
}

export async function getPendingPrescriptions() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .eq('status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  // Group flat prescription rows by visit, since a pharmacist hands over
  // everything for one patient's visit together, not drug by drug.
  const groups = {};
  data.forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: rx.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

export async function dispensePrescription(id) {
  const supabase = await createClient();
  const { data: rx } = await supabase.from('prescriptions').select('drug_name, encounters(visit_id)').eq('id', id).maybeSingle();
  const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, rx?.encounters?.visit_id, 'pharmacy_dispensed', { drug_name: rx?.drug_name });
  return { success: true };
}

export async function dispenseAllForVisit(prescriptionIds) {
  const supabase = await createClient();
  const { data: rxList } = await supabase.from('prescriptions').select('id, drug_name, encounters(visit_id)').in('id', prescriptionIds);
  for (const id of prescriptionIds) {
    const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
    if (error) return { error: error.message };
  }
  const visitId = rxList?.[0]?.encounters?.visit_id;
  await logJourneyEvent(supabase, visitId, 'pharmacy_dispensed', { count: prescriptionIds.length });
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every prescription lands here the moment it's written in
// Consultation, regardless of dispensing status -- Front Office can
// bill it at the counter before the patient even reaches Pharmacy.
export async function getPendingPrescriptionsForFrontOffice() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    const visit = rx.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

async function setPrescriptionBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('prescriptions')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markPrescriptionDenied(id, note) {
  return setPrescriptionBillingStatus(id, 'Denied', note);
}

export async function markPrescriptionDeferred(id, note) {
  return setPrescriptionBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetPrescriptionBilling(id) {
  return setPrescriptionBillingStatus(id, 'Pending', null);
}


FILEEOF_app__main__pharmacy_actions_js

mkdir -p "app/(main)/pharmacy/[visitId]"
cat > "app/(main)/pharmacy/[visitId]/workspace.js" << 'FILEEOF_app__main__pharmacy__visitId__workspace_js'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { useRouter } from 'next/navigation';
import {
  getPharmacyWorkspace,
  billPharmacyItems,
  dispensePrescription,
  markPrescriptionDenied,
  markPrescriptionDeferred,
  resetPrescriptionBilling,
} from '../actions';

function fmt(n) {
  return `Rs ${Number(n || 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
}

const BILLING_BADGE = { Pending: 'b-amber', Billed: 'b-green', Denied: 'b-red', Deferred: 'b-gray' };

export default function Workspace({ visitId }) {
  const router = useRouter();
  const [visit, setVisit] = useState(null);
  const [items, setItems] = useState([]);
  const [drugCatalog, setDrugCatalog] = useState([]);
  const [selections, setSelections] = useState({}); // { [prescriptionId]: { drugId, qty, discPct } }
  const [checked, setChecked] = useState({});
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [billing, setBilling] = useState(false);
  const [noteDraft, setNoteDraft] = useState({});
  const [expandedNoteId, setExpandedNoteId] = useState(null);

  const refresh = useCallback(async () => {
    const data = await getPharmacyWorkspace(visitId);
    setVisit(data.visit);
    setItems(data.items);
    setDrugCatalog(data.drugCatalog);
    setSelections((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status !== 'Pending') return;
        if (!next[rx.id]) next[rx.id] = { drugId: rx.suggestedDrugId || '', qty: rx.qty || 1, discPct: 0 };
      });
      return next;
    });
    setChecked((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status === 'Pending' && next[rx.id] === undefined) next[rx.id] = true;
      });
      return next;
    });
    setLoading(false);
  }, [visitId]);

  useEffect(() => { refresh(); }, [refresh]);

  // The payment tab closes itself after a successful receipt (see
  // collect-payment-tab.js) -- refreshing on focus means the moment
  // that happens and this tab regains attention, the just-billed item
  // already shows its updated status without a manual reload.
  useEffect(() => {
    window.addEventListener('focus', refresh);
    return () => window.removeEventListener('focus', refresh);
  }, [refresh]);

  function updateSelection(rxId, field, value) {
    setSelections((prev) => ({ ...prev, [rxId]: { ...prev[rxId], [field]: value } }));
  }

  // Same math as billing/new/new-invoice-tab.js's computeLine() --
  // GST computed on the post-discount amount, matching the rest of
  // the app exactly.
  function lineTotal(rx) {
    if (rx.billing_status === 'Billed') {
      const li = rx.invoice_line_items;
      if (!li) return null;
      const gross = li.rate * li.qty;
      return { qty: li.qty, rate: li.rate, discPct: gross > 0 ? Math.round((li.disc / gross) * 10000) / 100 : 0, net: Number(li.net) };
    }
    const sel = selections[rx.id];
    const drug = drugCatalog.find((d) => d.id === sel?.drugId);
    if (!drug || !sel?.qty) return null;
    const gross = drug.rate * sel.qty;
    const discPct = Math.min(100, Math.max(0, sel.discPct || 0));
    const disc = Math.round((gross * discPct / 100) * 100) / 100;
    const taxable = gross - disc;
    const gst = Math.round((taxable * drug.gst_pct / 100) * 100) / 100;
    return { qty: sel.qty, rate: drug.rate, discPct, net: Math.round((taxable + gst) * 100) / 100, drug };
  }

  const grandTotal = items.reduce((sum, rx) => {
    if (rx.billing_status === 'Denied' || rx.billing_status === 'Deferred') return sum;
    if (rx.billing_status === 'Pending' && !checked[rx.id]) return sum;
    return sum + (lineTotal(rx)?.net || 0);
  }, 0);

  async function handleBillAndPay() {
    setError('');
    const selected = items.filter((rx) => rx.billing_status === 'Pending' && checked[rx.id]);
    if (selected.length === 0) { setError('Select at least one item to bill.'); return; }

    const payload = [];
    for (const rx of selected) {
      const t = lineTotal(rx);
      if (!t) { setError(`Pick a catalog match and quantity for ${rx.drug_name} before billing.`); return; }
      payload.push({
        prescriptionId: rx.id,
        drugName: rx.drug_name,
        serviceCode: t.drug.code,
        rate: t.drug.rate,
        gstPct: t.drug.gst_pct,
        qty: selections[rx.id].qty,
        discPct: selections[rx.id].discPct || 0,
      });
    }

    setBilling(true);
    const result = await billPharmacyItems(visitId, payload);
    setBilling(false);
    if (result.error) { setError(result.error); return; }

    // Opens as a real new tab rather than navigating away from the
    // Workspace, since the pharmacist typically wants to keep working
    // through the queue -- the payment tab closes itself once the
    // receipt is confirmed there (see collect-payment-tab.js), which
    // naturally drops focus back here.
    const patientId = visit?.patients?.id;
    const url = `/payments/collect?patientId=${patientId}&invoiceId=${result.invoiceId}&popup=1`;
    window.open(url, '_blank');
    refresh();
  }

  async function handleDispense(rxId) {
    setError('');
    const result = await dispensePrescription(rxId);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAction(fn, rxId) {
    setError('');
    const result = await fn(rxId, noteDraft[rxId] || '');
    if (result.error) { setError(result.error); return; }
    setExpandedNoteId(null);
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading...</div>;
  if (!visit) return <div className="msg-err">Visit not found.</div>;

  const anyBillable = items.some((rx) => rx.billing_status === 'Pending');

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/pharmacy')}>
        <i className="ti ti-arrow-left"></i> Back to Dashboard
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
          <div>
            <div style={{ fontSize: 16, fontWeight: 700 }}>{visit.patients?.first_name} {visit.patients?.last_name}</div>
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{visit.patients?.uhid} &middot; Visit {visit.visit_number} &middot; {visit.patients?.mobile}</div>
          </div>
          {items.length > 0 && (
            <button className="btn btn-sm" onClick={() => window.open(`/prescription-print/${visitId}`, '_blank')}>
              <i className="ti ti-printer"></i> Print Prescription
            </button>
          )}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {items.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <table className="tbl">
            <thead>
              <tr>
                <th style={{ width: 26 }}></th>
                <th style={{ width: 34 }}>S.No</th>
                <th>Medicine</th>
                <th style={{ width: 60 }}>Qty</th>
                <th style={{ width: 90 }}>Rate</th>
                <th style={{ width: 90 }}>Discount</th>
                <th style={{ width: 100 }}>Billing Status</th>
                <th style={{ width: 110 }}>Dispensing Status</th>
                <th style={{ textAlign: 'right', width: 90 }}>Total</th>
                <th></th>
              </tr>
            </thead>
            <tbody>
              {items.map((rx, i) => {
                const t = lineTotal(rx);
                const isPending = rx.billing_status === 'Pending';
                const isActioned = rx.billing_status === 'Denied' || rx.billing_status === 'Deferred';
                return (
                  <Fragment key={rx.id}>
                    <tr>
                      <td>
                        {isPending && (
                          <input
                            type="checkbox"
                            checked={!!checked[rx.id]}
                            onChange={(e) => setChecked((prev) => ({ ...prev, [rx.id]: e.target.checked }))}
                          />
                        )}
                      </td>
                      <td>{i + 1}</td>
                      <td>
                        <div style={{ fontWeight: 600, fontSize: 13 }}>{rx.drug_name}</div>
                        <div style={{ fontSize: 11, color: 'var(--g400)' }}>{rx.eye} &middot; {rx.dosage} &middot; {rx.plainFrequency} &middot; for {rx.duration}</div>
                        {isPending && (
                          <select
                            className="fi fi-sm"
                            style={{ marginTop: 4, maxWidth: 260 }}
                            value={selections[rx.id]?.drugId || ''}
                            onChange={(e) => updateSelection(rx.id, 'drugId', e.target.value)}
                          >
                            <option value="">-- Match catalog item --</option>
                            {drugCatalog.map((d) => (
                              <option key={d.id} value={d.id}>{d.brand ? `${d.brand} (${d.generic})` : d.generic} -- {fmt(d.rate)}</option>
                            ))}
                          </select>
                        )}
                      </td>
                      <td>
                        {isPending ? (
                          <input
                            type="number" min="1" className="fi fi-sm" style={{ width: 55 }}
                            value={selections[rx.id]?.qty || 1}
                            onChange={(e) => updateSelection(rx.id, 'qty', parseInt(e.target.value, 10) || 1)}
                          />
                        ) : (t?.qty ?? '--')}
                      </td>
                      <td>{t?.rate != null ? fmt(t.rate) : '--'}</td>
                      <td>
                        {isPending ? (
                          <input
                            type="number" min="0" max="100" className="fi fi-sm" style={{ width: 55 }}
                            placeholder="%"
                            value={selections[rx.id]?.discPct || ''}
                            onChange={(e) => updateSelection(rx.id, 'discPct', parseFloat(e.target.value) || 0)}
                          />
                        ) : (t?.discPct > 0 ? `${t.discPct}%` : '--')}
                      </td>
                      <td><span className={`badge ${BILLING_BADGE[rx.billing_status] || 'b-gray'}`} style={{ fontSize: 10 }}>{rx.billing_status}</span></td>
                      <td>
                        {rx.status === 'Dispensed'
                          ? <span className="badge b-blue" style={{ fontSize: 10 }}>Dispensed</span>
                          : <span className="badge b-gray" style={{ fontSize: 10 }}>Not Dispensed</span>}
                      </td>
                      <td style={{ textAlign: 'right', fontWeight: 700 }}>{t ? fmt(t.net) : '--'}</td>
                      <td style={{ whiteSpace: 'nowrap' }}>
                        {isPending && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => setExpandedNoteId(expandedNoteId === rx.id ? null : rx.id)}>
                            Decline / Defer
                          </button>
                        )}
                        {rx.billing_status === 'Billed' && rx.status !== 'Dispensed' && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => handleDispense(rx.id)}>Dispense</button>
                        )}
                        {isActioned && (
                          <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} onClick={() => handleAction(resetPrescriptionBilling, rx.id)}>Undo</button>
                        )}
                      </td>
                    </tr>
                    {expandedNoteId === rx.id && (
                      <tr>
                        <td colSpan={10} style={{ background: 'var(--g50)', padding: 8 }}>
                          <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                            <input
                              type="text" className="fi fi-sm" placeholder="Note (optional)" style={{ maxWidth: 240 }}
                              value={noteDraft[rx.id] || ''}
                              onChange={(e) => setNoteDraft((prev) => ({ ...prev, [rx.id]: e.target.value }))}
                            />
                            <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDenied, rx.id)}>
                              Declined / Bought Elsewhere
                            </button>
                            <button className="btn" style={{ fontSize: 11, padding: '3px 9px' }} onClick={() => handleAction(markPrescriptionDeferred, rx.id)}>
                              Deferred
                            </button>
                          </div>
                        </td>
                      </tr>
                    )}
                  </Fragment>
                );
              })}
            </tbody>
            <tfoot>
              <tr>
                <td colSpan={8} style={{ textAlign: 'right', fontWeight: 800, fontSize: 14 }}>Total</td>
                <td style={{ textAlign: 'right', fontWeight: 800, fontSize: 14 }}>{fmt(grandTotal)}</td>
                <td></td>
              </tr>
            </tfoot>
          </table>

          {anyBillable && (
            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 14 }}>
              <button className="btn btn-primary" disabled={billing} onClick={handleBillAndPay}>
                {billing ? 'Billing...' : <><i className="ti ti-receipt"></i> Bill Selected & Send to Payment</>}
              </button>
            </div>
          )}
        </div>
      )}

      {items.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No prescriptions found for this visit.
        </div>
      )}
    </div>
  );
}
FILEEOF_app__main__pharmacy__visitId__workspace_js


echo "Files written."

git add -A
git commit -m "Pharmacy Workspace: single unified table (S.No/Medicine/Qty/Rate/Discount/Billing Status/Dispensing Status/Total), add per-line discount option while billing"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
