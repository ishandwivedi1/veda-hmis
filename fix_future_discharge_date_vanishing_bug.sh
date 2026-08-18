#!/usr/bin/env bash
set -e

echo 'Applying fix: patients with a future-dated discharge_date disappearing from Surgical Journey / Recovery'

mkdir -p "app/(main)/surgical-journey"
cat > "app/(main)/surgical-journey/actions.js" << 'VEDAEOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { adviseBiometry } from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/counselling/actions';
import { getAdvanceBalance } from '@/app/(main)/payments/actions';

// This module deliberately does NOT reimplement package selection,
// biometry skip/unskip, decision recording, ready-for-scheduling, or OT
// booking -- the page imports those directly from Counselling and OT
// Schedule (same pattern Consultation already uses to call into
// Counselling), since that logic is already built, tested, and
// correct. What THIS file adds is a single page that walks through all
// of it for one patient without switching modules, plus a few
// genuinely new pieces (proceed status, IOL order notes, manual
// reminder tracking) that didn't exist anywhere before.

// ── EDIT PROCEDURE / EYE (any stage) ───────────────────────────────
// counselling's updateSurgicalCase only allows this while status is
// still 'Pending Workup' and refuses otherwise with no real
// alternative -- there was no actual place "further changes should go
// through Counselling" could happen. This lets a genuine correction
// (wrong eye picked, procedure name needs fixing) happen at ANY stage,
// same principle as changePackage/setDecision: once the case has
// progressed, a reason is required and logged, rather than the edit
// being refused outright.
export async function editSurgicalCaseDetails(caseId, procedureName, eye, reason) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status, procedure_name, eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const progressed = sc.status !== 'Pending Workup';
  if (progressed && (!reason || !reason.trim())) {
    return { error: `A reason is required to change the procedure/eye once the case has moved to "${sc.status}".` };
  }

  const { error } = await supabase.from('surgical_cases').update({ procedure_name: procedureName, eye }).eq('id', caseId);
  if (error) return { error: error.message };

  if (progressed) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Procedure/eye corrected -- was "${sc.procedure_name}" (${sc.eye}), now "${procedureName}" (${eye}). Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  return { success: true };
}

// ── IN-HOUSE INVESTIGATIONS (Step 2) ───────────────────────────────
// Flexible and optional -- add whatever this case actually needs, not
// a fixed required panel. Fully generic -- Biometry is just one more
// option in the same list, not a separate hardcoded section, per your
// instruction. Routes through the same investigation_orders table and
// Investigation module queue Doctor Consultation uses. "Further
// investigations for a surgical case go through the surgery module" --
// this is that entry point, not a trip back to Consultation.
export async function getInvestigationOptionsForCase() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

export async function addInHouseInvestigationForCase(caseId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Select an investigation.' };

  const { data: sc } = await supabase.from('surgical_cases').select('encounter_id, patient_id, visit_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!sc.encounter_id) return { error: 'This case has no linked consultation encounter to attach investigations to.' };

  const resolvedEye = eye || 'OU';

  // Don't let the same investigation get ordered twice for this case
  // while an earlier order is still open (Ordered/In Progress).
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', sc.encounter_id)
    .eq('eye', resolvedEye)
    .ilike('name', name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${name.trim()}" (${resolvedEye}) is already ordered and still pending for this case.` };
  }

  // Biometry is patient-level and fulfilled through its own dedicated
  // module -- same special-case Doctor Consultation's addInvestigation
  // already does. A normal investigation_orders row is still created so
  // it shows up in this same list with a status badge, but the actual
  // biometry_records row (device readings, IOL recommendations) is what
  // makes it real -- ensured here, same as everywhere else biometry
  // gets ordered from.
  if (name.trim().toLowerCase() === 'biometry') {
    const result = await adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, null);
    if (result.error) return result;
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: sc.encounter_id, name: name.trim(), eye: resolvedEye, priority: 'Routine',
  });
  if (error) return { error: error.message };

  await supabase.from('encounter_audit_log').insert({
    encounter_id: sc.encounter_id,
    message: `Investigation ordered from Surgical Journey: ${name.trim()} (${resolvedEye})`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}

export async function removeInHouseInvestigationForCase(investigationId) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', investigationId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EXTERNAL INVESTIGATIONS ─────────────────────────────────────────
// Named tests done elsewhere (blood work, HIV test -- not done
// in-house). Each is added by name; the report, once it comes back, is
// a normal clinical_attachments upload keyed to that specific test, not
// a generic unlabeled bucket. Also printable as a referral slip to
// hand the patient.
export async function getExternalTestsForCase(caseId) {
  const supabase = await createClient();
  const { data: tests, error } = await supabase
    .from('external_investigations')
    .select('*')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });
  if (error) return [];

  const testIds = (tests || []).map((t) => t.id);
  let attachmentCountByTest = {};
  if (testIds.length > 0) {
    const { data: attachments } = await supabase
      .from('clinical_attachments')
      .select('entity_id')
      .eq('entity_type', 'external_investigation')
      .in('entity_id', testIds);
    (attachments || []).forEach((a) => { attachmentCountByTest[a.entity_id] = (attachmentCountByTest[a.entity_id] || 0) + 1; });
  }

  return (tests || []).map((t) => ({ ...t, attachmentCount: attachmentCountByTest[t.id] || 0 }));
}

