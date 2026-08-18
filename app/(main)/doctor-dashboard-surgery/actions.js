'use server';

import { createClient } from '@/lib/supabase-server';

// ── SURGERY DASHBOARD -- doctor-facing view of the surgical pipeline,
// parallel to the OPD Doctor Dashboard but scoped entirely to
// ot_schedule/surgical_cases/recovery_episodes instead of queue_entries.
// Not scoped by surgeon for now (single-surgeon hospital today) --
// surgeon_id is already on ot_schedule/surgical_cases so a per-doctor
// filter can be added later without a schema change.
//
// Three buckets, all derived from existing status fields -- no new
// "surgery dashboard status" column, so nothing here can drift out of
// sync with what Patient Check-In / Intraop / Recovery already show:
//   Scheduled -- ot_schedule.status = 'Scheduled' (any upcoming date,
//     not just today -- a doctor reviewing their surgical list wants
//     the full upcoming picture, not just today's).
//   Active    -- ot_schedule.status = 'In Progress' (checked in, in OT)
//     OR status = 'Completed' with an open recovery_episode
//     (discharge_date IS NULL) -- surgery is done but the patient
//     hasn't been discharged from Recovery yet.
//   History   -- recovery_episodes.discharge_date IS NOT NULL. This is
//     the single completion signal -- matches the fix already in place
//     for Recovery/Surgical Journey (future-dated discharge_date bug).

const CASE_SELECT = '*, master_ot_sessions(name), surgical_cases(id, surgery_code, procedure_name, eye, patient_id, patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))';

export async function getSurgeryDashboardScheduled() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('ot_schedule')
    .select(CASE_SELECT)
    .eq('status', 'Scheduled')
    .gte('scheduled_date', todayIst)
    .order('scheduled_date', { ascending: true })
    .order('sequence_number', { ascending: true, nullsFirst: false });
  if (error) return [];
  return (data || []).filter((b) => b.surgical_cases);
}

export async function getSurgeryDashboardActive() {
  const supabase = await createClient();

  const [{ data: inProgress, error: inProgressError }, { data: completed, error: completedError }] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'In Progress')
      .order('scheduled_date', { ascending: true }),
    supabase
      .from('ot_schedule')
      .select(`${CASE_SELECT}, recovery_episodes(id, discharge_date)`)
      .eq('status', 'Completed')
      .order('scheduled_date', { ascending: false }),
  ]);
  if (inProgressError || completedError) return [];

  const inRecovery = (completed || []).filter((b) => b.surgical_cases && (b.recovery_episodes || []).some((e) => !e.discharge_date));

  const stage = (b) => (b.status === 'In Progress' ? 'Checked-In / In OT' : 'In Recovery');

  return [
    ...(inProgress || []).filter((b) => b.surgical_cases).map((b) => ({ ...b, stage: stage(b) })),
    ...inRecovery.map((b) => ({ ...b, stage: stage(b), recoveryEpisodeId: b.recovery_episodes.find((e) => !e.discharge_date)?.id })),
  ];
}

export async function getSurgeryDashboardHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('id, discharge_date, ot_schedule_id, surgical_cases(id, surgery_code, procedure_name, eye, patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .order('discharge_date', { ascending: false })
    .limit(200);
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

export async function getSurgeryDashboardCounts() {
  const [scheduled, active, history] = await Promise.all([
    getSurgeryDashboardScheduled(),
    getSurgeryDashboardActive(),
    getSurgeryDashboardHistory(),
  ]);
  return { scheduledCount: scheduled.length, activeCount: active.length, historyCount: history.length };
}
