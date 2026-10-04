'use server';

import { createClient } from '@/lib/supabase-server';
import { after } from 'next/server'; // audit rows written after the reply is sent
import { getUserFast } from '@/lib/authUser'; // local token check, no Auth round trip per save
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
  'ref_subjd_re_dist_va', 'ref_subjd_re_dist_sph', 'ref_subjd_re_dist_cyl', 'ref_subjd_re_dist_axis',
  'ref_subjd_re_near_va', 'ref_subjd_re_near_sph', 'ref_subjd_re_near_cyl', 'ref_subjd_re_near_axis',
  'ref_subjd_le_dist_va', 'ref_subjd_le_dist_sph', 'ref_subjd_le_dist_cyl', 'ref_subjd_le_dist_axis',
  'ref_subjd_le_near_va', 'ref_subjd_le_near_sph', 'ref_subjd_le_near_cyl', 'ref_subjd_le_near_axis',
  'ref_subjd_re_add', 'ref_subjd_le_add',
  'ref_subjd_copy_re_to_le',
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

// Loads everything the workspace needs in ONE database call
// (optometry_open_workspace, migration 048): the queue entry + patient,
// the assessment row (creating an empty Draft one on first open -- same
// pattern as encounters auto-creating on first doctor consultation), the
// encounter (also auto-created, for the History section), IOP readings,
// audit log (Administrators only -- RLS on optometry_audit_log is the real
// boundary), doctor-override lines (everyone), lock status, and the
// pick-lists the screen used to fetch separately (iopMethods,
// investigationOptions, historyOptions). Lock rule as before: once
// completed, editable until the doctor's queue entry moves to "In
// Consultation" or "Done" (viewed from the doctor's own entry: only Done).
export async function getAssessmentWorkspaceData(queueEntryId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('optometry_open_workspace', { p_queue_entry_id: queueEntryId });
  if (error) return { error: error.message };
  if (!data || data.error) return { error: data?.error || 'Could not load this assessment.' };
  return data;
}

// "Save Draft" -- patient stays in the queue, nothing routed anywhere
// (BR-OPT-003).
// reloadQueueEntryId (optional): the "Save Draft" button passes it so the
// refreshed workspace comes back in the SAME request (it used to be a
// second request after the save). Autosave doesn't pass it.
export async function saveDraft(assessmentId, fields, reloadQueueEntryId = null) {
  const supabase = await createClient();
  const { data: userData } = await getUserFast(supabase);

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  // Autosave (~1s after typing stops) calls this too: the audit row is
  // written after the reply is sent, so the optometrist never waits on it.
  after(() => addAudit(supabase, assessmentId, 'Draft saved -- patient remains in Optometry Queue', userData?.user?.id));
  if (reloadQueueEntryId) return { success: true, workspace: await getAssessmentWorkspaceData(reloadQueueEntryId) };
  return { success: true };
}

// "Complete Assessment" -- first-time completion. Requires at least
// one VA measurement (VAL-OPT-002). Locks the queue entry forward by
// calling the existing optometry_complete RPC, which issues the
// Doctor token (BR-OPT-004) -- same mechanism the rest of the app
// already relies on.
export async function completeAssessment(assessmentId, queueEntryId, fields) {
  const supabase = await createClient();
  const { data: userData } = await getUserFast(supabase);

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
  const { data: userData } = await getUserFast(supabase);

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
  const { data: userData } = await getUserFast(supabase);

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
// reloadQueueEntryId (optional): see saveDraft -- the "Save Changes"
// button gets the refreshed workspace in the same request.
export async function updateCompletedAssessment(assessmentId, fields, reloadQueueEntryId = null) {
  const supabase = await createClient();
  const { data: userData } = await getUserFast(supabase);

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  after(() => addAudit(supabase, assessmentId, 'Assessment updated post-completion -- not yet seen by doctor', userData?.user?.id)); // after the reply, as above
  if (reloadQueueEntryId) return { success: true, workspace: await getAssessmentWorkspaceData(reloadQueueEntryId) };
  return { success: true };
}

// Add a single IOP reading -- applied immediately (not batched with
// the rest of the form), same as the prototype's "Add reading" flow.
// Out-of-range values still get recorded but flagged (VAL-OPT-003).
// Edit an existing IOP reading -- e.g. a mistyped digit (41 instead of
// 14). Previously there was no way to correct a reading once added,
// only to add more -- an optometrist had no recourse but to leave a
// wrong value on file or add a second reading and hope the doctor
// noticed the right one. Logs old -> new value to the assessment's
// audit trail, same as every other clinical edit here.
export async function updateIopReading(readingId, assessmentId, value) {
  const supabase = await createClient();
  const { data: userData } = await getUserFast(supabase);

  const numericValue = parseFloat(value);
  if (!numericValue || numericValue <= 0 || numericValue > 80) {
    return { error: 'Enter a valid IOP value (1-80 mmHg).' };
  }

  const { data: existing } = await supabase.from('optometry_iop_readings').select('eye, value').eq('id', readingId).single();
  if (!existing) return { error: 'Reading not found.' };

  const { data: reading, error } = await supabase
    .from('optometry_iop_readings')
    .update({ value: numericValue })
    .eq('id', readingId)
    .select()
    .single();

  if (error) return { error: error.message };

  const isHigh = numericValue > 21;
  await addAudit(
    supabase,
    assessmentId,
    `IOP ${existing.eye} corrected: ${existing.value} -> ${numericValue} mmHg${isHigh ? ' -- ELEVATED (VAL-OPT-003)' : ''}`,
    userData?.user?.id
  );

  return { reading };
}

export async function addIopReading(assessmentId, eye, value) {
  const supabase = await createClient();
  const { data: userData } = await getUserFast(supabase);

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

// ── Final glasses prescription lookup, for use OUTSIDE the Optometry
// workspace itself -- specifically Optical Shop, so staff there can
// pull up a patient's most recent finalized refraction (without
// needing to re-open the Optometry module) both to read the numbers
// while preparing an order and to print the same prescription slip
// that's already offered from inside the workspace
// (glasses-prescription-print/[assessmentId]). Only ever looks at
// Completed assessments -- a Draft is still being worked on and isn't
// a real prescription yet. ──
export async function getLatestGlassesPrescription(patientId) {
  if (!patientId) return null;
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('optometry_assessments')
    .select(`
      id, completed_at,
      ref_final_re_dist_sph, ref_final_re_dist_cyl, ref_final_re_dist_axis, ref_final_re_near_sph, ref_final_re_near_cyl, ref_final_re_near_axis, ref_final_re_add,
      ref_final_le_dist_sph, ref_final_le_dist_cyl, ref_final_le_dist_axis, ref_final_le_near_sph, ref_final_le_near_cyl, ref_final_le_near_axis, ref_final_le_add,
      glasses_prescribed, glasses_type, glasses_remarks,
      visits!inner(patient_id)
    `)
    .eq('visits.patient_id', patientId)
    .eq('status', 'Completed')
    .order('completed_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (error || !data) return null;

  // Blank if nothing was actually filled in on the final refraction --
  // a Completed assessment can still have skipped this section (e.g.
  // a visit that was only IOP/anterior-segment focused), and there's
  // nothing useful to show or print in that case.
  const hasAnyPower = [
    data.ref_final_re_dist_sph, data.ref_final_re_near_sph,
    data.ref_final_le_dist_sph, data.ref_final_le_near_sph,
  ].some((v) => v !== null && v !== undefined && v !== '');
  if (!hasAnyPower) return null;

  return data;
}
