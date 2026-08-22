'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';
import { plainFrequency } from '@/lib/prescriptionFormatting';
import { computeDispenseQty } from '@/lib/pharmacyQuantity';

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
    supabase.from('master_drugs').select('*, master_drug_types(id, name, is_countable)').eq('status', 'Active').order('generic'),
  ]);

  // Suggest the closest catalog match per prescription so the
  // pharmacist isn't hunting through the whole drug list for every
  // line -- same ilike logic the auto-bill RPC already uses, just
  // surfaced here before billing instead of silently applied after.
  function matchCatalog(drugName) {
    return (drugCatalog || []).find(
      (d) => drugName?.toLowerCase().includes(d.generic?.toLowerCase()) ||
             (d.brand && drugName?.toLowerCase().includes(d.brand.toLowerCase()))
    );
  }

  // A tapering schedule is N rows in `prescriptions` (one per step) so
  // it prints and edits cleanly, but Pharmacy shouldn't turn that into
  // N separate purchases/dispenses -- the patient needs one bottle of
  // eye drops, or one computed total of tablets, not four. Group rows
  // sharing a taper_group_id into a single pharmacy line, and compute
  // a suggested quantity from the whole schedule (see
  // lib/pharmacyQuantity.js). Only groups still fully Pending are
  // merged this way -- a group with mixed billing/dispensing status
  // (only possible from before this grouping existed) is left as
  // individual rows exactly as it always was, rather than guessing how
  // to reconcile already-processed history.
  const byTaperGroup = {};
  const standaloneRows = [];
  (prescriptions || []).forEach((rx) => {
    if (rx.taper_group_id) {
      (byTaperGroup[rx.taper_group_id] ||= []).push(rx);
    } else {
      standaloneRows.push(rx);
    }
  });

  function buildStandaloneItem(rx) {
    const match = matchCatalog(rx.drug_name);
    const isCountable = !!match?.master_drug_types?.is_countable;
    const suggestion = rx.billing_status === 'Pending'
      ? computeDispenseQty([{ dosage: rx.dosage, frequency: rx.frequency, duration: rx.duration }], isCountable)
      : null;
    return {
      ...rx,
      isTaper: false,
      stepIds: [rx.id],
      suggestedDrugId: match?.id || null,
      plainFrequency: plainFrequency(rx.frequency),
      suggestedQty: suggestion?.qty ?? null,
      qtyComputed: suggestion?.computed ?? false,
      needsManualQty: suggestion?.needsManualEntry ?? false,
      taperNote: suggestion?.reason || null,
    };
  }

  const items = standaloneRows.map(buildStandaloneItem);

  Object.values(byTaperGroup).forEach((steps) => {
    const sorted = [...steps].sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
    const consistentStatus = sorted.every((s) => s.billing_status === sorted[0].billing_status && s.status === sorted[0].status);
    if (!consistentStatus) {
      sorted.forEach((rx) => items.push(buildStandaloneItem(rx)));
      return;
    }
    const first = sorted[0];
    const match = matchCatalog(first.drug_name);
    const isCountable = !!match?.master_drug_types?.is_countable;
    const suggestion = first.billing_status === 'Pending' ? computeDispenseQty(sorted, isCountable) : null;
    items.push({
      id: first.taper_group_id,
      taper_group_id: first.taper_group_id,
      isTaper: true,
      stepIds: sorted.map((s) => s.id),
      drug_name: first.drug_name,
      eye: first.eye,
      dosage: [...new Set(sorted.map((s) => s.dosage))].join(' -> '),
      duration: null,
      plainFrequency: sorted.map((s) => `${plainFrequency(s.frequency)} x${s.duration}`).join(' -> ') + ', then stop',
      billing_status: first.billing_status,
      status: first.status,
      qty: first.qty,
      invoice_line_items: first.invoice_line_items,
      created_at: first.created_at,
      suggestedDrugId: match?.id || null,
      suggestedQty: suggestion?.qty ?? null,
      qtyComputed: suggestion?.computed ?? false,
      needsManualQty: suggestion?.needsManualEntry ?? false,
      taperNote: suggestion?.reason || null,
    });
  });

  items.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));

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
    // main Billing screen. Fixed-Rs discount is capped at the line's
    // gross so it can never make a line negative.
    let disc = 0;
    if (item.discType === 'pct') disc = Math.round((gross * Math.min(100, Math.max(0, item.discValue || 0)) / 100) * 100) / 100;
    else if (item.discType === 'fixed') disc = Math.min(Math.max(0, item.discValue || 0), gross);
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

    // A tapering schedule bills as ONE line item covering every step --
    // every underlying prescriptions row (one per step) is updated to
    // point at that same line item and quantity, not just the first.
    // Non-taper items just have a single id here.
    const ids = item.prescriptionIds && item.prescriptionIds.length > 0 ? item.prescriptionIds : [item.prescriptionId];
    const { error: updError } = await supabase
      .from('prescriptions')
      .update({
        billing_status: 'Billed',
        qty: item.qty,
        invoice_id: invoice.id,
        invoice_line_item_id: line.id,
        billing_updated_at: new Date().toISOString(),
      })
      .in('id', ids);
    if (updError) return { error: updError.message };
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

// Accepts either a single prescription id or an array -- a tapering
// schedule's Decline/Defer/Undo acts on every step together, since the
// Pharmacy Workspace's "id" for a taper group is its taper_group_id,
// not a row in `prescriptions`.
async function setPrescriptionBillingStatus(idOrIds, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const ids = Array.isArray(idOrIds) ? idOrIds : [idOrIds];
  const { error } = await supabase
    .from('prescriptions')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markPrescriptionDenied(idOrIds, note) {
  return setPrescriptionBillingStatus(idOrIds, 'Denied', note);
}

export async function markPrescriptionDeferred(idOrIds, note) {
  return setPrescriptionBillingStatus(idOrIds, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetPrescriptionBilling(idOrIds) {
  return setPrescriptionBillingStatus(idOrIds, 'Pending', null);
}


