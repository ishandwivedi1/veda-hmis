#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
#
# Restricts Audit Logs to Administrators only, everywhere they appear:
#   - Doctor Consultation (Context Sidebar Audit Log card)
#   - Optometry workspace (Audit Log card)
#   - Optometry History (Audit Log card + assessment detail viewer)
#   - Financial Masters (Change History card)
#
# The REAL security boundary is at the database (RLS) -- this part was
# ALREADY applied directly to both your production (flzysyzhaecaqbmdcuao)
# and training (ffaddzpwnbizhvhujlse) Supabase projects. The 4 audit log
# tables (encounter_audit_log, optometry_audit_log, ot_schedule_audit_log,
# master_data_audit_log) now only allow SELECT to Administrators -- any
# staff role can still INSERT (writing an audit entry is a normal
# side-effect of routine actions). schema.sql was NOT updated with this
# policy change since it only tracks table/column structure, not RLS
# policies -- there is no SQL left for you to run manually.
#
# A narrow SECURITY DEFINER function (get_doctor_override_assessment_ids)
# was also added so Optometry History's "a doctor corrected this"
# indicator keeps working for non-admins without exposing the underlying
# log content.
#
# The code changes below are the second layer (UX -- hiding the cards
# for non-admins instead of showing an empty "No activity" box).
#
# NOT touched, on purpose:
#   - Payments > Adjustments's ledger history (getPatientLedgerAudit)
#     -- this is core financial/transaction data Finance staff need for
#     their job, not a system audit trail. Say the word if you want
#     that locked down too.
#   - Workflow Monitor's "transitions" count (encounter_audit_log-
#     derived) will now silently show 0 for non-admins as a side effect
#     of the RLS change, since that page is not reachable from the
#     sidebar nav and wasn't otherwise gated.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "lib"
cat > "lib/authz.js" << 'FILEEOF_lib_authz_js'
// Shared server-side authorization helpers -- 'use server' files import
// this directly (it is not itself a server action, just a plain async
// helper function).
//
// isCurrentUserAdmin() answers "is the signed-in staff member an
// Administrator?" for gating anything Administrator-only in the app
// layer (audit logs, etc). This is a UX/defense-in-depth check, not the
// real security boundary -- the actual boundary is enforced by Postgres
// RLS policies on the underlying tables (e.g. audit log tables only
// allow SELECT to Administrators). Even if this check were skipped or
// bypassed, a non-admin's query would still come back empty at the
// database level.

import { createClient } from '@/lib/supabase-server';

export async function isCurrentUserAdmin(existingClient) {
  const supabase = existingClient || await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return false;
  const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
  return me?.designation === 'Administrator';
}
FILEEOF_lib_authz_js

mkdir -p "app/(main)/consultation"
cat > "app/(main)/consultation/actions.js" << 'FILEEOF_consultation_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';
import { isCurrentUserAdmin } from '@/lib/authz';

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let encounter;
  if (entry.status === 'Done') {
    // Most recent encounter for this visit, any status -- not combining
    // .limit() with .maybeSingle() here, since that pairing isn't used
    // anywhere else in this codebase (getOrCreateBiometryRecord uses the
    // same array + length check instead for exactly this kind of lookup).
    const { data: encounters, error: encListError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .order('started_at', { ascending: false })
      .limit(1);
    if (encListError) return { error: encListError.message };
    encounter = encounters && encounters.length > 0 ? encounters[0] : null;
  } else {
    const { data: activeEncounter, error: encActiveError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .eq('status', 'In Consultation')
      .maybeSingle();
    if (encActiveError) return { error: encActiveError.message };
    encounter = activeEncounter;
  }

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    // For a completed (Done) queue entry there's nothing to auto-create --
    // if no encounter exists, the visit genuinely has no clinical record.
    // Auto-creating only makes sense for an active/new consultation.
    if (entry.status === 'Done') {
      return { error: 'No clinical record found for this completed visit.' };
    }
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await addAudit(supabase, encounter.id, 'Encounter started', userData?.user?.id);
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const patientId = entry.visits.patients.id;

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // encounter_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw }, { data: biometryRecords }, { data: surgicalCases },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('workflow_requests').select('*').eq('visit_id', visitId).order('requested_at', { ascending: false }),
    supabase.from('encounter_audit_log').select('*').eq('encounter_id', encounter.id).order('created_at', { ascending: false }),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounter.id).maybeSingle(),
    // Longitudinal (cross-visit) diagnosis history: every diagnosis this
    // patient has, across all their encounters, via visits -> encounters.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, status, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    // Biometry gets its own dedicated section in Diagnosis & Plan (not
    // folded into Investigations) -- same reasoning as its own
    // Financial Masters department: it's structurally its own thing.
    supabase.from('biometry_records').select('id, status, surgical_eye, doctor_instructions, billing_status').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
    // So "Mark for Surgery" can show what's already been marked instead
    // of silently reverting to a blank button after saving. Scoped by
    // visit_id (one visit, one surgical case), not just this encounter,
    // since a visit can span more than one encounter.
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  // Follow-up Template: same consultation engine, just extra context --
  // a patient is a "follow-up" the moment they have any prior encounter
  // at all, on a different visit, regardless of whether that encounter
  // was ever formally completed (an abandoned/in-progress note still
  // means this isn't their first time being seen).
  const priorEncounters = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorCompletedEncounters = priorEncounters.filter((e) => e.status === 'Completed');
  const isFollowUp = priorEncounters.length > 0;

  if (isFollowUp && encounter.encounter_type !== 'Follow-up') {
    await supabase.from('encounters').update({ encounter_type: 'Follow-up' }).eq('id', encounter.id);
    encounter.encounter_type = 'Follow-up';
  }

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: isAdmin ? (auditLog || []) : [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
    biometryRecords: biometryRecords || [],
    surgicalCases: surgicalCases || [],
    isLocked: encounter.status === 'Completed',
    isFollowUp, priorEncounterId: priorCompletedEncounters[0]?.id || null,
    isAdmin,
  };
}

// ── FOLLOW-UP TEMPLATE CONTEXT ──
// Everything the Follow-up template needs beyond what getConsultationData
// already returns: the visit timeline, patient snapshot, and a summary
// of the immediately preceding visit. Only called when isFollowUp is true.
export async function getFollowUpContext(patientId, currentVisitId, currentEncounterId) {
  const supabase = await createClient();

  const { data: visitsRaw } = await supabase
    .from('visits')
    .select('id, visit_number, encounters(id, started_at, completed_at, chief_complaint, status)')
    .eq('patient_id', patientId);

  const allPriorEncounters = (visitsRaw || [])
    .flatMap((v) => (v.encounters || []).map((e) => ({ ...e, visitId: v.id, visitNumber: v.visit_number })))
    .filter((e) => e.id !== currentEncounterId)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorEncounters = allPriorEncounters.filter((e) => e.status === 'Completed');

  // Map each prior visit back to its Doctor queue entry, so the
  // timeline can open it read-only -- same lookup pattern Patient
  // Timeline already uses.
  const priorVisitIds = [...new Set(allPriorEncounters.map((e) => e.visitId))];
  let queueEntryByVisit = {};
  if (priorVisitIds.length > 0) {
    const { data: entries } = await supabase.from('queue_entries').select('id, visit_id').in('visit_id', priorVisitIds).eq('department', 'Doctor');
    (entries || []).forEach((e) => { queueEntryByVisit[e.visit_id] = e.id; });
  }

  // Timeline shows every prior visit, including ones that were never
  // finalized -- still useful context, just labeled as such.
  const timeline = allPriorEncounters.slice(0, 15).map((e) => ({
    encounterId: e.id, date: e.started_at, chiefComplaint: e.chief_complaint,
    status: e.status, queueEntryId: queueEntryByVisit[e.visitId] || null,
  }));

  const lastEncounter = priorEncounters[0] || null;
  let snapshot = {
    lastVisitDate: lastEncounter?.started_at || null,
    currentDiagnoses: [], currentMedications: [], allergy: null,
    lastVision: null, lastIop: null, surgicalStatus: null,
    previousVisitSummary: null,
    noCompletedPriorVisit: !lastEncounter,
  };
  let newInvestigations = [];

  if (lastEncounter) {
    // Investigations ordered (anywhere -- Counselling, a walk-in
    // Investigation visit, etc.) since the last consultation, with
    // results ready -- these are easy to miss since they don't
    // necessarily belong to *this* encounter's own Investigations list.
    const allEncounterIds = (visitsRaw || []).flatMap((v) => (v.encounters || []).map((e) => e.id));
    if (allEncounterIds.length > 0) {
      const { data: recentInv } = await supabase
        .from('investigation_orders')
        .select('*')
        .in('encounter_id', allEncounterIds)
        .neq('encounter_id', currentEncounterId)
        .eq('status', 'Available')
        .gt('created_at', lastEncounter.started_at)
        .order('created_at', { ascending: false });
      newInvestigations = recentInv || [];
    }
    const [{ data: fullEncounter }, { data: diagnoses }, { data: medications }, { data: assessment }, { data: advice }, { data: fu }] = await Promise.all([
      supabase.from('encounters').select('hx_drug_allergy').eq('id', lastEncounter.id).maybeSingle(),
      supabase.from('diagnoses').select('*').eq('encounter_id', lastEncounter.id).eq('status', 'Active').order('created_at'),
      supabase.from('prescriptions').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('optometry_assessments').select('*').eq('visit_id', lastEncounter.visitId).eq('status', 'Completed').maybeSingle(),
      supabase.from('plan_optical_advice').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('plan_followups').select('*').eq('encounter_id', lastEncounter.id).maybeSingle(),
    ]);

    let lastIop = null;
    if (assessment) {
      const { data: iopReadings } = await supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: false }).limit(1);
      lastIop = iopReadings?.[0] || null;
    }

    const { data: recentSurgicalCase } = await supabase
      .from('surgical_cases').select('procedure_name, eye, status')
      .eq('patient_id', patientId).neq('status', 'Cancelled')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();

    snapshot = {
      lastVisitDate: lastEncounter.started_at,
      currentDiagnoses: diagnoses || [],
      currentMedications: medications || [],
      allergy: fullEncounter?.hx_drug_allergy || null,
      lastVision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
      lastIop,
      surgicalStatus: recentSurgicalCase || null,
      previousVisitSummary: {
        date: lastEncounter.started_at,
        diagnoses: diagnoses || [],
        medications: medications || [],
        advice: advice || [],
        followupPlan: fu || null,
        vision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
        iop: lastIop,
      },
    };
  }

  return { timeline, snapshot, newInvestigations };
}

// ── VISIT OUTCOME ──
export async function saveVisitOutcome(encounterId, outcome) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ visit_outcome: outcome }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CARRY FORWARD a prior diagnosis into the current encounter ──
export async function carryForwardDiagnosis(encounterId, diagnosis) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId, name: diagnosis.name, category: diagnosis.category, eye: diagnosis.eye, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}
export async function saveExamination(examinationId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Examination saved', userData?.user?.id);
  return { success: true };
}

