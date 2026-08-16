#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
#
# Biometry moved out of its own special category, per your instruction:
# it's now an ordinary entry in the Investigations master list, ordered
# through the same regular Investigations panel in Doctor Consultation
# as anything else (OCT, Visual Field, etc) -- while still routing to
# its own dedicated Biometry module underneath, since the actual
# fulfillment (device readings, both eyes, IOL recommendations, report)
# doesn't fit the generic investigation flow.
#
# DB changes ALREADY applied to both production (flzysyzhaecaqbmdcuao)
# and training (ffaddzpwnbizhvhujlse):
#   - master_services: BIO001 ("Biometry (Procedure Charge)", dept=
#     Biometry) renamed to "Biometry" and moved to dept=Investigation.
#   - surgical_cases: new treatment_instructions column (Surgical
#     Journey's new "Further Instructions" field under Treatment,
#     separate from the existing pre-op panel notes).
# No SQL to run manually.
#
# ALSO FOUND AND FIXED while doing this: "Pediatric Biometry" (already
# correctly dept=Investigation) never showed up in the doctor's
# Investigations dropdown either -- the filter excluded ANY investigation
# with "biometry" in its name, not just the special Biometry service.
# Removed entirely; both now appear correctly.
#
# WHAT CHANGED:
#   - Master Data (Financial): "Biometry" removed as its own department
#     tab -- it's just Investigation now, same tab as everything else.
#   - Doctor Consultation (OPD only, per your instruction): the entire
#     dedicated "Biometry" section/card is gone. Biometry is selected
#     from the regular Investigations dropdown like any other item.
#     Ordering it there still creates a normal investigation_orders row
#     (shows up in the OPD list like anything else) AND ensures the
#     underlying biometry_records row exists so it correctly routes to
#     the Biometry module. If the patient already has Measured biometry
#     on file (it'"'"'s reusable for years), ordering again just tells you
#     that instead of creating a duplicate -- "just check if it exists,
#     it can be mapped" per your instruction.
#   - When biometry is marked Measured, the matching investigation_orders
#     row(s) across ALL of this patient'"'"'s encounters flip to Available
#     automatically, so nothing sits stuck showing "Ordered" forever in
#     the doctor'"'"'s list.
#   - "Send for Biometry" as a separate queue-routing action is gone --
#     biometry now travels with "Send for Investigation" like everything
#     else in that list.
#   - Surgical Journey (surgery module) is confirmed as the ONLY place
#     for further surgery-specific investigation handling -- this was
#     already true structurally and needed no change. Added a new
#     "Further Instructions" field under the Treatment section (next to
#     procedure/eye) for anything else worth noting about the treatment
#     itself.

cd ~/veda-hmis 2>/dev/null || true

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
    { data: diagnosisHistoryRaw }, { data: surgicalCases },
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

  // Biometry is a "special" investigation -- selectable here like any
  // other, but fulfilled through its own dedicated module (device
  // readings for both eyes, IOL recommendations, report upload), not
  // the plain investigation queue. Ordering it here still creates a
  // normal investigation_orders row (shows up in this OPD list like
  // anything else), but also ensures the underlying biometry_records
  // row exists so it correctly routes there. Biometry is patient-level
  // and reusable for years -- if it's already Measured, there's
  // nothing to re-order, just say so instead of creating a duplicate.
  if (values.name.trim().toLowerCase() === 'biometry') {
    const { data: enc } = await supabase.from('encounters').select('visit_id, visits(patient_id)').eq('id', encounterId).single();
    const patientId = enc?.visits?.patient_id;
    if (!patientId) return { error: 'Could not resolve patient for this encounter.' };

    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id, status')
      .eq('patient_id', patientId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (existing && existing.length > 0 && existing[0].status === 'Measured') {
      return { error: 'Biometry is already on file for this patient (Measured) -- no need to re-order. Open it from the Biometry module if you need to review it.' };
    }

    const { error } = await supabase.from('investigation_orders').insert({
      encounter_id: encounterId, name: 'Biometry', eye: values.eye, priority: values.priority,
    });
    if (error) return { error: error.message };

    if (!existing || existing.length === 0) {
      await supabase.from('biometry_records').insert({ patient_id: patientId, visit_id: enc.visit_id, encounter_id: encounterId });
    }

    await addAudit(supabase, encounterId, 'Biometry ordered', userData?.user?.id);
    return { success: true };
  }

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
// Biometry is patient-level now, not visit/case-level, and always
// covers both eyes -- one session is reused across every future
// surgical case for that patient (readings don't meaningfully change
// for years). "Advise" just ensures a record exists for this patient,
// updating instructions if one already does.
async function ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: created } = await supabase.from('biometry_records').insert({
      patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null,
      doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// The "Add" step -- advises Biometry is needed (records instructions,
// if any) without moving the patient's queue position at all. Mirrors
// exactly how Investigations work: "Add" saves the order, "Send for
// Investigation" is a separate, later action that routes the patient.
export async function adviseBiometry(patientId, visitId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions);
  await addAudit(supabase, encounterId, 'Biometry advised', userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, patientId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, 'Sent for Biometry', userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  await ensureBiometryRecord(supabase, patientId, entry?.visit_id || null, encounterId, instructions);

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
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation'));
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
  }, [data]);

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
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
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

              <GroupHeader num={2} color="var(--teal)" title="Diagnosis" />

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

              <GroupHeader num={3} color="var(--blue)" title="Treatment" />

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

              <GroupHeader num={4} color="var(--amber)" title="Patient Management" />

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

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/actions.js" << 'FILEEOF_biometry_actions_js'
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
FILEEOF_biometry_actions_js

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

const SERVICE_DEPTS = ['Consultation', 'Investigation', 'Minor Procedure'];
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

mkdir -p "app/(main)/surgical-journey"
cat > "app/(main)/surgical-journey/actions.js" << 'FILEEOF_surgical_journey_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { adviseBiometry } from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/counselling/actions';

// This module deliberately does NOT reimplement package selection,
// biometry skip/unskip, decision recording, ready-for-scheduling, or OT
// booking -- the page imports those directly from Counselling and OT
// Schedule (same pattern Consultation already uses to call into
// Counselling), since that logic is already built, tested, and
// correct. What THIS file adds is a single page that walks through all
// of it for one patient without switching modules, plus a few
// genuinely new pieces (proceed status, IOL order notes, manual
// reminder tracking) that didn't exist anywhere before.

// ── EDIT PROCEDURE / EYE (any stage) ───────────────────────────────
// counselling's updateSurgicalCase only allows this while status is
// still 'Pending Workup' and refuses otherwise with no real
// alternative -- there was no actual place "further changes should go
// through Counselling" could happen. This lets a genuine correction
// (wrong eye picked, procedure name needs fixing) happen at ANY stage,
// same principle as changePackage/setDecision: once the case has
// progressed, a reason is required and logged, rather than the edit
// being refused outright.
export async function editSurgicalCaseDetails(caseId, procedureName, eye, reason) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status, procedure_name, eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const progressed = sc.status !== 'Pending Workup';
  if (progressed && (!reason || !reason.trim())) {
    return { error: `A reason is required to change the procedure/eye once the case has moved to "${sc.status}".` };
  }

  const { error } = await supabase.from('surgical_cases').update({ procedure_name: procedureName, eye }).eq('id', caseId);
  if (error) return { error: error.message };

  if (progressed) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Procedure/eye corrected -- was "${sc.procedure_name}" (${sc.eye}), now "${procedureName}" (${eye}). Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  return { success: true };
}

// ── FURTHER INSTRUCTIONS (Treatment) ───────────────────────────────
// Free text tied to the treatment itself (procedure + eye), distinct
// from the pre-op panel notes in the Investigations step.
export async function setTreatmentInstructions(caseId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ treatment_instructions: instructions || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DASHBOARD ────────────────────────────────────────────────────────

// Every open surgical case (any staff member -- a small setup doesn't
// have per-doctor case ownership walls). "Open" = not yet Completed or
// Cancelled.
export async function getMyActiveSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: false });
  if (error) return [];
  return data || [];
}

// Patients who said they'd come back another day and haven't yet
// (proceed_status stays 'Awaiting Return' until someone either moves
// them to Proceeding or the case is cancelled). Ordered oldest-first so
// the ones most overdue for a follow-up call surface at the top.
export async function getAwaitingReturnCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile)')
    .eq('proceed_status', 'Awaiting Return')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── CASE DETAIL ─────────────────────────────────────────────────────

export async function getSurgicalCaseDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select(`
      *,
      patients:patient_id(id, first_name, last_name, uhid, mobile, age, gender),
      master_packages:package_id(id, name, price, iol_category),
      profiles:surgeon_id(full_name)
    `)
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  // Biometry is patient-level now, not case-scoped -- reused across
  // every future surgical case for that patient (readings don't
  // meaningfully change for years). No more per-eye/per-case matching
  // needed; just look up whatever's on file for this patient.
  const { data: biometryRecords } = await supabase
    .from('biometry_records')
    .select('id, status, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false });

  // Day-of-surgery live status -- OT Schedule / Intraop / Recovery
  // already have solid, tested clinical workflows; this page doesn't
  // rebuild them, it just shows where the case currently stands and
  // deep-links into whichever one applies.
  const { data: otSchedule } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, status, master_ot_sessions(name)')
    .eq('surgical_case_id', caseId)
    .order('scheduled_date', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recoveryEpisode = null;
  if (otSchedule) {
    const { data } = await supabase
      .from('recovery_episodes')
      .select('id, discharge_date')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    recoveryEpisode = data;
  }

  // Medical fitness stays a real doctor referral/review, same as
  // Counselling -- this isn't a rubber-stamp checkbox, so it keeps its
  // own dedicated review step rather than being folded into a form
  // field here.
  const { data: fitnessReferral } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status, referred_at, fitness_notes')
    .eq('surgical_case_id', caseId)
    .order('referred_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: caseNotes } = await supabase
    .from('surgical_case_notes')
    .select('*, profiles:created_by(full_name)')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });

  // The surgeon's final IOL choice -- separate module/step from both
  // Biometry (raw device recommendations) and this page's own package
  // selection (billing category only).
  const { data: iolApproval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  return {
    case: { ...sc, biometry_done: biometryRecords.some((b) => b.status === 'Measured') },
    biometryRecords,
    fitnessReferral: fitnessReferral || null,
    iolApproval: iolApproval || null,
    otSchedule: otSchedule || null,
    recoveryEpisode,
    caseNotes: caseNotes || [],
  };
}

// ── ADVISE SURGERY (Step 1-2) ──────────────────────────────────────
// Thin wrapper so the new page's "Advise Surgery" button doesn't need
// to import from Consultation directly -- same underlying function,
// same surgical_cases row Counselling already reads.
export async function adviseSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  return markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes);
}

// ── INVESTIGATIONS (Step 3) ────────────────────────────────────────
// Biometry is real, in-house, tracked work, always covers both eyes,
// and is reused across every future surgical case for the patient
// (readings don't meaningfully change for years). Goes through the
// same mechanism a doctor uses during a normal consultation, landing
// in the actual Biometry Queue. The pre-op panel (blood work etc.) is
// done entirely by a third party -- there's nothing to "order" in this
// system, so it's just a free-text note here; the report itself comes
// in later as an attachment (see AttachmentUploader on the page).
export async function orderBiometryForCase(caseId, instructions) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('patient_id, visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  return adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, instructions);
}

