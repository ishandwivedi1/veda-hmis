'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs, getDosageOptions } from '../master-data/actions';
import { getCaseProcedures } from '@/app/(main)/counselling/actions';

// Same Pharmacy drug list + dosage master used in the Doctor
// (Consultation) module's prescription form -- so post-op medication
// entry is the same experience, not a simpler one-off form. Keeps
// drug_type_id and generic/strength so the workspace can filter dosage
// options and power a type-ahead the same way Consultation does.
export async function getDrugOptions() {
  const all = await getDrugs();
  return all.filter((d) => d.status === 'Active' && d.brand);
}

export async function getMedDosageOptions() {
  return getDosageOptions();
}

// Called from OT Intraop's "Hand Over to Recovery" -- creates the
// episode the moment a patient actually arrives here, same
// lazy-create-on-handoff pattern used for biometry/medical fitness.
// visit_id is optional -- a surgical case registered directly (e.g. OT
// Schedule's "Register Surgery Directly", for a patient whose surgery
// was decided outside today's Doctor -> Counselling pipeline) may not
// have one. Recovery still needs to work for that patient; it just
// can't show the pre-approved biometry/IOL plan (there isn't one to
// show -- biometry was skipped for exactly this kind of case anyway).
export async function ensureRecoveryEpisode(otScheduleId, surgicalCaseId, visitId, scheduledDate) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('recovery_episodes').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('recovery_episodes').insert({
    ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId, visit_id: visitId || null,
    admission_date: scheduledDate, surgery_date: scheduledDate,
  }).select('id').single();
  if (error) {
    console.error('ensureRecoveryEpisode failed:', error.message, { otScheduleId, surgicalCaseId, visitId });
    return null;
  }
  return created.id;
}

// ── DASHBOARD: patients still in recovery, not yet discharged -- PLUS
// anyone discharged today. A discharge shouldn't make the patient
// vanish from the dashboard the instant it happens; it only moves to
// History once the day rolls over (same pattern as OT Intraop's
// Dashboard vs History split). Uses >= today, not = today -- a
// discharge_date mistakenly entered in the FUTURE (the date input has
// no upper bound) must stay visible here too, since it hasn't actually
// happened yet. Previously an exact-match-today filter meant a future
// date matched neither this query nor History's "< today", so the
// patient vanished from Recovery entirely. ──
export async function getRecoveryCaseList() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .or(`discharge_date.is.null,discharge_date.gte.${todayIst}`)
    .order('created_at', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: discharged episodes from BEFORE today -- Recovery's part
// is done, Post Op takes over follow-up tracking and closure from here.
// Today's discharges stay on the Dashboard until the day rolls over. ──
export async function getRecoveryHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .lt('discharge_date', todayIst)
    .order('discharge_date', { ascending: false });
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

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }, { data: complications }, caseProcedures] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model, surgical_outcome, outcome_remarks').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, matched by
    // surgical_case_id (a real FK, always available) -- not biometry,
    // which no longer has any "approved" concept and isn't scoped to a
    // visit/case anymore either.
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
    // Additional procedures within the same surgery (e.g. Anti-VEGF
    // Injection alongside a Cataract case) -- shown alongside the
    // primary procedure everywhere Recovery displays it, including the
    // Discharge Summary printout.
    getCaseProcedures(sc.id),
  ]);

  return {
    episode, sc, intraop: intraop || null, biometryPlans: approval ? [approval] : [],
    meds: meds || [], followups: followups || [], complications: complications || [],
    caseProcedures,
  };
}

// ── RECOVERY ASSESSMENT / GENERAL SAVE ──
export async function saveRecoveryFields(episodeId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_episodes').update(values).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── MEDICATIONS -- same structured Dosage/Frequency/Duration/Eye
// entry (and tapering schedule support) as the Doctor module's
// prescription form, instead of a single free-text "sig" field. `sig`
// is still composed and stored on each row so existing consumers (the
// Discharge Summary print template, the on-page list) keep working
// unchanged. ──
function composeSig(dosage, frequency, duration) {
  return [dosage, frequency, duration && `x ${duration}`].filter(Boolean).join(' ');
}

export async function addRecoveryMedication(episodeId, values, reason) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Medicine name is required.' };
  if (!values.dosage?.trim()) return { error: 'Dosage is required.' };
  if (!values.frequency?.trim() || !values.duration?.trim()) return { error: 'Frequency and duration are required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_medications').insert({
    recovery_episode_id: episodeId,
    name: values.name.trim(),
    dosage: values.dosage, frequency: values.frequency, duration: values.duration, eye: values.eye || null,
    sig: composeSig(values.dosage, values.frequency, values.duration),
    reason: reason?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// Tapering schedule -- same drug across steps as Consultation's
// tapering builder, but dosage, frequency, and duration can all vary
// per step (e.g. 2 tablets tapering down to 1), each step a separate
// row sharing one taper_group_id.
export async function addTaperedRecoveryMedication(episodeId, values, reason) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Medicine name is required.' };
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration && s.dosage);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const { data: userData } = await supabase.auth.getUser();
  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    recovery_episode_id: episodeId,
    name: values.name.trim(),
    dosage: s.dosage, frequency: s.frequency, duration: s.duration, eye: values.eye || null,
    sig: composeSig(s.dosage, s.frequency, s.duration),
    reason: reason?.trim() || null,
    taper_group_id: taperGroupId, taper_step: i + 1,
    added_by: userData?.user?.id || null,
  }));

  const { error } = await supabase.from('recovery_medications').insert(rows);
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeRecoveryMedication(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_medications').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeRecoveryTaperGroup(taperGroupId) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_medications').delete().eq('taper_group_id', taperGroupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DISCHARGE ──
// The 4 suggested review dates (Day 1 / Week 1 / Month 1 / Final
// Refraction) are a starting point, not a rule -- different surgeries
// need different review schedules, so the doctor can edit labels/dates
// or remove any of them before confirming discharge. followupPlan is
// whatever's left in that editable list at the time of discharge.
export async function confirmDischarge(episodeId, checklist, dischargeNotes, dischargeInstructions, dischargeDate, followupPlan) {
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

  const followups = (followupPlan || [])
    .filter((f) => f.visit_label?.trim() && f.scheduled_date)
    .map((f) => ({ recovery_episode_id: episodeId, visit_label: f.visit_label.trim(), scheduled_date: f.scheduled_date }));
  if (followups.length > 0) {
    await supabase.from('recovery_followups').insert(followups);
  }

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