export async function addExternalTest(caseId, name) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Enter a test name.' };
  const { error } = await supabase.from('external_investigations').insert({
    surgical_case_id: caseId, test_name: name.trim(), created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeExternalTest(testId) {
  const supabase = await createClient();
  const { error } = await supabase.from('external_investigations').delete().eq('id', testId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FURTHER INSTRUCTIONS (Treatment) ───────────────────────────────
// Free text tied to the treatment itself (procedure + eye), distinct
// from the pre-op panel notes in the Investigations step.
export async function setTreatmentInstructions(caseId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ treatment_instructions: instructions || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DASHBOARD ────────────────────────────────────────────────────────

// A "Completed" surgical_cases.status only means the surgery itself is
// done (set the moment Intraoperative Management's Surgery Complete is
// submitted) -- the patient isn't actually through the journey until
// Recovery confirms discharge. This resolves, for a batch of case ids
// already known to be status='Completed', each one's discharge_date
// (or undefined if not yet discharged) so callers can bucket cases into
// Active / Discharged Today / History exactly like the Dashboard vs
// History split used elsewhere (OT Intraop, Recovery, Medical Fitness).
async function getDischargeDatesByCase(supabase, completedCaseIds) {
  if (completedCaseIds.length === 0) return {};
  const { data: schedules } = await supabase
    .from('ot_schedule')
    .select('id, surgical_case_id')
    .in('surgical_case_id', completedCaseIds);
  const scheduleIds = (schedules || []).map((s) => s.id);
  if (scheduleIds.length === 0) return {};
  const scheduleToCase = Object.fromEntries((schedules || []).map((s) => [s.id, s.surgical_case_id]));
  const { data: episodes } = await supabase
    .from('recovery_episodes')
    .select('ot_schedule_id, discharge_date')
    .in('ot_schedule_id', scheduleIds)
    .not('discharge_date', 'is', null);
  const byCase = {};
  (episodes || []).forEach((e) => {
    const caseId = scheduleToCase[e.ot_schedule_id];
    if (caseId) byCase[caseId] = e.discharge_date;
  });
  return byCase;
}

// Still genuinely in progress: not Cancelled, and not a Completed case
// that's also been discharged (whether today or earlier) -- a case
// whose surgery finished but whose patient hasn't been discharged yet
// still belongs here. A discharge_date that's somehow in the FUTURE
// (bad manual entry -- the date input has no upper bound) does NOT
// count as "actually discharged" yet -- it must stay here rather than
// falling into the gap between this list, Discharged Today, and
// History (none of which match a future date), which is what made a
// mis-dated case vanish from the module entirely.
export async function getMyActiveSurgicalCases() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false });
  if (error) return [];
  const cases = data || [];

  const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);

  return cases.filter((c) => !(c.status === 'Completed' && dischargeDates[c.id] && dischargeDates[c.id] <= todayIst));
}

// Discharged TODAY -- kept visible on the front page instead of
// vanishing into History the instant discharge happens, same
// Dashboard/History convention as OT Intraop and Recovery. Moves to
// History once the day rolls over.
export async function getDischargedTodaySurgicalCases() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .eq('status', 'Completed')
    .order('created_at', { ascending: false });
  if (error) return [];
  const cases = data || [];

  const completedIds = cases.map((c) => c.id);
  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);

  return cases.filter((c) => dischargeDates[c.id] === todayIst);
}

// Cancelled cases (any time), plus Completed cases discharged BEFORE
// today -- the counterpart to the two functions above, so a case
// doesn't just vanish once it drops off Active / Discharged Today.
export async function getCompletedSurgicalCases() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .order('created_at', { ascending: false })
    .limit(300);
  if (error) return [];
  const cases = data || [];

  const completedIds = cases.filter((c) => c.status === 'Completed').map((c) => c.id);
  const dischargeDates = await getDischargeDatesByCase(supabase, completedIds);

  return cases.filter((c) => c.status === 'Cancelled' || (c.status === 'Completed' && dischargeDates[c.id] && dischargeDates[c.id] < todayIst));
}

