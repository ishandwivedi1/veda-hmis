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
  'ref_obj_re_add', 'ref_obj_le_add',
  'ref_obj_copy_re_to_le',
  'ref_subj_re_dist_va', 'ref_subj_re_dist_sph', 'ref_subj_re_dist_cyl', 'ref_subj_re_dist_axis',
  'ref_subj_re_near_va', 'ref_subj_re_near_sph', 'ref_subj_re_near_cyl', 'ref_subj_re_near_axis',
  'ref_subj_le_dist_va', 'ref_subj_le_dist_sph', 'ref_subj_le_dist_cyl', 'ref_subj_le_dist_axis',
  'ref_subj_le_near_va', 'ref_subj_le_near_sph', 'ref_subj_le_near_cyl', 'ref_subj_le_near_axis',
  'ref_subj_re_add', 'ref_subj_le_add',
  'ref_subj_copy_re_to_le',
  'ref_final_re_dist_va', 'ref_final_re_dist_sph', 'ref_final_re_dist_cyl', 'ref_final_re_dist_axis',
  'ref_final_re_near_va', 'ref_final_re_near_sph', 'ref_final_re_near_cyl', 'ref_final_re_near_axis',
  'ref_final_le_dist_va', 'ref_final_le_dist_sph', 'ref_final_le_dist_cyl', 'ref_final_le_dist_axis',
  'ref_final_le_near_va', 'ref_final_le_near_sph', 'ref_final_le_near_cyl', 'ref_final_le_near_axis',
  'ref_final_re_add', 'ref_final_le_add',
  'ref_final_re_dist_prism', 'ref_final_le_dist_prism', 'ref_final_re_near_prism', 'ref_final_le_near_prism',
  'glasses_prescribed', 'glasses_type', 'glasses_remarks',
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

  const [{ data: iopReadings }, { data: auditLog }, { data: doctorOverrides }] = await Promise.all([
    supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: true }),
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessment.id).order('created_at', { ascending: false }),
    // Visible to everyone (not just admins) -- narrow RLS policy only
    // exposes rows whose message begins with 'Doctor override', so the
    // optometrist can see what the doctor changed on their record.
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessment.id).ilike('message', 'Doctor override%').order('created_at', { ascending: false }),
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

  return { entry, assessment, encounter, iopReadings: iopReadings || [], auditLog: isAdmin ? (auditLog || []) : [], doctorOverrides: doctorOverrides || [], locked, isAdmin };
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