// ── STRUCTURED HISTORY (Section 11.9) ──
// Batched save, same pattern as Examination -- not per-keystroke.
export async function saveHistory(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({
      chief_complaint: fields.chiefComplaint,
      chief_complaint_chips: fields.chiefComplaintChips,
      hx_duration: fields.hxDuration,
      hx_laterality: fields.hxLaterality,
      hx_hopi: fields.hxHopi,
      ocular_history: fields.ocularHistory,
      medical_history: fields.medicalHistory,
      family_history: fields.familyHistory,
      drug_history: fields.drugHistory,
      allergy: fields.allergy,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DOCTOR EDITS OPTOMETRY FINDINGS DIRECTLY (in-place override) ──
// The doctor edits the optometrist's own assessment record. Every
// changed field is written to that assessment's audit log (the same
// log the optometrist sees in Optometry History) as a before/after
// entry, so the optometrist can see exactly what was changed and by
// whom -- without a separate shadow record.
const OPTOM_FIELD_LABELS = {
  va_scale: 'VA Scale',
  re_dist_unaided: 'RE Dist Unaided', re_dist_glasses: 'RE Dist Glasses', re_dist_ph: 'RE Dist Pinhole', re_near_unaided: 'RE Near Unaided',
  le_dist_unaided: 'LE Dist Unaided', le_dist_glasses: 'LE Dist Glasses', le_dist_ph: 'LE Dist Pinhole', le_near_unaided: 'LE Near Unaided',
  ref_pd: 'PD', ref_vd: 'VD',
  ref_obj_re_sph: 'RE Obj Sph', ref_obj_re_cyl: 'RE Obj Cyl', ref_obj_re_axis: 'RE Obj Axis',
  ref_obj_le_sph: 'LE Obj Sph', ref_obj_le_cyl: 'LE Obj Cyl', ref_obj_le_axis: 'LE Obj Axis',
  ref_subj_re_sph: 'RE Subj Sph', ref_subj_re_cyl: 'RE Subj Cyl', ref_subj_re_axis: 'RE Subj Axis',
  ref_subj_le_sph: 'LE Subj Sph', ref_subj_le_cyl: 'LE Subj Cyl', ref_subj_le_axis: 'LE Subj Axis',
  ref_final_re_sph: 'RE Final Sph', ref_final_re_cyl: 'RE Final Cyl', ref_final_re_axis: 'RE Final Axis', ref_final_re_add: 'RE Final Add',
  ref_final_le_sph: 'LE Final Sph', ref_final_le_cyl: 'LE Final Cyl', ref_final_le_axis: 'LE Final Axis', ref_final_le_add: 'LE Final Add',
  iop_method: 'IOP Method', iop_time: 'IOP Time',
  add_k1: 'Keratometry K1', add_k2: 'Keratometry K2', add_axial_length: 'Axial Length', add_pachymetry: 'Pachymetry',
  add_white_to_white: 'White-to-White', add_schirmer: 'Schirmer', add_color_vision: 'Color Vision',
  add_ocular_motility: 'Ocular Motility', add_syringing: 'Syringing',
  observation_chips: 'Observation Tags', observations_text: 'Observations',
};

export async function updateOptometryFindings(assessmentId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: current, error: fetchError } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('id', assessmentId)
    .single();
  if (fetchError) return { error: fetchError.message };

  const changes = [];
  const updatePayload = {};
  Object.keys(OPTOM_FIELD_LABELS).forEach((key) => {
    if (fields[key] === undefined) return;
    const oldVal = current[key];
    const newVal = fields[key];
    const oldStr = Array.isArray(oldVal) ? oldVal.join(', ') : (oldVal ?? '');
    const newStr = Array.isArray(newVal) ? newVal.join(', ') : (newVal ?? '');
    if (oldStr === newStr) return;
    updatePayload[key] = newVal;
    changes.push({ label: OPTOM_FIELD_LABELS[key], oldStr: oldStr || '--', newStr: newStr || '--' });
  });

  if (changes.length === 0) return { success: true, changedCount: 0 };

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...updatePayload, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  for (const c of changes) {
    await supabase.from('optometry_audit_log').insert({
      assessment_id: assessmentId,
      message: `Doctor override -- ${c.label}: "${c.oldStr}" -> "${c.newStr}"`,
      created_by: doctorId,
    });
  }

  if (encounterId) {
    await addAudit(supabase, encounterId, `Optometry findings overridden -- ${changes.length} field(s) changed`, doctorId);
  }

  return { success: true, changedCount: changes.length };
}

// Lets the doctor start an optometry assessment directly when the
// patient never went through Optometry -- same table, just created and
// initially owned from the consultation side instead of the queue.
export async function createOptometryAssessmentForVisit(visitId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .insert({ visit_id: visitId, recorded_by: doctorId, completed_by: doctorId, status: 'Completed', completed_at: new Date().toISOString() })
    .select()
    .single();
  if (error) return { error: error.message };

  await supabase.from('optometry_audit_log').insert({ assessment_id: assessment.id, message: 'Assessment started by Doctor -- no prior Optometry visit', created_by: doctorId });
  if (encounterId) await addAudit(supabase, encounterId, 'Optometry assessment created directly by doctor', doctorId);

  return { assessment };
}


// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye}, ${values.category})`, userData?.user?.id);
  return { success: true };
}

export async function removeDiagnosis(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Diagnosis removed', userData?.user?.id);
  return { success: true };
}

export async function updateDiagnosisNotes(id, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').update({ notes: notes?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Prescription added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

// Tapering schedule -- same drug and dosage-per-administration across
// steps (that's how tapering actually works clinically: the amount per
// dose stays the same, e.g. 1 drop, only the frequency reduces over
// time), each step a separate row sharing one taper_group_id so they
// render and print as a single continuous instruction, not N unrelated
// prescriptions.
export async function addTaperedPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: s.frequency,
    duration: s.duration,
    eye: values.eye,
    taper_group_id: taperGroupId,
    taper_step: i + 1,
  }));

  const { error } = await supabase.from('prescriptions').insert(rows);
  if (error) return { error: error.message };
  const summary = steps.map((s) => `${s.frequency} x${s.duration}`).join(' -> ');
  await addAudit(supabase, encounterId, `Tapering schedule added: ${values.drugName} (${values.eye}) -- ${summary}`, userData?.user?.id);
  return { success: true };
}

export async function removeTaperGroup(taperGroupId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: rows } = await supabase.from('prescriptions').select('drug_name, eye').eq('taper_group_id', taperGroupId).limit(1);
  const { error } = await supabase.from('prescriptions').delete().eq('taper_group_id', taperGroupId);
  if (error) return { error: error.message };
  if (rows?.[0]) await addAudit(supabase, encounterId, `Tapering schedule removed: ${rows[0].drug_name} (${rows[0].eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePrescription(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Prescription removed', userData?.user?.id);
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Investigation ordered: ${values.name} (${values.eye}, ${values.priority})`, userData?.user?.id);
  return { success: true };
}

export async function removeInvestigation(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Investigation removed', userData?.user?.id);
  return { success: true };
}

// ── WORKFLOW REQUESTS (Biometry / Medical Fitness / Counselling) ──
// Independent, non-exclusive toggles -- a visit can have more than one
// open at a time, unlike Dilation/Investigation which move the queue
// entry itself. Toggling an already-open request cancels it.
export async function toggleWorkflowRequest(visitId, encounterId, kind) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: existing } = await supabase
    .from('workflow_requests')
    .select('*')
    .eq('visit_id', visitId)
    .eq('kind', kind)
    .eq('status', 'Requested')
    .maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('workflow_requests')
      .update({ status: 'Cancelled', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
      .eq('id', existing.id);
    if (error) return { error: error.message };
    await addAudit(supabase, encounterId, `Workflow request cancelled: ${kind}`, userData?.user?.id);
    return { success: true, active: false };
  }

  const { error } = await supabase.from('workflow_requests').insert({
    visit_id: visitId, encounter_id: encounterId, kind, requested_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Workflow requested: ${kind}`, userData?.user?.id);
  return { success: true, active: true };
}

// Mark a workflow request (Biometry/Fitness/Counselling) as done --
// used by whichever staff member actually completes it (e.g. the
// counsellor marking a Counselling request resolved).
export async function completeWorkflowRequest(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('workflow_requests')
    .update({ status: 'Completed', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
    .eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Workflow request marked complete', userData?.user?.id);
  return { success: true };
}

// ── MANAGEMENT PLAN EXPANSION (Ch.14) ──
export async function addOpticalAdvice(encounterId, advice) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_optical_advice').insert({ encounter_id: encounterId, advice, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Optical advice added: ${advice}`, userData?.user?.id);
  return { success: true };
}

export async function removeOpticalAdvice(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_optical_advice').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Optical advice removed', null);
  return { success: true };
}

export async function addProcedure(encounterId, name, eye, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, notes: notes || null, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Minor Procedure planned: ${name} (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function removeProcedure(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_procedures').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Procedure removed', null);
  return { success: true };
}

export async function addReferral(encounterId, destination, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_referrals').insert({ encounter_id: encounterId, destination, reason, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Referral added: ${destination}`, userData?.user?.id);
  return { success: true };
}

export async function removeReferral(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_referrals').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Referral removed', null);
  return { success: true };
}

export async function addCounsellingItem(encounterId, topic) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_counselling_items').insert({ encounter_id: encounterId, topic, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Counselling topic added: ${topic}`, userData?.user?.id);
  return { success: true };
}

export async function removeCounsellingItem(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Counselling topic removed', null);
  return { success: true };
}

// Any plan item (optical/procedure/referral/counselling) marked done --
// used from the Action Tracker tab.
export async function completePlanItem(table, id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ status: 'Done' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Plan item marked done', null);
  return { success: true };
}

