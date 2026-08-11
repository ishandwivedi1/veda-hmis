#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/page.js" << 'FILEEOF_app__main__pharmacy_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPharmacyDashboard } from './actions';
import PharmacyTabs from './pharmacy-tabs';

const STATUS_BADGE = {
  Purchased: 'b-green',
  Pending: 'b-amber',
  Deferred: 'b-gray',
  'Declined / Bought Elsewhere': 'b-red',
};

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

function VisitStatusBadge({ g }) {
  if (g.allPurchased) return <span className="badge b-green">All Purchased</span>;
  if (g.anyPending) return <span className="badge b-amber">Action Needed</span>;
  return <span className="badge b-gray">Closed Out</span>;
}

export default function PharmacyDashboard() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ totalPatients: 0, pendingItems: 0, purchasedItems: 0, declinedOrDeferred: 0 });
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const data = await getPharmacyDashboard();
    setGroups(data.groups);
    setStats(data.stats);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 20000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Patients today" value={stats.totalPatients} sub="With a prescription written" color="var(--blue)" />
        <KpiCard label="Pending action" value={stats.pendingItems} sub="Not yet billed or dispensed" color="var(--amber)" />
        <KpiCard label="Purchased" value={stats.purchasedItems} sub="Dispensed today" color="var(--green)" />
        <KpiCard label="Declined / deferred" value={stats.declinedOrDeferred} sub="Not collecting from here" color="var(--red)" />
      </div>

      <PharmacyTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Today&apos;s Prescriptions
          <span className="badge b-gray" style={{ marginLeft: 8 }}>{groups.length}</span>
        </div>

        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

        {!loading && groups.length > 0 && (
          <table className="tbl">
            <thead>
              <tr><th>Patient</th><th>Visit</th><th>Medicines</th><th>Status</th><th></th></tr>
            </thead>
            <tbody>
              {groups.map((g) => (
                <tr key={g.visitId}>
                  <td>
                    <strong>{g.patient?.first_name} {g.patient?.last_name}</strong>
                    <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid}</div>
                  </td>
                  <td style={{ fontSize: 12, color: 'var(--g500)' }}>{g.visitNumber}</td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', maxWidth: 320 }}>
                      {g.items.map((rx) => (
                        <span key={rx.id} className={`badge ${STATUS_BADGE[rx.purchaseStatus] || 'b-gray'}`} style={{ fontSize: 10 }}>
                          {rx.drug_name}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td><VisitStatusBadge g={g} /></td>
                  <td style={{ textAlign: 'right' }}>
                    <button className="btn btn-sm" onClick={() => router.push(`/pharmacy/${g.visitId}`)}>
                      Open <i className="ti ti-arrow-right"></i>
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {!loading && groups.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            No prescriptions written today yet.
          </div>
        )}
      </div>

      <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 12, padding: 14 }}>
        <i className="ti ti-boxes"></i> Stock tracking is planned for a future update -- current inventory levels aren't shown here yet.
      </div>
    </div>
  );
}
FILEEOF_app__main__pharmacy_page_js

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/actions.js" << 'FILEEOF_app__main__pharmacy_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

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
      .select('*, encounters!inner(visit_id)')
      .eq('encounters.visit_id', visitId)
      .order('created_at', { ascending: true }),
    supabase.from('master_drugs').select('*').eq('status', 'Active').order('generic'),
  ]);

  // Suggest the closest catalog match per prescription so the
  // pharmacist isn't hunting through the whole drug list for every
  // line -- same ilike logic the auto-bill RPC already uses, just
  // surfaced here before billing instead of silently applied after.
  const items = (prescriptions || []).map((rx) => {
    const match = (drugCatalog || []).find(
      (d) => rx.drug_name?.toLowerCase().includes(d.generic?.toLowerCase()) ||
             (d.brand && rx.drug_name?.toLowerCase().includes(d.brand.toLowerCase()))
    );
    return { ...rx, suggestedDrugId: match?.id || null };
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
    const gstAmount = Math.round((gross * item.gstPct / 100) * 100) / 100;
    const net = Math.round((gross + gstAmount) * 100) / 100;

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
        disc: 0,
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
    .select('*, encounters(visit_id, visits(visit_number, patients(first_name, last_name, uhid)))')
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
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [], invoiceId: rx.invoice_id };
    }
    groups[visitId].items.push(rx);
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

