'use server';

import { createClient } from '@/lib/supabase-server';

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

  return [...(services || []), ...drugsAsServices].sort((a, b) => a.name.localeCompare(b.name));
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

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}