export async function setPreOpPanelNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEED STATUS (Step 4) ────────────────────────────────────────
export async function setProceedStatus(caseId, status) {
  const supabase = await createClient();
  if (!['Deciding', 'Awaiting Return', 'Proceeding'].includes(status)) return { error: 'Invalid status.' };
  const { error } = await supabase.from('surgical_cases').update({ proceed_status: status }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── IOL PROCUREMENT + INFORMAL DATE (Step 6-7) ─────────────────────
// Free text by design -- "Ordered Alcon monofocal +21D from XYZ
// Optics, expected Friday". No structured supplier/PO tracking yet.
export async function setIolOrderNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ iol_order_notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── AWAITING-RETURN REMINDERS (manual for now -- WhatsApp template not
// yet approved, see conversation) -- just tracks that someone called,
// for the front-desk follow-up list. Also drops a case note so there's
// a record of what was said, reusing the same notes trail as everything
// else on the case. ──
export async function recordManualReminder(caseId, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('reminder_count').eq('id', caseId).single();
  const { error } = await supabase.from('surgical_cases').update({
    last_reminder_sent_at: new Date().toISOString(),
    reminder_count: (sc?.reminder_count || 0) + 1,
  }).eq('id', caseId);
  if (error) return { error: error.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: `Follow-up call -- ${note || 'no details recorded'}`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}
FILEEOF_surgical_journey_actions_js

mkdir -p "app/(main)/surgical-journey/[id]"
cat > "app/(main)/surgical-journey/[id]/workspace.js" << 'FILEEOF_surgical_journey_id_workspace_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import {
  getSurgicalCaseDetail, orderBiometryForCase, setPreOpPanelNotes,
  setProceedStatus, setIolOrderNotes, editSurgicalCaseDetails, setTreatmentInstructions,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, getPackagesForCase,
  setDecision, referForMedicalFitness, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
} from '@/app/(main)/counselling/actions';
import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];
const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

// ── HEADER (editable) ──────────────────────────────────────────────
function CaseHeader({ sc, patient, onAction }) {
  const [editing, setEditing] = useState(false);
  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState(sc.procedure_name);
  const [eye, setEye] = useState(sc.eye || 'OD');
  const [reason, setReason] = useState('');
  const [instructions, setInstructions] = useState(sc.treatment_instructions || '');
  const [savingInstructions, setSavingInstructions] = useState(false);
  const progressed = sc.status !== 'Pending Workup';

  useEffect(() => { if (editing) getSurgeries().then(setSurgeries); }, [editing]);

  function startEdit() {
    setProcedureName(sc.procedure_name); setEye(sc.eye || 'OD'); setReason(''); setEditing(true);
  }

  async function handleSaveInstructions() {
    setSavingInstructions(true);
    await onAction(setTreatmentInstructions)(sc.id, instructions);
    setSavingInstructions(false);
  }

  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--indigo)', color: '#fff' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, opacity: 0.85 }}>{patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile}</div>
        </div>
        {!editing ? (
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 700, fontSize: 14 }}>
              {sc.procedure_name}
              <button
                className="btn btn-sm" style={{ marginLeft: 8, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff', padding: '2px 8px' }}
                onClick={startEdit} title="Edit procedure/eye"
              >
                <i className="ti ti-pencil"></i>
              </button>
            </div>
            <div style={{ fontSize: 12, opacity: 0.85 }}>{EYE_LABEL[sc.eye] || sc.eye}</div>
          </div>
        ) : null}
      </div>

      {editing && (
        <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
              <option value={sc.procedure_name}>{sc.procedure_name}</option>
              {surgeries.filter((s) => s.name !== sc.procedure_name).map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
            </select>
            <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
              <option value="OD">Right (OD)</option>
              <option value="OS">Left (OS)</option>
              <option value="OU">Both (OU)</option>
            </select>
          </div>
          {progressed && (
            <input
              className="fi fi-sm" style={{ marginBottom: 8 }}
              placeholder={`Reason for changing (required -- case has already moved to "${sc.status}")`}
              value={reason} onChange={(e) => setReason(e.target.value)}
            />
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              className="btn btn-sm btn-primary"
              onClick={async () => {
                const r = await onAction(editSurgicalCaseDetails)(sc.id, procedureName, eye, reason);
                if (r?.error) return;
                setEditing(false);
              }}
            >
              Save
            </button>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={() => setEditing(false)}>Cancel</button>
          </div>
        </div>
      )}

      {/* Further instructions -- tied to the treatment itself (what's
          being done, which eye), not the pre-op investigations note. */}
      <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
        <div style={{ fontSize: 10, fontWeight: 700, opacity: 0.75, textTransform: 'uppercase', marginBottom: 6 }}>Further Instructions</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="fi fi-sm" style={{ flex: 1 }}
            placeholder="Anything else about this treatment worth noting..."
            value={instructions} onChange={(e) => setInstructions(e.target.value)}
          />
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={handleSaveInstructions} disabled={savingInstructions}>
            {savingInstructions ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ num, color, title, done, children, defaultOpen, active }) {
  const [open, setOpen] = useState(!!defaultOpen || !!active);
  return (
    <div
      className="card"
      style={{
        marginBottom: 12,
        border: active ? `2px solid ${color}` : '1px solid var(--g200)',
        background: active ? `color-mix(in srgb, ${color} 10%, white)` : '#fff',
        boxShadow: active ? `0 0 0 3px color-mix(in srgb, ${color} 20%, transparent)` : 'none',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }} onClick={() => setOpen((v) => !v)}>
        <div style={{ width: 24, height: 24, borderRadius: '50%', background: done ? 'var(--green)' : color, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
          {done ? <i className="ti ti-check"></i> : num}
        </div>
        <div style={{ fontWeight: 700, fontSize: 13, flex: 1 }}>
          {title}
          {active && <span className="badge" style={{ marginLeft: 8, background: color, color: '#fff', fontSize: 10 }}><i className="ti ti-arrow-right"></i> Next Step</span>}
        </div>
        <i className={`ti ${open ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ marginTop: 12, paddingLeft: 34 }}>{children}</div>}
    </div>
  );
}

export default function Workspace({ caseId }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getSurgicalCaseDetail(caseId);
    if (result.error) { setError(result.error); return; }
    setData(result);
  }, [caseId]);

  useEffect(() => { refresh(); }, [refresh]);

  function flash(fn) {
    return async (...args) => {
      setError(''); setOk('');
      const result = await fn(...args);
      if (result?.error) { setError(result.error); return result; }
      setOk('Saved.');
      await refresh();
      setTimeout(() => setOk(''), 2000);
      return result;
    };
  }

  if (error && !data) return <div className="msg-err">{error}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = data.case;
  const patient = sc.patients;

  // Drives the "Next Step" highlight -- the first not-yet-done stage in
  // the natural order gets the full-color treatment, everything else
  // stays normal. Reports and Notes aren't part of this sequence (they
  // don't have a natural "done" state -- reports trickle in whenever,
  // notes are an ongoing log), so they're excluded.
  const stepDone = {
    investigations: data.biometryRecords.length > 0,
    proceeding: sc.proceed_status === 'Proceeding',
    package: !!sc.package_id && sc.decision === 'Accepted',
    fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
    iolApproval: data.iolApproval?.status === 'Approved',
    iol: !!data.otSchedule,
    advance: !!sc.advance_payment_id,
    dayof: !!data.recoveryEpisode?.discharge_date,
  };
  const currentStep = Object.keys(stepDone).find((k) => !stepDone[k]) || null;

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/surgical-journey')}>
        <i className="ti ti-arrow-left"></i> All Cases
      </button>

      <CaseHeader sc={sc} patient={patient} onAction={flash} />

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      {/* 1. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} onAction={flash} active={currentStep === 'investigations'} />

      {/* 2. PROCEED STATUS */}
      <ProceedSection sc={sc} onAction={flash} active={currentStep === 'proceeding'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} onAction={flash} active={currentStep === 'package'} />

      {/* 4. MEDICAL FITNESS */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} />

      {/* 5. IOL APPROVAL -- separate module: surgeon's final brand/power
          sign-off, based on Biometry's device recommendations. */}
      <IolApprovalSection iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />

      {/* 6. IOL PROCUREMENT + DATE + BOOK */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} onAction={flash} active={currentStep === 'iol'} num={6} />

      {/* 7. ADVANCE */}
      <Section num={7} color="var(--teal)" title="Advance Payment" done={stepDone.advance} active={currentStep === 'advance'}>
        {sc.advance_payment_id ? (
          <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Advance collected.</div>
        ) : (
          <div>
            <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>Not yet collected.</div>
            <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => router.push(`/payments/advance?patientId=${patient.id}&returnTo=surgical-journey`)}>
              <i className="ti ti-cash"></i> Collect Advance
            </button>
          </div>
        )}
      </Section>

      {/* 8. REPORTS */}
      <Section num={8} color="var(--blue)" title="Reports (Biometry printout, blood work, etc.)" done={false}>
        <AttachmentUploader entityType="surgical_case" entityId={sc.id} title="" />
      </Section>

      {/* 9. DAY OF SURGERY */}
      <DayOfSurgerySection sc={sc} otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'dayof'} num={9} />

      {/* 10. NOTES / FOLLOW-UP */}
      <NotesSection caseId={sc.id} notes={data.caseNotes} onAction={flash} />
    </div>
  );
}

// ── FITNESS ─────────────────────────────────────────────────────────
// Kept as a real doctor referral/review (same as Counselling), not a
// self-certify checkbox -- clearing a patient for anaesthesia is a
// genuine clinical judgment, not paperwork. Deep-links to the Medical
// Fitness module for the actual review.
function FitnessSection({ sc, fitnessReferral, onAction, active }) {
  const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';
  return (
    <Section num={4} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>Refer to a doctor to review and clear for anaesthesia/surgery.</div>
          <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
            <i className="ti ti-heart-rate-monitor"></i> Refer to Doctor
          </button>
        </div>
      ) : fitnessReferral.status === 'Pending Review' ? (
        <span className="badge b-amber"><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}) -- <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Medical Fitness &rarr;</a></span>
      ) : fitnessReferral.status === 'Cleared' ? (
        <div>
          <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
        </div>
      ) : (
        <div>
          <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
          <div style={{ marginTop: 8 }}>
            <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
              <i className="ti ti-refresh"></i> Refer Again
            </button>
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. ──
function IolApprovalSection({ iolApproval, active }) {
  const approved = iolApproval?.status === 'Approved';
  return (
    <Section num={5} color="var(--indigo)" title="IOL Approval" done={approved} active={active}>
      {approved ? (
        <div style={{ fontSize: 12.5 }}>
          <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
          <div style={{ marginTop: 6 }}>
            {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
          </div>
        </div>
      ) : (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
            The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
          </div>
          <a href="/iol-approval" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
            <i className="ti ti-lens"></i> Open IOL Approval
          </a>
        </div>
      )}
    </Section>
  );
}

// ── 1. INVESTIGATIONS ──────────────────────────────────────────────
function InvestigationsSection({ sc, biometryRecords, onAction, active }) {
  const [instructions, setInstructions] = useState('');
  const [panelNotes, setPanelNotes] = useState(sc.notes || '');
  const biometryOrdered = biometryRecords.length > 0;

  return (
    <Section num={1} color="var(--purple)" title="Investigations (Biometry + Pre-Op Panel)" done={biometryOrdered} defaultOpen={!biometryOrdered} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Biometry (both eyes, for IOL power)</div>
        {biometryRecords.length > 0 ? (
          biometryRecords.map((b) => (
            <div key={b.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
              <span>{b.status}{b.verified_at ? ` -- ${new Date(b.verified_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}` : ''}</span>
              <a href="/biometry" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Biometry &rarr;</a>
            </div>
          ))
        ) : (
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Instructions (optional)" value={instructions} onChange={(e) => setInstructions(e.target.value)} />
            <button className="btn btn-sm btn-primary" onClick={() => onAction(orderBiometryForCase)(sc.id, instructions)}>
              <i className="ti ti-ruler-measure"></i> Order Biometry
            </button>
          </div>
        )}
      </div>

      <div>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Pre-Op Panel (blood work, done externally -- just note where, report comes in later)</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Sent to XYZ Lab for CBC/RBS/ECG"' value={panelNotes} onChange={(e) => setPanelNotes(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setPreOpPanelNotes)(sc.id, panelNotes)}>Save</button>
        </div>
      </div>
    </Section>
  );
}

// ── 2. PROCEED STATUS ──────────────────────────────────────────────
function ProceedSection({ sc, onAction, active }) {
  const OPTIONS = [
    { v: 'Deciding', label: 'Still deciding', color: 'var(--g500)' },
    { v: 'Awaiting Return', label: 'Will come back another day', color: 'var(--amber)' },
    { v: 'Proceeding', label: 'Proceeding now', color: 'var(--green)' },
  ];
  return (
    <Section num={2} color="var(--amber)" title="Is the patient proceeding?" done={sc.proceed_status === 'Proceeding'} active={active}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {OPTIONS.map((o) => (
          <button
            key={o.v}
            className="btn btn-sm"
            style={{ background: sc.proceed_status === o.v ? o.color : '', color: sc.proceed_status === o.v ? '#fff' : '', border: sc.proceed_status === o.v ? 'none' : undefined }}
            onClick={() => onAction(setProceedStatus)(sc.id, o.v)}
          >
            {o.label}
          </button>
        ))}
      </div>
    </Section>
  );
}

// ── 3. PACKAGE & IOL DECISION ──────────────────────────────────────
function PackageDecisionSection({ sc, onAction, active }) {
  const [packages, setPackages] = useState([]);
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [decisionReason, setDecisionReason] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changing, setChanging] = useState(false);
  const biometryReady = sc.biometry_done || sc.biometry_required === false;

  useEffect(() => {
    if (biometryReady) getPackagesForCase(sc.iol_category).then(setPackages);
  }, [biometryReady, sc.iol_category]);

  if (!biometryReady) {
    return (
      <Section num={3} color="var(--indigo)" title="Package &amp; IOL Decision" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Biometry approval first.</div>
      </Section>
    );
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package &amp; IOL Decision" done={!!sc.package_id && sc.decision === 'Accepted'} defaultOpen={biometryReady && !sc.package_id} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Package</div>
        {sc.master_packages ? (
          <div>
            <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: changing ? 8 : 0 }}>
              <span style={{ fontWeight: 600, fontSize: 12.5 }}>{sc.master_packages.name}</span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
                {!changing && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
              </div>
            </div>
            {changing && (
              <div>
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a new package...</option>
                    {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>)}
                  </select>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                  <button
                    className="btn btn-sm btn-primary"
                    disabled={!selectedPackageId || !changeReason.trim()}
                    onClick={async () => {
                      const r = await onAction(changePackage)(sc.id, changeReason);
                      if (r?.error) return;
                      await onAction(selectPackage)(sc.id, selectedPackageId);
                      setChanging(false); setChangeReason(''); setSelectedPackageId('');
                    }}
                  >
                    Confirm Change
                  </button>
                  <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); }}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        ) : (
          <div style={{ display: 'flex', gap: 8 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
              <option value="">Select a package...</option>
              {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>)}
            </select>
            <button className="btn btn-sm btn-primary" disabled={!selectedPackageId} onClick={() => onAction(selectPackage)(sc.id, selectedPackageId)}>Select</button>
          </div>
        )}
      </div>

      <div>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Patient Decision</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
          {DECISIONS.map((d) => (
            <button
              key={d} className="btn btn-sm"
              style={{ background: sc.decision === d ? 'var(--indigo)' : '', color: sc.decision === d ? '#fff' : '' }}
              onClick={() => onAction(setDecision)(sc.id, d, decisionReason)}
            >
              {d}
            </button>
          ))}
        </div>
        {sc.decision_locked && <input className="fi fi-sm" placeholder="Reason to change decision..." value={decisionReason} onChange={(e) => setDecisionReason(e.target.value)} />}
      </div>
    </Section>
  );
}

// ── 4. IOL PROCUREMENT + DATE + BOOK SLOT ──────────────────────────
function IolAndBookingSection({ sc, otSchedule, onAction, active, num }) {
  const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  const canBook = sc.status === 'Ready for Scheduling';
  const readyGateMet = sc.package_id && sc.decision === 'Accepted' && (sc.biometry_done || sc.biometry_required === false) && (sc.fitness_cleared || sc.fitness_required === false);

  const [rescheduling, setRescheduling] = useState(false);
  const [rescheduleReason, setRescheduleReason] = useState('');

  if (otSchedule) {
    return (
      <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done active={active}>
        <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>

        {!rescheduling ? (
          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><i className="ti ti-calendar-check"></i> Booked -- {new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}, {otSchedule.master_ot_sessions?.name} session</span>
            {otSchedule.status === 'Scheduled' && <button className="btn btn-sm" onClick={() => setRescheduling(true)}>Reschedule</button>}
          </div>
        ) : (
          <div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
              <input type="date" className="fi fi-sm" value={date} min={new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })} onChange={(e) => setDate(e.target.value)} />
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {loadingSessions ? <span style={{ fontSize: 12, color: 'var(--g400)' }}>Checking...</span> : sessions.map((s) => {
                  const full = s.remaining <= 0;
                  return (
                    <button key={s.session_id} disabled={full} className="btn btn-sm"
                      style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                      onClick={() => setSessionId(s.session_id)}>
                      {s.name} ({s.remaining} left)
                    </button>
                  );
                })}
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
              <button
                className="btn btn-sm btn-primary"
                disabled={!date || !sessionId || !rescheduleReason.trim()}
                onClick={async () => {
                  const r = await onAction(rescheduleOTSlot)(otSchedule.id, date, sessionId, rescheduleReason);
                  if (r?.error) return;
                  setRescheduling(false); setRescheduleReason(''); setDate(''); setSessionId('');
                }}
              >
                Confirm
              </button>
              <button className="btn btn-sm" onClick={() => setRescheduling(false)}>Cancel</button>
            </div>
          </div>
        )}
      </Section>
    );
  }

  return (
    <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done={false} defaultOpen={readyGateMet} active={active}>
      <div style={{ marginBottom: 12 }}>
        <label className="flbl">IOL Order Notes</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>
      </div>

      {!readyGateMet && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Package, decision, biometry, and fitness must all be settled before booking a date.
        </div>
      )}

      {readyGateMet && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 10 }}>
            <div>
              <label className="flbl">Date</label>
              <input type="date" className="fi fi-sm" value={date} min={new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })} onChange={(e) => setDate(e.target.value)} />
            </div>
            <div>
              <label className="flbl">Surgeon</label>
              <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                <option value="">--</option>
                {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </div>
          </div>
          {date && (
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Session</label>
              {loadingSessions ? (
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
              ) : (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {sessions.map((s) => {
                    const full = s.remaining <= 0;
                    return (
                      <button
                        key={s.session_id} disabled={full} className="btn btn-sm"
                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                        onClick={() => setSessionId(s.session_id)}
                      >
                        {s.name} ({s.remaining} left)
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          )}
          <button
            className="btn btn-primary btn-sm"
            disabled={!date || !sessionId}
            onClick={async () => {
              if (!canBook) {
                const r = await onAction(markReadyForScheduling)(sc.id);
                if (r?.error) return;
              }
              await onAction(bookOTSlot)(sc.id, date, sessionId, surgeonId || null, null);
            }}
          >
            <i className="ti ti-calendar-check"></i> Give This Date
          </button>
        </>
      )}
    </Section>
  );
}

// ── 7. DAY OF SURGERY (live status, deep-links only -- OT Intraop and
// Recovery remain their own solid clinical workflows) ──
function DayOfSurgerySection({ sc, otSchedule, recoveryEpisode, router, active, num }) {
  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;

  if (otSchedule) {
    if (otSchedule.status === 'Scheduled') {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
      color = 'var(--blue)';
      action = { label: 'Open in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'Completed') {
      if (recoveryEpisode && !recoveryEpisode.discharge_date) {
        status = 'Surgery done -- in Recovery';
        color = 'var(--teal)';
        action = { label: 'Open in Recovery', onClick: () => router.push('/ot-recovery') };
      } else if (recoveryEpisode?.discharge_date) {
        status = `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
        color = 'var(--green)';
        action = { label: 'Open in Post-Op', onClick: () => router.push('/ot-postop') };
      } else {
        status = 'Surgery completed';
        color = 'var(--green)';
      }
    }
  }

  return (
    <Section num={num} color={color} title="Day of Surgery" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!otSchedule} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, the surgery itself, and discharge all happen in the Operation Theatre / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── 8. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
function NotesSection({ caseId, notes, onAction }) {
  const [text, setText] = useState('');
  return (
    <Section num={10} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
        <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Add a note (e.g. follow-up call outcome)..." value={text} onChange={(e) => setText(e.target.value)} />
        <button
          className="btn btn-sm"
          onClick={async () => { if (!text.trim()) return; await onAction(addCaseNote)(caseId, text); setText(''); }}
        >
          Add
        </button>
      </div>
      {notes.map((n) => (
        <div key={n.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
          <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {n.profiles?.full_name || 'Staff'}:</span> {n.note}
        </div>
      ))}
      {notes.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No notes yet.</div>}
    </Section>
  );
}
FILEEOF_surgical_journey_id_workspace_js

cat > "schema.sql" << 'FILEEOF_schema_sql'



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";





SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "visit_id" "uuid",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "gross" numeric DEFAULT 0 NOT NULL,
    "gst" numeric DEFAULT 0 NOT NULL,
    "net" numeric DEFAULT 0 NOT NULL,
    "paid" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "cancelled_by" "uuid",
    "cancellation_reason" "text",
    "invoice_number" "text",
    "source" "text" DEFAULT 'visit'::"text" NOT NULL,
    "purpose" "text" DEFAULT 'Consultation'::"text" NOT NULL,
    CONSTRAINT "invoices_purpose_check" CHECK (("purpose" = ANY (ARRAY['Consultation'::"text", 'Investigation'::"text", 'Pharmacy'::"text", 'Surgery'::"text", 'Combined'::"text", 'Other'::"text"]))),
    CONSTRAINT "invoices_source_check" CHECK (("source" = ANY (ARRAY['visit'::"text", 'standalone'::"text", 'package'::"text"]))),
    CONSTRAINT "invoices_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Partial'::"text", 'Paid'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."invoices" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer DEFAULT 1) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  svc master_services;
begin
  select * into svc from master_services where code = p_service_code and status = 'Active';
  if svc is null then
    raise exception 'Service not found or inactive';
  end if;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (
    p_invoice_id, svc.code, svc.name, svc.dept, p_qty,
    svc.rate, svc.gst_pct, 0,
    svc.rate * p_qty, round(svc.rate * p_qty * svc.gst_pct / 100, 2),
    round(svc.rate * p_qty * (1 + svc.gst_pct / 100), 2)
  );

  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer DEFAULT 1, "p_disc_type" "text" DEFAULT 'none'::"text", "p_disc_value" numeric DEFAULT 0, "p_disc_reason" "text" DEFAULT NULL::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_name text;
  v_dept text;
  v_rate numeric;
  v_gst_pct numeric;
  v_gross numeric;
  v_disc numeric;
  v_taxable numeric;
  v_gst numeric;
  v_net numeric;
  v_found boolean;
  v_is_package boolean := false;
  v_package_id uuid;
  v_patient_id uuid;
begin
  select name, dept, rate, gst_pct into v_name, v_dept, v_rate, v_gst_pct
  from master_services where code = p_service_code and status = 'Active';
  v_found := found;

  if not v_found then
    select (generic || ' ' || coalesce(strength, '')), 'Pharmacy'::text, coalesce(rate, 0), coalesce(gst_pct, 0)
    into v_name, v_dept, v_rate, v_gst_pct
    from master_drugs where code = p_service_code and status = 'Active';
    v_found := found;
  end if;

  -- Packages live in their own master table (master_packages), not
  -- master_services -- without this branch, package billing (from
  -- Counselling's locked package or the Front Office widget) would
  -- fail with "Service not found" the moment it tried to bill.
  if not v_found then
    select id, name, 'Surgery'::text, price, 0::numeric
    into v_package_id, v_name, v_dept, v_rate, v_gst_pct
    from master_packages where code = p_service_code and status = 'Active';
    v_found := found;
    v_is_package := found;
  end if;

  if not v_found then
    raise exception 'Service not found or inactive';
  end if;

  if p_disc_type <> 'none' and (p_disc_reason is null or trim(p_disc_reason) = '') then
    raise exception 'A discount reason is required whenever a discount is applied.';
  end if;

  v_gross := v_rate * p_qty;

  if p_disc_type = 'pct' then
    v_disc := round(v_gross * p_disc_value / 100, 2);
  elsif p_disc_type = 'fixed' then
    v_disc := least(p_disc_value, v_gross);
  else
    v_disc := 0;
  end if;

  v_taxable := v_gross - v_disc;
  v_gst := round(v_taxable * v_gst_pct / 100, 2);
  v_net := v_taxable + v_gst;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (p_invoice_id, p_service_code, v_name, v_dept, p_qty, v_rate, v_gst_pct, v_disc, v_gross, v_gst, v_net);

  -- Mark the matching surgical case's package as billed regardless of
  -- how the line item got added (Front Office widget prefill, or a
  -- department picked manually) -- previously only the prefill path
  -- did this, so a manually-added package invoice left the case
  -- looking permanently unbilled even after it was fully paid.
  if v_is_package then
    select patient_id into v_patient_id from invoices where id = p_invoice_id;
    if v_patient_id is not null then
      update surgical_cases
      set package_billed = true
      where package_id = v_package_id
        and patient_id = v_patient_id
        and package_locked = true
        and package_billed = false;
    end if;
  end if;

  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_balance numeric;
  v_outstanding numeric;
  v_receipt_number text;
  new_payment payments;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before adjustments can be made.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Adjustment amount must be greater than zero.';
  end if;

  v_balance := get_advance_balance(p_patient_id);
  if p_amount > v_balance then
    raise exception 'Adjustment amount (Rs.%) exceeds available advance balance (Rs.%).', p_amount, v_balance;
  end if;

  select net - paid into v_outstanding from invoices where id = p_invoice_id;
  if v_outstanding is null then
    raise exception 'Invoice not found';
  end if;
  if p_amount > v_outstanding then
    raise exception 'Adjustment amount (Rs.%) exceeds this invoice''s outstanding balance (Rs.%).', p_amount, v_outstanding;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_receipt_number, p_patient_id, p_amount, 'Advance adjusted against invoice', auth.uid(), 'advance_adjustment')
  returning * into new_payment;

  insert into payment_allocations (payment_id, invoice_id, amount)
  values (new_payment.id, p_invoice_id, p_amount);

  -- New, linked debit entry -- the original "Advance Collected" entry
  -- is never touched, per Section 22.11.
  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_payment.id, 'Advance Adjusted', -p_amount, 'Applied against invoice', auth.uid());

  update invoices set paid = paid + p_amount where id = p_invoice_id;
  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_session record;
  v_case record;
  v_booked_count int;
  v_ot_id uuid;
begin
  select * into v_session from master_ot_sessions where id = p_session_id and status = 'Active' for update;
  if not found then
    return jsonb_build_object('error', 'Selected OT session not found or inactive.');
  end if;

  select * into v_case from surgical_cases where id = p_case_id for update;
  if not found then
    return jsonb_build_object('error', 'Surgical case not found.');
  end if;
  if v_case.status <> 'Ready for Scheduling' then
    return jsonb_build_object('error', 'Case is not Ready for Scheduling.');
  end if;

  if p_date < current_date then
    return jsonb_build_object('error', 'Cannot book a date in the past.');
  end if;

  select count(*) into v_booked_count
  from ot_schedule
  where scheduled_date = p_date and session_id = p_session_id and status <> 'Cancelled';

  if v_booked_count >= v_session.capacity then
    return jsonb_build_object(
      'error',
      format('%s session on %s is full (%s/%s booked). Choose another date or session.',
        v_session.name, to_char(p_date, 'DD Mon YYYY'), v_booked_count, v_session.capacity)
    );
  end if;

  insert into ot_schedule (surgical_case_id, surgeon_id, scheduled_date, scheduled_time, session_id, room, notes)
  values (p_case_id, p_surgeon_id, p_date, v_session.start_time, p_session_id, v_session.default_room, nullif(p_notes, ''))
  returning id into v_ot_id;

  update surgical_cases set status = 'Scheduled' where id = p_case_id;

  return jsonb_build_object('success', true, 'ot_schedule_id', v_ot_id);
end;
$$;


ALTER FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  inv invoices;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A cancellation reason is required.';
  end if;

  select * into inv from invoices where id = p_invoice_id;
  if inv is null then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'Cancelled' then
    raise exception 'This invoice is already cancelled.';
  end if;
  if inv.paid > 0 then
    raise exception 'Cannot cancel an invoice that already has payments recorded against it. Contact an administrator.';
  end if;

  update invoices
  set status = 'Cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
  where id = p_invoice_id
  returning * into inv;

  insert into invoice_modifications (invoice_id, modified_by, action, reason)
  values (p_invoice_id, auth.uid(), 'cancelled', p_reason);

  return inv;
end;
$$;


ALTER FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "appointment_id" "uuid",
    "doctor_id" "uuid",
    "visit_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "status" "text" DEFAULT 'Open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "referral_source" "text",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "visit_number" "text",
    "cancellation_reason" "text",
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "surgery_type" "text",
    CONSTRAINT "visits_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text", 'Emergency'::"text"]))),
    CONSTRAINT "visits_status_check" CHECK (("status" = ANY (ARRAY['Open'::"text", 'Closed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."visits" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  appt appointments;
  new_visit visits;
  existing_visit_count int;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before new visits can be created.';
  end if;

  select * into appt from appointments where id = p_appointment_id;

  if appt is null then
    raise exception 'Appointment not found';
  end if;

  if appt.patient_id is null then
    raise exception 'This appointment has no registered patient yet -- register the patient first, then check in.';
  end if;

  select count(*) into existing_visit_count
  from visits
  where patient_id = appt.patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, appointment_id, doctor_id, visit_type, referral_source, status, visit_number)
  values (appt.patient_id, appt.id, appt.doctor_id, appt.visit_type, 'Appointment', 'Open', next_visit_number())
  returning * into new_visit;

  update appointments set status = 'Checked-in' where id = p_appointment_id;

  if new_visit.visit_type = 'Surgery' then
    update ot_schedule os
    set patient_reported_at = now()
    from surgical_cases sc
    where os.surgical_case_id = sc.id
      and sc.patient_id = new_visit.patient_id
      and os.scheduled_date = ist_date(now())
      and os.status in ('Scheduled', 'In Progress');
  elsif new_visit.visit_type = 'Post-operative Review' then
    perform issue_queue_token(new_visit.id, 'Doctor');
  else
    perform issue_queue_token(new_visit.id, 'Optometry');
  end if;

  return new_visit;
end;
$$;


ALTER FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_closings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "closed_by" "uuid",
    "closed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_revenue" numeric NOT NULL,
    "total_collected" numeric NOT NULL,
    "total_outstanding" numeric NOT NULL,
    "total_invoices" integer NOT NULL,
    "total_visits" integer NOT NULL,
    "notes" "text"
);


ALTER TABLE "public"."day_closings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."close_day"("p_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."day_closings"
    LANGUAGE "plpgsql"
    AS $$
declare
  closing day_closings;
  v_revenue numeric;
  v_collected numeric;
  v_outstanding numeric;
  v_invoice_count int;
  v_visit_count int;
  v_date date;
  v_modes_expected int;
  v_modes_reconciled int;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if is_day_closed(v_date) then
    raise exception 'This day has already been closed.';
  end if;

  select count(distinct pm.mode) into v_modes_expected
  from payment_modes pm join payments p on p.id = pm.payment_id
  where ist_date(p.collected_at) = v_date;

  select count(*) into v_modes_reconciled from day_reconciliation where closing_date = v_date;

  if v_modes_expected > 0 and v_modes_reconciled < v_modes_expected then
    raise exception 'Reconciliation is incomplete for %s -- % of % payment modes reconciled. Complete reconciliation before closing.', v_date, v_modes_reconciled, v_modes_expected;
  end if;

  select coalesce(sum(net),0), coalesce(sum(paid),0), coalesce(sum(net - paid),0), count(*)
  into v_revenue, v_collected, v_outstanding, v_invoice_count
  from invoices where ist_date(created_at) = v_date;

  select count(*) into v_visit_count from visits where ist_date(created_at) = v_date;

  insert into day_closings (closing_date, closed_by, total_revenue, total_collected, total_outstanding, total_invoices, total_visits, notes)
  values (v_date, auth.uid(), v_revenue, v_collected, v_outstanding, v_invoice_count, v_visit_count, p_notes)
  returning * into closing;

  return closing;
end;
$$;


ALTER FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_number" "text" NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "total_amount" numeric NOT NULL,
    "reference" "text",
    "remarks" "text",
    "collected_by" "uuid",
    "collected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_type" "text" DEFAULT 'invoice_payment'::"text" NOT NULL,
    "advance_type" "text",
    CONSTRAINT "payments_payment_type_check" CHECK (("payment_type" = ANY (ARRAY['invoice_payment'::"text", 'advance'::"text", 'advance_adjustment'::"text", 'credit_note'::"text", 'refund'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_payment payments;
  v_receipt_number text;
  v_mode jsonb;
  v_modes_sum numeric := 0;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before advances can be collected.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_modes_sum := v_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_modes_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment mode split (Rs.%) must add up to the amount (Rs.%).', v_modes_sum, p_amount;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, reference, remarks, collected_by, payment_type, advance_type)
  values (v_receipt_number, p_patient_id, p_amount, p_reference, p_remarks, auth.uid(), 'advance', p_advance_type)
  returning * into new_payment;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount)
    values (new_payment.id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_payment.id, 'Advance Collected', p_amount, p_advance_type, auth.uid());

  return new_payment;
end;
$$;


ALTER FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_payment payments;
  v_receipt_number text;
  v_remaining numeric;
  v_invoice_id uuid;
  v_outstanding numeric;
  v_allocate numeric;
  v_mode jsonb;
  v_modes_sum numeric := 0;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before payments can be collected.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount collecting must be greater than zero.';
  end if;

  if p_invoice_ids is null or array_length(p_invoice_ids, 1) is null then
    raise exception 'Select at least one invoice to pay.';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_modes_sum := v_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_modes_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment mode split (Rs.%) must add up to the amount collecting (Rs.%).', v_modes_sum, p_amount;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, reference, remarks, collected_by)
  values (v_receipt_number, p_patient_id, p_amount, p_reference, p_remarks, auth.uid())
  returning * into new_payment;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount)
    values (new_payment.id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  v_remaining := p_amount;
  foreach v_invoice_id in array p_invoice_ids
  loop
    exit when v_remaining <= 0;

    select net - paid into v_outstanding from invoices where id = v_invoice_id;
    if v_outstanding is null or v_outstanding <= 0 then
      continue;
    end if;

    v_allocate := least(v_remaining, v_outstanding);

    insert into payment_allocations (payment_id, invoice_id, amount)
    values (new_payment.id, v_invoice_id, v_allocate);

    update invoices set paid = paid + v_allocate where id = v_invoice_id;
    perform recompute_invoice_totals(v_invoice_id);

    v_remaining := v_remaining - v_allocate;
  end loop;

  -- Anything left over after fully paying off every selected invoice
  -- becomes advance credit, same as collecting advance directly.
  if v_remaining > 0 then
    insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
    values (
      p_patient_id, new_payment.id, 'Advance Collected', v_remaining,
      'Overpayment from Receipt ' || v_receipt_number, auth.uid()
    );
  end if;

  return new_payment;
end;
$$;


ALTER FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "credit_note_number" "text" NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "payment_id" "uuid",
    "amount" numeric NOT NULL,
    "reason" "text" NOT NULL,
    "approved_by" "uuid",
    "remarks" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."credit_notes" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."credit_notes"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_outstanding numeric;
  v_cn_number text;
  new_payment payments;
  new_cn credit_notes;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before credit notes can be issued.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Credit amount must be greater than zero.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required for a credit note.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a credit note.';
  end if;

  select net - paid into v_outstanding from invoices where id = p_invoice_id;
  if v_outstanding is null then
    raise exception 'Invoice not found';
  end if;
  if p_amount > v_outstanding then
    raise exception 'Credit amount (Rs.%) exceeds this invoice''s outstanding balance (Rs.%).', p_amount, v_outstanding;
  end if;

  v_cn_number := next_credit_note_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_cn_number, p_patient_id, p_amount, 'Credit note: ' || p_reason, auth.uid(), 'credit_note')
  returning * into new_payment;

  insert into payment_allocations (payment_id, invoice_id, amount)
  values (new_payment.id, p_invoice_id, p_amount);

  update invoices set paid = paid + p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  insert into credit_notes (credit_note_number, patient_id, invoice_id, payment_id, amount, reason, approved_by, remarks, created_by)
  values (v_cn_number, p_patient_id, p_invoice_id, new_payment.id, p_amount, p_reason, p_approved_by, p_remarks, auth.uid())
  returning * into new_cn;

  return new_cn;
end;
$$;


ALTER FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid" DEFAULT NULL::"uuid", "p_purpose" "text" DEFAULT 'Consultation'::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  inv invoices;
begin
  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source, purpose)
  values (
    p_patient_id, p_visit_id, 'Pending', 0, 0, 0, 0, next_invoice_number(),
    case when p_visit_id is null then 'standalone' else 'visit' end,
    coalesce(p_purpose, 'Consultation')
  )
  returning * into inv;

  return inv;
end;
$$;


ALTER FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text" DEFAULT NULL::"text", "p_priority" "text" DEFAULT 'Routine'::"text", "p_surgery_type" "text" DEFAULT NULL::"text") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_visit visits;
  existing_visit_count int;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before new visits can be created.';
  end if;

  select count(*) into existing_visit_count
  from visits
  where patient_id = p_patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, doctor_id, visit_type, referral_source, priority, surgery_type, status, visit_number)
  values (p_patient_id, p_doctor_id, p_visit_type, p_referral_source, coalesce(p_priority, 'Routine'), p_surgery_type, 'Open', next_visit_number())
  returning * into new_visit;

  if new_visit.visit_type = 'Surgery' then
    update ot_schedule os
    set patient_reported_at = now()
    from surgical_cases sc
    where os.surgical_case_id = sc.id
      and sc.patient_id = new_visit.patient_id
      and os.scheduled_date = ist_date(now())
      and os.status in ('Scheduled', 'In Progress');
  else
    -- Post-operative Review patients now route through Optometry too --
    -- refraction and other clinical recording may be needed post-surgery
    -- just like a normal visit. The doctor still keeps the existing
    -- "Call Directly" override (Doctor Dashboard / Post-op module) to
    -- pull them straight in without waiting on Optometry.
    perform issue_queue_token(new_visit.id, 'Optometry');
  end if;

  return new_visit;
end;
$$;


ALTER FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prescriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "drug_name" "text" NOT NULL,
    "dosage" "text",
    "frequency" "text",
    "duration" "text",
    "eye" "text",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    CONSTRAINT "prescriptions_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "prescriptions_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Sent'::"text", 'Dispensed'::"text"])))
);


ALTER TABLE "public"."prescriptions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."prescriptions"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



CREATE OR REPLACE FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") RETURNS "public"."prescriptions"
    LANGUAGE "plpgsql"
    AS $$
declare
  rx prescriptions;
  v_visit_id uuid;
  inv invoices;
  matched master_drugs;
begin
  select * into rx from prescriptions where id = p_prescription_id;
  if rx is null then
    raise exception 'Prescription not found';
  end if;

  update prescriptions set status = 'Dispensed' where id = p_prescription_id returning * into rx;

  if rx.billing_status = 'Billed' then
    return rx;
  end if;

  select visit_id into v_visit_id from encounters where id = rx.encounter_id;

  inv := get_or_create_invoice_for_visit(v_visit_id);

  select * into matched from master_drugs
  where status = 'Active'
    and (rx.drug_name ilike '%' || generic || '%' or rx.drug_name ilike '%' || brand || '%')
  limit 1;

  if matched is not null then
    insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
    values (
      inv.id, matched.code, rx.drug_name, 'Pharmacy', 1,
      matched.rate, matched.gst_pct, 0,
      matched.rate, round(matched.rate * matched.gst_pct / 100, 2),
      round(matched.rate * (1 + matched.gst_pct / 100), 2)
    );
    perform recompute_invoice_totals(inv.id);
    update prescriptions set billing_status = 'Billed', billing_updated_at = now()
      where id = p_prescription_id returning * into rx;
  end if;

  return rx;
end;
$$;


ALTER FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  pay payments;
  v_old_modes jsonb;
  v_new_modes_sum numeric := 0;
  v_mode jsonb;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to edit a payment.';
  end if;

  select * into pay from payments where id = p_payment_id;
  if pay is null then
    raise exception 'Payment not found';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_new_modes_sum := v_new_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_new_modes_sum, 2) <> round(pay.total_amount, 2) then
    raise exception 'Mode split (Rs.%) must still add up to the original amount collected (Rs.%). To change the amount itself, use Refund or Credit Note instead.', v_new_modes_sum, pay.total_amount;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('mode', mode, 'amount', amount)), '[]'::jsonb)
  into v_old_modes
  from payment_modes where payment_id = p_payment_id;

  insert into payment_edits (payment_id, old_reference, new_reference, old_remarks, new_remarks, old_modes, new_modes, reason, edited_by)
  values (p_payment_id, pay.reference, p_reference, pay.remarks, p_remarks, v_old_modes, p_modes, p_reason, auth.uid());

  delete from payment_modes where payment_id = p_payment_id;
  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount) values (p_payment_id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  update payments set reference = p_reference, remarks = p_remarks where id = p_payment_id returning * into pay;

  return pay;
end;
$$;


ALTER FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric DEFAULT 0) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  pkg master_packages;
  inv invoices;
  v_paid numeric;