import { useState, useEffect, useCallback } from 'react';
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

export default function Workspace({ visitId }) {
  const router = useRouter();
  const [visit, setVisit] = useState(null);
  const [items, setItems] = useState([]);
  const [drugCatalog, setDrugCatalog] = useState([]);
  const [selections, setSelections] = useState({}); // { [prescriptionId]: { drugId, qty } }
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [billing, setBilling] = useState(false);
  const [noteDraft, setNoteDraft] = useState({});

  const refresh = useCallback(async () => {
    const data = await getPharmacyWorkspace(visitId);
    setVisit(data.visit);
    setItems(data.items);
    setDrugCatalog(data.drugCatalog);
    // Default each unbilled item to its suggested catalog match and qty 1
    setSelections((prev) => {
      const next = { ...prev };
      data.items.forEach((rx) => {
        if (rx.billing_status !== 'Pending') return;
        if (!next[rx.id]) next[rx.id] = { drugId: rx.suggestedDrugId || '', qty: rx.qty || 1 };
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

  const billableItems = items.filter((rx) => rx.billing_status === 'Pending');
  const [checked, setChecked] = useState({});
  useEffect(() => {
    // Check everything billable by default so a normal "bill all, send to payment" is one click
    const initial = {};
    billableItems.forEach((rx) => { initial[rx.id] = true; });
    setChecked((prev) => ({ ...initial, ...prev }));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items.length]);

  function lineTotal(rx) {
    const sel = selections[rx.id];
    const drug = drugCatalog.find((d) => d.id === sel?.drugId);
    if (!drug || !sel?.qty) return null;
    const gross = drug.rate * sel.qty;
    const gst = Math.round((gross * drug.gst_pct / 100) * 100) / 100;
    return { gross, gst, net: Math.round((gross + gst) * 100) / 100, drug };
  }

  const grandTotal = billableItems
    .filter((rx) => checked[rx.id])
    .reduce((sum, rx) => sum + (lineTotal(rx)?.net || 0), 0);

  async function handleBillAndPay() {
    setError('');
    const selected = billableItems.filter((rx) => checked[rx.id]);
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
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading...</div>;
  if (!visit) return <div className="msg-err">Visit not found.</div>;

  const billed = items.filter((rx) => rx.billing_status !== 'Pending');

  return (
    <div style={{ maxWidth: 800, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/pharmacy')}>
        <i className="ti ti-arrow-left"></i> Back to Dashboard
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{visit.patients?.first_name} {visit.patients?.last_name}</div>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>{visit.patients?.uhid} &middot; Visit {visit.visit_number} &middot; {visit.patients?.mobile}</div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {billableItems.length > 0 && (
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>Prescribed -- Not Yet Billed</div>
          {billableItems.map((rx) => {
            const t = lineTotal(rx);
            return (
              <div key={rx.id} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
                <div style={{ display: 'flex', alignItems: 'flex-start', gap: 10 }}>
                  <input
                    type="checkbox"
                    checked={!!checked[rx.id]}
                    onChange={(e) => setChecked((prev) => ({ ...prev, [rx.id]: e.target.checked }))}
                    style={{ marginTop: 4 }}
                  />
                  <div style={{ flex: 1 }}>
                    <div style={{ fontWeight: 600, fontSize: 13 }}>{rx.drug_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g400)' }}>{rx.dosage} {rx.frequency} x {rx.duration} -- {rx.eye}</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '2fr 90px 1fr', gap: 8, marginTop: 8 }}>
                      <select
                        className="fi fi-sm"
                        value={selections[rx.id]?.drugId || ''}
                        onChange={(e) => updateSelection(rx.id, 'drugId', e.target.value)}
                      >
                        <option value="">-- Match catalog item --</option>
                        {drugCatalog.map((d) => (
                          <option key={d.id} value={d.id}>{d.brand ? `${d.brand} (${d.generic})` : d.generic} -- {fmt(d.rate)}</option>
                        ))}
                      </select>
                      <input
                        type="number"
                        className="fi fi-sm"
                        min="1"
                        value={selections[rx.id]?.qty || 1}
                        onChange={(e) => updateSelection(rx.id, 'qty', parseInt(e.target.value, 10) || 1)}
                      />
                      <div style={{ fontSize: 13, fontWeight: 700, alignSelf: 'center', textAlign: 'right' }}>
                        {t ? fmt(t.net) : '--'}
                      </div>
                    </div>
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 26 }}>
                  <input
                    type="text"
                    className="fi fi-sm"
                    placeholder="Note (why declined/deferred)"
                    style={{ maxWidth: 220, fontSize: 11 }}
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
              </div>
            );
          })}

          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginTop: 14 }}>
            <div style={{ fontSize: 15, fontWeight: 800 }}>Total: {fmt(grandTotal)}</div>
            <button className="btn btn-primary" disabled={billing} onClick={handleBillAndPay}>
              {billing ? 'Billing...' : <><i className="ti ti-receipt"></i> Bill & Send to Payment</>}
            </button>
          </div>
        </div>
      )}

      {billed.length > 0 && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>Billed / Actioned</div>
          {billed.map((rx) => (
            <div key={rx.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
              <span>
                <strong>{rx.drug_name}</strong> &middot; Qty {rx.qty}
                {rx.billing_status === 'Billed' && <span className="badge b-green" style={{ marginLeft: 6, fontSize: 10 }}>Billed</span>}
                {rx.billing_status === 'Denied' && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>Declined</span>}
                {rx.billing_status === 'Deferred' && <span className="badge b-gray" style={{ marginLeft: 6, fontSize: 10 }}>Deferred</span>}
                {rx.status === 'Dispensed' && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>Dispensed</span>}
              </span>
              <span style={{ display: 'flex', gap: 6 }}>
                {rx.status !== 'Dispensed' && (
                  <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleDispense(rx.id)}>Dispense</button>
                )}
                {(rx.billing_status === 'Denied' || rx.billing_status === 'Deferred') && (
                  <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleAction(resetPrescriptionBilling, rx.id)}>Undo</button>
                )}
              </span>
            </div>
          ))}
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

mkdir -p "app/(main)/payments/collect"
cat > "app/(main)/payments/collect/collect-payment-tab.js" << 'FILEEOF_app__main__payments_collect_collect_payment_tab_js'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment, getAdvanceBalance, getPatientById, getAllUnpaidInvoices, applyAdjustment } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const STATUS_BADGE = { Partial: 'b-amber', Pending: 'b-red' };

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [highlightInvoiceId, setHighlightInvoiceId] = useState(null);
  const [unpaidInvoices, setUnpaidInvoices] = useState([]);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [applyingAdvance, setApplyingAdvance] = useState(false);
  const [receipt, setReceipt] = useState(null);
  const [overpaidAmount, setOverpaidAmount] = useState(0);
  const searchParams = useSearchParams();
  const router = useRouter();
  const urlPatientId = searchParams.get('patientId');
  const urlInvoiceId = searchParams.get('invoiceId');
  const isPopup = searchParams.get('popup') === '1';
  const returnTo = searchParams.get('returnTo');
  const autofillDoneFor = useRef(null);

  useEffect(() => {
    getAllUnpaidInvoices().then(setUnpaidInvoices);
  }, []);

  // Arrived from "Finalize invoice" -- auto-load the patient and their
  // outstanding invoices (including the one just billed) instead of
  // requiring a manual search.
  useEffect(() => {
    if (!urlPatientId) return;
    if (autofillDoneFor.current === urlPatientId) return;
    autofillDoneFor.current = urlPatientId;
    (async () => {
      const result = await getPatientById(urlPatientId);
      if (result.error) { setError(result.error); return; }
      if (urlInvoiceId) setHighlightInvoiceId(urlInvoiceId);
      await pickPatient(result.patient);
    })();
  }, [urlPatientId, urlInvoiceId]);

  // In the common case (single payment mode), the mode's amount should
  // always match the amount collecting -- no need to type the same
  // number twice. Only once a second mode is added (a real split) does
  // each row need its own independently-entered amount.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);

  const totalSelectedOutstanding = invoices
    .filter((inv) => selectedInvoiceIds.includes(inv.id))
    .reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const invs = await getOutstandingInvoices(p.id);
    setInvoices(invs);
    setSelectedInvoiceIds(invs.map((i) => i.id)); // pre-select all, matching "select invoice(s) to pay"
    setAdvanceBalance(await getAdvanceBalance(p.id));
  }

  function toggleInvoice(id) {
    setSelectedInvoiceIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }

  function useFullOutstanding() {
    setAmount(totalSelectedOutstanding.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: totalSelectedOutstanding.toFixed(2) }]);
  }

  // The day-of-surgery flow: patient already paid an advance at booking;
  // today the full remaining balance is collected upfront. This applies
  // the advance against the selected invoice(s) first (a real ledger
  // adjustment, not just arithmetic on screen -- the advance balance
  // actually goes down), then auto-fills the correct remaining amount
  // to collect, so nobody has to subtract by hand or remember to visit
  // the separate Adjustments tab.
  async function handleApplyAdvanceAndCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice.'); return; }
    if (advanceBalance <= 0) { setError('No advance balance available for this patient.'); return; }

    setApplyingAdvance(true);
    let remaining = advanceBalance;
    for (const invId of selectedInvoiceIds) {
      if (remaining <= 0) break;
      const inv = invoices.find((i) => i.id === invId);
      if (!inv) continue;
      const outstanding = Number(inv.net) - Number(inv.paid);
      if (outstanding <= 0.01) continue;
      const toApply = Math.min(remaining, outstanding);
      const result = await applyAdjustment(selectedPatient.id, invId, toApply);
      if (result.error) { setApplyingAdvance(false); setError(result.error); return; }
      remaining -= toApply;
    }

    const [refreshedInvoices, refreshedAdvance] = await Promise.all([
      getOutstandingInvoices(selectedPatient.id),
      getAdvanceBalance(selectedPatient.id),
    ]);
    setInvoices(refreshedInvoices);
    setAdvanceBalance(refreshedAdvance);
    const stillOutstandingIds = refreshedInvoices.filter((i) => selectedInvoiceIds.includes(i.id)).map((i) => i.id);
    setSelectedInvoiceIds(stillOutstandingIds);
    const newTotal = refreshedInvoices
      .filter((i) => stillOutstandingIds.includes(i.id))
      .reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
    setAmount(newTotal.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: newTotal.toFixed(2) }]);
    setApplyingAdvance(false);
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }

  function addModeRow() {
    setModeRows((rows) => {
      // Moving from single-mode (auto-filled) to a real split -- clear
      // amounts so staff explicitly enters how much goes to each mode,
      // rather than leaving a stale auto-filled value on the first row.
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }

  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      // Back to a single mode -- re-sync it to the amount collecting.
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setInvoices([]);
    setSelectedInvoiceIds([]);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setReceipt(null);
    setOverpaidAmount(0);
    setError('');
  }

  async function handleCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice to pay.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount collecting.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount collecting (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectPayment(selectedPatient.id, selectedInvoiceIds, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    // Anything collected beyond the selected invoices' outstanding
    // total was automatically credited to advance -- surface that so
    // it's not a silent surprise.
    const overpaid = amt - totalSelectedOutstanding;
    setOverpaidAmount(overpaid > 0.01 ? overpaid : 0);
    setReceipt(result.payment);
  }

  // Collecting from a specific invoice means this was reached via a
  // link from elsewhere (Billing Dashboard, or another module's own
  // billing flow like Pharmacy) -- once paid, the natural next step is
  // back there rather than sitting on this form. A short delay keeps
  // the receipt confirmation visible instead of yanking it away.
  //
  // Opened as a popup (from Pharmacy's own bill-and-pay flow): just
  // close the tab so the person lands back on the page they were
  // already on, instead of navigating that popup somewhere new.
  useEffect(() => {
    if (!receipt || !urlInvoiceId) return;
    const timer = setTimeout(() => {
      if (isPopup) { window.close(); return; }
      router.push(returnTo || '/billing');
    }, 2500);
    return () => clearTimeout(timer);
  }, [receipt, urlInvoiceId, router, isPopup, returnTo]);

  if (receipt) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Payment collected -- Receipt <strong>{receipt.receipt_number}</strong> -- Rs.{receipt.total_amount}
        </div>
        {overpaidAmount > 0 && (
          <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-piggy-bank"></i> Rs.{overpaidAmount.toFixed(2)} was more than the selected invoices' balance -- credited to this patient's advance for future use.
          </div>
        )}
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {selectedPatient.first_name} {selectedPatient.last_name} -- {selectedPatient.uhid}</div>
          <div><strong>Amount:</strong> Rs.{receipt.total_amount}</div>
          {receipt.reference && <div><strong>Reference:</strong> {receipt.reference}</div>}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          {urlInvoiceId ? (
            <>
              <button className="btn btn-primary" onClick={() => router.push('/billing')}>
                <i className="ti ti-arrow-left"></i> Back to Billing Dashboard
              </button>
              <span style={{ fontSize: 11, color: 'var(--g400)', alignSelf: 'center' }}>Returning automatically...</span>
            </>
          ) : (
            <button className="btn btn-primary" onClick={reset}>Collect another payment</button>
          )}
        </div>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-cash" style={{ color: 'var(--green)' }}></i> Collect Payment
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
          <div>
            <label className="flbl">Patient (name, UHID, or mobile) *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            <div style={{ background: 'var(--green-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 11, marginTop: 5 }}>
                <span style={{ color: 'var(--purple)', fontWeight: 600 }}>Advance balance: </span>
                <span style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{advanceBalance}</span>
                {advanceBalance > 0 && <span style={{ color: 'var(--g500)', marginLeft: 4 }}>-- use the purple button below to apply it</span>}
              </div>
            </div>

            <label className="flbl">Select invoice(s) to pay *</label>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>No outstanding invoices for this patient.</div>}
            <div style={{ marginBottom: 14 }}>
              {invoices.map((inv) => (
                <label
                  key={inv.id}
                  style={{
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px',
                    borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer',
                    background: inv.id === highlightInvoiceId ? 'var(--green-lt)' : 'transparent', borderRadius: 4,
                  }}
                >
                  <span>
                    <input type="checkbox" checked={selectedInvoiceIds.includes(inv.id)} onChange={() => toggleInvoice(inv.id)} style={{ marginRight: 8 }} />
                    {inv.invoice_number} -- <span className={`badge ${inv.status === 'Partial' ? 'b-amber' : 'b-red'}`}>{inv.status}</span>
                    {inv.id === highlightInvoiceId && <span className="badge b-green" style={{ marginLeft: 6 }}>Just billed</span>}
                  </span>
                  <span style={{ fontWeight: 600 }}>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </label>
              ))}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Amount collecting (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Total selected outstanding</label>
                <input className="fi" value={`Rs.${totalSelectedOutstanding.toFixed(2)}`} readOnly style={{ background: 'var(--g50)', fontWeight: 700, color: 'var(--red)' }} />
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8, marginBottom: 14, flexWrap: 'wrap' }}>
              <button className="btn btn-sm" onClick={useFullOutstanding}>Use full outstanding amount</button>
              {advanceBalance > 0 && (
                <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleApplyAdvanceAndCollect} disabled={applyingAdvance}>
                  <i className="ti ti-piggy-bank"></i> {applyingAdvance ? 'Applying advance...' : 'Apply Advance & Auto-fill Remaining'}
                </button>
              )}
            </div>

            <label className="flbl">Payment mode(s) * -- split across multiple if needed</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Finalizing...' : 'Finalize Payment'}
            </button>
          </div>
        )}
      </div>

      <div>
        {!urlPatientId && (
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Unpaid Invoices
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click one to start collecting for that patient.</div>
            {unpaidInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => { setHighlightInvoiceId(inv.id); pickPatient(inv.patients); }}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{inv.invoice_number}</span>
                  <span>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </div>
              </div>
            ))}
            {unpaidInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding right now.</div>}
          </div>
        )}

        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Payment Summary
          </div>
          {!selectedPatient ? (
            <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 13 }}>Select patient and invoice</div>
          ) : (
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices selected</span><span>{selectedInvoiceIds.length}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total outstanding</span><span>Rs.{totalSelectedOutstanding.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Amount collecting</span><span>Rs.{(parseFloat(amount) || 0).toFixed(2)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}



FILEEOF_app__main__payments_collect_collect_payment_tab_js


echo "Files written."

git add -A
git commit -m "Pharmacy: professional KPI-card dashboard, fix payment auto-fill (missing patientId), bill-and-pay opens as popup and closes itself on receipt"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
