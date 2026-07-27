#!/bin/bash
set -e
echo "Applying: IST time-display fix (site-wide) + compulsory Cash Day Open"

mkdir -p "app/(main)/cash-management"

cat > "app/(main)/billing/actions.js" << 'PYEOF_8729133913428851282'
'use server';

import { createClient } from '@/lib/supabase-server';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';

export async function getTodaysVisitsForBilling() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

// Lists every invoice already on a visit -- used both by New Invoice
// (to show what exists before deciding to create another) and by
// Invoice Modification (to jump straight to a visit's invoice(s)
// instead of a generic search).
export async function getInvoicesForVisit(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('invoices')
    .select('*, patients(id, first_name, last_name, uhid, mobile)')
    .eq('visit_id', visitId)
    .order('created_at', { ascending: false });
  if (error) return { error: error.message };
  return { invoices: data || [] };
}

// Always creates a brand new invoice -- creating one is now always a
// deliberate action (the "New Invoice" button + a chosen purpose), so
// there's no "get or reuse" ambiguity here. Adding to an existing
// invoice happens through Invoice Modification instead.
export async function createInvoiceForVisit(patientId, visitId, purpose) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_invoice_for_visit', {
    p_patient_id: patientId,
    p_visit_id: visitId || null,
    p_purpose: purpose || 'Consultation',
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data: services } = await supabase.from('master_services').select('*').eq('status', 'Active');
  const { data: drugs } = await supabase.from('master_drugs').select('*').eq('status', 'Active');
  const { data: packages } = await supabase.from('master_packages').select('*').eq('status', 'Active');

  // Drugs live in their own master (managed under Master Data -> Drugs)
  // but bill under the Pharmacy department -- mapped here rather than
  // duplicated into master_services, so Master Data stays the one
  // place to manage drug pricing.
  const drugsAsServices = (drugs || []).map((d) => ({
    code: d.code,
    name: `${d.generic}${d.strength ? ' ' + d.strength : ''}${d.brand ? ' (' + d.brand + ')' : ''}`,
    dept: 'Pharmacy',
    rate: d.rate,
    gst_pct: d.gst_pct,
    status: d.status,
  }));

  // Same mapping for packages -- their own master (Financial Masters ->
  // Surgery tab), billed under the Surgery department. Without this the
  // Surgery dropdown in New Invoice has nothing to show, even though
  // add_invoice_line_item already knows how to look packages up.
  const packagesAsServices = (packages || []).map((p) => ({
    code: p.code,
    name: p.name,
    dept: 'Surgery',
    rate: p.price,
    gst_pct: 0,
    status: p.status,
  }));

  return [...(services || []), ...drugsAsServices, ...packagesAsServices].sort((a, b) => a.name.localeCompare(b.name));
}

export async function addLineItem(invoiceId, serviceCode, qty, discType, discValue, discReason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
    p_disc_type: discType || 'none',
    p_disc_value: discValue || 0,
    p_disc_reason: discReason || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── NEW INVOICE (standalone, not tied to visit creation) ──
export async function searchPatientsForInvoice(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getMostRecentVisitForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return data || null;
}
export async function getVisitWithPatient(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('visits')
    .select('*, patients(id, first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();
  if (error) return { error: error.message };
  return { visit: data };
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED INVESTIGATIONS" WIDGET ──
// Takes the investigation_orders selected on the dashboard and turns
// each into a draft line item by matching its free-text name against
// the Investigation department of the service catalog. A name that
// doesn't match anything (e.g. it was typed instead of picked from
// master data back in Consultation) is returned as unmatched so the
// front desk can still see it and add it manually rather than it
// silently vanishing from the invoice.
export async function getInvestigationOrdersForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: orders, error } = await supabase
    .from('investigation_orders')
    .select('id, name, eye, priority, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: catalog } = await supabase.from('master_services').select('*').eq('dept', 'Investigation').eq('status', 'Active');

  const items = (orders || []).map((io) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === io.name.toLowerCase());
    return {
      invOrderId: io.id,
      name: io.name,
      eye: io.eye,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

// Called once the invoice carrying these investigations is actually
// saved (finalized or draft) -- flips them out of the Front Office
// queue and remembers which invoice they landed on, so the Queue can
// show real payment status rather than just "billed".
export async function markInvestigationOrdersBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      billing_status: 'Billed',
      billed: true,
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE WIDGET DATA -- grouped by visit, same shape as
//    getPendingInvestigationBilling() in the investigation module. ──
export async function getPendingProcedureBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .eq('billing_status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((p) => {
    const visitId = p.encounters?.visit_id;
    const visit = p.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(p);
  });

  return Object.values(groups);
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED MINOR PROCEDURES" WIDGET ──
// Same pattern as getInvestigationOrdersForBilling -- matches each
// plan_procedures row against the Minor Procedure department of the
// service catalog by name.
export async function getProceduresForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: orders, error } = await supabase
    .from('plan_procedures')
    .select('id, name, eye, notes, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: catalog } = await supabase.from('master_services').select('*').eq('dept', 'Minor Procedure').eq('status', 'Active');

  const items = (orders || []).map((p) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === p.name.toLowerCase());
    return {
      procedureId: p.id,
      name: p.name,
      eye: p.eye,
      notes: p.notes,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

export async function markProceduresBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_procedures')
    .update({
      billing_status: 'Billed',
      billed: true,
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED MEDICINES" WIDGET ──
// Same idea as investigation prefill, but matched against master_drugs
// the same fuzzy way the pharmacy's own auto-bill RPC does (drug_name
// containing the generic or brand name), since prescriptions are
// free-text ("Timolol 0.5% eye drops") rather than a catalog code.
export async function getPrescriptionsForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: prescriptions, error } = await supabase
    .from('prescriptions')
    .select('id, drug_name, eye, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: drugs } = await supabase.from('master_drugs').select('*').eq('status', 'Active');

  const items = (prescriptions || []).map((rx) => {
    const nameLower = rx.drug_name.toLowerCase();
    const match = (drugs || []).find(
      (d) => (d.generic && nameLower.includes(d.generic.toLowerCase())) || (d.brand && nameLower.includes(d.brand.toLowerCase()))
    );
    return {
      rxId: rx.id,
      name: rx.drug_name,
      eye: rx.eye,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

// Called once the invoice carrying these prescriptions is actually
// saved -- flips them out of the Front Office queue. When the patient
// later reaches Pharmacy, dispense_prescription_and_bill sees
// billing_status = 'Billed' and skips adding a second line item.
export async function markPrescriptionsBilled(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('prescriptions')
    .update({
      billing_status: 'Billed',
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PREFILL FROM FRONT OFFICE'S "BIOMETRY" WIDGET ──
// Unlike investigations/prescriptions, there's exactly one fixed
// billing line for any biometry -- Biometry's own dedicated Financial
// Masters department (separate from Investigation for clarity).
// ── PACKAGE BILLING (Front Office widget) ──
// Package gets locked in Counselling; this is the real invoicing path
// for it -- goes through New Invoice -> Finalize -> Collect Payment like
// everything else, unlike the old generate_package_invoice RPC which
// used to mark the invoice paid directly with no actual payment
// collected (see package-billing-tab.js).
export async function getPendingPackageBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(id, code, name, price)')
    .eq('package_locked', true)
    .eq('package_billed', false)
    .not('package_id', 'is', null);
  if (error) return [];
  return (data || []).filter((sc) => sc.master_packages);
}

export async function getPackageForBilling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('master_packages:package_id(code, name, price)').eq('id', caseId).maybeSingle();
  if (!sc?.master_packages) return { item: null };
  return {
    item: {
      caseId, name: sc.master_packages.name, matched: true,
      serviceCode: sc.master_packages.code, rate: sc.master_packages.price, gstPct: 0,
    },
  };
}

// Called once the invoice carrying this package is actually saved --
// flips it out of the Front Office queue.
export async function markPackageBilled(caseId, invoiceId) {
  const supabase = await createClient();
  if (!caseId) return { success: true };
  const { error } = await supabase.from('surgical_cases').update({ package_billed: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getBiometryForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: service } = await supabase
    .from('master_services')
    .select('code, name, rate, gst_pct')
    .eq('status', 'Active')
    .eq('dept', 'Biometry')
    .limit(1)
    .maybeSingle();

  if (!service) {
    return { items: ids.map((id) => ({ bioId: id, name: 'Biometry', matched: false })) };
  }

  return {
    items: ids.map((id) => ({
      bioId: id, name: service.name, matched: true,
      serviceCode: service.code, rate: service.rate, gstPct: service.gst_pct,
    })),
  };
}

// Called once the invoice carrying this biometry is actually saved --
// flips it out of the Front Office queue.
export async function markBiometryBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: 'Billed',
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getInvoiceById(invoiceId) {
  const supabase = await createClient();
  const { data: invoice, error } = await supabase.from('invoices').select('*, patients(id, first_name, last_name, uhid, mobile)').eq('id', invoiceId).single();
  if (error) return { error: error.message };
  const { data: lineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');
  return { invoice, lineItems: lineItems || [] };
}

export async function removeLineItem(lineItemId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId, p_reason: reason || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function cancelInvoice(invoiceId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('cancel_invoice', { p_invoice_id: invoiceId, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

// ── PACKAGE BILLING ──
export async function getPostSurgicalPendingPackages() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('surgical_cases')
    .select('*, patients(id, first_name, last_name, uhid), master_packages(id, name, price)')
    .eq('status', 'Completed')
    .eq('package_billed', false);
  return data || [];
}

export async function getActivePackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function searchPatientsForPackage(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function generatePackageInvoice(patientId, packageId, paymentMode, advanceAmount, surgicalCaseId) {
  if (advanceAmount && Number(advanceAmount) > 0) {
    const blocked = await requireDayOpen();
    if (blocked) return blocked;
  }
  const supabase = await createClient();

  const { data: visit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data, error } = await supabase.rpc('generate_package_invoice', {
    p_patient_id: patientId,
    p_visit_id: visit?.id || null,
    p_package_id: packageId,
    p_payment_mode: paymentMode,
    p_advance_amount: advanceAmount || 0,
    p_surgical_case_id: surgicalCaseId || null,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── INVOICE DETAILS (search + history) ──
export async function getTodaysInvoicesForModification() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function searchInvoices(query, deptFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
    .order('created_at', { ascending: false })
    .limit(50);

  if (query) {
    // First try to match by patient -- invoices don't carry patient
    // name/uhid directly, so we resolve matching patient ids first.
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    if (ids.length === 0) return [];
    q = q.in('patient_id', ids);
  }

  const { data: invoices } = await q;
  if (!invoices || invoices.length === 0) return [];

  if (!deptFilter) return invoices;

  // Department filter is per-line-item, not per-invoice -- keep only
  // invoices that have at least one line item in that department.
  const invoiceIds = invoices.map((i) => i.id);
  const { data: lines } = await supabase.from('invoice_line_items').select('invoice_id, dept').in('invoice_id', invoiceIds).eq('dept', deptFilter);
  const matchingIds = new Set((lines || []).map((l) => l.invoice_id));
  return invoices.filter((i) => matchingIds.has(i.id));
}

// NOTE: recordPayment/record_payment was removed (Migration 36) --
// it bypassed the real payment ledger (payments/payment_modes/
// payment_allocations), leaving invoices.paid inconsistent with
// actual receipts. Use Collect Payment (payments/collect) instead,
// which properly creates a full payment record.



PYEOF_8729133913428851282

cat > "app/(main)/billing/billing-tabs.js" << 'PYEOF_6159555488323214901'
'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

const TABS = [
  { href: '/billing', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/billing/new', label: 'New Invoice', icon: 'ti-file-plus' },
  { href: '/billing/details', label: 'Invoice Details', icon: 'ti-search' },
  { href: '/billing/cancel', label: 'Invoice Modification', icon: 'ti-edit' },
  { href: '/billing/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function BillingTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true);

  useEffect(() => { isTodayOpen().then(setDayOpen); }, []);

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today's cash day hasn't been opened -- Package Billing advance collection will be blocked until it is. Plain invoicing without an advance still works.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
        </div>
      )}
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
    </div>
  );
}


PYEOF_6159555488323214901

cat > "app/(main)/billing/details/invoice-details-tab.js" << 'PYEOF_389370919986568610'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById } from '../actions';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceDetailsTab() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [invoices, setInvoices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [error, setError] = useState('');

  const runSearch = useCallback(async () => {
    setInvoices(await searchInvoices(query, deptFilter));
  }, [query, deptFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  async function openInvoice(inv) {
    setError('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

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
        </div>

        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Date</th><th>Patient</th><th>Visit</th><th>Gross</th><th>Disc</th><th>Net</th><th>Paid</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {invoices.map((inv) => (
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
                  <a
                    href={`/invoice-print/${inv.id}`}
                    target="_blank"
                    rel="noopener noreferrer"
                    onClick={(e) => e.stopPropagation()}
                    className="btn"
                    style={{ padding: '3px 8px', fontSize: 11, textDecoration: 'none' }}
                    title="Print / PDF"
                  >
                    <i className="ti ti-printer"></i>
                  </a>
                </td>
              </tr>
            ))}
            {invoices.length === 0 && (
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
                <a href={`/invoice-print/${selected.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                  <i className="ti ti-printer"></i> Print / PDF
                </a>
                <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
              </div>
            </div>
            {error && <div className="msg-err">{error}</div>}
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


PYEOF_389370919986568610

cat > "app/(main)/biometry/[id]/approval-tab.js" << 'PYEOF_761211619952016359'
'use client';

import { useState, useEffect } from 'react';
import { approveIolPlan, getIolVersionHistory } from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];

export default function ApprovalTab({ record, recordId, surgeonName, onSaved }) {
  const [finalPower, setFinalPower] = useState('');
  const [finalFormula, setFinalFormula] = useState(FORMULA_NAMES[0]);
  const [finalCategory, setFinalCategory] = useState(IOL_CATEGORIES[0]);
  const [finalTarget, setFinalTarget] = useState('');
  const [iolCatalogId, setIolCatalogId] = useState('');
  const [surgeonNotes, setSurgeonNotes] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [versions, setVersions] = useState([]);
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [revising, setRevising] = useState(false);

  async function loadVersions() {
    const v = await getIolVersionHistory(recordId);
    setVersions(v);
  }

  useEffect(() => {
    getActiveIolCatalog().then(setCatalog);
    loadVersions();
  }, [recordId]);

  useEffect(() => {
    const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
    setFinalPower(record.final_iol_power || selected?.power || '');
    setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
    setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
    setFinalTarget(record.target_refraction || '');
    setIolCatalogId(record.final_iol_catalog_id || '');
    setSurgeonNotes(record.surgeon_notes || '');
  }, [record]);

  const notCalculated = record.status !== 'Calculated' && record.status !== 'Approved';
  const isApproved = record.status === 'Approved' && !revising;
  const catalogForCategory = catalog.filter((c) => c.category === finalCategory);

  async function handleApprove() {
    setError(''); setOkMsg('');
    if (!finalPower.trim()) { setError('Final IOL power is required.'); return; }
    setSaving(true);
    const result = await approveIolPlan(recordId, {
      finalPower, finalFormula, finalCategory, finalTarget, iolCatalogId: iolCatalogId || null, surgeonNotes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(`IOL Plan approved (version ${result.versionNo}).`);
    setRevising(false);
    loadVersions();
    if (onSaved) onSaved();
  }

  if (notCalculated) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Save at least one formula result in IOL Calculation before approval is available.
      </div>
    );
  }

  const selectedCatalogItem = catalog.find((c) => c.id === record.final_iol_catalog_id);

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#166534,#157a4f)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <i className="ti ti-shield-check" style={{ fontSize: 26, flexShrink: 0 }}></i>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Final IOL Plan Approval</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{record.procedure_name || 'Procedure not set'} {record.surgical_eye} -- Dr. {surgeonName}</div>
        </div>
        <div style={{ marginLeft: 'auto', textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>Only surgeon/ophthalmologist should approve</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 2 }}>{isApproved ? 'Approved' : revising ? 'Revising' : 'Approval required'}</div>
        </div>
      </div>

      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 12 }}>
        <i className="ti ti-alert-triangle"></i> This isn't role-restricted at the database level yet -- please only approve if you're the operating surgeon or ophthalmologist for this case.
      </div>

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}
      {revising && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-edit"></i> Revising the approved plan. Approving again will add a new version -- the current approved version stays in history, marked Superseded.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calculator" style={{ color: 'var(--indigo)' }}></i> Calculation Review</div>
            {record.formula_results?.length > 0 ? (
              record.formula_results.map((r, i) => (
                <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12, fontWeight: r.name === record.selected_formula ? 700 : 400, color: r.name === record.selected_formula ? 'var(--green)' : 'var(--g700)' }}>
                  <span>{r.name}{r.name === record.selected_formula ? ' (selected)' : ''}</span>
                  <span style={{ fontFamily: 'monospace' }}>{r.power} D -- {r.refraction}</span>
                </div>
              ))
            ) : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No calculation saved yet.</div>
            )}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Final IOL Plan</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">Final IOL power (D) *</label>
                <input className="fi fi-sm" placeholder="+21.5" value={finalPower} onChange={(e) => setFinalPower(e.target.value)} disabled={isApproved} />
              </div>
              <div>
                <label className="flbl">Formula used</label>
                <select className="fi fi-sm" value={finalFormula} onChange={(e) => setFinalFormula(e.target.value)} disabled={isApproved}>
                  {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                </select>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">IOL category *</label>
                <select className="fi fi-sm" value={finalCategory} onChange={(e) => { setFinalCategory(e.target.value); setIolCatalogId(''); }} disabled={isApproved}>
                  {IOL_CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Target refraction</label>
                <input className="fi fi-sm" value={finalTarget} onChange={(e) => setFinalTarget(e.target.value)} disabled={isApproved} />
              </div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Specific IOL (Master Data -- IOL Catalog)</label>
              <select className="fi fi-sm" value={iolCatalogId} onChange={(e) => setIolCatalogId(e.target.value)} disabled={isApproved}>
                <option value="">-- Not specified --</option>
                {catalogForCategory.map((c) => <option key={c.id} value={c.id}>{c.brand} -- {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
              </select>
              {catalogForCategory.length === 0 && (
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 3 }}>No catalog items for {finalCategory} yet -- add them in Master Data -&gt; Clinical -&gt; IOL Catalog.</div>
              )}
            </div>
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Surgeon notes</label>
              <textarea className="fi fi-sm" rows={2} value={surgeonNotes} onChange={(e) => setSurgeonNotes(e.target.value)} disabled={isApproved} placeholder="e.g. Aim for slight myopia. Avoid multifocal due to macular finding. Toric axis to be confirmed intra-op..." />
            </div>

            {!isApproved && (
              <button className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleApprove} disabled={saving}>
                <i className="ti ti-shield-check"></i> {saving ? 'Approving...' : revising ? 'Approve Revised Plan' : 'Approve Final IOL Plan'}
              </button>
            )}
            {revising && (
              <button
                className="btn btn-sm"
                style={{ marginLeft: 8 }}
                onClick={() => {
                  setRevising(false);
                  const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
                  setFinalPower(record.final_iol_power || selected?.power || '');
                  setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
                  setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
                  setFinalTarget(record.target_refraction || '');
                  setIolCatalogId(record.final_iol_catalog_id || '');
                  setSurgeonNotes(record.surgeon_notes || '');
                  setError(''); setOkMsg('');
                }}
              >
                Cancel revision
              </button>
            )}
            {record.status === 'Approved' && !revising && (
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                Approved{record.approved_at ? ` on ${new Date(record.approved_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. To change the plan (e.g. patient requests a different IOL), click Revise -- this creates a new version without deleting the old one.
              </div>
            )}
            {record.status === 'Approved' && !revising && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => setRevising(true)}>
                <i className="ti ti-edit"></i> Revise plan (creates new version)
              </button>
            )}
          </div>
        </div>

        <div>
          {record.status === 'Approved' && (
            <div className="card" style={{ marginBottom: 12, background: 'var(--green-lt)', borderColor: '#86efac' }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--green)', marginBottom: 8 }}>
                <i className="ti ti-clipboard-check"></i> IOL Planning Summary
              </div>
              <div style={{ fontSize: 12, color: 'var(--g700)', lineHeight: 1.8 }}>
                <div><strong>Power:</strong> {record.final_iol_power} D</div>
                <div><strong>Category:</strong> {record.final_iol_category}</div>
                {selectedCatalogItem && <div><strong>Lens:</strong> {selectedCatalogItem.brand} -- {selectedCatalogItem.model}</div>}
                <div><strong>Target:</strong> {record.target_refraction}</div>
              </div>
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Version History</div>
            {versions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No approved versions yet.</div>}
            {versions.map((v) => (
              <div key={v.id} style={{ padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <span style={{ fontWeight: 700 }}>v{v.version_no} -- {v.power} D ({v.formula})</span>
                  <span className={`badge ${v.status === 'Approved' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 9 }}>{v.status}</span>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>
                  {v.profiles?.full_name || 'Staff'} -- {new Date(v.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </div>
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Approval supersedes the previous plan but never deletes historical versions.</div>
          </div>
        </div>
      </div>
    </div>
  );
}
PYEOF_761211619952016359

cat > "app/(main)/biometry/[id]/measurements-tab.js" << 'PYEOF_1244505004339041697'
'use client';

import { useState, useEffect } from 'react';
import {
  setBiometrySurgicalDetails, saveBiometryDraft, verifyBiometryMeasurements,
} from '../actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];

const DEVICES = ['ZEISS IOLMaster 700', 'Haag-Streit Lenstar', 'NIDEK AL-Scan', 'Manual A-Scan'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

function emptySet(device) {
  return { device, axl: '', k1: '', k2: '', acd: '', lt: '', wtw: '' };
}

function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

// Each eye can hold multiple tagged readings -- e.g. Manual A-Scan AND
// an optical biometer, when both were used (fallback for dense
// cataracts, or cross-checking). Every reading keeps its own device tag.
function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, disabled, headColor, headBg }) {
  const [newDevice, setNewDevice] = useState(DEVICES[0]);

  return (
    <div>
      <div style={{ padding: '8px 12px', fontSize: 12, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, background: headBg, color: headColor, borderRadius: '8px 8px 0 0' }}>
        <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {label}
      </div>
      <div style={{ border: '1px solid var(--g200)', borderTop: 'none', borderRadius: '0 0 8px 8px', padding: '10px 12px' }}>
        {sets.length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)', padding: '4px 0' }}>No readings yet.</div>}

        {sets.map((set, idx) => (
          <div key={idx} style={{ marginBottom: 10, paddingBottom: 10, borderBottom: idx < sets.length - 1 || !disabled ? '1px dashed var(--g200)' : 'none' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
              <span className={`badge ${isComplete(set) ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>
                <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
              </span>
              {!disabled && (
                <button className="btn" style={{ padding: '1px 7px', fontSize: 10 }} onClick={() => onRemoveSet(eyeKey, idx)}>Remove</button>
              )}
            </div>
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <input
                    type="text"
                    value={set[f.key] || ''}
                    onChange={(e) => onFieldChange(eyeKey, idx, f.key, e.target.value)}
                    disabled={disabled}
                    placeholder="--"
                    style={{ width: 90, padding: '4px 7px', border: '1.5px solid var(--g200)', borderRadius: 8, fontSize: 12, textAlign: 'right' }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--g400)' }}>{f.unit}</span>
                </div>
              </div>
            ))}
          </div>
        ))}

        {!disabled && (
          <div style={{ display: 'flex', gap: 6 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={newDevice} onChange={(e) => setNewDevice(e.target.value)}>
              {DEVICES.map((d) => <option key={d}>{d}</option>)}
            </select>
            <button className="btn btn-sm" onClick={() => onAddSet(eyeKey, newDevice)}><i className="ti ti-plus"></i> Add reading</button>
          </div>
        )}
      </div>
    </div>
  );
}

export default function MeasurementsTab({ record, recordId, onSaved }) {
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [procedureName, setProcedureName] = useState('');
  const [surgicalEye, setSurgicalEye] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const m = record.measurements || {};
    setMeasurements({
      re: Array.isArray(m.re) ? m.re : (m.re && Object.keys(m.re).length ? [{ ...m.re, device: record.verify_device || 'Unspecified' }] : []),
      le: Array.isArray(m.le) ? m.le : (m.le && Object.keys(m.le).length ? [{ ...m.le, device: record.verify_device || 'Unspecified' }] : []),
    });
    setProcedureName(record.procedure_name || '');
    setSurgicalEye(record.surgical_eye || '');
    setRemarks(record.verify_remarks || '');
  }, [record]);

  const canEdit = record.status !== 'Calculated' && record.status !== 'Approved';
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';

  function setFieldInSet(eyeKey, idx, fieldKey, value) {
    setMeasurements((prev) => {
      const list = [...(prev[eyeKey] || [])];
      list[idx] = { ...list[idx], [fieldKey]: value };
      return { ...prev, [eyeKey]: list };
    });
  }

  function addSet(eyeKey, device) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: [...(prev[eyeKey] || []), emptySet(device)] }));
  }

  function removeSet(eyeKey, idx) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: (prev[eyeKey] || []).filter((_, i) => i !== idx) }));
  }

  async function handleSaveSurgicalDetails() {
    setError('');
    await setBiometrySurgicalDetails(recordId, procedureName, surgicalEye);
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    await handleSaveSurgicalDetails();
    const result = await saveBiometryDraft(recordId, measurements);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleVerify() {
    setError(''); setOkMsg('');
    if (!procedureName.trim()) { setError('Enter the planned procedure before verifying.'); return; }
    setSaving(true);
    await handleSaveSurgicalDetails();
    const result = await verifyBiometryMeasurements(recordId, measurements, surgicalEye, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Measurements verified. IOL Calculation tab is now available.');
    if (onSaved) onSaved();
  }

  const surgicalEyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  const surgicalEyeHasComplete = surgicalEyeKey ? (measurements[surgicalEyeKey] || []).some(isComplete) : false;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--indigo)' }}></i> Surgical Details</div>
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 10 }}>
          <div>
            <label className="flbl">Planned procedure</label>
            <input className="fi fi-sm" placeholder="e.g. Phacoemulsification + IOL" value={procedureName} onChange={(e) => setProcedureName(e.target.value)} disabled={!canEdit} onBlur={canEdit ? handleSaveSurgicalDetails : undefined} />
          </div>
          <div>
            <label className="flbl">Surgical eye</label>
            <select className="fi fi-sm" value={surgicalEye} onChange={(e) => setSurgicalEye(e.target.value)} disabled={!canEdit} onBlur={canEdit ? handleSaveSurgicalDetails : undefined}>
              <option value="">-- Select --</option>
              <option value="RE">Right Eye (RE)</option>
              <option value="LE">Left Eye (LE)</option>
              <option value="OU">Both Eyes (OU)</option>
            </select>
          </div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isVerified ? 'b-green' : 'b-gray'}`}>{isVerified ? 'Verified' : 'Not verified'}</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken for this patient. Each reading keeps its own device tag.
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
          <div style={{ borderRight: '1px solid var(--g200)' }}>
            <EyeSets label="Right Eye (OD)" eyeKey="re" sets={measurements.re || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--blue)" headBg="var(--blue-lt)" />
          </div>
          <div>
            <EyeSets label="Left Eye (OS)" eyeKey="le" sets={measurements.le || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--teal)" headBg="var(--teal-lt)" />
          </div>
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Reports (IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            Verification confirms technical accuracy -- not the surgical plan. Requires at least one complete reading (AXL, K1, K2, ACD) for the surgical eye.
            {surgicalEyeKey && !surgicalEyeHasComplete && <span style={{ color: 'var(--amber)', fontWeight: 600 }}> No complete reading yet for {surgicalEye}.</span>}
          </div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
              <i className="ti ti-shield-check"></i> Verify Measurements
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
          </div>
        </div>
      )}

      {isVerified && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measurements verified{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Continue to the IOL Calculation tab.
          </div>
        </div>
      )}
    </div>
  );
}
PYEOF_1244505004339041697

cat > "app/(main)/biometry/history/page.js" << 'PYEOF_5857821747196694968'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryHistory } from '../actions';

export default function BiometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patients, setPatients] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const router = useRouter();

  const refresh = useCallback(async (filter) => {
    const result = await getBiometryHistory(filter || undefined);
    setRows(result.rows);
    setPatients(result.patients);
  }, []);

  useEffect(() => { refresh(patientFilter); }, [patientFilter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Biometry History</div>
          <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
            <option value="">All patients</option>
            {patients.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
          Historical measurements are never overwritten. Recalculations and re-approvals create new versions, visible in each record's Surgeon Approval tab.
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date</th><th>Patient</th><th>Eye</th><th>AXL</th><th>K1/K2</th><th>ACD</th><th>Device</th><th>Formula</th><th>Approved IOL</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.visits?.patients;
              const eyeKey = r.surgical_eye === 'RE' ? 're' : r.surgical_eye === 'LE' ? 'le' : null;
              const eyeSets = eyeKey && Array.isArray(r.measurements?.[eyeKey]) ? r.measurements[eyeKey] : [];
              const m = eyeSets.find((s) => s.axl && s.k1 && s.k2 && s.acd) || eyeSets[0] || {};
              return (
                <tr key={r.id} onClick={() => router.push(`/biometry/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.updated_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td>
                    <strong>{patient?.first_name} {patient?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span>
                  </td>
                  <td>{r.surgical_eye || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.axl || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.k1 || '--'}/{m.k2 || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.acd || '--'}</td>
                  <td style={{ fontSize: 11 }}>{m.device || '--'}</td>
                  <td>{r.selected_formula || r.final_iol_power ? (r.selected_formula || '--') : '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.final_iol_power ? `${r.final_iol_power} D` : '--'}</td>
                  <td><span className={`badge ${r.status === 'Approved' ? 'b-green' : 'b-blue'}`}>{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
PYEOF_5857821747196694968

cat > "app/(main)/cash-management/actions.js" << 'PYEOF_6850943513789206473'
'use server';

import { createClient } from '@/lib/supabase-server';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// A plain date string compared against a timestamptz column is
// interpreted at UTC midnight by Postgres, not IST midnight -- that
// mismatch is exactly what made the readiness check disagree with
// close_day() (which correctly uses the ist_date() helper). Building
// explicit +05:30 boundaries makes the two agree.
function istDayBoundsUTC(dateStr) {
  const d = dateStr || todayIST();
  return {
    dateStr: d,
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

export async function getTodayCollectionSummary() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), patients(first_name, last_name)')
    .gte('collected_at', startUTC)
    .lte('collected_at', endUTC)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const isRefund = (p) => p.payment_type === 'refund';

  const byMode = {};
  rows.forEach((p) => {
    (p.payment_modes || []).forEach((m) => {
      byMode[m.mode] = (byMode[m.mode] || 0) + (isRefund(p) ? -Number(m.amount) : Number(m.amount));
    });
  });

  const total = rows.reduce((s, p) => s + (isRefund(p) ? -Number(p.total_amount) : Number(p.total_amount)), 0);

  return { transactions: rows, byMode, total, count: rows.length };
}

export async function getReconciliationData() {
  const supabase = await createClient();
  const today = todayIST();

  const summary = await getTodayCollectionSummary();
  const { data: saved } = await supabase.from('day_reconciliation').select('*').eq('closing_date', today);
  const savedByMode = {};
  (saved || []).forEach((r) => { savedByMode[r.mode] = r; });

  const modes = Object.keys(summary.byMode);
  return modes.map((mode) => ({
    mode,
    expected: summary.byMode[mode],
    actual: savedByMode[mode] ? Number(savedByMode[mode].actual) : summary.byMode[mode],
    saved: !!savedByMode[mode],
    reason: savedByMode[mode]?.reason || '',
  }));
}

export async function saveReconciliation(mode, expected, actual, reason, approvedBy) {
  const supabase = await createClient();
  const today = todayIST();
  const { error } = await supabase.rpc('save_reconciliation', {
    p_closing_date: today, p_mode: mode, p_expected: expected, p_actual: actual,
    p_reason: reason || null, p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getCloseDayReadiness() {
  const supabase = await createClient();
  const today = todayIST();

  const [{ count: unreconciledModes }, recon, { data: alreadyClosed }] = await Promise.all([
    (async () => {
      const summary = await getTodayCollectionSummary();
      const { data: saved } = await supabase.from('day_reconciliation').select('mode').eq('closing_date', today);
      const savedModes = new Set((saved || []).map((r) => r.mode));
      const missing = Object.keys(summary.byMode).filter((m) => !savedModes.has(m));
      return { count: missing.length };
    })(),
    getReconciliationData(),
    supabase.from('day_closings').select('id').eq('closing_date', today).maybeSingle(),
  ]);

  return {
    reconciliationComplete: unreconciledModes === 0,
    alreadyClosed: !!alreadyClosed,
    reconciliation: recon,
  };
}

export async function closeDay(notes) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('close_day', { p_date: null, p_notes: notes || null });
  if (error) return { error: error.message };
  return { closing: data };
}

export async function getDayClosingHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('day_closings')
    .select('*, profiles(full_name)')
    .order('closing_date', { ascending: false })
    .limit(30);
  return data || [];
}

export async function getDailyReport(date) {
  const supabase = await createClient();
  const [{ data: closing }, { data: reconciliation }] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
  ]);
  return { closing, reconciliation: reconciliation || [] };
}

export async function reopenDay(date, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('reopen_day', { p_date: date, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getDayOpening() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('*, profiles(full_name)').eq('opening_date', today).maybeSingle();
  return data;
}

export async function openDay(openingBalance, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('open_day', { p_date: null, p_opening_balance: openingBalance || 0, p_remarks: remarks || null });
  if (error) return { error: error.message };
  return { opening: data };
}

export async function isTodayClosed() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.rpc('is_day_closed', { p_date: today });
  return !!data;
}

export async function isTodayOpen() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('id').eq('opening_date', today).maybeSingle();
  return !!data;
}

// Server-side guard for any action that moves physical cash (collect
// payment, refund, advance, or a package invoice that collects an
// advance inline). Called at the top of those actions specifically --
// not a global gate -- so clinical work (doctor, optometry, OT) is
// never blocked by a missed Open Day. Checked here rather than only
// in the UI so it can't be bypassed by calling the server action
// directly. Each new IST calendar date has no day_openings row until
// someone opens it, so this is naturally enforced fresh every day
// without any separate "reset" step.
export async function requireDayOpen() {
  const open = await isTodayOpen();
  if (!open) {
    return { error: "Today's cash day hasn't been opened yet. Go to Cash Management and open the day before collecting or refunding payments." };
  }
  return null;
}

PYEOF_6850943513789206473

cat > "app/(main)/cash-management/page.js" << 'PYEOF_3020872546832641573'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getTodayCollectionSummary,
  getReconciliationData,
  saveReconciliation,
  getCloseDayReadiness,
  closeDay,
  getDayClosingHistory,
  getDailyReport,
  reopenDay,
  isTodayClosed,
  getDayOpening,
  openDay,
} from './actions';
import { getApprovers } from '@/app/(main)/payments/actions';

const TABS = [
  { key: 'summary', label: "Today's Collection", icon: 'ti-chart-bar' },
  { key: 'reconciliation', label: 'Reconciliation', icon: 'ti-calculator' },
  { key: 'close', label: 'Close Day', icon: 'ti-lock' },
  { key: 'report', label: 'Daily Report', icon: 'ti-file-text' },
  { key: 'history', label: 'History', icon: 'ti-history' },
];

const VARIANCE_REASONS = ['Change given error', 'Denomination counting error', 'Uncounted change', 'Recording error', 'Other'];

function fmt(n) {
  return `Rs.${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function CashManagementPage() {
  const [activeTab, setActiveTab] = useState('summary');
  const [summary, setSummary] = useState({ transactions: [], byMode: {}, total: 0, count: 0 });
  const [reconRows, setReconRows] = useState([]);
  const [readiness, setReadiness] = useState(null);
  const [history, setHistory] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [closedToday, setClosedToday] = useState(false);
  const [opening, setOpening] = useState(null);
  const [openingBalance, setOpeningBalance] = useState('');
  const [openingRemarks, setOpeningRemarks] = useState('');
  const [todayClosingInfo, setTodayClosingInfo] = useState(null);

  const [reconEdits, setReconEdits] = useState({});
  const [reconApprover, setReconApprover] = useState('');
  const [closeNotes, setCloseNotes] = useState('');
  const [reportDate, setReportDate] = useState(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  const [report, setReport] = useState(null);
  const [reopenTarget, setReopenTarget] = useState(null);
  const [reopenReason, setReopenReason] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setSummary(await getTodayCollectionSummary());
    setReconRows(await getReconciliationData());
    setReadiness(await getCloseDayReadiness());
    setHistory(await getDayClosingHistory());
    const isClosed = await isTodayClosed();
    setClosedToday(isClosed);
    setOpening(await getDayOpening());
    if (isClosed) {
      const todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
      setTodayClosingInfo(await getDailyReport(todayStr));
    } else {
      setTodayClosingInfo(null);
    }
  }, []);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getApprovers().then(setApprovers); }, []);

  function updateReconField(mode, field, value) {
    setReconEdits((prev) => ({ ...prev, [mode]: { ...prev[mode], [field]: value } }));
  }

  async function handleSaveRecon(row) {
    setError(''); setSuccess('');
    const edit = reconEdits[row.mode] || {};
    const actual = edit.actual !== undefined ? parseFloat(edit.actual) : row.actual;
    const reason = edit.reason !== undefined ? edit.reason : row.reason;
    const variance = actual - row.expected;

    if (Math.abs(variance) > 0.01 && !reason) {
      setError(`A variance reason is required for ${row.mode} (variance: ${fmt(variance)}).`);
      return;
    }
    if (Math.abs(variance) > 0.01 && !reconApprover) {
      setError('Select a supervisor to approve this variance.');
      return;
    }

    const result = await saveReconciliation(row.mode, row.expected, actual, reason, Math.abs(variance) > 0.01 ? reconApprover : null);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${row.mode} reconciled.`);
    refresh();
  }

  async function handleOpenDay() {
    setError(''); setSuccess('');
    const result = await openDay(parseFloat(openingBalance) || 0, openingRemarks);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day opened.');
    setOpeningBalance(''); setOpeningRemarks('');
    refresh();
  }

  async function handleCloseDay() {
    setError(''); setSuccess('');
    if (!readiness?.reconciliationComplete) { setError('Complete reconciliation for every payment mode before closing.'); return; }
    setLoading(true);
    const result = await closeDay(closeNotes);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setSuccess('Day closed successfully. Daily report generated.');
    refresh();
    setActiveTab('report');
    loadReport(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  }

  async function loadReport(date) {
    setReport(await getDailyReport(date));
  }

  useEffect(() => { if (activeTab === 'report') loadReport(reportDate); }, [activeTab, reportDate]);

  async function handleReopen() {
    if (!reopenReason.trim()) { setError('A reason is required to reopen.'); return; }
    setError('');
    const result = await reopenDay(reopenTarget, reopenReason);
    if (result.error) { setError(result.error); return; }
    setSuccess(`${reopenTarget} reopened.`);
    setReopenTarget(null);
    setReopenReason('');
    refresh();
  }

  return (
    <div>
      <div style={{ borderRadius: 12, padding: '14px 18px', marginBottom: 16, color: '#fff', background: closedToday ? 'linear-gradient(135deg,#303a42,#1c242b)' : opening ? 'linear-gradient(135deg,#166534,#157a4f)' : 'linear-gradient(135deg,#92400e,#a15c00)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 10, height: 10, borderRadius: '50%', background: closedToday ? '#97a0aa' : opening ? '#4ade80' : '#fbbf24', boxShadow: closedToday ? 'none' : `0 0 8px ${opening ? '#4ade80' : '#fbbf24'}` }}></div>
          <div>
            <div style={{ fontWeight: 700 }}>
              {closedToday ? `Closed at ${new Date(todayClosingInfo?.closing?.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : opening ? `Opened at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} by ${opening.profiles?.full_name || '--'}` : 'Day not opened yet'}
            </div>
            <div style={{ fontSize: 12, opacity: .85 }}>{new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'long', day: 'numeric', month: 'long', year: 'numeric' })}</div>
          </div>
          <div style={{ marginLeft: 'auto', fontSize: 13 }}>{fmt(summary.total)} collected today ({summary.count} transactions)</div>
        </div>
        {!opening && !closedToday && (
          <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid rgba(255,255,255,.25)', display: 'flex', gap: 8, alignItems: 'flex-end', flexWrap: 'wrap' }}>
            <div>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Opening cash balance (Rs.)</label>
              <input type="number" value={openingBalance} onChange={(e) => setOpeningBalance(e.target.value)} placeholder="0.00" style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: 140 }} />
            </div>
            <div style={{ flex: 1, minWidth: 160 }}>
              <label style={{ fontSize: 10, opacity: .85, display: 'block', marginBottom: 3 }}>Remarks</label>
              <input value={openingRemarks} onChange={(e) => setOpeningRemarks(e.target.value)} placeholder="Optional..." style={{ padding: '6px 10px', borderRadius: 6, border: 'none', width: '100%' }} />
            </div>
            <button className="btn" style={{ background: '#fff', color: 'var(--amber)', fontWeight: 700 }} onClick={handleOpenDay}>
              <i className="ti ti-unlock"></i> Open Day
            </button>
          </div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <button key={t.key} className={activeTab === t.key ? 'btn btn-primary' : 'btn'} onClick={() => { setActiveTab(t.key); setError(''); setSuccess(''); }}>
            <i className={`ti ${t.icon}`}></i> {t.label}
          </button>
        ))}
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      {activeTab === 'summary' && (
        <div>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 16 }}>
            <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Collected</div>
              <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.total)}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{summary.count} transactions</div>
            </div>
            {['Cash', 'UPI', 'Card'].map((m) => (
              <div key={m} className="card" style={{ borderTop: '3px solid var(--blue)' }}>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{m}</div>
                <div style={{ fontSize: 22, fontWeight: 800, marginTop: 6 }}>{fmt(summary.byMode[m] || 0)}</div>
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Transactions Today</div>
            <table className="tbl">
              <thead><tr><th>Receipt #</th><th>Time</th><th>Patient</th><th>Mode(s)</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {summary.transactions.map((p) => (
                  <tr key={p.id}>
                    <td style={{ fontFamily: 'monospace' }}>{p.receipt_number}</td>
                    <td>{new Date(p.collected_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td>{p.patients?.first_name} {p.patients?.last_name}</td>
                    <td>{(p.payment_modes || []).map((m) => m.mode).join('+')}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: p.payment_type === 'refund' ? 'var(--red)' : 'var(--g800)' }}>
                      {p.payment_type === 'refund' ? '-' : ''}{fmt(p.total_amount)}
                    </td>
                  </tr>
                ))}
                {summary.transactions.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet today.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>
      )}

      {activeTab === 'reconciliation' && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-calculator" style={{ color: 'var(--amber)' }}></i> Cash Reconciliation</div>
          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14 }}>
            <i className="ti ti-info-circle"></i> Enter the actual counted amount for each mode. The system computes variance automatically -- a reason and supervisor approval are required whenever actual differs from expected.
          </div>
          {closedToday && (
            <div className="msg-err" style={{ marginBottom: 14 }}><i className="ti ti-lock"></i> Today is already closed -- reconciliation is read-only.</div>
          )}

          <div style={{ display: 'flex', padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, marginBottom: 6, fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
            <span style={{ minWidth: 140 }}>Mode</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Expected</span>
            <span style={{ flex: 1, textAlign: 'center' }}>Actual</span>
            <span style={{ minWidth: 130, textAlign: 'right' }}>Variance</span>
            <span style={{ minWidth: 90 }}></span>
          </div>

          {reconRows.map((row) => {
            const editedActual = reconEdits[row.mode]?.actual !== undefined ? reconEdits[row.mode].actual : row.actual;
            const variance = parseFloat(editedActual || 0) - row.expected;
            const hasVariance = Math.abs(variance) > 0.01;
            return (
              <div key={row.mode} style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', background: hasVariance ? 'var(--amber-lt)' : 'transparent', borderRadius: 8, marginBottom: 6 }}>
                <div style={{ display: 'flex', alignItems: 'center' }}>
                  <span style={{ minWidth: 140, fontWeight: 600, fontSize: 13 }}>{row.mode}</span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: 'var(--green)' }}>{fmt(row.expected)}</span>
                  <span style={{ flex: 1, textAlign: 'center' }}>
                    <input type="number" className="fi fi-sm" style={{ maxWidth: 140, textAlign: 'right', display: 'inline-block' }} value={editedActual} disabled={closedToday}
                      onChange={(e) => updateReconField(row.mode, 'actual', e.target.value)} />
                  </span>
                  <span style={{ minWidth: 130, textAlign: 'right', fontWeight: 700, color: hasVariance ? 'var(--red)' : 'var(--g400)' }}>
                    {hasVariance ? (variance > 0 ? '+' : '') + fmt(variance) : fmt(0)}
                  </span>
                  <span style={{ minWidth: 90, textAlign: 'right' }}>
                    {!closedToday && <button className="btn btn-sm btn-primary" onClick={() => handleSaveRecon(row)}>Save</button>}
                    {row.saved && <span className="badge b-green" style={{ marginLeft: 6 }}>Saved</span>}
                  </span>
                </div>
                {hasVariance && !closedToday && (
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginTop: 8 }}>
                    <select className="fi fi-sm" value={reconEdits[row.mode]?.reason !== undefined ? reconEdits[row.mode].reason : row.reason} onChange={(e) => updateReconField(row.mode, 'reason', e.target.value)}>
                      <option value="">-- Variance reason --</option>
                      {VARIANCE_REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                    </select>
                    <select className="fi fi-sm" value={reconApprover} onChange={(e) => setReconApprover(e.target.value)}>
                      <option value="">-- Approved by --</option>
                      {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                    </select>
                  </div>
                )}
              </div>
            );
          })}
          {reconRows.length === 0 && <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No collections yet today -- nothing to reconcile.</div>}
        </div>
      )}

      {activeTab === 'close' && (
        <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-lock" style={{ color: 'var(--red)' }}></i> Close Day</div>
            {closedToday ? (
              <div className="msg-success"><i className="ti ti-circle-check"></i> Today is already closed. See the Daily Report tab.</div>
            ) : (
              <>
                <div className="msg-err" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', border: 'none' }}>
                  <i className="ti ti-alert-triangle"></i> Once closed, no new visits, invoices, or payments can be created for today until it's reopened.
                </div>
                <label className="flbl">Closing notes</label>
                <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={closeNotes} onChange={(e) => setCloseNotes(e.target.value)} placeholder="Optional..." />
                <button className="btn btn-danger" onClick={handleCloseDay} disabled={loading || !readiness?.reconciliationComplete}>
                  <i className="ti ti-lock"></i> {loading ? 'Closing...' : 'Close Day and Generate Report'}
                </button>
              </>
            )}
          </div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-checklist" style={{ color: 'var(--green)' }}></i> Pre-close Checklist</div>
            <div style={{ fontSize: 13, lineHeight: 2.2 }}>
              <div><i className={`ti ${opening ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: opening ? 'var(--green)' : 'var(--amber)', marginRight: 6 }}></i>
                Day opened{opening ? ` at ${new Date(opening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : ' -- required before any payment can be collected today'}
              </div>
              <div><i className={`ti ${readiness?.reconciliationComplete ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: readiness?.reconciliationComplete ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Reconciliation complete for all payment modes
              </div>
              <div><i className={`ti ${!closedToday ? 'ti-circle-check' : 'ti-circle-x'}`} style={{ color: !closedToday ? 'var(--green)' : 'var(--red)', marginRight: 6 }}></i>
                Day not already closed
              </div>
            </div>
          </div>
        </div>
      )}

      {activeTab === 'report' && (
        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <label className="flbl">Report date</label>
            <input type="date" className="fi" style={{ maxWidth: 200 }} value={reportDate} onChange={(e) => setReportDate(e.target.value)} />
          </div>
          {!report?.closing ? (
            <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No closed day on record for this date.</div>
          ) : (
            <>
              <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#1e4e8c)', color: '#fff', borderRadius: 12, padding: '20px 24px', marginBottom: 16 }}>
                <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA EYE HOSPITAL</div>
                <div style={{ fontSize: 12, opacity: .8 }}>Haridwar, Uttarakhand</div>
                <div style={{ fontSize: 13, fontWeight: 700, marginTop: 10, borderTop: '1px solid rgba(255,255,255,.2)', paddingTop: 10 }}>
                  DAILY CASH CLOSING REPORT<br />
                  Date: {report.closing.closing_date}<br />
                  Closed by: {report.closing.profiles?.full_name || '--'} at {new Date(report.closing.closed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata' })}
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}>Reconciliation Summary</div>
                  {report.reconciliation.map((r) => (
                    <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>{r.mode}</span>
                      <span style={{ fontWeight: 600, color: Math.abs(r.variance) > 0.01 ? 'var(--red)' : 'var(--green)' }}>
                        {fmt(r.actual)}{Math.abs(r.variance) > 0.01 ? ` (var: ${r.variance > 0 ? '+' : ''}${fmt(r.variance)})` : ''}
                      </span>
                    </div>
                  ))}
                </div>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}>Day Totals</div>
                  <div style={{ fontSize: 13, lineHeight: 2 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total Revenue (billed)</span><strong>{fmt(report.closing.total_revenue)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total Collected</span><strong style={{ color: 'var(--green)' }}>{fmt(report.closing.total_collected)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Outstanding</span><strong style={{ color: 'var(--amber)' }}>{fmt(report.closing.total_outstanding)}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices</span><strong>{report.closing.total_invoices}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visits</span><strong>{report.closing.total_visits}</strong></div>
                  </div>
                </div>
              </div>
            </>
          )}
        </div>
      )}

      {activeTab === 'history' && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Closing History</div>
          <table className="tbl">
            <thead><tr><th>Date</th><th>Closed By</th><th>Revenue</th><th>Collected</th><th>Outstanding</th><th></th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td style={{ fontFamily: 'monospace' }}>{h.closing_date}</td>
                  <td>{h.profiles?.full_name || '--'}</td>
                  <td>{fmt(h.total_revenue)}</td>
                  <td>{fmt(h.total_collected)}</td>
                  <td>{fmt(h.total_outstanding)}</td>
                  <td>
                    {reopenTarget === h.closing_date ? (
                      <div style={{ display: 'flex', gap: 4 }}>
                        <input className="fi fi-sm" placeholder="Reason" value={reopenReason} onChange={(e) => setReopenReason(e.target.value)} style={{ width: 140 }} />
                        <button className="btn btn-sm btn-danger" onClick={handleReopen}>Confirm</button>
                        <button className="btn btn-sm" onClick={() => setReopenTarget(null)}>Cancel</button>
                      </div>
                    ) : (
                      <button className="btn btn-sm" onClick={() => { setReopenTarget(h.closing_date); setReopenReason(''); }}>
                        <i className="ti ti-lock-open"></i> Reopen
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {history.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No closed days yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

PYEOF_3020872546832641573

cat > "app/(main)/counselling/page.js" << 'PYEOF_2298550848061176493'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getCounsellingCases, getCounsellingHistory, getPackagesForCase, selectPackage, changePackage,
  setDecision, getCaseNotes, addCaseNote, getCounsellingItems, toggleCounsellingItem,
  markReadyForScheduling, referBackToDoctor,
  referForMedicalFitness,
  sendForBiometry, skipBiometry, unskipBiometry,
  getSurgeons, getOTAvailability, bookOTSlot, getOTSchedule, completeOT,
} from './actions';

// Biometry is satisfied either by actually being done, or by having
// been explicitly marked not required for this case (retina, glaucoma,
// oculoplasty...). Every gate that used to check biometry_done alone
// now goes through this.
function biometrySatisfied(sc) {
  return sc.biometry_done || sc.biometry_required === false;
}

function fitnessSatisfied(sc) {
  return sc.fitness_cleared || sc.fitness_required === false;
}

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function readiness(sc) {
  const items = [
    { key: 'surgeryRec', label: 'Surgery Recommended', done: true },
    { key: 'biometry', label: sc.biometry_required === false ? 'Biometry & IOL Type Advised (M23) -- Skipped' : 'Biometry & IOL Type Advised (M23)', done: biometrySatisfied(sc) },
    { key: 'fitness', label: sc.fitness_required === false ? 'Medical Fitness -- Not Required' : 'Medical Fitness', done: fitnessSatisfied(sc) },
    { key: 'advance', label: 'Advance Payment', done: !!sc.advance_payment_id },
  ];
  const done = items.filter((i) => i.done).length;
  return { items, pct: Math.round((done / items.length) * 100) };
}

function PackagePicker({ sc, onUpdate }) {
  const [packages, setPackages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!biometrySatisfied(sc)) { setLoading(false); return; }
    getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoading(false); });
  }, [sc.biometry_done, sc.biometry_required, sc.iol_category]);

  if (!biometrySatisfied(sc)) {
    return (
      <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 12.5, background: 'var(--g50)', borderRadius: 'var(--r)' }}>
        <i className="ti ti-lock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }}></i>
        Complete Biometry &amp; IOL type advice (M23) before presenting packages.
      </div>
    );
  }

  if (sc.master_packages) {
    return (
      <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{sc.master_packages.name}</div>
          <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 14 }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</div>
        </div>
        {sc.package_locked && (
          <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 6 }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</div>
        )}
        {error && <div className="msg-err" style={{ marginTop: 8 }}>{error}</div>}
        <button
          className="btn btn-sm"
          style={{ marginTop: 8 }}
          onClick={async () => {
            setError('');
            let reason = null;
            if (sc.package_locked) {
              reason = window.prompt(`Package is locked (currently "${sc.master_packages.name}"). Enter a reason to change it:`);
              if (reason === null) return;
              if (!reason.trim()) { setError('A reason is required to change a locked package.'); return; }
            }
            const result = await changePackage(sc.id, reason);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
        >
          Change package
        </button>
      </div>
    );
  }

  if (loading) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
        Showing packages for IOL type: <strong>{sc.iol_category}</strong> (from Master Data)
      </div>
      {packages.length === 0 && (
        <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)' }}>
          No packages found for IOL type "{sc.iol_category}" in Master Data. Add one under Financial Masters &gt; Packages.
        </div>
      )}
      {packages.map((p) => (
        <button
          key={p.id}
          onClick={async () => {
            setError('');
            const result = await selectPackage(sc.id, p.id);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
          style={{ display: 'block', width: '100%', textAlign: 'left', border: '1.5px solid var(--g200)', borderRadius: 'var(--r)', padding: 12, marginBottom: 8, background: '#fff', cursor: 'pointer', fontFamily: 'inherit' }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
              {p.name}
              {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{p.origin}</span>}
            </div>
            <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(p.price).toLocaleString('en-IN')}</div>
          </div>
          {p.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{p.includes}</div>}
        </button>
      ))}
    </div>
  );
}

function EducationPanel({ encounterId }) {
  const [items, setItems] = useState([]);

  const refresh = useCallback(() => {
    getCounsellingItems(encounterId).then(setItems);
  }, [encounterId]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-book" style={{ color: 'var(--teal)' }}></i> Patient education</div></div>
      {items.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No education topics logged from the doctor's plan.</div>}
      {items.map((item) => (
        <button
          key={item.id}
          onClick={async () => { await toggleCounsellingItem(item.id, item.status !== 'Done'); refresh(); }}
          style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', padding: '6px 4px', background: 'none', border: 'none', cursor: 'pointer', fontFamily: 'inherit', fontSize: 12.5 }}
        >
          <span style={{
            width: 16, height: 16, borderRadius: 4, border: '1.5px solid var(--g300)',
            background: item.status === 'Done' ? 'var(--teal)' : '#fff', borderColor: item.status === 'Done' ? 'var(--teal)' : 'var(--g300)',
            color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, flexShrink: 0,
          }}>
            {item.status === 'Done' ? '✓' : ''}
          </span>
          {item.topic}
        </button>
      ))}
    </div>
  );
}

function NotesPanel({ caseId }) {
  const [notes, setNotes] = useState([]);
  const [text, setText] = useState('');

  const refresh = useCallback(() => { getCaseNotes(caseId).then(setNotes); }, [caseId]);
  useEffect(() => { refresh(); }, [refresh]);

  async function handleSave() {
    if (!text.trim()) return;
    await addCaseNote(caseId, text);
    setText('');
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Counselling notes</div></div>
      <textarea className="fi" rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="e.g. Patient wants surgery after 1 week..." />
      <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSave}>Save note</button>
      <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
        {notes.map((n) => (
          <div key={n.id} style={{ fontSize: 11, background: 'var(--g50)', borderRadius: 'var(--r)', padding: '6px 8px' }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} -- {n.profiles?.full_name || 'Staff'}: </span>
            {n.note}
          </div>
        ))}
      </div>
    </div>
  );
}

// Numbered, collapsible section -- same visual pattern as AsmtSection in
// Optometry History ([assessmentId]/assessment-viewer.js): numbered
// colored circle, title, chevron toggle.
function CounsellingSection({ num, color, title, badge, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {badge}
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

// ── Book Surgery Slot -- last step of Counselling, replaces the old
//    standalone OT Scheduling module. Picking a date loads that date's OT
//    sessions (Morning/Midday/Afternoon etc, from Financial Masters) with
//    live booked/remaining counts so the counsellor books strictly within
//    capacity. ──
function BookSurgerySlot({ sc, onUpdate }) {
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [notes, setNotes] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [booking, setBooking] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleBook() {
    setError('');
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setBooking(true);
    const result = await bookOTSlot(sc.id, date, sessionId, surgeonId, notes);
    setBooking(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 10 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">-- Surgeon --</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Surgery Date</label>
          <input type="date" className="fi" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
      </div>

      {date && (
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      borderColor: selected ? 'transparent' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}
                    </div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      <input className="fi" placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} style={{ marginBottom: 10 }} />

      <button className="btn btn-primary btn-sm" onClick={handleBook} disabled={booking || !date || !sessionId}>
        {booking ? 'Booking...' : 'Confirm Surgery Slot'}
      </button>
    </div>
  );
}

function CaseWorkspace({ sc, onUpdate }) {
  const [error, setError] = useState('');
  const [ancillaryMsg, setAncillaryMsg] = useState(null); // { type: 'error'|'success', text }
  const [sendingBiometry, setSendingBiometry] = useState(false);
  const [openSections, setOpenSections] = useState({ surgery: true, biometry: true, decision: true, fitness: true });
  const { items, pct } = readiness(sc);
  const stage2Unlocked = !!sc.package_id && sc.decision === 'Accepted';
  const [referringFitness, setReferringFitness] = useState(false);

  async function handleReferFitness() {
    setError('');
    setReferringFitness(true);
    const result = await referForMedicalFitness(sc.id);
    setReferringFitness(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleDecision(d) {
    setError('');
    let reason = null;
    if (sc.decision_locked && d !== sc.decision) {
      reason = window.prompt(`Decision is locked (currently "${sc.decision}"). Enter a reason to change it to "${d}":`);
      if (reason === null) return; // cancelled
      if (!reason.trim()) { setError('A reason is required to change a locked decision.'); return; }
    }
    const result = await setDecision(sc.id, d, reason);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleSendForBiometry() {
    setAncillaryMsg(null);
    setSendingBiometry(true);
    const result = await sendForBiometry(sc.id);
    setSendingBiometry(false);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    setAncillaryMsg({ type: 'success', text: 'Sent -- patient will show as Awaiting Biometry in the Biometry queue.' });
    onUpdate();
  }

  async function handleSkipBiometry() {
    const reason = window.prompt('Why is Biometry not required for this case? (e.g. Retina surgery -- no IOL power needed)');
    if (reason === null) return;
    setAncillaryMsg(null);
    const result = await skipBiometry(sc.id, reason);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  async function handleUnskipBiometry() {
    setAncillaryMsg(null);
    const result = await unskipBiometry(sc.id);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  const advancePaid = !!sc.advance_payment_id;
  const fitnessItem = items.find((i) => i.key === 'fitness');

  return (
    <div style={{ marginBottom: 16 }}>
      {/* PATIENT STRIP -- fixed at top of the workspace, same visual language as Optometry History */}
      <div style={{
        position: 'sticky', top: 0, zIndex: 5,
        background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '12px 16px', color: '#fff',
        marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14,
      }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {sc.patients?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{sc.patients?.first_name} {sc.patients?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{sc.patients?.age} -- {sc.patients?.gender} -- {sc.patients?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.procedure_name} -- {sc.eye}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.priority}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.profiles?.full_name || 'Unassigned surgeon'}
            </span>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>IOL Type Advised</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc.iol_category || (sc.biometry_required === false ? 'Not applicable' : 'Pending biometry')}</div>
          <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`} style={{ marginTop: 4 }}>{sc.status}</span>
          <div style={{ fontSize: 10, opacity: .7, marginTop: 4 }}>{pct}% ready</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {/* 1. SURGERY ADVISED */}
      <CounsellingSection num={1} color="var(--g500)" title="Surgery Advised" open={openSections.surgery} onToggle={() => toggleSection('surgery')}
        badge={<span className="badge b-green"><i className="ti ti-check"></i> Done</span>}>
        <div style={{ fontSize: 12.5, color: 'var(--g600)' }}>
          <div><strong>{sc.procedure_name}</strong> -- {sc.eye} -- {sc.priority}</div>
          <div style={{ color: 'var(--g500)', marginTop: 4 }}>Surgeon: {sc.profiles?.full_name || 'Unassigned'}</div>
        </div>
      </CounsellingSection>

      {/* 2. BIOMETRY */}
      <CounsellingSection num={2} color="var(--blue)" title="Biometry" open={openSections.biometry} onToggle={() => toggleSection('biometry')}
        badge={
          sc.biometry_done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : sc.biometry_required === false
            ? <span className="badge b-purple">Not Required</span>
            : sc.biometry_record
            ? <span className="badge b-blue">Awaiting Technician</span>
            : <span className="badge b-amber">Not sent</span>
        }>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {sc.biometry_done ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Biometry Complete -- {sc.iol_category}</span>
          ) : sc.biometry_required === false ? (
            <>
              <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required -- {sc.biometry_skip_reason}</span>
              <button className="btn btn-sm" onClick={handleUnskipBiometry} style={{ fontSize: 11 }}>Undo -- make required again</button>
            </>
          ) : sc.biometry_record ? (
            <>
              <span className="badge b-blue"><i className="ti ti-clock"></i> Biometry Requested -- Awaiting Technician</span>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry} style={{ fontSize: 11 }}>
                {sendingBiometry ? 'Sending...' : 'Send again'}
              </button>
            </>
          ) : (
            <>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry}>
                <i className="ti ti-ruler-measure"></i> {sendingBiometry ? 'Sending...' : 'Send for Biometry'}
              </button>
              <button className="btn btn-sm" onClick={handleSkipBiometry} style={{ fontSize: 11 }}>
                <i className="ti ti-player-skip-forward"></i> Not required for this surgery
              </button>
            </>
          )}
          {ancillaryMsg && (
            <span style={{ fontSize: 11.5, color: ancillaryMsg.type === 'error' ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>
              {ancillaryMsg.text}
            </span>
          )}
        </div>
      </CounsellingSection>

      {/* 3. PATIENT DECISION -- package + decision, with Advance Payment as a sub-point */}
      <CounsellingSection num={3} color="var(--purple)" title="Patient Decision" open={openSections.decision} onToggle={() => toggleSection('decision')}
        badge={
          sc.decision === 'Accepted'
            ? <span className="badge b-green"><i className="ti ti-check"></i> Accepted</span>
            : sc.decision
            ? <span className="badge b-amber">{sc.decision}</span>
            : <span className="badge b-gray">Pending</span>
        }>
        <div style={{ marginBottom: 16 }}>
          <label className="flbl">Package</label>
          <PackagePicker sc={sc} onUpdate={onUpdate} />
        </div>

        <div style={{ marginBottom: 16 }}>
          <label className="flbl">
            Decision {sc.decision_locked && <span style={{ color: 'var(--amber)', fontWeight: 400, textTransform: 'none' }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</span>}
          </label>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {DECISIONS.map((d) => (
              <button
                key={d}
                onClick={() => handleDecision(d)}
                className="btn btn-sm"
                style={sc.decision === d ? {
                  background: d === 'Accepted' ? 'var(--green)' : d === 'Declined' ? 'var(--red)' : 'var(--purple)',
                  color: '#fff', borderColor: 'transparent',
                } : {}}
              >
                {d}
              </button>
            ))}
          </div>
        </div>

        {/* Sub-point: Advance Payment */}
        <div style={{ borderLeft: '3px solid var(--g200)', paddingLeft: 12, marginTop: 4 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 6 }}>
            3a. Advance Payment
          </div>
          {advancePaid ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Advance Paid</span>
          ) : (
            <span className="badge b-amber">Not yet collected -- via Billing (M11)</span>
          )}
        </div>
      </CounsellingSection>

      {/* 4. MEDICAL FITNESS */}
      <CounsellingSection num={4} color="var(--amber)" title="Medical Fitness" open={openSections.fitness} onToggle={() => toggleSection('fitness')}
        badge={
          fitnessItem?.done && sc.fitness_required === false
            ? <span className="badge b-purple">Not Required</span>
            : fitnessItem?.done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : <span className="badge b-amber">Pending</span>
        }>
        {!stage2Unlocked ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Locked until package confirmed and decision is Accepted.</div>
        ) : sc.fitness_required === false && !sc.fitness_referral ? (
          <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case -- per doctor's advice at consultation</span>
        ) : (
          <>
            {!sc.fitness_referral && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                  Refer this patient to a doctor to review clinical data, order any investigations needed, and clear for surgery.
                </div>
                <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                  <i className="ti ti-heart-rate-monitor"></i> {referringFitness ? 'Referring...' : 'Refer to Doctor'}
                </button>
              </div>
            )}
            {sc.fitness_referral?.status === 'Pending Review' && (
              <span className="badge b-amber"><i className="ti ti-clock"></i> Referred to doctor -- awaiting review ({new Date(sc.fitness_referral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })})</span>
            )}
            {sc.fitness_referral?.status === 'Cleared' && (
              <div>
                <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
              </div>
            )}
            {sc.fitness_referral?.status === 'Not Fit' && (
              <div>
                <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
                <div style={{ marginTop: 8 }}>
                  <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                    <i className="ti ti-refresh"></i> {referringFitness ? 'Referring...' : 'Refer Again'}
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </CounsellingSection>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <EducationPanel encounterId={sc.encounter_id} />
        <NotesPanel caseId={sc.id} />
      </div>

      {/* BOOK SURGERY SLOT -- only once Ready for Scheduling */}
      {sc.status === 'Ready for Scheduling' && (
        <CounsellingSection num="OT" color="var(--indigo)" title="Book Surgery Slot" open onToggle={() => {}}
          badge={<span className="badge b-green"><i className="ti ti-check"></i> Ready</span>}>
          <BookSurgerySlot sc={sc} onUpdate={onUpdate} />
        </CounsellingSection>
      )}

      {sc.status === 'Scheduled' && (
        <div className="msg-success" style={{ marginBottom: 16 }}>
          <i className="ti ti-circle-check"></i> Surgery slot booked -- see the OT Calendar tab.
        </div>
      )}

      <div style={{ display: 'flex', gap: 8 }}>
        <button
          className="btn btn-sm"
          onClick={async () => { await referBackToDoctor(sc.id); onUpdate(); }}
        >
          Refer back to doctor
        </button>
        {sc.status === 'Pending Workup' && (
          <button className="btn btn-primary btn-sm" onClick={handleReady}>Ready for Scheduling (VAL-SCC-002)</button>
        )}
      </div>
    </div>
  );
}

// ── Pre-op counselling stage, derived from real columns (not stored --
//    surgical_cases.status stays limited to Pending Workup / Ready for
//    Scheduling / Scheduled / Completed / Cancelled, since OT Scheduling
//    relies on those exact values). This just groups cases for the
//    dashboard so the counsellor can see where each patient actually is. ──
const STAGES = [
  { key: 'surgery_advised',     label: 'Surgery Advised',                badge: 'b-gray'   },
  { key: 'awaiting_biometry',   label: 'Awaiting Biometry',              badge: 'b-blue'   },
  { key: 'awaiting_package',    label: 'Awaiting Package Presentation',  badge: 'b-teal'   },
  { key: 'awaiting_decision',   label: 'Waiting for Patient Decision',   badge: 'b-amber'  },
  { key: 'financial_constraint',label: 'Financial Constraint',           badge: 'b-red'    },
  { key: 'finalised',           label: 'Finalised -- Prep Pending',      badge: 'b-purple' },
  { key: 'ready',               label: 'Ready for Scheduling',           badge: 'b-green'  },
  { key: 'declined',            label: 'Declined',                       badge: 'b-gray'   },
];
const STAGE_MAP = Object.fromEntries(STAGES.map((s) => [s.key, s]));

function getStage(sc) {
  if (sc.status === 'Ready for Scheduling') return 'ready';
  if (!sc.biometry_done && sc.biometry_required !== false) return sc.biometry_record ? 'awaiting_biometry' : 'surgery_advised';
  if (!sc.package_id) return 'awaiting_package';
  if (sc.decision === 'Declined') return 'declined';
  if (sc.decision === 'Financial Constraint') return 'financial_constraint';
  if (sc.decision === 'Accepted') return 'finalised';
  return 'awaiting_decision'; // null, Wants Time to Decide, Discuss with Family, Second Opinion, Other
}

function daysWaiting(sc) {
  return Math.floor((Date.now() - new Date(sc.created_at).getTime()) / 86400000);
}

function KpiCard({ label, value, sub, color, active, onClick }) {
  return (
    <button
      onClick={onClick}
      className="card"
      style={{ borderLeft: `3px solid ${color}`, marginBottom: 0, textAlign: 'left', cursor: 'pointer', background: active ? 'var(--g50)' : '#fff', fontFamily: 'inherit' }}
    >
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </button>
  );
}

function CounsellingDashboard({ cases, onOpen }) {
  const [stageFilter, setStageFilter] = useState('');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  const counts = STAGES.reduce((acc, s) => { acc[s.key] = 0; return acc; }, {});
  cases.forEach((sc) => { counts[getStage(sc)]++; });

  let rows = cases.map((sc) => ({ sc, stage: getStage(sc) }));
  if (stageFilter) rows = rows.filter((r) => r.stage === stageFilter);
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter(({ sc }) =>
      `${sc.patients?.first_name} ${sc.patients?.last_name}`.toLowerCase().includes(q) ||
      (sc.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  rows.sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.sc.created_at) - new Date(b.sc.created_at);
    if (sortBy === 'newest') return new Date(b.sc.created_at) - new Date(a.sc.created_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.sc.priority] ?? 9) - (order[b.sc.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
        <KpiCard label="Active cases" value={cases.filter((sc) => sc.status !== 'Ready for Scheduling').length + counts.ready} sub="All pre-op stages" color="var(--indigo)" active={!stageFilter} onClick={() => setStageFilter('')} />
        <KpiCard label="Waiting on patient" value={counts.awaiting_decision + counts.financial_constraint} sub="Decision or finance pending" color="var(--amber)" active={stageFilter === 'awaiting_decision'} onClick={() => setStageFilter('awaiting_decision')} />
        <KpiCard label="Finalised -- prep pending" value={counts.finalised} sub="Accepted, tests/fitness pending" color="var(--purple)" active={stageFilter === 'finalised'} onClick={() => setStageFilter('finalised')} />
        <KpiCard label="Ready for scheduling" value={counts.ready} sub="Go to OT Scheduling" color="var(--green)" active={stageFilter === 'ready'} onClick={() => setStageFilter('ready')} />
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Counselling Queue</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
            <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
              <option value="oldest">Oldest first</option>
              <option value="newest">Newest first</option>
              <option value="priority">Priority</option>
            </select>
          </div>
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
          <button className={`btn btn-sm ${!stageFilter ? 'btn-primary' : ''}`} onClick={() => setStageFilter('')}>All ({cases.length})</button>
          {STAGES.map((s) => (
            <button key={s.key} className={`btn btn-sm ${stageFilter === s.key ? 'btn-primary' : ''}`} onClick={() => setStageFilter(s.key)}>
              {s.label} ({counts[s.key]})
            </button>
          ))}
        </div>

        {rows.map(({ sc, stage }) => {
          const dw = daysWaiting(sc);
          return (
            <div key={sc.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--purple)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {sc.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</span>
                <span className={`badge ${STAGE_MAP[stage].badge}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_MAP[stage].label}</span>
                {sc.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{sc.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.iol_category || 'IOL type pending'} -- {sc.profiles?.full_name || 'Unassigned surgeon'}
                </div>
              </div>
              <div style={{ textAlign: 'right', fontSize: 10, color: dw > 7 ? 'var(--red)' : dw > 3 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                {dw === 0 ? 'Today' : `${dw}d waiting`}
              </div>
              <button className="btn btn-sm btn-primary" onClick={() => onOpen(sc.id)}>
                <i className="ti ti-arrow-right"></i> Open
              </button>
            </div>
          );
        })}

        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {cases.length === 0 ? 'No cases pending counselling. Mark a patient for surgery from their Consultation.' : 'No cases match this filter.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ── OT Calendar tab -- the read-only schedule + Complete action that used
//    to be the whole of the standalone OT Scheduling page. Booking itself
//    now happens inline in each case's workspace (BookSurgerySlot above). ──
function OTCalendar() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setSchedule(await getOTSchedule());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId) {
    await completeOT(otId, caseId);
    refresh();
  }

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading OT calendar...</div>;

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> OT Calendar
      </div>
      <table className="tbl">
        <thead>
          <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {schedule.map((s) => (
            <tr key={s.id}>
              <td>{new Date(s.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
              <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
              <td>{s.room || '--'}</td>
              <td>{s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}</td>
              <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
              <td>{s.profiles?.full_name || '--'}</td>
              <td><span className={`badge ${s.status === 'Completed' ? 'b-green' : 'b-blue'}`}>{s.status}</span></td>
              <td>
                {s.status === 'Scheduled' && (
                  <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id)}>Complete</button>
                )}
              </td>
            </tr>
          ))}
          {schedule.length === 0 && (
            <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

// ── History tab -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled, etc). Read-only lookup, same pattern as the
//    History tabs elsewhere in the app (Post-op, Investigation,
//    Optometry). Opens the same CaseWorkspace as an active case -- its
//    action buttons already only render for statuses that are still
//    actionable, so a past case naturally shows as read-only. ──
function HistoryTab({ cases, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? cases.filter((sc) => {
        const q = search.trim().toLowerCase();
        const p = sc.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : cases;

  const STATUS_BADGE = { Scheduled: 'b-blue', Completed: 'b-green', Cancelled: 'b-red' };

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Counselling History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Decision</th><th>Status</th><th>Date</th><th></th></tr></thead>
          <tbody>
            {filtered.map((sc) => (
              <tr key={sc.id} onClick={() => onOpen(sc.id)} style={{ cursor: 'pointer' }}>
                <td><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{sc.procedure_name} ({sc.eye})</td>
                <td style={{ fontSize: 12 }}>{sc.profiles?.full_name || '--'}</td>
                <td style={{ fontSize: 12 }}>{sc.decision || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[sc.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{sc.status}</span></td>
                <td style={{ fontSize: 11 }}>{sc.created_at ? new Date(sc.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No past cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function CounsellingPage() {
  const [cases, setCases] = useState([]);
  const [historyCases, setHistoryCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);

  const refresh = useCallback(async () => {
    setCases(await getCounsellingCases());
    setLoading(false);
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistoryCases(await getCounsellingHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refresh(); refreshHistory(); }, [refresh, refreshHistory]);

  function openCase(id) {
    setSelectedCaseId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refresh(); refreshHistory();
  }

  const selectedCase = cases.find((sc) => sc.id === selectedCaseId) || historyCases.find((sc) => sc.id === selectedCaseId) || null;

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading counselling cases...</div>;

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 540 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-messages" label="Workspace" disabled={!selectedCase} />
        <TabButton active={activeTab === 'otcalendar'} onClick={() => setActiveTab('otcalendar')} icon="ti-calendar-event" label="OT Calendar" />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <CounsellingDashboard cases={cases} onOpen={openCase} />}

      {activeTab === 'workspace' && selectedCase && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => setActiveTab('dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Dashboard
          </button>
          <CaseWorkspace sc={selectedCase} onUpdate={handleUpdate} />
        </div>
      )}

      {activeTab === 'workspace' && !selectedCase && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Dashboard tab.
        </div>
      )}

      {activeTab === 'otcalendar' && <OTCalendar />}

      {activeTab === 'history' && <HistoryTab cases={historyCases} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}

PYEOF_2298550848061176493

cat > "app/(main)/doctor-dashboard/page.js" << 'PYEOF_240250855942996371'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDoctorDashboardData, getDoctorHistory } from './actions';
import { doctorCallNext, doctorCallSpecific, doctorMarkReady, doctorCallDirect } from '@/app/(main)/queue/actions';
import PostOpWorkspace from '@/app/(main)/ot-postop/workspace';
import { getOpenPostOpEpisodeForPatient } from '@/app/(main)/ot-postop/actions';
import BiometryWorkspace from '@/app/(main)/biometry/[id]/workspace';
import { getBiometryApprovalsToday } from '@/app/(main)/biometry/actions';
import { WorkspaceTab as MedicalFitnessWorkspace } from '@/app/(main)/medical-fitness/page';
import { getMedicalFitnessToday } from '@/app/(main)/medical-fitness/actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

function TokenBadge({ token, color }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: color || 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

function VisitTypeBadge({ type }) {
  if (!type) return null;
  return (
    <span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})20`, color: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, marginLeft: 6, fontSize: 10 }}>
      {type}
    </span>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--blue)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ active, intermediate, completed, optometryWaiting, biometryApprovals, medicalFitnessToday, visitTypeCounts, totalVisitsToday, error, onRunAction, onOpen, onOpenBiometry, onOpenMedicalFitness }) {
  const inConsultation = active.find((e) => e.status === 'In Consultation');
  const waitingCount = active.filter((e) => e.status === 'Waiting' || e.status === 'Ready for Review').length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Consultation</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{inConsultation ? 1 : 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>With doctor now</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting for Doctor</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>In doctor queue</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Intermediate</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{intermediate.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Dilation / Investigation</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Completed Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{completed.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Encounters closed</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue<span className="badge b-gray">{active.length}</span></div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => onRunAction(doctorCallNext)} disabled={!!inConsultation}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {inConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={inConsultation.token} color="var(--blue)" />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(inConsultation)}</span>
                <VisitTypeBadge type={inConsultation.visits?.visit_type} />
              </div>
              <div style={{ marginBottom: 8 }}>
                <span className={`badge ${waitBadgeClass(elapsedMin(inConsultation.called_at || inConsultation.issued_at))}`}>
                  <i className="ti ti-clock"></i> In consultation {elapsedMin(inConsultation.called_at || inConsultation.issued_at)}m
                </span>
              </div>
              <button className="btn btn-primary btn-sm" onClick={() => onOpen(inConsultation)}>
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </button>
            </div>
          )}

          {active.filter((e) => e.id !== inConsultation?.id).map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} color={e.status === 'Ready for Review' ? 'var(--green)' : 'var(--amber)'} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                  <VisitTypeBadge type={e.visits?.visit_type} />
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Ready for Review' ? 'b-green' : 'b-amber'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}><i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallSpecific, e.id)} disabled={!!inConsultation}>Call</button>
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* INTERMEDIATE QUEUE -- side by side with Doctor Queue, not
            buried further down, since it's just as time-sensitive
            (patients sent out for Dilation/Investigation/Biometry who
            need to be pulled back in). */}
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> Intermediate Queue<span className="badge b-gray">{intermediate.length}</span></div>
          </div>
          {intermediate.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.status} -- {elapsedMin(e.sent_out_at)}m</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorMarkReady, e.id)}>Mark Ready</button>
            </div>
          ))}
          {intermediate.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              No one in Dilation, Investigation, or Biometry.
            </div>
          )}
        </div>
      </div>

      {/* Everything else -- side by side in pairs rather than one long
          vertical stack. */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* VISIT TYPE BREAKDOWN -- same widget as Front Office Dashboard */}
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
          </div>
          {Object.keys(visitTypeCounts || {}).length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
          )}
          {Object.entries(visitTypeCounts || {}).map(([type, count]) => (
            <div key={type} style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
              </div>
              <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                <div style={{
                  width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                  height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                }}></div>
              </div>
            </div>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Waiting in Optometry<span className="badge b-gray">{optometryWaiting.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Pull a patient straight into consultation without waiting for their optometry workup -- useful for quick reviews or referrals.
          </div>
          {optometryWaiting.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.issued_at)}m waiting in Optometry</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallDirect, e.id)} disabled={!!inConsultation}>
                <i className="ti ti-arrow-right"></i> Call Directly
              </button>
            </div>
          ))}
          {optometryWaiting.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No one currently waiting in Optometry.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry Approvals<span className="badge b-gray">{biometryApprovals.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's visits only. Only a doctor can approve.</div>
          {biometryApprovals.map((b) => (
            <div key={b.id} onClick={() => onOpenBiometry(b.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {b.visits?.patients?.first_name} {b.visits?.patients?.last_name}
                <span className="badge b-indigo" style={{ marginLeft: 6, fontSize: 10 }}>{b.surgical_eye}</span>
                <VisitTypeBadge type={b.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{b.visits?.patients?.uhid}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-shield-check"></i> Approve</button>
            </div>
          ))}
          {biometryApprovals.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing awaiting approval today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness<span className="badge b-gray">{medicalFitnessToday.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's referrals only.</div>
          {medicalFitnessToday.map((r) => (
            <div key={r.id} onClick={() => onOpenMedicalFitness(r.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {r.visits?.patients?.first_name} {r.visits?.patients?.last_name}
                <VisitTypeBadge type={r.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Review</button>
            </div>
          ))}
          {medicalFitnessToday.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today<span className="badge b-green">{completed.length}</span></div>
          </div>
          {completed.slice(0, 8).map((e) => (
            <div
              key={e.id}
              onClick={() => onOpen(e)}
              style={{ display: 'block', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span><span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span> {patientName(e)}<VisitTypeBadge type={e.visits?.visit_type} /></span>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                {e.completed_at ? new Date(e.completed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' }) : '--'}
              </div>
            </div>
          ))}
          {completed.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing completed yet today.</div>}
        </div>
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.visits?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Consultation History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Token</th><th>Patient</th><th>Visit Type</th><th>Completed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e)} style={{ cursor: 'pointer' }}>
                <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{e.token}</td>
                <td>
                  <strong>{patientName(e)}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 11 }}>{e.visits?.visit_type || '--'}</td>
                <td style={{ fontSize: 11 }}>{e.completed_at ? new Date(e.completed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed consultations found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorDashboardPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [postOpEpisodeId, setPostOpEpisodeId] = useState(null);
  const [biometryId, setBiometryId] = useState(null);
  const [medFitnessId, setMedFitnessId] = useState(null);
  const [active, setActive] = useState([]);
  const [intermediate, setIntermediate] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [optometryWaiting, setOptometryWaiting] = useState([]);
  const [biometryApprovals, setBiometryApprovals] = useState([]);
  const [medicalFitnessToday, setMedicalFitnessToday] = useState([]);
  const [visitTypeCounts, setVisitTypeCounts] = useState({});
  const [totalVisitsToday, setTotalVisitsToday] = useState(0);
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const result = await getDoctorDashboardData();
    setActive(result.active);
    setIntermediate(result.intermediate);
    setCompleted(result.completed);
    setOptometryWaiting(result.optometryWaiting);
    setVisitTypeCounts(result.visitTypeCounts);
    setTotalVisitsToday(result.totalVisitsToday);
    setBiometryApprovals(await getBiometryApprovalsToday());
    setMedicalFitnessToday(await getMedicalFitnessToday());
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistory(await getDoctorHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => {
    refresh();
    refreshHistory();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh, refreshHistory]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  async function openConsultation(entry) {
    if (entry.visits?.visit_type === 'Post-operative Review') {
      const episodeId = await getOpenPostOpEpisodeForPatient(entry.visits.patients.id);
      if (!episodeId) {
        setError('This is marked as a Post-operative Review visit, but no open post-op episode was found for this patient.');
        return;
      }
      setPostOpEpisodeId(episodeId);
      setBiometryId(null); setMedFitnessId(null);
      setActiveTab('workspace');
      return;
    }
    // Opens in its own window, which closes itself once the doctor
    // finishes this sitting (Save Draft / Send for Dilation / Send for
    // Investigation / Complete Encounter) -- see finishAndClose() in
    // consultation-form.js. Reuses the same window name so repeated
    // "Call" clicks don't spawn a pile of windows. Polls for the window
    // closing so the dashboard refreshes immediately rather than
    // waiting on the 15s interval.
    const win = window.open(`/consultation/${entry.id}`, 'doctor-consultation-window');
    if (win) {
      const poll = setInterval(() => {
        if (win.closed) { clearInterval(poll); refresh(); }
      }, 800);
    }
  }

  function openBiometry(id) {
    setPostOpEpisodeId(null); setMedFitnessId(null);
    setBiometryId(id);
    setActiveTab('workspace');
  }

  function openMedicalFitness(id) {
    setPostOpEpisodeId(null); setBiometryId(null);
    setMedFitnessId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh(); refreshHistory();
    setPostOpEpisodeId(null);
    setBiometryId(null);
    setMedFitnessId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      {activeTab !== 'workspace' && (
        <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-text" label="Workspace" disabled={!postOpEpisodeId && !biometryId && !medFitnessId} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
      )}

      {activeTab === 'dashboard' && (
        <DashboardTab
          active={active} intermediate={intermediate} completed={completed} optometryWaiting={optometryWaiting}
          biometryApprovals={biometryApprovals} medicalFitnessToday={medicalFitnessToday}
          visitTypeCounts={visitTypeCounts} totalVisitsToday={totalVisitsToday}
          error={error} onRunAction={runAction} onOpen={openConsultation}
          onOpenBiometry={openBiometry} onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'workspace' && postOpEpisodeId && (
        <PostOpWorkspace episodeId={postOpEpisodeId} onBack={handleBack} onUpdate={() => {}} />
      )}
      {activeTab === 'workspace' && biometryId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <BiometryWorkspace recordId={biometryId} />
        </div>
      )}
      {activeTab === 'workspace' && medFitnessId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <MedicalFitnessWorkspace referralId={medFitnessId} onDone={handleBack} />
        </div>
      )}
      {activeTab === 'workspace' && !postOpEpisodeId && !biometryId && !medFitnessId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard or History.</div>
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openConsultation} />}
    </div>
  );
}

PYEOF_240250855942996371

cat > "app/(main)/front-office-dashboard/page.js" << 'PYEOF_8507046871934059596'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';
import InvestigationsBillingWidget from './investigations-billing-widget';
import ProceduresBillingWidget from './procedures-billing-widget';
import PharmacyBillingWidget from './pharmacy-billing-widget';
import BiometryBillingWidget from './biometry-billing-widget';
import PackageBillingWidget from './package-billing-widget';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

function elapsedMin(iso) {
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

const APPT_STATUS_BADGE = { Booked: 'b-amber', 'Checked-in': 'b-green', Cancelled: 'b-red', 'No-show': 'b-gray' };

export default async function FrontOfficeDashboardPage({ searchParams }) {
  const params = await searchParams;
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: todaysRegistrations },
    { data: queueEntries },
    { count: walkInsToday },
    { data: pendingInvoices },
    { data: todaysVisits },
    { data: todaysAppointments },
    { count: surgicalPendingWorkup },
    dayOpen,
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('queue_entries').select('*, visits(patients(first_name, last_name))').neq('status', 'Done').order('issued_at', { ascending: true }),
    supabase.from('visits').select('*', { count: 'exact', head: true }).gte('created_at', today).is('appointment_id', null),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
    supabase.from('visits').select('*, patients(id, first_name, last_name, uhid), profiles!doctor_id(full_name)').gte('created_at', today).order('created_at', { ascending: false }),
    supabase.from('appointments').select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)').eq('appointment_date', today).order('appointment_time', { ascending: true }),
    supabase.from('surgical_cases').select('*', { count: 'exact', head: true }).eq('status', 'Pending Workup'),
    isTodayOpen(),
  ]);

  const waitingEntries = (queueEntries || []).filter((e) => e.status === 'Waiting');
  const avgWait = waitingEntries.length
    ? Math.round(waitingEntries.reduce((s, e) => s + elapsedMin(e.issued_at), 0) / waitingEntries.length)
    : 0;

  const outstandingTotal = (pendingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
  const unregisteredCount = (todaysAppointments || []).filter((a) => !a.patients).length;

  // Billing status per visit, batched in one query rather than per-row.
  // A visit can now have multiple invoices (Consultation, Investigation,
  // Pharmacy...) -- aggregate properly rather than keeping whichever one
  // happens to come back last from the query.
  const visitIds = (todaysVisits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, net, paid, status').in('visit_id', visitIds);
    const grouped = {};
    (invoices || []).forEach((inv) => {
      if (!grouped[inv.visit_id]) grouped[inv.visit_id] = [];
      grouped[inv.visit_id].push(inv);
    });
    Object.entries(grouped).forEach(([visitId, invs]) => {
      const active = invs.filter((i) => i.status !== 'Cancelled');
      const outstanding = active.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);
      const allPaid = active.length > 0 && active.every((i) => i.status === 'Paid');
      billingByVisit[visitId] = {
        count: active.length,
        outstanding,
        label: active.length === 0 ? '--' : allPaid ? 'Paid' : `Rs.${outstanding.toLocaleString('en-IN')} due`,
        badge: active.length === 0 ? 'b-gray' : allPaid ? 'b-green' : 'b-red',
      };
    });
  }

  const visitTypeCounts = {};
  (todaysVisits || []).forEach((v) => {
    visitTypeCounts[v.visit_type] = (visitTypeCounts[v.visit_type] || 0) + 1;
  });
  const totalVisitsToday = todaysVisits?.length || 0;

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> <strong>Today's cash day hasn't been opened.</strong> Payment collection is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day Now</Link>
        </div>
      )}
      {params?.registered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{params.registered}</strong>
        </div>
      )}
      {params?.visitCreated && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Visit created successfully.
        </div>
      )}
      {params?.linked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Patient registered and linked to their appointment.
        </div>
      )}
      {params?.booked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Appointment booked successfully.
        </div>
      )}

      {/* QUICK ACTIONS */}
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>
            Quick Actions
          </div>
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
              <i className="ti ti-user-plus"></i> New Registration
            </Link>
            <Link href="/appointments/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-calendar-plus"></i> Book Appointment
            </Link>
            <Link href="/visits/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-stethoscope"></i> New Visit
            </Link>
          </div>
        </div>
      </div>

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Visits</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{totalVisitsToday}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{todaysRegistrations ?? 0} new registrations</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Patients Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingEntries.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Avg wait: {avgWait} min</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{todaysAppointments?.length ?? 0}</div>
          {unregisteredCount > 0 && <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 2 }}>{unregisteredCount} not registered</div>}
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Billing Pending</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{pendingInvoices?.length ?? 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Rs.{outstandingTotal.toLocaleString('en-IN')} outstanding</div>
        </div>
      </div>

      {/* TODAY'S APPOINTMENTS */}
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--green)' }}></i> Today&apos;s Appointments
        </div>
        <table className="tbl">
          <thead><tr><th>Time</th><th>Patient</th><th>Mobile</th><th>Type</th><th>Doctor</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {(todaysAppointments || []).map((a) => {
              const isRegistered = !!a.patients;
              const name = isRegistered ? `${a.patients.first_name} ${a.patients.last_name}` : a.patient_name_temp;
              const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
              return (
                <tr key={a.id}>
                  <td style={{ fontWeight: 600 }}>{a.appointment_time?.slice(0, 5)}</td>
                  <td>{name}</td>
                  <td>{mobile}</td>
                  <td>{a.visit_type}</td>
                  <td>{a.profiles?.full_name || '--'}</td>
                  <td><span className={`badge ${APPT_STATUS_BADGE[a.status] || 'b-gray'}`}>{a.status}</span></td>
                  <td style={{ position: 'relative' }}>
                    {!isRegistered && <RegisterUnregisteredButton appointmentId={a.id} tempName={a.patient_name_temp} tempMobile={a.mobile_temp} />}
                    {isRegistered && a.status === 'Booked' && <CheckInButton appointmentId={a.id} />}
                    {isRegistered && a.status === 'Checked-in' && <span className="badge b-green">Registered</span>}
                  </td>
                </tr>
              );
            })}
            {(!todaysAppointments || todaysAppointments.length === 0) && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No appointments today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        {/* TODAY'S VISITS */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <table className="tbl">
            <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
            <tbody>
              {(todaysVisits || []).map((v) => {
                const billing = billingByVisit[v.id] || { count: 0, label: '--', badge: 'b-gray' };
                return (
                  <tr key={v.id}>
                    <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                    <td>{new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td>
                      <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                      <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                    </td>
                    <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                    <td>{v.profiles?.full_name || '--'}</td>
                    <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                    <td>
                      {billing.badge === 'b-red' && v.patients?.id ? (
                        <Link href={`/payments/collect?patientId=${v.patients.id}`} className="badge b-red" style={{ textDecoration: 'none', cursor: 'pointer' }}>
                          {billing.label}
                        </Link>
                      ) : (
                        <span className={`badge ${billing.badge}`}>{billing.label}</span>
                      )}
                      {billing.count > 1 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>({billing.count} invoices)</span>}
                    </td>
                    <td>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                          <i className="ti ti-receipt"></i> New Invoice
                        </Link>
                        {billing.count > 0 && (
                          <Link href={`/billing/cancel?visitId=${v.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                            <i className="ti ti-edit"></i> Modify
                          </Link>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {(!todaysVisits || todaysVisits.length === 0) && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div>
          <InvestigationsBillingWidget />
          <ProceduresBillingWidget />
          <PharmacyBillingWidget />
          <BiometryBillingWidget />
          <PackageBillingWidget />

          {/* VISIT TYPE BREAKDOWN */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
            </div>
            {Object.keys(visitTypeCounts).length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
            )}
            {Object.entries(visitTypeCounts).map(([type, count]) => (
              <div key={type} style={{ marginBottom: 8 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                  <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
                </div>
                <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                  <div style={{
                    width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                    height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                  }}></div>
                </div>
              </div>
            ))}
          </div>

          {/* PATIENTS WAITING NOW */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-list-numbers" style={{ color: 'var(--amber)' }}></i> Patients Waiting Now
            </div>
            {(queueEntries || []).slice(0, 5).map((e) => (
              <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                  {e.visits?.patients?.first_name} {e.visits?.patients?.last_name}
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.department} -- {elapsedMin(e.issued_at)} min</div>
                </div>
                <span className={`badge ${e.status === 'Calling' || e.status === 'In Consultation' ? 'b-blue' : 'b-amber'}`}>{e.status}</span>
              </div>
            ))}
            {(!queueEntries || queueEntries.length === 0) && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Queue is empty.</div>
            )}
          </div>

          {/* PENDING ACTIONS */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-circle" style={{ color: 'var(--red)' }}></i> Pending Actions
            </div>
            {(pendingInvoices?.length ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{pendingInvoices.length} invoices -- payment pending</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>Total: Rs.{outstandingTotal.toLocaleString('en-IN')}</div>
                </div>
              </div>
            )}
            {unregisteredCount > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-user-plus" style={{ color: 'var(--amber)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{unregisteredCount} appointments not yet registered</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>See Today&apos;s Appointments above</div>
                </div>
              </div>
            )}
            {(surgicalPendingWorkup ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0' }}>
                <i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{surgicalPendingWorkup} surgical cases pending workup</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    <Link href="/counselling" style={{ color: 'var(--blue)' }}>Go to Counselling</Link>
                  </div>
                </div>
              </div>
            )}
            {!(pendingInvoices?.length) && !unregisteredCount && !surgicalPendingWorkup && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all caught up.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}



PYEOF_8507046871934059596

cat > "app/(main)/investigation/[id]/workspace.js" << 'PYEOF_402896797764231868'
'use client';

import { useState, useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  getInvestigationDetail, saveInvestigationDraft,
  completeInvestigation, verifyInvestigation, markUnableToPerform,
} from '../actions';

// Maps a doctor's free-text investigation name to the closest workspace
// template -- same heuristic as the prototype's matchInvestigationType,
// with External Report as the generic fallback for anything unrecognised
// (e.g. external lab reports, blood work).
function matchInvestigationType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) {
    return {
      type: 'OCT', icon: 'ti-eye',
      fields: [
        { lbl: 'Central Macular Thickness (OD)', id: 'cmt-re', placeholder: 'e.g. 245 um' },
        { lbl: 'RNFL Thickness', id: 'rnfl', placeholder: 'e.g. Average 85 um' },
        { lbl: 'Signal Strength', id: 'signal', placeholder: 'e.g. 8/10' },
        { lbl: 'GCC', id: 'gcc', placeholder: 'Optional' },
      ],
      note: 'Clinical interpretation reserved for Ophthalmologist. Enter measurements only.',
      verifyItems: ['Scan quality acceptable', 'Central macula imaged', 'Both eyes captured if bilateral', 'Signal strength >= 6'],
    };
  }
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) {
    return {
      type: 'Visual Field', icon: 'ti-activity',
      fields: [
        { lbl: 'Test strategy', id: 'vf-strategy', placeholder: 'e.g. SITA Standard 24-2' },
        { lbl: 'MD (RE)', id: 'md-re', placeholder: 'e.g. -6.2 dB' },
        { lbl: 'PSD (RE)', id: 'psd-re', placeholder: 'e.g. 5.1 dB' },
        { lbl: 'MD (LE)', id: 'md-le', placeholder: 'e.g. -4.1 dB' },
        { lbl: 'PSD (LE)', id: 'psd-le', placeholder: 'e.g. 3.8 dB' },
        { lbl: 'VFI (%)', id: 'vfi', placeholder: 'e.g. 72%' },
        { lbl: 'Reliability indices', id: 'vf-rel', placeholder: 'FP<5%, FN<5%, FL<20%' },
      ],
      note: 'PDF report or device output should be uploaded once document upload is available.',
      verifyItems: ['Test completed bilaterally', 'Reliability indices acceptable', 'Patient cooperation noted'],
    };
  }
  if (n.includes('fundus')) {
    return {
      type: 'Fundus Photography', icon: 'ti-camera',
      fields: [
        { lbl: 'Image quality', id: 'img-qual', placeholder: 'Good / Fair / Poor' },
        { lbl: 'Field coverage', id: 'img-field', placeholder: 'e.g. Macula-centred, Disc-centred' },
        { lbl: 'Photography notes', id: 'photo-notes', placeholder: 'e.g. Media clear, good view...' },
      ],
      note: null,
      verifyItems: ['Images captured for required fields', 'Image quality acceptable', 'Linked to correct eye and encounter'],
    };
  }
  return {
    type: 'External Report', icon: 'ti-file-import',
    fields: [
      { lbl: 'Document type', id: 'doc-type', placeholder: 'e.g. Blood sugar report, ECG' },
      { lbl: 'Issuing lab/hospital', id: 'doc-source', placeholder: 'e.g. Pathology Lab, Haridwar' },
      { lbl: 'Report date', id: 'doc-date', placeholder: 'DD/MM/YYYY' },
      { lbl: 'Summary findings', id: 'doc-summary', placeholder: 'e.g. FBS 112 mg/dL, ECG normal sinus rhythm' },
    ],
    note: null,
    verifyItems: ['Document details recorded', 'Source and date documented', 'Linked to Clinical Encounter'],
  };
}

const STATUS_STEPS = ['Ordered', 'In Progress', 'Completed', 'Verified', 'Available'];
function statusIdx(status) {
  if (status === 'Available') return 4;
  const i = STATUS_STEPS.indexOf(status);
  return i === -1 ? 0 : i;
}

function StatusTimeline({ status }) {
  const currentIdx = statusIdx(status);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 0, flexWrap: 'wrap' }}>
      {STATUS_STEPS.map((s, i) => {
        const cls = i < currentIdx ? 'done' : i === currentIdx ? 'active' : 'pending';
        const bg = cls === 'done' ? 'var(--green)' : cls === 'active' ? 'var(--teal)' : '#fff';
        const border = cls === 'pending' ? 'var(--g200)' : (cls === 'done' ? 'var(--green)' : 'var(--teal)');
        const color = cls === 'pending' ? 'var(--g300)' : '#fff';
        return (
          <div key={s} style={{ display: 'flex', alignItems: 'center', flex: i < STATUS_STEPS.length - 1 ? 1 : 'none' }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, minWidth: 80 }}>
              <div style={{ width: 28, height: 28, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, border: `2px solid ${border}`, background: bg, color, boxShadow: cls === 'active' ? '0 0 0 4px var(--teal-lt)' : 'none' }}>
                <i className={`ti ${cls === 'done' ? 'ti-check' : cls === 'active' ? 'ti-loader' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
              </div>
              <div style={{ fontSize: 10, color: 'var(--g400)', textAlign: 'center' }}>{s}</div>
            </div>
            {i < STATUS_STEPS.length - 1 && <div style={{ flex: 1, height: 2, background: i < currentIdx ? 'var(--green)' : 'var(--g200)', minWidth: 20 }}></div>}
          </div>
        );
      })}
    </div>
  );
}

export default function InvestigationWorkspace({ orderId }) {
  const [order, setOrder] = useState(null);
  const [doctorName, setDoctorName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [fields, setFields] = useState({});
  const [remarks, setRemarks] = useState('');
  const [checklist, setChecklist] = useState({});
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [startedByName, setStartedByName] = useState(null);
  const router = useRouter();
  const searchParams = useSearchParams();
  const viewOnly = searchParams.get('mode') === 'view';

  useEffect(() => {
    getInvestigationDetail(orderId, viewOnly).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setOrder(result.order);
      setDoctorName(result.doctorName);
      setStartedByName(result.startedByName);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    });
  }, [orderId, viewOnly]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!order) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = order.encounters?.visits?.patients;
  const visitNumber = order.encounters?.visits?.visit_number;
  const template = matchInvestigationType(order.name);

  function setField(id, value) {
    setFields((prev) => ({ ...prev, [id]: value }));
  }
  function toggleCheck(item) {
    setChecklist((prev) => ({ ...prev, [item]: !prev[item] }));
  }

  async function refresh() {
    const result = await getInvestigationDetail(orderId, viewOnly);
    if (!result.error) {
      setOrder(result.order);
      setStartedByName(result.startedByName);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    }
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveInvestigationDraft(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleComplete() {
    setError(''); setSaving(true);
    const result = await completeInvestigation(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVerify() {
    setError('');
    const allChecked = template.verifyItems.every((item) => checklist[item]);
    if (!allChecked) {
      setError(`All verification items must be checked before verifying (${template.verifyItems.filter((i) => checklist[i]).length}/${template.verifyItems.length} checked).`);
      return;
    }
    setSaving(true);
    const result = await verifyInvestigation(orderId, checklist);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Investigation verified and released. Now available in Clinical Encounter.');
    refresh();
  }

  async function handleUnable() {
    const reason = window.prompt('Enter reason for unable to perform:');
    if (!reason) return;
    setError(''); setSaving(true);
    const result = await markUnableToPerform(orderId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  const isCancelled = order.status === 'Cancelled';
  const isAvailable = order.status === 'Available';
  const canEdit = !viewOnly && !isCancelled && !isAvailable;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Visit {visitNumber || '--'} -- Dr. {doctorName}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .7 }}>Investigation</div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{order.name}</div>
          <span className={`badge ${order.status === 'Available' ? 'b-green' : order.status === 'Cancelled' ? 'b-red' : order.status === 'Completed' ? 'b-teal' : order.status === 'In Progress' ? 'b-blue' : 'b-amber'}`} style={{ fontSize: 10, marginTop: 3 }}>
            {order.status}
          </span>
          {viewOnly && <span className="badge b-purple" style={{ fontSize: 10, marginTop: 3, marginLeft: 4 }}><i className="ti ti-eye"></i> Read-only</span>}
          {order.started_at && (
            <div style={{ fontSize: 10, opacity: .8, marginTop: 3 }}>
              Started by {startedByName || '--'} -- {new Date(order.started_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </div>
          )}
        </div>
      </div>

      {!isCancelled && (
        <div className="card" style={{ padding: 12 }}>
          <StatusTimeline status={order.status} />
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      {isCancelled ? (
        <div className="card" style={{ background: 'var(--red-lt)', borderColor: '#fca5a5' }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--red)', marginBottom: 6 }}>
            <i className="ti ti-x-circle"></i> Unable to Perform
          </div>
          <div style={{ fontSize: 13, color: 'var(--red)' }}>{order.unable_reason}</div>
        </div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
          <div>
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className={`ti ${template.icon}`} style={{ color: 'var(--teal)' }}></i> {order.name} workspace</div>
              {template.fields.map((f) => (
                <div key={f.id} style={{ marginBottom: 10 }}>
                  <label className="flbl">{f.lbl}</label>
                  <input className="fi fi-sm" placeholder={f.placeholder} value={fields[f.id] || ''} onChange={(e) => setField(f.id, e.target.value)} disabled={!canEdit} />
                </div>
              ))}
              {template.note && (
                <div style={{ marginTop: 8, padding: '8px 10px', background: 'var(--blue-lt)', borderRadius: 8, fontSize: 11, color: 'var(--blue)' }}>
                  <i className="ti ti-info-circle"></i> {template.note}
                </div>
              )}
            </div>
          </div>

          <div>
            <div className="card" style={{ marginBottom: 12 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Technician Remarks</div>
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 8 }}>
                <i className="ti ti-alert-triangle"></i> Factual observations only. Clinical interpretation is reserved for the Ophthalmologist.
              </div>
              <textarea className="fi fi-sm" rows={3} value={remarks} onChange={(e) => setRemarks(e.target.value)} disabled={!canEdit} placeholder="e.g. Poor fixation due to dense cataract. Scan quality: Good. Signal strength 7/10..." />
            </div>

            {!viewOnly && (order.status === 'Completed') && (
              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Verification confirms technical completeness -- not clinical interpretation.</div>
                {template.verifyItems.map((item) => (
                  <label key={item} style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, cursor: 'pointer', marginBottom: 5 }}>
                    <input type="checkbox" checked={!!checklist[item]} onChange={() => toggleCheck(item)} style={{ accentColor: 'var(--green)', width: 14, height: 14 }} />
                    {item}
                  </label>
                ))}
              </div>
            )}

            {viewOnly ? (
              <div className="card" style={{ marginBottom: 0, textAlign: 'center', color: 'var(--g400)', fontSize: 12 }}>
                <i className="ti ti-lock" style={{ display: 'block', fontSize: 18, marginBottom: 4 }}></i>
                Read-only view -- close this window to return.
              </div>
            ) : (
              <div className="card" style={{ marginBottom: 0 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrows-right" style={{ color: 'var(--teal)' }}></i> Workflow Controls</div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {order.status === 'In Progress' && (
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleComplete} disabled={saving}>
                      <i className="ti ti-check"></i> Mark Complete
                    </button>
                  )}
                  {order.status === 'Completed' && (
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
                      <i className="ti ti-shield-check"></i> Verify &amp; Release
                    </button>
                  )}
                  {canEdit && (
                    <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
                      <i className="ti ti-device-floppy"></i> Save Draft
                    </button>
                  )}
                  {canEdit && (
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleUnable} disabled={saving}>
                      <i className="ti ti-x-circle"></i> Unable to Perform
                    </button>
                  )}
                  <button className="btn btn-sm" onClick={() => router.push('/investigation')}>
                    <i className="ti ti-arrow-left"></i> Back to Queue
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

PYEOF_402896797764231868

cat > "app/(main)/investigation/actions.js" << 'PYEOF_4533903647715811800'
'use server';

import { createClient } from '@/lib/supabase-server';

// ── QUEUE (Ordered + In Progress, grouped by visit) plus today's KPI
// stats for the Queue screen's summary cards. ──
export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data: pending, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return { groups: [], stats: { ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 } };

  // Payment status is about the invoice, not just whether Front Office
  // ticked "billed" -- an invoice can be raised and still unpaid, so
  // this looks at the actual invoice net/paid amounts.
  const invoiceIds = [...new Set((pending || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  const groups = {};
  (pending || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient: io.encounters.visits.patients, items: [] };
    }
    groups[visitId].items.push({ ...io, kind: 'investigation', payment: paymentInfo(io) });
  });

  // Biometry is structurally its own thing (device measurements, IOL
  // formulas, surgeon approval -- not a text-field investigation), so it
  // stays in its own table and dedicated workspace. But per the doctor's
  // actual usage, it belongs in the same "what's outstanding for this
  // patient" queue as any other investigation, not off in a separate
  // module people forget to check. Approved/Cancelled are done, so left
  // out here the same way Available/Cancelled investigations are.
  const { data: bio } = await supabase
    .from('biometry_records')
    .select('*, visits(id, patients(first_name, last_name, uhid))')
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .order('created_at', { ascending: true });

  const bioInvoiceIds = [...new Set((bio || []).map((r) => r.invoice_id).filter(Boolean))];
  let bioInvoiceMap = invoiceMap;
  if (bioInvoiceIds.length > 0) {
    const { data: moreInvoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', bioInvoiceIds);
    (moreInvoices || []).forEach((inv) => { bioInvoiceMap[inv.id] = inv; });
  }
  function bioPaymentInfo(r) {
    if (r.billing_status !== 'Billed' || !r.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = bioInvoiceMap[r.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  (bio || []).forEach((r) => {
    const visitId = r.visit_id;
    const patient = r.visits?.patients;
    if (!visitId || !patient) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient, items: [] };
    }
    groups[visitId].items.push({
      id: r.id, kind: 'biometry', name: 'Biometry', eye: r.surgical_eye || 'OU', priority: 'Routine',
      status: r.status, created_at: r.created_at, payment: bioPaymentInfo(r),
    });
  });

  const ordered = (pending || []).filter((i) => i.status === 'Ordered').length;
  const inProgress = (pending || []).filter((i) => i.status === 'In Progress').length;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: todayOrders } = await supabase
    .from('investigation_orders')
    .select('id, status, verified_at, created_at')
    .gte('created_at', todayStart.toISOString());

  const availableToday = (todayOrders || []).filter((o) => o.status === 'Available' && o.verified_at && new Date(o.verified_at) >= todayStart).length;
  const totalToday = (todayOrders || []).length;

  return { groups: Object.values(groups), stats: { ordered, inProgress, availableToday, totalToday } };
}


// ── WORKSPACE: single order detail, with patient/doctor context ──
export async function getInvestigationDetail(id, viewOnly) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)))')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  // Opening the order to work on it (not just viewing) is the "start" --
  // no separate button needed. Timestamped with whoever opened it.
  if (!viewOnly && data.status === 'Ordered') {
    const { data: userData } = await supabase.auth.getUser();
    const startedAt = new Date().toISOString();
    await supabase.from('investigation_orders').update({
      status: 'In Progress', started_at: startedAt, started_by: userData?.user?.id || null,
    }).eq('id', id);
    data.status = 'In Progress';
    data.started_at = startedAt;
    data.started_by = userData?.user?.id || null;
  }

  let doctorName = '--';
  if (data.encounters?.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.encounters.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  let startedByName = null;
  if (data.started_by) {
    const { data: tech } = await supabase.from('profiles').select('full_name').eq('id', data.started_by).maybeSingle();
    startedByName = tech?.full_name || null;
  }

  return { order: data, doctorName, startedByName };
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').update({ status: 'In Progress' }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later, patient stays in the queue.
export async function saveInvestigationDraft(id, resultData, remarks) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('investigation_orders')
    .update({ result_data: resultData, result_notes: remarks })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, resultData, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_data: resultData,
      result_notes: remarks || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Verification is the gate between "technically done" and "visible to
// the doctor" -- status jumps straight to Available once every checklist
// item is confirmed (there's no separate persisted "Verified" state;
// it's a visual timeline step on the way to Available).
// Same "combine, don't overwrite" logic doctorSendOut uses -- a patient
// can be Awaiting more than one thing at once, so resolving Investigation
// should only clear that part, not silently blow away Biometry/Dilation
// if they're still pending.
async function resolveAwaitingPart(supabase, visitId, part) {
  if (!visitId) return;
  const { data: entry } = await supabase
    .from('queue_entries').select('id, status')
    .eq('visit_id', visitId).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!entry || !entry.status?.startsWith('Awaiting')) return;

  const remaining = entry.status.replace('Awaiting ', '').split(' & ').filter((l) => l !== part);
  const newStatus = remaining.length > 0 ? `Awaiting ${remaining.join(' & ')}` : 'Ready for Review';
  await supabase.from('queue_entries').update({ status: newStatus }).eq('id', entry.id);
}

export async function verifyInvestigation(id, checklist) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const allChecked = Object.values(checklist).every(Boolean) && Object.keys(checklist).length > 0;
  if (!allChecked) return { error: 'All verification items must be checked before verifying.' };

  const { data: order } = await supabase.from('investigation_orders').select('encounter_id, encounters(visit_id)').eq('id', id).maybeSingle();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Available',
      verification_checklist: checklist,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };

  await resolveAwaitingPart(supabase, order?.encounters?.visit_id, 'Investigation');

  return { success: true };
}

export async function markUnableToPerform(id, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  const { error } = await supabase
    .from('investigation_orders')
    .update({ status: 'Cancelled', unable_reason: reason })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every investigation lands here the moment it's ordered from
// Consultation, regardless of lab status -- Front Office bills as soon
// as the doctor orders it, it doesn't wait on the lab. Grouped by visit
// the same way the lab's own Queue screen is, so it reads the same way.
export async function getPendingInvestigationBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    const visit = io.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

async function setInvestigationBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
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

export async function markInvestigationDenied(id, note) {
  return setInvestigationBillingStatus(id, 'Denied', note);
}

export async function markInvestigationDeferred(id, note) {
  return setInvestigationBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetInvestigationBilling(id) {
  return setInvestigationBillingStatus(id, 'Pending', null);
}

// ── HISTORY ──
// Every investigation ever ordered, regardless of status -- filtering
// happens client-side (patient/type dropdowns) since a single-hospital
// dataset is small enough that a broad fetch is simpler and fast enough,
// same approach the rest of this module already takes.
export async function getInvestigationHistory(fromDate, toDate) {
  const supabase = await createClient();
  let query = supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(id, first_name, last_name, uhid)))')
    .order('created_at', { ascending: false })
    .limit(500);

  // Applied before the row cap so a date range reaches further back
  // than the default "most recent 500" would otherwise allow.
  if (fromDate) query = query.gte('created_at', `${fromDate}T00:00:00`);
  if (toDate) query = query.lte('created_at', `${toDate}T23:59:59`);

  const { data, error } = await query;
  if (error) return { error: error.message };

  const doctorIds = (data || []).map((o) => o.encounters?.doctor_id).filter(Boolean);
  const staffIds = (data || []).flatMap((o) => [o.completed_by, o.verified_by]).filter(Boolean);
  const allIds = [...new Set([...doctorIds, ...staffIds])];

  let profileMap = {};
  if (allIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', allIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }

  const rows = (data || []).map((o) => ({
    ...o,
    doctorName: profileMap[o.encounters?.doctor_id] || '--',
    performedByName: profileMap[o.verified_by] || profileMap[o.completed_by] || '--',
  }));

  return { rows };
}

// ── LONGITUDINAL COMPARISON ──
export async function searchPatientsForInvestigation(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getInvestigationComparisonData(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters!inner(id, visit_id, visits!inner(id, patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .in('status', ['Completed', 'Available'])
    .order('created_at', { ascending: true });
  if (error) return { error: error.message };
  return { rows: data || [] };
}

// ── REPORTS ──
export async function getInvestigationReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const fromIso = `${fromDate}T00:00:00`;
  const toIso = `${toDate}T23:59:59`;

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, doctor_id, visits(id, patients(first_name, last_name, uhid)))')
    .gte('created_at', fromIso)
    .lte('created_at', toIso)
    .order('created_at', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  const doctorIds = [...new Set((data || []).map((o) => o.encounters?.doctor_id).filter(Boolean))];
  let profileMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const doctorName = (o) => profileMap[o.encounters?.doctor_id] || '--';
  const patientName = (o) => {
    const p = o.encounters?.visits?.patients;
    return p ? `${p.first_name} ${p.last_name} (${p.uhid})` : '--';
  };

  if (reportId === 'register') {
    return {
      title: 'Daily Investigation Register',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: (data || []).map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'type_summary') {
    const counts = {};
    (data || []).forEach((o) => {
      const n = (o.name || '').toLowerCase();
      const type = n.includes('oct') ? 'OCT' : (n.includes('visual field') || n.includes(' vf')) ? 'Visual Field' : n.includes('fundus') ? 'Fundus Photography' : 'External Report';
      counts[type] = (counts[type] || 0) + 1;
    });
    return {
      title: 'Investigation Type Summary',
      headers: ['Type', 'Count'],
      rows: Object.entries(counts).map(([type, count]) => ({ cols: [type, count] })),
    };
  }

  if (reportId === 'pending') {
    const pending = (data || []).filter((o) => o.status === 'Ordered' || o.status === 'In Progress');
    return {
      title: 'Pending Investigations',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: pending.map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'quality') {
    const cancelled = (data || []).filter((o) => o.status === 'Cancelled');
    const total = (data || []).length;
    const rows = cancelled.map((o) => ({
      cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.unable_reason || '--'],
    }));
    rows.push({ cols: [`Total ordered in period: ${total}`, `Unable to perform: ${cancelled.length}`, '', ''] });
    return {
      title: 'Quality Report -- Unable to Perform',
      headers: ['Date', 'Patient', 'Investigation', 'Reason'],
      rows,
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

PYEOF_4533903647715811800

cat > "app/(main)/investigation/comparison/page.js" << 'PYEOF_4025278840246266652'
'use client';

import { useState } from 'react';
import { searchPatientsForInvestigation, getInvestigationComparisonData } from '../actions';
import { matchInvestigationType, parseNumeric } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const COMPARE_TYPES = ['OCT', 'Visual Field'];

export default function InvestigationComparisonPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [type, setType] = useState('OCT');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvestigation(searchQuery.trim());
    setSearchResults(results);
  }

  async function pickPatient(p) {
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    await loadData(p.id, type);
  }

  async function loadData(patientId, t) {
    setLoading(true);
    const result = await getInvestigationComparisonData(patientId);
    setLoading(false);
    if (result.error) { setRows([]); return; }
    const filtered = (result.rows || []).filter((r) => matchInvestigationType(r.name) === t);
    setRows(filtered);
  }

  async function handleTypeChange(t) {
    setType(t);
    if (patient) await loadData(patient.id, t);
  }

  const first = rows[0];
  const last = rows[rows.length - 1];
  const trend = type === 'OCT' && rows.length > 1 && first && last
    ? {
        cmt: (() => { const a = parseNumeric(first.result_data?.['cmt-re']); const b = parseNumeric(last.result_data?.['cmt-re']); return a !== null && b !== null ? b - a : null; })(),
        rnfl: (() => { const a = parseNumeric(first.result_data?.rnfl); const b = parseNumeric(last.result_data?.rnfl); return a !== null && b !== null ? b - a : null; })(),
      }
    : null;

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-chart-bar-off" style={{ color: 'var(--teal)' }}></i> Longitudinal Comparison</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {!patient ? (
            <div style={{ position: 'relative', flex: 1, minWidth: 240 }}>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient by name or UHID..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, position: 'absolute', background: '#fff', width: '100%', zIndex: 5 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--blue-lt)', padding: '6px 12px', borderRadius: 8 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={() => { setPatient(null); setRows([]); }}>Change</button>
            </div>
          )}
          <select className="fi" style={{ width: 'auto', padding: '7px 10px' }} value={type} onChange={(e) => handleTypeChange(e.target.value)}>
            {COMPARE_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && patient && rows.length === 0 && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No {type} history for this patient.</div>
      )}

      {!loading && rows.length > 0 && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: `repeat(${rows.length}, 1fr)`, gap: 12, marginBottom: 12 }}>
            {rows.map((r) => (
              <div key={r.id} className="card" style={{ marginBottom: 0 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', marginBottom: 8 }}>
                  {new Date(r.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                </div>
                {type === 'OCT' ? (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>CMT</span><strong>{r.result_data?.['cmt-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>RNFL</span><strong>{r.result_data?.rnfl || '--'}</strong></div>
                  </>
                ) : (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD RE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD LE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-le'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>VFI</span><strong>{r.result_data?.vfi || '--'}</strong></div>
                  </>
                )}
              </div>
            ))}
          </div>

          {trend && (trend.cmt !== null || trend.rnfl !== null) && (
            <div className="card">
              <div className="card-title"><i className="ti ti-trending-up" style={{ color: 'var(--teal)' }}></i> Trend Analysis</div>
              {trend.cmt !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <span>CMT change</span>
                  <span style={{ fontWeight: 700, color: trend.cmt > 10 ? 'var(--red)' : trend.cmt < -10 ? 'var(--green)' : 'var(--g600)' }}>{trend.cmt >= 0 ? '+' : ''}{trend.cmt} um over {rows.length - 1} visit(s)</span>
                </div>
              )}
              {trend.rnfl !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', fontSize: 12 }}>
                  <span>RNFL change</span>
                  <span style={{ fontWeight: 700, color: trend.rnfl < -5 ? 'var(--red)' : 'var(--green)' }}>{trend.rnfl >= 0 ? '+' : ''}{trend.rnfl} um</span>
                </div>
              )}
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>For clinical decision support. Interpretation by Ophthalmologist only.</div>
            </div>
          )}
        </>
      )}

      {!patient && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Search for a patient to compare their investigation results over time.</div>
      )}
    </div>
  );
}

PYEOF_4025278840246266652

cat > "app/(main)/investigation/history/page.js" << 'PYEOF_9183403782287395220'
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

const SORT_OPTIONS = [
  { value: 'date_desc', label: 'Newest first' },
  { value: 'date_asc', label: 'Oldest first' },
  { value: 'patient_asc', label: 'Patient (A-Z)' },
  { value: 'status', label: 'Status' },
];

function patientLabel(r) {
  const p = r.encounters?.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : '';
}

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [sortBy, setSortBy] = useState('date_desc');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (from, to) => {
    setLoading(true);
    const result = await getInvestigationHistory(from || undefined, to || undefined);
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(fromDate, toDate); }, [fromDate, toDate, refresh]);

  function clearDates() {
    setFromDate('');
    setToDate('');
  }

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = useMemo(() => {
    const result = rows.filter((r) => {
      if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
      if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
      return true;
    });

    const sorted = [...result];
    if (sortBy === 'date_desc') sorted.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    else if (sortBy === 'date_asc') sorted.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    else if (sortBy === 'patient_asc') sorted.sort((a, b) => patientLabel(a).localeCompare(patientLabel(b)));
    else if (sortBy === 'status') sorted.sort((a, b) => a.status.localeCompare(b.status));
    return sorted;
  }, [rows, patientFilter, typeFilter, sortBy]);

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <label className="flbl">From</label>
            <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">To</label>
            <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          </div>
          {(fromDate || toDate) && (
            <button className="btn btn-sm" style={{ alignSelf: 'flex-end' }} onClick={clearDates}>
              <i className="ti ti-x"></i> Clear dates
            </button>
          )}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignSelf: 'flex-end' }}>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
              {SORT_OPTIONS.map((s) => <option key={s.value} value={s.value}>Sort: {s.label}</option>)}
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Date/Time</th><th>Patient</th><th>Investigation</th><th>Eye</th><th>Key values</th><th>Status</th><th>Doctor</th><th>Performed by</th></tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const p = r.encounters?.visits?.patients;
              const type = matchInvestigationType(r.name);
              return (
                <tr key={r.id} onClick={() => router.push(`/investigation/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <strong>{p?.first_name} {p?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{p?.uhid}</span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td><span className="badge b-blue" style={{ fontSize: 10 }}>{r.eye}</span></td>
                  <td style={{ fontSize: 11, color: 'var(--g600)' }}>{summarizeResultData(type, r.result_data)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 11 }}>{r.doctorName}</td>
                  <td style={{ fontSize: 11, color: 'var(--g400)' }}>{r.performedByName}</td>
                </tr>
              );
            })}
            {!loading && filtered.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No records found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

PYEOF_9183403782287395220

cat > "app/(main)/master-data/financial/page.js" << 'PYEOF_2485398474093958387'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService, deleteService,
  getPackages, addPackage, updatePackage, deletePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug, deleteDrug,
  getSurgeries,
  getMasterAuditLog,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', label: 'Surgery', type: 'package' }];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const ORIGINS = ['Indian', 'Imported'];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status, record.code);
    setLoading(false);
    onUpdate();
  }
  return (
    <button className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ border: 'none', cursor: 'pointer' }} onClick={handleToggle} disabled={loading}>
      {record.status}
    </button>
  );
}

export default function FinancialMastersPage() {
  const [activeTab, setActiveTab] = useState('Consultation');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [drugs, setDrugs] = useState([]);
  const [surgeries, setSurgeries] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const [constituentsFor, setConstituentsFor] = useState(null);
  const [constituents, setConstituents] = useState([]);
  const [newLineDesc, setNewLineDesc] = useState('');
  const [newLineAmount, setNewLineAmount] = useState('');

  const tabDef = TABS.find((t) => t.key === activeTab);
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setSurgeries(await getSurgeries());
    setAuditLog(await getMasterAuditLog(auditTable));
  }, [auditTable]);

  useEffect(() => { refresh(); }, [refresh]);

  const deptServices = services.filter((s) => s.dept === activeTab);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }
  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError(''); setSuccess('');
    if (tabDef.type === 'drug') {
      if (!form.generic) { setError('Generic name is required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (!form.name) {
      setError('Name is required.'); return;
    }

    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract';
      result = await addPackage(isCataract ? form : { ...form, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else result = await addService({ ...form, dept: activeTab });

    if (result?.error) { setError(result.error); return; }
    setSuccess(`${form.name || form.generic} added${tabDef.type === 'package' ? ' -- add its constituents to set the price' : ''}.`);
    setForm({});
    setShowAdd(false);
    refresh();
    if (tabDef.type === 'package' && result.package) openConstituents(result.package);
  }

  function startEdit(record) {
    setError(''); setSuccess('');
    setEditingId(record.id);
    if (tabDef.type === 'package') setEditForm({ name: record.name || '', includes: record.includes || '', surgeryId: record.surgery_id || '', iolCategory: record.iol_category || '', origin: record.origin || '' });
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand || '', generic: record.generic || '', strength: record.strength || '', form: record.form || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
    else setEditForm({ name: record.name || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '', investigationPackage: record.investigation_package || '' });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract';
      result = await updatePackage(record.id, record, isCataract ? editForm : { ...editForm, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else result = await updateService(record.id, record, { ...editForm, dept: record.dept });
    if (result?.error) { setError(result.error); return; }
    setSuccess('Updated.');
    setEditingId(null);
    refresh();
  }

  async function handleDelete(record) {
    if (!window.confirm(`Delete "${record.name || record.generic}"? This cannot be undone. If it's in use elsewhere, deletion will be blocked and you should mark it Inactive instead.`)) return;
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') result = await deletePackage(record.id, record.code);
    else if (tabDef.type === 'drug') result = await deleteDrug(record.id, record.code);
    else result = await deleteService(record.id, record.code);
    if (result?.error) { setError(result.error); return; }
    setSuccess('Deleted.');
    refresh();
  }

  async function openConstituents(pkg) {
    setConstituentsFor(pkg);
    setConstituents(await getPackageLineItems(pkg.id));
    setNewLineDesc(''); setNewLineAmount('');
  }

  function closeConstituents() {
    setConstituentsFor(null);
    setConstituents([]);
  }

  async function handleAddLine() {
    if (!newLineDesc.trim() || !newLineAmount) { setError('Description and amount are required.'); return; }
    setError('');
    const result = await addPackageLineItem(constituentsFor.id, newLineDesc, newLineAmount);
    if (result?.error) { setError(result.error); return; }
    setNewLineDesc(''); setNewLineAmount('');
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  async function handleRemoveLine(id) {
    await removePackageLineItem(id, constituentsFor.id);
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  const constituentsTotal = constituents.reduce((s, c) => s + Number(c.amount), 0);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div>
        <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
          {TABS.map((t) => (
            <button
              key={t.key}
              className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
              onClick={() => { setActiveTab(t.key); setShowAdd(false); setEditingId(null); setError(''); setSuccess(''); }}
            >
              {t.label || t.key}
            </button>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> {activeTab}</div>
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {(tabDef.type === 'service' || tabDef.type === 'drug') && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> {tabDef.type === 'service' ? 'Code is generated automatically, linked to department (e.g. INV001, INV002...).' : 'Code is generated automatically from the name.'}
            </div>
          )}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {tabDef.type === 'service' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                  {activeTab === 'Investigation' && (
                    <div style={{ gridColumn: 'span 3' }}>
                      <input className="fi" placeholder="Package (optional, e.g. Cataract) -- lets Counselling order this as part of a standard panel" onChange={update('investigationPackage')} />
                    </div>
                  )}
                </div>
              )}
              {tabDef.type === 'drug' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Brand" onChange={update('brand')} />
                  <input className="fi" placeholder="Generic name" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <input className="fi" placeholder="Form (e.g. Eye Drop)" onChange={update('form')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'package' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery -- Standard IOL)" onChange={update('name')} />
                  <select className="fi" onChange={update('surgeryId')} defaultValue="">
                    <option value="">-- Link to surgery (optional) --</option>
                    {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select>
                  {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
                    <>
                      <select className="fi" onChange={update('iolCategory')} defaultValue="">
                        <option value="">-- IOL type (optional) --</option>
                        {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                      </select>
                      <select className="fi" onChange={update('origin')} defaultValue="">
                        <option value="">-- Origin (optional) --</option>
                        {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                      </select>
                    </>
                  )}
                  <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 2' }} onChange={update('includes')} />
                  <div style={{ gridColumn: 'span 2', fontSize: 11, color: 'var(--g500)' }}>
                    Code auto-generates (PKG001, PKG002...). Price is set by adding constituents after saving.
                    {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
                      <> IOL type + Origin determine which packages the Counselling module shows for a given Biometry result.</>
                    )}
                  </div>
                </div>
              )}
              <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
            </div>
          )}

          {tabDef.type === 'service' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Rate</th><th>GST%</th>{activeTab === 'Investigation' && <th>Package</th>}<th>Status</th><th></th></tr></thead>
              <tbody>
                {deptServices.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 80 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 60 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      {activeTab === 'Investigation' && (
                        <td><input className="fi fi-sm" style={{ width: 110 }} placeholder="optional" value={editForm.investigationPackage} onChange={updateEdit('investigationPackage')} /></td>
                      )}
                      <td><span className={`badge ${s.status === 'Active' ? 'b-green' : 'b-gray'}`}>{s.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(s)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={s.id}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td>
                      <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                      {activeTab === 'Investigation' && <td>{s.investigation_package ? <span className="badge b-purple" style={{ fontSize: 10 }}>{s.investigation_package}</span> : <span style={{ color: 'var(--g400)' }}>--</span>}</td>}
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(s)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {deptServices.length === 0 && (
                  <tr><td colSpan={activeTab === 'Investigation' ? 7 : 6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No {activeTab.toLowerCase()} services yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Brand</th><th>Generic</th><th>Strength</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 70 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 55 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${d.status === 'Active' ? 'b-green' : 'b-gray'}`}>{d.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(d)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={d.id}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                      <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                      <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(d)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(d)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Surgery</th><th>IOL Type / Origin</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.surgeryId} onChange={updateEdit('surgeryId')}>
                          <option value="">--</option>
                          {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                        </select>
                      </td>
                      <td>
                        {(surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract') ? (
                          <div style={{ display: 'flex', gap: 4 }}>
                            <select className="fi fi-sm" value={editForm.iolCategory} onChange={updateEdit('iolCategory')}>
                              <option value="">IOL type --</option>
                              {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                            </select>
                            <select className="fi fi-sm" value={editForm.origin} onChange={updateEdit('origin')}>
                              <option value="">Origin --</option>
                              {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                            </select>
                          </div>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>N/A</span>}
                      </td>
                      <td>Rs.{p.price}</td>
                      <td><span className={`badge ${p.status === 'Active' ? 'b-green' : 'b-gray'}`}>{p.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(p)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td>
                      <td style={{ fontSize: 12, color: 'var(--g500)' }}>{p.master_surgeries?.name || '--'}</td>
                      <td>
                        {p.iol_category ? (
                          <span style={{ display: 'flex', gap: 4 }}>
                            <span className="badge b-purple" style={{ fontSize: 10 }}>{p.iol_category}</span>
                            {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`} style={{ fontSize: 10 }}>{p.origin}</span>}
                          </span>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>--</span>}
                      </td>
                      <td style={{ fontWeight: 600 }}>Rs.{p.price}</td>
                      <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => openConstituents(p)}><i className="ti ti-list-details"></i> Breakup</button>
                        <button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(p)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {constituentsFor && (
            <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, marginTop: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                <div style={{ fontSize: 13, fontWeight: 700 }}>
                  <i className="ti ti-list-details" style={{ color: 'var(--teal)' }}></i> Breakup -- {constituentsFor.name} ({constituentsFor.code})
                </div>
                <button className="btn btn-sm" onClick={closeConstituents}><i className="ti ti-x"></i> Close</button>
              </div>
              <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> The package price is always the sum of these constituents.
              </div>
              <table className="tbl" style={{ marginBottom: 12 }}>
                <thead><tr><th>Description</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
                <tbody>
                  {constituents.map((c) => (
                    <tr key={c.id}>
                      <td>{c.description}</td>
                      <td style={{ textAlign: 'right' }}>Rs.{Number(c.amount).toFixed(2)}</td>
                      <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(c.id)}>Remove</button></td>
                    </tr>
                  ))}
                  {constituents.length === 0 && (
                    <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No constituents yet -- price is Rs.0 until you add some.</td></tr>
                  )}
                </tbody>
                <tfoot>
                  <tr style={{ fontWeight: 700 }}>
                    <td>Total</td><td style={{ textAlign: 'right' }}>Rs.{constituentsTotal.toFixed(2)}</td><td></td>
                  </tr>
                </tfoot>
              </table>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" placeholder="e.g. Surgeon Fee, OT Charges, IOL, Consumables..." value={newLineDesc} onChange={(e) => setNewLineDesc(e.target.value)} style={{ flex: 2 }} />
                <input type="number" className="fi" placeholder="Amount" value={newLineAmount} onChange={(e) => setNewLineAmount(e.target.value)} style={{ flex: 1 }} />
                <button className="btn btn-primary btn-sm" onClick={handleAddLine}><i className="ti ti-plus"></i> Add</button>
              </div>
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Change History -- {activeTab}
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded yet.</div>}
          {auditLog.map((a) => (
            <div key={a.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span className={`badge ${a.action === 'Create' ? 'b-green' : a.action === 'Edit' ? 'b-blue' : a.action === 'Reactivate' ? 'b-teal' : 'b-red'}`} style={{ fontSize: 10 }}>{a.action}</span>
                <span style={{ fontSize: 10, color: 'var(--g400)' }}>{new Date(a.changed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
              </div>
              <div style={{ marginTop: 3, fontFamily: 'monospace', fontSize: 11, color: 'var(--g600)' }}>{a.record_code}</div>
              <div style={{ marginTop: 2 }}>{a.detail}</div>
              <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{a.profiles?.full_name || 'Staff'}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

PYEOF_2485398474093958387

cat > "app/(main)/medical-fitness/page.js" << 'PYEOF_1110691121906022253'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getMedicalFitnessQueue, getMedicalFitnessHistory, getMedicalFitnessDetail,
  getInvestigationMasterOptions, orderFitnessInvestigation, removeFitnessInvestigation,
  clearFitness, markNotFit,
} from './actions';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { openPopup } from '@/lib/popup';

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };
const HISTORY_STATUS_BADGE = { Cleared: 'b-green', 'Not Fit': 'b-red' };
const TIMELINE_TYPE_COLOR = { Visit: 'var(--blue)', Diagnosis: 'var(--red)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--amber)' };
const TIMELINE_TYPE_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };

function daysWaiting(referral) {
  const ms = new Date() - new Date(referral.referred_at);
  return Math.floor(ms / (1000 * 60 * 60 * 24));
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--amber)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// ── TAB 1: QUEUE (Pending Review) ──
function QueueTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  let filtered = rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  filtered = [...filtered].sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.referred_at) - new Date(b.referred_at);
    if (sortBy === 'newest') return new Date(b.referred_at) - new Date(a.referred_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.surgical_cases?.priority] ?? 9) - (order[b.surgical_cases?.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Pending Review <span className="badge b-amber">{rows.length}</span></div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
          <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
            <option value="oldest">Oldest first</option>
            <option value="newest">Newest first</option>
            <option value="priority">Priority</option>
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && filtered.map((r) => {
        const dw = daysWaiting(r);
        return (
          <div key={r.id} onClick={() => onOpen(r.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {r.visits?.patients?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</span>
              <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Pending Review</span>
              {r.surgical_cases?.priority && r.surgical_cases.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{r.surgical_cases.priority}</span>}
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})
              </div>
            </div>
            <div style={{ textAlign: 'right', fontSize: 10, color: dw > 3 ? 'var(--red)' : dw > 1 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
              {dw === 0 ? 'Today' : `${dw}d waiting`}
            </div>
            <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
          </div>
        );
      })}

      {!loading && filtered.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          {rows.length === 0 ? 'No referrals pending review. Counsellors refer patients from Counselling once package is confirmed and accepted.' : 'No referrals match this search.'}
        </div>
      )}
    </div>
  );
}

// ── TAB 3: HISTORY (completed referrals) ──
function HistoryTab({ rows, loading, onOpen }) {
  const [statusFilter, setStatusFilter] = useState('');
  const [search, setSearch] = useState('');

  const counts = {
    Cleared: rows.filter((r) => r.status === 'Cleared').length,
    'Not Fit': rows.filter((r) => r.status === 'Not Fit').length,
  };

  let filtered = statusFilter ? rows.filter((r) => r.status === statusFilter) : rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Medical Fitness History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
        <button className={`btn btn-sm ${!statusFilter ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('')}>All ({rows.length})</button>
        <button className={`btn btn-sm ${statusFilter === 'Cleared' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Cleared')}>Cleared ({counts.Cleared})</button>
        <button className={`btn btn-sm ${statusFilter === 'Not Fit' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Not Fit')}>Not Fit ({counts['Not Fit']})</button>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Decided By</th><th>Date</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => (
              <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                <td>
                  <strong>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 12 }}>{r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})</td>
                <td><span className={`badge ${HISTORY_STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                <td style={{ fontSize: 12 }}>{r.clearedByName}</td>
                <td style={{ fontSize: 11 }}>{r.cleared_at ? new Date(r.cleared_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed referrals yet.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── TAB 2: WORKSPACE (per-patient clinical review) ──
export function WorkspaceTab({ referralId, onDone }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [subTab, setSubTab] = useState('summary');

  const [invOptions, setInvOptions] = useState([]);
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('N/A');
  const [invPriority, setInvPriority] = useState('Routine');
  const [ordering, setOrdering] = useState(false);

  const [timeline, setTimeline] = useState(null);
  const [timelineLoading, setTimelineLoading] = useState(false);

  const [decisionNotes, setDecisionNotes] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getMedicalFitnessDetail(referralId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [referralId]);

  useEffect(() => {
    setData(null); setLoadError(''); setSubTab('summary'); setTimeline(null); setDecisionNotes('');
    refresh();
    getInvestigationMasterOptions().then(setInvOptions);
  }, [referralId, refresh]);

  useEffect(() => {
    if (subTab === 'timeline' && !timeline && data) {
      setTimelineLoading(true);
      getPatientTimeline(data.referral.visits.patients.id).then((t) => { setTimeline(t); setTimelineLoading(false); });
    }
  }, [subTab, timeline, data]);

  async function handleOrderInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Select or enter an investigation.'); return; }
    setOrdering(true);
    const result = await orderFitnessInvestigation(referralId, data.referral.encounter_id, { name: invName, eye: invEye, priority: invPriority });
    setOrdering(false);
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleRemoveInvestigation(id) {
    await removeFitnessInvestigation(id);
    refresh();
  }

  async function handleClear() {
    setError('');
    setSaving(true);
    const result = await clearFitness(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  async function handleMarkNotFit() {
    setError('');
    if (!decisionNotes.trim()) { setError('Notes are required when marking not fit.'); return; }
    setSaving(true);
    const result = await markNotFit(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { referral, currentDiagnoses, investigations, diagnosisHistory, referredByName, clearedByName } = data;
  const patient = referral.visits.patients;
  const sc = referral.surgical_cases;
  const isPending = referral.status === 'Pending Review';

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#a15c00,#d97706)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient.uhid} -- {patient.age} {patient.gender} -- {referral.visits.visit_number}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .8 }}>Referred for surgery</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc?.procedure_name} ({sc?.eye})</div>
          <div style={{ fontSize: 10, opacity: .8 }}>By {referredByName} -- {new Date(referral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {referral.status !== 'Pending Review' && (
        <div className={`msg-${referral.status === 'Cleared' ? 'ok' : 'err'}`} style={{ marginBottom: 12 }}>
          <i className={`ti ${referral.status === 'Cleared' ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i>
          <span>
            <strong>{referral.status}</strong>{referral.fitness_notes ? ` -- ${referral.fitness_notes}` : ''}
            <span style={{ display: 'block', fontSize: 11, opacity: 0.85, marginTop: 2 }}>
              By Dr. {clearedByName || '--'} -- {referral.cleared_at ? new Date(referral.cleared_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '--'}
            </span>
          </span>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 14 }}>
        <div>
          <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <TabButton active={subTab === 'summary'} onClick={() => setSubTab('summary')} icon="ti-report-medical" label="Clinical Summary" />
            <TabButton active={subTab === 'timeline'} onClick={() => setSubTab('timeline')} icon="ti-timeline" label="Visit Timeline" />
            <TabButton active={subTab === 'investigations'} onClick={() => setSubTab('investigations')} icon="ti-flask" label={`Investigations${investigations.length > 0 ? ` (${investigations.length})` : ''}`} />
          </div>

          {subTab === 'summary' && (
            <>
              <div className="card">
                <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-report-medical" style={{ color: 'var(--blue)' }}></i> Current Diagnoses</div>
                {currentDiagnoses.map((d) => (
                  <div key={d.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
                    <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
                    {d.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{d.notes}</div>}
                  </div>
                ))}
                {currentDiagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>None recorded.</div>}
              </div>

              <div className="card" style={{ marginBottom: 0 }}>
                <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(prior visits)</span></div>
                <div style={{ maxHeight: 260, overflowY: 'auto' }}>
                  {diagnosisHistory.map((d) => (
                    <div key={d.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 10.5 }}>{new Date(d.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      {' -- '}<strong>{d.name}</strong> -- {d.eye}
                    </div>
                  ))}
                  {diagnosisHistory.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior diagnoses on record.</div>}
                </div>
              </div>
            </>
          )}

          {subTab === 'timeline' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Visit Timeline</div>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Every visit this patient has had. Click a Visit to open the doctor&apos;s full clinical record for it, read-only.</div>

              {timelineLoading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 16, textAlign: 'center' }}>Loading timeline...</div>}

              {!timelineLoading && timeline && (
                <div style={{ maxHeight: 420, overflowY: 'auto' }}>
                  {timeline.events.map((ev, i) => {
                    const isVisit = ev.type === 'Visit';
                    const clickable = isVisit && ev.queueEntryId;
                    return (
                      <div
                        key={i}
                        onClick={clickable ? () => window.open(`/consultation/${ev.queueEntryId}`, '_blank', 'noopener,noreferrer') : undefined}
                        style={{
                          border: clickable ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', marginBottom: 6,
                          display: 'flex', alignItems: 'center', gap: 8, cursor: clickable ? 'pointer' : 'default',
                        }}
                      >
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 10, color: 'var(--g400)', marginBottom: 2 }}>{new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</div>
                          <div style={{ fontSize: 12.5, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TIMELINE_TYPE_ICON[ev.type]}`} style={{ color: TIMELINE_TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>{ev.detail}</div>
                        </div>
                        {clickable && <i className="ti ti-external-link" style={{ color: 'var(--blue)' }}></i>}
                      </div>
                    );
                  })}
                  {timeline.events.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', textAlign: 'center', padding: 16 }}>No prior events.</div>}
                </div>
              )}
            </div>
          )}

          {subTab === 'investigations' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>

              {investigations.map((i) => {
                const type = matchInvestigationType(i.name);
                const hasResults = i.status === 'Available';
                return (
                  <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 12.5 }}>
                      <span><strong>{i.name}</strong> -- {i.eye}</span>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                        {hasResults && (
                          <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                            <i className="ti ti-eye"></i> View
                          </button>
                        )}
                        {i.status === 'Ordered' && isPending && (
                          <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => handleRemoveInvestigation(i.id)}>Remove</button>
                        )}
                      </div>
                    </div>
                    {hasResults && (
                      <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{summarizeResultData(type, i.result_data)}</div>
                    )}
                  </div>
                );
              })}
              {investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>None ordered yet.</div>}

              {isPending && (
                <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                  <select className="fi" style={{ flex: 2, minWidth: 140 }} value={invOptions.some((o) => o.name === invName) ? invName : ''} onChange={(e) => setInvName(e.target.value)}>
                    <option value="">-- Pick investigation --</option>
                    {invOptions.map((o) => <option key={o.code} value={o.name}>{o.name}</option>)}
                  </select>
                  <select className="fi" style={{ width: 80 }} value={invEye} onChange={(e) => setInvEye(e.target.value)}>
                    <option value="N/A">N/A</option><option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" style={{ width: 100 }} value={invPriority} onChange={(e) => setInvPriority(e.target.value)}>
                    <option value="Routine">Routine</option><option value="Urgent">Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleOrderInvestigation} disabled={ordering}>
                    {ordering ? 'Ordering...' : 'Order'}
                  </button>
                </div>
              )}
            </div>
          )}
        </div>

        <div>
          {isPending && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-clipboard-check" style={{ color: 'var(--amber)' }}></i> Fitness Decision</div>
              <textarea className="fi" rows={3} placeholder="Clinical notes / certificate remarks (required if marking not fit, optional if clearing)" value={decisionNotes} onChange={(e) => setDecisionNotes(e.target.value)} style={{ marginBottom: 8 }} />
              <div style={{ display: 'flex', gap: 8 }}>
                <button className="btn btn-primary" style={{ flex: 1 }} onClick={handleClear} disabled={saving}>
                  <i className="ti ti-circle-check"></i> {saving ? 'Saving...' : 'Clear for Surgery'}
                </button>
                <button className="btn" style={{ flex: 1, color: 'var(--red)' }} onClick={handleMarkNotFit} disabled={saving}>
                  <i className="ti ti-x"></i> Not Fit
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── PAGE: single SPA with client-side tab switching, matching Counselling ──
export default function MedicalFitnessPage() {
  const [queueRows, setQueueRows] = useState([]);
  const [historyRows, setHistoryRows] = useState([]);
  const [loadingQueue, setLoadingQueue] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState('queue');
  const [selectedReferralId, setSelectedReferralId] = useState(null);

  const refreshQueue = useCallback(async () => {
    setQueueRows(await getMedicalFitnessQueue());
    setLoadingQueue(false);
  }, []);
  const refreshHistory = useCallback(async () => {
    setHistoryRows(await getMedicalFitnessHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refreshQueue(); refreshHistory(); }, [refreshQueue, refreshHistory]);

  function openReferral(id) {
    setSelectedReferralId(id);
    setActiveTab('workspace');
  }

  function handleWorkspaceDone() {
    // A decision was just made -- refresh both lists (patient moves out
    // of Queue and into History) and go back to the Queue.
    refreshQueue();
    refreshHistory();
    setSelectedReferralId(null);
    setActiveTab('queue');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'queue'} onClick={() => setActiveTab('queue')} icon="ti-list-numbers" label="Queue (Pending Review)" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-user-square" label="Workspace" disabled={!selectedReferralId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'queue' && <QueueTab rows={queueRows} loading={loadingQueue} onOpen={openReferral} />}
      {activeTab === 'history' && <HistoryTab rows={historyRows} loading={loadingHistory} onOpen={openReferral} />}
      {activeTab === 'workspace' && selectedReferralId && <WorkspaceTab referralId={selectedReferralId} onDone={handleWorkspaceDone} />}
      {activeTab === 'workspace' && !selectedReferralId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Queue or History tab.
        </div>
      )}
    </div>
  );
}

PYEOF_1110691121906022253

cat > "app/(main)/optometry-history/[assessmentId]/assessment-viewer.js" << 'PYEOF_8611417911920902714'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getAssessmentDetail } from '@/app/(main)/optometry-history/actions';

// Same VA field layout as the live entry workspace (app/(main)/optometry/[id]/optometry-workspace.js)
// -- kept in sync deliberately so a completed sheet renders identically here, just non-editable.
const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

function AsmtSection({ num, color, title, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

// Read-only VA pill -- same visual language as the entry form's
// selectable pills, minus the click handler.
function VaPill({ value }) {
  if (!value) return <span style={{ fontSize: 12, color: 'var(--g400)' }}>Not recorded</span>;
  return (
    <div style={{ display: 'inline-block', padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>
      {value}
    </div>
  );
}

export default function AssessmentViewer({ assessmentId }) {
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [overrideCount, setOverrideCount] = useState(0);
  const [loadError, setLoadError] = useState('');
  const [openSections, setOpenSections] = useState({ va: true, refraction: true, iop: true, additional: true, obs: true });
  const router = useRouter();

  useEffect(() => {
    getAssessmentDetail(assessmentId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setOverrideCount(result.overrideCount);
    });
  }, [assessmentId]);

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = assessment.visits?.patients;
  const reIop = iopReadings.filter((r) => r.eye === 'RE');
  const leIop = iopReadings.filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  return (
    <div>
      {/* PATIENT STRIP */}
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              Visit {assessment.visits?.visit_number || '--'}
            </span>
          </div>
        </div>
      </div>

      {/* LOCK / STATUS BANNER */}
      <div className="msg-err" style={{ marginBottom: 12 }}>
        <i className="ti ti-lock"></i> Historical record -- read only. Current values shown, including any doctor edits.
      </div>
      {overrideCount > 0 && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-alert-triangle"></i> A doctor has overridden {overrideCount} field{overrideCount > 1 ? 's' : ''} on this record. See the highlighted entries in the Audit Log below for exactly what changed and when.
        </div>
      )}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={1} color="var(--teal)" title={`Visual Acuity (${assessment.va_scale || 'Snellen'})`} open={openSections.va} onToggle={() => toggleSection('va')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaPill value={assessment[f.key]} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={2} color="var(--blue)" title="Refraction" open={openSections.refraction} onToggle={() => toggleSection('refraction')}>
          {['obj', 'subj', 'final'].map((type) => (
            <div key={type} style={{ marginBottom: 16 }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', marginBottom: 6 }}>
                {type === 'obj' ? 'Objective (Auto-Rx)' : type === 'subj' ? 'Subjective' : 'Final Rx'}
              </div>
              <table className="tbl">
                <thead>
                  <tr>
                    <th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{type === 'final' && <th>ADD (near)</th>}
                  </tr>
                </thead>
                <tbody>
                  {['re', 'le'].map((eye) => (
                    <tr key={eye}>
                      <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_sph`] || '--'}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_cyl`] || '--'}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_axis`] || '--'}</td>
                      {type === 'final' && <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_add`] || '--'}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div><label className="flbl">Pupillary Distance (PD)</label><div style={{ fontSize: 13 }}>{assessment.ref_pd || '--'}</div></div>
            <div><label className="flbl">Vertex Distance</label><div style={{ fontSize: 13 }}>{assessment.ref_vd || '--'}</div></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={3} color="var(--purple)" title={`Intraocular Pressure (${assessment.iop_method || '--'})`} open={openSections.iop} onToggle={() => toggleSection('iop')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIop], ['LE', leIop]].map(([eye, list]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings recorded</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={4} color="var(--amber)" title="Additional Measurements" open={openSections.additional} onToggle={() => toggleSection('additional')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><div style={{ fontSize: 13 }}>{assessment.add_k1 || '--'}</div></div>
            <div><label className="flbl">Keratometry K2</label><div style={{ fontSize: 13 }}>{assessment.add_k2 || '--'}</div></div>
            <div><label className="flbl">Axial Length</label><div style={{ fontSize: 13 }}>{assessment.add_axial_length || '--'}</div></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><div style={{ fontSize: 13 }}>{assessment.add_pachymetry || '--'}</div></div>
            <div><label className="flbl">White-to-White</label><div style={{ fontSize: 13 }}>{assessment.add_white_to_white || '--'}</div></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><div style={{ fontSize: 13 }}>{assessment.add_schirmer || '--'}</div></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div><label className="flbl">Color vision</label><div style={{ fontSize: 13 }}>{assessment.add_color_vision || 'Not tested'}</div></div>
            <div><label className="flbl">Ocular motility</label><div style={{ fontSize: 13 }}>{assessment.add_ocular_motility || 'Not tested'}</div></div>
            <div><label className="flbl">Syringing</label><div style={{ fontSize: 13 }}>{assessment.add_syringing || 'Not done'}</div></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={5} color="var(--g500)" title="Clinical Observations" open={openSections.obs} onToggle={() => toggleSection('obs')}>
          {assessment.observation_chips?.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
              {assessment.observation_chips.map((chip) => (
                <div key={chip} style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>
                  {chip}
                </div>
              ))}
            </div>
          )}
          <label className="flbl">Additional observations</label>
          <div style={{ fontSize: 13, color: assessment.observations_text ? 'var(--g800)' : 'var(--g400)' }}>
            {assessment.observations_text || 'None recorded'}
          </div>
        </AsmtSection>
      </div>

      {/* AUDIT LOG -- doctor overrides are highlighted here since they're
          logged as regular entries on this same assessment (no separate
          shadow table). */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
        {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity recorded.</div>}
        {auditLog.map((a) => (
          <div
            key={a.id}
            style={{
              fontSize: 11, padding: '6px 8px', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8,
              background: a.isDoctorOverride ? 'rgba(220,38,38,0.06)' : 'transparent',
              borderRadius: a.isDoctorOverride ? 6 : 0,
              marginBottom: a.isDoctorOverride ? 2 : 0,
            }}
          >
            <span style={{ color: a.isDoctorOverride ? 'var(--red)' : 'var(--g400)', flexShrink: 0 }}>
              {new Date(a.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </span>
            <span style={{ color: a.isDoctorOverride ? 'var(--red)' : 'var(--g500)', fontWeight: a.isDoctorOverride ? 600 : 400 }}>
              {a.isDoctorOverride && <i className="ti ti-stethoscope" style={{ marginRight: 4 }}></i>}
              {a.message}
              {a.isDoctorOverride && a.created_by_name && <span style={{ fontWeight: 400 }}> -- {a.created_by_name}</span>}
            </span>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-history')}>
          <i className="ti ti-arrow-left"></i> Back to History
        </button>
      </div>
    </div>
  );
}
PYEOF_8611417911920902714

cat > "app/(main)/optometry-history/page.js" << 'PYEOF_248864227435603103'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getOptometryHistory } from './actions';

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export default function OptometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (status) => {
    setLoading(true);
    const result = await getOptometryHistory(status || undefined);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setError('');
    setRows(result.rows);
  }, []);

  useEffect(() => { refresh(filter); }, [filter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Assessment History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <select className="fi" style={{ width: 'auto', padding: '9px 12px' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="">All</option>
            <option value="Completed">Completed</option>
            <option value="Draft">Draft</option>
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date/Time</th><th>Patient</th><th>Visit</th><th>VA RE</th><th>VA LE</th><th>IOP RE</th><th>IOP LE</th><th>Status</th><th>By</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const iopReHigh = typeof r.iopRe === 'number' && r.iopRe > 21;
              const iopLeHigh = typeof r.iopLe === 'number' && r.iopLe > 21;
              const by = r.status === 'Completed' ? (r.completed_by_profile?.full_name || '--') : (r.recorded_by_profile?.full_name || '--');
              const dt = new Date(r.completed_at || r.updated_at || r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
              return (
                <tr
                  key={r.id}
                  onClick={() => router.push(`/optometry-history/${r.id}`)}
                  style={{ cursor: 'pointer' }}
                >
                  <td style={{ fontSize: 11 }}>{dt}</td>
                  <td>
                    <strong>{patientName(r)}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.visits?.visit_number || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.re_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.le_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600, color: iopReHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopRe ?? '--'}{iopReHigh ? ' !' : ''}</td>
                  <td style={{ fontWeight: 600, color: iopLeHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopLe ?? '--'}{iopLeHigh ? ' !' : ''}</td>
                  <td>
                    <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-amber'}`}>{r.status}</span>
                    {r.hasDoctorCorrection && (
                      <span className="badge" style={{ marginLeft: 6, background: 'rgba(220,38,38,0.1)', color: 'var(--red)' }} title="Doctor recorded a differing finding for this visit">
                        <i className="ti ti-alert-triangle" style={{ fontSize: 11 }}></i> Correction
                      </span>
                    )}
                  </td>
                  <td style={{ fontSize: 12 }}>{by}</td>
                </tr>
              );
            })}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No assessments found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
PYEOF_248864227435603103

cat > "app/(main)/optometry-reports/actions.js" << 'PYEOF_2348177055663470064'
'use server';

import { createClient } from '@/lib/supabase-server';

async function fetchAssessmentsWithIop(supabase, from, to, dateColumn) {
  const { data: assessments } = await supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .gte(dateColumn, from)
    .lte(dateColumn, `${to}T23:59:59`);

  const rows = assessments || [];
  const ids = rows.map((a) => a.id);

  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r.value);
    });
  }

  return rows.map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    return {
      ...a,
      iopRe: readings.RE.length ? readings.RE[readings.RE.length - 1] : null,
      iopLe: readings.LE.length ? readings.LE[readings.LE.length - 1] : null,
    };
  });
}

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export async function getOptometryReport(id, from, to) {
  const supabase = await createClient();

  if (id === 'register') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'created_at');
    rows.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    return {
      title: 'Daily Assessment Register',
      headers: ['Date/Time', 'Patient', 'Visit', 'VA RE', 'VA LE', 'IOP RE', 'IOP LE', 'Status', 'By'],
      rows: rows.map((r) => ({
        cols: [
          new Date(r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }),
          `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
          r.visits?.visit_number || '--',
          r.re_dist_unaided || '--',
          r.le_dist_unaided || '--',
          r.iopRe ?? '--',
          r.iopLe ?? '--',
          r.status,
          r.completed_by_profile?.full_name || '--',
        ],
      })),
      total: null,
    };
  }

  if (id === 'va_distribution') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const tally = {};
    rows.forEach((r) => {
      [r.re_dist_unaided, r.le_dist_unaided].forEach((v) => {
        if (!v) return;
        tally[v] = (tally[v] || 0) + 1;
      });
    });
    const sorted = Object.entries(tally).sort((a, b) => b[1] - a[1]);
    return {
      title: 'VA Distribution (Unaided, both eyes) -- Completed Assessments',
      headers: ['VA Value', 'Count'],
      rows: sorted.map(([val, count]) => ({ cols: [val, count] })),
      total: null,
    };
  }

  if (id === 'iop_surveillance') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const withReadings = rows.filter((r) => r.iopRe !== null || r.iopLe !== null);
    withReadings.sort((a, b) => Math.max(b.iopRe || 0, b.iopLe || 0) - Math.max(a.iopRe || 0, a.iopLe || 0));
    return {
      title: 'IOP Surveillance -- Completed Assessments',
      headers: ['Patient', 'Visit', 'IOP RE', 'IOP LE', 'Flag'],
      rows: withReadings.map((r) => {
        const high = (r.iopRe && r.iopRe > 21) || (r.iopLe && r.iopLe > 21);
        const warn = !high && ((r.iopRe && r.iopRe > 18) || (r.iopLe && r.iopLe > 18));
        return {
          cols: [
            `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
            r.visits?.visit_number || '--',
            r.iopRe ?? '--',
            r.iopLe ?? '--',
            high ? 'ELEVATED' : warn ? 'Borderline' : 'Normal',
          ],
        };
      }),
      total: null,
    };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

PYEOF_2348177055663470064

cat > "app/(main)/optometry/[id]/optometry-workspace.js" << 'PYEOF_2808488633758329437'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getAssessmentWorkspaceData,
  saveDraft,
  completeAssessment,
  updateCompletedAssessment,
  addIopReading,
} from '@/app/(main)/optometry/actions';
import { getIopMethods, getClinicalObservations } from '@/app/(main)/master-data/actions';

const VA_SNELLEN = ['6/6', '6/9', '6/12', '6/18', '6/24', '6/36', '6/60', '3/60', '2/60', '1/60'];
const VA_SPECIAL = ['CF', 'HM', 'PL', 'NPL'];
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen',
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1: '', add_k2: '', add_axial_length: '', add_pachymetry: '', add_white_to_white: '', add_schirmer: '',
    add_color_vision: '', add_ocular_motility: '', add_syringing: '',
    observation_chips: [], observations_text: '',
    section_va_done: false, section_refraction_done: false, section_iop_done: false, section_additional_done: false, section_obs_done: false,
  };
  VA_FIELDS.forEach((f2) => { f[f2.key] = ''; });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['sph', 'cyl', 'axis'].forEach((p) => { f[`ref_${type}_${eye}_${p}`] = ''; });
      if (type === 'final') f[`ref_${type}_${eye}_add`] = '';
    });
  });
  return f;
}

function AsmtSection({ id, num, color, title, badge, badgeCls, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
          <span className={`badge ${badgeCls}`}>{badge}</span>
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

function VaOptPills({ values, selected, onSelect, disabled }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 6 }}>
      {values.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px solid ${selected === v ? 'var(--teal)' : 'var(--g200)'}`,
            background: selected === v ? 'var(--teal)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
      {VA_SPECIAL.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px dashed ${selected === v ? 'var(--amber)' : 'var(--g200)'}`,
            borderStyle: selected === v ? 'solid' : 'dashed',
            background: selected === v ? 'var(--amber)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
    </div>
  );
}

export default function OptometryWorkspace({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ va: true, refraction: false, iop: false, additional: false, obs: false });
  const [refTab, setRefTab] = useState('obj');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');

  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [iopMethods, setIopMethods] = useState([]);
  const [obsChips, setObsChips] = useState([]);
  const router = useRouter();

  function load() {
    getAssessmentWorkspaceData(queueEntryId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setEntry(result.entry);
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setLocked(result.locked);

      const f = emptyForm();
      Object.keys(f).forEach((key) => {
        if (result.assessment[key] !== null && result.assessment[key] !== undefined) f[key] = result.assessment[key];
      });
      setForm(f);
    });
  }

  useEffect(() => { load(); }, [queueEntryId]);

  useEffect(() => {
    getIopMethods().then((all) => setIopMethods(all.filter((m) => m.status === 'Active')));
    getClinicalObservations().then((all) => setObsChips(all.filter((o) => o.status === 'Active')));
  }, []);

  const isEdit = assessment?.status === 'Completed';

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function setVa(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_va_done: true }));
  }

  function setRef(type, eye, part, value) {
    setForm((prev) => ({ ...prev, [`ref_${type}_${eye}_${part}`]: value, section_refraction_done: true }));
  }

  function toggleObsChip(chip) {
    setForm((prev) => {
      const has = prev.observation_chips.includes(chip);
      return {
        ...prev,
        observation_chips: has ? prev.observation_chips.filter((c) => c !== chip) : [...prev.observation_chips, chip],
        section_obs_done: true,
      };
    });
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value) return;
    const result = await addIopReading(assessment.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setForm((prev) => ({ ...prev, section_iop_done: true }));
    // Append the new reading locally rather than calling load() -- a
    // full reload would overwrite any not-yet-saved edits sitting in
    // other sections (VA, refraction, additional measurements) with
    // whatever's still on the server, silently discarding them.
    setIopReadings((prev) => [...prev, result.reading]);
  }

  async function handleSaveDraft() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await saveDraft(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in Optometry Queue.');
    load();
  }

  async function handleComplete() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await completeAssessment(assessment.id, queueEntryId, form);
    setSaving(false);
    if (result.error) {
      setError(result.error);
      if (!openSections.va) toggleSection('va');
      return;
    }
    setOkMsg('Assessment completed -- routed to Doctor Queue.');
    setTimeout(() => router.push('/optometry-dashboard'), 1200);
  }

  async function handleUpdate() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateCompletedAssessment(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Changes saved.');
    load();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!entry || !assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = entry.visits?.patients;
  const doneCount = ['section_va_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done', 'section_obs_done'].filter((k) => form[k]).length;
  const vaScaleValues = vaValuesForScale(form.va_scale);

  const reIopSorted = iopReadings.filter((r) => r.eye === 'RE');
  const leIopSorted = iopReadings.filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  return (
    <div>
      {/* PATIENT STRIP */}
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>Token {entry.token}</span>
          </div>
        </div>
      </div>

      {/* WORKFLOW PANEL */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#5eead4', boxShadow: '0 0 6px #5eead4', flexShrink: 0 }}></div>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#5eead4' }}>
          {locked ? 'Locked -- Doctor Reviewing' : isEdit ? 'Assessment Completed -- Editable' : 'Optometry -- In Progress'}
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 10, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.4px' }}>Assessment progress</div>
            <div style={{ fontSize: 13, fontWeight: 700, color: '#e2e8f0' }}>{doneCount} / 5 sections</div>
            <div style={{ height: 6, borderRadius: 3, background: 'var(--g200)', width: 160, marginTop: 4, overflow: 'hidden' }}>
              <div style={{ height: '100%', borderRadius: 3, background: 'var(--teal)', width: `${(doneCount / 5) * 100}%`, transition: 'width .3s' }}></div>
            </div>
          </div>
          {!locked && (
            <div style={{ display: 'flex', gap: 6 }}>
              {!isEdit && (
                <>
                  <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.1)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSaveDraft} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> Save Draft
                  </button>
                  <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleComplete} disabled={saving}>
                    <i className="ti ti-circle-check"></i> Complete Assessment
                  </button>
                </>
              )}
              {isEdit && (
                <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleUpdate} disabled={saving}>
                  <i className="ti ti-device-floppy"></i> Save Changes
                </button>
              )}
            </div>
          )}
        </div>
      </div>

      {locked && (
        <div className="msg-err" style={{ marginBottom: 12 }}>
          <i className="ti ti-lock"></i> The doctor has already started this consultation. Shown here for reference only -- no further edits.
        </div>
      )}
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={1} color="var(--teal)" title="Visual Acuity" badge={form.section_va_done ? 'Done' : 'Not started'} badgeCls={form.section_va_done ? 'b-green' : 'b-gray'}
          open={openSections.va} onToggle={() => toggleSection('va')}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => !locked && setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaOptPills values={vaScaleValues} selected={form[f.key]} onSelect={(v) => setVa(f.key, v)} disabled={locked} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={2} color="var(--blue)" title="Refraction" badge={form.section_refraction_done ? 'Done' : 'Not started'} badgeCls={form.section_refraction_done ? 'b-green' : 'b-gray'}
          open={openSections.refraction} onToggle={() => toggleSection('refraction')}
        >
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {[['obj', 'Objective (Auto-Rx)'], ['subj', 'Subjective'], ['final', 'Final Rx']].map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>

          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            {refTab === 'obj' ? 'Auto-refractometer values. Review before finalizing.' : refTab === 'subj' ? 'Values obtained during subjective refraction with trial lenses.' : 'Final accepted refraction used for prescription / optical order.'}
          </div>

          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead>
              <tr>
                <th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{refTab === 'final' && <th>ADD (near)</th>}
              </tr>
            </thead>
            <tbody>
              {['re', 'le'].map((eye) => (
                <tr key={eye}>
                  <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_sph`]} onChange={(e) => setRef(refTab, eye, 'sph', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_cyl`]} onChange={(e) => setRef(refTab, eye, 'cyl', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_axis`]} onChange={(e) => setRef(refTab, eye, 'axis', e.target.value)} placeholder="--" /></td>
                  {refTab === 'final' && (
                    <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_add`]} onChange={(e) => setRef(refTab, eye, 'add', e.target.value)} placeholder="--" /></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Pupillary Distance (PD)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" />
            </div>
            <div>
              <label className="flbl">Vertex Distance (optional)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" />
            </div>
          </div>

          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-info-circle"></i> Device-imported values should be reviewed before finalizing. All 3 refraction types are recorded independently.
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={3} color="var(--purple)" title="Intraocular Pressure" badge={form.section_iop_done ? 'Done' : 'Not started'} badgeCls={form.section_iop_done ? 'b-green' : 'b-gray'}
          open={openSections.iop} onToggle={() => toggleSection('iop')}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" disabled={locked} value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {iopMethods.map((m) => <option key={m.id}>{m.name}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" disabled={locked} value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIopSorted, reIopInput, setReIopInput], ['LE', leIopSorted, leIopInput, setLeIopInput]].map(([eye, list, val, setVal]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings yet</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
                {!locked && (
                  <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                    <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                    <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                  </div>
                )}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={4} color="var(--amber)" title="Additional Measurements" badge={form.section_additional_done ? 'Done' : 'Not started'} badgeCls={form.section_additional_done ? 'b-green' : 'b-gray'}
          open={openSections.additional} onToggle={() => toggleSection('additional')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 12 }}>Complete only the measurements relevant to this visit.</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><input className="fi fi-sm" disabled={locked} value={form.add_k1} onChange={(e) => setField('add_k1', e.target.value)} placeholder="e.g. 43.50 D" /></div>
            <div><label className="flbl">Keratometry K2</label><input className="fi fi-sm" disabled={locked} value={form.add_k2} onChange={(e) => setField('add_k2', e.target.value)} placeholder="e.g. 44.25 D" /></div>
            <div><label className="flbl">Axial Length</label><input className="fi fi-sm" disabled={locked} value={form.add_axial_length} onChange={(e) => setField('add_axial_length', e.target.value)} placeholder="e.g. 23.2 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><input className="fi fi-sm" disabled={locked} value={form.add_pachymetry} onChange={(e) => setField('add_pachymetry', e.target.value)} placeholder="e.g. 542 microns" /></div>
            <div><label className="flbl">White-to-White</label><input className="fi fi-sm" disabled={locked} value={form.add_white_to_white} onChange={(e) => setField('add_white_to_white', e.target.value)} placeholder="e.g. 11.8 mm" /></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><input className="fi fi-sm" disabled={locked} value={form.add_schirmer} onChange={(e) => setField('add_schirmer', e.target.value)} placeholder="e.g. 8/6 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div>
              <label className="flbl">Color vision</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_color_vision} onChange={(e) => setField('add_color_vision', e.target.value)}>
                <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
              </select>
            </div>
            <div>
              <label className="flbl">Ocular motility</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_ocular_motility} onChange={(e) => setField('add_ocular_motility', e.target.value)}>
                <option value="">Not tested</option><option>Full in all directions</option><option>Restricted</option><option>Nystagmus present</option>
              </select>
            </div>
            <div>
              <label className="flbl">Syringing</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_syringing} onChange={(e) => setField('add_syringing', e.target.value)}>
                <option value="">Not done</option><option>Patent RE</option><option>Patent LE</option><option>Patent bilateral</option><option>Block RE</option><option>Block LE</option>
              </select>
            </div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={5} color="var(--g500)" title="Clinical Observations" badge={form.section_obs_done ? 'Done' : 'Not started'} badgeCls={form.section_obs_done ? 'b-green' : 'b-gray'}
          open={openSections.obs} onToggle={() => toggleSection('obs')}
        >
          <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-alert-triangle"></i> Observations shall be descriptive only. No diagnoses or interpretations permitted here.
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
            {obsChips.map((o) => (
              <div
                key={o.id}
                onClick={() => !locked && toggleObsChip(o.name)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.observation_chips.includes(o.name) ? 'var(--teal)' : 'var(--g200)'}`, background: form.observation_chips.includes(o.name) ? 'var(--teal)' : '#fff', color: form.observation_chips.includes(o.name) ? '#fff' : 'var(--g600)' }}
              >
                {o.name}
              </div>
            ))}
          </div>
          <label className="flbl">Additional observations (descriptive -- no diagnoses)</label>
          <textarea className="fi" disabled={locked} rows={2} value={form.observations_text} onChange={(e) => setField('observations_text', e.target.value)} placeholder="e.g. Patient had difficulty with right eye assessment due to glare sensitivity..." />
        </AsmtSection>
      </div>

      {/* AUDIT LOG */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
        {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
        {auditLog.map((a) => (
          <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8 }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
            <span>{a.message}</span>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}


PYEOF_2808488633758329437

cat > "app/(main)/ot-intraop/page.js" << 'PYEOF_197897931832989053'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOTCaseList, getOTIntraopHistory, markPatientReported, unmarkPatientReported } from './actions';
import Workspace from './workspace';

const STATUS_BADGE = { Scheduled: 'b-amber', 'In Progress': 'b-blue' };

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--red)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ cases, loading, onOpen, onRefresh }) {
  const [busyId, setBusyId] = useState(null);

  async function handleToggleReported(e, otId, currentlyReported) {
    e.stopPropagation();
    setBusyId(otId);
    if (currentlyReported) await unmarkPatientReported(otId);
    else await markPatientReported(otId);
    setBusyId(null);
    onRefresh();
  }

  const counts = {
    Scheduled: cases.filter((c) => c.status === 'Scheduled').length,
    'In Progress': cases.filter((c) => c.status === 'In Progress').length,
  };

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Scheduled, not checked in</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Scheduled}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In Progress</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts['In Progress']}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Total open cases</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--red)' }}></i> Today&apos;s OT Cases</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--red)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status}</span>
                <button
                  type="button"
                  className={`badge ${c.patient_reported_at ? 'b-green' : 'b-gray'}`}
                  style={{ marginLeft: 6, fontSize: 10, border: 'none', cursor: 'pointer' }}
                  disabled={busyId === c.id}
                  onClick={(e) => handleToggleReported(e, c.id, !!c.patient_reported_at)}
                  title={c.patient_reported_at ? `Reported at ${new Date(c.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Click to mark patient as reported'}
                >
                  {busyId === c.id ? '...' : c.patient_reported_at ? 'Reported' : 'Mark Reported'}
                </button>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No OT cases scheduled for today.</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((r) => {
        const q = search.trim().toLowerCase();
        const patient = r.surgical_cases?.patients;
        return `${patient?.first_name} ${patient?.last_name}`.toLowerCase().includes(q) || (patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Completed OT Cases</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Date</th><th>Patient</th><th>Procedure</th><th>Outcome</th><th>Completed By</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => {
              const sc = r.surgical_cases;
              const patient = sc?.patients;
              return (
                <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td><strong>{patient?.first_name} {patient?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>{sc?.procedure_name} ({sc?.eye})</td>
                  <td><span className="badge b-green" style={{ fontSize: 10 }}>{r.intraopSummary?.surgical_outcome || '--'}</span></td>
                  <td style={{ fontSize: 12 }}>{r.intraopSummary?.completedByName || '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              );
            })}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function OTIntraopPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getOTIntraopHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-building-hospital" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} />}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

PYEOF_197897931832989053

cat > "app/(main)/ot-intraop/workspace.js" << 'PYEOF_7329222430778202908'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  getOTCaseDetail,
  saveCheckinItems, completeCheckin, recordAnaesthesia, saveIntraopDraft,
  addConsumable, removeConsumable, addIntraopEvent, removeIntraopEvent,
  completeSurgery, getConsumableOptions, markPatientReported, unmarkPatientReported,
} from './actions';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { uploadAttachment, deleteAttachment } from '@/lib/attachments';

const STEPS = ['Check-In', 'Anaesthesia', 'Surgery', 'Implant', 'Recovery'];
const EVENT_QUICK = ['Small Pupil', 'Zonular Weakness', 'Difficult Capsulorhexis', 'Iris Prolapse', 'Floppy Iris Syndrome'];
const COMPL_QUICK = ['Posterior Capsular Rupture', 'Dropped Nucleus', 'Vitreous Loss', 'Wound Leak', 'Endothelial Trauma'];
const CONSENT_INDEX = CHECKIN_ITEMS.indexOf('Consent availability verified');

function fmtTime(secs) {
  const m = String(Math.floor(secs / 60)).padStart(2, '0');
  const s = String(secs % 60).padStart(2, '0');
  return `${m}:${s}`;
}

export default function Workspace({ otScheduleId, onBack }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [log, setLog] = useState([]);
  const [seconds, setSeconds] = useState(0);
  const timerRef = useRef(null);

  const [checkinChecked, setCheckinChecked] = useState({});
  const [uploadingKey, setUploadingKey] = useState(null);
  const [subTab, setSubTab] = useState('checkin');
  const initializedTabRef = useRef(false);

  const [anaesType, setAnaesType] = useState('Topical');
  const [anaesDoctor, setAnaesDoctor] = useState('');
  const [anaesStart, setAnaesStart] = useState('');
  const [anaesEnd, setAnaesEnd] = useState('');
  const [anaesRemarks, setAnaesRemarks] = useState('');

  const [imMfr, setImMfr] = useState('');
  const [imModel, setImModel] = useState('');
  const [imPower, setImPower] = useState('');
  const [imSerial, setImSerial] = useState('');
  const [imExpiry, setImExpiry] = useState('');
  const [imEye, setImEye] = useState('OD');
  const [varianceReason, setVarianceReason] = useState('');

  const [consumableName, setConsumableName] = useState('');
  const [consumableOptions, setConsumableOptions] = useState([]);
  const [checkinConsumableId, setCheckinConsumableId] = useState('');
  const [eventName, setEventName] = useState('');
  const [eventSeverity, setEventSeverity] = useState('Mild');
  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [opNotes, setOpNotes] = useState('');
  const [surgicalOutcome, setSurgicalOutcome] = useState('Successful');
  const [outcomeRemarks, setOutcomeRemarks] = useState('');

  const [recoveryDest, setRecoveryDest] = useState('Recovery Bay 1');
  const [recoveryMonitor, setRecoveryMonitor] = useState('');
  const [recoveryInstructions, setRecoveryInstructions] = useState('');
  const [recoveryConcerns, setRecoveryConcerns] = useState('');
  const [saving, setSaving] = useState(false);

  function addLog(msg) {
    setLog((prev) => [`${new Date().toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })} -- ${msg}`, ...prev].slice(0, 20));
  }

  const refresh = useCallback(async () => {
    const result = await getOTCaseDetail(otScheduleId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    if (!initializedTabRef.current) {
      initializedTabRef.current = true;
      if (result.intraop?.checkin_completed_at || result.booking.status === 'Completed') setSubTab('intraop');
    }
    const io = result.intraop;
    if (io) {
      setCheckinChecked(io.checkin_items || {});
      setAnaesType(io.anaesthesia_type || 'Topical');
      setAnaesDoctor(io.anaesthetist || '');
      setAnaesStart(io.anaesthesia_start || '');
      setAnaesEnd(io.anaesthesia_end || '');
      setAnaesRemarks(io.anaesthesia_remarks || '');
      setImMfr(io.implant_manufacturer || '');
      setImModel(io.implant_model || '');
      setImPower(io.implant_power || result.biometryPlans[0]?.final_iol_power || '');
      setImSerial(io.implant_serial || '');
      setImExpiry(io.implant_expiry || '');
      setImEye(io.implant_eye || result.booking.surgical_cases.eye || 'OD');
      setVarianceReason(io.variance_reason || '');
      setOpNotes(io.operative_notes || '');
      setSurgicalOutcome(io.surgical_outcome || 'Successful');
      setOutcomeRemarks(io.outcome_remarks || '');
      setRecoveryDest(io.recovery_destination || 'Recovery Bay 1');
      setRecoveryMonitor(io.recovery_monitoring || '');
      setRecoveryInstructions(io.recovery_instructions || '');
      setRecoveryConcerns(io.recovery_concerns || '');
    } else {
      setImPower(result.biometryPlans[0]?.final_iol_power || '');
      setImEye(result.booking.surgical_cases.eye || 'OD');
    }
  }, [otScheduleId]);

  useEffect(() => {
    refresh();
    getConsumableOptions().then(setConsumableOptions);
    initializedTabRef.current = false;
    setSubTab('checkin');
    setSeconds(0);
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(timerRef.current);
  }, [otScheduleId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const { booking, biometryPlans, intraop, consumables, events, complications, consentForms } = data;
  const sc = booking.surgical_cases;
  const patient = sc.patients;
  const isCompleted = booking.status === 'Completed';
  const currentStep = isCompleted ? 4 : intraop?.checkin_completed_at ? (intraop?.anaesthesia_recorded_at ? (intraop?.completed_at ? 4 : 2) : 1) : 0;

  const requiredConsentsOk = CONSENT_FORM_TYPES.filter((f) => f.required).every((f) => consentForms[f.key]);
  const manualCheckinDone = CHECKIN_ITEMS.filter((_, i) => i !== CONSENT_INDEX).every((_, i) => {
    const realIdx = i >= CONSENT_INDEX ? i + 1 : i;
    return checkinChecked[realIdx];
  });

  async function handleUploadConsent(key, file) {
    if (!file) return;
    setUploadingKey(key);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', `ot_consent_${key}`);
    formData.append('entityId', otScheduleId);
    const result = await uploadAttachment(formData);
    setUploadingKey(null);
    if (result.error) { setError(result.error); return; }
    addLog(`Consent uploaded: ${CONSENT_FORM_TYPES.find((f) => f.key === key)?.label}`);
    refresh();
  }

  async function handleRemoveConsent(key) {
    const file = consentForms[key];
    if (!file) return;
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  function toggleCheckinItem(i) {
    if (i === CONSENT_INDEX) return;
    const updated = { ...checkinChecked, [i]: !checkinChecked[i] };
    setCheckinChecked(updated);
    saveCheckinItems(otScheduleId, sc.id, updated);
  }

  async function handleToggleReported() {
    if (booking.patient_reported_at) await unmarkPatientReported(otScheduleId);
    else { await markPatientReported(otScheduleId); addLog('Patient marked as reported to OT'); }
    refresh();
  }

  async function handleCompleteCheckin() {
    setError('');
    const result = await completeCheckin(otScheduleId, sc.id);
    if (result.error) { setError(result.error); return; }
    addLog('OT Check-In completed');
    setOk('Check-in complete -- patient confirmed in OT.');
    await refresh();
    setSubTab('intraop');
  }

  async function handleRecordAnaesthesia() {
    setError('');
    const result = await recordAnaesthesia(otScheduleId, sc.id, { type: anaesType, doctor: anaesDoctor, start: anaesStart, end: anaesEnd, remarks: anaesRemarks });
    if (result.error) { setError(result.error); return; }
    addLog(`Anaesthesia recorded: ${anaesType}`);
    refresh();
  }

  async function handleAddConsumable(name) {
    const value = name || consumableName;
    if (!value.trim()) return;
    await addConsumable(otScheduleId, value);
    setConsumableName('');
    addLog(`Consumable: ${value}`);
    refresh();
  }

  async function handleAddEvent() {
    if (!eventName.trim()) return;
    const result = await addIntraopEvent(otScheduleId, { kind: 'Event', name: eventName, severity: eventSeverity });
    if (result.error) { setError(result.error); return; }
    setEventName('');
    addLog(`Event: ${eventName} (${eventSeverity})`);
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addIntraopEvent(otScheduleId, { kind: 'Complication', name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    addLog(`COMPLICATION: ${complName} (${complSeverity})`);
    refresh();
  }

  async function handleSaveDraft() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveIntraopDraft(otScheduleId, sc.id, {
      implant_manufacturer: imMfr || null, implant_model: imModel || null,
      implant_power: imPower || null, implant_serial: imSerial || null, implant_expiry: imExpiry || null,
      implant_eye: imEye, variance_reason: varianceReason || null, operative_notes: opNotes || null,
      surgical_outcome: surgicalOutcome || null, outcome_remarks: outcomeRemarks || null,
      recovery_destination: recoveryDest || null, recovery_monitoring: recoveryMonitor || null,
      recovery_instructions: recoveryInstructions || null, recovery_concerns: recoveryConcerns || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    addLog('Draft saved');
    setOk('Draft saved -- documentation preserved.');
    refresh();
  }

  const plannedPower = biometryPlans[0]?.final_iol_power;
  const variancePresent = plannedPower && imPower && String(plannedPower) !== String(imPower);

  async function handleCompleteSurgery() {
    setError(''); setOk('');
    const result = await completeSurgery(otScheduleId, sc.id, {
      implantPower: imPower, implantSerial: imSerial, implantManufacturer: imMfr, implantModel: imModel, implantExpiry: imExpiry, implantEye: imEye,
      skipImplant: biometryPlans.length === 0,
      recoveryInstructions, recoveryDestination: recoveryDest, recoveryMonitoring: recoveryMonitor, recoveryConcerns,
      variancePresent, varianceReason,
      operativeNotes: opNotes, surgicalOutcome, outcomeRemarks,
    });
    if (result.error) { setError(result.error); return; }
    clearInterval(timerRef.current);
    addLog('SURGERY COMPLETED -- OT Case marked complete, handed over to Recovery');
    setOk('Surgery completed and handed over to Recovery. Case marked Completed in OT Scheduling.');
    refresh();
  }

  return (
    <div>
      <div style={{ background: isCompleted ? 'linear-gradient(135deg,#14532d,#157a4f)' : 'linear-gradient(135deg,#7f1d1d,#991b1b)', borderRadius: 12, padding: '11px 18px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{booking.id.slice(0, 8)}</div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name} -- {booking.master_ot_sessions?.name}</div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isCompleted ? 'Surgery Completed' : booking.status}</span>
          {!isCompleted && (
            <button
              type="button"
              className="btn btn-sm"
              style={{
                borderColor: 'rgba(255,255,255,.3)',
                background: booking.patient_reported_at ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.1)',
                color: '#fff',
              }}
              onClick={handleToggleReported}
              title={booking.patient_reported_at ? `Reported at ${new Date(booking.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Mark patient as reported to OT'}
            >
              <i className={`ti ${booking.patient_reported_at ? 'ti-check' : 'ti-door-enter'}`}></i> {booking.patient_reported_at ? 'Patient Reported' : 'Mark Reported'}
            </button>
          )}
          {!isCompleted && (
            <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '6px 12px' }}>
              <div style={{ fontSize: 9, opacity: .7, textTransform: 'uppercase' }}>OT Duration</div>
              <div style={{ fontSize: 17, fontWeight: 700, fontFamily: 'monospace' }}>{fmtTime(seconds)}</div>
            </div>
          )}
          <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
        </div>
      </div>

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '210px 1fr 220px', gap: 14 }}>
        {/* LEFT: Timeline */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 10 }}>OT Timeline</div>
            {STEPS.map((s, i) => (
              <div key={s} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0', borderBottom: i < STEPS.length - 1 ? '1px solid var(--g100)' : 'none' }}>
                <div style={{ width: 26, height: 26, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, flexShrink: 0, border: '2px solid', borderColor: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : 'var(--g200)', background: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : '#fff', color: i <= currentStep ? '#fff' : 'var(--g300)' }}>
                  <i className={`ti ${i < currentStep ? 'ti-check' : i === currentStep ? 'ti-player-play' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
                </div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{s}</div>
              </div>
            ))}
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Event log</div>
            <div style={{ fontSize: 10, color: 'var(--g500)', maxHeight: 200, overflowY: 'auto' }}>
              {log.map((l, i) => <div key={i} style={{ padding: '3px 0', borderBottom: '1px solid var(--g100)' }}>{l}</div>)}
            </div>
          </div>
        </div>

        {/* CENTER: sections */}
        <div>
          {/* Big-visibility case summary */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--red)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-scalpel"></i> Procedure</div>
              <div style={{ fontSize: 15, fontWeight: 700, lineHeight: 1.2 }}>{sc.procedure_name}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--blue)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-eye"></i> Eye</div>
              <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--blue)' }}>{sc.eye}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--green)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-package"></i> Package</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2, color: sc.master_packages ? 'inherit' : 'var(--g400)' }}>{sc.master_packages?.name || 'No package'}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--indigo)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-stethoscope"></i> Surgeon</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2 }}>{sc.profiles?.full_name || 'Not assigned'}</div>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <button
              type="button"
              onClick={() => setSubTab('checkin')}
              style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'checkin' ? '#fff' : 'transparent', color: subTab === 'checkin' ? 'var(--red)' : 'var(--g500)', cursor: 'pointer', boxShadow: subTab === 'checkin' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
            >
              <i className="ti ti-clipboard-check"></i> Patient Check-In
            </button>
            <button
              type="button"
              onClick={() => (intraop?.checkin_completed_at || isCompleted) && setSubTab('intraop')}
              disabled={!intraop?.checkin_completed_at && !isCompleted}
              title={!intraop?.checkin_completed_at && !isCompleted ? 'Complete Patient Check-In first' : ''}
              style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'intraop' ? '#fff' : 'transparent', color: !intraop?.checkin_completed_at && !isCompleted ? 'var(--g300)' : subTab === 'intraop' ? 'var(--red)' : 'var(--g500)', cursor: !intraop?.checkin_completed_at && !isCompleted ? 'not-allowed' : 'pointer', boxShadow: subTab === 'intraop' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
            >
              <i className="ti ti-building-hospital"></i> Intraoperative Management {!intraop?.checkin_completed_at && !isCompleted && <i className="ti ti-lock" style={{ fontSize: 10 }}></i>}
            </button>
          </div>

          {subTab === 'checkin' && (
          <>
          {/* Consent Forms */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-file-check" style={{ color: 'var(--green)' }}></i> Consent Forms</div>
              <span className={`badge ${requiredConsentsOk ? 'b-green' : 'b-gray'}`}>{CONSENT_FORM_TYPES.filter((f) => f.required && consentForms[f.key]).length}/{CONSENT_FORM_TYPES.filter((f) => f.required).length}</span>
            </div>
            {CONSENT_FORM_TYPES.map((f) => {
              const file = consentForms[f.key];
              return (
                <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, border: '2px solid var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, background: file ? 'var(--green)' : '#fff', borderColor: file ? 'var(--green)' : 'var(--g300)' }}>
                    {file && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12.5, fontWeight: 600 }}>{f.label} {!f.required && <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(optional)</span>}</div>
                    <div style={{ fontSize: 11, color: file ? 'var(--g500)' : 'var(--g400)', marginTop: 1 }}>
                      {file ? <><i className="ti ti-paperclip"></i> {file.file_name}</> : 'Not uploaded yet'}
                    </div>
                  </div>
                  {file ? (
                    <div style={{ display: 'flex', gap: 4 }}>
                      {file.url && <a href={file.url} target="_blank" rel="noopener noreferrer" className="btn btn-sm">View</a>}
                      <button className="btn btn-sm" onClick={() => handleRemoveConsent(f.key)}><i className="ti ti-x"></i></button>
                    </div>
                  ) : (
                    <label className="btn btn-sm btn-primary" style={{ cursor: 'pointer', marginBottom: 0 }}>
                      {uploadingKey === f.key ? 'Uploading...' : <><i className="ti ti-upload"></i> Upload</>}
                      <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadConsent(f.key, e.target.files?.[0])} disabled={uploadingKey === f.key} />
                    </label>
                  )}
                </div>
              );
            })}
          </div>

          {/* Check-In */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--blue)' }}></i> OT Check-In</div>
              <span className={`badge ${intraop?.checkin_completed_at ? 'b-green' : 'b-gray'}`}>{intraop?.checkin_completed_at ? 'Complete' : `${Object.values(checkinChecked).filter(Boolean).length}/${CHECKIN_ITEMS.length}`}</span>
            </div>
            {CHECKIN_ITEMS.map((item, i) => (
              i === CONSENT_INDEX ? (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', background: requiredConsentsOk ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: requiredConsentsOk ? 'var(--green)' : '#fff', border: '2px solid', borderColor: requiredConsentsOk ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{requiredConsentsOk && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item} <span style={{ fontSize: 10, color: 'var(--g400)' }}>(auto -- from Consent Forms above)</span></span>
                </div>
              ) : (
                <div key={i} onClick={() => !isCompleted && toggleCheckinItem(i)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isCompleted ? 'default' : 'pointer', background: checkinChecked[i] ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: checkinChecked[i] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checkinChecked[i] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checkinChecked[i] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item}</span>
                </div>
              )
            ))}
            {!intraop?.checkin_completed_at && !isCompleted && (!manualCheckinDone || !requiredConsentsOk) && (
              <div style={{ fontSize: 11, color: 'var(--amber)', marginTop: 8 }}>
                <i className="ti ti-info-circle"></i> Complete all items above{!requiredConsentsOk ? ' and upload required consent forms' : ''} to check in.
              </div>
            )}
          </div>

          {/* Implant Verification */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-disc" style={{ color: 'var(--indigo)' }}></i> Implant Verification</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr auto 1fr', gap: 10, marginBottom: 10, alignItems: 'center' }}>
              <div style={{ border: '1.5px solid var(--g200)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Approved IOL Plan</div>
                {biometryPlans.length > 0 ? biometryPlans.map((p) => (
                  <div key={p.id} style={{ fontSize: 11, marginBottom: 4 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span style={{ color: 'var(--g500)' }}>Power ({p.surgical_eye})</span><strong>{p.final_iol_power} D</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between' }}><span style={{ color: 'var(--g500)' }}>Formula</span><strong>{p.selected_formula}</strong></div>
                  </div>
                )) : <div style={{ fontSize: 11, color: 'var(--g400)' }}>No IOL plan (non-IOL procedure)</div>}
              </div>
              <i className="ti ti-arrow-right" style={{ color: 'var(--g400)' }}></i>
              <div style={{ border: '1.5px solid', borderColor: variancePresent ? 'var(--red)' : 'var(--green)', background: variancePresent ? 'var(--red-lt)' : 'var(--green-lt)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Actual Implanted IOL</div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11 }}><span style={{ color: 'var(--g500)' }}>Power</span><strong>{imPower || '--'} D</strong></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11 }}><span style={{ color: 'var(--g500)' }}>Match</span><strong style={{ color: variancePresent ? 'var(--red)' : 'var(--green)' }}>{variancePresent ? 'VARIANCE' : 'Matches plan'}</strong></div>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Manufacturer</label><input className="fi fi-sm" value={imMfr} onChange={(e) => setImMfr(e.target.value)} disabled={isCompleted} /></div>
              <div><label className="flbl">Model</label><input className="fi fi-sm" value={imModel} onChange={(e) => setImModel(e.target.value)} disabled={isCompleted} /></div>
              <div><label className="flbl">Power (D)</label><input className="fi fi-sm" value={imPower} onChange={(e) => setImPower(e.target.value)} disabled={isCompleted} /></div>
              <div><label className="flbl">Serial / Batch</label><input className="fi fi-sm" value={imSerial} onChange={(e) => setImSerial(e.target.value)} disabled={isCompleted} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
              <div><label className="flbl">Expiry date</label><input type="date" className="fi fi-sm" value={imExpiry} onChange={(e) => setImExpiry(e.target.value)} disabled={isCompleted} /></div>
              <div><label className="flbl">Eye implanted</label><select className="fi fi-sm" value={imEye} onChange={(e) => setImEye(e.target.value)} disabled={isCompleted}><option>OD</option><option>OS</option></select></div>
            </div>
            {variancePresent && (
              <div style={{ marginTop: 8 }}>
                <label className="flbl">Variance reason (mandatory)</label>
                <input className="fi fi-sm" value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isCompleted} placeholder="Document reason for deviation..." />
              </div>
            )}
          </div>

          {/* Anaesthesia */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-injection" style={{ color: 'var(--teal)' }}></i> Anaesthesia</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Anaesthesia type</label><select className="fi fi-sm" value={anaesType} onChange={(e) => setAnaesType(e.target.value)} disabled={isCompleted}><option>Topical</option><option>Peribulbar</option><option>Retrobulbar</option><option>Local with Sedation</option><option>General</option></select></div>
              <div><label className="flbl">Anaesthetist</label><input className="fi fi-sm" value={anaesDoctor} onChange={(e) => setAnaesDoctor(e.target.value)} disabled={isCompleted} placeholder="If applicable" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Start time</label><input type="time" className="fi fi-sm" value={anaesStart} onChange={(e) => setAnaesStart(e.target.value)} disabled={isCompleted} /></div>
              <div><label className="flbl">End time</label><input type="time" className="fi fi-sm" value={anaesEnd} onChange={(e) => setAnaesEnd(e.target.value)} disabled={isCompleted} /></div>
            </div>
            <input className="fi fi-sm" value={anaesRemarks} onChange={(e) => setAnaesRemarks(e.target.value)} disabled={isCompleted} placeholder="Sedation details / special remarks..." />
            {!intraop?.anaesthesia_recorded_at && !isCompleted && (
              <button className="btn btn-sm" style={{ background: 'var(--blue)', color: '#fff', border: 'none', marginTop: 8 }} onClick={handleRecordAnaesthesia}><i className="ti ti-check"></i> Record anaesthesia</button>
            )}
            {intraop?.anaesthesia_recorded_at && <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 6 }}><i className="ti ti-check"></i> Recorded</div>}
          </div>

          {/* Surgical Consumables -- pre-op selection via dropdown from
              the Clinical Master; same underlying list as the quick-pick
              badges in Intraoperative Management. */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-box" style={{ color: 'var(--amber)' }}></i> Surgical Consumables</div>
            {!isCompleted && (
              <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                <select className="fi fi-sm" style={{ flex: 1 }} value={checkinConsumableId} onChange={(e) => setCheckinConsumableId(e.target.value)}>
                  <option value="">-- Select consumable --</option>
                  {consumableOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <button
                  className="btn btn-sm"
                  style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
                  onClick={() => {
                    const selected = consumableOptions.find((c) => c.id === checkinConsumableId);
                    if (!selected) return;
                    handleAddConsumable(selected.name);
                    setCheckinConsumableId('');
                  }}
                >
                  <i className="ti ti-plus"></i> Add
                </button>
              </div>
            )}
            {consumables.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-box" style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{c.name}</span>
                {!isCompleted && <button onClick={() => removeConsumable(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
            {consumables.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>None selected yet.</div>}
          </div>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={onBack}><i className="ti ti-arrow-left"></i> Back to Dashboard</button>
            {intraop?.checkin_completed_at || isCompleted ? (
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Checked In</span>
            ) : (
              <button className="btn btn-primary" onClick={handleCompleteCheckin} disabled={!manualCheckinDone || !requiredConsentsOk}>
                <i className="ti ti-check"></i> Check In
              </button>
            )}
          </div>
          </>
          )}

          {subTab === 'intraop' && (
          <>
          {/* Consumables */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-box" style={{ color: 'var(--amber)' }}></i> Consumables</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {consumableOptions.map((c) => <span key={c.id} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isCompleted && handleAddConsumable(c.name)}>{c.name}</span>)}
            </div>
            {!isCompleted && (
              <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} value={consumableName} onChange={(e) => setConsumableName(e.target.value)} placeholder="Consumable name..." />
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => handleAddConsumable()}><i className="ti ti-plus"></i> Add</button>
              </div>
            )}
            {consumables.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-box" style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{c.name}</span>
                {!isCompleted && <button onClick={() => removeConsumable(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Events */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Intraoperative Events</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {EVENT_QUICK.map((e) => <span key={e} className="badge b-amber" style={{ cursor: 'pointer' }} onClick={() => setEventName(e)}>{e}</span>)}
            </div>
            {!isCompleted && (
              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: 8, marginBottom: 8 }}>
                <input className="fi fi-sm" value={eventName} onChange={(e) => setEventName(e.target.value)} placeholder="Event description..." />
                <select className="fi fi-sm" value={eventSeverity} onChange={(e) => setEventSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddEvent}><i className="ti ti-plus"></i></button>
              </div>
            )}
            {events.map((e) => (
              <div key={e.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginBottom: 6, fontSize: 12, border: '1px solid var(--g200)', background: e.severity === 'Severe' ? 'var(--red-lt)' : e.severity === 'Moderate' ? 'var(--amber-lt)' : 'var(--g50)' }}>
                <div style={{ flex: 1 }}><strong>{e.name}</strong> <span className={`badge ${e.severity === 'Severe' ? 'b-red' : e.severity === 'Moderate' ? 'b-amber' : 'b-gray'}`} style={{ fontSize: 10 }}>{e.severity}</span></div>
                {!isCompleted && <button onClick={() => removeIntraopEvent(e.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Complications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Complications</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {COMPL_QUICK.map((c) => <span key={c} className="badge b-red" style={{ cursor: 'pointer' }} onClick={() => setComplName(c)}>{c}</span>)}
            </div>
            {!isCompleted && (
              <>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication..." />
                  <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management (required)" />
                  <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome (if known)" />
                </div>
                <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
              </>
            )}
            {complications.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginTop: 8, fontSize: 12, border: '1px solid var(--g200)', background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)' }}>
                <div style={{ flex: 1 }}>
                  <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
                  <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>Management: {c.management}</div>
                  {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
                </div>
                {!isCompleted && <button onClick={() => removeIntraopEvent(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Operative Notes</div>
            <textarea className="fi fi-sm" rows={3} value={opNotes} onChange={(e) => setOpNotes(e.target.value)} disabled={isCompleted} placeholder="Free-text operative narrative..." />
          </div>

          {/* Outcome */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--green)' }}></i> Surgical Outcome</div>
            <select className="fi fi-sm" value={surgicalOutcome} onChange={(e) => setSurgicalOutcome(e.target.value)} disabled={isCompleted} style={{ marginBottom: 8 }}>
              <option>Successful</option><option>Successful with Complication</option><option>Converted Procedure</option><option>Procedure Deferred</option><option>Procedure Abandoned</option>
            </select>
            <input className="fi fi-sm" value={outcomeRemarks} onChange={(e) => setOutcomeRemarks(e.target.value)} disabled={isCompleted} placeholder="Additional remarks..." />
          </div>

          {/* Recovery */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Recovery Handover</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery destination</label><select className="fi fi-sm" value={recoveryDest} onChange={(e) => setRecoveryDest(e.target.value)} disabled={isCompleted}><option>Recovery Bay 1</option><option>Recovery Bay 2</option><option>Day Care Ward</option></select></div>
              <div><label className="flbl">Required monitoring</label><input className="fi fi-sm" value={recoveryMonitor} onChange={(e) => setRecoveryMonitor(e.target.value)} disabled={isCompleted} placeholder="e.g. Vitals q15min x1hr" /></div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Post-operative instructions</label>
              <textarea className="fi fi-sm" rows={2} value={recoveryInstructions} onChange={(e) => setRecoveryInstructions(e.target.value)} disabled={isCompleted} placeholder="e.g. Eye shield overnight. Moxifloxacin QID..." />
            </div>
            <input className="fi fi-sm" value={recoveryConcerns} onChange={(e) => setRecoveryConcerns(e.target.value)} disabled={isCompleted} placeholder="Immediate concerns (if any)..." />
          </div>

          {!isCompleted && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={handleSaveDraft} disabled={saving}>
                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Draft'}
              </button>
              <button className="btn btn-primary" onClick={handleCompleteSurgery}>
                <i className="ti ti-circle-check"></i> Surgery Complete
              </button>
            </div>
          )}
          {isCompleted && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Surgery Completed</span>
            </div>
          )}
          </>
          )}
        </div>

        {/* RIGHT: status panel */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>OT Case Status</div>
            <div style={{ padding: 10, background: 'var(--blue-lt)', borderRadius: 8, textAlign: 'center' }}>
              <div style={{ fontSize: 11, color: 'var(--blue)', fontWeight: 700 }}>{STEPS[currentStep]}</div>
              <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>Step {currentStep + 1} of {STEPS.length}</div>
            </div>
          </div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Quick Stats</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Events</span><strong>{events.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Complications</span><strong style={{ color: complications.length ? 'var(--red)' : 'inherit' }}>{complications.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Consumables</span><strong>{consumables.length}</strong></div>
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Completion Checklist</div>
            {[
              { label: 'Implant information complete', done: biometryPlans.length === 0 || !!(imPower && imSerial) },
              { label: 'Recovery handover documented', done: !!recoveryInstructions },
            ].map((it) => (
              <div key={it.label} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className={`ti ${it.done ? 'ti-circle-check' : 'ti-circle'}`} style={{ color: it.done ? 'var(--green)' : 'var(--g300)' }}></i> {it.label}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

PYEOF_7329222430778202908

cat > "app/(main)/ot-postop/page.js" << 'PYEOF_174323293869365477'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPostOpCaseList, getPostOpTurnedUpToday, getPostOpHistory } from './actions';
import Workspace from './workspace';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--purple)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function daysWaiting(dischargeDate) {
  if (!dischargeDate) return 0;
  return Math.floor((new Date() - new Date(`${dischargeDate}T00:00:00`)) / (1000 * 60 * 60 * 24));
}

function PatientRow({ c, onClick, accentColor, rightLabel, actionLabel, actionIcon }) {
  const sc = c.surgical_cases;
  const patient = sc.patients;
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
      <div style={{ width: 34, height: 34, borderRadius: '50%', background: accentColor, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
        {patient?.first_name?.charAt(0)}
      </div>
      <div style={{ flex: 1 }}>
        <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
        <span className="badge b-purple" style={{ marginLeft: 8, fontSize: 10 }}>Post-op</span>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
          {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
        </div>
      </div>
      <div style={{ fontSize: 10, color: 'var(--g400)', width: 90, textAlign: 'right' }}>{rightLabel}</div>
      <button className="btn btn-sm btn-primary" style={accentColor === 'var(--green)' ? { background: 'var(--green)', borderColor: 'transparent' } : undefined}>
        <i className={`ti ${actionIcon}`}></i> {actionLabel}
      </button>
    </div>
  );
}

function TurnedUpTodayTab({ cases, loading, onOpen }) {
  return (
    <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--green)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-user-check" style={{ color: 'var(--green)' }}></i> Turned Up Today for Review
        <span className="badge b-green" style={{ marginLeft: 8 }}>{cases.length}</span>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Only patients with an actual visit today -- opens in the full workspace so you can start the review.
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
      {!loading && cases.map((c) => (
        <PatientRow
          key={c.id}
          c={c}
          onClick={() => onOpen(c.id, false)}
          accentColor="var(--green)"
          rightLabel="Checked in today"
          actionLabel="Start Review"
          actionIcon="ti-clipboard-text"
        />
      ))}
      {!loading && cases.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20, fontSize: 12.5 }}>No post-op patients have checked in yet today.</div>
      )}
    </div>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(1, 1fr)', gap: 10, marginBottom: 14, maxWidth: 260 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Open post-op episodes</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 2 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Patients Pending Review (Not Yet Checked In)</div>
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
          Read-only -- opens for viewing only. Use "Turned Up Today" above to actually start a review.
        </div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => (
          <PatientRow
            key={c.id}
            c={c}
            onClick={() => onOpen(c.id, true)}
            accentColor="var(--purple)"
            rightLabel={`${daysWaiting(c.discharge_date)}d since discharge`}
            actionLabel="View"
            actionIcon="ti-eye"
          />
        ))}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No open post-op episodes.</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Closed Episodes</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Outcome</th><th>Closed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e.id, true)} style={{ cursor: 'pointer' }}>
                <td><strong>{e.surgical_cases?.patients?.first_name} {e.surgical_cases?.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.surgical_cases?.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{e.surgical_cases?.procedure_name} ({e.surgical_cases?.eye})</td>
                <td><span className="badge b-purple" style={{ fontSize: 10 }}>{e.closure_status}</span></td>
                <td style={{ fontSize: 12 }}>{e.closure_outcome}</td>
                <td style={{ fontSize: 11 }}>{e.closed_at ? new Date(e.closed_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No closed episodes yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function PostOpPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [workspaceReadOnly, setWorkspaceReadOnly] = useState(false);
  const [cases, setCases] = useState([]);
  const [turnedUpToday, setTurnedUpToday] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingTurnedUp, setLoadingTurnedUp] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getPostOpCaseList()); setLoadingCases(false); }, []);
  const refreshTurnedUp = useCallback(async () => { setTurnedUpToday(await getPostOpTurnedUpToday()); setLoadingTurnedUp(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getPostOpHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshTurnedUp(); refreshHistory(); }, [refreshCases, refreshTurnedUp, refreshHistory]);

  function openCase(id, readOnly) {
    setSelectedId(id);
    setWorkspaceReadOnly(!!readOnly);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-list" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && (
        <>
          <TurnedUpTodayTab cases={turnedUpToday} loading={loadingTurnedUp} onOpen={openCase} />
          <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />
        </>
      )}
      {activeTab === 'workspace' && selectedId && (
        <Workspace episodeId={selectedId} readOnly={workspaceReadOnly} onBack={handleBack} onUpdate={handleUpdate} />
      )}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}
PYEOF_174323293869365477

cat > "app/(main)/ot-postop/workspace.js" << 'PYEOF_525439674637007921'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostOpEpisodeDetail, rescheduleFollowup, saveFollowupNotes, markFollowupStatus,
  addRecoveryComplication, closeEpisode, openFollowupReview, addFollowup, removeFollowup,
} from './actions';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';

const MILESTONES_START = [
  { key: 'recovery', label: 'Recovery', icon: 'ti-bed' },
  { key: 'discharge', label: 'Discharge', icon: 'ti-door-exit' },
];
const MILESTONES_END = [
  { key: 'closure', label: 'Episode Closure', icon: 'ti-circle-check' },
];


export default function Workspace({ episodeId, readOnly, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [editingFollowupId, setEditingFollowupId] = useState(null);
  const [editDate, setEditDate] = useState('');
  const [notesEditingId, setNotesEditingId] = useState(null);
  const [notesDraft, setNotesDraft] = useState('');
  const [attachmentsByFollowup, setAttachmentsByFollowup] = useState({});
  const [uploadingFollowupId, setUploadingFollowupId] = useState(null);
  const [saving, setSaving] = useState(false);

  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [showClose, setShowClose] = useState(false);
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const [openingReview, setOpeningReview] = useState(null);

  const [showAddFollowup, setShowAddFollowup] = useState(false);
  const [newFollowupLabel, setNewFollowupLabel] = useState('');
  const [newFollowupDate, setNewFollowupDate] = useState('');
  const [addingFollowup, setAddingFollowup] = useState(false);
  const [removingFollowupId, setRemovingFollowupId] = useState(null);

  const refresh = useCallback(async () => {
    const result = await getPostOpEpisodeDetail(episodeId);
    setData(result);
    if (!result.error && result.followups?.length > 0) {
      const entries = await Promise.all(result.followups.map(async (f) => [f.id, await getAttachments('postop_followup', f.id)]));
      setAttachmentsByFollowup(Object.fromEntries(entries));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); }, [episodeId, refresh]);

  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
  if (data.error) return <div className="msg-err">{data.error}</div>;


  const { episode, sc, followups, complications } = data;
  const patient = sc?.patients;
  const isClosed = !!episode.closure_status;
  const todayStr = new Date().toISOString().slice(0, 10);

  const milestoneStatus = (key) => {
    if (key === 'recovery') return 'done';
    if (key === 'discharge') return episode.discharge_date ? 'done' : 'pending';
    if (key === 'closure') return episode.closure_status ? 'done' : 'pending';
    return 'pending';
  };

  function startEdit(f) {
    setError('');
    setEditingFollowupId(f.id);
    setEditDate(f.scheduled_date);
  }

  function startNotesEdit(f) {
    setError('');
    setNotesEditingId(f.id);
    setNotesDraft(f.notes || '');
  }

  async function handleSaveNotesOnly(f) {
    setError('');
    setSaving(true);
    const result = await saveFollowupNotes(f.id, notesDraft);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setNotesEditingId(null);
    refresh();
  }

  async function handleUploadFollowupFile(followupId, file) {
    if (!file) return;
    setUploadingFollowupId(followupId);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', 'postop_followup');
    formData.append('entityId', followupId);
    const result = await uploadAttachment(formData);
    setUploadingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleRemoveFollowupFile(file) {
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  async function handleSaveFollowup(f) {
    setError('');
    if (!editDate || editDate === f.scheduled_date) { setEditingFollowupId(null); return; }
    setSaving(true);
    const result = await rescheduleFollowup(f.id, editDate, f.notes || '');
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEditingFollowupId(null);
    refresh();
  }

  async function handleMarkStatus(f, status) {
    setError('');
    const result = await markFollowupStatus(f.id, status);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addRecoveryComplication(episodeId, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    refresh();
  }

  async function handleOpenReview(f) {
    setError('');
    setOpeningReview(f.id);
    const result = await openFollowupReview(f.id);
    setOpeningReview(null);
    if (result.error) { setError(result.error); return; }
    // Opens in its own window (closes itself once the doctor finishes --
    // see finishAndClose() in consultation-form.js) -- poll for it
    // closing so the follow-up list refreshes without waiting on a timer.
    const win = window.open(`/consultation/${result.queueEntryId}`, 'postop-review-window');
    if (win) {
      const poll = setInterval(() => {
        if (win.closed) { clearInterval(poll); refresh(); }
      }, 800);
    }
  }

  async function handleAddFollowup() {
    setError('');
    if (!newFollowupLabel.trim()) { setError('A label for the review is required.'); return; }
    if (!newFollowupDate) { setError('A date is required.'); return; }
    setAddingFollowup(true);
    const result = await addFollowup(episodeId, newFollowupLabel, newFollowupDate);
    setAddingFollowup(false);
    if (result.error) { setError(result.error); return; }
    setNewFollowupLabel(''); setNewFollowupDate(''); setShowAddFollowup(false);
    refresh();
  }

  async function handleRemoveFollowup(followupId) {
    setError('');
    setRemovingFollowupId(followupId);
    const result = await removeFollowup(followupId);
    setRemovingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleCloseEpisode() {
    setError('');
    if (!closureOutcome) { setError('VAL-POST-005: Overall clinical outcome is required.'); return; }
    setSaving(true);
    const result = await closeEpisode(episodeId, { status: closureStatus, outcome: closureOutcome, remarks: closureRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowClose(false);
    setOk('Episode closed.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient?.uhid} -- {sc?.procedure_name} {sc?.eye} -- {sc?.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Closed' : 'Post-op'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {ok && <div className="msg-ok">{ok}</div>}

      {readOnly && !isClosed && (
        <div className="msg-info" style={{ marginBottom: 14 }}>
          <i className="ti ti-eye"></i> Read-only view -- this patient doesn't have a visit today. You can still view any past review records below. Open them from "Turned Up Today" on the Dashboard once they've checked in to start a new review.
        </div>
      )}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Surgical Episode Dashboard</div>

        {MILESTONES_START.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}

        {followups.length === 0 && (
          <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No follow-ups scheduled yet.</div>
        )}
        {followups.map((f) => {
          const color = f.status === 'Completed' ? 'var(--green)' : f.status === 'Due' ? 'var(--red)' : 'var(--blue)';
          const bg = f.status === 'Completed' ? 'var(--green-lt)' : f.status === 'Due' ? 'var(--red-lt)' : 'var(--blue-lt)';
          const icon = f.status === 'Completed' ? 'ti-check' : 'ti-calendar';
          return (
            <div key={f.id} style={{ padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 12, marginBottom: 8, background: bg }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color, flexShrink: 0 }}><i className={`ti ${icon}`}></i></div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 13 }}>{f.visit_label}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {new Date(f.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                    {f.scheduled_date > todayStr && f.status !== 'Completed' && <span style={{ color: 'var(--blue)', marginLeft: 6 }}>-- upcoming</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  {f.rescheduled_count > 0 && <span style={{ fontSize: 10, color: 'var(--amber)' }}>Rescheduled {f.rescheduled_count}x</span>}
                  <span className="badge" style={{ background: `${color}20`, color }}>{f.status}</span>
                </div>
              </div>

              {f.notes && notesEditingId !== f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: '8px 10px', background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}><i className="ti ti-notes"></i> Notes</div>
                  <div style={{ fontSize: 12.5, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{f.notes}</div>
                </div>
              )}

              {notesEditingId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <textarea className="fi fi-sm" rows={3} value={notesDraft} onChange={(e) => setNotesDraft(e.target.value)} placeholder="Notes for this visit..." style={{ marginBottom: 6 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveNotesOnly(f)} disabled={saving}>Save Notes</button>
                    <button className="btn btn-sm" onClick={() => setNotesEditingId(null)}>Cancel</button>
                  </div>
                </div>
              )}

              {/* Optional attachment -- any file relevant to this visit */}
              <div style={{ marginTop: 8, marginLeft: 42 }}>
                {(attachmentsByFollowup[f.id] || []).map((file) => (
                  <div key={file.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11.5, padding: '4px 0' }}>
                    <i className="ti ti-paperclip" style={{ color: 'var(--g500)' }}></i>
                    {file.url ? <a href={file.url} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--blue)' }}>{file.file_name}</a> : <span>{file.file_name}</span>}
                    {!isClosed && !readOnly && <button onClick={() => handleRemoveFollowupFile(file)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 11 }}>Remove</button>}
                  </div>
                ))}
                {!isClosed && !readOnly && (
                  <label className="btn btn-sm" style={{ cursor: 'pointer', marginTop: 4, display: 'inline-flex' }}>
                    {uploadingFollowupId === f.id ? 'Uploading...' : <><i className="ti ti-upload"></i> Attach file (optional)</>}
                    <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadFollowupFile(f.id, e.target.files?.[0])} disabled={uploadingFollowupId === f.id} />
                  </label>
                )}
              </div>

              {!isClosed && editingFollowupId !== f.id && (readOnly ? !!f.visit_id : true) && (
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 42 }}>
                  {readOnly ? (
                    <button className="btn btn-sm" onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                      <i className="ti ti-eye"></i> {openingReview === f.id ? 'Opening...' : 'View Record'}
                    </button>
                  ) : f.scheduled_date === todayStr ? (
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                      <i className="ti ti-clipboard-text"></i> {openingReview === f.id ? 'Opening...' : f.visit_id ? 'Open Review' : 'Start Review'}
                    </button>
                  ) : (
                    <button
                      className="btn btn-sm"
                      disabled
                      style={{ opacity: 0.5, cursor: 'not-allowed' }}
                      title="This review can only be opened on its scheduled date -- reschedule it to today first"
                    >
                      <i className="ti ti-calendar-time"></i> {f.scheduled_date > todayStr ? 'Not due yet' : 'Reschedule to open'}
                    </button>
                  )}
                  {!readOnly && (
                    <>
                      <button className="btn btn-sm" onClick={() => startEdit(f)}><i className="ti ti-calendar-time"></i> Reschedule</button>
                      {notesEditingId !== f.id && (
                        <button className="btn btn-sm" onClick={() => startNotesEdit(f)}><i className="ti ti-edit"></i> {f.notes ? 'Edit Notes' : 'Add Notes'}</button>
                      )}
                      {f.status !== 'Completed' && (
                        <button
                          className="btn btn-sm"
                          style={{ background: 'var(--green)', color: '#fff', border: 'none', opacity: f.scheduled_date > todayStr ? 0.5 : 1, cursor: f.scheduled_date > todayStr ? 'not-allowed' : 'pointer' }}
                          onClick={() => handleMarkStatus(f, 'Completed')}
                          disabled={f.scheduled_date > todayStr}
                          title={f.scheduled_date > todayStr ? "This visit hasn't happened yet" : ''}
                        >
                          Mark Completed
                        </button>
                      )}
                      <button
                        className="btn btn-sm"
                        style={{ color: 'var(--red)' }}
                        onClick={() => handleRemoveFollowup(f.id)}
                        disabled={removingFollowupId === f.id}
                        title={f.visit_id ? 'A review that already has a visit recorded cannot be removed' : 'Remove this review'}
                      >
                        <i className="ti ti-trash"></i> {removingFollowupId === f.id ? 'Removing...' : 'Remove'}
                      </button>
                    </>
                  )}
                </div>
              )}

              {!readOnly && editingFollowupId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8 }}>
                  <div style={{ marginBottom: 6 }}>
                    <label className="flbl">New date</label>
                    <input type="date" className="fi fi-sm" value={editDate} onChange={(e) => setEditDate(e.target.value)} />
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveFollowup(f)} disabled={saving}>Save</button>
                    <button className="btn btn-sm" onClick={() => setEditingFollowupId(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          );
        })}

        {!isClosed && !readOnly && (
          showAddFollowup ? (
            <div style={{ padding: '10px 12px', border: '1px dashed var(--g300)', borderRadius: 12, marginBottom: 8 }}>
              <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={newFollowupLabel} onChange={(e) => setNewFollowupLabel(e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 150 }} value={newFollowupDate} onChange={(e) => setNewFollowupDate(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={handleAddFollowup} disabled={addingFollowup}>{addingFollowup ? 'Adding...' : 'Add Review'}</button>
                <button className="btn btn-sm" onClick={() => { setShowAddFollowup(false); setNewFollowupLabel(''); setNewFollowupDate(''); }}>Cancel</button>
              </div>
            </div>
          ) : (
            <button className="btn btn-sm" style={{ marginBottom: 8 }} onClick={() => setShowAddFollowup(true)}><i className="ti ti-plus"></i> Add Review</button>
          )
        )}

        {MILESTONES_END.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Post-operative Complications <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(separate from intraop)</span></div>
        {!isClosed && !readOnly && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication (e.g. Raised IOP, CME)..." />
              <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management..." />
              <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome..." />
            </div>
            <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
          </>
        )}
        <div style={{ marginTop: 8 }}>
          {complications.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No post-operative complications recorded.</div>}
          {complications.map((c) => (
            <div key={c.id} style={{ padding: '8px 10px', borderRadius: 8, background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)', marginBottom: 6, fontSize: 12 }}>
              <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>{c.management ? `Management: ${c.management}` : <span style={{ color: 'var(--red)' }}>Management pending -- required before episode can close</span>}</div>
              {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
            </div>
          ))}
        </div>
      </div>

      {!isClosed && !readOnly && !showClose && (
        <div className="card" style={{ textAlign: 'center', marginBottom: 0 }}>
          <button className="btn btn-primary" onClick={() => setShowClose(true)}><i className="ti ti-circle-check"></i> Close Surgical Episode</button>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 6 }}>Only the Ophthalmologist should close an episode. Overall outcome must be documented.</div>
        </div>
      )}

      {showClose && !readOnly && (
        <div className="card" style={{ marginBottom: 0 }}>
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-circle-check" style={{ color: 'var(--purple)' }}></i> Close Surgical Episode</div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Episode closure status</label>
            <select className="fi" value={closureStatus} onChange={(e) => setClosureStatus(e.target.value)}>
              <option>Successfully Completed</option><option>Completed with Residual Condition</option><option>Requires Ongoing Follow-up</option><option>Transferred to Long-term Care</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Overall clinical outcome *</label>
            <select className="fi" value={closureOutcome} onChange={(e) => setClosureOutcome(e.target.value)}>
              <option value="">-- Select --</option>
              <option>Excellent Visual Outcome</option><option>Expected Recovery</option><option>Delayed Recovery</option><option>Complication Managed</option><option>Additional Surgery Required</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Closure remarks</label>
            <textarea className="fi" rows={2} value={closureRemarks} onChange={(e) => setClosureRemarks(e.target.value)} placeholder="Final remarks..." />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleCloseEpisode} disabled={saving}>{saving ? 'Closing...' : 'Close Episode'}</button>
            <button className="btn" onClick={() => setShowClose(false)}>Cancel</button>
          </div>
        </div>
      )}

      {isClosed && (
        <div className="msg-ok">
          <i className="ti ti-circle-check"></i>
          <span><strong>Episode Closed</strong> -- {episode.closure_status}. Outcome: {episode.closure_outcome}. {episode.closure_remarks}</span>
        </div>
      )}
    </div>
  );
}

PYEOF_525439674637007921

cat > "app/(main)/ot-recovery/page.js" << 'PYEOF_4720864690468171226'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getRecoveryCaseList, getRecoveryHistory } from './actions';
import Workspace from './workspace';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--teal)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(1, 1fr)', gap: 10, marginBottom: 14, maxWidth: 260 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--teal)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In recovery, not yet discharged</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Patients in Recovery</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--teal)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Recovery</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
                </div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No patients currently in recovery.</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Discharged Patients</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Follow-up tracking and episode closure now happen in the Post Op module.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Discharged</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e.id)} style={{ cursor: 'pointer' }}>
                <td><strong>{e.surgical_cases?.patients?.first_name} {e.surgical_cases?.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.surgical_cases?.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{e.surgical_cases?.procedure_name} ({e.surgical_cases?.eye})</td>
                <td style={{ fontSize: 11 }}>{e.discharge_date ? new Date(e.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={4} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No discharged patients found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function RecoveryPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getRecoveryCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getRecoveryHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-bed" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace episodeId={selectedId} onBack={handleBack} onUpdate={handleUpdate} />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}

PYEOF_4720864690468171226

cat > "app/(main)/ot-recovery/workspace.js" << 'PYEOF_2482487577131651857'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, removeRecoveryMedication, confirmDischarge, getDrugOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';

const TEMPLATES = {
  cataract: 'Eye drops as prescribed -- Moxifloxacin QID x1wk, Prednisolone QID tapering over 4wks.\nUse eye shield while sleeping for 1 week.\nAvoid bending, lifting heavy objects, and swimming for 2 weeks.\nWarning signs: sudden pain, redness, decreased vision -- contact immediately.\nFollow-up: Day 1, Week 1, Month 1, Final refraction at 4-6 weeks.',
  glaucoma: 'Eye drops as prescribed. Avoid rubbing operated eye.\nAvoid straining, heavy lifting for 4 weeks.\nWarning signs: severe pain, sudden vision loss, excessive redness -- contact immediately.\nFollow-up as scheduled by surgeon.',
};

// Suggested starting point -- Day 1 / Week 1 / Month 1 / Final Refraction
// relative to the chosen discharge date. Purely a default: the doctor
// can rename, redate, remove, or add to this list before confirming
// discharge, since different surgeries need different review schedules.
let planRowSeq = 0;
function defaultFollowupPlan(dischargeDate) {
  const addDays = (n) => { const d = new Date(`${dischargeDate}T00:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  return [
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Day 1', scheduled_date: addDays(1) },
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Week 1', scheduled_date: addDays(7) },
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Month 1', scheduled_date: addDays(30) },
    { key: `p${planRowSeq++}`, visit_label: 'Final Refraction', scheduled_date: addDays(45) },
  ];
}

export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);

  const [admissionDate, setAdmissionDate] = useState('');
  const [surgeryDate, setSurgeryDate] = useState('');
  const [recStart, setRecStart] = useState('');
  const [recEnd, setRecEnd] = useState('');
  const [consciousness, setConsciousness] = useState('Alert');
  const [pain, setPain] = useState('None');
  const [nausea, setNausea] = useState('None');
  const [dressing, setDressing] = useState('Intact, dry');
  const [escalation, setEscalation] = useState(false);
  const [escalationReason, setEscalationReason] = useState('');
  const [observations, setObservations] = useState('');

  const [checklist, setChecklist] = useState({});
  const [medName, setMedName] = useState('');
  const [drugOptions, setDrugOptions] = useState([]);
  const [dischargeDate, setDischargeDate] = useState(new Date().toISOString().slice(0, 10));
  const [medSig, setMedSig] = useState('');
  const [medReason, setMedReason] = useState('');
  const [showMedForm, setShowMedForm] = useState(false);

  const [instructions, setInstructions] = useState('');
  const [dischargeNotes, setDischargeNotes] = useState('');
  const [followupPlan, setFollowupPlan] = useState([]);

  const refresh = useCallback(async () => {
    const result = await getRecoveryEpisodeDetail(episodeId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    const e = result.episode;
    setAdmissionDate(e.admission_date || '');
    setSurgeryDate(e.surgery_date || '');
    setRecStart(e.recovery_start || '');
    setRecEnd(e.recovery_end || '');
    setConsciousness(e.consciousness || 'Alert');
    setPain(e.pain_level || 'None');
    setNausea(e.nausea || 'None');
    setDressing(e.dressing_status || 'Intact, dry');
    setEscalation(e.escalation_required || false);
    setEscalationReason(e.escalation_reason || '');
    setObservations(e.observations || '');
    setChecklist(e.discharge_checklist || {});
    setInstructions(e.discharge_instructions || '');
    setDischargeNotes(e.discharge_notes || '');
    setDischargeDate(e.discharge_date || new Date().toISOString().slice(0, 10));
    if (!e.discharge_date) {
      setFollowupPlan((prev) => (prev.length > 0 ? prev : defaultFollowupPlan(e.discharge_date || new Date().toISOString().slice(0, 10))));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); }, [episodeId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { episode, sc, intraop, biometryPlans, meds, followups } = data;
  const patient = sc.patients;
  const isDischarged = !!episode.discharge_date;
  const isClosed = !!episode.closure_status;

  function toggleChecklistItem(key) {
    if (isClosed) return;
    setChecklist((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  const mandatoryTotal = DISCHARGE_ITEMS.filter((i) => i.mandatory).length;
  const mandatoryChecked = DISCHARGE_ITEMS.filter((i) => i.mandatory && checklist[i.key]).length;

  async function handleSave() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveRecoveryFields(episodeId, {
      admission_date: admissionDate || null, surgery_date: surgeryDate || null,
      recovery_start: recStart || null, recovery_end: recEnd || null,
      consciousness, pain_level: pain, nausea, dressing_status: dressing,
      escalation_required: escalation, escalation_reason: escalation ? escalationReason || null : null,
      observations: observations || null, discharge_checklist: checklist,
      discharge_instructions: instructions || null, discharge_notes: dischargeNotes || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Recovery documentation saved.');
  }

  async function handleAddMedicine() {
    setError('');
    const result = await addRecoveryMedication(episodeId, medName, medSig, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedSig(''); setMedReason(''); setShowMedForm(false);
    refresh();
  }

  function updatePlanRow(key, field, value) {
    setFollowupPlan((prev) => prev.map((r) => (r.key === key ? { ...r, [field]: value } : r)));
  }

  function removePlanRow(key) {
    setFollowupPlan((prev) => prev.filter((r) => r.key !== key));
  }

  function addPlanRow() {
    setFollowupPlan((prev) => [...prev, { key: `p${planRowSeq++}`, visit_label: '', scheduled_date: dischargeDate }]);
  }

  function resetPlanToDefault() {
    setFollowupPlan(defaultFollowupPlan(dischargeDate));
  }

  async function handleDischarge() {
    setError(''); setOk('');
    if (!dischargeDate) { setError('Discharge date is required.'); return; }
    const result = await confirmDischarge(episodeId, checklist, dischargeNotes, instructions, dischargeDate, followupPlan);
    if (result.error) { setError(result.error); return; }
    setOk('Patient discharged. Discharge summary is ready to print. Follow-up schedule generated.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Episode Closed' : isDischarged ? 'Discharged' : 'Recovery'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          {/* Surgical summary read-only */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            {biometryPlans.map((p) => (
              <div key={p.surgical_eye} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>Implanted IOL ({p.surgical_eye})</span><strong style={{ color: 'var(--indigo)', fontFamily: 'monospace', fontSize: 11 }}>{intraop?.implant_power || p.final_iol_power} D -- {p.final_iol_category}</strong>
              </div>
            ))}
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
              <span style={{ color: 'var(--g500)' }}>Surgical outcome</span>
              <span className="badge b-green" style={{ fontSize: 10 }}>{intraop?.surgical_outcome || '--'}</span>
            </div>
          </div>

          {/* Recovery assessment */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--teal)' }}></i> Recovery Assessment</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={isClosed} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={isClosed}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={isClosed}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={isClosed}><option>No</option><option>Yes</option></select></div>
            </div>
            {escalation && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Escalation reason</label>
                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={isClosed} placeholder="Document reason for escalation..." />
              </div>
            )}
            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={isClosed} placeholder="Clinical observations / immediate concerns..." />
          </div>

          {/* Discharge checklist */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--green)' }}></i> Discharge Readiness Checklist</div>
              <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
            </div>
            {DISCHARGE_ITEMS.map((item) => (
              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isClosed ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          {/* Medications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
            {meds.map((m) => (
              <div key={m.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
                <span style={{ flex: 1 }}><strong>{m.name}</strong> -- {m.sig}</span>
                {!isClosed && <button onClick={() => removeRecoveryMedication(m.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
            {meds.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
            {!isClosed && (
              <>
                {!showMedForm ? (
                  <button className="btn btn-sm btn-primary" style={{ marginTop: 8 }} onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                ) : (
                  <div style={{ marginTop: 8 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                      <select className="fi fi-sm" value={medName} onChange={(e) => setMedName(e.target.value)}>
                        <option value="">-- Select medicine --</option>
                        {drugOptions.map((d) => <option key={d.id} value={d.label}>{d.label}</option>)}
                      </select>
                      <input className="fi fi-sm" value={medSig} onChange={(e) => setMedSig(e.target.value)} placeholder="Dose/Freq/Duration" />
                    </div>
                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6 }} />
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-sm btn-primary" onClick={handleAddMedicine}>Add</button>
                      <button className="btn btn-sm" onClick={() => setShowMedForm(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </>
            )}
          </div>

          {/* Discharge instructions */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
            </div>
            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={isClosed} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
          </div>

          {/* Discharge notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={isClosed} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
          </div>

          {/* Follow-up schedule */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Follow-up Schedule</div>
              {!isDischarged && (
                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={resetPlanToDefault}>Reset to standard schedule</button>
              )}
            </div>
            {!isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                Suggested reviews below -- edit the label/date, remove any that don't apply, or add your own before discharging.
              </div>
            )}

            {!isDischarged && followupPlan.map((f) => (
              <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', borderBottom: '1px solid var(--g100)' }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={f.visit_label} onChange={(e) => updatePlanRow(f.key, 'visit_label', e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 130 }} value={f.scheduled_date} onChange={(e) => updatePlanRow(f.key, 'scheduled_date', e.target.value)} />
                <button onClick={() => removePlanRow(f.key)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 16, padding: '0 4px' }} title="Remove this review">&times;</button>
              </div>
            ))}
            {!isDischarged && followupPlan.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No reviews planned -- add one below if needed, or leave empty if none are required.</div>
            )}
            {!isDischarged && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={addPlanRow}><i className="ti ti-plus"></i> Add review</button>
            )}

            {isDischarged && followups.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No reviews were scheduled at discharge.</div>}
            {isDischarged && followups.map((f) => (
              <div key={f.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ fontWeight: 600 }}>{f.visit_label}</span>
                <span style={{ color: 'var(--g500)' }}>{new Date(f.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                <span className={`badge ${f.status === 'Completed' ? 'b-green' : f.status === 'Due' ? 'b-red' : 'b-blue'}`} style={{ fontSize: 10 }}>{f.status}</span>
              </div>
            ))}
            {isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
                Reviews can be added or removed from the Post-op page as requirements change.
              </div>
            )}
          </div>
        </div>
      </div>

      {!isClosed && (
        <div style={{ background: '#0f172a', borderRadius: 12, padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
          <span style={{ fontSize: 11, color: '#64748b', fontWeight: 600 }}>ACTIONS:</span>
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
          </button>
          {!isDischarged && (
            <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
              <i className="ti ti-door-exit"></i> Discharge
            </button>
          )}
          {isDischarged && (
            <a href={`/discharge-summary-print/${episodeId}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)', textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Discharge Summary
            </a>
          )}
          {isDischarged && (
            <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
              <i className="ti ti-circle-check"></i> Discharged
            </span>
          )}
        </div>
      )}
    </div>
  );
}

PYEOF_2482487577131651857

cat > "app/(main)/patient-timeline/page.js" << 'PYEOF_8825433227110042375'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchPatients, getPatientTimeline } from './actions';
import { openPopup } from '@/lib/popup';

// Same mapping used in the Consultation workspace's context sidebar --
// kept identical across both so an event type reads as the same color
// everywhere in the app.
const TYPE_COLOR = {
  Visit: 'var(--indigo)',
  Diagnosis: 'var(--blue)',
  Investigation: 'var(--teal)',
  Prescription: 'var(--purple)',
  Surgery: 'var(--red)',
};
const TYPE_ICON = {
  Visit: 'ti-door-enter',
  Diagnosis: 'ti-clipboard-list',
  Investigation: 'ti-flask',
  Prescription: 'ti-pill',
  Surgery: 'ti-scalpel',
};

function PatientTimelineInner() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [events, setEvents] = useState([]);
  const [filter, setFilter] = useState('');
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [loading, setLoading] = useState(false);
  const searchParams = useSearchParams();

  async function handleSearch(val) {
    setQuery(val);
    if (val.trim().length < 2) { setResults([]); return; }
    const rows = await searchPatients(val);
    setResults(rows);
  }

  const loadPatientById = useCallback(async (patientId) => {
    setLoading(true);
    setResults([]);
    setSelectedEvent(null);
    const result = await getPatientTimeline(patientId);
    setLoading(false);
    setPatient(result.patient);
    setEvents(result.events || []);
    if (result.patient) setQuery(`${result.patient.first_name} ${result.patient.last_name} -- ${result.patient.uhid}`);
  }, []);

  async function handleSelectPatient(p) {
    await loadPatientById(p.id);
  }

  // Deep link from elsewhere in the app (e.g. the Consultation workspace's
  // "Open full timeline" link) -- skip the search step and load directly.
  useEffect(() => {
    const patientId = searchParams.get('patientId');
    if (patientId) loadPatientById(patientId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  const filteredEvents = filter ? events.filter((e) => e.type === filter) : events;
  const counts = {};
  events.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Clinical Timeline</div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Read-only longitudinal history, aggregated across every visit this patient has had.
        </div>
        <div style={{ position: 'relative' }}>
          <input className="fi" placeholder="Search patient by name or UHID..." value={query} onChange={(e) => handleSearch(e.target.value)} />
          {results.length > 0 && (
            <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, zIndex: 10, boxShadow: '0 4px 16px rgba(0,0,0,.1)' }}>
              {results.map((p) => (
                <div
                  key={p.id}
                  onClick={() => handleSelectPatient(p)}
                  style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 13, borderBottom: '1px solid var(--g100)' }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g50)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = '#fff')}
                >
                  <strong>{p.first_name} {p.last_name}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {loading && <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading timeline...</div>}

      {!loading && patient && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
          <div>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 14px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)', display: 'flex', gap: 8 }}>
                <select className="fi fi-sm" style={{ width: 'auto' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
                  <option value="">All events</option>
                  <option value="Visit">OPD Visits</option>
                  <option value="Diagnosis">Diagnoses</option>
                  <option value="Investigation">Investigations</option>
                  <option value="Surgery">Surgeries</option>
                  <option value="Prescription">Prescriptions</option>
                </select>
              </div>
              <div style={{ padding: 16 }}>
                {filteredEvents.length === 0 && (
                  <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No events match this filter.</div>
                )}
                {filteredEvents.map((ev, i) => (
                  <div key={i} style={{ display: 'flex', gap: 12 }}>
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 16, flexShrink: 0 }}>
                      <div style={{ width: 12, height: 12, borderRadius: '50%', background: TYPE_COLOR[ev.type], border: '2px solid #fff', boxShadow: '0 0 0 2px var(--g200)', flexShrink: 0 }}></div>
                      {i < filteredEvents.length - 1 && <div style={{ width: 2, background: 'var(--g200)', flex: 1, minHeight: 20, margin: '3px 0' }}></div>}
                    </div>
                    <div style={{ flex: 1, paddingBottom: 16, cursor: 'pointer' }} onClick={() => setSelectedEvent(ev)}>
                      <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 3 }}>
                        {new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                      </div>
                      <div style={{ border: ev.type === 'Visit' && ev.queueEntryId ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TYPE_ICON[ev.type]}`} style={{ color: TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{ev.detail}</div>
                        </div>
                        {ev.type === 'Visit' && ev.queueEntryId && (
                          <i className="ti ti-chevron-right" style={{ color: 'var(--blue)' }}></i>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div>
            {selectedEvent && (
              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-file"></i> Event Detail</div>
                <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Type</span><span className="badge" style={{ background: `${TYPE_COLOR[selectedEvent.type]}20`, color: TYPE_COLOR[selectedEvent.type] }}>{selectedEvent.type}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Date</span><span>{new Date(selectedEvent.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visit</span><span style={{ fontFamily: 'monospace' }}>{selectedEvent.visit}</span></div>
                  <div style={{ marginTop: 6 }}><strong>{selectedEvent.title}</strong></div>
                  <div style={{ color: 'var(--g500)', marginTop: 2 }}>{selectedEvent.detail}</div>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Read-only. Editing happens through the corresponding encounter only.</div>
                {selectedEvent.type === 'Visit' && selectedEvent.queueEntryId && (
                  <Link
                    href={`/consultation/${selectedEvent.queueEntryId}`}
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', textAlign: 'center', textDecoration: 'none', display: 'block' }}
                  >
                    <i className="ti ti-file-text"></i> Open Clinical Record
                  </Link>
                )}
                {selectedEvent.type === 'Visit' && !selectedEvent.queueEntryId && (
                  <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 6 }}>No clinical record was created for this visit.</div>
                )}
                {selectedEvent.type === 'Investigation' && selectedEvent.id && (
                  <button
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', justifyContent: 'center' }}
                    onClick={() => openPopup(`/investigation/${selectedEvent.id}?mode=view`, `inv-${selectedEvent.id}`)}
                  >
                    <i className="ti ti-eye"></i> View Result
                  </button>
                )}
              </div>
            )}

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Timeline Summary</div>
              <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Patient</span><span style={{ fontWeight: 600 }}>{patient.first_name} {patient.last_name}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total events</span><span style={{ fontWeight: 700 }}>{events.length}</span></div>
                {Object.entries(counts).map(([type, count]) => (
                  <div key={type} style={{ display: 'flex', justifyContent: 'space-between' }}>
                    <span>{type}</span><span className="badge" style={{ background: `${TYPE_COLOR[type]}20`, color: TYPE_COLOR[type] }}>{count}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {!loading && !patient && (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
          Search for a patient above to view their clinical timeline.
        </div>
      )}
    </div>
  );
}

export default function PatientTimelinePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <PatientTimelineInner />
    </Suspense>
  );
}
PYEOF_8825433227110042375

cat > "app/(main)/patients/page.js" << 'PYEOF_7043910820033744208'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

const GENDER_BADGE = { M: 'b-blue', F: 'b-purple', O: 'b-gray' };
const GENDER_LABEL = { M: 'Male', F: 'Female', O: 'Other' };

export default async function PatientsPage({ searchParams }) {
  const params = await searchParams;
  const justRegistered = params?.registered;
  const q = params?.q || '';

  const supabase = await createClient();
  let query = supabase.from('patients').select('*').order('created_at', { ascending: false });

  if (q) {
    query = query.or(
      `uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`
    );
  }

  const { data: patients, error } = await query;

  // Richer search results, matching M20's "Find Patient" screen -- shows
  // each patient's last visit date and whether they currently have an
  // open (active) visit, computed in one batched query rather than one
  // query per row.
  const patientIds = (patients || []).map((p) => p.id);
  let visitInfo = {};
  if (patientIds.length > 0) {
    const { data: visits } = await supabase
      .from('visits')
      .select('patient_id, status, created_at')
      .in('patient_id', patientIds)
      .order('created_at', { ascending: false });

    (visits || []).forEach((v) => {
      if (!visitInfo[v.patient_id]) {
        visitInfo[v.patient_id] = { lastVisit: v.created_at, hasActive: false };
      }
      if (v.status === 'Open') {
        visitInfo[v.patient_id].hasActive = true;
      }
    });
  }

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-users" style={{ color: 'var(--blue)' }}></i> Patients
          <span className="badge b-gray">{patients?.length ?? 0}</span>
        </div>
        <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Register New Patient
        </Link>
      </div>

      <form method="GET" action="/patients" style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        <input
          type="text"
          name="q"
          defaultValue={q}
          placeholder="Search by name, UHID, or mobile..."
          className="fi"
          style={{ flex: 1 }}
        />
        <button type="submit" className="btn btn-primary"><i className="ti ti-search"></i> Search</button>
        {q && (
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            Clear
          </Link>
        )}
      </form>

      {justRegistered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{justRegistered}</strong>
        </div>
      )}

      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>UHID</th>
            <th>Name</th>
            <th>Age</th>
            <th>Gender</th>
            <th>Mobile</th>
            <th>Blood Group</th>
            <th>Last Visit</th>
            <th>Active Visit</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(patients || []).map((p) => {
            const info = visitInfo[p.id];
            return (
              <tr key={p.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
                <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
                <td>{p.age || '--'}</td>
                <td><span className={`badge ${GENDER_BADGE[p.gender] || 'b-gray'}`}>{GENDER_LABEL[p.gender] || p.gender}</span></td>
                <td>{p.mobile}</td>
                <td>{p.blood_group ? <span className="badge b-red">{p.blood_group}</span> : '--'}</td>
                <td style={{ color: 'var(--g500)' }}>{info ? new Date(info.lastVisit).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }) : 'Never'}</td>
                <td>{info?.hasActive ? <span className="badge b-green">Active</span> : <span className="badge b-gray">None</span>}</td>
                <td>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <Link
                      href={`/patients/${p.id}/edit`}
                      className="btn"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-edit"></i> Edit
                    </Link>
                    <Link
                      href={`/visits/new?patientId=${p.id}`}
                      className="btn btn-primary"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-door-enter"></i> Create Visit
                    </Link>
                  </div>
                </td>
              </tr>
            );
          })}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

PYEOF_7043910820033744208

cat > "app/(main)/payments/actions.js" << 'PYEOF_3303361616357718638'
'use server';

import { createClient } from '@/lib/supabase-server';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';

export async function getTodaysVisits() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getPatientById(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  if (error) return { error: error.message };
  return { patient: data };
}

export async function getAllUnpaidInvoices() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at, patients(id, first_name, last_name, uhid)')
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── CREDIT NOTES ──
export async function getApprovers() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name, designation').eq('status', 'Active').order('full_name');
  return data || [];
}

export async function createCreditNote(patientId, invoiceId, amount, reason, approvedBy, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_credit_note', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_approved_by: approvedBy,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function getCreditNoteRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('credit_notes')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!credit_notes_approved_by_fkey(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── UNIFIED PATIENT LEDGER (Invoice / Payment / Advance / Advance
// Adjustment / Credit Note / Refund, interleaved with a running
// balance). patient_ledger itself is deliberately NOT a source here --
// it's an internal advance-balance tracker (get_advance_balance sums
// it), and every event it records already has a richer counterpart in
// payments/invoices/credit_notes, so including both would double-count.
export async function getPatientUnifiedLedger(patientId) {
  const supabase = await createClient();

  const [{ data: invoices }, { data: payments }, { data: refunds }, { data: creditNotes }] = await Promise.all([
    supabase.from('invoices').select('id, invoice_number, net, status, created_at, visits(visit_number)').eq('patient_id', patientId),
    supabase.from('payments').select('*, payment_modes(mode, amount)').eq('patient_id', patientId),
    supabase.from('payment_refunds').select('*, refund_payment:payments!payment_refunds_refund_payment_id_fkey(receipt_number), invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
    supabase.from('credit_notes').select('*, invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
  ]);

  const PAYMENT_TYPE_LABEL = { advance: 'Advance', advance_adjustment: 'Advance Adjustment', credit_note: 'Credit Note' };

  const entries = [];

  (invoices || []).forEach((inv) => {
    entries.push({
      date: inv.created_at, type: 'Invoice', ref: inv.invoice_number, visit: inv.visits?.visit_number || '--',
      desc: `Invoice ${inv.invoice_number}`, debit: Number(inv.net), credit: 0, by: 'System',
    });
  });

  // Every refund (invoice-based or from advance) now has exactly one
  // payment_refunds row -- its companion payments row (created purely
  // for Receipt visibility) is always skipped here to avoid double
  // counting.
  (payments || []).forEach((p) => {
    if (p.payment_type === 'credit_note' || p.payment_type === 'refund') return;
    const type = PAYMENT_TYPE_LABEL[p.payment_type] || 'Payment';
    const modeDesc = (p.payment_modes || []).map((m) => m.mode).join('+') || 'Advance';
    entries.push({
      date: p.collected_at, type, ref: p.receipt_number, visit: '--',
      desc: `${type} via ${modeDesc}${p.remarks ? ' -- ' + p.remarks : ''}`, debit: 0, credit: Number(p.total_amount), by: 'Staff',
    });
  });

  (refunds || []).forEach((r) => {
    const desc = r.invoice_id
      ? `Refund against ${r.invoices?.invoice_number || '--'} -- ${r.reason}`
      : `Refund from advance -- ${r.reason}`;
    entries.push({
      date: r.refunded_at, type: 'Refund', ref: r.refund_payment?.receipt_number || '--', visit: r.invoices?.visits?.visit_number || '--',
      desc, debit: Number(r.amount), credit: 0, by: 'Staff',
    });
  });

  (creditNotes || []).forEach((cn) => {
    entries.push({
      date: cn.created_at, type: 'Credit Note', ref: cn.credit_note_number, visit: cn.invoices?.visits?.visit_number || '--',
      desc: `${cn.reason} -- against ${cn.invoices?.invoice_number || '--'}`, debit: 0, credit: Number(cn.amount), by: 'Staff',
    });
  });

  entries.sort((a, b) => new Date(a.date) - new Date(b.date));

  let balance = 0;
  entries.forEach((e) => {
    balance += e.debit - e.credit;
    e.balance = balance;
  });

  return entries.reverse(); // newest first for display
}

// ── EDIT PAYMENT (clerical corrections only -- mode/reference/remarks,
// never amount) ──
export async function editPaymentClerical(paymentId, modes, reference, remarks, reason) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('edit_payment_clerical', {
    p_payment_id: paymentId,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_reason: reason,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getPaymentEditHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase.from('payment_edits').select('*, profiles(full_name)').eq('payment_id', paymentId).order('edited_at', { ascending: false });
  return data || [];
}

// ── REFUND (patient-first flow) ──
export async function getPatientPayments(patientId) {
  const supabase = await createClient();
  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), payment_allocations(id, invoice_id, amount, invoices(invoice_number))')
    .eq('patient_id', patientId)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const paymentIds = rows.map((p) => p.id);

  let refundedByPaymentInvoice = {};
  if (paymentIds.length > 0) {
    const { data: refunds } = await supabase.from('payment_refunds').select('payment_id, invoice_id, amount').in('payment_id', paymentIds);
    (refunds || []).forEach((r) => {
      const key = `${r.payment_id}:${r.invoice_id}`;
      refundedByPaymentInvoice[key] = (refundedByPaymentInvoice[key] || 0) + Number(r.amount);
    });
  }

  return rows.map((p) => ({
    ...p,
    payment_allocations: (p.payment_allocations || []).map((a) => {
      const alreadyRefunded = refundedByPaymentInvoice[`${p.id}:${a.invoice_id}`] || 0;
      return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
    }),
  }));
}

export async function refundAdvance(patientId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_advance', {
    p_patient_id: patientId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getRefundRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!payment_refunds_approved_by_fkey(full_name)')
    .order('refunded_at', { ascending: false })
    .limit(50);
  return data || [];
}

export async function searchPatientsForPayment(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getOutstandingInvoices(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at')
    .eq('patient_id', patientId)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true }); // oldest first, matches allocation order
  return data || [];
}

// ── ADVANCE ──
export async function getAdvanceBalance(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_advance_balance', { p_patient_id: patientId });
  if (error) return 0;
  return data || 0;
}

export async function collectAdvance(patientId, advanceType, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_advance', {
    p_patient_id: patientId,
    p_advance_type: advanceType,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}

export async function getCurrentBalancesByPatient() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('patient_id, amount, patients(id, first_name, last_name, uhid)');
  if (!data) return [];

  const byPatient = {};
  data.forEach((entry) => {
    if (!byPatient[entry.patient_id]) {
      byPatient[entry.patient_id] = { patient: entry.patients, balance: 0 };
    }
    byPatient[entry.patient_id].balance += Number(entry.amount);
  });
  return Object.values(byPatient).filter((p) => p.balance > 0);
}

export async function getLedgerHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*, patients(id, first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
    .order('recorded_at', { ascending: false })
    .limit(30);
  return data || [];
}
// ── ADJUSTMENTS ──
export async function getPatientLedgerAudit(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*')
    .eq('patient_id', patientId)
    .order('recorded_at', { ascending: false });
  return data || [];
}

export async function applyAdjustment(patientId, invoiceId, amount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_advance_adjustment', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── RECEIPTS ──
export async function searchReceipts(query, modeFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('payments')
    .select('*, patients(id, first_name, last_name, uhid), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
    .order('collected_at', { ascending: false })
    .limit(50);

  if (query) {
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    q = q.or(`receipt_number.ilike.%${query}%${ids.length ? ',patient_id.in.(' + ids.join(',') + ')' : ''}`);
  }

  const { data: receipts } = await q;
  if (!receipts) return [];

  if (!modeFilter) return receipts;
  return receipts.filter((r) => (r.payment_modes || []).some((m) => m.mode === modeFilter));
}

export async function getReceiptById(paymentId) {
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();
  if (error) return { error: error.message };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return { payment, modes: modes || [], allocations: allocations || [] };
}

// ── REFUND / MODIFICATION ──
export async function getRefundableAllocations(paymentId) {
  const supabase = await createClient();
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const { data: refunds } = await supabase
    .from('payment_refunds')
    .select('*')
    .eq('payment_id', paymentId);

  return (allocations || []).map((a) => {
    const alreadyRefunded = (refunds || [])
      .filter((r) => r.invoice_id === a.invoice_id)
      .reduce((s, r) => s + Number(r.amount), 0);
    return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
  });
}

export async function getRefundHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId)
    .order('refunded_at', { ascending: false });
  return data || [];
}

export async function refundPayment(paymentId, invoiceId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_payment', {
    p_payment_id: paymentId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── REPORTS ──
export async function getPaymentReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const from = fromDate || today;
  const to = toDate || today;
  // Include the entire "to" day, not just its midnight instant.
  const toEnd = `${to}T23:59:59`;
  const rangeLabel = from === to ? new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })
    : `${new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- ${new Date(to).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}`;

  if (reportId === 'daily') {
    const [{ data }, { data: refundsData }] = await Promise.all([
      supabase
        .from('payments')
        .select('receipt_number, total_amount, collected_at, patients(first_name, last_name)')
        .in('payment_type', ['invoice_payment', 'advance'])
        .gte('collected_at', from)
        .lte('collected_at', toEnd)
        .order('collected_at', { ascending: false }),
      supabase
        .from('payment_refunds')
        .select('amount')
        .gte('refunded_at', from)
        .lte('refunded_at', toEnd),
    ]);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, new Date(p.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }), `Rs.${p.total_amount}`],
    }));
    const grossTotal = (data || []).reduce((s, p) => s + Number(p.total_amount), 0);
    const refundTotal = (refundsData || []).reduce((s, r) => s + Number(r.amount), 0);
    return {
      title: `Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date/Time', 'Amount'], rows,
      total: grossTotal - refundTotal,
      summary: [
        { label: 'Gross Collected', value: grossTotal },
        { label: 'Refunds This Period', value: -refundTotal },
        { label: 'Net Collection', value: grossTotal - refundTotal, emphasize: true },
      ],
    };
  }

  if (reportId === 'mode' || reportId === 'cash' || reportId === 'upi') {
    const modeFilter = reportId === 'cash' ? 'Cash' : reportId === 'upi' ? 'UPI' : null;
    let q = supabase
      .from('payment_modes')
      .select('mode, amount, payments!inner(receipt_number, collected_at, patients(first_name, last_name), payment_type)')
      .gte('payments.collected_at', from)
      .lte('payments.collected_at', toEnd);
    if (modeFilter) q = q.eq('mode', modeFilter);
    const { data } = await q;

    // Refunds are included, not hidden -- but count against their mode
    // as negative, so both the per-mode summary and the mode-specific
    // reports show what was actually retained, not gross collected.
    const signedAmount = (m) => (m.payments?.payment_type === 'refund' ? -Number(m.amount) : Number(m.amount));

    if (reportId === 'mode') {
      const byMode = {};
      (data || []).forEach((m) => { byMode[m.mode] = (byMode[m.mode] || 0) + signedAmount(m); });
      const rows = Object.entries(byMode).map(([mode, amount]) => ({ cols: [mode, `Rs.${amount.toFixed(2)}`] }));
      return { title: `Payment Mode Summary (net of refunds) -- ${rangeLabel}`, headers: ['Mode', 'Net Total'], rows, total: Object.values(byMode).reduce((s, v) => s + v, 0) };
    }

    const rows = (data || []).map((m) => {
      const isRefund = m.payments?.payment_type === 'refund';
      return {
        cols: [
          m.payments?.receipt_number, `${m.payments?.patients?.first_name} ${m.payments?.patients?.last_name}`,
          new Date(m.payments?.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }),
          isRefund ? 'Refund' : 'Collection',
          `${isRefund ? '-' : ''}Rs.${m.amount}`,
        ],
      };
    });
    return { title: `${modeFilter} Collection (net of refunds) -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date', 'Type', 'Amount'], rows, total: (data || []).reduce((s, m) => s + signedAmount(m), 0) };
  }

  if (reportId === 'advance') {
    const { data } = await supabase
      .from('patient_ledger')
      .select('*, patients(id, first_name, last_name, uhid)')
      .gte('recorded_at', from)
      .lte('recorded_at', toEnd)
      .order('recorded_at', { ascending: false });
    const rows = (data || []).map((l) => ({
      cols: [`${l.patients?.first_name} ${l.patients?.last_name}`, l.patients?.uhid, l.entry_type, `Rs.${Math.abs(l.amount).toFixed(2)}`],
    }));
    return { title: `Advance Report -- ${rangeLabel}`, headers: ['Patient', 'UHID', 'Entry', 'Amount'], rows, total: null };
  }

  if (reportId === 'out') {
    // Outstanding balances are inherently "as of now", not date-ranged --
    // the range here filters by when the invoice was created, so you can
    // still see "what's still outstanding from invoices raised in period X".
    const { data } = await supabase
      .from('invoices')
      .select('invoice_number, net, paid, created_at, patients(id, first_name, last_name, uhid)')
      .in('status', ['Pending', 'Partial'])
      .gte('created_at', from)
      .lte('created_at', toEnd)
      .order('created_at', { ascending: true });
    const rows = (data || []).map((i) => ({
      cols: [i.invoice_number, `${i.patients?.first_name} ${i.patients?.last_name}`, i.patients?.uhid, `Rs.${(i.net - i.paid).toFixed(2)}`],
    }));
    return { title: `Outstanding Balances -- invoices raised ${rangeLabel}`, headers: ['Invoice #', 'Patient', 'UHID', 'Outstanding'], rows, total: (data || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0) };
  }

  if (reportId === 'register') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, payment_type, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false })
      .limit(200);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, p.payment_type, new Date(p.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }), `Rs.${p.total_amount}`],
    }));
    return { title: `Receipt Register -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Type', 'Date', 'Amount'], rows, total: null };
  }

  if (reportId === 'cancel') {
    const { data } = await supabase
      .from('payment_refunds')
      .select('*, patients(first_name, last_name), invoices(invoice_number)')
      .gte('refunded_at', from)
      .lte('refunded_at', toEnd)
      .order('refunded_at', { ascending: false });
    const rows = (data || []).map((r) => ({
      cols: [`${r.patients?.first_name} ${r.patients?.last_name}`, r.invoices?.invoice_number || 'Advance', `Rs.${r.amount}`, r.reason],
    }));
    return { title: `Refund Report -- ${rangeLabel}`, headers: ['Patient', 'Invoice', 'Amount', 'Reason'], rows, total: (data || []).reduce((s, r) => s + Number(r.amount), 0) };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_payment', {
    p_patient_id: patientId,
    p_invoice_ids: invoiceIds,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}


PYEOF_3303361616357718638

cat > "app/(main)/payments/adjustments/adjustments-tab.js" << 'PYEOF_1931406675140698494'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getCurrentBalancesByPatient, getAdvanceBalance, getOutstandingInvoices, getPatientLedgerAudit, applyAdjustment, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

export default function AdjustmentsTab() {
  const [patientsWithBalance, setPatientsWithBalance] = useState([]);
  const [selected, setSelected] = useState(null);
  const [balance, setBalance] = useState(0);
  const [invoices, setInvoices] = useState([]);
  const [audit, setAudit] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const [amount, setAmount] = useState('');
  const [invoiceId, setInvoiceId] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setPatientsWithBalance(await getCurrentBalancesByPatient());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function loadPatientData(patient) {
    setBalance(await getAdvanceBalance(patient.id));
    setInvoices(await getOutstandingInvoices(patient.id));
    setAudit(await getPatientLedgerAudit(patient.id));
  }

  async function selectPatient(patient) {
    setError(''); setSuccess('');
    setSelected(patient);
    await loadPatientData(patient);
    setAmount('');
    setInvoiceId('');
  }

  async function pickPatient(entry) {
    await selectPatient(entry.patient);
  }

  async function handleRefresh() {
    if (!selected) return;
    setError(''); setSuccess('');
    await loadPatientData(selected);
    refresh();
  }

  async function handleApply() {
    setError(''); setSuccess('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid adjustment amount.'); return; }
    if (!invoiceId) { setError('Select an invoice to adjust against.'); return; }

    setLoading(true);
    const result = await applyAdjustment(selected.id, invoiceId, amt);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Rs.${amt} adjusted against invoice successfully.`);
    setAmount('');
    setInvoiceId('');
    await loadPatientData(selected);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-arrows-exchange" style={{ color: 'var(--blue)' }}></i> Advance Adjustment
      </div>
      <div className="msg-info">
        <i className="ti ti-info-circle"></i> Adjusting an advance never edits or deletes the original collection entry -- it creates a new, linked adjustment entry instead, so the full history stays intact and auditable.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 20 }}>
        <div>
          <TodaysVisitsWidget visits={todaysVisits} onSelect={selectPatient} />

          <label className="flbl" style={{ marginBottom: 8 }}>Patients with advance balance</label>
          {patientsWithBalance.map((entry, i) => (
            <div
              key={i}
              onClick={() => pickPatient(entry)}
              style={{
                padding: '10px 12px', cursor: 'pointer', borderRadius: 8, marginBottom: 6, fontSize: 13,
                background: selected?.id === entry.patient.id ? 'var(--purple-lt)' : 'var(--g50)',
                border: selected?.id === entry.patient.id ? '1.5px solid var(--purple)' : '1px solid var(--g200)',
              }}
            >
              <div style={{ fontWeight: 600 }}>{entry.patient.first_name} {entry.patient.last_name}</div>
              <div style={{ color: 'var(--purple)', fontWeight: 700 }}>Rs.{entry.balance.toFixed(2)}</div>
            </div>
          ))}
          {patientsWithBalance.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No patients currently hold an advance balance.</div>}
        </div>

        {selected && (
          <div>
            <div style={{ background: 'var(--purple-lt)', border: '1px solid var(--purple)', borderRadius: 8, padding: 12, marginBottom: 12 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>{selected.first_name} {selected.last_name}</div>
              <div style={{ fontSize: 13, marginTop: 4 }}>Advance available: <strong style={{ color: 'var(--purple)', fontSize: 16 }}>Rs.{balance}</strong></div>
            </div>

            {error && <div className="msg-err">{error}</div>}
            {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <label className="flbl" style={{ marginBottom: 0 }}>Outstanding invoices</label>
              <button className="btn btn-sm" onClick={handleRefresh}><i className="ti ti-refresh"></i> Refresh</button>
            </div>
            <table className="tbl" style={{ marginBottom: 12 }}>
              <thead><tr><th>Invoice</th><th>Outstanding</th></tr></thead>
              <tbody>
                {invoices.map((inv) => (
                  <tr key={inv.id}><td style={{ fontFamily: 'monospace' }}>{inv.invoice_number}</td><td>Rs.{(inv.net - inv.paid).toFixed(2)}</td></tr>
                ))}
                {invoices.length === 0 && <tr><td colSpan={2} style={{ padding: 10, textAlign: 'center', color: 'var(--g400)' }}>No outstanding invoices.</td></tr>}
              </tbody>
            </table>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Adjust amount (Rs.)</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Against invoice</label>
                <select className="fi" value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
                  <option value="">-- Select --</option>
                  {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)}</option>)}
                </select>
              </div>
            </div>

            <button className="btn btn-primary" onClick={handleApply} disabled={loading || invoices.length === 0}>
              <i className="ti ti-arrows-exchange"></i> {loading ? 'Applying...' : 'Apply adjustment'}
            </button>

            <div style={{ marginTop: 16 }}>
              <label className="flbl" style={{ marginBottom: 8 }}>Audit trail -- this patient</label>
              {audit.map((a) => (
                <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                  {new Date(a.recorded_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })} -- {a.entry_type} -- Rs.{Math.abs(a.amount).toFixed(2)}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}


PYEOF_1931406675140698494

cat > "app/(main)/payments/ledger/ledger-tab.js" << 'PYEOF_5838798307933210736'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientUnifiedLedger, getAdvanceBalance, getOutstandingInvoices, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const TYPE_COLOR = {
  Invoice: 'var(--red)', Payment: 'var(--green)', Advance: 'var(--purple)',
  'Advance Adjustment': 'var(--blue)', Refund: 'var(--amber)', 'Credit Note': 'var(--teal)',
};

function fmt(n) {
  return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function LedgerTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [entries, setEntries] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [outstandingInvoices, setOutstandingInvoices] = useState([]);
  const [typeFilter, setTypeFilter] = useState('');
  const [visitFilter, setVisitFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setLoading(true);
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate('');
    const [ledgerEntries, balance, outstanding] = await Promise.all([
      getPatientUnifiedLedger(p.id), getAdvanceBalance(p.id), getOutstandingInvoices(p.id),
    ]);
    setEntries(ledgerEntries);
    setAdvanceBalance(balance);
    setOutstandingInvoices(outstanding);
    setLoading(false);
  }

  function changePatient() {
    setPatient(null);
    setEntries([]);
  }

  const visits = [...new Set(entries.map((e) => e.visit).filter((v) => v && v !== '--'))];
  const filtered = entries.filter((e) => {
    if (typeFilter && e.type !== typeFilter) return false;
    if (visitFilter && e.visit !== visitFilter) return false;
    if (fromDate && new Date(e.date) < new Date(fromDate)) return false;
    if (toDate && new Date(e.date) > new Date(`${toDate}T23:59:59`)) return false;
    return true;
  });

  const totalInvoiced = entries.filter((e) => e.type === 'Invoice').reduce((s, e) => s + e.debit, 0);
  const totalCollected = entries.filter((e) => e.type !== 'Invoice').reduce((s, e) => s + e.credit - e.debit, 0);
  const currentBalance = entries.length > 0 ? entries[0].balance : 0;

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Patient Ledger
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Spans all visits for this patient. Outstanding balance is calculated dynamically from every entry below -- Balance {'>'} 0 means the patient owes the hospital; Balance {'<'} 0 means the hospital owes the patient (unused advance).
        </div>

        {!patient ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            <div>
              <label className="flbl">Search patient (name, UHID, or mobile)</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
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
            <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
          </div>
        ) : (
          <div>
            <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '14px 18px', color: '#fff', marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 16, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
                  <div style={{ fontSize: 12, opacity: .8, marginTop: 2 }}>{patient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={changePatient} style={{ background: 'rgba(255,255,255,.15)', color: '#fff', border: '1px solid rgba(255,255,255,.3)' }}>
                  <i className="ti ti-arrow-left"></i> Change patient
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginTop: 14 }}>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Invoiced</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3 }}>Rs.{fmt(totalInvoiced)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Collected</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#86efac' }}>Rs.{fmt(totalCollected)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Advance Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#c4b5fd' }}>Rs.{fmt(advanceBalance)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Current Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: currentBalance > 0 ? '#fca5a5' : '#86efac' }}>Rs.{fmt(currentBalance)}</div>
                </div>
              </div>
            </div>

            {loading ? (
              <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading ledger...</div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
                  <select className="fi" style={{ width: 'auto' }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                    <option value="">All types</option>
                    {Object.keys(TYPE_COLOR).map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                  <select className="fi" style={{ width: 'auto' }} value={visitFilter} onChange={(e) => setVisitFilter(e.target.value)}>
                    <option value="">All visits</option>
                    {visits.map((v) => <option key={v} value={v}>{v}</option>)}
                  </select>
                  <input type="date" className="fi" style={{ width: 'auto' }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
                  <input type="date" className="fi" style={{ width: 'auto' }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
                  {(typeFilter || visitFilter || fromDate || toDate) && (
                    <button className="btn btn-sm" onClick={() => { setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate(''); }}>
                      <i className="ti ti-x"></i> Clear
                    </button>
                  )}
                </div>

                <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
                  <table className="tbl">
                    <thead>
                      <tr><th>Date/Time</th><th>Type</th><th>Reference</th><th>Visit</th><th>Description</th><th style={{ textAlign: 'right' }}>Debit</th><th style={{ textAlign: 'right' }}>Credit</th><th style={{ textAlign: 'right' }}>Balance</th></tr>
                    </thead>
                    <tbody>
                      {filtered.map((e, i) => (
                        <tr key={i} style={{ borderLeft: `3px solid ${TYPE_COLOR[e.type]}` }}>
                          <td style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{new Date(e.date).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                          <td>
                            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600 }}>
                              <span style={{ width: 7, height: 7, borderRadius: '50%', background: TYPE_COLOR[e.type], flexShrink: 0 }}></span>
                              {e.type}
                            </span>
                          </td>
                          <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.ref}</td>
                          <td style={{ fontSize: 11 }}>{e.visit}</td>
                          <td style={{ fontSize: 12 }}>{e.desc}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.debit > 0 ? <span style={{ color: 'var(--red)', fontWeight: 600 }}>{fmt(e.debit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.credit > 0 ? <span style={{ color: 'var(--green)', fontWeight: 600 }}>{fmt(e.credit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 700, color: e.balance > 0 ? 'var(--red)' : e.balance < 0 ? 'var(--purple)' : 'var(--green)' }}>{fmt(e.balance)}</td>
                        </tr>
                      ))}
                      {filtered.length === 0 && (
                        <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No entries match these filters.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <div className="card" style={{ padding: '10px 14px' }}>
                  <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: 'var(--g600)' }}>
                    {Object.entries(TYPE_COLOR).map(([type, color]) => (
                      <span key={type}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: color, marginRight: 4 }}></span>{type}</span>
                    ))}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

PYEOF_5838798307933210736

cat > "app/(main)/payments/payments-tabs.js" << 'PYEOF_2847851206141480032'
'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function PaymentsTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true); // assume open until checked, to avoid a flash of warning on every load

  useEffect(() => { isTodayOpen().then(setDayOpen); }, []);

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today's cash day hasn't been opened -- collecting or refunding payments is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
        </div>
      )}
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
    </div>
  );
}

PYEOF_2847851206141480032

cat > "app/(main)/payments/receipt/receipt-tab.js" << 'PYEOF_4135911945593997371'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { searchReceipts, editPaymentClerical, getPaymentEditHistory } from '../actions';

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const TYPE_BADGE = { invoice_payment: 'b-blue', advance: 'b-purple', advance_adjustment: 'b-amber', credit_note: 'b-teal' };
const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Adjustment', credit_note: 'Credit Note' };

export default function ReceiptTab() {
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [receipts, setReceipts] = useState([]);

  const [editingId, setEditingId] = useState(null);
  const [editModes, setEditModes] = useState([]);
  const [editReference, setEditReference] = useState('');
  const [editRemarks, setEditRemarks] = useState('');
  const [editReason, setEditReason] = useState('');
  const [editHistory, setEditHistory] = useState([]);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [saving, setSaving] = useState(false);

  const runSearch = useCallback(async () => {
    setReceipts(await searchReceipts(query, modeFilter));
  }, [query, modeFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  async function startEdit(r) {
    setError(''); setSuccess('');
    setEditingId(r.id);
    setEditModes((r.payment_modes || []).map((m) => ({ mode: m.mode, amount: String(m.amount) })));
    setEditReference(r.reference || '');
    setEditRemarks(r.remarks || '');
    setEditReason('');
    setEditHistory(await getPaymentEditHistory(r.id));
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  function updateModeRow(idx, field, value) {
    setEditModes((rows) => rows.map((row, i) => (i === idx ? { ...row, [field]: value } : row)));
  }

  function addModeRow() {
    setEditModes((rows) => [...rows, { mode: 'Cash', amount: '' }]);
  }

  function removeModeRow(idx) {
    setEditModes((rows) => rows.filter((_, i) => i !== idx));
  }

  async function saveEdit(receipt) {
    setError(''); setSuccess('');
    if (!editReason.trim()) { setError('A reason is required to edit this payment.'); return; }
    const modesPayload = editModes.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const modesSum = modesPayload.reduce((s, m) => s + m.amount, 0);
    if (Math.abs(modesSum - Number(receipt.total_amount)) > 0.01) {
      setError(`Mode split (Rs.${modesSum.toFixed(2)}) must still add up to the original amount collected (Rs.${Number(receipt.total_amount).toFixed(2)}). To change the amount itself, use Refund or Credit Note instead.`);
      return;
    }

    setSaving(true);
    const result = await editPaymentClerical(receipt.id, modesPayload, editReference, editRemarks, editReason);
    setSaving(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`${receipt.receipt_number} updated.`);
    setEditingId(null);
    runSearch();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Receipt Register
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 220 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Receipt #, patient, UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
            <option value="">All modes</option>
            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
        <table className="tbl">
          <thead>
            <tr><th>Receipt #</th><th>Date/Time</th><th>Patient</th><th>Invoice ref</th><th>Mode(s)</th><th>Amount</th><th>Type</th><th></th></tr>
          </thead>
          <tbody>
            {receipts.map((r) => (
              <Fragment key={r.id}>
                <tr>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{r.receipt_number}</td>
                  <td>{new Date(r.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td style={{ fontWeight: 600 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--'}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_modes || []).map((m) => `${m.mode} Rs.${m.amount}`).join(', ')}</td>
                  <td style={{ fontWeight: 600 }}>Rs.{r.total_amount}</td>
                  <td><span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || r.payment_type || 'Payment'}</span></td>
                  <td style={{ display: 'flex', gap: 4 }}>
                    <a href={`/receipt-print/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                      <i className="ti ti-printer"></i>
                    </a>
                    <button className="btn btn-sm" onClick={() => (editingId === r.id ? cancelEdit() : startEdit(r))}>
                      <i className="ti ti-edit"></i> {editingId === r.id ? 'Close' : 'Edit'}
                    </button>
                  </td>
                </tr>
                {editingId === r.id && (
                  <tr key={`${r.id}-edit`}>
                    <td colSpan={8} style={{ background: 'var(--g50)', padding: 16 }}>
                      <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 10 }}>
                        <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Edit clerical details for {r.receipt_number}
                      </div>
                      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                        <i className="ti ti-info-circle"></i> For correcting clerical mistakes only -- payment mode, reference number, remarks. The mode split must still total Rs.{r.total_amount}. To change the amount collected, use Refund or Credit Note instead.
                      </div>

                      <label className="flbl">Payment mode(s)</label>
                      {editModes.map((row, idx) => (
                        <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                          <select className="fi" style={{ flex: 1 }} value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)}>
                            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
                          </select>
                          <input type="number" className="fi" style={{ flex: 1 }} value={row.amount} onChange={(e) => updateModeRow(idx, 'amount', e.target.value)} placeholder="Amount" />
                          {editModes.length > 1 && <button className="btn" style={{ padding: '4px 10px' }} onClick={() => removeModeRow(idx)}>x</button>}
                        </div>
                      ))}
                      <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Add mode</button>

                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                        <div>
                          <label className="flbl">Reference / Transaction ID</label>
                          <input className="fi" value={editReference} onChange={(e) => setEditReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
                        </div>
                        <div>
                          <label className="flbl">Remarks</label>
                          <input className="fi" value={editRemarks} onChange={(e) => setEditRemarks(e.target.value)} />
                        </div>
                      </div>

                      <label className="flbl">Reason for this edit *</label>
                      <input className="fi" style={{ marginBottom: 10 }} value={editReason} onChange={(e) => setEditReason(e.target.value)} placeholder="e.g. Staff mis-entered UPI as Cash" />

                      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                        <button className="btn btn-primary btn-sm" onClick={() => saveEdit(r)} disabled={saving}>{saving ? 'Saving...' : 'Save Correction'}</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </div>

                      {editHistory.length > 0 && (
                        <div>
                          <label className="flbl" style={{ marginBottom: 6 }}>Edit history</label>
                          {editHistory.map((h) => (
                            <div key={h.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g200)' }}>
                              {new Date(h.edited_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {h.profiles?.full_name || 'Staff'} -- {h.reason}
                            </div>
                          ))}
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {receipts.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

PYEOF_4135911945593997371

cat > "app/(main)/payments/refund/refund-tab.js" << 'PYEOF_7421189657519949285'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientPayments, getAdvanceBalance, getApprovers, refundPayment, refundAdvance, getRefundRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Excess payment', 'Cancelled service', 'Duplicate payment', 'Service not rendered', 'Patient request -- approved', 'Other approved reason'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function RefundTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [payments, setPayments] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [refundFor, setRefundFor] = useState(null);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [mode, setMode] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    getTodaysVisits().then(setTodaysVisits);
  }, []);

  async function refreshRegister() {
    setRegister(await getRefundRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(p.id), getAdvanceBalance(p.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
  }

  function changePatient() {
    setPatient(null);
    setPayments([]);
    setRefundFor(null);
  }

  function startRefund(payment, allocation) {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'invoice', payment, allocation });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  function startRefundAdvance() {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'advance' });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  const totalPaid = payments.reduce((s, p) => s + Number(p.total_amount), 0);
  const totalRefundable = payments.reduce((s, p) => s + (p.payment_allocations || []).reduce((s2, a) => s2 + Math.max(0, a.refundable), 0), 0);

  async function confirmRefund() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid refund amount.'); return; }
    if (!reason) { setError('Select a refund reason.'); return; }
    if (!mode) { setError('Select a refund mode.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    let result;
    if (refundFor.kind === 'advance') {
      if (amt > advanceBalance) { setLoading(false); setError(`Refund amount cannot exceed the available advance balance (Rs.${advanceBalance}).`); return; }
      result = await refundAdvance(patient.id, amt, reason, mode, approvedBy);
    } else {
      if (amt > refundFor.allocation.refundable) { setLoading(false); setError(`Refund amount cannot exceed what remains refundable (Rs.${refundFor.allocation.refundable.toFixed(2)}).`); return; }
      result = await refundPayment(refundFor.payment.id, refundFor.allocation.invoice_id, amt, reason, mode, approvedBy);
    }
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(refundFor.kind === 'advance'
      ? `Refund of Rs.${amt.toFixed(2)} processed from advance balance.`
      : `Refund of Rs.${amt.toFixed(2)} processed against ${refundFor.allocation.invoices?.invoice_number}.`);
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(patient.id), getAdvanceBalance(patient.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-rotate-clockwise" style={{ color: 'var(--amber)' }}></i> Refund
          </div>
          <div className="msg-info" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-info-circle"></i> Reverses money already collected -- the original receipt is never edited or deleted, a new linked refund entry is added alongside it. Requires an approver.
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {!patient ? (
            <div>
              <label className="flbl">Patient</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
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
              <div style={{ marginTop: 16 }}>
                <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
              </div>
            </div>
          ) : (
            <div>
              <div style={{ background: 'var(--amber-lt)', border: '1px solid var(--amber)', borderRadius: 8, padding: '10px 14px', marginBottom: 14 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>{patient.first_name} {patient.last_name}</div>
                  <button className="btn btn-sm" onClick={changePatient}>Change</button>
                </div>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 2 }}>{patient.uhid}</div>
                <div style={{ display: 'flex', gap: 16, marginTop: 8, fontSize: 12 }}>
                  <span>Total paid: <strong style={{ color: 'var(--green)' }}>Rs.{totalPaid.toFixed(2)}</strong></span>
                  <span>Refundable: <strong style={{ color: 'var(--amber)' }}>Rs.{totalRefundable.toFixed(2)}</strong></span>
                  <span>Advance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong></span>
                </div>
              </div>

              {advanceBalance > 0 && (
                <div className="card" style={{ padding: '10px 12px', marginBottom: 8, background: 'var(--purple-lt)', border: '1px solid var(--purple)' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ fontSize: 12 }}>
                      <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance balance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong>
                      <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Not tied to any invoice -- refund it directly from the pooled balance.</div>
                    </div>
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={startRefundAdvance}>
                      Refund from Advance
                    </button>
                  </div>
                </div>
              )}

              <label className="flbl" style={{ marginBottom: 8 }}>Receipts -- select what to refund</label>
              {payments.map((p) => (
                <div key={p.id} className="card" style={{ padding: '10px 12px', marginBottom: 8 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 6 }}>
                    <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{p.receipt_number}</span>
                    <span style={{ color: 'var(--g500)' }}>{new Date(p.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })} -- Rs.{p.total_amount}</span>
                  </div>
                  {(p.payment_allocations || []).length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)' }}>Not applied to any invoice (advance).</div>}
                  {(p.payment_allocations || []).map((a) => (
                    <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', fontSize: 12, borderTop: '1px solid var(--g100)' }}>
                      <span style={{ fontFamily: 'monospace' }}>{a.invoices?.invoice_number}</span>
                      <span>Rs.{Number(a.amount).toFixed(2)} allocated{a.alreadyRefunded > 0 ? ` -- Rs.${a.alreadyRefunded.toFixed(2)} refunded` : ''}</span>
                      {a.refundable > 0 ? (
                        <button className="btn btn-sm" onClick={() => startRefund(p, a)}>Refund up to Rs.{a.refundable.toFixed(2)}</button>
                      ) : <span style={{ color: 'var(--g400)', fontSize: 11 }}>Fully refunded</span>}
                    </div>
                  ))}
                </div>
              ))}
              {payments.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments found for this patient.</div>}

              {refundFor && (
                <div style={{ border: '1.5px solid var(--amber)', borderRadius: 8, padding: 14, marginTop: 12 }}>
                  <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}>
                    {refundFor.kind === 'advance'
                      ? `Refund from advance balance -- up to Rs.${advanceBalance}`
                      : `Refund against ${refundFor.allocation.invoices?.invoice_number} -- up to Rs.${refundFor.allocation.refundable.toFixed(2)}`}
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund reason *</label>
                      <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                        <option value="">-- Select --</option>
                        {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Refund amount (Rs.) *</label>
                      <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
                    </div>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund mode *</label>
                      <select className="fi" value={mode} onChange={(e) => setMode(e.target.value)}>
                        <option value="">-- Select --</option>
                        {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Approved by *</label>
                      <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
                        <option value="">-- Select --</option>
                        {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                      </select>
                    </div>
                  </div>
                  <label className="flbl">Remarks</label>
                  <input className="fi" style={{ marginBottom: 12 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={confirmRefund} disabled={loading}>
                      {loading ? 'Processing...' : 'Process Refund'}
                    </button>
                    <button className="btn" onClick={() => setRefundFor(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--amber)' }}></i> Refund Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Invoice</th><th>Amount</th><th>Mode</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((r) => (
                <tr key={r.id}>
                  <td style={{ fontSize: 12 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.invoices?.invoice_number || 'Advance'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(r.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{r.refund_mode || '--'}</td>
                  <td style={{ fontSize: 11 }}>{r.reason}</td>
                  <td style={{ fontSize: 11 }}>{r.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No refunds processed yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

PYEOF_7421189657519949285

cat > "app/(main)/visits/page.js" << 'PYEOF_959014328938811136'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import { getDoctorOptionsForVisit } from './actions';
import VisitActions from './visit-actions';

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Surgery': '--teal',
};

const BILLING_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', '--': 'b-gray' };

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;
  const tab = params?.tab === 'all' ? 'all' : 'today';

  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  let query = supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles!doctor_id(full_name)')
    .order('created_at', { ascending: false });

  if (tab === 'today') {
    query = query.gte('created_at', today);
  } else {
    query = query.limit(100); // most recent 100 -- avoids loading the entire visit history at once
  }

  const { data: visits, error } = await query;
  const doctors = await getDoctorOptionsForVisit();

  const visitIds = (visits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, status').in('visit_id', visitIds);
    (invoices || []).forEach((inv) => { billingByVisit[inv.visit_id] = inv.status; });
  }

  return (
    <div className="card">
      <div className="card-head">
        <div>
          <div className="card-title"><i className="ti ti-door-enter" style={{ color: 'var(--green)' }}></i> Visits <span className="badge b-gray">{visits?.length ?? 0}</span></div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>{tab === 'today' ? "Today's visits, all statuses." : 'Most recent 100 visits, all time.'}</div>
        </div>
        <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Walk-in Visit
        </Link>
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        <Link href="/visits?tab=today" className={tab === 'today' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          Today&apos;s Visits
        </Link>
        <Link href="/visits?tab=all" className={tab === 'all' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          All Visits
        </Link>
      </div>

      {justCreated && <div className="msg-success"><i className="ti ti-circle-check"></i> Visit created successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Visit ID</th>
            <th>{tab === 'today' ? 'Time' : 'Date'}</th>
            <th>Patient</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Status</th>
            <th>Billing</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(visits || []).map((v) => {
            const billStatus = billingByVisit[v.id] || '--';
            return (
              <tr key={v.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                <td style={{ color: 'var(--g500)' }}>
                  {tab === 'today'
                    ? new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })
                    : new Date(v.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                </td>
                <td>
                  <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                </td>
                <td>
                  <span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span>
                  {v.surgery_type && <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>{v.surgery_type}</div>}
                </td>
                <td>{v.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : v.status === 'Cancelled' ? 'b-red' : 'b-gray'}`}>{v.status}</span></td>
                <td><span className={`badge ${BILLING_BADGE[billStatus]}`}>{billStatus}</span></td>
                <td>
                  <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
                    {v.status === 'Open' && (
                      <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> Bill
                      </Link>
                    )}
                    <VisitActions visit={v} doctors={doctors} />
                  </div>
                </td>
              </tr>
            );
          })}
          {(!visits || visits.length === 0) && (
            <tr>
              <td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {tab === 'today' ? 'No visits yet today.' : 'No visits found.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}


PYEOF_959014328938811136

cat > "app/components/AppShell.js" << 'PYEOF_1712920477259943870'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/workflow-monitor', label: 'Workflow Monitor', icon: 'ti-activity', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}



PYEOF_1712920477259943870

cat > "app/components/AttachmentUploader.js" << 'PYEOF_3012496618956718340'
'use client';

import { useState, useEffect, useRef } from 'react';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';

function formatSize(bytes) {
  if (!bytes) return '--';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function AttachmentUploader({ entityType, entityId, title = 'Reports & Documents' }) {
  const [files, setFiles] = useState([]);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const inputRef = useRef(null);

  async function refresh() {
    const result = await getAttachments(entityType, entityId);
    setFiles(result);
  }

  useEffect(() => { refresh(); }, [entityType, entityId]);

  async function handleFileSelect(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError('');
    setUploading(true);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', entityType);
    formData.append('entityId', entityId);
    const result = await uploadAttachment(formData);
    setUploading(false);
    if (inputRef.current) inputRef.current.value = '';
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleDelete(a) {
    if (!window.confirm(`Delete "${a.file_name}"? This cannot be undone.`)) return;
    await deleteAttachment(a.id, a.storage_path);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-paperclip" style={{ color: 'var(--indigo)' }}></i> {title}</div>
        <label className="btn btn-sm" style={{ cursor: uploading ? 'default' : 'pointer', opacity: uploading ? 0.6 : 1, marginBottom: 0 }}>
          <i className="ti ti-upload"></i> {uploading ? 'Uploading...' : 'Upload'}
          <input ref={inputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/jpg" onChange={handleFileSelect} disabled={uploading} style={{ display: 'none' }} />
        </label>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {files.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No reports uploaded yet.</div>}

      {files.map((a) => (
        <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: '1px solid var(--g100)' }}>
          <i className={`ti ${a.mime_type === 'application/pdf' ? 'ti-file-type-pdf' : 'ti-photo'}`} style={{ color: 'var(--g400)', fontSize: 16 }}></i>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.file_name}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>
              {formatSize(a.file_size)} -- {a.profiles?.full_name || 'Staff'} -- {new Date(a.uploaded_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </div>
          </div>
          {a.url && <a href={a.url} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '3px 9px', fontSize: 11 }}>View</a>}
          <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => handleDelete(a)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
        </div>
      ))}
    </div>
  );
}
PYEOF_3012496618956718340

cat > "app/consultation/[id]/consultation-form.js" << 'PYEOF_8095883710994921870'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  sendForBiometryFromConsultation,
  adviseBiometry,
  updateBiometryInstructions,
  removeBiometryRecord,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  sendForProcedureFromConsultation,
  addReferral,
  removeReferral,
  addCounsellingItem,
  removeCounsellingItem,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
  saveDraft,
  getFollowUpContext,
  saveVisitOutcome,
  carryForwardDiagnosis,
} from '@/app/(main)/consultation/actions';
import { openPopup } from '@/lib/popup';
import { markForSurgery, updateSurgicalCase } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import HistoryTab from './history-tab';
import OptometryTab from './optometry-tab';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

function DiagnosisRow({ d, index, encounterId, onRemove }) {
  const [notes, setNotes] = useState(d.notes || '');
  const [saved, setSaved] = useState(true);

  async function handleBlur() {
    if (notes === (d.notes || '')) return;
    await updateDiagnosisNotes(d.id, notes);
    setSaved(true);
  }

  return (
    <div style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
        <span>
          <span style={{ color: 'var(--g400)', fontWeight: 700, marginRight: 4 }}>{index + 1}.</span>
          <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
        </span>
        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={onRemove}>Remove</button>
      </div>
      <input
        className="fi fi-sm"
        style={{ marginTop: 5, marginLeft: 18, width: 'calc(100% - 18px)' }}
        placeholder="Doctor notes for this diagnosis (optional)"
        value={notes}
        onChange={(e) => { setNotes(e.target.value); setSaved(false); }}
        onBlur={handleBlur}
      />
      {!saved && <div style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 18, marginTop: 2 }}>Unsaved -- click away to save</div>}
    </div>
  );
}

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// Section group divider for Diagnosis & Plan -- numbered circle badge,
// same visual language as the numbered sections in Optometry Assessment,
// so the two clinical screens feel consistent.
function GroupHeader({ num, color, title }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '4px 0 12px' }}>
      <span style={{ width: 24, height: 24, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>{num}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)' }}>{title}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--g200)' }}></div>
    </div>
  );
}

export default function ConsultationForm({ queueEntryId, hideHistoryTracker = false, onBack, backLabel = 'Dashboard' }) {
  const [data, setData] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [visitOutcome, setVisitOutcome] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState(hideHistoryTracker ? 'optometry' : 'history');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');
  const [bioEye, setBioEye] = useState('');
  const [bioInstructions, setBioInstructions] = useState('');
  const [editingBioId, setEditingBioId] = useState(null);
  const [editBioInstructions, setEditBioInstructions] = useState('');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [procNotes, setProcNotes] = useState('');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [counselTopic, setCounselTopic] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  // Master Data options for the Diagnosis/Prescription/Investigation
  // dropdowns -- fetched once on mount, not re-fetched on every add/remove.
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && !s.name.toLowerCase().includes('biometry')));
      setProcedureOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Minor Procedure'));
      setSurgeryOptions(sg.filter((s) => s.status === 'Active'));
    })();
  }, []);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    setVisitOutcome(data.encounter.visit_outcome || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
    if (data.biometryRecords && data.biometryRecords.length > 0) {
      const first = data.biometryRecords[0];
      setBioEye(data.biometryRecords.length === 2 ? 'Both' : (first.surgical_eye || ''));
      setBioInstructions(first.doctor_instructions || '');
    }
  }, [data]);

  async function handleAdviseBiometry() {
    setError('');
    if (!bioEye) { setError('Select which eye Biometry is required for.'); return; }
    const result = await adviseBiometry(data.entry.visits.id, data.encounter.id, bioEye, bioInstructions);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  function startEditBioInstructions(record) {
    setEditingBioId(record.id);
    setEditBioInstructions(record.doctor_instructions || '');
  }

  async function saveBioInstructions(id) {
    await updateBiometryInstructions(id, editBioInstructions);
    setEditingBioId(null);
    refresh();
  }

  async function handleRemoveBiometry(id) {
    setError('');
    const result = await removeBiometryRecord(id, data.encounter.id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVisitOutcomeChange(outcome) {
    setVisitOutcome(outcome);
    await saveVisitOutcome(data.encounter.id, outcome);
  }

  async function handleCarryForward(priorDiagnosis) {
    setError('');
    const result = await carryForwardDiagnosis(data.encounter.id, priorDiagnosis);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName) { setError('Select a procedure.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye, procNotes);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    setProcNotes('');
    refresh();
  }

  async function handleSendForProcedure() {
    setError('');
    setLoading(true);
    const result = await sendForProcedureFromConsultation(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleAddCounsel() {
    setError('');
    if (!counselTopic.trim()) { setError('Counselling topic is required.'); return; }
    const result = await addCounsellingItem(data.encounter.id, counselTopic);
    if (result.error) { setError(result.error); return; }
    setCounselTopic('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  // This page is meant to be opened in its own window (see doctor-dashboard's
  // "Call"/"Call Next" and ot-postop's "Start Review"), closing itself the
  // moment the doctor is done with this sitting -- window.close() only
  // works on script-opened windows, so this quietly falls back to
  // navigating back to the queue if it was opened by direct navigation
  // instead (e.g. a bookmark or typed URL).
  function finishAndClose() {
    window.close();
    router.push('/queue');
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  async function handleSendOut(kind) {
    setError('');
    if (kind === 'biometry' && !bioEye) { setError('Select which eye Biometry is required for before sending.'); return; }
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : kind === 'biometry'
      ? await sendForBiometryFromConsultation(queueEntryId, data.encounter.id, bioEye, bioInstructions)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    // Biometry stays on the page -- a doctor may still need to add
    // diagnoses, order investigations, etc. in the same sitting. Dilation
    // and Investigation keep the existing "done with this patient for
    // now" behavior since that wasn't something you flagged.
    if (kind === 'biometry') { refresh(); return; }
    finishAndClose();
  }

  async function handleSaveDraft() {
    setError('');
    setLoading(true);
    const result = await saveDraft(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  const isReadOnly = data.isLocked && !unlocked;
  // Already routed to the technician if the current queue status
  // mentions Biometry (including compound statuses like "Awaiting
  // Investigation & Biometry" -- see doctorSendOut).
  const bioSent = data.entry?.status?.includes('Biometry') || false;

  return (
    <div style={{ maxWidth: 1440, margin: '0 auto', padding: '20px 26px' }}>
      {/* STICKY HEADER + TABS -- frozen at the top of the scroll area so
          the patient's identity and which tab you're on never scroll out
          of view, no matter how long the tab's content gets. */}
      <div style={{ position: 'sticky', top: 0, zIndex: 20, background: 'var(--g50)', paddingBottom: 10, marginBottom: 6 }}>
        {onBack && (
          <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> {backLabel}
          </button>
        )}
        <div style={{
          background: 'linear-gradient(135deg, var(--blue-dk), var(--blue))', borderRadius: 'var(--r-lg)',
          padding: '14px 20px', color: '#fff', boxShadow: 'var(--shadow-md)', marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 16,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: '50%', background: 'rgba(255,255,255,.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800, flexShrink: 0,
            fontFamily: 'var(--font-display-stack)',
          }}>
            {patient.first_name?.charAt(0)?.toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
              {patient.first_name} {patient.last_name}
              {data.isFollowUp && <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontSize: 10.5 }}>Follow-up Visit</span>}
            </div>
            <div style={{ fontSize: 12, opacity: .85, marginTop: 2 }}>
              {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- Token {data.entry.token}
            </div>
          </div>
          <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.16)', borderRadius: 10, padding: '6px 16px', flexShrink: 0 }}>
            <div style={{ fontSize: 9.5, opacity: .8, textTransform: 'uppercase', letterSpacing: '.5px' }}>Duration</div>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'monospace' }}>{elapsedMin(data.encounter.started_at)}m</div>
          </div>
        </div>

        {/* TABS */}
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
          {!hideHistoryTracker && <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-message" label="History" />}
          <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
          <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
          <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
          {!hideHistoryTracker && <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />}
        </div>
      </div>

      {data.isFollowUp && followUpContext && (
        <PatientSnapshotBar snapshot={followUpContext.snapshot} />
      )}

      {data.isLocked && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed consultation -- changes save immediately.'
              : 'This consultation is completed. Viewing read-only for reference.'}
          </span>
          <button className="btn btn-sm" onClick={() => setUnlocked((v) => !v)}>
            {unlocked ? 'Lock' : 'Unlock to Edit'}
          </button>
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        {/* CONTEXT SIDEBAR -- patient history (previous visit, timeline,
            investigations) plus this encounter's own status/tasks/audit
            log, all in one place so the main column has full width. */}
        <div>
          <ContextSidebar
            patientId={patient.id}
            previousVisitSummary={data.isFollowUp && followUpContext ? followUpContext.snapshot.previousVisitSummary : null}
            encounter={data.encounter}
            auditLog={data.auditLog}
            openInvestigations={openInvestigations}
            activeWorkflows={activeWorkflows}
            pendingRx={pendingRx}
            wfItems={WF_ITEMS}
          />
        </div>

        {/* MAIN COLUMN -- tab content only; the tab bar itself now lives
            in the sticky header above so it freezes along with the
            patient identity bar. */}
        <div>
          {/* Tab content and the actions bar below are wrapped in a native
              <fieldset disabled> when the encounter is locked -- this
              cascades to every nested input/select/button in HistoryTab,
              OptometryTab, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'history' && (
            <HistoryTab
              encounter={data.encounter}
              findings={data.findings}
              onSaved={refresh}
            />
          )}

          {activeTab === 'optometry' && (
            <OptometryTab
              findings={data.findings}
              iopReadings={data.iopReadings}
              visitId={data.entry.visits.id}
              encounterId={data.encounter.id}
              onSaved={refresh}
            />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              <GroupHeader num={1} color="var(--purple)" title="Investigations" />

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>
                {data.isFollowUp && followUpContext && (
                  <NewInvestigationsSinceLastVisit
                    investigations={followUpContext.newInvestigations}
                    matchInvestigationType={matchInvestigationType}
                    summarizeResultData={summarizeResultData}
                  />
                )}
                {data.investigations.map((i) => {
                  const type = matchInvestigationType(i.name);
                  const hasResults = i.status === 'Available';
                  return (
                    <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
                        <span>
                          <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                        </span>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                          {hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {hasResults && (
                        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3 }}>{summarizeResultData(type, i.result_data)}</div>
                      )}
                      {i.status === 'Cancelled' && i.unable_reason && (
                        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}><i className="ti ti-alert-triangle"></i> Unable to perform -- {i.unable_reason}</div>
                      )}
                    </div>
                  );
                })}
                {data.investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No investigations ordered yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setInvName(e.target.value); }}>
                  <option value="">-- Pick from Investigations master (or type below) --</option>
                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
                    <option>Routine</option><option>Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              <GroupHeader num={2} color="var(--indigo)" title="Biometry" />
              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                  Device measurements, IOL power calculation, and surgeon approval -- its own dedicated workflow, separate from lab investigations.
                </div>

                {bioSent ? (
                  <>
                    <div style={{ marginBottom: 6 }}>
                      <span className="badge b-green"><i className="ti ti-check"></i> Sent for Biometry</span>
                    </div>
                    {data.biometryRecords.map((r) => (
                      <div key={r.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                          <span className={`badge ${r.status === 'Approved' ? 'b-green' : r.status === 'Calculated' ? 'b-purple' : r.status === 'Measured' ? 'b-blue' : 'b-amber'}`}>
                            {r.status}
                          </span>
                          <span className="badge b-indigo">{r.surgical_eye}</span>
                          <a href={`/biometry/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 12, textDecoration: 'none' }}>
                            <i className="ti ti-external-link"></i> Open Biometry
                          </a>
                          {editingBioId !== r.id && (
                            <button className="btn" style={{ fontSize: 11 }} onClick={() => startEditBioInstructions(r)}>
                              <i className="ti ti-edit"></i> {r.doctor_instructions ? 'Edit instructions' : 'Add instructions'}
                            </button>
                          )}
                          {r.billing_status !== 'Billed' ? (
                            <button className="btn" style={{ fontSize: 11, color: 'var(--red)' }} onClick={() => handleRemoveBiometry(r.id)}>
                              <i className="ti ti-trash"></i> Remove
                            </button>
                          ) : (
                            <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                          )}
                        </div>
                        {editingBioId === r.id ? (
                          <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                            <input className="fi" style={{ flex: 1 }} placeholder="Instructions for technician" value={editBioInstructions} onChange={(e) => setEditBioInstructions(e.target.value)} />
                            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => saveBioInstructions(r.id)}>Save</button>
                            <button className="btn" style={{ fontSize: 12 }} onClick={() => setEditingBioId(null)}>Cancel</button>
                          </div>
                        ) : r.doctor_instructions && (
                          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 4 }}><i className="ti ti-notes"></i> {r.doctor_instructions}</div>
                        )}
                      </div>
                    ))}
                  </>
                ) : (
                  <>
                    {data.biometryRecords.length > 0 && (
                      <div style={{ marginBottom: 10 }}>
                        {data.biometryRecords.map((r) => (
                          <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4, flexWrap: 'wrap' }}>
                            <span className="badge b-indigo"><i className="ti ti-check"></i> Advised -- {r.surgical_eye}</span>
                            {r.billing_status !== 'Billed' ? (
                              <button className="btn" style={{ fontSize: 10 }} onClick={() => handleRemoveBiometry(r.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i> Remove
                              </button>
                            ) : (
                              <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                            )}
                          </div>
                        ))}
                        <span style={{ fontSize: 11, color: 'var(--g500)' }}>Adjust below if needed, then use &quot;Send for Biometry&quot; at the bottom.</span>
                      </div>
                    )}
                    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                      <div>
                        <label className="flbl">Eye required</label>
                        <select className="fi" style={{ width: 100 }} value={bioEye} onChange={(e) => setBioEye(e.target.value)}>
                          <option value="">Select</option>
                          <option value="RE">RE</option>
                          <option value="LE">LE</option>
                          <option value="Both">Both Eyes</option>
                        </select>
                      </div>
                      <div style={{ flex: 1, minWidth: 200 }}>
                        <label className="flbl">Instructions for technician (optional)</label>
                        <input className="fi" placeholder="e.g. prior RK surgery, use formula X" value={bioInstructions} onChange={(e) => setBioInstructions(e.target.value)} />
                      </div>
                      <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAdviseBiometry}>
                        {data.biometryRecords.length > 0 ? 'Update' : 'Add'}
                      </button>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>
                      Adding here records the advice -- use &quot;Send for Biometry&quot; below when you&apos;re ready to actually route the patient.
                    </div>
                  </>
                )}
              </div>

              <GroupHeader num={3} color="var(--teal)" title="Diagnosis" />

              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
                {data.isFollowUp && followUpContext && !isReadOnly && (
                  <CarryForwardDiagnoses
                    priorDiagnoses={followUpContext.snapshot.currentDiagnoses}
                    alreadyAdded={data.diagnoses}
                    onCarryForward={handleCarryForward}
                  />
                )}
                {data.diagnoses.map((d, idx) => (
                  <DiagnosisRow key={d.id} d={d} index={idx} encounterId={data.encounter.id} onRemove={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }} />
                ))}
                {data.diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setDxName(e.target.value); }}>
                  <option value="">-- Pick from Diagnoses master (or type below) --</option>
                  {diagnosisOptions.map((d) => <option key={d.id} value={d.name}>{d.name}{d.category ? ` (${d.category})` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option>
                    <option value="OS">OS</option>
                    <option value="OU">OU</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              <GroupHeader num={4} color="var(--blue)" title="Treatment" />

              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Prescription</div>
                {data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && !isReadOnly && (
                  <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Continue from last visit</div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {followUpContext.snapshot.currentMedications
                        .filter((m) => !data.prescriptions.some((r) => r.drug_name === m.drug_name && r.eye === m.eye))
                        .map((m) => (
                          <button
                            key={m.id}
                            className="btn btn-sm"
                            onClick={async () => {
                              await addPrescription(data.encounter.id, { drugName: m.drug_name, dosage: m.dosage, frequency: m.frequency, duration: m.duration, eye: m.eye });
                              refresh();
                            }}
                          >
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye})
                          </button>
                        ))}
                    </div>
                  </div>
                )}
                {data.prescriptions.map((r) => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setRxDrug(e.target.value); }}>
                  <option value="">-- Pick from Pharmacy master (or type below) --</option>
                  {drugOptions.map((d) => <option key={d.id} value={d.generic}>{d.generic}{d.brand ? ` (${d.brand})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
                  <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                  {data.opticalAdvice.map((o) => (
                    <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{o.advice}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                    {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                      <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                    ))}
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Minor Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                      {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{p.notes}</div>}
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select minor procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name} -- Rs.{p.rate}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 70 }}>
                      <option>OD</option><option>OS</option><option>OU</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                  </div>
                  <input className="fi fi-sm" placeholder="Notes (optional)" value={procNotes} onChange={(e) => setProcNotes(e.target.value)} />
                </div>
              </div>

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery</div>

                {data.surgicalCases.length > 0 ? (
                  <div>
                    {data.surgicalCases.map((sc) => (
                      <div key={sc.id}>
                        {editingSurgicalCaseId === sc.id ? (
                          <div style={{ padding: '8px 0' }}>
                            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                              <select className="fi" value={editSurgeryProcedure} onChange={(e) => setEditSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                                <option value="">-- Select surgery --</option>
                                {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                              </select>
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 80 }}>
                                <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Pre-op Required</label>
                              <select className="fi" value={editSurgeryPreOp} onChange={(e) => setEditSurgeryPreOp(e.target.value)}>
                                <option value="None">None</option>
                                <option value="Biometry">Biometry</option>
                                <option value="Medical Fitness">Medical Fitness</option>
                                <option value="Both">Both</option>
                              </select>
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 0', fontSize: 13 }}>
                            <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                            <span style={{ flex: 1 }}>
                              <strong>{sc.procedure_name}</strong> -- {sc.eye}
                              <span style={{ marginLeft: 8, fontSize: 10.5, color: 'var(--g500)' }}>
                                Pre-op: {sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None'}
                              </span>
                            </span>
                            <span className="badge b-blue" style={{ fontSize: 10 }}>{sc.status}</span>
                            {sc.status === 'Pending Workup' && (
                              <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => startEditSurgicalCase(sc)}>
                                <i className="ti ti-edit"></i> Edit
                              </button>
                            )}
                          </div>
                        )}
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select surgery --</option>
                        {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                        <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Pre-op Required</label>
                      <select className="fi" value={surgeryPreOp} onChange={(e) => setSurgeryPreOp(e.target.value)}>
                        <option value="None">None</option>
                        <option value="Biometry">Biometry</option>
                        <option value="Medical Fitness">Medical Fitness</option>
                        <option value="Both">Both</option>
                      </select>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              <GroupHeader num={5} color="var(--amber)" title="Patient Management" />

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div>
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                    <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                    {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
                  </div>

                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-messages" style={{ color: 'var(--teal)' }}></i> Counselling Topics</div>
                    {data.counsellingItems.map((c) => (
                      <div key={c.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{c.topic}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeCounsellingItem(c.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Cataract counselling', 'Premium IOL discussion', 'Financial counselling', 'Consent education'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setCounselTopic(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Counselling topic..." value={counselTopic} onChange={(e) => setCounselTopic(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleAddCounsel}>Add</button>
                    </div>
                  </div>
                </div>

                <div>
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                    {data.referrals.map((r) => (
                      <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                      <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                        <option value="">-- Destination --</option>
                        <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                      </select>
                      <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                    </div>
                  </div>

                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                      <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                        <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                      </select>
                      <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                        <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                      </select>
                      <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                        <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                      </select>
                    </div>
                    <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                    {fuSaved && (
                      <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                        Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                      </div>
                    )}
                  </div>
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {data.isFollowUp && (
            <VisitOutcomeSelector value={visitOutcome} onChange={handleVisitOutcomeChange} disabled={isReadOnly} />
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn" onClick={handleSaveDraft} disabled={loading}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            {data.investigations.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
                Send for Investigation
              </button>
            )}
            {!bioSent && data.biometryRecords.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('biometry')} disabled={loading}>
                <i className="ti ti-ruler-measure"></i> Send for Biometry
              </button>
            )}
            {data.procedures.length > 0 && (
              <button className="btn" onClick={handleSendForProcedure} disabled={loading}>
                <i className="ti ti-tool"></i> Send for Procedure
              </button>
            )}
            <a href={`/opd-case-sheet-print/${data.encounter.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </a>
            <a href={`/visit-summary-print/${data.encounter.id}`} target="_blank" rel="noopener noreferrer" className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </a>
          </div>
          </fieldset>
        </div>
      </div>
    </div>
  );
}
PYEOF_8095883710994921870

cat > "app/consultation/[id]/follow-up-panel.js" << 'PYEOF_8628426644037720422'
'use client';

import { useState, useEffect } from 'react';
import { openPopup } from '@/lib/popup';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';

const VISIT_OUTCOMES = [
  'Continue Follow-up', 'Surgery Advised', 'Proceed to Pre-operative Consultation',
  'Surgery Planned', 'Referred', 'Admitted', 'Discharged',
];

function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function visionStr(v) {
  if (!v) return '--';
  return `RE ${v.re || '--'} / LE ${v.le || '--'}`;
}

function iopStr(iop) {
  if (!iop) return '--';
  return `RE ${iop.re ?? '--'} / LE ${iop.le ?? '--'} mmHg`;
}

// ── Patient Snapshot (top panel, always visible for a Follow-up encounter) ──
export function PatientSnapshotBar({ snapshot }) {
  if (!snapshot) return null;
  if (snapshot.noCompletedPriorVisit) {
    return (
      <div className="card" style={{ marginBottom: 16, background: 'var(--amber-lt)', border: '1px solid #fcd34d' }}>
        <div style={{ fontSize: 12, color: 'var(--amber)' }}>
          <i className="ti ti-info-circle"></i> This patient has prior visits, but none were ever finalized -- no completed clinical record to summarize yet.
        </div>
      </div>
    );
  }
  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--blue-lt)', border: '1px solid #93c5fd' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Patient Snapshot -- Follow-up Visit
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10 }}>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Diagnosis</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentDiagnoses.length > 0 ? snapshot.currentDiagnoses.map((d) => d.name).join(', ') : 'None on record'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Surgery Status</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.surgicalStatus ? `${snapshot.surgicalStatus.procedure_name} -- ${snapshot.surgicalStatus.status}` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Medications</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentMedications.length > 0 ? `${snapshot.currentMedications.length} active` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Drug Allergies</div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: snapshot.allergy ? 'var(--red)' : 'inherit' }}>{snapshot.allergy || 'None recorded'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Visit</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{fmtDate(snapshot.lastVisitDate)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Vision</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{visionStr(snapshot.lastVision)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last IOP</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{iopStr(snapshot.lastIop)}</div>
        </div>
      </div>
    </div>
  );
}

// ── Previous visits, shown as an in-flow horizontal strip at the top of
// the workspace (not floating -- sits inside the consultation content,
// same as everything else). ──
export function PatientTimelineSidebar({ timeline }) {
  return (
    <div className="card" style={{ marginBottom: 16, borderLeft: '4px solid var(--indigo)' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--indigo)', textTransform: 'uppercase', marginBottom: 10, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Previous Visits
      </div>
      {timeline.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior visits.</div>
      ) : (
        <div style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
          {timeline.map((t) => {
            const clickable = !!t.queueEntryId;
            return (
              <div
                key={t.encounterId}
                onClick={clickable ? () => window.open(`/consultation/${t.queueEntryId}`, '_blank', 'noopener,noreferrer') : undefined}
                style={{ minWidth: 160, flexShrink: 0, padding: '10px 12px', borderRadius: 10, border: '1.5px solid var(--indigo)', cursor: clickable ? 'pointer' : 'default', background: 'var(--indigo-lt)' }}
              >
                <div style={{ fontSize: 12, fontWeight: 800, color: 'var(--indigo)' }}>{fmtDate(t.date)}</div>
                <div style={{ fontSize: 11.5, color: 'var(--g700)', marginTop: 2 }}>{t.chiefComplaint || 'Consultation'}</div>
                {t.status !== 'Completed' && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 4, fontWeight: 600 }}>Not finalized -- {t.status}</div>}
                {clickable && <div style={{ fontSize: 10.5, color: 'var(--indigo)', marginTop: 4, fontWeight: 700 }}><i className="ti ti-eye"></i> {t.status === 'Completed' ? 'View read-only' : 'Open'}</div>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ── Previous Visit Summary (read-only card) ──
export function PreviousVisitSummary({ summary }) {
  if (!summary) return null;
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--g500)' }}></i> Previous Visit Summary -- {fmtDate(summary.date)}</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, fontSize: 12.5 }}>
        <div><span style={{ color: 'var(--g500)' }}>Vision: </span>{visionStr(summary.vision)}</div>
        <div><span style={{ color: 'var(--g500)' }}>IOP: </span>{iopStr(summary.iop)}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Diagnosis: </span>{summary.diagnoses.length > 0 ? summary.diagnoses.map((d) => d.name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Medications: </span>{summary.medications.length > 0 ? summary.medications.map((m) => m.drug_name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Advice: </span>{summary.advice.length > 0 ? summary.advice.map((a) => a.text || a.advice_text || a.note).filter(Boolean).join('; ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Follow-up Plan: </span>{summary.followupPlan?.instructions || summary.followupPlan?.notes || '--'}</div>
      </div>
    </div>
  );
}

// Same mapping as the standalone Patient Timeline module -- kept
// identical across both so an event type reads as the same color
// everywhere in the app, not just within this sidebar.
const EVENT_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };
const EVENT_COLOR = { Visit: 'var(--indigo)', Diagnosis: 'var(--blue)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--red)' };

function EventTypeChip({ type }) {
  const color = EVENT_COLOR[type] || 'var(--g500)';
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 7px', borderRadius: 999, background: `${color}1a`, color, fontSize: 9.5, fontWeight: 800, textTransform: 'uppercase', letterSpacing: '.3px' }}>
      <i className={`ti ${EVENT_ICON[type] || 'ti-point'}`} style={{ fontSize: 10 }}></i> {type}
    </span>
  );
}

function elapsedMin(iso) {
  return Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
}

// ── Context sidebar -- lives alongside the workspace. Combines patient
//    history (previous visit, timeline, past investigations) with this
//    encounter's own status/tasks/audit log, all in one column so the
//    main workspace gets the full remaining width. ──
export function ContextSidebar({ patientId, previousVisitSummary, encounter, auditLog, openInvestigations, activeWorkflows, pendingRx, wfItems }) {
  const [showSummary, setShowSummary] = useState(false);
  const [events, setEvents] = useState(null);

  useEffect(() => {
    if (!patientId) return;
    let cancelled = false;
    getPatientTimeline(patientId).then((r) => { if (!cancelled) setEvents(r.events || []); });
    return () => { cancelled = true; };
  }, [patientId]);

  const investigations = (events || []).filter((e) => e.type === 'Investigation');

  return (
    <div>
      <button
        className="btn"
        style={{ width: '100%', justifyContent: 'center', marginBottom: 16 }}
        onClick={() => setShowSummary(true)}
        disabled={!previousVisitSummary}
        title={previousVisitSummary ? '' : 'No previous visit on record'}
      >
        <i className="ti ti-file-text"></i> Previous Visit Summary
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-timeline" style={{ color: 'var(--indigo)' }}></i> Patient Timeline</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && events.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No prior history.</div>}
        {events && events.length > 0 && (
          <div style={{ maxHeight: 300, overflowY: 'auto' }}>
            {events.slice(0, 25).map((e, idx) => {
              const clickable = (e.type === 'Visit' && !!e.queueEntryId) || (e.type === 'Investigation' && !!e.id);
              function handleClick() {
                if (e.type === 'Visit' && e.queueEntryId) window.open(`/consultation/${e.queueEntryId}`, '_blank', 'noopener,noreferrer');
                else if (e.type === 'Investigation' && e.id) openPopup(`/investigation/${e.id}?mode=view`, `inv-${e.id}`);
              }
              return (
                <div
                  key={idx}
                  onClick={clickable ? handleClick : undefined}
                  style={{ padding: '8px 4px', borderBottom: '1px solid var(--g100)', cursor: clickable ? 'pointer' : 'default', borderRadius: 6 }}
                  onMouseEnter={clickable ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
                  onMouseLeave={clickable ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <EventTypeChip type={e.type} />
                    <span style={{ marginLeft: 'auto', color: 'var(--g400)', fontSize: 10 }}>{fmtDate(e.date)}</span>
                    {clickable && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR[e.type], fontSize: 12 }}></i>}
                  </div>
                  <div style={{ fontSize: 11.5, fontWeight: 600, marginTop: 4 }}>{e.title}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
                </div>
              );
            })}
          </div>
        )}
        <a href={patientId ? `/patient-timeline?patientId=${patientId}` : '/patient-timeline'} target="_blank" rel="noopener noreferrer" style={{ fontSize: 10.5, color: 'var(--blue)', display: 'inline-flex', alignItems: 'center', gap: 4, marginTop: 8 }}>
          <i className="ti ti-external-link"></i> Open full timeline
        </a>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Previous Investigations</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && investigations.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>None on record.</div>}
        {investigations.slice(0, 15).map((e, idx) => (
          <div
            key={idx}
            onClick={e.id ? () => openPopup(`/investigation/${e.id}?mode=view`, `inv-${e.id}`) : undefined}
            style={{ padding: '7px 4px', borderBottom: '1px solid var(--g100)', cursor: e.id ? 'pointer' : 'default', borderRadius: 6 }}
            onMouseEnter={e.id ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
            onMouseLeave={e.id ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11.5, fontWeight: 600, flex: 1 }}>{e.title}</span>
              <span className="badge" style={{ background: `${EVENT_COLOR.Investigation}1a`, color: EVENT_COLOR.Investigation, fontSize: 9 }}>{e.status || '--'}</span>
              {e.id && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR.Investigation, fontSize: 12 }}></i>}
            </div>
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>{fmtDate(e.date)}</div>
          </div>
        ))}
      </div>

      {encounter && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Encounter Status</div>
          <div style={{ fontSize: 11.5, color: 'var(--g600)', lineHeight: 1.9 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Status</span><span className="badge b-blue">{encounter.status}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(encounter.started_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>In progress</span><span style={{ fontWeight: 700 }}>{elapsedMin(encounter.started_at)}m</span></div>
          </div>
        </div>
      )}

      {(openInvestigations || activeWorkflows || pendingRx) && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-list-checks" style={{ color: 'var(--amber)' }}></i> Outstanding Tasks</div>
          {(openInvestigations || []).length === 0 && (activeWorkflows || []).length === 0 && (pendingRx || []).length === 0 && (
            <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Nothing outstanding.</div>
          )}
          {(openInvestigations || []).map((i) => (
            <div key={i.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i><span style={{ flex: 1 }}>{i.name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{i.status}</span>
            </div>
          ))}
          {(activeWorkflows || []).map((w) => (
            <div key={w.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className={`ti ${wfItems?.[w.kind]?.icon || 'ti-clipboard'}`} style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{w.kind}</span><span className="badge b-amber" style={{ fontSize: 9 }}>Requested</span>
            </div>
          ))}
          {(pendingRx || []).map((r) => (
            <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i><span style={{ flex: 1 }}>{r.drug_name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{r.status}</span>
            </div>
          ))}
        </div>
      )}

      {auditLog && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
          <div style={{ maxHeight: 240, overflowY: 'auto' }}>
            {auditLog.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No activity yet.</div>}
            {auditLog.map((a) => (
              <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
                <div>{a.message}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {showSummary && previousVisitSummary && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={() => setShowSummary(false)}>
          <div style={{ width: 480, maxHeight: '80vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <PreviousVisitSummary summary={previousVisitSummary} />
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setShowSummary(false)}>Close</button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Carry Forward: bring an unresolved diagnosis from the last visit
// into this one, without silently duplicating it -- doctor picks. ──
export function CarryForwardDiagnoses({ priorDiagnoses, alreadyAdded, onCarryForward }) {
  const available = priorDiagnoses.filter((pd) => !alreadyAdded.some((d) => d.name === pd.name && d.eye === pd.eye));
  if (available.length === 0) return null;
  return (
    <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Carry forward from last visit</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
        {available.map((pd) => (
          <button key={pd.id} className="btn btn-sm" onClick={() => onCarryForward(pd)}>
            <i className="ti ti-plus"></i> {pd.name} ({pd.eye})
          </button>
        ))}
      </div>
    </div>
  );
}

// ── New investigations since the last visit, with results ready ──
export function NewInvestigationsSinceLastVisit({ investigations, matchInvestigationType, summarizeResultData }) {
  if (!investigations || investigations.length === 0) return null;
  return (
    <div style={{ background: 'var(--teal-lt)', borderRadius: 8, padding: 10, marginBottom: 12 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--teal)', marginBottom: 6 }}>
        <i className="ti ti-flask"></i> New since last visit -- {investigations.length} result{investigations.length > 1 ? 's' : ''} ready
      </div>
      {investigations.map((i) => {
        const type = matchInvestigationType(i.name);
        return (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', fontSize: 12.5 }}>
            <span><strong>{i.name}</strong> -- {i.eye} -- <span style={{ color: 'var(--g500)' }}>{summarizeResultData(type, i.result_data)}</span></span>
            <button className="btn btn-sm" onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
              <i className="ti ti-eye"></i> View
            </button>
          </div>
        );
      })}
    </div>
  );
}

// ── Visit Outcome selector ──
export function VisitOutcomeSelector({ value, onChange, disabled }) {
  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--purple)' }}></i> Visit Outcome</div>
      <select className="fi" value={value || ''} onChange={(e) => onChange(e.target.value)} disabled={disabled}>
        <option value="">-- Select outcome --</option>
        {VISIT_OUTCOMES.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

PYEOF_8628426644037720422

cat > "app/consultation/[id]/optometry-tab.js" << 'PYEOF_196898862638383432'
'use client';

import { useState, useEffect } from 'react';
import { updateOptometryFindings, createOptometryAssessmentForVisit } from '@/app/(main)/consultation/actions';
import { addIopReading } from '@/app/(main)/optometry/actions';

// Same VA scale/field definitions as the optometrist's own entry form
// (app/(main)/optometry/[id]/optometry-workspace.js) -- kept in sync so
// this editable view behaves identically, just reached from Consultation.
const VA_SNELLEN = ['6/6', '6/9', '6/12', '6/18', '6/24', '6/36', '6/60', '3/60', '2/60', '1/60'];
const VA_SPECIAL = ['CF', 'HM', 'PL', 'NPL'];
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

const OBS_CHIPS = ['Poor fixation', 'Excessive blinking', 'Difficulty cooperating', 'Media opacity limiting measurement', 'Nystagmus noted', 'Patient anxious'];

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen',
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1: '', add_k2: '', add_axial_length: '', add_pachymetry: '', add_white_to_white: '', add_schirmer: '',
    add_color_vision: '', add_ocular_motility: '', add_syringing: '',
    observation_chips: [], observations_text: '',
  };
  VA_FIELDS.forEach((f2) => { f[f2.key] = ''; });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['sph', 'cyl', 'axis'].forEach((p) => { f[`ref_${type}_${eye}_${p}`] = ''; });
      if (type === 'final') f[`ref_${type}_${eye}_add`] = '';
    });
  });
  return f;
}

function AsmtSection({ num, color, title, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

function VaOptPills({ values, selected, onSelect }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 6 }}>
      {values.map((v) => (
        <div
          key={v}
          onClick={() => onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
            border: `1.5px solid ${selected === v ? 'var(--teal)' : 'var(--g200)'}`,
            background: selected === v ? 'var(--teal)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
      {VA_SPECIAL.map((v) => (
        <div
          key={v}
          onClick={() => onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
            border: `1.5px dashed ${selected === v ? 'var(--amber)' : 'var(--g200)'}`,
            borderStyle: selected === v ? 'solid' : 'dashed',
            background: selected === v ? 'var(--amber)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
    </div>
  );
}

export default function OptometryTab({ findings, iopReadings, visitId, encounterId, onSaved }) {
  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ va: true, refraction: true, iop: true, additional: false, obs: false });
  const [refTab, setRefTab] = useState('final');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [creating, setCreating] = useState(false);
  const [dirty, setDirty] = useState(false);

  useEffect(() => {
    if (!findings) { setForm(emptyForm()); return; }
    const f = emptyForm();
    Object.keys(f).forEach((key) => {
      if (findings[key] !== null && findings[key] !== undefined) f[key] = findings[key];
    });
    setForm(f);
    setDirty(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- deliberately
    // keyed on the assessment's id, not the findings object itself. Any
    // parent refresh (e.g. another tab saving) creates a new findings
    // object reference for the *same* assessment, and resetting on every
    // such reference change was wiping out not-yet-saved edits in this
    // tab whenever something elsewhere triggered a refresh.
  }, [findings?.id]);

  const [localIopReadings, setLocalIopReadings] = useState(iopReadings || []);
  useEffect(() => {
    setLocalIopReadings(iopReadings || []);
    // Re-sync only when switching to a different assessment, same reasoning as above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [findings?.id]);

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setDirty(true);
  }

  function setRef(type, eye, part, value) {
    setField(`ref_${type}_${eye}_${part}`, value);
  }

  function toggleObsChip(chip) {
    setForm((prev) => {
      const has = prev.observation_chips.includes(chip);
      return { ...prev, observation_chips: has ? prev.observation_chips.filter((c) => c !== chip) : [...prev.observation_chips, chip] };
    });
    setDirty(true);
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value || !findings) return;
    const result = await addIopReading(findings.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setLocalIopReadings((prev) => [...prev, result.reading]);
  }

  async function handleSave() {
    if (!findings) return;
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateOptometryFindings(findings.id, encounterId, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(result.changedCount > 0 ? `Saved -- ${result.changedCount} field(s) updated. Visible in Optometry History.` : 'No changes to save.');
    setDirty(false);
    if (onSaved) onSaved();
  }

  async function handleCreate() {
    setCreating(true);
    setError('');
    const result = await createOptometryAssessmentForVisit(visitId, encounterId);
    setCreating(false);
    if (result.error) { setError(result.error); return; }
    if (onSaved) onSaved();
  }

  const vaScaleValues = vaValuesForScale(form.va_scale);
  const reIopSorted = (localIopReadings || []).filter((r) => r.eye === 'RE');
  const leIopSorted = (localIopReadings || []).filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  if (!findings) {
    return (
      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Findings
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>No optometry assessment on file for this visit.</div>
        <button type="button" className="btn btn-primary" onClick={handleCreate} disabled={creating}>
          {creating ? 'Creating...' : 'Start Assessment Here'}
        </button>
        {error && <div className="msg-err" style={{ marginTop: 10 }}>{error}</div>}
      </div>
    );
  }

  return (
    <div>
      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-edit"></i> Editable -- this is the optometrist's own record. Any change you save here updates it directly and is logged to Optometry History so the optometrist can see what changed.
      </div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={1} color="var(--teal)" title="Visual Acuity" open={openSections.va} onToggle={() => toggleSection('va')}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaOptPills values={vaScaleValues} selected={form[f.key]} onSelect={(v) => setField(f.key, v)} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={2} color="var(--blue)" title="Refraction" open={openSections.refraction} onToggle={() => toggleSection('refraction')}>
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {[['obj', 'Objective (Auto-Rx)'], ['subj', 'Subjective'], ['final', 'Final Rx']].map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>
          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead>
              <tr><th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{refTab === 'final' && <th>ADD (near)</th>}</tr>
            </thead>
            <tbody>
              {['re', 'le'].map((eye) => (
                <tr key={eye}>
                  <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_sph`]} onChange={(e) => setRef(refTab, eye, 'sph', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_cyl`]} onChange={(e) => setRef(refTab, eye, 'cyl', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_axis`]} onChange={(e) => setRef(refTab, eye, 'axis', e.target.value)} placeholder="--" /></td>
                  {refTab === 'final' && (
                    <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_add`]} onChange={(e) => setRef(refTab, eye, 'add', e.target.value)} placeholder="--" /></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div><label className="flbl">Pupillary Distance (PD)</label><input className="fi fi-sm" value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" /></div>
            <div><label className="flbl">Vertex Distance</label><input className="fi fi-sm" value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" /></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={3} color="var(--purple)" title="Intraocular Pressure" open={openSections.iop} onToggle={() => toggleSection('iop')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {['Non-Contact Tonometer (NCT)', 'Goldmann Applanation', 'Perkins', 'Tono-Pen', 'iCare'].map((m) => <option key={m}>{m}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIopSorted, reIopInput, setReIopInput], ['LE', leIopSorted, leIopInput, setLeIopInput]].map(([eye, list, val, setVal]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings yet</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
                <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                  <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                </div>
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={4} color="var(--amber)" title="Additional Measurements" open={openSections.additional} onToggle={() => toggleSection('additional')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><input className="fi fi-sm" value={form.add_k1} onChange={(e) => setField('add_k1', e.target.value)} placeholder="e.g. 43.50 D" /></div>
            <div><label className="flbl">Keratometry K2</label><input className="fi fi-sm" value={form.add_k2} onChange={(e) => setField('add_k2', e.target.value)} placeholder="e.g. 44.25 D" /></div>
            <div><label className="flbl">Axial Length</label><input className="fi fi-sm" value={form.add_axial_length} onChange={(e) => setField('add_axial_length', e.target.value)} placeholder="e.g. 23.2 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><input className="fi fi-sm" value={form.add_pachymetry} onChange={(e) => setField('add_pachymetry', e.target.value)} placeholder="e.g. 542 microns" /></div>
            <div><label className="flbl">White-to-White</label><input className="fi fi-sm" value={form.add_white_to_white} onChange={(e) => setField('add_white_to_white', e.target.value)} placeholder="e.g. 11.8 mm" /></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><input className="fi fi-sm" value={form.add_schirmer} onChange={(e) => setField('add_schirmer', e.target.value)} placeholder="e.g. 8/6 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div>
              <label className="flbl">Color vision</label>
              <select className="fi fi-sm" value={form.add_color_vision} onChange={(e) => setField('add_color_vision', e.target.value)}>
                <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
              </select>
            </div>
            <div>
              <label className="flbl">Ocular motility</label>
              <select className="fi fi-sm" value={form.add_ocular_motility} onChange={(e) => setField('add_ocular_motility', e.target.value)}>
                <option value="">Not tested</option><option>Full in all directions</option><option>Restricted</option><option>Nystagmus present</option>
              </select>
            </div>
            <div>
              <label className="flbl">Syringing</label>
              <select className="fi fi-sm" value={form.add_syringing} onChange={(e) => setField('add_syringing', e.target.value)}>
                <option value="">Not done</option><option>Patent RE</option><option>Patent LE</option><option>Patent bilateral</option><option>Block RE</option><option>Block LE</option>
              </select>
            </div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={5} color="var(--g500)" title="Clinical Observations" open={openSections.obs} onToggle={() => toggleSection('obs')}>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
            {OBS_CHIPS.map((chip) => (
              <div
                key={chip}
                onClick={() => toggleObsChip(chip)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${form.observation_chips.includes(chip) ? 'var(--teal)' : 'var(--g200)'}`, background: form.observation_chips.includes(chip) ? 'var(--teal)' : '#fff', color: form.observation_chips.includes(chip) ? '#fff' : 'var(--g600)' }}
              >
                {chip}
              </div>
            ))}
          </div>
          <label className="flbl">Additional observations</label>
          <textarea className="fi" rows={2} value={form.observations_text} onChange={(e) => setField('observations_text', e.target.value)} placeholder="e.g. Patient had difficulty with right eye assessment due to glare sensitivity..." />
        </AsmtSection>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 4 }}>
        <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving || !dirty}>
          {saving ? 'Saving...' : 'Save Changes'}
        </button>
        {!dirty && <span style={{ fontSize: 11, color: 'var(--g400)' }}>No unsaved changes</span>}
      </div>
    </div>
  );
}
PYEOF_196898862638383432

cat > "app/discharge-summary-print/[episodeId]/page.js" << 'PYEOF_4634598753942405589'
import { createClient } from '@/lib/supabase-server';
import PrintButton from './print-button';

export default async function DischargeSummaryPrintPage({ params }) {
  const { episodeId } = await params;
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();

  if (error || !episode) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Episode not found.</div>;
  }
  if (!episode.discharge_date) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>This patient hasn&apos;t been discharged yet.</div>;
  }

  const sc = episode.surgical_cases;
  const patient = sc.patients;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', episode.visit_id).eq('status', 'Approved'),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  function formatDate(d) {
    if (!d) return '--';
    return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric' });
  }

  function Section({ title, children }) {
    return (
      <div style={{ marginBottom: 18 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#0f766e', textTransform: 'uppercase', letterSpacing: '.4px', borderBottom: '1px solid #e5e7eb', paddingBottom: 4, marginBottom: 8 }}>
          {title}
        </div>
        {children}
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 750, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #0f766e', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#0f766e' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 13, fontWeight: 700, marginTop: 8, color: '#111827' }}>Discharge Summary</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Patient</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{patient?.uhid} -- {patient?.age} {patient?.gender}</div>
          {patient?.mobile && <div style={{ fontSize: 12, color: '#4b5563' }}>{patient.mobile}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Surgeon</div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>Dr. {sc.profiles?.full_name || '--'}</div>
          <div style={{ fontSize: 12, color: '#4b5563', marginTop: 2 }}>Discharged: {formatDate(episode.discharge_date)}</div>
        </div>
      </div>

      <Section title="Episode Dates">
        <div style={{ display: 'flex', gap: 30, fontSize: 13 }}>
          <div><span style={{ color: '#6b7280' }}>Admission: </span>{formatDate(episode.admission_date)}</div>
          <div><span style={{ color: '#6b7280' }}>Surgery: </span>{formatDate(episode.surgery_date)}</div>
          <div><span style={{ color: '#6b7280' }}>Discharge: </span>{formatDate(episode.discharge_date)}</div>
        </div>
      </Section>

      <Section title="Procedure Summary">
        <div style={{ fontSize: 13, padding: '3px 0' }}>Procedure: <strong>{sc.procedure_name}</strong> ({sc.eye})</div>
        {(biometry || []).map((p) => (
          <div key={p.surgical_eye} style={{ fontSize: 13, padding: '3px 0' }}>
            IOL ({p.surgical_eye}): <strong>{intraop?.implant_power || p.final_iol_power} D -- {p.final_iol_category}</strong>
            {intraop?.implant_manufacturer && ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}`}
          </div>
        ))}
      </Section>

      <Section title="Medications">
        {(meds || []).length === 0 && <div style={{ fontSize: 12, color: '#9ca3af' }}>None prescribed.</div>}
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <tbody>
            {(meds || []).map((m) => (
              <tr key={m.id}>
                <td style={{ padding: '4px 8px 4px 0', fontWeight: 600 }}>{m.name}</td>
                <td style={{ padding: '4px 0', color: '#4b5563' }}>{m.sig}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      {episode.discharge_notes && (
        <Section title="Discharge Notes (Doctor)">
          <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{episode.discharge_notes}</div>
        </Section>
      )}

      <Section title="Discharge Instructions">
        <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{episode.discharge_instructions || 'As advised by the surgeon.'}</div>
      </Section>

      <Section title="Follow-up Schedule">
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
          <thead>
            <tr style={{ background: '#f0fdfa' }}>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Visit</th>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Date</th>
              <th style={{ textAlign: 'left', padding: '5px 8px', color: '#0f766e' }}>Status</th>
            </tr>
          </thead>
          <tbody>
            {(followups || []).map((f) => (
              <tr key={f.id}>
                <td style={{ padding: '4px 8px' }}>{f.visit_label}</td>
                <td style={{ padding: '4px 8px', color: '#4b5563' }}>{formatDate(f.scheduled_date)}</td>
                <td style={{ padding: '4px 8px', color: '#4b5563' }}>{f.status}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </Section>

      <div style={{ marginTop: 50, display: 'flex', justifyContent: 'flex-end' }}>
        <div style={{ textAlign: 'center', borderTop: '1px solid #9ca3af', paddingTop: 6, width: 220 }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>Dr. {sc.profiles?.full_name || '--'}</div>
          <div style={{ fontSize: 10, color: '#9ca3af' }}>Signature</div>
        </div>
      </div>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated discharge summary -- Veda Eye Hospital.
      </div>
    </div>
  );
}

PYEOF_4634598753942405589

cat > "app/print-templates/actions.js" << 'PYEOF_8273931512703693147'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';

// ── Editable print templates ──────────────────────────────────────────
// Each template's HTML lives here as a code-level DEFAULT (versioned,
// reviewable) which the database can override once someone edits and
// saves it from the Print Templates admin page. getPrintTemplate()
// always returns *something renderable* -- the DB row if one exists,
// otherwise this default -- so there's never a missing-template state.
//
// Hospital-wide info (name, address, logo, etc) is deliberately NOT
// hardcoded into these templates -- it lives in hospital_settings and
// gets merged into the render context, edited once as a proper form
// rather than hunted down inside every template's HTML.
//
// Templates use Handlebars {field} tokens ({{field}} for the one
// HTML field, the logo). All formatting (currency, dates) happens in
// the *data-building* functions below, so editors only ever see plain
// tokens, never format-string logic.

const DEFAULT_TEMPLATES = {
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PROCEDURE</td><td>: <strong>{{procedure}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PROCEDURE</td><td>: <strong>{{procedure}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Chief Complaint</div>\n    <div style=\"font-size: 12.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">IOP (mmHg)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n      {{#if hasRefraction}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Refraction (Sph/Cyl/Axis)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_refraction}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_refraction}}</td>\n      </tr>\n      {{/if}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 12.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{drug}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dosage}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{duration}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Advice</div>\n    <div style=\"font-size: 12.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #123a66; margin-bottom: 16px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Coming soon.', comingSoon: true },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Coming soon.', comingSoon: true },
];

// ── Hospital Settings -- the "actual fields to edit" form (name,
//    address, logo, etc), shared across every template. Singleton row
//    (id is always `true`). ──
export async function getHospitalSettings() {
  const supabase = await createClient();
  const { data } = await supabase.from('hospital_settings').select('*').eq('id', true).maybeSingle();
  return data || {};
}

export async function saveHospitalSettings(fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('hospital_settings').update({
    ...fields, updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }).eq('id', true);
  if (error) return { error: error.message };
  return { success: true };
}

function logoHtml(settings) {
  if (settings?.logo_data_url) {
    return `<img src="${settings.logo_data_url}" style="width: 88px; height: 88px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="88" height="88" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
    <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>
    <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>
    <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>
  </svg>`;
}

export async function listPrintTemplates() {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('template_key, updated_at, updated_by, profiles(full_name)');
  const byKey = {};
  (data || []).forEach((r) => { byKey[r.template_key] = r; });
  return PRINT_TEMPLATE_CATALOG.map((t) => ({
    ...t,
    customized: !!byKey[t.key],
    updatedAt: byKey[t.key]?.updated_at || null,
    updatedBy: byKey[t.key]?.profiles?.full_name || null,
  }));
}

export async function getPrintTemplate(key) {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('html, updated_at').eq('template_key', key).maybeSingle();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  return {
    key,
    name: catalog?.name || key,
    html: data?.html || DEFAULT_TEMPLATES[key] || '<div>No template found.</div>',
    isCustomized: !!data,
    updatedAt: data?.updated_at || null,
  };
}

export async function savePrintTemplate(key, html) {
  const supabase = await createClient();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('print_templates').upsert({
    template_key: key, name: catalog?.name || key, html,
    updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }, { onConflict: 'template_key' });
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetPrintTemplate(key) {
  const supabase = await createClient();
  const { error } = await supabase.from('print_templates').delete().eq('template_key', key);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Preview arbitrary (possibly unsaved) template HTML against sample
//    data -- lets the editor see changes before committing them. ──
export async function previewTemplateHtml(key, html) {
  try {
    const compiled = Handlebars.compile(html);
    return { html: compiled(await getSampleData(key)) };
  } catch (e) {
    return { error: `Template error: ${e.message}` };
  }
}

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  const settings = await getHospitalSettings();
  if (key === 'invoice_opd') return buildInvoiceContext(settings, SAMPLE_OPD_RAW);
  if (key === 'invoice_surgery') return buildInvoiceContext(settings, SAMPLE_SURGERY_RAW);
  if (key === 'receipt') return buildReceiptContext(settings, SAMPLE_RECEIPT_RAW);
  if (key === 'receipt_advance') return buildReceiptContext(settings, SAMPLE_ADVANCE_RAW);
  if (key === 'opd_case_sheet') return buildOpdCaseSheetContext(settings, SAMPLE_CASE_SHEET_RAW);
  return {};
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, dischargeDate: null,
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', dischargeDate: '2026-06-11T00:00:00Z',
};

const SAMPLE_RECEIPT_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970' },
  payment: {
    receipt_number: 'VEH/RECEIPT/-0054', collected_at: '2026-06-03T00:00:00Z', total_amount: 300,
    payment_type: 'invoice_payment', reference: null, remarks: null,
  },
  collector: { full_name: 'Front Desk' },
  modes: [{ mode: 'Cash', amount: 300 }],
  allocations: [{ amount: 300, invoices: { invoice_number: 'VEH-BILL-0143' } }],
};

const SAMPLE_ADVANCE_RAW = {
  ...SAMPLE_RECEIPT_RAW,
  payment: {
    receipt_number: 'VEH/RECEIPT/-0060', collected_at: '2026-06-15T00:00:00Z', total_amount: 10000,
    payment_type: 'advance', reference: null, remarks: null,
  },
  modes: [{ mode: 'UPI', amount: 10000 }],
  allocations: [],
};

const SAMPLE_CASE_SHEET_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  encounter: {
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes',
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    ref_final_re_sph: '-2.00', ref_final_re_cyl: '-0.50', ref_final_re_axis: '90',
    ref_final_le_sph: '-1.50', ref_final_le_cyl: '-0.25', ref_final_le_axis: '85',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: lineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (lineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let dischargeDate = null;
  if (isSurgery && invoice.visit_id) {
    const { data: surgicalCase } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, master_packages:package_id(name)')
      .eq('visit_id', invoice.visit_id)
      .neq('status', 'Cancelled')
      .maybeSingle();
    packageName = surgicalCase?.master_packages?.name || null;
    if (surgicalCase) {
      const { data: episode } = await supabase
        .from('recovery_episodes')
        .select('discharge_date')
        .eq('surgical_case_id', surgicalCase.id)
        .maybeSingle();
      dischargeDate = episode?.discharge_date || null;
    }
  }

  const settings = await getHospitalSettings();
  const context = buildInvoiceContext(settings, {
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    dischargeDate,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, dischargeDate }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    terms_text: settings.terms_text || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',
    package_name: packageName || '--',
    discharge_date: fmtDate(dischargeDate),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1, name: li.service_name, qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}

const PAYMENT_TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

// ── Renders the actual receipt HTML for a given paymentId. Picks the
//    Advance Receipt variant when payment_type is 'advance' (a fresh
//    advance collection, not yet applied to any invoice); everything
//    else (a regular payment, or an advance being adjusted against an
//    invoice) uses the standard Payment Receipt. ──
export async function renderReceiptHtml(paymentId) {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(uhid, first_name, last_name, mobile), profiles:collected_by(full_name)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: 'Receipt not found.' };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const settings = await getHospitalSettings();
  const context = buildReceiptContext(settings, {
    patient: {
      patient_code: payment.patients?.uhid, first_name: payment.patients?.first_name, last_name: payment.patients?.last_name,
      mobile: payment.patients?.mobile,
    },
    payment,
    collector: payment.profiles,
    modes: modes || [],
    allocations: allocations || [],
  });

  const templateKey = payment.payment_type === 'advance' ? 'receipt_advance' : 'receipt';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildReceiptContext(settings, { patient, payment, collector, modes, allocations }) {
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_id: patient.patient_code || '--',
    patient_mobile: patient.mobile || '--',

    receipt_no: payment.receipt_number,
    receipt_date: fmtDate(payment.collected_at),
    payment_type_label: PAYMENT_TYPE_LABEL[payment.payment_type] || payment.payment_type,
    collected_by: collector?.full_name || '--',

    amount_received: inr(payment.total_amount),
    amount_in_words: amountInWords(payment.total_amount),

    hasAllocations: (allocations || []).length > 0,
    allocations: (allocations || []).map((a) => ({ invoiceNumber: a.invoices?.invoice_number || '--', amount: inr(a.amount) })),

    modes: (modes || []).map((m) => ({ mode: m.mode, amount: inr(m.amount) })),

    reference: payment.reference || null,
    remarks: payment.remarks || null,
  };
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

function twoDigitWords(n) {
  if (n < 20) return ONES[n];
  return `${TENS[Math.floor(n / 10)]}${n % 10 ? ' ' + ONES[n % 10] : ''}`;
}
function threeDigitWords(n) {
  if (n < 100) return twoDigitWords(n);
  return `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? ' ' + twoDigitWords(n % 100) : ''}`;
}

// Indian numbering (lakh/crore), matching how amounts are normally
// written out on Indian receipts.
function amountInWords(amount) {
  let n = Math.round(Number(amount || 0));
  if (n === 0) return 'Rupees Zero Only';
  const parts = [];
  const crore = Math.floor(n / 10000000); n %= 10000000;
  const lakh = Math.floor(n / 100000); n %= 100000;
  const thousand = Math.floor(n / 1000); n %= 1000;
  const hundred = n;
  if (crore) parts.push(`${threeDigitWords(crore)} Crore`);
  if (lakh) parts.push(`${threeDigitWords(lakh)} Lakh`);
  if (thousand) parts.push(`${threeDigitWords(thousand)} Thousand`);
  if (hundred) parts.push(threeDigitWords(hundred));
  return `Rupees ${parts.join(' ')} Only`;
}

// ── Renders the OPD Case Sheet for a given encounterId -- the
//    patient-facing handout: chief complaint, vision/IOP/refraction,
//    diagnosis, prescription, advice, and follow-up. ──
export async function renderOpdCaseSheetHtml(encounterId) {
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(id, created_at, visit_type, doctor_id, patients(uhid, first_name, last_name, mobile, age, gender), profiles:doctor_id(full_name, registration_no))')
    .eq('id', encounterId)
    .single();
  if (error || !encounter) return { error: 'Consultation not found.' };

  const visit = encounter.visits;

  const { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visit?.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let iopReadings = [];
  if (assessment) {
    const { data: readings } = await supabase.from('optometry_iop_readings').select('eye, value').eq('assessment_id', assessment.id);
    iopReadings = readings || [];
  }

  const { data: diagnoses } = await supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: prescriptions } = await supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: followup } = await supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle();

  const settings = await getHospitalSettings();
  const context = buildOpdCaseSheetContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      mobile: visit?.patients?.mobile, age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    encounter,
    visit,
    doctor: visit?.profiles,
    assessment,
    iopReadings,
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function refractionStr(sph, cyl, axis) {
  if (!sph && !cyl && !axis) return '--';
  return `${sph || '--'} / ${cyl || '--'} x ${axis || '--'}`;
}

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, diagnoses, prescriptions, followup }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const hasRefraction = !!(assessment?.ref_final_re_sph || assessment?.ref_final_le_sph);

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,

    hasVision: !!assessment,
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    hasRefraction,
    re_refraction: refractionStr(assessment?.ref_final_re_sph, assessment?.ref_final_re_cyl, assessment?.ref_final_re_axis),
    le_refraction: refractionStr(assessment?.ref_final_le_sph, assessment?.ref_final_le_cyl, assessment?.ref_final_le_axis),

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: prescriptions.map((p) => ({ drug: p.drug, eye: p.eye, dosage: p.dosage, frequency: p.frequency, duration: p.duration })),

    advice: encounter.patient_instructions || null,
    followup_text: followupParts.length > 0 ? followupParts.join(' ') : null,
  };
}
PYEOF_8273931512703693147

cat > "app/visit-summary-print/[encounterId]/page.js" << 'PYEOF_2172807090578560424'
import { createClient } from '@/lib/supabase-server';
import PrintButton from './print-button';

export default async function VisitSummaryPrintPage({ params }) {
  const { encounterId } = await params;
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(visit_number, patients(first_name, last_name, uhid, age, gender, mobile))')
    .eq('id', encounterId)
    .single();

  if (error || !encounter) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Visit not found.</div>;
  }

  let doctorName = '--';
  if (encounter.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', encounter.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounterId).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle(),
  ]);

  const patient = encounter.visits?.patients;
  const visitNumber = encounter.visits?.visit_number;
  const visitDate = new Date(encounter.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'long', year: 'numeric' });

  function Section({ title, children }) {
    return (
      <div style={{ marginBottom: 18 }}>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#1e3a8a', textTransform: 'uppercase', letterSpacing: '.4px', borderBottom: '1px solid #e5e7eb', paddingBottom: 4, marginBottom: 8 }}>
          {title}
        </div>
        {children}
      </div>
    );
  }

  return (
    <div style={{ maxWidth: 750, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #1d4ed8', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#1e3a8a' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 13, fontWeight: 700, marginTop: 8, color: '#111827' }}>Visit Summary</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Patient</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{patient?.uhid} -- {patient?.age} {patient?.gender}</div>
          {patient?.mobile && <div style={{ fontSize: 12, color: '#4b5563' }}>{patient.mobile}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Visit</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{visitNumber || '--'}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{visitDate}</div>
          <div style={{ fontSize: 12, color: '#4b5563', marginTop: 2 }}>Dr. {doctorName}</div>
        </div>
      </div>

      {encounter.chief_complaint && (
        <Section title="Chief Complaint">
          <div style={{ fontSize: 13 }}>{encounter.chief_complaint}</div>
        </Section>
      )}

      <Section title="Diagnosis">
        {(diagnoses || []).length === 0 && <div style={{ fontSize: 12, color: '#9ca3af' }}>No diagnosis recorded.</div>}
        {(diagnoses || []).map((d) => (
          <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 13 }}>
            <span>
              <strong>{d.name}</strong> -- {d.eye}
            </span>
            <span style={{ color: '#6b7280', fontSize: 11, textTransform: 'capitalize' }}>{d.category}</span>
          </div>
        ))}
      </Section>

      {(prescriptions || []).length > 0 && (
        <Section title="Prescription">
          <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
            <thead>
              <tr style={{ borderBottom: '1px solid #d1d5db' }}>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Drug</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Dosage</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Frequency</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Duration</th>
                <th style={{ textAlign: 'left', padding: '4px 4px' }}>Eye</th>
              </tr>
            </thead>
            <tbody>
              {prescriptions.map((r) => (
                <tr key={r.id} style={{ borderBottom: '1px solid #f3f4f6' }}>
                  <td style={{ padding: '4px 4px', fontWeight: 600 }}>{r.drug_name}</td>
                  <td style={{ padding: '4px 4px' }}>{r.dosage}</td>
                  <td style={{ padding: '4px 4px' }}>{r.frequency}</td>
                  <td style={{ padding: '4px 4px' }}>{r.duration}</td>
                  <td style={{ padding: '4px 4px' }}>{r.eye}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </Section>
      )}

      {(investigations || []).length > 0 && (
        <Section title="Investigations Ordered">
          {investigations.map((i) => (
            <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 13 }}>
              <span><strong>{i.name}</strong> -- {i.eye}</span>
              <span style={{ color: '#6b7280', fontSize: 11 }}>{i.priority}</span>
            </div>
          ))}
        </Section>
      )}

      {((opticalAdvice || []).length > 0 || (procedures || []).length > 0 || (referrals || []).length > 0 || (counsellingItems || []).length > 0) && (
        <Section title="Management Plan">
          {(opticalAdvice || []).map((o) => (
            <div key={o.id} style={{ fontSize: 13, padding: '3px 0' }}>-- {o.advice}</div>
          ))}
          {(procedures || []).map((p) => (
            <div key={p.id} style={{ fontSize: 13, padding: '3px 0' }}>-- {p.name} ({p.eye})</div>
          ))}
          {(referrals || []).map((r) => (
            <div key={r.id} style={{ fontSize: 13, padding: '3px 0' }}>-- Referral: {r.destination}{r.reason ? ` (${r.reason})` : ''}</div>
          ))}
          {(counsellingItems || []).map((c) => (
            <div key={c.id} style={{ fontSize: 13, padding: '3px 0' }}>-- Counselling: {c.topic}</div>
          ))}
        </Section>
      )}

      {followup && (
        <Section title="Follow-up">
          <div style={{ fontSize: 13 }}>
            {followup.after_period} -- {followup.visit_type} -- {followup.clinic} clinic
          </div>
          {followup.instructions && <div style={{ fontSize: 12, color: '#4b5563', marginTop: 4 }}>{followup.instructions}</div>}
        </Section>
      )}

      {encounter.patient_instructions && (
        <Section title="Patient Instructions">
          <div style={{ fontSize: 13, whiteSpace: 'pre-wrap' }}>{encounter.patient_instructions}</div>
        </Section>
      )}

      <div style={{ marginTop: 50, display: 'flex', justifyContent: 'flex-end' }}>
        <div style={{ textAlign: 'center', borderTop: '1px solid #9ca3af', paddingTop: 6, width: 220 }}>
          <div style={{ fontSize: 12, fontWeight: 600 }}>Dr. {doctorName}</div>
          <div style={{ fontSize: 10, color: '#9ca3af' }}>Signature</div>
        </div>
      </div>

      <div style={{ marginTop: 30, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated visit summary.
      </div>
    </div>
  );
}
PYEOF_2172807090578560424

echo "Files written. Run: npm run build"