// Follow-up is one record per encounter -- upsert by encounter_id.
export async function saveFollowup(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_followups')
    .upsert(
      { encounter_id: encounterId, after_period: fields.after, visit_type: fields.type, clinic: fields.clinic, instructions: fields.instructions, created_by: userData?.user?.id || null },
      { onConflict: 'encounter_id' }
    );
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Follow-up scheduled: ${fields.after} -- ${fields.type}`, userData?.user?.id);
  return { success: true };
}

export async function savePatientInstructions(encounterId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ patient_instructions: instructions }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Encounter completed', userData?.user?.id);

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'dilate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Dilation', userData?.user?.id);
  return result;
}

export async function sendForInvestigationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'investigate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Investigation', userData?.user?.id);
  return result;
}

// Minor Procedures are performed by the doctor directly, in the same
// sitting -- unlike Dilation/Investigation/Biometry there's no separate
// department to route the patient to, so this just confirms the
// procedure(s) for the audit trail. Billing already picks them up the
// moment they're added (billing_status defaults to 'Pending'); this
// doesn't change that.
export async function sendForProcedureFromConsultation(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Sent for Procedure', userData?.user?.id);
  return { success: true };
}

// Shared by both the "Add" button (advises Biometry without moving the
// patient anywhere yet) and "Send for Biometry" (which also routes the
// queue) -- creates the record if none exists yet for that eye, or
// updates instructions on the existing one rather than duplicating it.
// Matched per-eye (not just per-visit) since "Both Eyes" needs two
// independent records -- the Biometry workspace itself is built around
// one eye per record (separate measurements/IOL calc/approval each),
// so bilateral cases genuinely need two rows, not one row meaning both.
async function ensureBiometryRecordForEye(supabase, visitId, encounterId, eye, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .eq('surgical_eye', eye)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();
    const { data: created } = await supabase.from('biometry_records').insert({
      visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null,
      surgical_eye: eye, doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// "Both" fans out into one record per eye; RE/LE is just the one.
async function ensureBiometryRecords(supabase, visitId, encounterId, eye, instructions) {
  const eyes = eye === 'Both' ? ['RE', 'LE'] : [eye];
  const ids = [];
  for (const e of eyes) ids.push(await ensureBiometryRecordForEye(supabase, visitId, encounterId, e, instructions));
  return ids;
}

// The "Add" step -- advises Biometry is needed (records eye + optional
// instructions) without moving the patient's queue position at all.
// Mirrors exactly how Investigations work: "Add" saves the order,
// "Send for Investigation" is a separate, later action that routes the
// patient. Shows up immediately in the Investigation Queue's merged
// Biometry view either way, since that doesn't depend on queue status.
export async function adviseBiometry(visitId, encounterId, eye, instructions) {
  const supabase = await createClient();
  if (!eye) return { error: 'Select which eye Biometry is required for.' };
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecords(supabase, visitId, encounterId, eye, instructions);
  await addAudit(supabase, encounterId, `Biometry advised (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, encounterId, eye, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, `Sent for Biometry (${eye})`, userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  if (entry?.visit_id) await ensureBiometryRecords(supabase, entry.visit_id, encounterId, eye, instructions);

  return result;
}

// For updating instructions on a biometry record that's already been
// sent -- eye is fixed once a record exists (changing it would mean a
// different physical record, not editing this one), but instructions
// can still be corrected/added at any point before the technician
// finishes.
// Doctor can remove a mistakenly-added/sent biometry request (wrong
// eye, duplicate, etc.) -- but only while it's still unbilled. Once
// Front Office has billed it, removing the record here would leave an
// invoice line with nothing behind it, so that has to go through
// billing's own modification flow instead.
export async function removeBiometryRecord(id, encounterId) {
  const supabase = await createClient();
  const { data: record } = await supabase.from('biometry_records').select('billing_status').eq('id', id).maybeSingle();
  if (!record) return { error: 'Record not found.' };
  if (record.billing_status === 'Billed') {
    return { error: 'This has already been billed and cannot be removed here -- use Billing to modify the invoice first.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('biometry_records').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Biometry request removed', userData?.user?.id);
  return { success: true };
}

export async function updateBiometryInstructions(id, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_records').update({ doctor_instructions: instructions?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function saveDraft(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Consultation saved as draft', userData?.user?.id);
  return { success: true };
}

FILEEOF_consultation_actions_js

mkdir -p "app/consultation/[id]"
cat > "app/consultation/[id]/consultation-form.js" << 'FILEEOF_consultation_form_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addTaperedPrescription,
  removeTaperGroup,
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
import { getDiagnosesMaster, getDrugs, getDosageOptions, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import OptometryWorkspace from '@/app/(main)/optometry/[id]/optometry-workspace';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';
import { openPrintPopup } from '@/lib/printPopup';

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
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('optometry');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week' },
    { frequency: 'TDS', duration: '1 week' },
    { frequency: 'BD', duration: '1 week' },
    { frequency: 'OD', duration: '1 week' },
  ]);
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const invPriority = 'Routine'; // selector removed -- no longer needed
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
  const [dosageOptions, setDosageOptions] = useState([]);
  const [rxDrugTypeId, setRxDrugTypeId] = useState(null);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg, dg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      setDosageOptions(dg);
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

  // Type-ahead for the Prescription drug field -- matches on brand or
  // generic name, case-insensitive substring, capped to keep the list
  // scannable. Falls back to free-text (rxDrug itself) when nothing
  // matches, or to the full Browse dropdown if the doctor wants to look
  // rather than type.
  const rxSuggestions = rxDrug.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(rxDrug.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(rxDrug.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectRxDrug(d) {
    setRxDrug(d.brand);
    setRxDrugTypeId(d.drug_type_id || null);
    setRxDosage('');
    setShowRxSuggestions(false);
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week' }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    if (!rxDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxEye, steps: taperSteps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setShowTaperBuilder(false);
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

  // Escape hatch for a visit that genuinely can't go through the normal
  // completion path -- patient left before being seen, token called but
  // nobody responded, etc. Doesn't touch the diagnosis requirement for
  // any other visit; just closes this one with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a diagnosis.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp, surgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryNotes('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
    setEditSurgeryNotes(sc.notes || '');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp, editSurgeryNotes);
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
            isAdmin={data.isAdmin}
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
              cascades to every nested input/select/button in the embedded
              OptometryWorkspace, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'optometry' && (
            <OptometryWorkspace queueEntryId={queueEntryId} embedded />
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
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
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
                        <select className="fi" style={{ width: 130 }} value={bioEye} onChange={(e) => setBioEye(e.target.value)}>
                          <option value="">Select</option>
                          <option value="RE">Right (OD)</option>
                          <option value="LE">Left (OS)</option>
                          <option value="Both">Both (OU)</option>
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
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
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
                {(() => {
                  // Group rows sharing a taper_group_id into one block
                  // (ordered by taper_step); everything else renders as
                  // a normal single-line prescription, same as before.
                  const seen = new Set();
                  const items = [];
                  data.prescriptions.forEach((r) => {
                    if (r.taper_group_id) {
                      if (seen.has(r.taper_group_id)) return;
                      seen.add(r.taper_group_id);
                      const steps = data.prescriptions
                        .filter((x) => x.taper_group_id === r.taper_group_id)
                        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
                      items.push({ type: 'taper', key: r.taper_group_id, steps });
                    } else {
                      items.push({ type: 'single', key: r.id, row: r });
                    }
                  });
                  return items.map((item) => item.type === 'single' ? (
                    <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>
                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye}
                      </span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ) : (
                    <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <span style={{ fontSize: 13 }}>
                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye}
                          <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering Schedule</span>
                        </span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>
                      </div>
                      <div style={{ fontSize: 12.5, marginTop: 4, color: 'var(--g700)' }}>
                        {item.steps.map((s, i) => (
                          <span key={s.id}>
                            {i > 0 && <i className="ti ti-arrow-right" style={{ margin: '0 4px', color: 'var(--g400)' }}></i>}
                            {s.frequency} <span style={{ color: 'var(--g500)' }}>x {s.duration}</span>
                          </span>
                        ))}
                        <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
                      </div>
                    </div>
                  ));
                })()}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr auto', gap: 6, marginTop: 10, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span>Drug</span><span>Dosage</span><span>Frequency</span><span>Duration</span><span>Eye</span><span></span>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 4, flexWrap: 'wrap', alignItems: 'flex-start' }}>
                  <div style={{ position: 'relative', flex: '2 1 160px' }}>
                    <input
                      className="fi"
                      placeholder="Type to search medicines, or enter a new name"
                      value={rxDrug}
                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setShowRxSuggestions(true); }}
                      onFocus={() => setShowRxSuggestions(true)}
                      onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
                      style={{ width: '100%' }}
                    />
                    {showRxSuggestions && rxDrug.trim().length > 0 && (
                      <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 230, overflowY: 'auto', marginTop: 3 }}>
                        {rxSuggestions.length > 0 ? rxSuggestions.map((d) => (
                          <div key={d.id} onMouseDown={() => selectRxDrug(d)} style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 12.5, borderBottom: '1px solid var(--g100)' }}>
                            <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
                            {d.master_drug_types?.name && <span style={{ marginLeft: 6, fontSize: 10.5, color: 'var(--purple)' }}>{d.master_drug_types.name}</span>}
                          </div>
                        )) : (
                          <div style={{ padding: '8px 12px', fontSize: 12, color: 'var(--g500)' }}>
                            No match in Pharmacy master.{' '}
                            <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 11 }} onMouseDown={() => { setShowRxBrowseAll(true); setShowRxSuggestions(false); }}>Browse full list</button>
                            {' '}or keep typing to prescribe as free text.
                          </div>
                        )}
                      </div>
                    )}
                    {showRxBrowseAll && (
                      <select className="fi" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
                        if (!e.target.value) return;
                        const picked = drugOptions.find((d) => d.brand === e.target.value);
                        if (picked) selectRxDrug(picked);
                        setShowRxBrowseAll(false);
                      }}>
                        <option value="">-- Browse full Pharmacy master --</option>
                        {drugOptions.filter((d) => d.brand).map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                      </select>
                    )}
                  </div>
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option value="">-- Dosage --</option>
                    {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => (
                      <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                    ))}
                    {/* Generic fallback -- shown when the drug has no type assigned yet (free-typed name, or a master drug still missing its Type in Financial Masters) so the field never comes up empty. */}
                    {!rxDrugTypeId && (
                      <>
                        <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                      </>
                    )}
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>

                {!showTaperBuilder ? (
                  <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => setShowTaperBuilder(true)}>
                    <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                  </button>
                ) : (
                  <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug, Dosage &amp; Eye entered above; frequency reduces step by step below
                    </div>
                    {taperSteps.map((s, i) => (
                      <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                        <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                        <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                          <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                        </select>
                        <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                          <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
                        </select>
                        {taperSteps.length > 2 && (
                          <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
                        )}
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                      <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                      <button className="btn btn-sm btn-primary" onClick={handleAddTaperSchedule}>Save Tapering Schedule</button>
                      <button className="btn btn-sm" onClick={() => setShowTaperBuilder(false)}>Cancel</button>
                    </div>
                  </div>
                )}
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
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 110 }}>
                      <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
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
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 110 }}>
                                <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
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
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Notes</label>
                              <input className="fi" placeholder="Any notes for this surgery recommendation..." value={editSurgeryNotes} onChange={(e) => setEditSurgeryNotes(e.target.value)} />
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ padding: '6px 0' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                              <span style={{ flex: 1 }}>
                                <strong>{sc.procedure_name}</strong> -- {sc.eye === 'OD' ? 'Right (OD)' : sc.eye === 'OS' ? 'Left (OS)' : sc.eye === 'OU' ? 'Both (OU)' : sc.eye}
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
                            {sc.notes && (
                              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3, marginLeft: 22 }}><i className="ti ti-notes"></i> {sc.notes}</div>
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
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 110 }}>
                        <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
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
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
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

              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
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
          </div>

          {/* Escape hatch -- for a visit that genuinely can't reach the
              diagnosis requirement above (patient left, no-show after
              being called, etc). Kept visually separate from the main
              actions so it isn't a tempting shortcut for normal visits. */}
          {!isReadOnly && (
            <div className="card" style={{ marginTop: 8 }}>
              {!showForceClose ? (
                <button className="btn" style={{ fontSize: 12, color: 'var(--g500)' }} onClick={() => setShowForceClose(true)}>
                  <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
                </button>
              ) : (
                <div>
                  <label className="flbl">Why can&apos;t this visit be completed normally? *</label>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <input className="fi" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                      {forceClosing ? 'Closing...' : 'Confirm'}
                    </button>
                    <button className="btn" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
          </fieldset>

          {/* PRINT ACTIONS -- deliberately kept OUTSIDE the <fieldset
              disabled={isReadOnly}> above. Printing a case sheet / visit
              summary doesn't change any data, so a completed (locked)
              encounter should still allow printing without requiring
              "Unlock to Edit" first. */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <button onClick={() => openPrintPopup(`/opd-case-sheet-print/${data.encounter.id}`)} className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </button>
            <button onClick={() => openPrintPopup(`/visit-summary-print/${data.encounter.id}`)} className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

FILEEOF_consultation_form_js

mkdir -p "app/consultation/[id]"
cat > "app/consultation/[id]/follow-up-panel.js" << 'FILEEOF_follow_up_panel_js'
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
export function ContextSidebar({ patientId, previousVisitSummary, encounter, auditLog, isAdmin, openInvestigations, activeWorkflows, pendingRx, wfItems }) {
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

      {/* Audit Log is Administrator-only. */}
      {isAdmin && auditLog && (
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

FILEEOF_follow_up_panel_js

mkdir -p "app/(main)/optometry"
cat > "app/(main)/optometry/actions.js" << 'FILEEOF_optometry_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';

// Fields that live directly on optometry_assessments -- everything
// except IOP readings (own table, timestamped list) and audit entries
// (own table, append-only).
const ASSESSMENT_FIELDS = [
  'va_scale', 're_dist_unaided', 're_dist_glasses', 're_dist_ph', 're_near_unaided', 're_near_glasses',
  'le_dist_unaided', 'le_dist_glasses', 'le_dist_ph', 'le_near_unaided', 'le_near_glasses',
  'va_not_assessed',
  'ref_pg_re_dist_va', 'ref_pg_re_dist_sph', 'ref_pg_re_dist_cyl', 'ref_pg_re_dist_axis',
  'ref_pg_re_near_va', 'ref_pg_re_near_sph', 'ref_pg_re_near_cyl', 'ref_pg_re_near_axis',
  'ref_pg_le_dist_va', 'ref_pg_le_dist_sph', 'ref_pg_le_dist_cyl', 'ref_pg_le_dist_axis',
  'ref_pg_le_near_va', 'ref_pg_le_near_sph', 'ref_pg_le_near_cyl', 'ref_pg_le_near_axis',
  'ref_pg_copy_re_to_le',
  'ref_pd', 'ref_vd',
  'ref_obj_re_dist_va', 'ref_obj_re_dist_sph', 'ref_obj_re_dist_cyl', 'ref_obj_re_dist_axis',
  'ref_obj_re_near_va', 'ref_obj_re_near_sph', 'ref_obj_re_near_cyl', 'ref_obj_re_near_axis',
  'ref_obj_le_dist_va', 'ref_obj_le_dist_sph', 'ref_obj_le_dist_cyl', 'ref_obj_le_dist_axis',
  'ref_obj_le_near_va', 'ref_obj_le_near_sph', 'ref_obj_le_near_cyl', 'ref_obj_le_near_axis',
  'ref_obj_copy_re_to_le',
  'ref_subj_re_dist_va', 'ref_subj_re_dist_sph', 'ref_subj_re_dist_cyl', 'ref_subj_re_dist_axis',
  'ref_subj_re_near_va', 'ref_subj_re_near_sph', 'ref_subj_re_near_cyl', 'ref_subj_re_near_axis',
  'ref_subj_le_dist_va', 'ref_subj_le_dist_sph', 'ref_subj_le_dist_cyl', 'ref_subj_le_dist_axis',
  'ref_subj_le_near_va', 'ref_subj_le_near_sph', 'ref_subj_le_near_cyl', 'ref_subj_le_near_axis',
  'ref_subj_copy_re_to_le',
  'ref_final_re_dist_va', 'ref_final_re_dist_sph', 'ref_final_re_dist_cyl', 'ref_final_re_dist_axis',
  'ref_final_re_near_va', 'ref_final_re_near_sph', 'ref_final_re_near_cyl', 'ref_final_re_near_axis',
  'ref_final_le_dist_va', 'ref_final_le_dist_sph', 'ref_final_le_dist_cyl', 'ref_final_le_dist_axis',
  'ref_final_le_near_va', 'ref_final_le_near_sph', 'ref_final_le_near_cyl', 'ref_final_le_near_axis',
  'ref_final_copy_re_to_le',
  'iop_method', 'iop_time',
  'add_k1_re', 'add_k1_le', 'add_k2_re', 'add_k2_le', 'add_axial_length_re', 'add_axial_length_le',
  'add_pachymetry_re', 'add_pachymetry_le', 'add_schirmer_re', 'add_schirmer_le',
  'add_color_vision_re', 'add_color_vision_le', 'add_syringing_re', 'add_syringing_le',
  'section_va_done', 'section_pg_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done',
];

function pickAssessmentFields(fields) {
  const out = {};
  ASSESSMENT_FIELDS.forEach((key) => {
    if (fields[key] !== undefined) out[key] = fields[key];
  });
  return out;
}

async function addAudit(supabase, assessmentId, message, userId) {
  await supabase.from('optometry_audit_log').insert({ assessment_id: assessmentId, message, created_by: userId || null });
}

// Loads everything the workspace needs: the queue entry + patient, the
// assessment row (creating an empty Draft one on first open -- same
// pattern as encounters auto-creating on first doctor consultation),
// IOP readings, audit log, and lock status.
export async function getAssessmentWorkspaceData(queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits?.id;

  let { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .maybeSingle();

  if (!assessment) {
    const { data: newAssessment, error: createError } = await supabase
      .from('optometry_assessments')
      .insert({ visit_id: visitId, recorded_by: userData?.user?.id || null })
      .select()
      .single();

    if (createError) return { error: createError.message };
    assessment = newAssessment;
    await addAudit(supabase, assessment.id, 'Assessment started', userData?.user?.id);
  }

  // History (chief complaint, HOPI, ocular/medical/family/drug history,
  // allergy) lives on `encounters`, same table and columns the doctor's
  // History tab reads/writes via saveHistory. Opening it here lets the
  // optometrist capture it before the doctor ever sees the patient --
  // auto-created on first open, same pattern as the assessment above and
  // as the doctor's own encounter in consultation/actions.js.
  let { data: encounter } = await supabase
    .from('encounters')
    .select('*')
    .eq('visit_id', visitId)
    .order('started_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!encounter) {
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits?.doctor_id || null })
      .select()
      .single();

    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await supabase.from('encounter_audit_log').insert({ encounter_id: encounter.id, message: 'Encounter started (from Optometry)', created_by: userData?.user?.id || null });
  }

  const [{ data: iopReadings }, { data: auditLog }] = await Promise.all([
    supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: true }),
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessment.id).order('created_at', { ascending: false }),
  ]);

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // optometry_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);

  // Same lock rule as before: once completed, editable until the
  // doctor's queue entry moves to "In Consultation" or "Done".
  let locked = false;
  if (assessment.status === 'Completed') {
    const { data: doctorEntry } = await supabase
      .from('queue_entries')
      .select('status')
      .eq('visit_id', visitId)
      .eq('department', 'Doctor')
      .maybeSingle();

    // Viewed from the Optometry queue: lock as soon as the doctor has
    // taken over (In Consultation) or finished (Done). Viewed from the
    // Doctor's own queue entry (embedded in the consultation): the
    // doctor is the one currently "In Consultation", so that status
    // shouldn't lock them out of their own screen -- only a fully
    // Done visit does.
    const viewerIsDoctor = entry.department === 'Doctor';
    locked = doctorEntry?.status === 'Done' || (!viewerIsDoctor && doctorEntry?.status === 'In Consultation');
  }

  return { entry, assessment, encounter, iopReadings: iopReadings || [], auditLog: isAdmin ? (auditLog || []) : [], locked, isAdmin };
}

// "Save Draft" -- patient stays in the queue, nothing routed anywhere
// (BR-OPT-003).
export async function saveDraft(assessmentId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  await addAudit(supabase, assessmentId, 'Draft saved -- patient remains in Optometry Queue', userData?.user?.id);
  return { success: true };
}

// "Complete Assessment" -- first-time completion. Requires at least
// one VA measurement (VAL-OPT-002). Locks the queue entry forward by
// calling the existing optometry_complete RPC, which issues the
// Doctor token (BR-OPT-004) -- same mechanism the rest of the app
// already relies on.
export async function completeAssessment(assessmentId, queueEntryId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const vaFields = ['re_dist_unaided', 're_dist_glasses', 're_dist_ph', 're_near_unaided', 'le_dist_unaided', 'le_dist_glasses', 'le_dist_ph', 'le_near_unaided'];
  const hasVa = vaFields.some((k) => fields[k]);
  if (!hasVa) {
    return { error: 'At least one Visual Acuity measurement must be recorded before completion (VAL-OPT-002).' };
  }

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({
      ...pickAssessmentFields(fields),
      status: 'Completed',
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
      recorded_by: userData?.user?.id || null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', assessmentId);

  if (updateError) return { error: updateError.message };

  const { error: completeError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: queueEntryId });
  if (completeError) return { error: completeError.message };

  await addAudit(supabase, assessmentId, 'Assessment COMPLETED -- routed to Doctor Queue (AUTO-OPT-001)', userData?.user?.id);
  return { success: true };
}

// Edit path -- assessment already Completed and not yet locked (doctor
// hasn't opened the consultation). Updates fields only; queue status
// and doctor token were already handled the first time.
export async function updateCompletedAssessment(assessmentId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  await addAudit(supabase, assessmentId, 'Assessment updated post-completion -- not yet seen by doctor', userData?.user?.id);
  return { success: true };
}

// Add a single IOP reading -- applied immediately (not batched with
// the rest of the form), same as the prototype's "Add reading" flow.
// Out-of-range values still get recorded but flagged (VAL-OPT-003).
export async function addIopReading(assessmentId, eye, value) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const numericValue = parseFloat(value);
  if (!numericValue || numericValue <= 0 || numericValue > 80) {
    return { error: 'Enter a valid IOP value (1-80 mmHg).' };
  }

  const { data: reading, error } = await supabase
    .from('optometry_iop_readings')
    .insert({ assessment_id: assessmentId, eye, value: numericValue, recorded_by: userData?.user?.id || null })
    .select()
    .single();

  if (error) return { error: error.message };

  const isHigh = numericValue > 21;
  await addAudit(
    supabase,
    assessmentId,
    `IOP ${eye} = ${numericValue} mmHg${isHigh ? ' -- ELEVATED (VAL-OPT-003)' : ''}`,
    userData?.user?.id
  );

  return { reading };
}
FILEEOF_optometry_actions_js

mkdir -p "app/(main)/optometry/[id]"
cat > "app/(main)/optometry/[id]/optometry-workspace.js" << 'FILEEOF_optometry_workspace_js'
'use client';

import { useState, useEffect, useRef, Fragment } from 'react';
import { useRouter } from 'next/navigation';
import {
  getAssessmentWorkspaceData,
  saveDraft,
  completeAssessment,
  updateCompletedAssessment,
  addIopReading,
} from '@/app/(main)/optometry/actions';
import { getIopMethods } from '@/app/(main)/master-data/actions';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import HistoryTab from '@/app/consultation/[id]/history-tab';
import { openPrintPopup } from '@/lib/printPopup';

// "P" = partial line read -- standard Snellen convention, one P variant
// per line from 6/6 through 6/60 (worse lines below 6/60 -- 3/60, 2/60,
// 1/60 -- don't get a P variant).
const VA_SNELLEN = [
  '6/6', '6/6P', '6/9', '6/9P', '6/12', '6/12P', '6/18', '6/18P', '6/24', '6/24P',
  '6/36', '6/36P', '6/60', '6/60P', '3/60', '2/60', '1/60',
];
const VA_SPECIAL = ['FC@1m', 'FC@2m', 'FC@3m', 'HM', 'PL+', 'PL-', 'NPL'];

// Near vision uses its own fixed N-notation scale -- independent of the
// Snellen/LogMAR/ETDRS distance scale toggle. This is a closed list (no
// custom entry), unlike Distance.
const VA_NEAR = ['N4', 'N5', 'N6', 'N8', 'N10', 'N12', 'N18', 'N24', 'N36', '<N36'];

// SPH/CYL magnitude picker grid: 0.25 steps from 0.25 to 20.00, then a
// final row for the less-common high-power values (20.25 - 30.0).
const SPH_CYL_MAGNITUDES = [];
for (let v = 0.25; v <= 20; v += 0.25) SPH_CYL_MAGNITUDES.push(v.toFixed(2).replace(/0$/, ''));
SPH_CYL_MAGNITUDES.push('20.25', '20.5', '20.75', '30.0');

// AXIS picker grid: 0 - 180 in steps of 5.
const AXIS_VALUES = [];
for (let v = 0; v <= 180; v += 5) AXIS_VALUES.push(String(v));

const REF_TYPES = { obj: 'Objective (Auto-Rx)', subj: 'Subjective', final: 'Final Rx' };

function refKey(type, eye, distNear, metric) {
  return `ref_${type}_${eye}_${distNear}_${metric}`;
}
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

// Rows x eyes for the Visual Acuity table. "With PH" (pinhole) is
// Distance-only, per standard clinical practice -- no Near column for it.
const VA_ROWS = [
  { row: 'unaided', label: 'Unaided', dist: true, near: true },
  { row: 'glasses', label: 'With Existing Glass', dist: true, near: true },
  { row: 'ph', label: 'With PH', dist: true, near: false },
];
function vaKey(eye, distNear, row) {
  return `${eye}_${distNear}_${row}`;
}

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen', va_not_assessed: false,
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1_re: '', add_k1_le: '', add_k2_re: '', add_k2_le: '', add_axial_length_re: '', add_axial_length_le: '',
    add_pachymetry_re: '', add_pachymetry_le: '', add_schirmer_re: '', add_schirmer_le: '',
    add_color_vision_re: '', add_color_vision_le: '', add_syringing_re: '', add_syringing_le: '',
    section_va_done: false, section_pg_done: false, section_refraction_done: false, section_iop_done: false, section_additional_done: false,
  };
  ['re', 'le'].forEach((eye) => {
    VA_ROWS.forEach(({ row, dist, near }) => {
      if (dist) f[vaKey(eye, 'dist', row)] = '';
      if (near) f[vaKey(eye, 'near', row)] = '';
    });
  });
  ['pg', 'obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['dist', 'near'].forEach((dn) => {
        ['va', 'sph', 'cyl', 'axis'].forEach((m) => { f[refKey(type, eye, dn, m)] = ''; });
      });
    });
    f[`ref_${type}_copy_re_to_le`] = false;
  });
  return f;
}