begin
  select * into pkg from master_packages where id = p_package_id and status = 'Active';
  if pkg is null then
    raise exception 'Package not found or inactive';
  end if;

  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source)
  values (p_patient_id, p_visit_id, 'Pending', pkg.price, 0, pkg.price, 0, next_invoice_number(), 'package')
  returning * into inv;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (inv.id, pkg.code, pkg.name, 'Surgery', 1, pkg.price, 0, 0, pkg.price, 0, pkg.price);

  if p_payment_mode = 'full' then
    v_paid := pkg.price;
  else
    if p_advance_amount is null or p_advance_amount <= 0 or p_advance_amount > pkg.price then
      raise exception 'Advance amount must be greater than zero and not exceed the package price.';
    end if;
    v_paid := p_advance_amount;
  end if;

  update invoices set paid = v_paid where id = inv.id;

  return recompute_invoice_totals(inv.id);
end;
$$;


ALTER FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric DEFAULT 0, "p_surgical_case_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  pkg master_packages;
  inv invoices;
  v_paid numeric;
begin
  select * into pkg from master_packages where id = p_package_id and status = 'Active';
  if pkg is null then
    raise exception 'Package not found or inactive';
  end if;

  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source)
  values (p_patient_id, p_visit_id, 'Pending', pkg.price, 0, pkg.price, 0, next_invoice_number(), 'package')
  returning * into inv;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (inv.id, pkg.code, pkg.name, 'Surgery', 1, pkg.price, 0, 0, pkg.price, 0, pkg.price);

  if p_payment_mode = 'full' then
    v_paid := pkg.price;
  else
    if p_advance_amount is null or p_advance_amount <= 0 or p_advance_amount > pkg.price then
      raise exception 'Advance amount must be greater than zero and not exceed the package price.';
    end if;
    v_paid := p_advance_amount;
  end if;

  update invoices set paid = v_paid where id = inv.id;

  if p_surgical_case_id is not null then
    update surgical_cases set package_billed = true where id = p_surgical_case_id;
  end if;

  return recompute_invoice_totals(inv.id);
