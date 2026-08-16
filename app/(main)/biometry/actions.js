'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──────────────────────────────────────────────────────────
// Biometry is patient-level now, not visit/case-level -- a session is
// reused across every future surgical case for that patient. The queue
// just lists records not yet Measured, regardless of which visit
// originally ordered them.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measuredToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.patients)
    .map((r) => ({
      recordId: r.id,
      patientId: r.patient_id,
      patient: r.patients,
      status: r.status,
      doctorInstructions: r.doctor_instructions,
    }));

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const { data: measuredToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC);

  const stats = {
    awaiting: rows.length,
    measuredToday: (measuredToday || []).length,
  };

  return { rows, stats };
}

// ── COMPLETED TODAY -- Measured records from today, so a session
// doesn't disappear from the Queue the instant it's done. Moves to
// History once the day rolls over -- same Dashboard/History split used
// elsewhere. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC)
    .lte('updated_at', endUTC)
    .order('updated_at', { ascending: false });
  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ recordId: r.id, patientId: r.patient_id, patient: r.patients, status: r.status }));
}

// Finds an existing biometry record for this PATIENT -- reused across
// every future surgical case (readings don't meaningfully change for
// years), so this is a lookup-or-create against patient_id, not
// visit_id like most other "ensure a record" functions in this app.
export async function getOrCreateBiometryRecord(patientId, visitId, encounterId) {
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid, age, gender)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  const { data: recommendations } = await supabase
    .from('biometry_iol_recommendations')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('biometry_record_id', id)
    .order('created_at', { ascending: true });

  return { record: data, recommendations: recommendations || [] };
}

// Persists measurement readings without changing status -- technician
// can leave and resume later.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

// Marks the session done -- requires at least one complete reading for
// EACH eye (biometry is always done for both eyes now) and at least
// one IOL recommendation row entered, plus the device report attached
// (checked by the caller via AttachmentUploader's own listing, not
// re-verified here -- consistent with how other modules treat
// attachments as informational rather than a hard DB gate).
export async function markBiometryMeasured(id, measurements, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const reHasComplete = (measurements.re || []).some(isComplete);
  const leHasComplete = (measurements.le || []).some(isComplete);
  if (!reHasComplete || !leHasComplete) {
    return { error: 'At least one complete reading (AXL, K1, K2, ACD) is required for BOTH eyes.' };
  }

  const { count } = await supabase
    .from('biometry_iol_recommendations')
    .select('id', { count: 'exact', head: true })
    .eq('biometry_record_id', id);
  if (!count) return { error: 'Add at least one IOL recommendation from the device printout before marking as measured.' };

  const devicesUsed = [...new Set([...(measurements.re || []), ...(measurements.le || [])].map((s) => s.device).filter(Boolean))];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Measured',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks || null,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id, patient_id')
    .single();

  if (error) return { error: error.message };
  if (data?.visit_id) await logJourneyEvent(supabase, data.visit_id, 'biometry_completed');

  // Biometry is ordered through the regular OPD Investigations panel
  // now (selectable like any other investigation), which creates a
  // normal investigation_orders row alongside this specialized
  // fulfillment. Keep that row in sync so it doesn't sit showing
  // "Ordered" forever in the doctor's list once the actual work is
  // done -- match across ALL of this patient's encounters, since
  // biometry is patient-level and the order could have come from any
  // visit.
  if (data?.patient_id) {
    const { data: visits } = await supabase.from('visits').select('id').eq('patient_id', data.patient_id);
    const visitIds = (visits || []).map((v) => v.id);
    if (visitIds.length > 0) {
      const { data: encounters } = await supabase.from('encounters').select('id').in('visit_id', visitIds);
      const encounterIds = (encounters || []).map((e) => e.id);
      if (encounterIds.length > 0) {
        await supabase
          .from('investigation_orders')
          .update({ status: 'Available', verified_at: new Date().toISOString() })
          .in('encounter_id', encounterIds)
          .ilike('name', 'biometry')
          .eq('status', 'Ordered');
      }
    }
  }

  return { success: true };
}

// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
// The device's own printed table -- for each brand/model it evaluated,
// what power it recommends per eye. This app records what the printout
// says; it does not calculate anything itself.
export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
  const supabase = await createClient();
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
  const { error } = await supabase.from('biometry_iol_recommendations').insert({
    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    re_power: rePower || null, le_power: lePower || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIolRecommendation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── HISTORY -- cross-patient, Measured or Cancelled. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ patientId: r.patient_id, patient: r.patients, items: [r] }));
}

async function setBiometryBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
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

export async function markBiometryDenied(id, note) {
  return setBiometryBillingStatus(id, 'Denied', note);
}

export async function markBiometryDeferred(id, note) {
  return setBiometryBillingStatus(id, 'Deferred', note);
}

export async function resetBiometryBilling(id) {
  return setBiometryBillingStatus(id, 'Pending', null);
}