// Button-styled stand-in for a text input, whose value is set via the
// SPH/CYL/AXIS pop-up picker rather than typed directly.
function PickerField({ value, onClick, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      className="fi fi-sm"
      style={{ textAlign: 'center', cursor: disabled ? 'default' : 'pointer', background: disabled ? 'var(--g50)' : '#fff', color: value ? 'var(--g800)' : 'var(--g400)', fontWeight: value ? 600 : 400 }}
    >
      {value || '--'}
    </button>
  );
}

// SPH/CYL magnitude + sign picker, or AXIS picker, depending on picker.kind.
function ValuePickerModal({ picker, currentValue, onSelect, onClose }) {
  const isAxis = picker.kind === 'axis';
  const [negative, setNegative] = useState(!String(currentValue || '').trim().startsWith('+'));

  return (
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 16, maxWidth: 480, width: '100%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>{picker.label}</div>
          <button type="button" className="btn btn-sm" onClick={onClose}><i className="ti ti-x"></i></button>
        </div>

        {!isAxis && (
          <>
            <div style={{ display: 'flex', gap: 6, marginBottom: 12 }}>
              <div
                onClick={() => setNegative(false)}
                style={{ flex: 1, textAlign: 'center', padding: '6px 0', borderRadius: 8, fontSize: 12, fontWeight: 700, cursor: 'pointer', border: `1.5px solid ${!negative ? 'var(--teal)' : 'var(--g200)'}`, background: !negative ? 'var(--teal)' : '#fff', color: !negative ? '#fff' : 'var(--g600)' }}
              >
                +ve
              </div>
              <div
                onClick={() => setNegative(true)}
                style={{ flex: 1, textAlign: 'center', padding: '6px 0', borderRadius: 8, fontSize: 12, fontWeight: 700, cursor: 'pointer', border: `1.5px solid ${negative ? 'var(--red)' : 'var(--g200)'}`, background: negative ? 'var(--red)' : '#fff', color: negative ? '#fff' : 'var(--g600)' }}
              >
                -ve
              </div>
            </div>
            <div
              onClick={() => { onSelect('0.00'); onClose(); }}
              style={{ marginBottom: 10, padding: '6px 10px', borderRadius: 8, fontSize: 12, fontWeight: 600, textAlign: 'center', cursor: 'pointer', border: '1.5px dashed var(--g300)', color: 'var(--g600)' }}
            >
              Plano (0.00)
            </div>
          </>
        )}

        <div style={{ display: 'grid', gridTemplateColumns: isAxis ? 'repeat(4, 1fr)' : 'repeat(5, 1fr)', gap: 6 }}>
          {(isAxis ? AXIS_VALUES : SPH_CYL_MAGNITUDES).map((v) => (
            <div
              key={v}
              onClick={() => { onSelect(isAxis ? v : `${negative ? '-' : '+'}${v}`); onClose(); }}
              style={{ textAlign: 'center', padding: '8px 4px', borderRadius: 8, fontSize: 12, fontWeight: 600, cursor: 'pointer', background: 'var(--g50)', border: '1px solid var(--g200)', color: 'var(--g700)' }}
            >
              {v}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
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


export default function OptometryWorkspace({ queueEntryId, embedded = false }) {
  const [entry, setEntry] = useState(null);
  const [assessment, setAssessment] = useState(null);
  const [encounter, setEncounter] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [isAdmin, setIsAdmin] = useState(false);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ history: true, va: true, pg: false, refraction: false, iop: false, additional: false });
  const [refTab, setRefTab] = useState('obj');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');
  const [picker, setPicker] = useState(null); // { kind: 'sphcyl'|'axis', fieldKey }
  const [showRefInstructions, setShowRefInstructions] = useState(false);

  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [iopMethods, setIopMethods] = useState([]);
  const router = useRouter();

  // 'idle' | 'pending' | 'saving' | 'saved' | 'error'
  const [autosaveState, setAutosaveState] = useState('idle');
  const autosaveTimer = useRef(null);
  const skipNextAutosave = useRef(true);

  function load() {
    getAssessmentWorkspaceData(queueEntryId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setEntry(result.entry);
      setAssessment(result.assessment);
      setEncounter(result.encounter);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setIsAdmin(!!result.isAdmin);
      setLocked(result.locked);

      const f = emptyForm();
      Object.keys(f).forEach((key) => {
        if (result.assessment[key] !== null && result.assessment[key] !== undefined) f[key] = result.assessment[key];
      });
      // Loading data (initial open, or a reload after a manual save)
      // sets the form too -- skip the very next autosave tick so that
      // doesn't get mistaken for a real edit.
      skipNextAutosave.current = true;
      setForm(f);
    });
  }

  useEffect(() => { load(); }, [queueEntryId]);

  useEffect(() => {
    getIopMethods().then((all) => setIopMethods(all.filter((m) => m.status === 'Active')));
  }, []);

  const isEdit = assessment?.status === 'Completed';

  // Autosaves the whole assessment ~1.2s after the last edit, in both
  // the Optometry module and embedded inside the Doctor module -- same
  // debounced pattern as the Examination tab, so nothing is lost if the
  // user navigates away without pressing Save Draft / Save Changes.
  useEffect(() => {
    if (!assessment || locked) return;
    if (skipNextAutosave.current) { skipNextAutosave.current = false; return; }

    setAutosaveState('pending');
    if (autosaveTimer.current) clearTimeout(autosaveTimer.current);
    const assessmentIdAtSchedule = assessment.id;

    autosaveTimer.current = setTimeout(async () => {
      setAutosaveState('saving');
      const saveFn = isEdit ? updateCompletedAssessment : saveDraft;
      const result = await saveFn(assessmentIdAtSchedule, form);
      setAutosaveState(result.error ? 'error' : 'saved');
    }, 1200);

    return () => clearTimeout(autosaveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form]);

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function setAdditional(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_additional_done: true }));
  }

  function setVa(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_va_done: true }));
  }

  function setVaNotAssessed(checked) {
    setForm((prev) => ({ ...prev, va_not_assessed: checked, section_va_done: true }));
  }

  function setRef(type, eye, distNear, metric, value) {
    setForm((prev) => {
      const next = { ...prev, [refKey(type, eye, distNear, metric)]: value, section_refraction_done: true };
      // Keep LE mirroring RE live while "Copy RE Value to LE" is on for this refraction type.
      if (eye === 're' && prev[`ref_${type}_copy_re_to_le`]) {
        next[refKey(type, 'le', distNear, metric)] = value;
      }
      return next;
    });
  }

  function toggleCopyToLE(type, checked) {
    setForm((prev) => {
      const next = { ...prev, [`ref_${type}_copy_re_to_le`]: checked };
      if (checked) {
        ['dist', 'near'].forEach((dn) => {
          ['va', 'sph', 'cyl', 'axis'].forEach((m) => {
            next[refKey(type, 'le', dn, m)] = prev[refKey(type, 're', dn, m)];
          });
        });
      }
      return next;
    });
  }

  // Present Glasses (PG) power -- same shape as a refraction entry
  // (SPH/CYL/AXIS/VA x Dist/Near x RE/LE), but describes the glasses
  // the patient already has, not a new prescription. Kept as its own
  // section/done-flag so it can't be conflated with actual refraction.
  function setPg(eye, distNear, metric, value) {
    setForm((prev) => {
      const next = { ...prev, [refKey('pg', eye, distNear, metric)]: value, section_pg_done: true };
      if (eye === 're' && prev.ref_pg_copy_re_to_le) {
        next[refKey('pg', 'le', distNear, metric)] = value;
      }
      return next;
    });
  }

  function togglePgCopyToLE(checked) {
    setForm((prev) => {
      const next = { ...prev, ref_pg_copy_re_to_le: checked };
      if (checked) {
        ['dist', 'near'].forEach((dn) => {
          ['va', 'sph', 'cyl', 'axis'].forEach((m) => {
            next[refKey('pg', 'le', dn, m)] = prev[refKey('pg', 're', dn, m)];
          });
        });
      }
      return next;
    });
  }

  // Pulls every value from one refraction type into another -- used to
  // bring Objective/Subjective readings into Final Rx with one click.
  // Printed documents (prescription, case sheet) only show what's in
  // Final Rx, so leaving this un-copied is what makes a genuinely
  // recorded Distance refraction silently vanish from the printout.
  function copyRefractionInto(fromType, toType) {
    setForm((prev) => {
      const next = { ...prev, [`section_${toType === 'final' ? 'refraction' : toType}_done`]: true };
      ['re', 'le'].forEach((eye) => {
        ['dist', 'near'].forEach((dn) => {
          ['va', 'sph', 'cyl', 'axis'].forEach((m) => {
            next[refKey(toType, eye, dn, m)] = prev[refKey(fromType, eye, dn, m)];
          });
        });
      });
      return next;
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
    if (result.error) {
      setSaving(false);
      setError(result.error);
      if (!openSections.va) toggleSection('va');
      return;
    }
    // Deliberately NOT resetting saving to false here -- stays disabled
    // through the navigation delay below, so a second click in that
    // window can't re-run completion (this is exactly how a duplicate
    // Doctor queue token got created previously).
    setOkMsg('Assessment completed -- routed to Doctor Queue.');
    setTimeout(() => router.push('/optometry-dashboard'), 1200);
  }

  // Escape hatch for a visit that can't reach the Visual Acuity
  // requirement above (patient left before being seen, etc). Doesn't
  // bypass VAL-OPT-002 for anyone else -- just closes this one entry
  // with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a VA measurement.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Visit closed.');
    setTimeout(() => router.push('/optometry-dashboard'), 1000);
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
  const doneCount = ['section_va_done', 'section_pg_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done'].filter((k) => form[k]).length;
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
      {!embedded && (
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
      )}

      {/* WORKFLOW PANEL */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#5eead4', boxShadow: '0 0 6px #5eead4', flexShrink: 0 }}></div>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#5eead4' }}>
          {locked ? (embedded ? 'Locked -- Visit Closed' : 'Locked -- Doctor Reviewing') : isEdit ? 'Assessment Completed -- Editable' : 'Optometry -- In Progress'}
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
            <div style={{ fontSize: 10.5, color: autosaveState === 'error' ? '#fca5a5' : '#64748b', display: 'flex', alignItems: 'center', gap: 4 }}>
              {autosaveState === 'pending' && <>Unsaved changes...</>}
              {autosaveState === 'saving' && <><i className="ti ti-loader-2"></i> Saving...</>}
              {autosaveState === 'saved' && <><i className="ti ti-cloud-check"></i> All changes saved</>}
              {autosaveState === 'error' && <><i className="ti ti-alert-triangle"></i> Autosave failed -- use Save button</>}
            </div>
          )}
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
          <i className="ti ti-lock"></i> {embedded ? 'This visit is closed. Shown here for reference only -- no further edits.' : 'The doctor has already started this consultation. Shown here for reference only -- no further edits.'}
        </div>
      )}
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* Escape hatch -- for a visit that can't reach the VA requirement
          above (patient left, no-show after being called, etc). Kept
          visually separate from the main actions so it isn't a tempting
          shortcut for normal visits. */}
      {!locked && !isEdit && (
        <div style={{ marginBottom: 12 }}>
          {!showForceClose ? (
            <button className="btn btn-sm" style={{ fontSize: 11.5, background: 'rgba(255,255,255,.06)', color: '#94a3b8', borderColor: 'rgba(255,255,255,.15)' }} onClick={() => setShowForceClose(true)}>
              <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
            </button>
          ) : (
            <div style={{ background: 'rgba(255,255,255,.05)', border: '1px solid rgba(255,255,255,.15)', borderRadius: 8, padding: 10 }}>
              <label className="flbl" style={{ color: '#cbd5e1' }}>Why can&apos;t this visit be completed normally? *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi fi-sm" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                  {forceClosing ? 'Closing...' : 'Confirm'}
                </button>
                <button className="btn btn-sm" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* PATIENT HISTORY -- same HistoryTab component and encounter
          record the doctor's History tab uses (app/consultation/[id]/history-tab.js,
          table `encounters`). Filling it in here means it's already on
          file by the time the doctor opens the consultation. */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num="H" color="var(--blue)" title="Patient History" badge={locked ? 'Locked' : 'Editable'} badgeCls={locked ? 'b-gray' : 'b-green'}
          open={openSections.history} onToggle={() => toggleSection('history')}
        >
          <fieldset disabled={locked} style={{ border: 'none', margin: 0, padding: 0 }}>
            {encounter && <HistoryTab encounter={encounter} findings={null} onSaved={() => {}} hideOptometryBanner />}
          </fieldset>
        </AsmtSection>
      </div>

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
                onClick={() => !locked && !form.va_not_assessed && setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: (locked || form.va_not_assessed) ? 'default' : 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>

          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600, color: 'var(--g700)', marginBottom: 12, cursor: locked ? 'default' : 'pointer' }}>
            <input type="checkbox" disabled={locked} checked={form.va_not_assessed} onChange={(e) => setVaNotAssessed(e.target.checked)} />
            None
          </label>

          {!form.va_not_assessed && (
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr>
                    <th style={{ width: 150 }}></th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                      OD (RE)
                    </th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                      OS (LE)
                    </th>
                  </tr>
                  <tr>
                    <th></th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>Dist</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>Near</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: '4px solid #fff' }}>Dist</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700 }}>Near</th>
                  </tr>
                </thead>
                <tbody>
                  {VA_ROWS.map(({ row, label, dist, near }) => (
                    <tr key={row} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>{label}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                            {dist ? (
                              <input className="fi fi-sm" list="va-dist-options" disabled={locked} value={form[vaKey(eye, 'dist', row)]} onChange={(e) => setVa(vaKey(eye, 'dist', row), e.target.value)} placeholder="--" />
                            ) : null}
                          </td>
                          <td style={{ padding: '6px 8px' }}>
                            {near ? (
                              <select className="fi fi-sm" disabled={locked} value={form[vaKey(eye, 'near', row)]} onChange={(e) => setVa(vaKey(eye, 'near', row), e.target.value)}>
                                <option value="">--</option>
                                {VA_NEAR.map((v) => <option key={v} value={v}>{v}</option>)}
                              </select>
                            ) : null}
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <datalist id="va-dist-options">
            {vaScaleValues.map((v) => <option key={v} value={v} />)}
            {VA_SPECIAL.map((v) => <option key={v} value={v} />)}
          </datalist>
        </AsmtSection>
      </div>
      {/* SECTION 2: PRESENT GLASSES (PG) POWER */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={2} color="var(--indigo, #4338ca)" title="Present Glasses (PG) Power" badge={form.section_pg_done ? 'Done' : 'Not started'} badgeCls={form.section_pg_done ? 'b-green' : 'b-gray'}
          open={openSections.pg} onToggle={() => toggleSection('pg')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            Power of the glasses the patient is currently wearing, read off a lensometer -- not a new prescription.
          </div>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 60 }}></th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                    OD (RE)
                  </th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                    OS (LE)
                  </th>
                </tr>
                <tr>
                  <th></th>
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h) => (
                    <th key={`pg-re-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>{h}</th>
                  ))}
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h, i) => (
                    <th key={`pg-le-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: i === 0 ? '4px solid #fff' : undefined }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {['dist', 'near'].map((distNear) => {
                  const leCopying = form.ref_pg_copy_re_to_le;
                  return (
                    <tr key={distNear} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)', textTransform: 'capitalize' }}>{distNear === 'dist' ? 'Dist' : 'Near'}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                            {distNear === 'dist' ? (
                              <input className="fi fi-sm" list="va-dist-options" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey('pg', eye, distNear, 'va')]} onChange={(e) => setPg(eye, distNear, 'va', e.target.value)} placeholder="--" />
                            ) : (
                              <select className="fi fi-sm" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey('pg', eye, distNear, 'va')]} onChange={(e) => setPg(eye, distNear, 'va', e.target.value)}>
                                <option value="">--</option>
                                {VA_NEAR.map((v) => <option key={v} value={v}>{v}</option>)}
                              </select>
                            )}
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey('pg', eye, distNear, 'sph')]} onClick={() => setPicker({ kind: 'sphcyl', label: `SPH -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey('pg', eye, distNear, 'sph') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey('pg', eye, distNear, 'cyl')]} onClick={() => setPicker({ kind: 'sphcyl', label: `CYL -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey('pg', eye, distNear, 'cyl') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey('pg', eye, distNear, 'axis')]} onClick={() => setPicker({ kind: 'axis', label: `AXIS -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey('pg', eye, distNear, 'axis') })} />
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  );
                })}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px' }}></td>
                  <td colSpan={7} style={{ padding: '6px 6px' }}>
                    <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, fontWeight: 600, color: 'var(--g700)', cursor: locked ? 'default' : 'pointer' }}>
                      <input type="checkbox" disabled={locked} checked={!!form.ref_pg_copy_re_to_le} onChange={(e) => togglePgCopyToLE(e.target.checked)} />
                      Copy RE Value to LE
                    </label>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </AsmtSection>
      </div>
      {/* SECTION 3: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={3} color="var(--blue)" title="Refraction" badge={form.section_refraction_done ? 'Done' : 'Not started'} badgeCls={form.section_refraction_done ? 'b-green' : 'b-gray'}
          open={openSections.refraction} onToggle={() => toggleSection('refraction')}
        >
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {Object.entries(REF_TYPES).map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10, flexWrap: 'wrap' }}>
            <div style={{ fontSize: 11, color: 'var(--g500)', flex: 1 }}>
              {refTab === 'obj' ? 'Auto-refractometer values. Review before finalizing.' : refTab === 'subj' ? 'Values obtained during subjective refraction with trial lenses.' : 'Final accepted refraction used for prescription / optical order -- printouts only read from this tab.'}
            </div>
            {refTab === 'final' && !locked && (
              <div style={{ display: 'flex', gap: 6 }}>
                <button type="button" className="btn btn-sm" onClick={() => copyRefractionInto('subj', 'final')} title="Pull every Subjective value into Final Rx">
                  <i className="ti ti-copy"></i> Copy from Subjective
                </button>
                <button type="button" className="btn btn-sm" onClick={() => copyRefractionInto('obj', 'final')} title="Pull every Objective (Auto-Rx) value into Final Rx">
                  <i className="ti ti-copy"></i> Copy from Objective
                </button>
              </div>
            )}
            <button
              type="button"
              className="btn btn-sm"
              style={{ background: 'var(--teal)', color: '#fff', border: 'none', flexShrink: 0 }}
              onClick={() => openPrintPopup(`/glasses-prescription-print/${assessment.id}`)}
            >
              <i className="ti ti-printer"></i> Print Prescription
            </button>
          </div>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 60 }}></th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                    OD (RE)
                  </th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                    OS (LE)
                  </th>
                </tr>
                <tr>
                  <th></th>
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h) => (
                    <th key={`re-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>{h}</th>
                  ))}
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h, i) => (
                    <th key={`le-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: i === 0 ? '4px solid #fff' : undefined }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {['dist', 'near'].map((distNear) => {
                  const leCopying = form[`ref_${refTab}_copy_re_to_le`];
                  return (
                    <tr key={distNear} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)', textTransform: 'capitalize' }}>{distNear === 'dist' ? 'Dist' : 'Near'}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                            {distNear === 'dist' ? (
                              <input className="fi fi-sm" list="va-dist-options" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'va')]} onChange={(e) => setRef(refTab, eye, distNear, 'va', e.target.value)} placeholder="--" />
                            ) : (
                              <select className="fi fi-sm" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'va')]} onChange={(e) => setRef(refTab, eye, distNear, 'va', e.target.value)}>
                                <option value="">--</option>
                                {VA_NEAR.map((v) => <option key={v} value={v}>{v}</option>)}
                              </select>
                            )}
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'sph')]} onClick={() => setPicker({ kind: 'sphcyl', label: `SPH -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'sph') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'cyl')]} onClick={() => setPicker({ kind: 'sphcyl', label: `CYL -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'cyl') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'axis')]} onClick={() => setPicker({ kind: 'axis', label: `AXIS -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'axis') })} />
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  );
                })}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>IPD</td>
                  <td colSpan={2} style={{ padding: '6px 6px' }}>
                    <input className="fi fi-sm" disabled={locked} style={{ width: 90 }} value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" />
                  </td>
                  <td colSpan={3} style={{ padding: '6px 6px' }}>
                    <button type="button" className="btn btn-sm" style={{ background: 'var(--indigo, #4338ca)', color: '#fff', border: 'none' }} onClick={() => setShowRefInstructions(true)}>
                      <i className="ti ti-info-circle"></i> Instructions
                    </button>
                  </td>
                  <td colSpan={3} style={{ padding: '6px 6px' }}>
                    <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, fontWeight: 600, color: 'var(--g700)', cursor: locked ? 'default' : 'pointer' }}>
                      <input type="checkbox" disabled={locked} checked={!!form[`ref_${refTab}_copy_re_to_le`]} onChange={(e) => toggleCopyToLE(refTab, e.target.checked)} />
                      Copy RE Value to LE
                    </label>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div style={{ marginTop: 12 }}>
            <label className="flbl">Vertex Distance (optional)</label>
            <input className="fi fi-sm" style={{ maxWidth: 200 }} disabled={locked} value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" />
          </div>

          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginTop: 12 }}>
            <i className="ti ti-info-circle"></i> Device-imported values should be reviewed before finalizing. All 3 refraction types are recorded independently.
          </div>
        </AsmtSection>
      </div>

      {picker && (
        <ValuePickerModal
          picker={picker}
          currentValue={form[picker.fieldKey]}
          onSelect={(v) => {
            const [, type, eye, distNear, metric] = picker.fieldKey.split('_');
            if (type === 'pg') setPg(eye, distNear, metric, v);
            else setRef(type, eye, distNear, metric, v);
          }}
          onClose={() => setPicker(null)}
        />
      )}

      {showRefInstructions && (
        <div onClick={() => setShowRefInstructions(false)} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
          <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 18, maxWidth: 440, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>Refraction -- Instructions</div>
              <button type="button" className="btn btn-sm" onClick={() => setShowRefInstructions(false)}><i className="ti ti-x"></i></button>
            </div>
            <ul style={{ fontSize: 12, color: 'var(--g600)', paddingLeft: 18, lineHeight: 1.7 }}>
              <li>Record Distance and Near separately for each eye -- tap a field to open the value picker.</li>
              <li>Tap SPH / CYL and choose +ve or -ve before selecting the magnitude.</li>
              <li>Enable &quot;Copy RE Value to LE&quot; only when both eyes genuinely match -- it overwrites LE with RE and keeps them locked together until unchecked.</li>
              <li>IPD (Interpupillary Distance) is recorded once per assessment, not per refraction type.</li>
            </ul>
          </div>
        </div>
      )}

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={4} color="var(--purple)" title="Intraocular Pressure" badge={form.section_iop_done ? 'Done' : 'Not started'} badgeCls={form.section_iop_done ? 'b-green' : 'b-gray'}
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
          num={5} color="var(--amber)" title="Additional Measurements" badge={form.section_additional_done ? 'Done' : 'Not started'} badgeCls={form.section_additional_done ? 'b-green' : 'b-gray'}
          open={openSections.additional} onToggle={() => toggleSection('additional')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 12 }}>Complete only the measurements relevant to this visit -- recorded per eye.</div>
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 150 }}></th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                    OD (RE)
                  </th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                    OS (LE)
                  </th>
                </tr>
              </thead>
              <tbody>
                {[
                  { key: 'k1', label: 'Keratometry K1', placeholder: 'e.g. 43.50 D' },
                  { key: 'k2', label: 'Keratometry K2', placeholder: 'e.g. 44.25 D' },
                  { key: 'axial_length', label: 'Axial Length', placeholder: 'e.g. 23.2 mm' },
                  { key: 'pachymetry', label: 'Pachymetry (CCT)', placeholder: 'e.g. 542 microns' },
                  { key: 'schirmer', label: 'Schirmer test', placeholder: 'e.g. 8 mm' },
                ].map(({ key, label, placeholder }) => (
                  <tr key={key} style={{ borderTop: '1px solid var(--g100)' }}>
                    <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>{label}</td>
                    <td style={{ padding: '6px 8px' }}>
                      <input className="fi fi-sm" disabled={locked} value={form[`add_${key}_re`]} onChange={(e) => setAdditional(`add_${key}_re`, e.target.value)} placeholder={placeholder} />
                    </td>
                    <td style={{ padding: '6px 8px', borderLeft: '4px solid #fff' }}>
                      <input className="fi fi-sm" disabled={locked} value={form[`add_${key}_le`]} onChange={(e) => setAdditional(`add_${key}_le`, e.target.value)} placeholder={placeholder} />
                    </td>
                  </tr>
                ))}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Color Vision</td>
                  {['re', 'le'].map((eye) => (
                    <td key={eye} style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                      <select className="fi fi-sm" disabled={locked} value={form[`add_color_vision_${eye}`]} onChange={(e) => setAdditional(`add_color_vision_${eye}`, e.target.value)}>
                        <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
                      </select>
                    </td>
                  ))}
                </tr>
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Syringing</td>
                  {['re', 'le'].map((eye) => (
                    <td key={eye} style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                      <select className="fi fi-sm" disabled={locked} value={form[`add_syringing_${eye}`]} onChange={(e) => setAdditional(`add_syringing_${eye}`, e.target.value)}>
                        <option value="">Not done</option><option>Patent</option><option>Blocked</option>
                      </select>
                    </td>
                  ))}
                </tr>
              </tbody>
            </table>
          </div>
        </AsmtSection>
      </div>

      {/* AUDIT LOG -- Administrator-only */}
      {isAdmin && (
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
      )}

      {!embedded && (
        <div style={{ marginTop: 16 }}>
          <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Queue
          </button>
        </div>
      )}
    </div>
  );
}
FILEEOF_optometry_workspace_js

