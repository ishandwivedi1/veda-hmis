#!/bin/bash
set -e
echo "Applying: sticky billing tabs, remove stat cards, move revenue-by-dept to cash mgmt, unified pending billing widget"

rm -f "app/(main)/billing/investigations-billing-widget.js"
rm -f "app/(main)/billing/procedures-billing-widget.js"
rm -f "app/(main)/billing/pharmacy-billing-widget.js"
rm -f "app/(main)/billing/biometry-billing-widget.js"
rm -f "app/(main)/billing/package-billing-widget.js"

cat > "app/(main)/billing/pending-billing-widget.js" << 'PYEOF_8820576805169754833'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingInvestigationBilling, markInvestigationDenied, markInvestigationDeferred, resetInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingProcedureBilling, getPendingPackageBilling } from '@/app/(main)/billing/actions';
import { getPendingPrescriptionsForFrontOffice, markPrescriptionDenied, markPrescriptionDeferred, resetPrescriptionBilling } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling, markBiometryDenied, markBiometryDeferred, resetBiometryBilling } from '@/app/(main)/biometry/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

const TYPE_META = {
  Investigation: { icon: 'ti-flask', color: 'var(--teal)' },
  Procedure: { icon: 'ti-tool', color: 'var(--blue)' },
  Pharmacy: { icon: 'ti-pill', color: 'var(--purple)' },
  Biometry: { icon: 'ti-ruler-measure', color: 'var(--indigo)' },
  Package: { icon: 'ti-package', color: 'var(--green)' },
};

