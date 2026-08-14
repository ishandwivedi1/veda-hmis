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