mkdir -p "app/(main)/optometry-history"
cat > "app/(main)/optometry-history/actions.js" << 'FILEEOF_optometry_history_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';

export async function getOptometryHistory(filterStatus) {
  const supabase = await createClient();

  let query = supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      recorded_by_profile:profiles!optometry_assessments_recorded_by_fkey(full_name),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .order('created_at', { ascending: false });

  if (filterStatus) query = query.eq('status', filterStatus);

  const { data: assessments, error } = await query;
  if (error) return { error: error.message };

  const ids = (assessments || []).map((a) => a.id);

  // Full IOP reading history per assessment (not just the latest value --
  // the detail view needs the whole trend; the summary row still only
  // shows the latest).
  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r);
    });
  }

  // Doctor overrides: the doctor edits this assessment directly (no
  // separate shadow table). Every changed field is logged to this same
  // assessment's audit log as "Doctor override -- ...". The raw audit
  // log itself is Administrator-only (see optometry_audit_log RLS), but
  // this "was it overridden" signal is useful to everyone reviewing the
  // history list, so it's resolved via a narrow RPC that returns only
  // the assessment_ids affected -- never the message content, who made
  // the change, or when.
  let overriddenIds = new Set();
  if (ids.length > 0) {
    const { data: overrideRows } = await supabase.rpc('get_doctor_override_assessment_ids', { assessment_ids: ids });
    (overrideRows || []).forEach((r) => overriddenIds.add(r.assessment_id));
  }

  const rows = (assessments || []).map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    const lastRe = readings.RE.length ? readings.RE[readings.RE.length - 1].value : null;
    const lastLe = readings.LE.length ? readings.LE[readings.LE.length - 1].value : null;

    return {
      ...a,
      iopRe: lastRe,
      iopLe: lastLe,
      iopReadings: readings,
      hasDoctorCorrection: overriddenIds.has(a.id),
    };
  });

  return { rows };
}

