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

  // Everything below only depends on fields already on `sc` (patient_id,
  // encounter_id, or just caseId) -- none of these seven depend on each
  // other's results, so they run as one parallel wave instead of one
  // after another. This was the main reason opening a surgical case felt
  // slow: 8 fully sequential round trips, now 2 waves.
  const [
    { data: biometryRecords },
    inHouseInvestigations,
    { data: otSchedule },
    { data: fitnessReferral },
    { data: iolApproval },
    externalTests,
    advanceBalance,
  ] = await Promise.all([
    // Biometry is patient-level now, not case-scoped -- reused across
    // every future surgical case for that patient (readings don't
    // meaningfully change for years). No more per-eye/per-case matching
    // needed; just look up whatever's on file for this patient.
    supabase
      .from('biometry_records')
      .select('id, status, verify_remarks, verified_at')
      .eq('patient_id', sc.patient_id)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false }),

    // In-house investigations -- ordered against this case's own
    // consultation encounter, same investigation_orders table Doctor
    // Consultation uses and the same Investigation module queue picks
    // them up from. Fully generic -- Biometry shows up here too now,
    // same as anything else (whatever the doctor feels like), not a
    // separate hardcoded section.
    sc.encounter_id
      ? supabase.from('investigation_orders').select('*').eq('encounter_id', sc.encounter_id).order('created_at', { ascending: false }).then((r) => r.data || [])
      : Promise.resolve([]),

    // Day-of-surgery live status -- OT Schedule / Intraop / Recovery
    // already have solid, tested clinical workflows; this page doesn't
    // rebuild them, it just shows where the case currently stands and
    // deep-links into whichever one applies.
    supabase
      .from('ot_schedule')
      .select('id, scheduled_date, status, master_ot_sessions(name)')
      .eq('surgical_case_id', caseId)
      .order('scheduled_date', { ascending: false })
      .limit(1)
      .maybeSingle(),

    // Medical fitness stays a real doctor referral/review, same as
    // Counselling -- this isn't a rubber-stamp checkbox, so it keeps its
    // own dedicated review step rather than being folded into a form
    // field here.
    supabase
      .from('medical_fitness_referrals')
      .select('id, status, referred_at, fitness_notes')
      .eq('surgical_case_id', caseId)
      .order('referred_at', { ascending: false })
      .limit(1)
      .maybeSingle(),

    // The surgeon's final IOL choice -- separate module/step from both
    // Biometry (raw device recommendations) and this page's own package
    // selection (billing category only).
    supabase.from('iol_approvals').select('*, master_iol_catalog(brand, model, category)').eq('surgical_case_id', caseId).maybeSingle(),

    getExternalTestsForCase(caseId),

    // Payment step (M11's held advance balance, live) -- checked against
    // the net package amount (price - discount) rather than the old
    // never-actually-set advance_payment_id flag. See workspace.js.
    sc.patient_id ? getAdvanceBalance(sc.patient_id) : Promise.resolve(0),
  ]);

  // recoveryEpisode and checkinCompletedAt both depend on otSchedule.id,
  // so this second wave only fires once the first wave (which produced
  // otSchedule) has resolved -- still just 2 waves total, not 8 steps.
  let recoveryEpisode = null;
  let checkinCompletedAt = null;
  if (otSchedule) {
    const [{ data: episode }, { data: intraopRecord }] = await Promise.all([
      supabase.from('recovery_episodes').select('id, discharge_date').eq('ot_schedule_id', otSchedule.id).maybeSingle(),
      supabase.from('ot_intraop_records').select('checkin_completed_at').eq('ot_schedule_id', otSchedule.id).maybeSingle(),
    ]);
    recoveryEpisode = episode;
    checkinCompletedAt = intraopRecord?.checkin_completed_at || null;
  }

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
