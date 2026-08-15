'use server';

import { createClient } from '@/lib/supabase-server';

const OT_SELECT = '*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles!ot_schedule_surgeon_id_fkey(full_name)';

// ── SCHEDULED OT -- upcoming bookings that haven't happened yet.
// Reschedulable while still in this state; once a patient checks in
// (In Progress) or the case is Completed/Cancelled, it moves to OT
// History instead. ──
export async function getScheduledOT() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select(OT_SELECT)
    .eq('status', 'Scheduled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── OT HISTORY -- everything no longer sitting in the active schedule:
// In Progress (currently in surgery), Completed, and Cancelled. ──
export async function getOTHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select(OT_SELECT)
    .in('status', ['In Progress', 'Completed', 'Cancelled'])
    .order('scheduled_date', { ascending: false });
  if (error) return [];
  return data || [];
}

// Reuses the same capacity-checked availability RPC Counselling uses to
// book a slot in the first place, so the reschedule picker shows the
// same real-time remaining-slot info.
export async function getOTAvailability(date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_ot_availability', { p_date: date });
  if (error) return [];
  return data || [];
}

export async function rescheduleOTSlot(otScheduleId, date, sessionId, reason) {
  const supabase = await createClient();
  if (!date) return { error: 'Pick a new date.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data, error } = await supabase.rpc('reschedule_ot_slot', {
    p_ot_schedule_id: otScheduleId,
    p_date: date,
    p_session_id: sessionId,
    p_reason: reason || null,
  });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { success: true };
}

// Kept here (moved from Counselling) since completing a booking now
// belongs to OT Schedule's own Scheduled tab, not Counselling.
export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

// Self-serve fix for an accidental Complete click, without needing a
// database intervention. Only allowed if no intraop record exists yet
// for this booking -- that's the real safety boundary: a surgery with
// actual recorded intraoperative details has genuinely happened and
// should never be silently reverted this way, only one that was marked
// Complete by mistake before ever being checked in.
export async function undoCompleteOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { data: intraop } = await supabase.from('ot_intraop_records').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (intraop) {
    return { error: 'This surgery already has recorded intraoperative details, so it cannot be undone this way. Contact your administrator if this was still marked Complete in error.' };
  }

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Scheduled' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

// ── REGISTER SURGERY DIRECTLY ──────────────────────────────────────────
// Fast-track for a surgical case that never went through today's
// Doctor -> Counselling pipeline -- a patient returning for a surgery
// that was decided a month ago (before HMIS existed), an external
// referral arriving with their own workup, or an emergency. Without
// this, such a patient's surgical_cases row never gets created, so they
// can never appear in OT Schedule no matter how many times front desk
// checks them in.
//
// Deliberately open to any signed-in staff member for now (no role
// restriction) -- there's a backlog of exactly this kind of case to
// clear. Restricting it to OT Schedule/Administrator only is a
// follow-up, not done here.
//
// This does NOT bypass biometry/fitness silently -- it reuses the exact
// same "skip with a mandatory reason" pattern Counselling already uses
// for biometry (biometry_skip_reason), extended to fitness the same way
// (fitness_skip_reason), so the case honestly records why those steps
// weren't done in this system rather than faking that they were.

export async function searchPatientsForDirectSurgery(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  if (error) return [];
  return data || [];
}

// All active packages, unfiltered by IOL category -- the normal
// Counselling picker (getPackagesForCase) filters by iol_category, but
// that comes from Biometry, which this fast-track deliberately skips.
// Staff pick the correct package directly instead.
export async function getPackagesForDirectSurgery() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return data || [];
}

export async function getSurgeonsForDirectSurgery() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name')
    .eq('designation', 'Doctor')
    .eq('status', 'Active')
    .order('full_name');
  if (error) return [];
  return data || [];
}

export async function registerSurgeryDirect(input) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { patientId, procedureName, eye, surgeonId, priority, workupNote, packageId, date, sessionId, notes } = input || {};

  if (!patientId) return { error: 'Select a patient.' };
  if (!procedureName || !procedureName.trim()) return { error: 'Enter the procedure.' };
  if (!workupNote || !workupNote.trim()) {
    return { error: 'Explain where biometry & medical fitness clearance came from (e.g. "done before HMIS", "external hospital referral -- reports attached", "emergency"). This is recorded on the case for audit purposes.' };
  }
  if (!packageId) return { error: 'Select a billing package.' };
  if (!date) return { error: 'Select a date.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  // Guard against accidentally duplicating an already-open case for this
  // patient + procedure. This bypasses the normal pipeline entirely, so
  // there's no visit_id-scoped check to lean on like markForSurgery has
  // -- check across all of this patient's open cases instead.
  const { data: existingCases } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, status')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .neq('status', 'Completed');
  const dup = (existingCases || []).find((c) => c.procedure_name?.trim().toLowerCase() === procedureName.trim().toLowerCase());
  if (dup) {
    return { error: `This patient already has an open case for ${dup.procedure_name} (${dup.status}). Use OT Schedule or Counselling to manage that one instead of creating a duplicate.` };
  }

  const trimmedNote = workupNote.trim();

  // If front desk already checked this patient in today (the normal
  // order of events -- Surgery visit created, then OT discovers no
  // matching case), attach that visit now so Recovery can show the
  // pre-approved biometry/IOL plan later if one exists. Not required --
  // recovery_episodes.visit_id is nullable specifically so this case
  // still works cleanly when no visit exists yet either way.
  const { data: openVisit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .eq('status', 'Open')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: created, error: insertError } = await supabase
    .from('surgical_cases')
    .insert({
      patient_id: patientId,
      visit_id: openVisit?.id || null,
      procedure_name: procedureName.trim(),
      eye: eye || null,
      surgeon_id: surgeonId || null,
      priority: priority || 'Routine',
      biometry_required: false,
      biometry_skip_reason: trimmedNote,
      fitness_required: false,
      fitness_skip_reason: trimmedNote,
      decision: 'Accepted',
      decision_locked: true,
      package_id: packageId,
      package_locked: true,
      status: 'Ready for Scheduling',
      notes: notes?.trim() || null,
    })
    .select('id')
    .single();

  if (insertError) return { error: insertError.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: created.id,
    note: `Case registered directly, bypassing Doctor/Counselling -- ${trimmedNote}`,
    created_by: userData?.user?.id || null,
  });

  // Reuses the exact same booking RPC Counselling uses -- same capacity
  // checks, same ot_schedule row shape, nothing duplicated.
  const { data: bookResult, error: bookError } = await supabase.rpc('book_ot_slot', {
    p_case_id: created.id,
    p_date: date,
    p_session_id: sessionId,
    p_surgeon_id: surgeonId || null,
    p_notes: notes?.trim() || null,
  });
  if (bookError) return { error: bookError.message, caseId: created.id };
  if (bookResult?.error) return { error: bookResult.error, caseId: created.id };

  return { success: true, caseId: created.id, otScheduleId: bookResult.ot_schedule_id };
}
