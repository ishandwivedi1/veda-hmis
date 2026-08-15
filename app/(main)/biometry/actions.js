'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const MEAS_FIELDS = ['axl', 'k1', 'k2', 'acd', 'lt', 'wtw'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──
// Reads biometry_records directly (not queue_entries.status), same
// architecture as the Investigation Queue. This is deliberate: if it
// depended on queue_entries.status, sending a patient for both an
// investigation and Biometry in the same consultation would risk one
// overwriting the other and the patient silently vanishing from this
// screen. Reading the record itself means it always shows up here
// regardless of whatever else the patient's front-desk status says.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.visits)
    .map((r) => ({
      recordId: r.id,
      visitId: r.visit_id,
      encounterId: r.encounter_id,
      doctorId: r.visits?.doctor_id,
      patient: r.visits?.patients,
      status: r.status,
      procedureName: r.procedure_name,
      surgicalEye: r.surgical_eye,
    }));

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

// ── COMPLETED TODAY -- Approved records from today, so a biometry
// doesn't just disappear from the Queue the instant it's approved.
// Moves to History (getBiometryHistory) once the day rolls over --
// mirrors the same Dashboard/History split used in OT Intraop, OT
// Recovery, and the Investigation Queue. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .eq('status', 'Approved')
    .gte('approved_at', startUTC)
    .lte('approved_at', endUTC)
    .order('approved_at', { ascending: false });
  if (error) return [];

  return (data || [])
    .filter((r) => r.visits)
    .map((r) => ({
      recordId: r.id,
      visitId: r.visit_id,
      encounterId: r.encounter_id,
      doctorId: r.visits?.doctor_id,
      patient: r.visits?.patients,
      status: r.status,
      procedureName: r.procedure_name,
      surgicalEye: r.surgical_eye,
      approvedAt: r.approved_at,
    }));
}

// Finds an in-flight record for this visit, or creates a fresh one --
// same lazy-create pattern as the encounter/optometry assessment.
export async function getOrCreateBiometryRecord(visitId, encounterId) {
  const supabase = await createClient();

  // Reuse ANY existing non-cancelled record for this visit -- including
  // Approved ones. Previously this only matched in-flight statuses, so
  // reopening an already-approved patient (e.g. from the Queue, since
  // queue_entries.status doesn't change on approval) silently created a
  // second, blank record for the same visit.
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();

  // Procedure + eye come from the surgical case (set when the doctor
  // marked the patient for surgery) rather than being re-typed by hand
  // in Biometry -- one source of truth, no risk of the two drifting
  // apart. Falls back to blank only if biometry is genuinely being done
  // before any surgical case exists yet for this visit.
  const { data: surgicalCase } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  // OU (bilateral) can't be represented on a single record --
  // verifyBiometryMeasurements only supports one eye per record. This
  // fallback path only ever creates ONE record (unlike Counselling's
  // sendForBiometry, which fans an OU case out into two), so for OU we
  // deliberately leave surgical_eye blank here rather than writing an
  // unsupported value -- the technician sets it explicitly instead.
  const surgicalEye = surgicalCase?.eye === 'OD' ? 'RE' : surgicalCase?.eye === 'OS' ? 'LE' : null;

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({
      visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null,
      surgical_case_id: surgicalCase?.id || null,
      procedure_name: surgicalCase?.procedure_name || null,
      surgical_eye: surgicalEye,
    })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)), master_iol_catalog(brand, model, manufacturer)')
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
export async function verifyBiometryMeasurements(id, measurements, surgicalEye, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!surgicalEye) return { error: 'Set the surgical eye before verifying.' };

  const eyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  if (!eyeKey) return { error: 'Surgical eye must be RE or LE to verify (OU not supported for a single IOL calculation).' };

  // Each eye can now hold multiple tagged readings (e.g. Manual A-Scan
  // AND an optical biometer, when both were used) -- verification just
  // needs at least ONE complete reading for the surgical eye, not every
  // reading filled in.
  const eyeSets = Array.isArray(measurements[eyeKey]) ? measurements[eyeKey] : [];
  const completeSet = eyeSets.find((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim()));
  if (!completeSet) {
    return { error: `At least one complete reading (AXL, K1, K2, ACD) is required for the surgical eye (${surgicalEye}) before verification.` };
  }

  // Summarize which device(s) actually produced complete readings for
  // the surgical eye, for a readable record -- e.g. "Manual A-Scan,
  // ZEISS IOLMaster 700" if both were used.
  const devicesUsed = [...new Set(
    eyeSets.filter((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim())).map((set) => set.device)
  )];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Calculated',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, data?.visit_id, 'biometry_completed');
  return { success: true };
}