// Patients whose decision is "Wants Time to Decide" and haven't
// resolved it yet (accepted or declined). Front desk's follow-up list.
// Ordered oldest-first so the ones most overdue for a call surface at
// the top.
export async function getAwaitingReturnCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile)')
    .eq('decision', 'Wants Time to Decide')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── CASE DETAIL ─────────────────────────────────────────────────────

export async function getSurgicalCaseDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select(`
      *,
      patients:patient_id(id, first_name, last_name, uhid, mobile, age, gender),
      master_packages:package_id(id, name, price, iol_category),
      profiles:surgeon_id(full_name)
    `)
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  // Biometry is patient-level now, not case-scoped -- reused across
  // every future surgical case for that patient (readings don't
  // meaningfully change for years). No more per-eye/per-case matching
  // needed; just look up whatever's on file for this patient.
  const { data: biometryRecords } = await supabase
    .from('biometry_records')
    .select('id, status, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false });

  // In-house investigations -- ordered against this case's own
  // consultation encounter, same investigation_orders table Doctor
  // Consultation uses and the same Investigation module queue picks
  // them up from. Fully generic -- Biometry shows up here too now,
  // same as anything else (whatever the doctor feels like), not a
  // separate hardcoded section.
  let inHouseInvestigations = [];
  if (sc.encounter_id) {
    const { data } = await supabase
      .from('investigation_orders')
      .select('*')
      .eq('encounter_id', sc.encounter_id)
      .order('created_at', { ascending: false });
    inHouseInvestigations = data || [];
  }

  // Day-of-surgery live status -- OT Schedule / Intraop / Recovery
  // already have solid, tested clinical workflows; this page doesn't
  // rebuild them, it just shows where the case currently stands and
  // deep-links into whichever one applies.
  const { data: otSchedule } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, status, master_ot_sessions(name)')
    .eq('surgical_case_id', caseId)
    .order('scheduled_date', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recoveryEpisode = null;
  let checkinCompletedAt = null;
  if (otSchedule) {
    const { data } = await supabase
      .from('recovery_episodes')
      .select('id, discharge_date')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    recoveryEpisode = data;

    const { data: intraopRecord } = await supabase
      .from('ot_intraop_records')
      .select('checkin_completed_at')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    checkinCompletedAt = intraopRecord?.checkin_completed_at || null;
  }

  // Medical fitness stays a real doctor referral/review, same as
  // Counselling -- this isn't a rubber-stamp checkbox, so it keeps its
  // own dedicated review step rather than being folded into a form
  // field here.
  const { data: fitnessReferral } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status, referred_at, fitness_notes')
    .eq('surgical_case_id', caseId)
    .order('referred_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  // The surgeon's final IOL choice -- separate module/step from both
  // Biometry (raw device recommendations) and this page's own package
  // selection (billing category only).
  const { data: iolApproval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  const externalTests = await getExternalTestsForCase(caseId);

  // Payment step (M11's held advance balance, live) -- checked against
  // the net package amount (price - discount) rather than the old
  // never-actually-set advance_payment_id flag. See workspace.js.
  const advanceBalance = sc.patient_id ? await getAdvanceBalance(sc.patient_id) : 0;

  return {
    case: { ...sc, biometry_done: biometryRecords.some((b) => b.status === 'Measured') },
    biometryRecords,
    inHouseInvestigations,
    externalTests,
    fitnessReferral: fitnessReferral || null,
    iolApproval: iolApproval || null,
    otSchedule: otSchedule || null,
    checkinCompletedAt,
    recoveryEpisode,
    advanceBalance: Number(advanceBalance) || 0,
  };
}

// ── ADVISE SURGERY (Step 1-2) ──────────────────────────────────────
// Thin wrapper so the new page's "Advise Surgery" button doesn't need
// to import from Consultation directly -- same underlying function,
// same surgical_cases row Counselling already reads.
export async function adviseSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  return markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes);
}

// ── INVESTIGATIONS (Step 3) ────────────────────────────────────────
// Biometry is real, in-house, tracked work, always covers both eyes,
// and is reused across every future surgical case for the patient
// (readings don't meaningfully change for years). Goes through the
// same mechanism a doctor uses during a normal consultation, landing
// in the actual Biometry Queue. The pre-op panel (blood work etc.) is
// done entirely by a third party -- there's nothing to "order" in this
// system, so it's just a free-text note here; the report itself comes
// in later as an attachment (see AttachmentUploader on the page).
export async function orderBiometryForCase(caseId, instructions) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('patient_id, visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  return adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, instructions);
}

export async function setPreOpPanelNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEED STATUS (Step 4) ────────────────────────────────────────
export async function setProceedStatus(caseId, status) {
  const supabase = await createClient();
  if (!['Deciding', 'Awaiting Return', 'Proceeding'].includes(status)) return { error: 'Invalid status.' };
  const { error } = await supabase.from('surgical_cases').update({ proceed_status: status }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── IOL PROCUREMENT + INFORMAL DATE (Step 6-7) ─────────────────────
// Free text by design -- "Ordered Alcon monofocal +21D from XYZ
// Optics, expected Friday". No structured supplier/PO tracking yet.
export async function setIolOrderNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ iol_order_notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── AWAITING-RETURN REMINDERS (manual for now -- WhatsApp template not
// yet approved, see conversation) -- just tracks that someone called,
// for the front-desk follow-up list. Also drops a case note so there's
// a record of what was said, reusing the same notes trail as everything
// else on the case. ──
export async function recordManualReminder(caseId, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('reminder_count').eq('id', caseId).single();
  const { error } = await supabase.from('surgical_cases').update({
    last_reminder_sent_at: new Date().toISOString(),
    reminder_count: (sc?.reminder_count || 0) + 1,
  }).eq('id', caseId);
  if (error) return { error: error.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: `Follow-up call -- ${note || 'no details recorded'}`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}
VEDAEOF
echo "Wrote app/(main)/surgical-journey/actions.js"

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/actions.js" << 'VEDAEOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs, getDosageOptions } from '../master-data/actions';

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

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }, { data: complications }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model, surgical_outcome, outcome_remarks').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, matched by
    // surgical_case_id (a real FK, always available) -- not biometry,
    // which no longer has any "approved" concept and isn't scoped to a
    // visit/case anymore either.
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return {
    episode, sc, intraop: intraop || null, biometryPlans: approval ? [approval] : [],
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

// Tapering schedule -- same drug and dosage-per-administration across
// steps as Consultation's tapering builder (the amount per dose stays
// the same, only the frequency reduces over time), each step a
// separate row sharing one taper_group_id.
export async function addTaperedRecoveryMedication(episodeId, values, reason) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Medicine name is required.' };
  if (!values.dosage?.trim()) return { error: 'Dosage is required.' };
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const { data: userData } = await supabase.auth.getUser();
  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    recovery_episode_id: episodeId,
    name: values.name.trim(),
    dosage: values.dosage, frequency: s.frequency, duration: s.duration, eye: values.eye || null,
    sig: composeSig(values.dosage, s.frequency, s.duration),
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
VEDAEOF
echo "Wrote app/(main)/ot-recovery/actions.js"

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/workspace.js" << 'VEDAEOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, addTaperedRecoveryMedication, removeRecoveryMedication, removeRecoveryTaperGroup,
  confirmDischarge, getDrugOptions, getMedDosageOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';
import { openPrintPopup } from '@/lib/printPopup';

// IST "today" as YYYY-MM-DD -- used to default AND cap the discharge
// date input so it can't be mis-entered in the future (a future
// discharge_date isn't a real discharge yet and previously made the
// case vanish from every Recovery/Surgical Journey list -- see actions.js).
function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

const TEMPLATES = {
  cataract: 'Eye drops as prescribed -- Moxifloxacin QID x1wk, Prednisolone QID tapering over 4wks.\nUse eye shield while sleeping for 1 week.\nAvoid bending, lifting heavy objects, and swimming for 2 weeks.\nWarning signs: sudden pain, redness, decreased vision -- contact immediately.\nFollow-up: Day 1, Week 1, Month 1, Final refraction at 4-6 weeks.',
  glaucoma: 'Eye drops as prescribed. Avoid rubbing operated eye.\nAvoid straining, heavy lifting for 4 weeks.\nWarning signs: severe pain, sudden vision loss, excessive redness -- contact immediately.\nFollow-up as scheduled by surgeon.',
};

// Suggested starting point -- Day 1 / Week 1 / Month 1 / Final Refraction
// relative to the chosen discharge date. Purely a default: the doctor
// can rename, redate, remove, or add to this list before confirming
// discharge, since different surgeries need different review schedules.
let planRowSeq = 0;
function defaultFollowupPlan(dischargeDate) {
  const addDays = (n) => { const d = new Date(`${dischargeDate}T00:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  return [
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Day 1', scheduled_date: addDays(1) },
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Week 1', scheduled_date: addDays(7) },
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Month 1', scheduled_date: addDays(30) },
    { key: `p${planRowSeq++}`, visit_label: 'Final Refraction', scheduled_date: addDays(45) },
  ];
}

export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);

  const [admissionDate, setAdmissionDate] = useState('');
  const [surgeryDate, setSurgeryDate] = useState('');
  const [recStart, setRecStart] = useState('');
  const [recEnd, setRecEnd] = useState('');
  const [consciousness, setConsciousness] = useState('Alert');
  const [pain, setPain] = useState('None');
  const [nausea, setNausea] = useState('None');
  const [dressing, setDressing] = useState('Intact, dry');
  const [escalation, setEscalation] = useState(false);
  const [escalationReason, setEscalationReason] = useState('');
  const [observations, setObservations] = useState('');

  const [checklist, setChecklist] = useState({});
  const [dischargeDate, setDischargeDate] = useState(todayIst());

  // Medication entry -- same structured Dosage/Frequency/Duration/Eye
  // fields (plus tapering schedule builder) as the Doctor module's
  // prescription form, instead of a single free-text field.
  const [medName, setMedName] = useState('');
  const [showMedSuggestions, setShowMedSuggestions] = useState(false);
  const [showMedBrowseAll, setShowMedBrowseAll] = useState(false);
  const [medDrugTypeId, setMedDrugTypeId] = useState(null);
  const [medDosage, setMedDosage] = useState('');
  const [medFrequency, setMedFrequency] = useState('BD');
  const [medDuration, setMedDuration] = useState('1 week');
  const [medEye, setMedEye] = useState('BE');
  const [medIsOcular, setMedIsOcular] = useState(true);
  const [medReason, setMedReason] = useState('');
  const [showMedForm, setShowMedForm] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week' },
    { frequency: 'TDS', duration: '1 week' },
    { frequency: 'BD', duration: '1 week' },
    { frequency: 'OD', duration: '1 week' },
  ]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);

  const [unlocked, setUnlocked] = useState(false);

  const [instructions, setInstructions] = useState('');
  const [dischargeNotes, setDischargeNotes] = useState('');
  const [followupPlan, setFollowupPlan] = useState([]);

  const refresh = useCallback(async () => {
    const result = await getRecoveryEpisodeDetail(episodeId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    const e = result.episode;
    setAdmissionDate(e.admission_date || '');
    setSurgeryDate(e.surgery_date || '');
    setRecStart(e.recovery_start || '');
    setRecEnd(e.recovery_end || '');
    setConsciousness(e.consciousness || 'Alert');
    setPain(e.pain_level || 'None');
    setNausea(e.nausea || 'None');
    setDressing(e.dressing_status || 'Intact, dry');
    setEscalation(e.escalation_required || false);
    setEscalationReason(e.escalation_reason || '');
    setObservations(e.observations || '');
    setChecklist(e.discharge_checklist || {});
    setInstructions(e.discharge_instructions || '');
    setDischargeNotes(e.discharge_notes || '');
    setDischargeDate(e.discharge_date || todayIst());
    if (!e.discharge_date) {
      setFollowupPlan((prev) => (prev.length > 0 ? prev : defaultFollowupPlan(e.discharge_date || todayIst())));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); getMedDosageOptions().then(setDosageOptions); }, [episodeId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { episode, sc, intraop, biometryPlans, meds, followups } = data;
  const patient = sc.patients;
  const isDischarged = !!episode.discharge_date;
  const isClosed = !!episode.closure_status;
  // Once discharged, the record is finalized and locked by default --
  // same convention as Biometry, IOL Approval, and Medical Fitness.
  // Explicit unlock is required before any field becomes editable
  // again; a fully Closed episode (Post-Op) can never be unlocked here.
  const isLocked = isDischarged && !isClosed && !unlocked;
  const fieldsDisabled = isClosed || isLocked;

  // Type-ahead for the medicine field -- same matching logic as
  // Consultation's prescription form.
  const medSuggestions = medName.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(medName.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(medName.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectMedDrug(d) {
    setMedName(d.brand);
    setMedDrugTypeId(d.drug_type_id || null);
    // Same logic as Consultation's prescription form -- tablets,
    // capsules, syrups, and injections aren't applied to an eye.
    setMedIsOcular(d.master_drug_types?.is_ocular !== false);
    setMedDosage('');
    setShowMedSuggestions(false);
  }

  // Group rows sharing a taper_group_id into one block, same as
  // Consultation's prescription list -- so a tapering schedule renders
  // and can be removed as one item, not N unrelated medication rows.
  const medItems = [];
  { const seen = new Set();
    meds.forEach((m) => {
      if (m.taper_group_id) {
        if (seen.has(m.taper_group_id)) return;
        seen.add(m.taper_group_id);
        const steps = meds.filter((x) => x.taper_group_id === m.taper_group_id).sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
        medItems.push({ type: 'taper', key: m.taper_group_id, steps });
      } else {
        medItems.push({ type: 'single', key: m.id, row: m });
      }
    });
  }

  function toggleChecklistItem(key) {
    if (fieldsDisabled) return;
    setChecklist((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  const mandatoryTotal = DISCHARGE_ITEMS.filter((i) => i.mandatory).length;
  const mandatoryChecked = DISCHARGE_ITEMS.filter((i) => i.mandatory && checklist[i.key]).length;

  async function handleSave() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveRecoveryFields(episodeId, {
      admission_date: admissionDate || null, surgery_date: surgeryDate || null,
      recovery_start: recStart || null, recovery_end: recEnd || null,
      consciousness, pain_level: pain, nausea, dressing_status: dressing,
      escalation_required: escalation, escalation_reason: escalation ? escalationReason || null : null,
      observations: observations || null, discharge_checklist: checklist,
      discharge_instructions: instructions || null, discharge_notes: dischargeNotes || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Recovery documentation saved.');
  }

  async function handleAddMedicine() {
    setError('');
    if (!medName.trim()) { setError('Drug name is required.'); return; }
    const result = await addRecoveryMedication(episodeId, { name: medName, dosage: medDosage, frequency: medFrequency, duration: medDuration, eye: medIsOcular ? medEye : null }, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowMedForm(false);
    refresh();
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week' }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!medName.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    if (!medDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
    const result = await addTaperedRecoveryMedication(episodeId, { name: medName, dosage: medDosage, eye: medIsOcular ? medEye : null, steps: taperSteps }, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedDosage(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowTaperBuilder(false);
    refresh();
  }

  function updatePlanRow(key, field, value) {
    setFollowupPlan((prev) => prev.map((r) => (r.key === key ? { ...r, [field]: value } : r)));
  }

  function removePlanRow(key) {
    setFollowupPlan((prev) => prev.filter((r) => r.key !== key));
  }

  function addPlanRow() {
    setFollowupPlan((prev) => [...prev, { key: `p${planRowSeq++}`, visit_label: '', scheduled_date: dischargeDate }]);
  }

  function resetPlanToDefault() {
    setFollowupPlan(defaultFollowupPlan(dischargeDate));
  }

  async function handleDischarge() {
    setError(''); setOk('');
    if (!dischargeDate) { setError('Discharge date is required.'); return; }
    const result = await confirmDischarge(episodeId, checklist, dischargeNotes, instructions, dischargeDate, followupPlan);
    if (result.error) { setError(result.error); return; }
    // Opened as a deep link from Surgical Journey (a real opener window
    // exists) -- signal completion back and close this tab. Same
    // close-on-complete pattern as IOL Approval, Medical Fitness,
    // Patient Check-In, and Intraoperative Management.
    if (typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'recovery-updated', episodeId }, window.location.origin);
      window.close();
      return;
    }
    setOk('Patient discharged. Discharge summary is ready to print. Follow-up schedule generated.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Episode Closed' : isDischarged ? 'Discharged' : 'Recovery'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      {isLocked && (
        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-lock"></i>
          <span style={{ flex: 1 }}>This record is finalized (discharged) and locked for viewing.</span>
          <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
            <i className="ti ti-lock-open"></i> Edit
          </button>
        </div>
      )}
      {isDischarged && !isClosed && unlocked && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-edit"></i>
          <span style={{ flex: 1 }}>Editing a discharged record. Changes are saved immediately.</span>
          <button className="btn btn-sm" onClick={() => { setUnlocked(false); refresh(); }}>
            <i className="ti ti-lock"></i> Lock again
          </button>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          {/* Surgical summary read-only */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" max={todayIst()} value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            {biometryPlans.map((p) => (
              <div key={p.eye} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>Implanted IOL ({p.eye})</span><strong style={{ color: 'var(--indigo)', fontFamily: 'monospace', fontSize: 11 }}>{intraop?.implant_power || p.power} D -- {p.master_iol_catalog?.category}</strong>
              </div>
            ))}
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
              <span style={{ color: 'var(--g500)' }}>Surgical outcome</span>
              <span className="badge b-green" style={{ fontSize: 10 }}>{intraop?.surgical_outcome || '--'}</span>
            </div>
          </div>

          {/* Recovery assessment */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--teal)' }}></i> Recovery Assessment</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={fieldsDisabled} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={fieldsDisabled}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={fieldsDisabled}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={fieldsDisabled}><option>No</option><option>Yes</option></select></div>
            </div>
            {escalation && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Escalation reason</label>
                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={fieldsDisabled} placeholder="Document reason for escalation..." />
              </div>
            )}
            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={fieldsDisabled} placeholder="Clinical observations / immediate concerns..." />
          </div>

          {/* Discharge checklist */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--green)' }}></i> Discharge Readiness Checklist</div>
              <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
            </div>
            {DISCHARGE_ITEMS.map((item) => (
              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: fieldsDisabled ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          {/* Medications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
              Same drug catalog, dosage, frequency, and tapering options as the Doctor module's prescription form.
            </div>
            {medItems.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
            {medItems.map((item) => (
              item.type === 'single' ? (
                <div key={item.key} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                  <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
                  <span style={{ flex: 1 }}><strong>{item.row.name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration}{item.row.eye ? ` -- ${item.row.eye}` : ''}</span>
                  {!fieldsDisabled && <button onClick={() => removeRecoveryMedication(item.row.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
                </div>
              ) : (
                <div key={item.key} style={{ padding: '6px 8px', background: 'var(--purple-lt)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
                    <strong>{item.steps[0].name}</strong> -- {item.steps[0].dosage}{item.steps[0].eye ? ` -- ${item.steps[0].eye}` : ''}
                    <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering</span>
                    {!fieldsDisabled && <button onClick={() => removeRecoveryTaperGroup(item.key).then(refresh)} style={{ marginLeft: 'auto', border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>
                    {item.steps.map((s, i) => (
                      <span key={s.id}>{i > 0 && ' -> '}{s.frequency} x {s.duration}</span>
                    ))}
                    <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
                  </div>
                </div>
              )
            ))}

            {!fieldsDisabled && (
              <div style={{ marginTop: 8 }}>
                {!showMedForm ? (
                  <button className="btn btn-sm btn-primary" onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                ) : (
                  <div>
                    <div style={{ position: 'relative', marginBottom: 6 }}>
                      <input
                        className="fi fi-sm" style={{ width: '100%' }}
                        placeholder="Type to search medicines, or enter a new name"
                        value={medName}
                        onChange={(e) => { setMedName(e.target.value); setMedDrugTypeId(null); setMedIsOcular(true); setShowMedSuggestions(true); }}
                        onFocus={() => setShowMedSuggestions(true)}
                        onBlur={() => setTimeout(() => setShowMedSuggestions(false), 150)}
                      />
                      {showMedSuggestions && medName.trim().length > 0 && (
                        <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 200, overflowY: 'auto', marginTop: 3 }}>
                          {medSuggestions.length > 0 ? medSuggestions.map((d) => (
                            <div key={d.id} onMouseDown={() => selectMedDrug(d)} style={{ padding: '7px 10px', cursor: 'pointer', fontSize: 12, borderBottom: '1px solid var(--g100)' }}>
                              <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
                            </div>
                          )) : (
                            <div style={{ padding: '7px 10px', fontSize: 11.5, color: 'var(--g500)' }}>
                              No match.{' '}
                              <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 10.5 }} onMouseDown={() => { setShowMedBrowseAll(true); setShowMedSuggestions(false); }}>Browse full list</button>
                              {' '}or keep typing for free text.
                            </div>
                          )}
                        </div>
                      )}
                      {showMedBrowseAll && (
                        <select className="fi fi-sm" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
                          if (!e.target.value) return;
                          const picked = drugOptions.find((d) => d.brand === e.target.value);
                          if (picked) selectMedDrug(picked);
                          setShowMedBrowseAll(false);
                        }}>
                          <option value="">-- Browse full Pharmacy master --</option>
                          {drugOptions.map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                        </select>
                      )}
                    </div>

                    <div style={{ display: 'grid', gridTemplateColumns: medIsOcular ? '1fr 1fr' : '1fr', gap: 6, marginBottom: 6 }}>
                      <select className="fi fi-sm" value={medDosage} onChange={(e) => setMedDosage(e.target.value)}>
                        <option value="">-- Dosage --</option>
                        {(medDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === medDrugTypeId) : []).map((o) => (
                          <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                        ))}
                        {!medDrugTypeId && (
                          <>
                            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                          </>
                        )}
                      </select>
                      {medIsOcular && (
                        <select className="fi fi-sm" value={medEye} onChange={(e) => setMedEye(e.target.value)}>
                          <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                        </select>
                      )}
                    </div>
                    {!medIsOcular && (
                      <div style={{ fontSize: 10, color: 'var(--g400)', marginBottom: 6 }}><i className="ti ti-info-circle"></i> {medName} is not applied to the eye -- no Eye field needed.</div>
                    )}

                    {!showTaperBuilder ? (
                      <>
                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                          <select className="fi fi-sm" value={medFrequency} onChange={(e) => setMedFrequency(e.target.value)}>
                            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                          </select>
                          <select className="fi fi-sm" value={medDuration} onChange={(e) => setMedDuration(e.target.value)}>
                            <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                          </select>
                        </div>
                        <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginBottom: 6 }} onClick={() => setShowTaperBuilder(true)}>
                          <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                        </button>
                      </>
                    ) : (
                      <div style={{ marginBottom: 6, padding: 10, background: 'var(--purple-lt)', borderRadius: 8 }}>
                        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--purple)', marginBottom: 6 }}>
                          <i className="ti ti-chart-line"></i> Tapering -- uses the Drug &amp; Dosage{medIsOcular ? ' & Eye' : ''} above; frequency reduces step by step
                        </div>
                        {taperSteps.map((s, i) => (
                          <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 5 }}>
                            <span style={{ fontSize: 10.5, color: 'var(--g500)', width: 14 }}>{i + 1}.</span>
                            <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 90 }}>
                              <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                            </select>
                            <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 100 }}>
                              <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
                            </select>
                            {taperSteps.length > 2 && (
                              <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
                            )}
                          </div>
                        ))}
                        <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                      </div>
                    )}

                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6, width: '100%' }} />

                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-sm btn-primary" onClick={showTaperBuilder ? handleAddTaperSchedule : handleAddMedicine}>
                        {showTaperBuilder ? 'Save Tapering Schedule' : 'Add'}
                      </button>
                      <button className="btn btn-sm" onClick={() => { setShowMedForm(false); setShowTaperBuilder(false); }}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Discharge instructions */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
            </div>
            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={fieldsDisabled} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
          </div>

          {/* Discharge notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={fieldsDisabled} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
          </div>

          {/* Follow-up schedule */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Follow-up Schedule</div>
              {!isDischarged && (
                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={resetPlanToDefault}>Reset to standard schedule</button>
              )}
            </div>
            {!isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                Suggested reviews below -- edit the label/date, remove any that don't apply, or add your own before discharging.
              </div>
            )}

            {!isDischarged && followupPlan.map((f) => (
              <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', borderBottom: '1px solid var(--g100)' }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={f.visit_label} onChange={(e) => updatePlanRow(f.key, 'visit_label', e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 130 }} value={f.scheduled_date} onChange={(e) => updatePlanRow(f.key, 'scheduled_date', e.target.value)} />
                <button onClick={() => removePlanRow(f.key)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 16, padding: '0 4px' }} title="Remove this review">&times;</button>
              </div>
            ))}
            {!isDischarged && followupPlan.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No reviews planned -- add one below if needed, or leave empty if none are required.</div>
            )}
            {!isDischarged && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={addPlanRow}><i className="ti ti-plus"></i> Add review</button>
            )}

            {isDischarged && followups.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No reviews were scheduled at discharge.</div>}
            {isDischarged && followups.map((f) => (
              <div key={f.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ fontWeight: 600 }}>{f.visit_label}</span>
                <span style={{ color: 'var(--g500)' }}>{new Date(f.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                <span className={`badge ${f.status === 'Completed' ? 'b-green' : f.status === 'Due' ? 'b-red' : 'b-blue'}`} style={{ fontSize: 10 }}>{f.status}</span>
              </div>
            ))}
            {isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
                Reviews can be added or removed from the Post-op page as requirements change.
              </div>
            )}
          </div>
        </div>
      </div>

      {!isClosed && (
        <div style={{ background: '#0f172a', borderRadius: 12, padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
          <span style={{ fontSize: 11, color: '#64748b', fontWeight: 600 }}>ACTIONS:</span>
          {isLocked ? (
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => setUnlocked(true)}>
              <i className="ti ti-lock-open"></i> Unlock to Edit
            </button>
          ) : (
            <>
              <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
              </button>
              {!isDischarged && (
                <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
                  <i className="ti ti-door-exit"></i> Discharge
                </button>
              )}
              {isDischarged && (
                <button onClick={() => openPrintPopup(`/discharge-summary-print/${episodeId}`)} className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)' }}>
                  <i className="ti ti-printer"></i> Print Discharge Summary
                </button>
              )}
              {isDischarged && (
                <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
                  <i className="ti ti-circle-check"></i> Discharged
                </span>
              )}
              {isDischarged && unlocked && (
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => { setUnlocked(false); refresh(); }}>
                  <i className="ti ti-lock"></i> Lock again
                </button>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}
VEDAEOF
echo "Wrote app/(main)/ot-recovery/workspace.js"

echo 'Running next build to verify...'
npm run build

echo 'Build succeeded. Staging and committing...'
git add "app/(main)/surgical-journey/actions.js" "app/(main)/ot-recovery/actions.js" "app/(main)/ot-recovery/workspace.js"
git commit -m "Fix: future-dated discharge_date made cases vanish from Surgical Journey and Recovery (Active/Discharged Today/History all excluded it); cap discharge date input at today"
git push

echo 'Done. Deployed via Vercel auto-deploy on push to main.'
