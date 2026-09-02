'use server';

import { createClient } from '@/lib/supabase-server';
import { formatPatientName } from '@/lib/patientName';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';
import { generateInvoicePdfBuffer } from '@/lib/pdf-generator';
import { sendInvoiceBillWhatsApp } from '@/lib/whatsapp';

// Shared by the auto-send-on-full-payment trigger (collectPayment, in
// payments/actions.js) and the manual "Resend WhatsApp Bill" button.
// force=false (automatic) skips sending if this invoice was already
// successfully sent before, so collect_payment being called more than
// once doesn't spam the patient. force=true (manual) always sends.
export async function sendInvoiceBill(invoiceId, { force = false, triggeredBy = null } = {}) {
  const supabase = await createClient();

  if (!force) {
    const { data: existing } = await supabase
      .from('whatsapp_logs')
      .select('id')
      .eq('invoice_id', invoiceId)
      .eq('module', 'invoice_bill')
      .eq('success', true)
      .limit(1);
    if (existing && existing.length > 0) return { skipped: true };
  }

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, patient_id, patients(id, first_name, salutation, last_name, mobile)')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: error?.message || 'Invoice not found.' };
  if (!invoice.patients?.mobile) return { error: 'Patient has no mobile number on file.' };

  const pdfResult = await generateInvoicePdfBuffer(invoiceId);
  if (pdfResult.error) return { success: false, error: pdfResult.error };

  return sendInvoiceBillWhatsApp({
    name: `${formatPatientName(invoice.patients)}`.trim(),
    invoiceNumber: invoice.invoice_number,
    amount: invoice.net,
    mobile: invoice.patients.mobile,
    pdfBuffer: pdfResult.buffer,
    filename: `${invoice.invoice_number || 'Invoice'}.pdf`,
    patientDbId: invoice.patient_id,
    invoiceDbId: invoice.id,
    meta: { module: 'invoice_bill', triggeredBy },
  });
}

// Manual resend, exposed to the "Resend WhatsApp Bill" button -- always
// sends regardless of whether it was sent automatically before.
export async function resendInvoiceBillWhatsApp(invoiceId) {
  if (!invoiceId) return { error: 'Missing invoice id.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  const result = await sendInvoiceBill(invoiceId, { force: true, triggeredBy: user?.id || null });
  if (!result.success) return { error: result.error || 'Failed to send WhatsApp bill.' };
  if (result.logError) return { success: true, warning: `Message sent, but audit logging failed: ${result.logError}` };
  return { success: true };
}

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
      .select('*, patients(first_name, salutation, last_name, uhid), visits(visit_number)')
      .gte('created_at', startUTC)
      .lte('created_at', endUTC)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false }),
    supabase
      .from('invoices')
      .select('*, patients(first_name, salutation, last_name, uhid), visits(visit_number)')
      .in('status', ['Pending', 'Partial'])
      .order('created_at', { ascending: true }),
  ]);

  const outstandingInvoices = allOutstanding || [];
  const outstandingTotal = outstandingInvoices.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);

  // Split out of the same list rather than a second query -- "today's
  // outstanding" is just the subset of allOutstanding created within
  // today's IST bounds. Mirrors the todayOnly/all-time split already
  // used by Pending Billing, so the Outstanding stat card can honour
  // the same Today/Historical toggle instead of always showing the
  // all-time figure.
  const outstandingInvoicesToday = outstandingInvoices.filter(
    (i) => i.created_at >= startUTC && i.created_at <= endUTC
  );
  const outstandingTotalToday = outstandingInvoicesToday.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);

  return {
    todaysInvoices: todaysInvoices || [],
    outstandingInvoices,
    outstandingTotal,
    outstandingInvoicesToday,
    outstandingTotalToday,
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
    .select('*, patients(id, first_name, salutation, last_name, uhid), profiles!doctor_id(full_name)')
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
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, salutation, last_name, uhid)')
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
    .select('*, patients(id, first_name, salutation, last_name, uhid, mobile)')
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
    name: `${d.brand || d.generic}${d.strength ? ' ' + d.strength : ''}${d.brand && d.generic ? ' (' + d.generic + ')' : ''}`,
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

