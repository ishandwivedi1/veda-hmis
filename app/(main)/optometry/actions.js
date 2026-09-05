'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';
import { doctorSendOut } from '@/app/(main)/queue/actions';
import { addInvestigation } from '@/app/(main)/consultation/actions';

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
    .select('*, visits(id, doctor_id, patients(first_name, salutation, last_name, uhid, age, gender))')
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

// Shared by sendForDilation/sendForInvestigation below -- closes out
// this Optometry queue entry (same optometry_complete RPC completion
// uses, so it's exactly as final: gone from the Optometry queue,
// nothing further expected here) and issues the fresh Doctor token
// that always comes with it, then immediately flips that new token
// from "Waiting" to "Awaiting <label>" via the doctor's own
// doctorSendOut -- the exact function the doctor's "Send for
// Dilation/Investigation" buttons already use. The patient lands
// directly in the doctor's Intermediate list, never sitting in the
// normal active queue at all.
async function routeToDoctorAwaiting(supabase, queueEntryId, kind) {
  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  if (!entry) return { error: 'Queue entry not found.' };

  const { error: completeError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: queueEntryId });
  if (completeError) return { error: completeError.message };

  const { data: doctorEntry } = await supabase
    .from('queue_entries')
    .select('id')
    .eq('visit_id', entry.visit_id)
    .eq('department', 'Doctor')
    .order('issued_at', { ascending: false })
    .limit(1)
    .single();
  if (!doctorEntry) return { error: 'Could not find the new Doctor queue entry.' };

  return doctorSendOut(doctorEntry.id, kind);
}

// No VA requirement here (unlike completeAssessment's VAL-OPT-002) --
// dilation drops go in before VA can be measured, so requiring VA
// first would be backwards for this specific path. Whatever's been
// entered so far is saved as-is; the optometrist's role on this visit
// ends the moment this succeeds.
export async function sendForDilation(assessmentId, queueEntryId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  const result = await routeToDoctorAwaiting(supabase, queueEntryId, 'dilate');
  if (result.error) return result;

  await addAudit(supabase, assessmentId, 'Sent for Dilation -- routed to Doctor Queue (Awaiting Dilation)', userData?.user?.id);
  return { success: true };
}

// Also no VA requirement -- some investigations (OCT, for instance)
// don't depend on it. Unlike Dilation, this also places a REAL
// investigation order (addInvestigation) -- the same function, same
// investigation_orders table, the doctor's own Investigations section
// already uses. That's deliberate: a bare "Awaiting Investigation"
// status with no order behind it would show the patient as sent out
// on the doctor's dashboard while the Investigation department has no
// idea what to actually do, and nothing would reach billing (Pending
// Billing reads investigation_orders directly, not queue status).
// Ordering here is the same record the doctor will see in their own
// Investigations section once they open this same encounter -- not a
// parallel, optometry-only list.
export async function sendForInvestigation(assessmentId, queueEntryId, encounterId, fields, investigationValues) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!investigationValues?.name?.trim()) {
    return { error: 'Select an investigation before sending.' };
  }

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  const orderResult = await addInvestigation(encounterId, investigationValues);
  if (orderResult.needsConfirmation) {
    return { error: `A biometry record already exists for ${orderResult.existingBiometryDate || 'an earlier date'} -- order Biometry from the Investigations section after the doctor opens this visit instead.` };
  }
  if (orderResult.error) return orderResult;

  const result = await routeToDoctorAwaiting(supabase, queueEntryId, 'investigate');
  if (result.error) return result;

  await addAudit(supabase, assessmentId, `Sent for Investigation (${investigationValues.name.trim()}, ${investigationValues.eye}) -- routed to Doctor Queue (Awaiting Investigation)`, userData?.user?.id);
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