end;
$$;


ALTER FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce(sum(amount), 0) from patient_ledger where patient_id = p_patient_id;
$$;


ALTER FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  existing visits;
  new_visit visits;
begin
  select * into existing from visits
  where patient_id = p_patient_id and ist_date(created_at) = ist_date(now())
  order by created_at desc
  limit 1;

  if found then
    return existing;
  end if;

  new_visit := create_walk_in_visit(p_patient_id, p_doctor_id, 'Post-operative Review', null, 'Routine', null);
  return new_visit;
end;
$$;


ALTER FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_ot_availability"("p_date" "date") RETURNS TABLE("session_id" "uuid", "name" "text", "start_time" time without time zone, "end_time" time without time zone, "default_room" "text", "capacity" integer, "booked" integer, "remaining" integer)
    LANGUAGE "sql" STABLE
    AS $$
  select
    s.id, s.name, s.start_time, s.end_time, s.default_room, s.capacity,
    coalesce(b.cnt, 0)::int as booked,
    (s.capacity - coalesce(b.cnt, 0))::int as remaining
  from master_ot_sessions s
  left join (
    select session_id, count(*) as cnt
    from ot_schedule
    where scheduled_date = p_date and status <> 'Cancelled'
    group by session_id
  ) b on b.session_id = s.id
  where s.status = 'Active'
  order by s.display_order;
$$;


ALTER FUNCTION "public"."get_ot_availability"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into public.profiles (id, full_name, designation, department)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce(new.raw_user_meta_data->>'designation', 'Staff'),
    coalesce(new.raw_user_meta_data->>'department', '')
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_day_closed"("p_date" "date") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select exists (select 1 from day_closings where closing_date = p_date);
$$;