// Full assessment detail for the read-only "open full sheet" viewer --
// fetched by assessment id directly (not queue entry id, since a
// history view has no live queue entry to key off).
export async function getAssessmentDetail(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid, age, gender)),
      recorded_by_profile:profiles!optometry_assessments_recorded_by_fkey(full_name),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .eq('id', assessmentId)
    .single();

  if (error) return { error: error.message };

  const [{ data: iopReadings }, { data: auditLog }] = await Promise.all([
    supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessmentId).order('recorded_at', { ascending: true }),
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessmentId).order('created_at', { ascending: false }),
  ]);

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // optometry_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);
  const visibleAuditLog = isAdmin ? (auditLog || []) : [];

  // Resolve "created_by" profile names for audit entries (mostly useful
  // for "Doctor override" lines, so the optometrist can see who made
  // the change) without needing a DB-level foreign key embed.
  const createdByIds = [...new Set(visibleAuditLog.map((a) => a.created_by).filter(Boolean))];
  let profileMap = {};
  if (createdByIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', createdByIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const annotatedAuditLog = visibleAuditLog.map((a) => ({
    ...a,
    created_by_name: profileMap[a.created_by] || null,
    isDoctorOverride: (a.message || '').startsWith('Doctor override'),
  }));

  // The "N field(s) overridden" banner stays visible to everyone (it's
  // resolved via the same non-admin-safe RPC as the history list), even
  // though the detailed entries below it are Administrator-only.
  let overrideCount = annotatedAuditLog.filter((a) => a.isDoctorOverride).length;
  if (!isAdmin) {
    const { data: overrideRows } = await supabase.rpc('get_doctor_override_assessment_ids', { assessment_ids: [assessmentId] });
    overrideCount = (overrideRows || []).length > 0 ? 1 : 0;
  }

  return {
    assessment,
    iopReadings: iopReadings || [],
    auditLog: annotatedAuditLog,
    overrideCount,
    isAdmin,
  };
}
FILEEOF_optometry_history_actions_js

