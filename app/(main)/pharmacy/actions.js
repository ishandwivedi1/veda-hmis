'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

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


