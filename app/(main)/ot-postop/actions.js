'use server';

import { createClient } from '@/lib/supabase-server';

// Used by Doctor Dashboard: a Post-operative Review visit routes here
// instead of the normal Consultation form -- find the patient's most
// recent still-open episode (discharged, not yet closed).
export async function getOpenPostOpEpisodeForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('recovery_episodes')
    .select('id, surgical_case_id')
    .is('closure_status', null)
    .not('discharge_date', 'is', null)
    .order('created_at', { ascending: false });
  if (!data || data.length === 0) return null;

  const caseIds = data.map((e) => e.surgical_case_id);
  const { data: cases } = await supabase.from('surgical_cases').select('id, patient_id').in('id', caseIds).eq('patient_id', patientId);
  if (!cases || cases.length === 0) return null;

  const match = data.find((e) => cases.some((c) => c.id === e.surgical_case_id));
  return match?.id || null;
}

// ── DASHBOARD: discharged episodes not yet closed ──
export async function getPostOpCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .is('closure_status', null)
    .order('discharge_date', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: closed episodes ──
export async function getPostOpHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('closure_status', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL (post-op focus: milestones, followups, complications) ──
export async function getPostOpEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const [{ data: followups }, { data: complications }] = await Promise.all([
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return { episode, sc: episode.surgical_cases, followups: followups || [], complications: complications || [] };
}

// ── RESCHEDULE / NOTES on a follow-up visit ──
export async function rescheduleFollowup(followupId, newDate, notes) {
  const supabase = await createClient();
  if (!newDate) return { error: 'A new date is required.' };
  const { data: existing } = await supabase.from('recovery_followups').select('rescheduled_count').eq('id', followupId).single();
  const { error } = await supabase.from('recovery_followups').update({
    scheduled_date: newDate, notes: notes?.trim() || null,
    rescheduled_count: (existing?.rescheduled_count || 0) + 1,
  }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// For adding/editing notes without necessarily changing the date.
export async function saveFollowupNotes(followupId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_followups').update({ notes: notes?.trim() || null }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFollowupStatus(followupId, status) {
  const supabase = await createClient();

  if (status === 'Completed') {
    const { data: followup } = await supabase.from('recovery_followups').select('scheduled_date').eq('id', followupId).single();
    const today = new Date().toISOString().slice(0, 10);
    if (followup && followup.scheduled_date > today) {
      return { error: `This visit is scheduled for ${followup.scheduled_date}, which hasn't happened yet -- it can't be marked Completed in advance.` };
    }
  }

  const { error } = await supabase.from('recovery_followups').update({ status }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── POST-OP COMPLICATIONS ──
export async function addRecoveryComplication(episodeId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Complication name is required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_complications').insert({
    recovery_episode_id: episodeId, name: values.name.trim(), severity: values.severity,
    management: values.management?.trim() || null, outcome: values.outcome?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── CLOSE EPISODE ──
export async function closeEpisode(episodeId, values) {
  const supabase = await createClient();
  if (!values.outcome) return { error: 'VAL-POST-005: Overall clinical outcome is required.' };

  const { data: complications } = await supabase.from('recovery_complications').select('management').eq('recovery_episode_id', episodeId);
  const unmanaged = (complications || []).filter((c) => !c.management);
  if (unmanaged.length > 0) return { error: 'VAL-POST-004: Unmanaged complications exist -- episode cannot close.' };

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_episodes').update({
    closure_status: values.status, closure_outcome: values.outcome, closure_remarks: values.remarks || null,
    closed_by: userData?.user?.id || null, closed_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