// For ad-hoc line items with no catalog entry behind them -- currently
// only the consolidated "OPD Procedure Consumables" pharmacy line
// (medicines clubbed into one line + total, since there's no pharmacy
// license yet to itemize them). Always qty 1, no GST/discount.
export async function addCustomLineItem(invoiceId, serviceName, amount, dept) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_custom_line_item', {
    p_invoice_id: invoiceId,
    p_service_name: serviceName,
    p_amount: amount,
    p_dept: dept || 'Pharmacy',
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
    .select('id, uhid, first_name, salutation, last_name, mobile')
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

// Full visit history for a patient, for the "Visit" dropdown on New
// Invoice -- lets the front desk pick which visit an invoice attaches
// to instead of always silently defaulting to the most recent one.
export async function getVisitsForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, status, created_at')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getVisitWithPatient(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('visits')
    .select('*, patients(id, first_name, salutation, last_name, uhid, mobile)')
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
// includeBilled=true returns every procedure regardless of
// billing_status (used by the Billing Dashboard's OPD Procedures tab).
export async function getPendingProcedureBilling({ includeBilled = false } = {}) {
  const supabase = await createClient();
  let query = supabase
    .from('plan_procedures')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, salutation, last_name, uhid, mobile)))')
    .order('created_at', { ascending: true });
  if (!includeBilled) query = query.eq('billing_status', 'Pending');
  const { data, error } = await query;

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

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED OPD PROCEDURES" WIDGET ──
// Same pattern as getInvestigationOrdersForBilling -- matches each
// plan_procedures row against the OPD Procedure department of the
// service catalog by name.
export async function getProceduresForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: orders, error } = await supabase
    .from('plan_procedures')
    .select('id, name, eye, notes, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: catalog } = await supabase.from('master_services').select('*').eq('dept', 'OPD Procedure').eq('status', 'Active');

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

// ── Surgery Billing panel (New Invoice) -- Surgery/Eye/Doctor fields
// shown alongside the Package selection, whether prefilled from an
// existing surgical_case (automatic route) or filled in by hand
// (manual route). ──
export async function getSurgeryBillingOptions() {
  const supabase = await createClient();
  const [{ data: surgeries }, { data: doctors }] = await Promise.all([
    supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name'),
    supabase.from('profiles').select('id, full_name').eq('designation', 'Doctor').eq('status', 'Active').order('full_name'),
  ]);
  return { surgeries: surgeries || [], doctors: doctors || [] };
}

// Only used for a manually-entered Surgery bill (no linked
// surgical_case) -- renderInvoiceHtml falls back to these when it can't
// find a case for the invoice's visit.
export async function setManualSurgeryDetails(invoiceId, surgeryName, surgeryEye, surgeonId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('invoices')
    .update({ manual_surgery_name: surgeryName || null, manual_surgery_eye: surgeryEye || null, manual_surgeon_id: surgeonId || null })
    .eq('id', invoiceId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGERY BILLING widget (Billing Dashboard) -- patients who've been
// discharged but whose surgery package still hasn't been billed. This
// is now the actual moment the full surgery invoice gets generated --
// advance was already collected pre-op (OT Dashboard), so this is
// "settle the rest." ──
// Surgery Billing -- surfaces a surgery for billing the moment FULL
// PAYMENT has been received against every procedure's package
// (primary + additional, see surgical_case_procedures), instead of
// waiting for discharge. A surgery can get fully paid well before the
// operation (advance collected upfront) or right at discharge --
// either way, front desk should see it here as soon as the money is
// actually in, not have to wait on Recovery to record a discharge
// date. Net-amount and advance-balance calculation matches Surgical
// Journey's Payment step and Patient Check-In's advance-cleared gate
// (see surgical-journey/[id]/workspace.js and
// ot-intraop/actions.js's getOTCaseList) -- keep these in sync.
export async function getPendingPackageBilling() {
  const supabase = await createClient();
  const { data: cases, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_discount, patients:patient_id(first_name, salutation, last_name, uhid), master_packages:package_id(id, code, name, price)')
    .eq('package_locked', true)
    .eq('package_billed', false)
    .not('package_id', 'is', null);
  if (error) return [];
  const eligibleCases = (cases || []).filter((sc) => sc.master_packages);
  if (eligibleCases.length === 0) return [];

  // Every procedure in the surgery must ALSO have a locked, unbilled
  // package before the case is even a billing candidate -- matches how
  // billing actually happens (every procedure together, one invoice).
  const { data: procs } = await supabase
    .from('surgical_case_procedures')
    .select('surgical_case_id, procedure_name, eye, package_discount, package_locked, package_billed, package_id, master_packages:package_id(name, price)')
    .in('surgical_case_id', eligibleCases.map((c) => c.id));

  const procsByCase = {};
  (procs || []).forEach((p) => { (procsByCase[p.surgical_case_id] ||= []).push(p); });

  const readyCases = eligibleCases.filter((sc) => {
    const caseProcs = procsByCase[sc.id] || [];
    return caseProcs.every((p) => p.package_locked && !p.package_billed && p.package_id);
  });
  if (readyCases.length === 0) return [];

  const patientIds = [...new Set(readyCases.map((sc) => sc.patient_id).filter(Boolean))];
  const balanceByPatient = {};
  await Promise.all(patientIds.map(async (pid) => {
    const { data: bal } = await supabase.rpc('get_advance_balance', { p_patient_id: pid });
    balanceByPatient[pid] = Number(bal) || 0;
  }));

  return readyCases
    .map((sc) => {
      const caseProcs = procsByCase[sc.id] || [];
      const netTotal = Math.max(0, Number(sc.master_packages.price) - Number(sc.package_discount || 0))
        + caseProcs.reduce((sum, p) => sum + Math.max(0, Number(p.master_packages?.price || 0) - Number(p.package_discount || 0)), 0);
      return { ...sc, additionalProcedures: caseProcs, netTotal, advanceBalance: balanceByPatient[sc.patient_id] || 0 };
    })
    .filter((sc) => sc.advanceBalance >= sc.netTotal - 0.01); // fully paid, small epsilon for rounding
}
// Shapes one billable row (the primary case, or one of its additional
// procedures) into a billing line item.
function shapePackageBillingItem({ caseId, name, code, price, discount, surgeryName, surgeryEye, surgeonId, surgeonName, breakup, patient, visitId }) {
  return {
    caseId, name, matched: true,
    serviceCode: code, rate: price, gstPct: 0,
    breakup: breakup || [],
    surgeryName, surgeryEye, surgeonId, surgeonName,
    discount: Number(discount || 0),
    patient: patient || null,
    visitId: visitId || null,
  };
}

// A surgery can include more than one procedure (see
// surgical_case_procedures) -- each keeps its own package/price, all
// billed together on the ONE invoice for this case.
export async function getPackageForBilling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase
    .from('surgical_cases')
    .select('package_id, package_discount, visit_id, procedure_name, eye, surgeon_id, profiles:surgeon_id(full_name), master_packages:package_id(code, name, price), patients:patient_id(id, first_name, salutation, last_name, uhid, mobile)')
    .eq('id', caseId)
    .maybeSingle();
  if (!sc?.master_packages) return { items: [] };

  const { data: breakupItems } = await supabase
    .from('package_line_items')
    .select('description, amount')
    .eq('package_id', sc.package_id)
    .order('sort_order');

  const items = [shapePackageBillingItem({
    caseId, name: sc.master_packages.name, code: sc.master_packages.code, price: sc.master_packages.price,
    discount: sc.package_discount, surgeryName: sc.procedure_name, surgeryEye: sc.eye,
    surgeonId: sc.surgeon_id, surgeonName: sc.profiles?.full_name || null,
    breakup: breakupItems, patient: sc.patients, visitId: sc.visit_id,
  })];

  const { data: procedures } = await supabase
    .from('surgical_case_procedures')
    .select('id, procedure_name, eye, package_id, package_discount, master_packages:package_id(code, name, price)')
    .eq('surgical_case_id', caseId)
    .eq('package_billed', false)
    .not('package_id', 'is', null);

  for (const proc of procedures || []) {
    if (!proc.master_packages) continue;
    const { data: procBreakup } = await supabase
      .from('package_line_items')
      .select('description, amount')
      .eq('package_id', proc.package_id)
      .order('sort_order');
    items.push(shapePackageBillingItem({
      caseId: `proc:${proc.id}`, name: proc.master_packages.name, code: proc.master_packages.code, price: proc.master_packages.price,
      discount: proc.package_discount, surgeryName: proc.procedure_name, surgeryEye: proc.eye,
      surgeonId: sc.surgeon_id, surgeonName: sc.profiles?.full_name || null,
      breakup: procBreakup, patient: sc.patients, visitId: sc.visit_id,
    }));
  }

  return { items };
}

// Called once the invoice carrying this package is actually saved --
// flips it out of the Front Office queue. caseId can be either a plain
// surgical_cases id (primary procedure) or "proc:<id>" (an additional
// procedure in surgical_case_procedures) -- see getPackageForBilling.
export async function markPackageBilled(caseId, invoiceId) {
  const supabase = await createClient();
  if (!caseId) return { success: true };
  if (typeof caseId === 'string' && caseId.startsWith('proc:')) {
    const procedureId = caseId.slice('proc:'.length);
    const { error } = await supabase.from('surgical_case_procedures').update({ package_billed: true, billed_invoice_id: invoiceId || null }).eq('id', procedureId);
    if (error) return { error: error.message };
    return { success: true };
  }
  const { error } = await supabase.from('surgical_cases').update({ package_billed: true, billed_invoice_id: invoiceId || null }).eq('id', caseId);
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
  const { data: invoice, error } = await supabase.from('invoices').select('*, patients(id, first_name, salutation, last_name, uhid, mobile), visits(id, visit_number, visit_type, created_at)').eq('id', invoiceId).single();
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
    .select('*, patients(id, first_name, salutation, last_name, uhid), master_packages(id, name, price)')
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
    .select('id, uhid, first_name, salutation, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function generatePackageInvoice(patientId, packageId, paymentMode, advanceAmount, surgicalCaseId) {
  const supabase = await createClient();

  // Surgery bill can only be generated once the patient has actually
  // been discharged (hospital policy). This blocks the invoice itself,
  // not advance collection -- a pre-op advance still goes through the
  // separate Advance tab in Payments (collectAdvance), unaffected here.
  if (surgicalCaseId) {
    const { data: episode } = await supabase
      .from('recovery_episodes')
      .select('discharge_date')
      .eq('surgical_case_id', surgicalCaseId)
      .maybeSingle();
    if (!episode || !episode.discharge_date) {
      return { error: 'The surgery bill can only be generated after the patient has been discharged. To collect a pre-op advance instead, use the Advance tab in Payments.' };
    }
  }

  if (advanceAmount && Number(advanceAmount) > 0) {
    const blocked = await requireDayOpen();
    if (blocked) return blocked;
  }

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
    .select('*, patients(first_name, salutation, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function searchInvoices(query, deptFilter, dateFrom, dateTo) {
  const supabase = await createClient();

  let q = supabase
    .from('invoices')
    .select('*, patients(first_name, salutation, last_name, uhid), visits(visit_number)')
    .order('created_at', { ascending: false });

  // Without a date range, this is a "browse recent activity" view and
  // stays capped at 50 so it loads fast -- older invoices are still
  // there, just need a date range (or a patient search, which isn't
  // capped) to reach them. This was the actual bug: invoices before
  // ~24 Aug had silently scrolled off this cap with no way back in.
  if (dateFrom) q = q.gte('created_at', `${dateFrom}T00:00:00`);
  if (dateTo) q = q.lte('created_at', `${dateTo}T23:59:59`);
  if (!dateFrom && !dateTo && !query) q = q.limit(50);
  else q = q.limit(1000);

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