mkdir -p "app/(main)/optometry-history/[assessmentId]"
cat > "app/(main)/optometry-history/[assessmentId]/assessment-viewer.js" << 'FILEEOF_assessment_viewer_js'
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
  const [isAdmin, setIsAdmin] = useState(false);
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
      setIsAdmin(!!result.isAdmin);
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
          <i className="ti ti-alert-triangle"></i> {isAdmin
            ? <>A doctor has overridden {overrideCount} field{overrideCount > 1 ? 's' : ''} on this record. See the highlighted entries in the Audit Log below for exactly what changed and when.</>
            : <>A doctor has overridden one or more fields on this record.</>}
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

      {/* AUDIT LOG -- Administrator-only. Doctor overrides are highlighted
          here since they're logged as regular entries on this same
          assessment (no separate shadow table). */}
      {isAdmin && (
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
      )}

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-history')}>
          <i className="ti ti-arrow-left"></i> Back to History
        </button>
      </div>
    </div>
  );
}
FILEEOF_assessment_viewer_js

mkdir -p "app/(main)/master-data"
cat > "app/(main)/master-data/actions.js" << 'FILEEOF_master_data_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

// Change History is Administrator-only (app-layer check here is a UX
// convenience -- the real boundary is the RLS policy on
// master_data_audit_log itself, which already blocks SELECT for
// non-admins at the database level).
export async function getMasterAuditLog(masterTable) {
  const supabase = await createClient();
  if (!(await isCurrentUserAdmin(supabase))) return [];
  let q = supabase.from('master_data_audit_log').select('*, profiles(full_name)').order('changed_at', { ascending: false }).limit(30);
  if (masterTable) q = q.eq('master_table', masterTable);
  const { data } = await q;
  return data || [];
}

// Lets client components (this page is 'use client') know whether to
// show the Change History card at all, rather than fetching it and
// getting an empty array back either way.
export async function amIAdmin() {
  return isCurrentUserAdmin();
}

// Generic toggle works the same way across all master tables -- every
// one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

// ── SHARED HELPERS: auto-code + consistent text formatting ──
// Applied everywhere a person types a free-text name/label into a
// master, so two staff members never accidentally create "iol",
// "IOL", and "Iol" as three different-looking entries, and nobody has
// to invent a unique code by hand.