// ── IOL CALCULATION ──
// Formula results are NOT computed by this system -- real IOL power
// formulas (Barrett Universal II, SRK/T, Haigis, etc.) are complex and
// in some cases proprietary. These numbers come from the biometry
// device's own built-in formula software (the same printout captured
// in Device Reports); staff transcribes each formula's result here so
// the surgeon has a structured side-by-side comparison to choose from.
export async function saveFormulaResults(id, targetRefraction, formulaResults, selectedFormula) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      target_refraction: targetRefraction,
      formula_results: formulaResults,
      selected_formula: selectedFormula,
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGEON APPROVAL ──
// BR-BIO-003: only surgeon sign-off finalizes a plan (soft UX check
// only -- see note in the Approval tab; not DB-enforced by role).
// BR-BIO-005: approval supersedes but never deletes a prior version --
// every approve call adds a new biometry_iol_versions row and marks
// any previous Approved version for this record as Superseded.
// ── Used by the Doctor Dashboard's Biometry Approvals widget --
// records ready for surgeon sign-off, mapped to today's visits only. ──
export async function getBiometryApprovalsToday() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from('biometry_records')
    .select('id, surgical_eye, status, visits(id, visit_type, created_at, patients(first_name, last_name, uhid))')
    .eq('status', 'Calculated')
    .gte('visits.created_at', today);
  if (error) return [];
  // The visits filter above can't be applied as a proper join filter via
  // PostgREST here, so double-check in JS that the visit really is today's.
  return (data || []).filter((r) => r.visits && r.visits.created_at?.slice(0, 10) === today);
}

export async function approveIolPlan(id, plan) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  const isDoctor = approverProfile?.designation === 'Doctor';
  if (!isDoctor) return { error: 'Only a doctor can approve a biometry / IOL plan.' };

  if (!plan.finalPower || !plan.finalCategory) return { error: 'Final IOL power and category are required.' };

  const { data: priorVersions } = await supabase
    .from('biometry_iol_versions')
    .select('id, version_no')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });

  const nextVersionNo = (priorVersions?.[0]?.version_no || 0) + 1;

  if (priorVersions && priorVersions.length > 0) {
    await supabase.from('biometry_iol_versions').update({ status: 'Superseded' }).eq('biometry_record_id', id).eq('status', 'Approved');
  }

  const { error: versionError } = await supabase.from('biometry_iol_versions').insert({
    biometry_record_id: id,
    version_no: nextVersionNo,
    power: plan.finalPower,
    formula: plan.finalFormula,
    status: 'Approved',
    created_by: userData?.user?.id || null,
  });
  if (versionError) return { error: versionError.message };

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Approved',
      final_iol_power: plan.finalPower,
      final_iol_category: plan.finalCategory,
      final_iol_catalog_id: plan.iolCatalogId || null,
      target_refraction: plan.finalTarget,
      surgeon_notes: plan.surgeonNotes,
      approved_by: userData?.user?.id || null,
      approved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true, versionNo: nextVersionNo };
}

export async function getIolVersionHistory(id) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_iol_versions')
    .select('*, profiles(full_name)')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });
  if (error) return [];
  return data || [];
}

// ── HISTORY (Section 17.15) -- cross-patient, all statuses past
// Awaiting Biometry. BR-BIO-005: nothing here is ever overwritten;
// re-approvals just add rows to biometry_iol_versions. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, visits(visit_number, patients(id, first_name, last_name, uhid))')
    .in('status', ['Calculated', 'Approved'])
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.visits?.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.visits?.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every biometry lands here the moment Counselling sends the patient
// for it (the stub row is created right then), regardless of how far
// the actual measurement/calculation/approval workflow has gotten --
// same "bill upfront, don't wait for completion" principle used for
// investigations and prescriptions.
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(id, first_name, last_name, uhid))')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.visit_id && r.visits)
    .map((r) => ({ visitId: r.visit_id, visitNumber: r.visits.visit_number, patient: r.visits.patients, items: [r] }));
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

