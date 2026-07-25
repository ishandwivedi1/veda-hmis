'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs } from '../master-data/actions';

// Same Pharmacy drug list used in Financial Masters -- so post-op
// medication is picked from the real catalog, not free text.
export async function getDrugOptions() {
  const all = await getDrugs();
  return all
    .filter((d) => d.status === 'Active')
    .map((d) => ({ id: d.id, label: `${d.generic}${d.strength ? ` ${d.strength}` : ''}${d.brand ? ` (${d.brand})` : ''}` }));
}

// Called from OT Intraop's "Hand Over to Recovery" -- creates the
// episode the moment a patient actually arrives here, same
// lazy-create-on-handoff pattern used for biometry/medical fitness.
export async function ensureRecoveryEpisode(otScheduleId, surgicalCaseId, visitId, scheduledDate) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('recovery_episodes').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('recovery_episodes').insert({
    ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId, visit_id: visitId,
    admission_date: scheduledDate, surgery_date: scheduledDate,
  }).select('id').single();
  if (error) return null;
  return created.id;
}

// ── DASHBOARD ──
export async function getRecoveryCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .is('closure_status', null)
    .order('created_at', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY (closed episodes) ──
export async function getRecoveryHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('closure_status', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL ──
export async function getRecoveryEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, ot_schedule_id, surgical_cases(*, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }, { data: complications }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model, surgical_outcome, outcome_remarks').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', episode.visit_id).eq('status', 'Approved'),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return {
    episode, sc, intraop: intraop || null, biometryPlans: biometry || [],
    meds: meds || [], followups: followups || [], complications: complications || [],
  };
}

// ── RECOVERY ASSESSMENT / GENERAL SAVE ──
export async function saveRecoveryFields(episodeId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_episodes').update(values).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── MEDICATIONS ──
export async function addRecoveryMedication(episodeId, name, sig, reason) {
  const supabase = await createClient();
  if (!name?.trim() || !sig?.trim()) return { error: 'Medicine name and dose/frequency are required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_medications').insert({ recovery_episode_id: episodeId, name: name.trim(), sig: sig.trim(), reason: reason?.trim() || null, added_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeRecoveryMedication(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_medications').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DISCHARGE ──
export async function confirmDischarge(episodeId, checklist, dischargeNotes, dischargeInstructions, dischargeDate) {
  const supabase = await createClient();

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  if (!mandatoryDone) return { error: 'VAL-POST-002: All mandatory discharge items must be checked.' };
  if (!dischargeDate) return { error: 'Discharge date is required.' };

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('recovery_episodes').update({
    discharge_date: dischargeDate, discharge_checklist: checklist,
    discharge_notes: dischargeNotes || null, discharge_instructions: dischargeInstructions || null,
    discharged_by: userData?.user?.id || null, discharged_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };

  // AUTO-POST-002: generate the standard follow-up schedule, relative
  // to the actual discharge date chosen (not just "today").
  const addDays = (n) => { const d = new Date(`${dischargeDate}T00:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  const followups = [
    { recovery_episode_id: episodeId, visit_label: 'Post-op Day 1', scheduled_date: addDays(1) },
    { recovery_episode_id: episodeId, visit_label: 'Post-op Week 1', scheduled_date: addDays(7) },
    { recovery_episode_id: episodeId, visit_label: 'Post-op Month 1', scheduled_date: addDays(30) },
    { recovery_episode_id: episodeId, visit_label: 'Final Refraction', scheduled_date: addDays(45) },
  ];
  await supabase.from('recovery_followups').insert(followups);

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

// ── QUALITY INDICATORS (real, computed from actual data) ──
export async function getQualityIndicators() {
  const supabase = await createClient();
  const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);

  const { data: closedThisMonth } = await supabase.from('recovery_episodes').select('id, closure_outcome, admission_date, discharge_date').gte('closed_at', monthStart.toISOString());
  const { data: complicationsThisMonth } = await supabase.from('recovery_complications').select('id, recovery_episode_id').gte('occurred_at', monthStart.toISOString());
  const { data: escalations } = await supabase.from('recovery_episodes').select('id').eq('escalation_required', true).gte('created_at', monthStart.toISOString());

  const total = closedThisMonth?.length || 0;
  const withComplications = new Set((complicationsThisMonth || []).map((c) => c.recovery_episode_id)).size;
  const sameDayDischarge = (closedThisMonth || []).filter((e) => e.admission_date && e.discharge_date && e.admission_date === e.discharge_date).length;

  return [
    { name: 'Episodes closed this month', value: String(total), sub: 'All procedures' },
    { name: 'Post-op complication rate', value: total > 0 ? `${((withComplications / total) * 100).toFixed(1)}%` : '--', sub: `${withComplications} of ${total} episodes` },
    { name: 'Same-day discharge rate', value: total > 0 ? `${((sameDayDischarge / total) * 100).toFixed(1)}%` : '--', sub: `${sameDayDischarge} of ${total} episodes` },
    { name: 'Escalations flagged', value: String(escalations?.length || 0), sub: 'This month' },
  ];
}