// Title-cases each word, collapses repeated whitespace, trims ends.
// Deliberately simple/predictable rather than clever -- staff can
// still see exactly what they typed, just consistently capitalized.
function normalizeName(s) {
  return (s || '')
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/\w\S*/g, (w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
}

// Derives a short prefix from a category (or a fixed fallback for
// tables with no category concept) -- multi-word categories become an
// initialism ("Minor Procedure" -> MP, "chief_complaint" -> CC), single
// words are used whole if short enough or trimmed to 3 letters
// otherwise ("Cataract" -> CAT, "EDOF" -> EDOF).
function codePrefix(categoryOrFallback) {
  const words = (categoryOrFallback || '').trim().split(/[\s_]+/).filter(Boolean);
  if (words.length === 0) return 'GEN';
  if (words.length === 1) return words[0].length <= 4 ? words[0].toUpperCase() : words[0].slice(0, 3).toUpperCase();
  return words.map((w) => w[0]).join('').toUpperCase().slice(0, 4);
}

// Short alphanumeric codes, auto-generated and linked to category where
// one exists (e.g. Surgery category "Cataract" -> CAT01, CAT02...;
// Procedure category "Minor Procedure" -> MP01, MP02...; History
// Option category "chief_complaint" -> CC01, CC02...). For Clinical
// Master tables with no category concept (IOP Methods, Clinical
// Observations), pass a fixed short fallback prefix instead, so every
// code in Clinical Masters follows the same short PREFIX+NN pattern
// rather than some being long name-derived slugs like the old scheme
// produced.
async function generateCategoryCode(supabase, table, categoryOrFallback) {
  const prefix = codePrefix(categoryOrFallback);
  const { data } = await supabase.from(table).select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(2, '0')}`;
}

// Delete with a friendly message instead of a raw Postgres error when
// the record is still referenced elsewhere (e.g. a service used on a
// past invoice) -- staff should mark it Inactive in that case instead.
async function deleteMasterRecord(supabase, table, id, code) {
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) {
    if (error.code === '23503') return { error: 'Cannot delete -- this item is already in use elsewhere (e.g. on a past invoice or record). Set it to Inactive instead.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, table, code || id, 'Delete', 'Record deleted');
  return { success: true };
}

// ── EXPENSE CATEGORIES (Financial Master -- used in Cash Management > Petty Cash) ──
export async function getExpenseCategories() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').order('name');
  return data || [];
}
export async function addExpenseCategory(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_expense_categories', 'EXP');
  const { error } = await supabase.from('master_expense_categories').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_expense_categories', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateExpenseCategory(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_expense_categories').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_expense_categories', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}

// ── IOP METHODS (Clinical Master -- used in Optometry Assessment) ──
export async function getIopMethods() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iop_methods').select('*').order('name');
  return data || [];
}
export async function addIopMethod(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_iop_methods', 'IOP');
  const { error } = await supabase.from('master_iop_methods').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iop_methods', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateIopMethod(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_iop_methods').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_iop_methods', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteIopMethod(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iop_methods', id, code);
}

// ── DRUG TYPES (Financial Master -- Pharmacy tab, drives what dosage
// phrasing options the doctor's Prescription picker shows) ──
export async function getDrugTypes() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drug_types').select('*').order('name');
  return data || [];
}
export async function addDrugType(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_drug_types', 'TYP');
  const { error } = await supabase.from('master_drug_types').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drug_types', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDrugType(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_drug_types').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_drug_types', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteDrugType(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drug_types', id, code);
}

// Dosage phrasing options nested under a drug type -- e.g. "Apply thin
// layer" under Eye Ointment, "1 drop" under Eye Drop. Simple list items
// (like Package line items), not full master records, so no audit code.
export async function getDosageOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_dosage_options').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}
export async function addDosageOption(drugTypeId, dosageText) {
  const supabase = await createClient();
  const text = (dosageText || '').trim();
  if (!text) return { error: 'Dosage text is required.' };
  const { data: existing } = await supabase.from('master_dosage_options').select('display_order').eq('drug_type_id', drugTypeId).order('display_order', { ascending: false }).limit(1);
  const nextOrder = (existing?.[0]?.display_order ?? 0) + 1;
  const { error } = await supabase.from('master_dosage_options').insert({ drug_type_id: drugTypeId, dosage_text: text, display_order: nextOrder });
  if (error) return { error: error.message };
  return { success: true };
}
export async function removeDosageOption(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_dosage_options').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGICAL CONSUMABLES (Clinical Master -- Patient Check-In dropdown
// and Intraoperative Management quick-pick, both in OT Intraop) ──
export async function getSurgicalConsumablesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgical_consumables').select('*').order('name');
  return data || [];
}
export async function addSurgicalConsumable(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_surgical_consumables', 'CONS');
  const { error } = await supabase.from('master_surgical_consumables').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgical_consumables', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgicalConsumable(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_surgical_consumables').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_surgical_consumables', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteSurgicalConsumable(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgical_consumables', id, code);
}

// ── CLINICAL OBSERVATIONS (Clinical Master -- quick-pick chips in
// Optometry Assessment's Clinical Observations section) ──
export async function getClinicalObservations() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_clinical_observations').select('*').order('name');
  return data || [];
}
export async function addClinicalObservation(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_clinical_observations', 'OBS');
  const { error } = await supabase.from('master_clinical_observations').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_clinical_observations', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateClinicalObservation(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_clinical_observations').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_clinical_observations', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteClinicalObservation(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_clinical_observations', id, code);
}

// ── HISTORY OPTIONS (Clinical Master -- chip options in the doctor's
// Consultation History tab: Chief Complaint, Ocular/Medical/Family
// History). Four categories in one table; code is unique per category
// (not globally) since e.g. "Glaucoma" is a legitimate chip in both
// Ocular History and Family History. ──
export async function getHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_history_options').select('*').order('category').order('name');
  return data || [];
}
export async function addHistoryOption(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_history_options', values.category);
  const { error } = await supabase.from('master_history_options').insert({ code, name, category: values.category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_history_options', code, 'Create', `${name} (${values.category}) created`);
  return { success: true };
}
export async function updateHistoryOption(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_history_options').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_history_options', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteHistoryOption(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_history_options', id, code);
}

// Active-only, grouped by category -- what the doctor's Consultation
// History tab actually renders as selectable chips
// (app/(main)/consultation/[id]/history-tab.js).
export async function getActiveHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_history_options')
    .select('category, name')
    .eq('status', 'Active')
    .order('name');

  const grouped = { chief_complaint: [], ocular_history: [], medical_history: [], family_history: [], drug_history: [], allergy: [] };
  (data || []).forEach((row) => {
    if (grouped[row.category]) grouped[row.category].push(row.name);
  });
  return grouped;
}

// ── DOCTORS (Clinical Master) ──
// Deliberately NOT a separate table -- doctors are profiles (same
// source User Management and Appointments' doctor dropdown already
// use). This is a management view onto that same data, filtered to
// doctor-type designations, showing both Active and Inactive (unlike
// the dropdown-facing getDoctors() in appointments/actions.js, which
// only wants Active ones). New doctor accounts are still created in
// User Management (needs a real login, service-role auth), and name
// changes belong there too (it's tied to their login identity) -- so
// this tab intentionally offers status management only, no Edit/Delete.
export async function getDoctorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, code, full_name, designation, status')
    .eq('designation', 'Doctor')
    .order('full_name');
  const doctors = data || [];

  // Self-heal: any doctor profile created via User Management since this
  // was added (or missed by the one-time backfill) won't have a code yet.
  // Assign the next one in the same uniform DOC01, DOC02... sequence used
  // everywhere else in Clinical Masters, rather than anything category- or
  // designation-specific.
  const missing = doctors.filter((d) => !d.code);
  for (const d of missing) {
    // Re-queried fresh each time so each new code accounts for the one
    // just assigned above it.
    const code = await generateCategoryCode(supabase, 'profiles', 'DOC');
    const { error } = await supabase.from('profiles').update({ code }).eq('id', d.id);
    if (!error) d.code = code;
  }
  return doctors;
}

// ── SERVICES ──
// Services (Consultation, Investigation, Surgery, Pharmacy departments
// in master_services) follow their own long-established CON001, INV001...
// pattern -- 3-digit, scoped per department -- rather than the 2-digit
// generateCategoryCode scheme above. Kept separate so it stays exactly
// consistent with the codes already seeded in the database.
async function generateServiceCode(supabase, dept) {
  const prefix = (dept || 'SVC').slice(0, 3).toUpperCase();
  const { data } = await supabase.from('master_services').select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateServiceCode(supabase, values.dept);
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
    investigation_package: values.investigationPackage?.trim() || null,
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_services', code, 'Create', `${name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_services').update({
    name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
    investigation_package: values.investigationPackage?.trim() || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  if (oldValues.dept !== values.dept) changes.push(`Dept ${oldValues.dept} -> ${values.dept}`);
  if ((oldValues.investigation_package || '') !== (values.investigationPackage || '')) changes.push(`Package ${oldValues.investigation_package || '--'} -> ${values.investigationPackage || '--'}`);
  await logMasterAudit(supabase, 'master_services', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteService(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_services', id, code);
}

// ── PACKAGES ──
export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*, master_surgeries(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes ? normalizeName(values.includes) : null,
    surgery_id: values.surgeryId || null, status: 'Active',
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const includes = values.includes ? normalizeName(values.includes) : values.includes;
  const { error } = await supabase.from('master_packages').update({
    name, includes, surgery_id: values.surgeryId || null,
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.includes !== includes) changes.push('Includes updated');
  if ((oldValues.iol_category || '') !== (values.iolCategory || '')) changes.push(`IOL type ${oldValues.iol_category || '--'} -> ${values.iolCategory || '--'}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deletePackage(id, code) {
  const supabase = await createClient();
  // Constituents belong to the package -- clear them first so the
  // package row itself isn't blocked by its own line items.
  await supabase.from('package_line_items').delete().eq('package_id', id);
  return deleteMasterRecord(supabase, 'master_packages', id, code);
}

// ── PACKAGE CONSTITUENTS (breakup for billing / insurance requests) ──
export async function getPackageLineItems(packageId) {
  const supabase = await createClient();
  const { data } = await supabase.from('package_line_items').select('*').eq('package_id', packageId).order('sort_order');
  return data || [];
}
export async function addPackageLineItem(packageId, description, amount) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('package_line_items').select('sort_order').eq('package_id', packageId).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  const { error } = await supabase.from('package_line_items').insert({
    package_id: packageId, description: normalizeName(description), amount: parseFloat(amount) || 0, sort_order: (existing?.sort_order || 0) + 1,
  });
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', `Constituent added: ${normalizeName(description)} -- Rs.${amount}`);
  return { success: true };
}
export async function removePackageLineItem(id, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('package_line_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', 'Constituent removed');
  return { success: true };
}

// ── PROCEDURES (Clinical Master -- minor, in-clinic procedures a doctor
// performs directly, e.g. "Syringing", "FB Removal". Distinct from
// SURGERIES below, which are OT-based and back billing Packages.) ──
export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_procedures', category);
  const { error } = await supabase.from('master_procedures').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_procedures', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateProcedure(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_procedures').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_procedures', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteProcedure(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_procedures', id, code);
}

// ── SURGERIES (Clinical Master -- the OT-based surgery a doctor advises,
// e.g. "Phaco Cataract Surgery". No price -- pure clinical classification.
// Multiple billing Packages can point at one surgery, sub-classified by
// IOL type/origin for Cataract.) ──
export async function getSurgeries() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('*').order('name');
  return data || [];
}
export async function addSurgery(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_surgeries', 'SUR');
  const { error } = await supabase.from('master_surgeries').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgeries', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgery(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_surgeries').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_surgeries', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteSurgery(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgeries', id, code);
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name)').order('generic');
  return data || [];
}
// Drugs (Pharmacy tab) -- fixed "DRG" prefix, 3-digit sequence, same
// PREFIX+NNN shape as Services (CON001...) and Packages (PKG001...)
// rather than the old name-derived slug codes.
async function generateDrugCode(supabase) {
  const { data } = await supabase.from('master_drugs').select('code').ilike('code', 'DRG%');
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(/^DRG(\d+)$/);
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `DRG${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function addDrug(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const code = await generateDrugCode(supabase);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength, form: normalizeName(values.form),
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drugs', code, 'Create', `${generic} (${brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const form = normalizeName(values.form);
  const { error } = await supabase.from('master_drugs').update({
    brand, generic, strength: values.strength, form,
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.generic !== generic) changes.push(`Generic ${oldValues.generic} -> ${generic}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  await logMasterAudit(supabase, 'master_drugs', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDrug(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drugs', id, code);
}

// ── VENDORS (Financial Master -- used by Inventory > Material Input) ──
export async function getVendorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('inventory_vendors').select('*').order('name');
  return data || [];
}
export async function addVendorMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'inventory_vendors', 'Vendor');
  const { error } = await supabase.from('inventory_vendors').insert({
    code, name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
    status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'inventory_vendors', code, 'Create', `${name} added`);
  return { success: true };
}
export async function updateVendorMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('inventory_vendors').update({
    name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
  }).eq('id', id);
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.phone !== values.phone) changes.push(`Phone updated`);
  await logMasterAudit(supabase, 'inventory_vendors', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteVendorMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'inventory_vendors', id, code);
}

// ── DIAGNOSES ──
export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_diagnoses', 'DIAG');
  const { error } = await supabase.from('master_diagnoses').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_diagnoses', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDiagnosisMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_diagnoses').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_diagnoses', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDiagnosisMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_diagnoses', id, code);
}

// ── IOL CATALOG (Clinical Master, M29 -- referenced by Biometry &
// IOL Planning's Surgeon Approval screen). Brand/model act as the
// name-equivalent fields for code generation and normalization. ──
export async function getIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iol_catalog').select('*').order('brand').order('model');
  return data || [];
}
export async function addIolCatalogItem(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const code = await generateCategoryCode(supabase, 'master_iol_catalog', 'IOL');
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, manufacturer, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, manufacturer, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_iol_catalog', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteIolCatalogItem(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iol_catalog', id, code);
}

// Active-only, grouped by category -- what Surgeon Approval's "Specific
// IOL" dropdown actually consumes.
export async function getActiveIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_iol_catalog')
    .select('id, code, brand, model, manufacturer, category')
    .eq('status', 'Active')
    .order('brand');
  return data || [];
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.
FILEEOF_master_data_actions_js

mkdir -p "app/(main)/master-data/financial"
cat > "app/(main)/master-data/financial/page.js" << 'FILEEOF_master_data_financial_page_js'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService, deleteService,
  getPackages, addPackage, updatePackage, deletePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug, deleteDrug,
  getDrugTypes, addDrugType, updateDrugType, deleteDrugType,
  getDosageOptions, addDosageOption, removeDosageOption,
  getVendorsMaster, addVendorMaster, updateVendorMaster, deleteVendorMaster,
  getSurgeries,
  getMasterAuditLog, amIAdmin,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', label: 'Surgery', type: 'package' }, { key: 'Vendors', type: 'vendor' }];
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
  const [drugTypes, setDrugTypes] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);
  const [showTypesPanel, setShowTypesPanel] = useState(false);
  const [expandedTypeId, setExpandedTypeId] = useState(null);
  const [newTypeName, setNewTypeName] = useState('');
  const [newDosageText, setNewDosageText] = useState('');
  const [surgeries, setSurgeries] = useState([]);
  const [vendors, setVendors] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [isAdmin, setIsAdmin] = useState(false);
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
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : tabDef.type === 'vendor' ? 'inventory_vendors' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setDrugTypes(await getDrugTypes());
    setDosageOptions(await getDosageOptions());
    setSurgeries(await getSurgeries());
    setVendors(await getVendorsMaster());
    const admin = await amIAdmin();
    setIsAdmin(admin);
    if (admin) setAuditLog(await getMasterAuditLog(auditTable));
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
      if (!form.generic) { setError('Salt Composition is required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (tabDef.type === 'vendor') {
      if (!form.name) { setError('Vendor name is required.'); return; }
    } else if (!form.name) {
      setError('Name is required.'); return;
    }

    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract';
      result = await addPackage(isCataract ? form : { ...form, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else if (tabDef.type === 'vendor') result = await addVendorMaster(form);
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
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand || '', generic: record.generic || '', strength: record.strength || '', form: record.form || '', drugTypeId: record.drug_type_id || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
    else if (tabDef.type === 'vendor') setEditForm({ name: record.name || '', contactPerson: record.contact_person || '', phone: record.phone || '', gstNumber: record.gst_number || '' });
    else setEditForm({ name: record.name || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '', investigationPackage: record.investigation_package || '' });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function handleAddType() {
    setError(''); setSuccess('');
    if (!newTypeName.trim()) return;
    const result = await addDrugType({ name: newTypeName });
    if (result?.error) { setError(result.error); return; }
    setNewTypeName('');
    refresh();
  }

  async function handleRenameType(t, name) {
    if (!name.trim() || name === t.name) return;
    await updateDrugType(t.id, t, { name });
    refresh();
  }

  async function handleAddDosage(typeId) {
    setError(''); setSuccess('');
    if (!newDosageText.trim()) return;
    const result = await addDosageOption(typeId, newDosageText);
    if (result?.error) { setError(result.error); return; }
    setNewDosageText('');
    refresh();
  }

  async function handleRemoveDosage(id) {
    await removeDosageOption(id);
    refresh();
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract';
      result = await updatePackage(record.id, record, isCataract ? editForm : { ...editForm, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else if (tabDef.type === 'vendor') result = await updateVendorMaster(record.id, record, editForm);
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
    else if (tabDef.type === 'vendor') result = await deleteVendorMaster(record.id, record.code);
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

          {(tabDef.type === 'service' || tabDef.type === 'drug' || tabDef.type === 'vendor') && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> {tabDef.type === 'service' ? 'Code is generated automatically, linked to department (e.g. INV001, INV002...).' : tabDef.type === 'vendor' ? 'Code is generated automatically (VEN01, VEN02...). Vendor names must be unique.' : 'Code is generated automatically from the name.'}
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
                  <input className="fi" placeholder="Name" onChange={update('brand')} />
                  <input className="fi" placeholder="Salt Composition" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <select className="fi" onChange={update('drugTypeId')} defaultValue="">
                    <option value="">-- Type (e.g. Eye Drop) --</option>
                    {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                  </select>
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'vendor' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Vendor / Distributor Name" onChange={update('name')} />
                  <input className="fi" placeholder="Contact Person (optional)" onChange={update('contactPerson')} />
                  <input className="fi" placeholder="Phone (optional)" onChange={update('phone')} />
                  <input className="fi" placeholder="GST Number (optional)" onChange={update('gstNumber')} />
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
              <thead><tr><th>Code</th><th>Name</th><th>Salt Composition</th><th>Strength</th><th>Type</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.drugTypeId || ''} onChange={updateEdit('drugTypeId')}>
                          <option value="">-- Type --</option>
                          {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                        </select>
                      </td>
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
                      <td>{d.master_drug_types?.name || <span style={{ color: 'var(--g400)' }}>-- unset --</span>}</td>
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

          {tabDef.type === 'vendor' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Contact Person</th><th>Phone</th><th>GST Number</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {vendors.map((v) => (
                  editingId === v.id ? (
                    <tr key={v.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input className="fi fi-sm" value={editForm.contactPerson} onChange={updateEdit('contactPerson')} /></td>
                      <td><input className="fi fi-sm" value={editForm.phone} onChange={updateEdit('phone')} /></td>
                      <td><input className="fi fi-sm" value={editForm.gstNumber} onChange={updateEdit('gstNumber')} /></td>
                      <td><span className={`badge ${v.status === 'Active' ? 'b-green' : 'b-gray'}`}>{v.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(v)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={v.id}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td><td style={{ fontWeight: 600 }}>{v.name}</td>
                      <td>{v.contact_person || '--'}</td><td>{v.phone || '--'}</td><td>{v.gst_number || '--'}</td>
                      <td><StatusToggle record={v} table="inventory_vendors" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(v)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(v)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {vendors.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No vendors yet. Add one to start using it in Inventory &gt; Material Input.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <div className="card" style={{ marginTop: 16 }}>
              <div className="card-head" style={{ cursor: 'pointer' }} onClick={() => setShowTypesPanel((p) => !p)}>
                <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-category-2" style={{ color: 'var(--purple)' }}></i> Manage Drug Types &amp; Dosage Options</div>
                <i className={`ti ti-chevron-${showTypesPanel ? 'up' : 'down'}`}></i>
              </div>
              {showTypesPanel && (
                <div style={{ marginTop: 12 }}>
                  <div className="msg-info" style={{ marginBottom: 12 }}>
                    <i className="ti ti-info-circle"></i> Each type&apos;s dosage options are what shows up in the doctor&apos;s Prescription dosage dropdown when a drug of that type is selected -- e.g. &quot;Apply thin layer&quot; for Eye Ointment instead of &quot;1 drop&quot;.
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                    <input className="fi" style={{ maxWidth: 260 }} placeholder="New type name (e.g. Suspension)" value={newTypeName} onChange={(e) => setNewTypeName(e.target.value)} />
                    <button className="btn btn-primary" onClick={handleAddType}>Add Type</button>
                  </div>
                  {drugTypes.map((t) => (
                    <div key={t.id} style={{ border: '1px solid var(--g100)', borderRadius: 8, marginBottom: 8, overflow: 'hidden' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: 'var(--g50)' }}>
                        <button className="btn btn-sm" onClick={() => setExpandedTypeId((id) => (id === t.id ? null : t.id))}>
                          <i className={`ti ti-chevron-${expandedTypeId === t.id ? 'up' : 'down'}`}></i>
                        </button>
                        <input
                          className="fi fi-sm" style={{ maxWidth: 220, fontWeight: 600 }}
                          defaultValue={t.name}
                          onBlur={(e) => handleRenameType(t, e.target.value)}
                        />
                        <span style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{t.code}</span>
                        <span style={{ marginLeft: 'auto' }}><StatusToggle record={t} table="master_drug_types" onUpdate={refresh} /></span>
                      </div>
                      {expandedTypeId === t.id && (
                        <div style={{ padding: 12 }}>
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).map((o) => (
                            <div key={o.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
                              <span style={{ fontSize: 13 }}>{o.dosage_text}</span>
                              <button className="btn btn-sm" style={{ marginLeft: 'auto', padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveDosage(o.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i>
                              </button>
                            </div>
                          ))}
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).length === 0 && (
                            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No dosage options yet for this type.</div>
                          )}
                          <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                            <input className="fi fi-sm" placeholder="e.g. Apply thin layer" value={newDosageText} onChange={(e) => setNewDosageText(e.target.value)} />
                            <button className="btn btn-sm btn-primary" onClick={() => handleAddDosage(t.id)}>Add</button>
                          </div>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Surgery</th><th>IOL Type / Origin</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  <Fragment key={p.id}>
                  {editingId === p.id ? (
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
                  )}

                  {constituentsFor?.id === p.id && (
                    <tr>
                      <td colSpan={7} style={{ padding: 0, border: 'none' }}>
                        <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, margin: '4px 0 12px' }}>
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
                      </td>
                    </tr>
                  )}
                  </Fragment>
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
          )}
        </div>
      </div>

      {isAdmin && (
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
      )}
    </div>
  );
}
FILEEOF_master_data_financial_page_js

echo "Files written. Run: npm run build"
