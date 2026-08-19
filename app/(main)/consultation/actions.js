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
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required, decision, decision_locked').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
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

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye})`, userData?.user?.id);
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

  // Don't let the same investigation get ordered twice for this
  // encounter while an earlier order is still open (Ordered/In
  // Progress) -- same name, same eye. Cancelled/completed ones don't
  // block a fresh order.
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', encounterId)
    .eq('eye', values.eye)
    .ilike('name', values.name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${values.name.trim()}" (${values.eye}) is already ordered and still pending for this visit.` };
  }

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

    // Shared with Surgical Journey's own "order Biometry" path --
    // creates the biometry_records row if none exists yet, or just
    // reuses the one that does, instead of duplicating that logic here.
    await ensureBiometryRecord(supabase, patientId, enc.visit_id, encounterId, null);

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