// One row of items within a patient's card for a single pending-billing
// type (e.g. their pending investigations). Handles its own defer/deny/
// reset actions where that type supports them.
function TypeSection({ type, group, busyId, onDefer, onDeny, onReset, onBillNow, renderItem }) {
  const meta = TYPE_META[type];
  return (
    <div style={{ marginTop: 8, paddingTop: 8, borderTop: '1px dashed var(--g200)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: meta.color }}>
          <i className={`ti ${meta.icon}`}></i> {type}
        </span>
        <button className="btn btn-sm" style={{ fontSize: 10, padding: '2px 8px' }} onClick={() => onBillNow(group)}>
          <i className="ti ti-receipt"></i> Bill Now
        </button>
      </div>
      {group.items.map((item) => (
        <div key={item.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12, flexWrap: 'wrap', gap: 4 }}>
          <div>
            {renderItem(item)}
            {item.billing_status && <span className={`badge ${BILLING_BADGE[item.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{item.billing_status}</span>}
          </div>
          {item.billing_status && (
            <div style={{ display: 'flex', gap: 4 }}>
              {item.billing_status === 'Pending' && onDefer && (
                <>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onDefer(item.id)}>
                    <i className="ti ti-clock"></i>
                  </button>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === item.id} onClick={() => onDeny(item.id)}>
                    <i className="ti ti-x"></i>
                  </button>
                </>
              )}
              {item.billing_status === 'Deferred' && onReset && (
                <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onReset(item.id)}>
                  Reset
                </button>
              )}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

export default function PendingBillingWidget() {
  const [investigations, setInvestigations] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [pharmacy, setPharmacy] = useState([]);
  const [biometry, setBiometry] = useState([]);
  const [packages, setPackages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState(null);
  const router = useRouter();

  const load = useCallback(async () => {
    const [inv, proc, rx, bio, pkg] = await Promise.all([
      getPendingInvestigationBilling(),
      getPendingProcedureBilling(),
      getPendingPrescriptionsForFrontOffice(),
      getPendingBiometryBilling(),
      getPendingPackageBilling(),
    ]);
    setInvestigations(inv);
    setProcedures(proc);
    setPharmacy(rx);
    setBiometry(bio);
    setPackages(pkg);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function withBusy(id, fn) {
    setBusyId(id);
    await fn(id);
    await load();
    setBusyId(null);
  }

  // Group everything by patient id -- package billing has no visitId, so
  // patient id is the only key common to all five sources.
  const byPatient = {};
  function ensurePatient(patient) {
    if (!patient?.id) return null;
    if (!byPatient[patient.id]) byPatient[patient.id] = { patient, types: {} };
    return byPatient[patient.id];
  }

  investigations.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Investigation = g; });
  procedures.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Procedure = g; });
  pharmacy.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Pharmacy = g; });
  biometry.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Biometry = g; });
  packages.forEach((sc) => {
    const p = ensurePatient(sc.patients);
    if (!p) return;
    if (!p.types.Package) p.types.Package = { visitId: null, items: [] };
    p.types.Package.items.push(sc);
  });

  const patients = Object.values(byPatient);
  const totalItems = patients.reduce((s, p) => s + Object.values(p.types).reduce((s2, g) => s2 + g.items.length, 0), 0);

  function billNowFor(type, group) {
    const ids = group.items.map((i) => i.id).join(',');
    const param = { Investigation: 'invOrderIds', Procedure: 'procIds', Pharmacy: 'rxIds', Biometry: 'bioIds' }[type];
    router.push(`/billing/new?visitId=${group.visitId}&${param}=${ids}`);
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-clipboard-list" style={{ color: 'var(--red)' }}></i> Pending Billing</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Everything prescribed or recommended for a patient, not yet billed -- grouped by patient across investigations, procedures, pharmacy, biometry, and packages.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && patients.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- everything is billed.</div>
      )}

      {!loading && patients.map(({ patient, types }) => (
        <div key={patient.id} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <div style={{ fontWeight: 600, fontSize: 13 }}>{patient.first_name} {patient.last_name}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{patient.uhid}</div>
            <div style={{ display: 'flex', gap: 4, marginLeft: 'auto' }}>
              {Object.keys(types).map((type) => (
                <span key={type} className="badge" style={{ background: `${TYPE_META[type].color}20`, color: TYPE_META[type].color, fontSize: 9 }}>{type}</span>
              ))}
            </div>
          </div>

          {types.Investigation && (
            <TypeSection
              type="Investigation" group={types.Investigation} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markInvestigationDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markInvestigationDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetInvestigationBilling)}
              onBillNow={(g) => billNowFor('Investigation', g)}
              renderItem={(io) => <>{io.name} <span style={{ color: 'var(--g400)' }}>({io.eye})</span></>}
            />
          )}
          {types.Procedure && (
            <TypeSection
              type="Procedure" group={types.Procedure} busyId={busyId}
              onBillNow={(g) => billNowFor('Procedure', g)}
              renderItem={(p) => <>{p.name} <span style={{ color: 'var(--g400)' }}>({p.eye})</span>{p.notes && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.notes}</div>}</>}
            />
          )}
          {types.Pharmacy && (
            <TypeSection
              type="Pharmacy" group={types.Pharmacy} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markPrescriptionDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markPrescriptionDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetPrescriptionBilling)}
              onBillNow={(g) => billNowFor('Pharmacy', g)}
              renderItem={(rx) => <>{rx.drug_name} <span style={{ color: 'var(--g400)' }}>({rx.eye})</span></>}
            />
          )}
          {types.Biometry && (
            <TypeSection
              type="Biometry" group={types.Biometry} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markBiometryDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markBiometryDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetBiometryBilling)}
              onBillNow={(g) => billNowFor('Biometry', g)}
              renderItem={() => <>Biometry</>}
            />
          )}
          {types.Package && (
            <div style={{ marginTop: 8, paddingTop: 8, borderTop: '1px dashed var(--g200)' }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: TYPE_META.Package.color, marginBottom: 4 }}>
                <i className={`ti ${TYPE_META.Package.icon}`}></i> Package
              </div>
              {types.Package.items.map((sc) => (
                <div key={sc.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12, flexWrap: 'wrap', gap: 4 }}>
                  <div>
                    {sc.procedure_name} <span style={{ color: 'var(--g400)' }}>({sc.eye})</span> -- <span style={{ color: 'var(--green)' }}>{sc.master_packages?.name}: Rs.{Number(sc.master_packages?.price || 0).toLocaleString('en-IN')}</span>
                  </div>
                  <button className="btn btn-sm" style={{ fontSize: 10, padding: '2px 8px' }} onClick={() => router.push(`/billing/new?pkgCaseId=${sc.id}`)}>
                    <i className="ti ti-receipt"></i> Bill Now
                  </button>
                </div>
              ))}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}
PYEOF_8820576805169754833

cat > "app/(main)/billing/actions.js" << 'PYEOF_5414955742037717051'
'use server';

import { createClient } from '@/lib/supabase-server';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';

// Same IST-boundary approach as Cash Management -- a plain date string
// compared against a timestamptz column is interpreted at UTC midnight
// by Postgres, not IST midnight, so "today's revenue" would otherwise
// drift by up to 5.5 hours depending on the time of day.
function istDayBoundsUTC() {
  const d = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  return {
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

// ── WS-086: BILLING DASHBOARD -- Recent Invoices + Outstanding Invoices.
// (Revenue-by-department and the daily revenue/collected/cancelled
// stats moved to the Cash Management dashboard.) ──
export async function getBillingDashboardData() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [{ data: todaysInvoices }, { data: allOutstanding }] = await Promise.all([
    supabase
      .from('invoices')
      .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
      .gte('created_at', startUTC)
      .lte('created_at', endUTC)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false }),
    supabase
      .from('invoices')
      .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
      .in('status', ['Pending', 'Partial'])
      .order('created_at', { ascending: true }),
  ]);

  const outstandingInvoices = allOutstanding || [];
  const outstandingTotal = outstandingInvoices.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);

  return {
    todaysInvoices: todaysInvoices || [],
    outstandingInvoices,
    outstandingTotal,
  };
}

// ── TODAY'S VISITS (with per-visit billing status) -- moved here from
// Front Office Dashboard, since New Invoice / Modify are billing
// actions. Front Office keeps its own read-only version of this same
// list without these actions. ──
export async function getTodaysVisitsWithBillingStatus() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: visits } = await supabase
    .from('visits')
    .select('*, patients(id, first_name, last_name, uhid), profiles!doctor_id(full_name)')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .order('created_at', { ascending: false });

  const visitIds = (visits || []).map((v) => v.id);
  const billingByVisit = {};
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

  return { visits: visits || [], billingByVisit };
}

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



PYEOF_5414955742037717051

cat > "app/(main)/billing/page.js" << 'PYEOF_8955204562841540782'
import Link from 'next/link';
import BillingTabs from './billing-tabs';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus } from './actions';
import RecentInvoicesTable from './recent-invoices-table';
import PendingBillingWidget from './pending-billing-widget';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

export default async function BillingDashboardPage() {
  const [data, todaysVisitsData] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
  ]);
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />

      {/* TODAY'S VISITS + PENDING BILLING side by side */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <table className="tbl">
            <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
            <tbody>
              {todaysVisits.map((v) => {
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
              {todaysVisits.length === 0 && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <PendingBillingWidget />
      </div>

      {/* RECENT INVOICES + OUTSTANDING */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        <RecentInvoicesTable invoices={data.todaysInvoices} />

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Outstanding Invoices</div>
            <span className="badge b-amber">{data.outstandingInvoices.length} pending</span>
          </div>
          <div style={{ maxHeight: 320, overflowY: 'auto' }}>
            {data.outstandingInvoices.map((inv) => (
              <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <div style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{inv.patients?.uhid} -- {inv.purpose || '--'}</div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontWeight: 700, color: 'var(--red)' }}>{RUPEE(Number(inv.net) - Number(inv.paid))}</div>
                  <Link href={`/payments/collect?patientId=${inv.patient_id}&invoiceId=${inv.id}`} style={{ fontSize: 11, color: 'var(--blue)', textDecoration: 'none' }}>
                    Collect &rarr;
                  </Link>
                </div>
              </div>
            ))}
            {data.outstandingInvoices.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>Nothing outstanding.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
PYEOF_8955204562841540782

cat > "app/(main)/billing/billing-tabs.js" << 'PYEOF_7621825012235975523'
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
      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap', position: 'sticky', top: 0, zIndex: 8, background: '#fff', padding: '8px 0' }}>
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


PYEOF_7621825012235975523

cat > "app/(main)/cash-management/actions.js" << 'PYEOF_9120490810207557052'
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

// ── REVENUE BY DEPARTMENT -- moved here from the Billing Dashboard,
// since it's a same-day revenue breakdown that belongs alongside the
// rest of today's collection summary. ──
export async function getRevenueByDepartmentToday() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: invoices } = await supabase
    .from('invoices')
    .select('purpose, net')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .neq('status', 'Cancelled');

  const byDept = {};
  (invoices || []).forEach((i) => {
    const dept = i.purpose || 'Other';
    byDept[dept] = (byDept[dept] || 0) + Number(i.net);
  });

  return byDept;
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

PYEOF_9120490810207557052

cat > "app/(main)/cash-management/page.js" << 'PYEOF_4170246803234702771'
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
  getRevenueByDepartmentToday,
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
  const [revenueByDept, setRevenueByDept] = useState({});
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
    setRevenueByDept(await getRevenueByDepartmentToday());
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

          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-bar" style={{ color: 'var(--amber)' }}></i> Revenue by Department -- Today
            </div>
            {Object.keys(revenueByDept).length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices yet today.</div>}
            {Object.entries(revenueByDept).sort((a, b) => b[1] - a[1]).map(([dept, amount]) => {
              const max = Math.max(...Object.values(revenueByDept));
              return (
                <div key={dept} style={{ marginBottom: 10 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                    <span>{dept}</span><span style={{ fontWeight: 600 }}>{fmt(amount)}</span>
                  </div>
                  <div style={{ height: 8, background: 'var(--g100)', borderRadius: 4 }}>
                    <div style={{ width: `${max ? (amount / max) * 100 : 0}%`, height: '100%', background: 'var(--amber)', borderRadius: 4 }}></div>
                  </div>
                </div>
              );
            })}
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

PYEOF_4170246803234702771

echo "Files written. Run: npm run build"