ALTER FUNCTION "public"."is_day_closed"("p_date" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."queue_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "department" "text" NOT NULL,
    "token" "text" NOT NULL,
    "status" "text" DEFAULT 'Waiting'::"text" NOT NULL,
    "issued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "called_at" timestamp with time zone,
    "sent_out_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    CONSTRAINT "queue_entries_department_check" CHECK (("department" = ANY (ARRAY['Optometry'::"text", 'Doctor'::"text"]))),
    CONSTRAINT "queue_entries_status_check" CHECK (("status" = ANY (ARRAY['Waiting'::"text", 'Calling'::"text", 'In Consultation'::"text", 'Awaiting Dilation'::"text", 'Awaiting Investigation'::"text", 'Awaiting Biometry'::"text", 'Awaiting Dilation & Investigation'::"text", 'Awaiting Dilation & Biometry'::"text", 'Awaiting Investigation & Biometry'::"text", 'Awaiting Dilation & Investigation & Biometry'::"text", 'Ready for Review'::"text", 'Done'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."queue_entries" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  today_count int;
  new_token text;
  prefix text;
  new_entry queue_entries;
begin
  prefix := case p_department when 'Optometry' then 'O' when 'Doctor' then 'D' else 'X' end;

  select count(*) into today_count
  from queue_entries
  where department = p_department
    and ist_date(issued_at) = ist_date(now());

  new_token := prefix || '-' || lpad((today_count + 1)::text, 2, '0');

  insert into queue_entries (visit_id, department, token, status)
  values (p_visit_id, p_department, new_token, 'Waiting')
  returning * into new_entry;

  return new_entry;
end;
$$;


ALTER FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ist_date"("ts" timestamp with time zone) RETURNS "date"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select (ts at time zone 'Asia/Kolkata')::date;
$$;


ALTER FUNCTION "public"."ist_date"("ts" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_credit_note_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'CN' || yr || '-' || lpad(nextval('credit_note_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_credit_note_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_invoice_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'INV' || yr || '-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_invoice_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_package_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
begin
  return 'PKG' || lpad(nextval('package_code_seq')::text, 3, '0');
end;
$$;


ALTER FUNCTION "public"."next_package_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_refund_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'REF' || yr || '-' || lpad(nextval('refund_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_refund_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_visit_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'V' || yr || '-' || lpad(nextval('visit_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_visit_number"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_openings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "opening_date" "date" NOT NULL,
    "opened_by" "uuid",
    "opened_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "opening_cash_balance" numeric DEFAULT 0 NOT NULL,
    "remarks" "text"
);


ALTER TABLE "public"."day_openings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."open_day"("p_date" "date" DEFAULT NULL::"date", "p_opening_balance" numeric DEFAULT 0, "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."day_openings"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_date date;
  row day_openings;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if exists (select 1 from day_openings where opening_date = v_date) then
    raise exception 'Today has already been opened.';
  end if;

  insert into day_openings (opening_date, opened_by, opening_cash_balance, remarks)
  values (v_date, auth.uid(), p_opening_balance, p_remarks)
  returning * into row;

  return row;
end;
$$;


ALTER FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  entry queue_entries;
begin
  update queue_entries set status = 'Done', completed_at = now()
  where id = p_queue_entry_id and department = 'Optometry'
  returning * into entry;

  if entry is null then
    raise exception 'Queue entry not found';
  end if;

  perform issue_queue_token(entry.visit_id, 'Doctor');

  return entry;
end;
$$;


ALTER FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  totals record;
  inv invoices;
begin
  select coalesce(sum(gross),0) as gross, coalesce(sum(gst_amount),0) as gst, coalesce(sum(net),0) as net
  into totals
  from invoice_line_items where invoice_id = p_invoice_id;

  select * into inv from invoices where id = p_invoice_id;

  update invoices
  set gross = totals.gross,
      gst = totals.gst,
      net = totals.net,
      status = case
        when totals.net <= 0 then 'Paid'
        when inv.paid <= 0 then 'Pending'
        when inv.paid >= totals.net then 'Paid'
        else 'Partial'
      end
  where id = p_invoice_id
  returning * into inv;

  return inv;
end;
$$;


ALTER FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update master_packages
  set price = coalesce((select sum(amount) from package_line_items where package_id = p_package_id), 0)
  where id = p_package_id;
end;
$$;


ALTER FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_refunds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid",
    "invoice_id" "uuid",
    "amount" numeric NOT NULL,
    "reason" "text" NOT NULL,
    "refunded_by" "uuid",
    "refunded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "refund_mode" "text",
    "approved_by" "uuid",
    "refund_payment_id" "uuid",
    "patient_id" "uuid"
);


ALTER TABLE "public"."payment_refunds" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_balance numeric;
  v_refund_number text;
  new_refund_payment payments;
  new_refund payment_refunds;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a refund.';
  end if;

  v_balance := get_advance_balance(p_patient_id);
  if p_amount > v_balance then
    raise exception 'Refund amount (Rs.%) exceeds available advance balance (Rs.%).', p_amount, v_balance;
  end if;

  v_refund_number := next_refund_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_refund_number, p_patient_id, p_amount, 'Refund from advance: ' || p_reason, auth.uid(), 'refund')
  returning * into new_refund_payment;

  if p_refund_mode is not null then
    insert into payment_modes (payment_id, mode, amount) values (new_refund_payment.id, p_refund_mode, p_amount);
  end if;

  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_refund_payment.id, 'Advance Refunded', -p_amount, p_reason, auth.uid());

  insert into payment_refunds (payment_id, invoice_id, patient_id, amount, reason, refunded_by, refund_mode, approved_by, refund_payment_id)
  values (null, null, p_patient_id, p_amount, p_reason, auth.uid(), p_refund_mode, p_approved_by, new_refund_payment.id)
  returning * into new_refund;

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_allocated numeric;
  v_already_refunded numeric;
  v_refundable numeric;
  new_refund payment_refunds;
  v_patient_id uuid;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  select amount into v_allocated from payment_allocations where payment_id = p_payment_id and invoice_id = p_invoice_id;
  if v_allocated is null then
    raise exception 'This payment was not applied to that invoice.';
  end if;

  select coalesce(sum(amount), 0) into v_already_refunded
  from payment_refunds where payment_id = p_payment_id and invoice_id = p_invoice_id;

  v_refundable := v_allocated - v_already_refunded;
  if p_amount > v_refundable then
    raise exception 'Refund amount (Rs.%) exceeds what remains refundable for this invoice (Rs.%).', p_amount, v_refundable;
  end if;

  insert into payment_refunds (payment_id, invoice_id, amount, reason, refunded_by)
  values (p_payment_id, p_invoice_id, p_amount, p_reason, auth.uid())
  returning * into new_refund;

  update invoices set paid = paid - p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_allocated numeric;
  v_already_refunded numeric;
  v_refundable numeric;
  v_patient_id uuid;
  v_invoice_number text;
  v_refund_number text;
  new_refund payment_refunds;
  new_refund_payment payments;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a refund.';
  end if;

  select amount into v_allocated from payment_allocations where payment_id = p_payment_id and invoice_id = p_invoice_id;
  if v_allocated is null then
    raise exception 'This payment was not applied to that invoice.';
  end if;

  select coalesce(sum(amount), 0) into v_already_refunded
  from payment_refunds where payment_id = p_payment_id and invoice_id = p_invoice_id;

  v_refundable := v_allocated - v_already_refunded;
  if p_amount > v_refundable then
    raise exception 'Refund amount (Rs.%) exceeds what remains refundable for this invoice (Rs.%).', p_amount, v_refundable;
  end if;

  select patient_id into v_patient_id from payments where id = p_payment_id;
  select invoice_number into v_invoice_number from invoices where id = p_invoice_id;
  v_refund_number := next_refund_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_refund_number, v_patient_id, p_amount, 'Refund against ' || coalesce(v_invoice_number, 'invoice') || ': ' || p_reason, auth.uid(), 'refund')
  returning * into new_refund_payment;

  if p_refund_mode is not null then
    insert into payment_modes (payment_id, mode, amount) values (new_refund_payment.id, p_refund_mode, p_amount);
  end if;

  insert into payment_refunds (payment_id, invoice_id, patient_id, amount, reason, refunded_by, refund_mode, approved_by, refund_payment_id)
  values (p_payment_id, p_invoice_id, v_patient_id, p_amount, p_reason, auth.uid(), p_refund_mode, p_approved_by, new_refund_payment.id)
  returning * into new_refund;

  update invoices set paid = paid - p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "uhid" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "age" integer,
    "gender" "text",
    "mobile" "text" NOT NULL,
    "address" "text",
    "blood_group" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "date_of_birth" "date",
    "alternate_mobile" "text",
    "city" "text",
    "state" "text",
    "pin_code" "text",
    "id_type" "text",
    "id_number" "text",
    "insurance_scheme" "text",
    "insurance_number" "text",
    "referral_source" "text",
    "preferred_language" "text",
    "remarks" "text",
    CONSTRAINT "mobile_ten_digits" CHECK (("mobile" ~ '^[0-9]{10}$'::"text")),
    CONSTRAINT "patients_gender_check" CHECK (("gender" = ANY (ARRAY['M'::"text", 'F'::"text", 'O'::"text"])))
);


ALTER TABLE "public"."patients" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") RETURNS "public"."patients"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_uhid text;
  new_patient patients;
begin
  new_uhid := 'VEH-' || lpad(nextval('patient_uhid_seq')::text, 5, '0');

  insert into patients (uhid, first_name, last_name, age, gender, mobile, address, blood_group)
  values (new_uhid, p_first_name, p_last_name, p_age, p_gender, p_mobile, p_address, p_blood_group)
  returning * into new_patient;

  return new_patient;
end;
$$;


ALTER FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date" DEFAULT NULL::"date", "p_alternate_mobile" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_pin_code" "text" DEFAULT NULL::"text", "p_id_type" "text" DEFAULT NULL::"text", "p_id_number" "text" DEFAULT NULL::"text", "p_insurance_scheme" "text" DEFAULT NULL::"text", "p_insurance_number" "text" DEFAULT NULL::"text", "p_referral_source" "text" DEFAULT NULL::"text", "p_preferred_language" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."patients"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_uhid text;
  new_patient patients;
begin
  new_uhid := 'VEH-' || lpad(nextval('patient_uhid_seq')::text, 5, '0');

  insert into patients (
    uhid, first_name, last_name, age, gender, mobile, address, blood_group,
    date_of_birth, alternate_mobile, city, state, pin_code,
    id_type, id_number, insurance_scheme, insurance_number,
    referral_source, preferred_language, remarks
  )
  values (
    new_uhid, initcap(trim(p_first_name)), initcap(trim(p_last_name)), p_age, p_gender, p_mobile, p_address, p_blood_group,
    p_date_of_birth, p_alternate_mobile, initcap(trim(p_city)), p_state, p_pin_code,
    p_id_type, p_id_number, p_insurance_scheme, p_insurance_number,
    p_referral_source, p_preferred_language, p_remarks
  )
  returning * into new_patient;

  return new_patient;
end;
$$;


ALTER FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_invoice_id uuid;
begin
  select invoice_id into v_invoice_id from invoice_line_items where id = p_line_item_id;
  delete from invoice_line_items where id = p_line_item_id;
  return recompute_invoice_totals(v_invoice_id);
end;
$$;


ALTER FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_invoice_id uuid;
  v_service_name text;
begin
  select invoice_id, service_name into v_invoice_id, v_service_name
  from invoice_line_items where id = p_line_item_id;

  if v_invoice_id is null then
    raise exception 'Line item not found';
  end if;

  if p_reason is not null and trim(p_reason) <> '' then
    insert into invoice_modifications (invoice_id, modified_by, action, reason, details)
    values (v_invoice_id, auth.uid(), 'line_item_removed', p_reason, v_service_name);
  end if;

  delete from invoice_line_items where id = p_line_item_id;
  return recompute_invoice_totals(v_invoice_id);
end;
$$;


ALTER FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to reopen a closed day.';
  end if;

  insert into day_closing_reopens (closing_date, reason, reopened_by)
  values (p_date, p_reason, auth.uid());

  delete from day_closings where closing_date = p_date;
end;
$$;


ALTER FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_reconciliation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "mode" "text" NOT NULL,
    "expected" numeric DEFAULT 0 NOT NULL,
    "actual" numeric DEFAULT 0 NOT NULL,
    "variance" numeric DEFAULT 0 NOT NULL,
    "reason" "text",
    "approved_by" "uuid",
    "saved_by" "uuid",
    "saved_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."day_reconciliation" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."day_reconciliation"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_variance numeric;
  row day_reconciliation;
begin
  v_variance := p_actual - p_expected;

  if abs(v_variance) > 0.01 and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A variance reason is required when actual does not match expected (Rs.%).', v_variance;
  end if;

  insert into day_reconciliation (closing_date, mode, expected, actual, variance, reason, approved_by, saved_by)
  values (p_closing_date, p_mode, p_expected, p_actual, v_variance, p_reason, p_approved_by, auth.uid())
  on conflict (closing_date, mode) do update
    set expected = excluded.expected, actual = excluded.actual, variance = excluded.variance,
        reason = excluded.reason, approved_by = excluded.approved_by, saved_by = excluded.saved_by, saved_at = now()
  returning * into row;

  return row;
end;
$$;


ALTER FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_patient_id uuid;
  v_encounter_id uuid;
  v_visit_id uuid;
  v_new_entry queue_entries;
begin
  select patient_id, encounter_id into v_patient_id, v_encounter_id
  from surgical_cases where id = p_case_id;

  if v_patient_id is null then
    raise exception 'Case not found.';
  end if;

  -- Most recent visit for this patient dated today (IST) -- deliberately
  -- NOT filtering by queue_entries status, since visits.status stays
  -- 'Open' regardless of whether its queue entries are Done.
  select id into v_visit_id
  from visits
  where patient_id = v_patient_id
    and ist_date(created_at) = ist_date(now())
  order by created_at desc
  limit 1;

  if v_visit_id is null then
    raise exception 'No visit found for this patient today -- they need to check in at Front Office first.';
  end if;

  v_new_entry := issue_queue_token(v_visit_id, 'Doctor');

  update queue_entries
  set status = p_queue_status, sent_out_at = now()
  where id = v_new_entry.id
  returning * into v_new_entry;

  insert into encounter_audit_log (encounter_id, message, created_by)
  values (v_encounter_id, p_audit_message, p_user_id);

  return v_new_entry;
end;
$$;


ALTER FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_surgical_case_iol_category"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.status = 'Approved' and new.final_iol_category is not null then
    update public.surgical_cases
    set iol_category = new.final_iol_category,
        biometry_done = true
    where encounter_id = new.encounter_id
      and (iol_category is distinct from new.final_iol_category or biometry_done = false);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_surgical_case_iol_category"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid",
    "patient_name_temp" "text",
    "mobile_temp" "text",
    "doctor_id" "uuid",
    "appointment_date" "date" NOT NULL,
    "appointment_time" time without time zone NOT NULL,
    "visit_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "remarks" "text",
    "status" "text" DEFAULT 'Booked'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "appointments_business_hours" CHECK ((("appointment_time" >= '10:00:00'::time without time zone) AND ("appointment_time" <= '18:00:00'::time without time zone))),
    CONSTRAINT "appointments_status_check" CHECK (("status" = ANY (ARRAY['Booked'::"text", 'Checked-in'::"text", 'Cancelled'::"text", 'No-show'::"text"]))),
    CONSTRAINT "appointments_visit_type_check" CHECK (("visit_type" = ANY (ARRAY['New Consultation'::"text", 'Follow-up'::"text", 'Investigation Only'::"text", 'Post-operative Review'::"text", 'Emergency'::"text", 'Procedure'::"text"])))
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."biometry_iol_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "biometry_record_id" "uuid" NOT NULL,
    "version_no" integer NOT NULL,
    "power" "text",
    "formula" "text",
    "status" "text" DEFAULT 'Approved'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "biometry_iol_versions_status_check" CHECK (("status" = ANY (ARRAY['Approved'::"text", 'Superseded'::"text"])))
);


ALTER TABLE "public"."biometry_iol_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."biometry_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "surgeon_id" "uuid",
    "procedure_name" "text",
    "surgical_eye" "text",
    "status" "text" DEFAULT 'Awaiting Biometry'::"text" NOT NULL,
    "measurements" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verify_device" "text",
    "verify_remarks" "text",
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "target_refraction" "text",
    "formula_results" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "selected_formula" "text",
    "final_iol_power" "text",
    "final_iol_category" "text",
    "final_iol_catalog_id" "uuid",
    "surgeon_notes" "text",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    "invoice_id" "uuid",
    "doctor_instructions" "text",
    "surgical_case_id" "uuid",
    CONSTRAINT "biometry_records_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "biometry_records_status_check" CHECK (("status" = ANY (ARRAY['Awaiting Biometry'::"text", 'Measured'::"text", 'Calculated'::"text", 'Approved'::"text", 'Cancelled'::"text"]))),
    CONSTRAINT "biometry_records_surgical_eye_check" CHECK (("surgical_eye" = ANY (ARRAY['RE'::"text", 'LE'::"text", 'OU'::"text"])))
);


ALTER TABLE "public"."biometry_records" OWNER TO "postgres";


COMMENT ON COLUMN "public"."biometry_records"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



COMMENT ON COLUMN "public"."biometry_records"."surgical_case_id" IS 'Optional link back to the surgical case this record originated from
   (set by Counselling''s "Send for Biometry"). NULL for standalone
   OPD-ordered biometry, which is equally valid and does not involve a
   surgical case at all.';



