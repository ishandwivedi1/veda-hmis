#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# The DB migration has ALREADY been applied to both production and
# training Supabase projects directly -- this script only pushes the
# application code.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/page.js" << 'FILEEOF_app__main__pharmacy_page_js'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getPharmacyDashboard } from './actions';
import PharmacyTabs from './pharmacy-tabs';

const STATUS_BADGE = {
  Purchased: 'b-green',
  Pending: 'b-amber',
  Deferred: 'b-gray',
  'Declined / Bought Elsewhere': 'b-red',
};

export default function PharmacyDashboard() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const data = await getPharmacyDashboard();
    setGroups(data);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 20000);
    return () => clearInterval(interval);
  }, [refresh]);

  const pendingCount = groups.reduce((sum, g) => sum + g.items.filter((i) => i.purchaseStatus === 'Pending').length, 0);

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
        <i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy
      </div>
      <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 12 }}>
        {pendingCount} item(s) still pending today &middot; auto-refreshes every 20s
      </div>
      <PharmacyTabs />

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && groups.map((g) => (
        <Link key={g.visitId} href={`/pharmacy/${g.visitId}`} style={{ textDecoration: 'none', color: 'inherit' }}>
          <div className="card" style={{ marginBottom: 12, cursor: 'pointer' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <div>
                <div style={{ fontSize: 15, fontWeight: 700 }}>
                  {g.patient?.first_name} {g.patient?.last_name}
                </div>
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>{g.patient?.uhid} &middot; Visit {g.visitNumber}</div>
              </div>
              {g.allPurchased && <span className="badge b-green" style={{ fontSize: 11 }}>All Purchased</span>}
              {!g.allPurchased && g.anyPending && <span className="badge b-amber" style={{ fontSize: 11 }}>Action Needed</span>}
            </div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {g.items.map((rx) => (
                <span key={rx.id} className={`badge ${STATUS_BADGE[rx.purchaseStatus] || 'b-gray'}`} style={{ fontSize: 10 }}>
                  {rx.drug_name}: {rx.purchaseStatus}
                </span>
              ))}
            </div>
          </div>
        </Link>
      ))}

      {!loading && groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No prescriptions written today yet.
        </div>
      )}

      <div className="card" style={{ marginTop: 20, textAlign: 'center', color: 'var(--g400)', fontSize: 12, padding: 14 }}>
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

  if (error) return [];

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

  return Object.values(groups).map((g) => ({
    ...g,
    allPurchased: g.items.every((i) => i.purchaseStatus === 'Purchased'),
    anyPending: g.items.some((i) => i.purchaseStatus === 'Pending'),
  }));
}

// ── WORKSPACE ──
export async function getPharmacyWorkspace(visitId) {
  const supabase = await createClient();

  const [{ data: visit }, { data: prescriptions }, { data: drugCatalog }] = await Promise.all([
    supabase.from('visits').select('id, visit_number, patients(first_name, last_name, uhid, mobile)').eq('id', visitId).single(),
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

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/pharmacy-tabs.js" << 'FILEEOF_app__main__pharmacy_pharmacy_tabs_js'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/pharmacy', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/pharmacy/history', label: 'History', icon: 'ti-history' },
];

export default function PharmacyTabs() {
  const pathname = usePathname();
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Link
          key={t.href}
          href={t.href}
          className={pathname === t.href ? 'btn btn-primary' : 'btn'}
          style={{ textDecoration: 'none' }}
        >
          <i className={`ti ${t.icon}`}></i> {t.label}
        </Link>
      ))}
    </div>
  );
}
FILEEOF_app__main__pharmacy_pharmacy_tabs_js

mkdir -p "app/(main)/pharmacy/[visitId]"
cat > "app/(main)/pharmacy/[visitId]/page.js" << 'FILEEOF_app__main__pharmacy__visitId__page_js'
import Workspace from './workspace';

export default async function PharmacyWorkspacePage({ params }) {
  const { visitId } = await params;
  return <Workspace visitId={visitId} />;
}
FILEEOF_app__main__pharmacy__visitId__page_js

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
    router.push(`/payments/collect?invoiceId=${result.invoiceId}`);
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

mkdir -p "app/(main)/pharmacy/history"
cat > "app/(main)/pharmacy/history/page.js" << 'FILEEOF_app__main__pharmacy_history_page_js'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getPharmacyHistory } from '../actions';
import PharmacyTabs from '../pharmacy-tabs';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

export default function PharmacyHistoryPage() {
  const [date, setDate] = useState(todayIST());
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    const data = await getPharmacyHistory(date);
    setGroups(data);
    setLoading(false);
  }, [date]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>
        <i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy
      </div>
      <PharmacyTabs />

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
        <label style={{ fontSize: 13, color: 'var(--g500)' }}>Date:</label>
        <input type="date" className="fi fi-sm" value={date} max={todayIST()} onChange={(e) => setDate(e.target.value)} style={{ maxWidth: 170 }} />
      </div>

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
            <div>
              <div style={{ fontSize: 14, fontWeight: 700 }}>{g.patient?.first_name} {g.patient?.last_name}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid} &middot; Visit {g.visitNumber}</div>
            </div>
            {g.invoiceId && (
              <Link href={`/payments/collect?invoiceId=${g.invoiceId}`} style={{ fontSize: 12 }}>
                View Invoice <i className="ti ti-external-link"></i>
              </Link>
            )}
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {g.items.map((rx) => (
              <span key={rx.id} className="badge b-gray" style={{ fontSize: 11 }}>
                {rx.drug_name} x{rx.qty} &middot; {new Date(rx.dispensed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}
              </span>
            ))}
          </div>
        </div>
      ))}

      {!loading && groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No dispensing recorded for this date.
        </div>
      )}
    </div>
  );
}
FILEEOF_app__main__pharmacy_history_page_js


echo "Files written."

git add -A
git commit -m "Rebuild Pharmacy as Dashboard/Workspace/History, add direct billing to invoice + redirect to Payments, fix live dispense_prescription_and_bill bug"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
