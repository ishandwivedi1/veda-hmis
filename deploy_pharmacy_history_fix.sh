
#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed.

cd ~/veda-hmis 2>/dev/null || true

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

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16, flexWrap: 'wrap' }}>
        <label style={{ fontSize: 13, color: 'var(--g500)' }}>Date:</label>
        <input type="date" className="fi fi-sm" value={date} max={todayIST()} onChange={(e) => setDate(e.target.value)} style={{ maxWidth: 170 }} />
        {!loading && groups.length > 0 && (
          <span className="badge b-blue" style={{ fontSize: 12 }}>
            Day total: Rs {groups.reduce((s, g) => s + g.total, 0).toLocaleString('en-IN', { maximumFractionDigits: 2 })}
          </span>
        )}
      </div>

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
            <div>
              <div style={{ fontSize: 14, fontWeight: 700 }}>{g.patient?.first_name} {g.patient?.last_name}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid} &middot; Visit {g.visitNumber}</div>
            </div>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 15, fontWeight: 800 }}>Rs {g.total.toLocaleString('en-IN', { maximumFractionDigits: 2 })}</div>
              {g.invoiceId && (
                <Link href={`/billing/details?invoiceId=${g.invoiceId}`} style={{ fontSize: 12 }}>
                  View Invoice <i className="ti ti-external-link"></i>
                </Link>
              )}
            </div>
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {g.items.map((rx) => (
              <span key={rx.id} className="badge b-gray" style={{ fontSize: 11 }}>
                {rx.drug_name} x{rx.qty} {rx.net > 0 && `-- Rs ${rx.net.toLocaleString('en-IN', { maximumFractionDigits: 2 })}`} &middot; {new Date(rx.dispensed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}
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

mkdir -p "app/(main)/billing/details"
cat > "app/(main)/billing/details/invoice-details-tab.js" << 'FILEEOF_app__main__billing_details_invoice_details_tab_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, resendInvoiceBillWhatsApp } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'net_high', label: 'Net (High-Low)' },
  { value: 'net_low', label: 'Net (Low-High)' },
];

function sortInvoices(invoices, sort) {
  const list = [...invoices];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'net_high': return list.sort((a, b) => Number(b.net) - Number(a.net));
    case 'net_low': return list.sort((a, b) => Number(a.net) - Number(b.net));
    default: return list.sort((a, b) => new Date(b.created_at) - new Date(a.created_at)); // newest
  }
}

export default function InvoiceDetailsTab() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [invoices, setInvoices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [error, setError] = useState('');
  const [waStatus, setWaStatus] = useState(''); // '', 'sending', 'sent', 'warning', 'error'
  const [waMsg, setWaMsg] = useState('');

  async function handleSendWhatsAppBill() {
    if (!selected) return;
    setWaStatus('sending');
    setWaMsg('');
    const result = await resendInvoiceBillWhatsApp(selected.id);
    if (result.error) { setWaStatus('error'); setWaMsg(result.error); return; }
    if (result.warning) { setWaStatus('warning'); setWaMsg(result.warning); return; }
    setWaStatus('sent');
  }

  const runSearch = useCallback(async () => {
    setInvoices(await searchInvoices(query, deptFilter));
  }, [query, deptFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  const sortedInvoices = sortInvoices(invoices, sortBy);

  async function openInvoice(inv) {
    setError('');
    setWaStatus('');
    setWaMsg('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  // Deep-linked from elsewhere (e.g. Pharmacy History's "View
  // Invoice") -- open that exact invoice directly instead of
  // requiring a text search first.
  const urlInvoiceId = searchParams.get('invoiceId');
  useEffect(() => {
    if (urlInvoiceId) openInvoice({ id: urlInvoiceId });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlInvoiceId]);

  const balanceDue = selected ? Number(selected.net) - Number(selected.paid) : 0;

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Search Invoices
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 200 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Patient name or UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={deptFilter} onChange={(e) => setDeptFilter(e.target.value)}>
            <option value="">All departments</option>
            <option>Consultation</option>
            <option>Investigation</option>
            <option>Surgery</option>
            <option>Pharmacy</option>
          </select>
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>

        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Date</th><th>Patient</th><th>Visit</th><th>Gross</th><th>Disc</th><th>Net</th><th>Paid</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {sortedInvoices.map((inv) => (
              <tr key={inv.id} onClick={() => openInvoice(inv)} style={{ cursor: 'pointer', background: selected?.id === inv.id ? 'var(--blue-lt)' : 'transparent' }}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{inv.invoice_number || '--'}</td>
                <td>{new Date(inv.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}</td>
                <td style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td>Rs.{inv.gross}</td>
                <td>{inv.gross - inv.net > 0 ? `Rs.${(inv.gross - inv.net).toFixed(2)}` : '--'}</td>
                <td>Rs.{inv.net}</td>
                <td>Rs.{inv.paid}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                <td>
                  <button
                    onClick={(e) => { e.stopPropagation(); openPrintPopup(`/invoice-print/${inv.id}`); }}
                    className="btn"
                    style={{ padding: '3px 8px', fontSize: 11 }}
                    title="Print / PDF"
                  >
                    <i className="ti ti-printer"></i>
                  </button>
                </td>
              </tr>
            ))}
            {sortedInvoices.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices found.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {selected && (
        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> {selected.invoice_number || 'Invoice Detail'}</div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <button onClick={() => openPrintPopup(`/invoice-print/${selected.id}`)} className="btn btn-sm">
                  <i className="ti ti-printer"></i> Print / PDF
                </button>
                <button onClick={handleSendWhatsAppBill} className="btn btn-sm" disabled={waStatus === 'sending'}>
                  <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i>
                  {waStatus === 'sending' ? 'Sending...' : 'Send WhatsApp Bill'}
                </button>
                <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
              </div>
            </div>
            {error && <div className="msg-err">{error}</div>}
            {waStatus === 'sent' && (
              <div className="msg-success" style={{ marginBottom: 10 }}>
                <i className="ti ti-circle-check"></i> WhatsApp bill sent.
              </div>
            )}
            {waStatus === 'warning' && (
              <div className="msg-info" style={{ marginBottom: 10, color: 'var(--amber)' }}>
                <i className="ti ti-alert-triangle"></i> {waMsg}
              </div>
            )}
            {waStatus === 'error' && (
              <div className="msg-err" style={{ marginBottom: 10 }}>
                <i className="ti ti-alert-circle"></i> {waMsg}
              </div>
            )}
            <div style={{ fontSize: 13, marginBottom: 12 }}>
              <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
            </div>
            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Net</th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id}><td>{li.service_name}</td><td>{li.qty}</td><td>Rs.{li.net}</td></tr>
                ))}
              </tbody>
            </table>
            <div style={{ fontSize: 13, lineHeight: 1.9, marginTop: 12, borderTop: '1px solid var(--g200)', paddingTop: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Net Total</span><span style={{ fontWeight: 700 }}>Rs.{selected.net}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>Rs.{selected.paid}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, color: balanceDue > 0 ? 'var(--red)' : 'var(--green)' }}><span>Balance Due</span><span>Rs.{balanceDue}</span></div>
            </div>
          </div>

          {balanceDue > 0 && selected.status !== 'Cancelled' && (
            <div className="card">
              <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
                Balance of Rs.{balanceDue} still due on this invoice.
              </div>
              <a
                href={`/payments/collect?patientId=${selected.patient_id}&invoiceId=${selected.id}`}
                className="btn btn-primary"
                style={{ textDecoration: 'none' }}
              >
                <i className="ti ti-cash"></i> Collect Payment
              </a>
            </div>
          )}
        </div>
      )}
    </div>
  );
}


FILEEOF_app__main__billing_details_invoice_details_tab_js


echo "Files written."

git add -A
git commit -m "Pharmacy History: View Invoice opens the actual invoice detail page, show per-visit and day-total medicine cost inline"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