CREATE TABLE IF NOT EXISTS "public"."clinical_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "file_name" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "file_size" bigint,
    "mime_type" "text",
    "uploaded_by" "uuid",
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."clinical_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clinical_examinations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "external_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "external_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "anterior_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "anterior_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "cdr_re" "text",
    "cdr_le" "text",
    "gonio_re" "text",
    "gonio_le" "text",
    "disc_appearance" "text",
    "glaucoma_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "posterior_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "posterior_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "remarks_re" "text",
    "remarks_le" "text",
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "clinical_examinations_anterior_status_check" CHECK (("anterior_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_external_status_check" CHECK (("external_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_glaucoma_status_check" CHECK (("glaucoma_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_posterior_status_check" CHECK (("posterior_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."clinical_examinations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."credit_note_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."credit_note_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_closing_reopens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "reason" "text" NOT NULL,
    "reopened_by" "uuid",
    "reopened_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."day_closing_reopens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."diagnoses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" DEFAULT 'primary'::"text" NOT NULL,
    "eye" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    CONSTRAINT "diagnoses_category_check" CHECK (("category" = ANY (ARRAY['primary'::"text", 'secondary'::"text", 'associated'::"text", 'systemic'::"text"])))
);


ALTER TABLE "public"."diagnoses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."doctor_repeat_findings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "re_va" "text",
    "le_va" "text",
    "re_iop" numeric,
    "le_iop" numeric,
    "re_sph" "text",
    "le_sph" "text",
    "re_cyl" "text",
    "le_cyl" "text",
    "notes" "text",
    "recorded_by" "uuid",
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."doctor_repeat_findings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."encounter_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."encounter_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."encounters" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "doctor_id" "uuid",
    "chief_complaint" "text",
    "status" "text" DEFAULT 'In Consultation'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "chief_complaint_chips" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "hx_duration" "text",
    "hx_laterality" "text",
    "hx_hopi" "text",
    "ocular_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "medical_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "family_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "hx_drug_allergy" "text",
    "patient_instructions" "text",
    "encounter_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "visit_outcome" "text",
    CONSTRAINT "encounters_encounter_type_check" CHECK (("encounter_type" = ANY (ARRAY['New Consultation'::"text", 'Follow-up'::"text"]))),
    CONSTRAINT "encounters_status_check" CHECK (("status" = ANY (ARRAY['In Consultation'::"text", 'Completed'::"text"])))
);


ALTER TABLE "public"."encounters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hospital_settings" (
    "id" boolean DEFAULT true NOT NULL,
    "name" "text" DEFAULT 'VEDA EYE HOSPITAL'::"text",
    "unit_line" "text" DEFAULT 'A UNIT OF VEDA MEDITECH OPC PVT LTD'::"text",
    "regn_no" "text" DEFAULT 'UK/HDR/DRA/2026/1014'::"text",
    "address_line1" "text" DEFAULT 'Kankhal Road, Vishnu Garden Lane 1,'::"text",
    "address_line2" "text" DEFAULT 'Above Sharma Imaging, Singhdwar,'::"text",
    "city_state_pin" "text" DEFAULT 'Haridwar, Uttarakhand-PIN:249404'::"text",
    "phone" "text" DEFAULT '01334-322523/+91-9084736880'::"text",
    "email" "text" DEFAULT 'admin@vedaeyehospital.com'::"text",
    "terms_text" "text" DEFAULT 'Invoice due & Payable on Receipt.'::"text",
    "logo_data_url" "text",
    "case_sheet_hide_header" boolean DEFAULT false NOT NULL,
    "glasses_rx_hide_header" boolean DEFAULT false NOT NULL,
    "print_letterhead_space_cm" numeric DEFAULT 5 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid",
    CONSTRAINT "hospital_settings_singleton" CHECK ("id")
);


ALTER TABLE "public"."hospital_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."investigation_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "eye" "text",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "status" "text" DEFAULT 'Ordered'::"text" NOT NULL,
    "billed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "result_notes" "text",
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "result_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verification_checklist" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "unable_reason" "text",
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    "invoice_id" "uuid",
    "started_at" timestamp with time zone,
    "started_by" "uuid",
    CONSTRAINT "investigation_orders_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "investigation_orders_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text"]))),
    CONSTRAINT "investigation_orders_status_check" CHECK (("status" = ANY (ARRAY['Ordered'::"text", 'In Progress'::"text", 'Completed'::"text", 'Available'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."investigation_orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."investigation_orders"."result_data" IS 'Type-specific measurement fields, e.g. {"cmt-re": "245", "rnfl": "85"} for OCT.';



COMMENT ON COLUMN "public"."investigation_orders"."verification_checklist" IS 'Which verification checklist items were checked at verify time, e.g. {"Scan quality acceptable": true}.';



COMMENT ON COLUMN "public"."investigation_orders"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



CREATE TABLE IF NOT EXISTS "public"."invoice_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "service_code" "text",
    "service_name" "text" NOT NULL,
    "dept" "text",
    "qty" integer DEFAULT 1 NOT NULL,
    "rate" numeric NOT NULL,
    "gst_pct" numeric DEFAULT 0 NOT NULL,
    "disc" numeric DEFAULT 0 NOT NULL,
    "gross" numeric NOT NULL,
    "gst_amount" numeric NOT NULL,
    "net" numeric NOT NULL
);


ALTER TABLE "public"."invoice_line_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoice_modifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "modified_by" "uuid",
    "modified_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "details" "text",
    CONSTRAINT "invoice_modifications_action_check" CHECK (("action" = ANY (ARRAY['line_item_removed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."invoice_modifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."invoice_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."invoice_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_clinical_observations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_clinical_observations_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_clinical_observations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_data_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "master_table" "text" NOT NULL,
    "record_code" "text" NOT NULL,
    "action" "text" NOT NULL,
    "detail" "text",
    "changed_by" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_data_audit_log_action_check" CHECK (("action" = ANY (ARRAY['Create'::"text", 'Edit'::"text", 'Deactivate'::"text", 'Reactivate'::"text"])))
);


ALTER TABLE "public"."master_data_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_diagnoses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_diagnoses_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_diagnoses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_drugs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "brand" "text",
    "generic" "text" NOT NULL,
    "strength" "text",
    "form" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "rate" numeric DEFAULT 0,
    "gst_pct" numeric DEFAULT 12,
    CONSTRAINT "master_drugs_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_drugs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_history_options" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "category" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text" NOT NULL,
    CONSTRAINT "master_history_options_category_check" CHECK (("category" = ANY (ARRAY['chief_complaint'::"text", 'ocular_history'::"text", 'medical_history'::"text", 'family_history'::"text"]))),
    CONSTRAINT "master_history_options_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_history_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_iol_catalog" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "brand" "text" NOT NULL,
    "model" "text" NOT NULL,
    "manufacturer" "text",
    "category" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "origin" "text",
    CONSTRAINT "master_iol_catalog_category_check" CHECK (("category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "master_iol_catalog_origin_check" CHECK (("origin" = ANY (ARRAY['Indian'::"text", 'Imported'::"text"]))),
    CONSTRAINT "master_iol_catalog_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_iol_catalog" OWNER TO "postgres";


COMMENT ON COLUMN "public"."master_iol_catalog"."origin" IS 'Indian or Imported make of this specific IOL SKU.';



CREATE TABLE IF NOT EXISTS "public"."master_iop_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_iop_methods_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_iop_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_ot_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "default_room" "text",
    "capacity" integer DEFAULT 4 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_ot_sessions_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_ot_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "price" numeric NOT NULL,
    "includes" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "iol_category" "text",
    "origin" "text",
    "surgery_id" "uuid",
    CONSTRAINT "master_packages_iol_category_check" CHECK (("iol_category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "master_packages_origin_check" CHECK (("origin" = ANY (ARRAY['Indian'::"text", 'Imported'::"text"]))),
    CONSTRAINT "master_packages_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_packages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."master_packages"."iol_category" IS 'Matches biometry_records.final_iol_category. Package is only shown during
   counselling once biometry has advised this IOL type. NULL = not IOL-
   specific (e.g. Glaucoma surgery package), shown regardless of IOL type.';



COMMENT ON COLUMN "public"."master_packages"."origin" IS 'Indian or Imported IOL make -- price tier within an iol_category.
   NULL for non-IOL packages.';



CREATE TABLE IF NOT EXISTS "public"."master_procedures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_procedures_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_procedures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "dept" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "gst_pct" numeric DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "investigation_package" "text",
    CONSTRAINT "master_services_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_surgeries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_surgeries_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_surgeries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_surgical_consumables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_surgical_consumables_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_surgical_consumables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."medical_fitness_referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "referred_by" "uuid",
    "referred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewing_doctor_id" "uuid",
    "status" "text" DEFAULT 'Pending Review'::"text" NOT NULL,
    "fitness_notes" "text",
    "cleared_by" "uuid",
    "cleared_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "medical_fitness_referrals_status_check" CHECK (("status" = ANY (ARRAY['Pending Review'::"text", 'Cleared'::"text", 'Not Fit'::"text"])))
);


ALTER TABLE "public"."medical_fitness_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_assessments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'Draft'::"text" NOT NULL,
    "va_scale" "text" DEFAULT 'Snellen'::"text" NOT NULL,
    "re_dist_unaided" "text",
    "re_dist_glasses" "text",
    "re_dist_ph" "text",
    "re_near_unaided" "text",
    "le_dist_unaided" "text",
    "le_dist_glasses" "text",
    "le_dist_ph" "text",
    "le_near_unaided" "text",
    "ref_pd" "text",
    "ref_vd" "text",
    "ref_obj_re_sph" "text",
    "ref_obj_re_cyl" "text",
    "ref_obj_re_axis" "text",
    "ref_obj_le_sph" "text",
    "ref_obj_le_cyl" "text",
    "ref_obj_le_axis" "text",
    "ref_subj_re_sph" "text",
    "ref_subj_re_cyl" "text",
    "ref_subj_re_axis" "text",
    "ref_subj_le_sph" "text",
    "ref_subj_le_cyl" "text",
    "ref_subj_le_axis" "text",
    "ref_final_re_sph" "text",
    "ref_final_re_cyl" "text",
    "ref_final_re_axis" "text",
    "ref_final_re_add" "text",
    "ref_final_le_sph" "text",
    "ref_final_le_cyl" "text",
    "ref_final_le_axis" "text",
    "ref_final_le_add" "text",
    "iop_method" "text" DEFAULT 'Non-Contact Tonometer (NCT)'::"text",
    "iop_time" "text",
    "add_k1" "text",
    "add_k2" "text",
    "add_axial_length" "text",
    "add_pachymetry" "text",
    "add_white_to_white" "text",
    "add_schirmer" "text",
    "add_color_vision" "text",
    "add_ocular_motility" "text",
    "add_syringing" "text",
    "observation_chips" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "observations_text" "text",
    "section_va_done" boolean DEFAULT false NOT NULL,
    "section_refraction_done" boolean DEFAULT false NOT NULL,
    "section_iop_done" boolean DEFAULT false NOT NULL,
    "section_additional_done" boolean DEFAULT false NOT NULL,
    "section_obs_done" boolean DEFAULT false NOT NULL,
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    CONSTRAINT "optometry_assessments_status_check" CHECK (("status" = ANY (ARRAY['Draft'::"text", 'Completed'::"text"]))),
    CONSTRAINT "optometry_assessments_va_scale_check" CHECK (("va_scale" = ANY (ARRAY['Snellen'::"text", 'LogMAR'::"text", 'ETDRS'::"text"])))
);


ALTER TABLE "public"."optometry_assessments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assessment_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."optometry_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_iop_readings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assessment_id" "uuid" NOT NULL,
    "eye" "text" NOT NULL,
    "value" numeric NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recorded_by" "uuid",
    CONSTRAINT "optometry_iop_readings_eye_check" CHECK (("eye" = ANY (ARRAY['RE'::"text", 'LE'::"text"]))),
    CONSTRAINT "optometry_iop_readings_value_check" CHECK ((("value" > (0)::numeric) AND ("value" <= (80)::numeric)))
);


ALTER TABLE "public"."optometry_iop_readings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_consumables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "added_by" "uuid",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ot_intraop_consumables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "name" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "management" "text",
    "outcome" "text",
    "added_by" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ot_intraop_events_kind_check" CHECK (("kind" = ANY (ARRAY['Event'::"text", 'Complication'::"text"]))),
    CONSTRAINT "ot_intraop_events_severity_check" CHECK (("severity" = ANY (ARRAY['Mild'::"text", 'Moderate'::"text", 'Severe'::"text"])))
);


ALTER TABLE "public"."ot_intraop_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "checkin_items" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "checkin_completed_at" timestamp with time zone,
    "procedure_name" "text",
    "procedure_eye" "text",
    "assistant_surgeon" "text",
    "ot_nurse" "text",
    "procedure_status" "text",
    "procedure_start_time" time without time zone,
    "procedure_end_time" time without time zone,
    "abandon_reason" "text",
    "anaesthesia_type" "text",
    "anaesthetist" "text",
    "anaesthesia_start" time without time zone,
    "anaesthesia_end" time without time zone,
    "anaesthesia_remarks" "text",
    "anaesthesia_recorded_at" timestamp with time zone,
    "implant_manufacturer" "text",
    "implant_model" "text",
    "implant_power" "text",
    "implant_serial" "text",
    "implant_expiry" "date",
    "implant_eye" "text",
    "variance_reason" "text",
    "operative_notes" "text",
    "surgical_outcome" "text",
    "outcome_remarks" "text",
    "recovery_destination" "text",
    "recovery_monitoring" "text",
    "recovery_instructions" "text",
    "recovery_concerns" "text",
    "transferred_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ot_intraop_records_procedure_status_check" CHECK (("procedure_status" = ANY (ARRAY['Completed'::"text", 'Partially Completed'::"text", 'Converted'::"text", 'Abandoned'::"text"])))
);


ALTER TABLE "public"."ot_intraop_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_schedule" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "surgeon_id" "uuid",
    "scheduled_date" "date" NOT NULL,
    "scheduled_time" time without time zone,
    "status" "text" DEFAULT 'Scheduled'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_id" "uuid",
    "room" "text",
    "sequence_number" integer,
    "expected_duration_minutes" integer DEFAULT 30,
    "cancellation_reason" "text",
    "cancellation_remarks" "text",
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "reschedule_count" integer DEFAULT 0 NOT NULL,
    "patient_reported_at" timestamp with time zone,
    CONSTRAINT "ot_schedule_status_check" CHECK (("status" = ANY (ARRAY['Scheduled'::"text", 'In Progress'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."ot_schedule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_schedule_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "detail" "text",
    "changed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ot_schedule_audit_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."package_code_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."package_code_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."package_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "package_id" "uuid" NOT NULL,
    "description" "text" NOT NULL,
    "amount" numeric DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."package_line_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_ledger" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "payment_id" "uuid",
    "entry_type" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "remarks" "text",
    "recorded_by" "uuid",
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "patient_ledger_entry_type_check" CHECK (("entry_type" = ANY (ARRAY['Advance Collected'::"text", 'Advance Adjusted'::"text", 'Advance Refunded'::"text"])))
);


ALTER TABLE "public"."patient_ledger" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."patient_uhid_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."patient_uhid_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL
);


ALTER TABLE "public"."payment_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_edits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "old_reference" "text",
    "new_reference" "text",
    "old_remarks" "text",
    "new_remarks" "text",
    "old_modes" "jsonb",
    "new_modes" "jsonb",
    "reason" "text" NOT NULL,
    "edited_by" "uuid",
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."payment_edits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_modes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "mode" "text" NOT NULL,
    "amount" numeric NOT NULL,
    CONSTRAINT "payment_modes_mode_check" CHECK (("mode" = ANY (ARRAY['Cash'::"text", 'Card'::"text", 'UPI'::"text", 'Cheque'::"text", 'Bank Transfer'::"text"])))
);


ALTER TABLE "public"."payment_modes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pharmacy_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "prescription_id" "uuid",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "dispensed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pharmacy_queue_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Dispensed'::"text"])))
);


ALTER TABLE "public"."pharmacy_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_counselling_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "topic" "text" NOT NULL,
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_counselling_items_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_counselling_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "after_period" "text" NOT NULL,
    "visit_type" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "clinic" "text" DEFAULT 'General'::"text" NOT NULL,
    "instructions" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_followups_visit_type_check" CHECK (("visit_type" = ANY (ARRAY['Routine'::"text", 'Post-operative'::"text", 'Urgent'::"text"])))
);


ALTER TABLE "public"."plan_followups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_optical_advice" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "advice" "text" NOT NULL,
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_optical_advice_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_optical_advice" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_procedures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "eye" "text",
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "notes" "text",
    "billing_status" "text" DEFAULT 'Pending'::"text",
    "billed" boolean DEFAULT false,
    "invoice_id" "uuid",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    CONSTRAINT "plan_procedures_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_procedures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "destination" "text" NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_referrals_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."print_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "html" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid"
);


ALTER TABLE "public"."print_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "designation" "text" NOT NULL,
    "department" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text",
    "registration_no" "text",
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text", 'Locked'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."receipt_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."receipt_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_complications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "management" "text",
    "outcome" "text",
    "added_by" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_complications_severity_check" CHECK (("severity" = ANY (ARRAY['Mild'::"text", 'Moderate'::"text", 'Severe'::"text"])))
);


ALTER TABLE "public"."recovery_complications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_episodes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "visit_id" "uuid",
    "admission_date" "date",
    "surgery_date" "date",
    "discharge_date" "date",
    "recovery_start" time without time zone,
    "recovery_end" time without time zone,
    "consciousness" "text",
    "pain_level" "text",
    "nausea" "text",
    "dressing_status" "text",
    "escalation_required" boolean DEFAULT false NOT NULL,
    "escalation_reason" "text",
    "observations" "text",
    "discharge_checklist" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "discharge_instructions" "text",
    "discharge_notes" "text",
    "discharged_by" "uuid",
    "discharged_at" timestamp with time zone,
    "closure_status" "text",
    "closure_outcome" "text",
    "closure_remarks" "text",
    "closed_by" "uuid",
    "closed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."recovery_episodes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "visit_label" "text" NOT NULL,
    "scheduled_date" "date" NOT NULL,
    "status" "text" DEFAULT 'Scheduled'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    "rescheduled_count" integer DEFAULT 0 NOT NULL,
    "visit_id" "uuid",
    "encounter_id" "uuid",
    CONSTRAINT "recovery_followups_status_check" CHECK (("status" = ANY (ARRAY['Scheduled'::"text", 'Due'::"text", 'Completed'::"text"])))
);


ALTER TABLE "public"."recovery_followups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_medications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sig" "text" NOT NULL,
    "reason" "text",
    "added_by" "uuid",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."recovery_medications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."refund_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."refund_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."surgical_case_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "note" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."surgical_case_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."surgical_cases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "procedure_name" "text" NOT NULL,
    "eye" "text",
    "package_id" "uuid",
    "status" "text" DEFAULT 'Pending Workup'::"text" NOT NULL,
    "consent_taken" boolean DEFAULT false NOT NULL,
    "biometry_done" boolean DEFAULT false NOT NULL,
    "fitness_cleared" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "package_billed" boolean DEFAULT false NOT NULL,
    "visit_id" "uuid",
    "surgeon_id" "uuid",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "iol_category" "text",
    "decision" "text",
    "decision_reason" "text",
    "investigations_complete" boolean DEFAULT false NOT NULL,
    "advance_payment_id" "uuid",
    "biometry_required" boolean DEFAULT true NOT NULL,
    "biometry_skip_reason" "text",
    "package_locked" boolean DEFAULT false NOT NULL,
    "decision_locked" boolean DEFAULT false NOT NULL,
    "fitness_required" boolean DEFAULT true,
    "fitness_skip_reason" "text",
    "proceed_status" "text" DEFAULT 'Deciding'::"text" NOT NULL,
    "iol_order_notes" "text",
    "last_reminder_sent_at" timestamp with time zone,
    "reminder_count" integer DEFAULT 0 NOT NULL,
    "treatment_instructions" "text",
    CONSTRAINT "surgical_cases_decision_check" CHECK (("decision" = ANY (ARRAY['Accepted'::"text", 'Wants Time to Decide'::"text", 'Discuss with Family'::"text", 'Financial Constraint'::"text", 'Declined'::"text", 'Second Opinion'::"text", 'Other'::"text"]))),
    CONSTRAINT "surgical_cases_iol_category_check" CHECK (("iol_category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "surgical_cases_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text", 'Emergency'::"text"]))),
    CONSTRAINT "surgical_cases_proceed_status_check" CHECK (("proceed_status" = ANY (ARRAY['Deciding'::"text", 'Awaiting Return'::"text", 'Proceeding'::"text"]))),
    CONSTRAINT "surgical_cases_status_check" CHECK (("status" = ANY (ARRAY['Pending Workup'::"text", 'Ready for Scheduling'::"text", 'Scheduled'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."surgical_cases" OWNER TO "postgres";


COMMENT ON COLUMN "public"."surgical_cases"."proceed_status" IS 'Deciding: just advised, no decision yet. Awaiting Return: patient said
   they will come back another day for workup/decision. Proceeding:
   patient is moving forward now (same visit or already returned).';
COMMENT ON COLUMN "public"."surgical_cases"."iol_order_notes" IS 'Free text -- e.g. "Ordered Alcon monofocal +21D from XYZ Optics,
   expected Friday". Simple by design, no structured procurement
   tracking yet.';
COMMENT ON COLUMN "public"."surgical_cases"."iol_category" IS 'Denormalized from biometry_records.final_iol_category once Biometry is
   Approved -- lets the counselling package picker filter Master Data
   packages without joining to biometry_records every time.';



COMMENT ON COLUMN "public"."surgical_cases"."advance_payment_id" IS 'Set once an advance is collected in M11 against the package chosen here.';



CREATE SEQUENCE IF NOT EXISTS "public"."visit_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."visit_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workflow_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "kind" "text" NOT NULL,
    "status" "text" DEFAULT 'Requested'::"text" NOT NULL,
    "requested_by" "uuid",
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    CONSTRAINT "workflow_requests_kind_check" CHECK (("kind" = ANY (ARRAY['Biometry'::"text", 'Medical Fitness'::"text", 'Counselling'::"text"]))),
    CONSTRAINT "workflow_requests_status_check" CHECK (("status" = ANY (ARRAY['Requested'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."workflow_requests" OWNER TO "postgres";


ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clinical_attachments"
    ADD CONSTRAINT "clinical_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_encounter_id_key" UNIQUE ("encounter_id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_credit_note_number_key" UNIQUE ("credit_note_number");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_closing_reopens"
    ADD CONSTRAINT "day_closing_reopens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_closing_date_key" UNIQUE ("closing_date");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_opening_date_key" UNIQUE ("opening_date");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_closing_date_mode_key" UNIQUE ("closing_date", "mode");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diagnoses"
    ADD CONSTRAINT "diagnoses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hospital_settings"
    ADD CONSTRAINT "hospital_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_invoice_number_key" UNIQUE ("invoice_number");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_clinical_observations"
    ADD CONSTRAINT "master_clinical_observations_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_clinical_observations"
    ADD CONSTRAINT "master_clinical_observations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_data_audit_log"
    ADD CONSTRAINT "master_data_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_diagnoses"
    ADD CONSTRAINT "master_diagnoses_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_diagnoses"
    ADD CONSTRAINT "master_diagnoses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_drugs"
    ADD CONSTRAINT "master_drugs_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_drugs"
    ADD CONSTRAINT "master_drugs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_history_options"
    ADD CONSTRAINT "master_history_options_category_code_key" UNIQUE ("category", "code");



ALTER TABLE ONLY "public"."master_history_options"
    ADD CONSTRAINT "master_history_options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_iol_catalog"
    ADD CONSTRAINT "master_iol_catalog_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_iol_catalog"
    ADD CONSTRAINT "master_iol_catalog_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_iop_methods"
    ADD CONSTRAINT "master_iop_methods_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_iop_methods"
    ADD CONSTRAINT "master_iop_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_ot_sessions"
    ADD CONSTRAINT "master_ot_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_procedures"
    ADD CONSTRAINT "master_procedures_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_procedures"
    ADD CONSTRAINT "master_procedures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_services"
    ADD CONSTRAINT "master_services_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_services"
    ADD CONSTRAINT "master_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_surgeries"
    ADD CONSTRAINT "master_surgeries_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_surgeries"
    ADD CONSTRAINT "master_surgeries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_surgical_consumables"
    ADD CONSTRAINT "master_surgical_consumables_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_surgical_consumables"
    ADD CONSTRAINT "master_surgical_consumables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_visit_id_key" UNIQUE ("visit_id");



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_ot_schedule_id_key" UNIQUE ("ot_schedule_id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."package_line_items"
    ADD CONSTRAINT "package_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_uhid_key" UNIQUE ("uhid");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_modes"
    ADD CONSTRAINT "payment_modes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_receipt_number_key" UNIQUE ("receipt_number");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_encounter_id_key" UNIQUE ("encounter_id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_template_key_key" UNIQUE ("template_key");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."queue_entries"
    ADD CONSTRAINT "queue_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_ot_schedule_id_key" UNIQUE ("ot_schedule_id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_visit_number_key" UNIQUE ("visit_number");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_pkey" PRIMARY KEY ("id");



CREATE INDEX "credit_notes_invoice_idx" ON "public"."credit_notes" USING "btree" ("invoice_id");



CREATE INDEX "credit_notes_patient_idx" ON "public"."credit_notes" USING "btree" ("patient_id", "created_at");



CREATE INDEX "doctor_repeat_findings_encounter_idx" ON "public"."doctor_repeat_findings" USING "btree" ("encounter_id", "recorded_at");



CREATE INDEX "encounter_audit_log_encounter_idx" ON "public"."encounter_audit_log" USING "btree" ("encounter_id", "created_at");



CREATE INDEX "idx_appointments_doctor_id" ON "public"."appointments" USING "btree" ("doctor_id");



CREATE INDEX "idx_appointments_patient_id" ON "public"."appointments" USING "btree" ("patient_id");



CREATE INDEX "idx_appt_date" ON "public"."appointments" USING "btree" ("appointment_date");



CREATE INDEX "idx_biometry_iol_versions_created_by" ON "public"."biometry_iol_versions" USING "btree" ("created_by");



CREATE INDEX "idx_biometry_iol_versions_record" ON "public"."biometry_iol_versions" USING "btree" ("biometry_record_id");



CREATE INDEX "idx_biometry_records_approved_by" ON "public"."biometry_records" USING "btree" ("approved_by");



CREATE INDEX "idx_biometry_records_billing_updated_by" ON "public"."biometry_records" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_biometry_records_encounter_id" ON "public"."biometry_records" USING "btree" ("encounter_id");



CREATE INDEX "idx_biometry_records_final_iol_catalog_id" ON "public"."biometry_records" USING "btree" ("final_iol_catalog_id");



CREATE INDEX "idx_biometry_records_invoice_id" ON "public"."biometry_records" USING "btree" ("invoice_id");



CREATE INDEX "idx_biometry_records_status" ON "public"."biometry_records" USING "btree" ("status");



CREATE INDEX "idx_biometry_records_surgeon_id" ON "public"."biometry_records" USING "btree" ("surgeon_id");



CREATE INDEX "idx_biometry_records_verified_by" ON "public"."biometry_records" USING "btree" ("verified_by");



CREATE INDEX "idx_biometry_records_visit" ON "public"."biometry_records" USING "btree" ("visit_id");



CREATE INDEX "idx_clinical_attachments_entity" ON "public"."clinical_attachments" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_clinical_attachments_uploaded_by" ON "public"."clinical_attachments" USING "btree" ("uploaded_by");



CREATE INDEX "idx_clinical_examinations_recorded_by" ON "public"."clinical_examinations" USING "btree" ("recorded_by");



CREATE INDEX "idx_credit_notes_approved_by" ON "public"."credit_notes" USING "btree" ("approved_by");



CREATE INDEX "idx_credit_notes_created_by" ON "public"."credit_notes" USING "btree" ("created_by");



CREATE INDEX "idx_credit_notes_payment_id" ON "public"."credit_notes" USING "btree" ("payment_id");



CREATE INDEX "idx_day_closing_reopens_reopened_by" ON "public"."day_closing_reopens" USING "btree" ("reopened_by");



CREATE INDEX "idx_day_closings_closed_by" ON "public"."day_closings" USING "btree" ("closed_by");



CREATE INDEX "idx_day_openings_opened_by" ON "public"."day_openings" USING "btree" ("opened_by");



CREATE INDEX "idx_day_reconciliation_approved_by" ON "public"."day_reconciliation" USING "btree" ("approved_by");



CREATE INDEX "idx_day_reconciliation_saved_by" ON "public"."day_reconciliation" USING "btree" ("saved_by");



CREATE INDEX "idx_doctor_repeat_findings_recorded_by" ON "public"."doctor_repeat_findings" USING "btree" ("recorded_by");



CREATE INDEX "idx_encounter_audit_log_created_by" ON "public"."encounter_audit_log" USING "btree" ("created_by");



CREATE INDEX "idx_encounters_doctor_id" ON "public"."encounters" USING "btree" ("doctor_id");



CREATE INDEX "idx_encounters_visit_id" ON "public"."encounters" USING "btree" ("visit_id");



CREATE INDEX "idx_hospital_settings_updated_by" ON "public"."hospital_settings" USING "btree" ("updated_by");



CREATE INDEX "idx_investigation_orders_billing_updated_by" ON "public"."investigation_orders" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_investigation_orders_completed_by" ON "public"."investigation_orders" USING "btree" ("completed_by");



CREATE INDEX "idx_investigation_orders_encounter_id" ON "public"."investigation_orders" USING "btree" ("encounter_id");



CREATE INDEX "idx_investigation_orders_invoice_id" ON "public"."investigation_orders" USING "btree" ("invoice_id");



CREATE INDEX "idx_investigation_orders_started_by" ON "public"."investigation_orders" USING "btree" ("started_by");



CREATE INDEX "idx_investigation_orders_verified_by" ON "public"."investigation_orders" USING "btree" ("verified_by");



CREATE INDEX "idx_invoice_line_items_invoice_id" ON "public"."invoice_line_items" USING "btree" ("invoice_id");



CREATE INDEX "idx_invoice_modifications_invoice_id" ON "public"."invoice_modifications" USING "btree" ("invoice_id");



CREATE INDEX "idx_invoice_modifications_modified_by" ON "public"."invoice_modifications" USING "btree" ("modified_by");



CREATE INDEX "idx_invoices_cancelled_by" ON "public"."invoices" USING "btree" ("cancelled_by");



CREATE INDEX "idx_invoices_patient_id" ON "public"."invoices" USING "btree" ("patient_id");



CREATE INDEX "idx_invoices_visit_id" ON "public"."invoices" USING "btree" ("visit_id");



CREATE INDEX "idx_master_data_audit_log_changed_by" ON "public"."master_data_audit_log" USING "btree" ("changed_by");



CREATE INDEX "idx_master_history_options_category_status" ON "public"."master_history_options" USING "btree" ("category", "status");



CREATE INDEX "idx_master_iol_catalog_category" ON "public"."master_iol_catalog" USING "btree" ("category", "status");



CREATE INDEX "idx_master_packages_surgery_id" ON "public"."master_packages" USING "btree" ("surgery_id");



CREATE INDEX "idx_medical_fitness_referrals_cleared_by" ON "public"."medical_fitness_referrals" USING "btree" ("cleared_by");



CREATE INDEX "idx_medical_fitness_referrals_encounter_id" ON "public"."medical_fitness_referrals" USING "btree" ("encounter_id");



CREATE INDEX "idx_medical_fitness_referrals_referred_by" ON "public"."medical_fitness_referrals" USING "btree" ("referred_by");



CREATE INDEX "idx_medical_fitness_referrals_reviewing_doctor_id" ON "public"."medical_fitness_referrals" USING "btree" ("reviewing_doctor_id");



CREATE INDEX "idx_medical_fitness_referrals_surgical_case_id" ON "public"."medical_fitness_referrals" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_mfr_status" ON "public"."medical_fitness_referrals" USING "btree" ("status");



CREATE INDEX "idx_mfr_visit" ON "public"."medical_fitness_referrals" USING "btree" ("visit_id");



CREATE INDEX "idx_optometry_assessments_completed_by" ON "public"."optometry_assessments" USING "btree" ("completed_by");



CREATE INDEX "idx_optometry_assessments_recorded_by" ON "public"."optometry_assessments" USING "btree" ("recorded_by");



CREATE INDEX "idx_optometry_audit_log_created_by" ON "public"."optometry_audit_log" USING "btree" ("created_by");



CREATE INDEX "idx_optometry_iop_readings_recorded_by" ON "public"."optometry_iop_readings" USING "btree" ("recorded_by");



CREATE INDEX "idx_ot_intraop_consumables_added_by" ON "public"."ot_intraop_consumables" USING "btree" ("added_by");



CREATE INDEX "idx_ot_intraop_consumables_ot_schedule_id" ON "public"."ot_intraop_consumables" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_intraop_events_added_by" ON "public"."ot_intraop_events" USING "btree" ("added_by");



CREATE INDEX "idx_ot_intraop_events_schedule" ON "public"."ot_intraop_events" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_intraop_records_completed_by" ON "public"."ot_intraop_records" USING "btree" ("completed_by");



CREATE INDEX "idx_ot_intraop_records_surgical_case_id" ON "public"."ot_intraop_records" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_ot_schedule_audit_log_changed_by" ON "public"."ot_schedule_audit_log" USING "btree" ("changed_by");



CREATE INDEX "idx_ot_schedule_audit_log_ot_schedule_id" ON "public"."ot_schedule_audit_log" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_schedule_cancelled_by" ON "public"."ot_schedule" USING "btree" ("cancelled_by");



CREATE INDEX "idx_ot_schedule_date" ON "public"."ot_schedule" USING "btree" ("scheduled_date");



CREATE INDEX "idx_ot_schedule_session" ON "public"."ot_schedule" USING "btree" ("session_id");



CREATE INDEX "idx_ot_schedule_surgeon_id" ON "public"."ot_schedule" USING "btree" ("surgeon_id");



CREATE INDEX "idx_ot_schedule_surgical_case_id" ON "public"."ot_schedule" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_patient_ledger_patient_id" ON "public"."patient_ledger" USING "btree" ("patient_id");



CREATE INDEX "idx_patient_ledger_payment_id" ON "public"."patient_ledger" USING "btree" ("payment_id");



CREATE INDEX "idx_patient_ledger_recorded_by" ON "public"."patient_ledger" USING "btree" ("recorded_by");



CREATE INDEX "idx_patients_mobile" ON "public"."patients" USING "btree" ("mobile");



CREATE INDEX "idx_payment_allocations_invoice_id" ON "public"."payment_allocations" USING "btree" ("invoice_id");



CREATE INDEX "idx_payment_allocations_payment_id" ON "public"."payment_allocations" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_edits_edited_by" ON "public"."payment_edits" USING "btree" ("edited_by");



CREATE INDEX "idx_payment_modes_payment_id" ON "public"."payment_modes" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_refunds_approved_by" ON "public"."payment_refunds" USING "btree" ("approved_by");



CREATE INDEX "idx_payment_refunds_invoice_id" ON "public"."payment_refunds" USING "btree" ("invoice_id");



CREATE INDEX "idx_payment_refunds_patient_id" ON "public"."payment_refunds" USING "btree" ("patient_id");



CREATE INDEX "idx_payment_refunds_payment_id" ON "public"."payment_refunds" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_refunds_refund_payment_id" ON "public"."payment_refunds" USING "btree" ("refund_payment_id");



CREATE INDEX "idx_payment_refunds_refunded_by" ON "public"."payment_refunds" USING "btree" ("refunded_by");



CREATE INDEX "idx_payments_collected_by" ON "public"."payments" USING "btree" ("collected_by");



CREATE INDEX "idx_payments_patient_id" ON "public"."payments" USING "btree" ("patient_id");



CREATE INDEX "idx_pharmacy_queue_patient_id" ON "public"."pharmacy_queue" USING "btree" ("patient_id");



CREATE INDEX "idx_pharmacy_queue_prescription_id" ON "public"."pharmacy_queue" USING "btree" ("prescription_id");



CREATE INDEX "idx_plan_counselling_items_created_by" ON "public"."plan_counselling_items" USING "btree" ("created_by");



CREATE INDEX "idx_plan_counselling_items_encounter_id" ON "public"."plan_counselling_items" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_followups_created_by" ON "public"."plan_followups" USING "btree" ("created_by");



CREATE INDEX "idx_plan_optical_advice_created_by" ON "public"."plan_optical_advice" USING "btree" ("created_by");



CREATE INDEX "idx_plan_optical_advice_encounter_id" ON "public"."plan_optical_advice" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_procedures_billing_updated_by" ON "public"."plan_procedures" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_plan_procedures_created_by" ON "public"."plan_procedures" USING "btree" ("created_by");



CREATE INDEX "idx_plan_procedures_encounter_id" ON "public"."plan_procedures" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_procedures_invoice_id" ON "public"."plan_procedures" USING "btree" ("invoice_id");



CREATE INDEX "idx_plan_referrals_created_by" ON "public"."plan_referrals" USING "btree" ("created_by");



CREATE INDEX "idx_plan_referrals_encounter_id" ON "public"."plan_referrals" USING "btree" ("encounter_id");



CREATE INDEX "idx_prescriptions_billing_updated_by" ON "public"."prescriptions" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_prescriptions_encounter_id" ON "public"."prescriptions" USING "btree" ("encounter_id");



CREATE INDEX "idx_print_templates_updated_by" ON "public"."print_templates" USING "btree" ("updated_by");



CREATE INDEX "idx_queue_dept_status" ON "public"."queue_entries" USING "btree" ("department", "status");



CREATE INDEX "idx_queue_visit" ON "public"."queue_entries" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_complications_added_by" ON "public"."recovery_complications" USING "btree" ("added_by");



CREATE INDEX "idx_recovery_complications_recovery_episode_id" ON "public"."recovery_complications" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_recovery_episodes_case" ON "public"."recovery_episodes" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_recovery_episodes_closed_by" ON "public"."recovery_episodes" USING "btree" ("closed_by");



CREATE INDEX "idx_recovery_episodes_discharged_by" ON "public"."recovery_episodes" USING "btree" ("discharged_by");



CREATE INDEX "idx_recovery_episodes_visit_id" ON "public"."recovery_episodes" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_followups_encounter_id" ON "public"."recovery_followups" USING "btree" ("encounter_id");



CREATE INDEX "idx_recovery_followups_recovery_episode_id" ON "public"."recovery_followups" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_recovery_followups_visit_id" ON "public"."recovery_followups" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_medications_added_by" ON "public"."recovery_medications" USING "btree" ("added_by");



CREATE INDEX "idx_recovery_medications_recovery_episode_id" ON "public"."recovery_medications" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_surgical_case_notes_created_by" ON "public"."surgical_case_notes" USING "btree" ("created_by");



CREATE INDEX "idx_surgical_case_notes_surgical_case_id" ON "public"."surgical_case_notes" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_surgical_cases_advance_payment_id" ON "public"."surgical_cases" USING "btree" ("advance_payment_id");



CREATE INDEX "idx_surgical_cases_encounter_id" ON "public"."surgical_cases" USING "btree" ("encounter_id");



CREATE INDEX "idx_surgical_cases_package_id" ON "public"."surgical_cases" USING "btree" ("package_id");



CREATE INDEX "idx_surgical_cases_patient_id" ON "public"."surgical_cases" USING "btree" ("patient_id");



CREATE INDEX "idx_surgical_cases_surgeon_id" ON "public"."surgical_cases" USING "btree" ("surgeon_id");



CREATE INDEX "idx_surgical_cases_visit_id" ON "public"."surgical_cases" USING "btree" ("visit_id");



CREATE INDEX "idx_visits_appointment_id" ON "public"."visits" USING "btree" ("appointment_id");



CREATE INDEX "idx_visits_cancelled_by" ON "public"."visits" USING "btree" ("cancelled_by");



CREATE INDEX "idx_visits_doctor_id" ON "public"."visits" USING "btree" ("doctor_id");



CREATE INDEX "idx_visits_patient" ON "public"."visits" USING "btree" ("patient_id");



CREATE INDEX "idx_workflow_requests_encounter_id" ON "public"."workflow_requests" USING "btree" ("encounter_id");



CREATE INDEX "idx_workflow_requests_requested_by" ON "public"."workflow_requests" USING "btree" ("requested_by");



CREATE INDEX "idx_workflow_requests_resolved_by" ON "public"."workflow_requests" USING "btree" ("resolved_by");



CREATE INDEX "master_data_audit_log_idx" ON "public"."master_data_audit_log" USING "btree" ("master_table", "changed_at");



CREATE UNIQUE INDEX "one_primary_diagnosis_per_encounter" ON "public"."diagnoses" USING "btree" ("encounter_id") WHERE (("category" = 'primary'::"text") AND ("status" = 'Active'::"text"));



CREATE UNIQUE INDEX "one_visit_per_patient_per_day" ON "public"."visits" USING "btree" ("patient_id", "public"."ist_date"("created_at"));



CREATE INDEX "optometry_audit_log_assessment_idx" ON "public"."optometry_audit_log" USING "btree" ("assessment_id", "created_at");



CREATE INDEX "optometry_iop_readings_assessment_idx" ON "public"."optometry_iop_readings" USING "btree" ("assessment_id", "eye", "recorded_at");



CREATE INDEX "package_line_items_package_idx" ON "public"."package_line_items" USING "btree" ("package_id", "sort_order");



CREATE INDEX "payment_edits_payment_idx" ON "public"."payment_edits" USING "btree" ("payment_id", "edited_at");



CREATE INDEX "workflow_requests_visit_idx" ON "public"."workflow_requests" USING "btree" ("visit_id", "status");



CREATE OR REPLACE TRIGGER "trg_sync_surgical_case_iol_category" AFTER INSERT OR UPDATE ON "public"."biometry_records" FOR EACH ROW EXECUTE FUNCTION "public"."sync_surgical_case_iol_category"();



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_biometry_record_id_fkey" FOREIGN KEY ("biometry_record_id") REFERENCES "public"."biometry_records"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_final_iol_catalog_id_fkey" FOREIGN KEY ("final_iol_catalog_id") REFERENCES "public"."master_iol_catalog"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."clinical_attachments"
    ADD CONSTRAINT "clinical_attachments_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."day_closing_reopens"
    ADD CONSTRAINT "day_closing_reopens_reopened_by_fkey" FOREIGN KEY ("reopened_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_opened_by_fkey" FOREIGN KEY ("opened_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_saved_by_fkey" FOREIGN KEY ("saved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."diagnoses"
    ADD CONSTRAINT "diagnoses_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."hospital_settings"
    ADD CONSTRAINT "hospital_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_started_by_fkey" FOREIGN KEY ("started_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_modified_by_fkey" FOREIGN KEY ("modified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."master_data_audit_log"
    ADD CONSTRAINT "master_data_audit_log_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_surgery_id_fkey" FOREIGN KEY ("surgery_id") REFERENCES "public"."master_surgeries"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_cleared_by_fkey" FOREIGN KEY ("cleared_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_referred_by_fkey" FOREIGN KEY ("referred_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_reviewing_doctor_id_fkey" FOREIGN KEY ("reviewing_doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_assessment_id_fkey" FOREIGN KEY ("assessment_id") REFERENCES "public"."optometry_assessments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_assessment_id_fkey" FOREIGN KEY ("assessment_id") REFERENCES "public"."optometry_assessments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."master_ot_sessions"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."package_line_items"
    ADD CONSTRAINT "package_line_items_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "public"."master_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_edited_by_fkey" FOREIGN KEY ("edited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_modes"
    ADD CONSTRAINT "payment_modes_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_refund_payment_id_fkey" FOREIGN KEY ("refund_payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_refunded_by_fkey" FOREIGN KEY ("refunded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_collected_by_fkey" FOREIGN KEY ("collected_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_prescription_id_fkey" FOREIGN KEY ("prescription_id") REFERENCES "public"."prescriptions"("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."queue_entries"
    ADD CONSTRAINT "queue_entries_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_discharged_by_fkey" FOREIGN KEY ("discharged_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_advance_payment_id_fkey" FOREIGN KEY ("advance_payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "public"."master_packages"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_appointment_id_fkey" FOREIGN KEY ("appointment_id") REFERENCES "public"."appointments"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE "public"."appointments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."biometry_iol_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."biometry_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clinical_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clinical_examinations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_closing_reopens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_closings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_openings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_reconciliation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."diagnoses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."doctor_repeat_findings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."encounter_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."encounters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hospital_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."investigation_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoice_line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoice_modifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_clinical_observations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_data_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_diagnoses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_drugs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_history_options" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_iol_catalog" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_iop_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_ot_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_packages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_procedures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_surgeries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_surgical_consumables" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."medical_fitness_referrals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_assessments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_iop_readings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_consumables" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_schedule" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_schedule_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."package_line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patient_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_allocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_edits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_modes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_refunds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pharmacy_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_counselling_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_followups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_optical_advice" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_procedures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_referrals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."prescriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."print_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."queue_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_complications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_episodes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_followups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_medications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_all_access" ON "public"."appointments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."biometry_iol_versions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."biometry_records" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."clinical_attachments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."clinical_examinations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."credit_notes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_closing_reopens" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_closings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_openings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_reconciliation" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."diagnoses" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."doctor_repeat_findings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."encounter_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."encounters" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."hospital_settings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."investigation_orders" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoice_line_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoice_modifications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoices" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_clinical_observations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_data_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_diagnoses" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_drugs" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_history_options" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_iol_catalog" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_iop_methods" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_ot_sessions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_packages" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_procedures" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_services" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_surgeries" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_surgical_consumables" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."medical_fitness_referrals" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_assessments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_iop_readings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_consumables" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_events" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_records" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_schedule" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_schedule_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."package_line_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."patient_ledger" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."patients" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_allocations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_edits" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_modes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_refunds" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."pharmacy_queue" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_counselling_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_followups" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_optical_advice" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_procedures" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_referrals" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."prescriptions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."print_templates" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."profiles" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."queue_entries" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_complications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_episodes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_followups" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_medications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."surgical_case_notes" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."surgical_cases" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."visits" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."workflow_requests" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."surgical_case_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."surgical_cases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."workflow_requests" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON TABLE "public"."invoices" TO "anon";
GRANT ALL ON TABLE "public"."invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."invoices" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON TABLE "public"."visits" TO "anon";
GRANT ALL ON TABLE "public"."visits" TO "authenticated";
GRANT ALL ON TABLE "public"."visits" TO "service_role";



GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."day_closings" TO "anon";
GRANT ALL ON TABLE "public"."day_closings" TO "authenticated";
GRANT ALL ON TABLE "public"."day_closings" TO "service_role";



GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON TABLE "public"."credit_notes" TO "anon";
GRANT ALL ON TABLE "public"."credit_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_notes" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "service_role";



GRANT ALL ON TABLE "public"."prescriptions" TO "anon";
GRANT ALL ON TABLE "public"."prescriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."prescriptions" TO "service_role";



GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "service_role";



GRANT ALL ON TABLE "public"."queue_entries" TO "anon";
GRANT ALL ON TABLE "public"."queue_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."queue_entries" TO "service_role";



GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_package_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_package_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_package_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "service_role";



GRANT ALL ON TABLE "public"."day_openings" TO "anon";
GRANT ALL ON TABLE "public"."day_openings" TO "authenticated";
GRANT ALL ON TABLE "public"."day_openings" TO "service_role";



GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."payment_refunds" TO "anon";
GRANT ALL ON TABLE "public"."payment_refunds" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_refunds" TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."patients" TO "anon";
GRANT ALL ON TABLE "public"."patients" TO "authenticated";
GRANT ALL ON TABLE "public"."patients" TO "service_role";



GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "service_role";



GRANT ALL ON TABLE "public"."day_reconciliation" TO "anon";
GRANT ALL ON TABLE "public"."day_reconciliation" TO "authenticated";
GRANT ALL ON TABLE "public"."day_reconciliation" TO "service_role";



GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "service_role";


















GRANT ALL ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "anon";
GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "service_role";



GRANT ALL ON TABLE "public"."biometry_records" TO "anon";
GRANT ALL ON TABLE "public"."biometry_records" TO "authenticated";
GRANT ALL ON TABLE "public"."biometry_records" TO "service_role";



GRANT ALL ON TABLE "public"."clinical_attachments" TO "anon";
GRANT ALL ON TABLE "public"."clinical_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."clinical_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."clinical_examinations" TO "anon";
GRANT ALL ON TABLE "public"."clinical_examinations" TO "authenticated";
GRANT ALL ON TABLE "public"."clinical_examinations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."day_closing_reopens" TO "anon";
GRANT ALL ON TABLE "public"."day_closing_reopens" TO "authenticated";
GRANT ALL ON TABLE "public"."day_closing_reopens" TO "service_role";



GRANT ALL ON TABLE "public"."diagnoses" TO "anon";
GRANT ALL ON TABLE "public"."diagnoses" TO "authenticated";
GRANT ALL ON TABLE "public"."diagnoses" TO "service_role";



GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "anon";
GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "authenticated";
GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "service_role";



GRANT ALL ON TABLE "public"."encounter_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."encounter_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."encounter_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."encounters" TO "anon";
GRANT ALL ON TABLE "public"."encounters" TO "authenticated";
GRANT ALL ON TABLE "public"."encounters" TO "service_role";



GRANT ALL ON TABLE "public"."hospital_settings" TO "anon";
GRANT ALL ON TABLE "public"."hospital_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."hospital_settings" TO "service_role";



GRANT ALL ON TABLE "public"."investigation_orders" TO "anon";
GRANT ALL ON TABLE "public"."investigation_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."investigation_orders" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_line_items" TO "anon";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_modifications" TO "anon";
GRANT ALL ON TABLE "public"."invoice_modifications" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_modifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."master_clinical_observations" TO "anon";
GRANT ALL ON TABLE "public"."master_clinical_observations" TO "authenticated";
GRANT ALL ON TABLE "public"."master_clinical_observations" TO "service_role";



GRANT ALL ON TABLE "public"."master_data_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."master_data_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."master_data_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."master_diagnoses" TO "anon";
GRANT ALL ON TABLE "public"."master_diagnoses" TO "authenticated";
GRANT ALL ON TABLE "public"."master_diagnoses" TO "service_role";



GRANT ALL ON TABLE "public"."master_drugs" TO "anon";
GRANT ALL ON TABLE "public"."master_drugs" TO "authenticated";
GRANT ALL ON TABLE "public"."master_drugs" TO "service_role";



GRANT ALL ON TABLE "public"."master_history_options" TO "anon";
GRANT ALL ON TABLE "public"."master_history_options" TO "authenticated";
GRANT ALL ON TABLE "public"."master_history_options" TO "service_role";



GRANT ALL ON TABLE "public"."master_iol_catalog" TO "anon";
GRANT ALL ON TABLE "public"."master_iol_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."master_iol_catalog" TO "service_role";



GRANT ALL ON TABLE "public"."master_iop_methods" TO "anon";
GRANT ALL ON TABLE "public"."master_iop_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."master_iop_methods" TO "service_role";



GRANT ALL ON TABLE "public"."master_ot_sessions" TO "anon";
GRANT ALL ON TABLE "public"."master_ot_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."master_ot_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."master_packages" TO "anon";
GRANT ALL ON TABLE "public"."master_packages" TO "authenticated";
GRANT ALL ON TABLE "public"."master_packages" TO "service_role";



GRANT ALL ON TABLE "public"."master_procedures" TO "anon";
GRANT ALL ON TABLE "public"."master_procedures" TO "authenticated";
GRANT ALL ON TABLE "public"."master_procedures" TO "service_role";



GRANT ALL ON TABLE "public"."master_services" TO "anon";
GRANT ALL ON TABLE "public"."master_services" TO "authenticated";
GRANT ALL ON TABLE "public"."master_services" TO "service_role";



GRANT ALL ON TABLE "public"."master_surgeries" TO "anon";
GRANT ALL ON TABLE "public"."master_surgeries" TO "authenticated";
GRANT ALL ON TABLE "public"."master_surgeries" TO "service_role";



GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "anon";
GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "authenticated";
GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "service_role";



GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "anon";
GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_assessments" TO "anon";
GRANT ALL ON TABLE "public"."optometry_assessments" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_assessments" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."optometry_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "anon";
GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_events" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_events" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_events" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_records" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_records" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_records" TO "service_role";



GRANT ALL ON TABLE "public"."ot_schedule" TO "anon";
GRANT ALL ON TABLE "public"."ot_schedule" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_schedule" TO "service_role";



GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "service_role";



GRANT ALL ON TABLE "public"."package_line_items" TO "anon";
GRANT ALL ON TABLE "public"."package_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."package_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."patient_ledger" TO "anon";
GRANT ALL ON TABLE "public"."patient_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_ledger" TO "service_role";



GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "service_role";



GRANT ALL ON TABLE "public"."payment_allocations" TO "anon";
GRANT ALL ON TABLE "public"."payment_allocations" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_allocations" TO "service_role";



GRANT ALL ON TABLE "public"."payment_edits" TO "anon";
GRANT ALL ON TABLE "public"."payment_edits" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_edits" TO "service_role";



GRANT ALL ON TABLE "public"."payment_modes" TO "anon";
GRANT ALL ON TABLE "public"."payment_modes" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_modes" TO "service_role";



GRANT ALL ON TABLE "public"."pharmacy_queue" TO "anon";
GRANT ALL ON TABLE "public"."pharmacy_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."pharmacy_queue" TO "service_role";



GRANT ALL ON TABLE "public"."plan_counselling_items" TO "anon";
GRANT ALL ON TABLE "public"."plan_counselling_items" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_counselling_items" TO "service_role";



GRANT ALL ON TABLE "public"."plan_followups" TO "anon";
GRANT ALL ON TABLE "public"."plan_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_followups" TO "service_role";



GRANT ALL ON TABLE "public"."plan_optical_advice" TO "anon";
GRANT ALL ON TABLE "public"."plan_optical_advice" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_optical_advice" TO "service_role";



GRANT ALL ON TABLE "public"."plan_procedures" TO "anon";
GRANT ALL ON TABLE "public"."plan_procedures" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_procedures" TO "service_role";



GRANT ALL ON TABLE "public"."plan_referrals" TO "anon";
GRANT ALL ON TABLE "public"."plan_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_referrals" TO "service_role";



GRANT ALL ON TABLE "public"."print_templates" TO "anon";
GRANT ALL ON TABLE "public"."print_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."print_templates" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_complications" TO "anon";
GRANT ALL ON TABLE "public"."recovery_complications" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_complications" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_episodes" TO "anon";
GRANT ALL ON TABLE "public"."recovery_episodes" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_episodes" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_followups" TO "anon";
GRANT ALL ON TABLE "public"."recovery_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_followups" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_medications" TO "anon";
GRANT ALL ON TABLE "public"."recovery_medications" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_medications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."surgical_case_notes" TO "anon";
GRANT ALL ON TABLE "public"."surgical_case_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."surgical_case_notes" TO "service_role";



GRANT ALL ON TABLE "public"."surgical_cases" TO "anon";
GRANT ALL ON TABLE "public"."surgical_cases" TO "authenticated";
GRANT ALL ON TABLE "public"."surgical_cases" TO "service_role";



GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_requests" TO "anon";
GRANT ALL ON TABLE "public"."workflow_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."workflow_requests" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































FILEEOF_schema_sql

echo "Files written. Run: npm run build"
