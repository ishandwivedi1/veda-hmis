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

// ── DASHBOARD (Turned Up Today): same open-episode pool as above, but
//    narrowed to patients who actually have an Open visit today -- i.e.
//    they've genuinely checked in for their review, not just due for
//    one. This is the only list that should open in an editable
//    workspace; the general "pending reviews" list above is read-only
//    since nothing there confirms the patient is actually present. ──
export async function getPostOpTurnedUpToday() {
  const supabase = await createClient();
  const { data: ids, error: idsError } = await supabase.rpc('get_postop_checked_in_today');
  if (idsError || !ids || ids.length === 0) return [];

  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .in('id', ids.map((r) => r.episode_id))
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

// ── ADD / REMOVE a review from the schedule -- requirements can change
//    after discharge (e.g. an unplanned complication needs an extra
//    check, or a review turns out unnecessary). Removal is blocked once
//    a review has an actual clinical visit tied to it (encounter already
//    started), so a real record never gets silently orphaned. ──
export async function addFollowup(episodeId, visitLabel, scheduledDate) {
  const supabase = await createClient();
  if (!visitLabel?.trim()) return { error: 'A label for the review is required.' };
  if (!scheduledDate) return { error: 'A date is required.' };
  const { error } = await supabase.from('recovery_followups').insert({
    recovery_episode_id: episodeId, visit_label: visitLabel.trim(), scheduled_date: scheduledDate,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeFollowup(followupId) {
  const supabase = await createClient();
  const { data: followup } = await supabase.from('recovery_followups').select('visit_id, status').eq('id', followupId).single();
  if (followup?.visit_id) {
    return { error: 'This review already has a visit recorded against it and cannot be removed -- reschedule it instead if it needs to move.' };
  }
  const { error } = await supabase.from('recovery_followups').delete().eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
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

// ── PATIENT REVIEW -- reuses the real Consultation screen ──
// Post-op patients now queue through Optometry like anyone else
// (refraction/clinical recording may be needed post-surgery too), with
// the exception of the surgery-day visit itself. Clicking "Start Review"
// here is the doctor's "Call Directly" override -- same mechanism as the
// "Waiting in Optometry" list on Doctor Dashboard: it completes the
// patient's Optometry entry (issuing them a Doctor token) if they
// haven't been seen yet, or just reuses the Doctor entry if Optometry
// already finished. get_or_create_postop_review_visit() reuses the
// patient's visit for today if one already exists (front desk check-in,
// or an earlier follow-up already opened today) instead of failing on
// the one-visit-per-day rule. The resulting queueEntryId is handed
// straight to <ConsultationForm queueEntryId hideHistoryTracker /> --
// the exact same screen as a normal consultation, just without History
// and Action Tracker. Reopening the same follow-up later reuses the same
// visit instead of creating a new one each time.
export async function openFollowupReview(followupId) {
  const supabase = await createClient();
  const { data: followup, error } = await supabase
    .from('recovery_followups')
    .select('*, recovery_episodes(surgical_case_id, surgical_cases(patient_id, surgeon_id))')
    .eq('id', followupId)
    .single();
  if (error) return { error: error.message };

  let visitId = followup.visit_id;

  if (!visitId) {
    const sc = followup.recovery_episodes?.surgical_cases;
    if (!sc) return { error: 'Could not find the surgical case for this follow-up.' };

    const { data: visit, error: visitError } = await supabase.rpc('get_or_create_postop_review_visit', {
      p_patient_id: sc.patient_id,
      p_doctor_id: sc.surgeon_id,
    });
    if (visitError) return { error: visitError.message };
    visitId = visit.id;

    const { error: linkError } = await supabase.from('recovery_followups').update({ visit_id: visitId }).eq('id', followupId);
    if (linkError) return { error: linkError.message };
  }

  // Already routed to Doctor (either Optometry finished normally, or
  // this follow-up's review was already opened before)?
  let { data: queueEntry } = await supabase
    .from('queue_entries')
    .select('id')
    .eq('visit_id', visitId)
    .eq('department', 'Doctor')
    .order('issued_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!queueEntry) {
    // Still waiting in Optometry -- pull them straight in, same as
    // "Call Directly" on Doctor Dashboard.
    const { data: optEntry } = await supabase
      .from('queue_entries')
      .select('id')
      .eq('visit_id', visitId)
      .eq('department', 'Optometry')
      .order('issued_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (optEntry) {
      const { error: rpcError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: optEntry.id });
      if (rpcError) return { error: rpcError.message };
      const { data: routedEntry } = await supabase
        .from('queue_entries')
        .select('id')
        .eq('visit_id', visitId)
        .eq('department', 'Doctor')
        .order('issued_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      queueEntry = routedEntry;
    }
  }

  if (!queueEntry) {
    const { data: newEntry, error: tokenError } = await supabase.rpc('issue_queue_token', { p_visit_id: visitId, p_department: 'Doctor' });
    if (tokenError) return { error: tokenError.message };
    queueEntry = newEntry;
  }

  return { queueEntryId: queueEntry.id };
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

