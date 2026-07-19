'use server';

import { createClient } from '@/lib/supabase-server';

const MEAS_FIELDS = ['axl', 'k1', 'k2', 'acd', 'lt', 'wtw'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE: real queue_entries with status = 'Awaiting Biometry' (set by
// Consultation's "Send for Biometry"), matched against any existing
// biometry_records for that visit so a patient shows the right stage
// even after a record's been started but not yet approved. ──
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: entries, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .eq('status', 'Awaiting Biometry')
    .order('issued_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 } };

  const visitIds = (entries || []).map((e) => e.visits?.id).filter(Boolean);

  let recordsByVisit = {};
  if (visitIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('*')
      .in('visit_id', visitIds)
      .in('status', ['Awaiting Biometry', 'Measured', 'Calculated']);
    (records || []).forEach((r) => { recordsByVisit[r.visit_id] = r; });
  }

  const rows = (entries || []).map((e) => {
    const record = recordsByVisit[e.visits?.id];
    return {
      queueEntryId: e.id,
      visitId: e.visits?.id,
      encounterId: null,
      doctorId: e.visits?.doctor_id,
      patient: e.visits?.patients,
      recordId: record?.id || null,
      status: record?.status || 'Awaiting Biometry',
      procedureName: record?.procedure_name || null,
      surgicalEye: record?.surgical_eye || null,
    };
  });

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: approvedToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Approved')
    .gte('approved_at', todayStart.toISOString());

  const stats = {
    awaiting: rows.filter((r) => r.status === 'Awaiting Biometry').length,
    measured: rows.filter((r) => r.status === 'Measured').length,
    calculated: rows.filter((r) => r.status === 'Calculated').length,
    approvedToday: (approvedToday || []).length,
  };

  return { rows, stats };
}

// Finds an in-flight record for this visit, or creates a fresh one --
// same lazy-create pattern as the encounter/optometry assessment.
export async function getOrCreateBiometryRecord(visitId, encounterId) {
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .maybeSingle();

  if (existing) return { id: existing.id };

  const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  let surgeonName = '--';
  if (data.surgeon_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.surgeon_id).maybeSingle();
    surgeonName = doc?.full_name || '--';
  }

  return { record: data, surgeonName };
}

// Sets/updates the procedure + surgical eye for this record -- captured
// here rather than assumed from elsewhere, since Biometry may be the
// first place this gets confirmed with the technician.
export async function setBiometrySurgicalDetails(id, procedureName, surgicalEye) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ procedure_name: procedureName, surgical_eye: surgicalEye, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// BR-BIO-002: only verified measurements may be used for calculation.
// AUTO-BIO-001: verification is what triggers calculation eligibility --
// there's no separate persisted "Measured" state in practice, mirroring
// the source workflow (jumps straight to Calculated).
export async function verifyBiometryMeasurements(id, measurements, surgicalEye, device, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!surgicalEye) return { error: 'Set the surgical eye before verifying.' };

  const eyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  if (!eyeKey) return { error: 'Surgical eye must be RE or LE to verify (OU not supported for a single IOL calculation).' };

  const eyeData = measurements[eyeKey] || {};
  const missing = REQUIRED_FIELDS.filter((f) => !eyeData[f] || !String(eyeData[f]).trim());
  if (missing.length > 0) {
    return { error: `Mandatory fields for the surgical eye (AXL, K1, K2, ACD) must be completed before verification. Missing: ${missing.join(', ').toUpperCase()}.` };
  }

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Calculated',
      measurements,
      verify_device: device,
      verify_remarks: remarks,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}
