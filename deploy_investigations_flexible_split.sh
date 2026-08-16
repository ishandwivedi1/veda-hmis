#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
#
# Three Surgical Journey changes:
#
# DB change ALREADY applied to both production (flzysyzhaecaqbmdcuao)
# and training (ffaddzpwnbizhvhujlse) -- surgical_cases got a new
# decision_accepted_at column. No SQL to run manually.
#
# 1) The case header now shows "Advised: [date]" (surgical_cases.
#    created_at) above Patient Decision -- already structurally above
#    it, just needed the date added.
#
# 2) Patient Decision now locks in the actual date the patient said
#    yes, stamped once the first time decision transitions to
#    Accepted (not overwritten on later saves, including re-saving
#    Accepted again). Shown as "Accepted on [date] -- locked." setDecision
#    is shared across Counselling, Doctor Consultation, and Surgical
#    Journey, so this works everywhere the decision gets set.
#
# 3) Investigations restructured to be flexible, not a fixed required
#    panel -- split into three parts:
#      - Biometry: unchanged, still its own dedicated patient-level flow.
#      - In-House Investigations: NEW -- add any investigation from the
#        same master list Doctor Consultation uses, routes through the
#        real investigation_orders table and Investigation module queue.
#        Each shows a status badge and a "View Report" button once
#        available.
#      - External Investigations: upload reports done elsewhere,
#        whenever they come back, view anytime -- no required workflow
#        around it. This absorbs the old standalone "Reports" step
#        (same entity_type, same attachments, nothing lost), which is
#        now removed since it was a near-duplicate. Stepper renumbered
#        9 steps instead of 10 accordingly.
#
# Also fixed in passing: getInvestigationMasterOptions (used by Medical
# Fitness'"'"'s own investigation picker) had a stale filter excluding
# anything with "biometry" in its name -- a leftover from before Biometry
# was renamed from "Biometry (Procedure Charge)" to just "Biometry",
# which meant the filter now incorrectly excluded the correctly-named
# entry too. Removed.
#
# All 19 imports across the touched files individually cross-checked
# against their real source functions before packaging, and the new
# investigation_orders/encounter_audit_log columns confirmed against
# the live training schema.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/counselling"
cat > "app/(main)/counselling/actions.js" << 'FILEEOF_counselling_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';

// This file replaces the old "Surgical Coordination" module's actions file.
// Booking an OT slot is the last step of the counselling workspace (see
// bookOTSlot/getOTAvailability below). The calendar view itself, plus
// rescheduling and OT History, now live in their own module at
// app/(main)/ot-schedule (getScheduledOT/getOTHistory/rescheduleOTSlot/
// completeOT), not here.
// The following exports are used by OTHER modules and MUST keep the same
// name + signature:
//   markForSurgery, updateSurgicalCase
//     -- imported by app/(main)/consultation/[id]/consultation-form.js
// Everything else below is used only within the Counselling module.

// ── Sending a patient to an ancillary service (Biometry, Dilation, ...)
//    from Counselling. Once a doctor completes a consultation, ALL of
//    that visit's queue_entries get marked 'Done' -- so by the time a
//    case reaches Counselling (even same-day), there's nothing left to
//    "update". send_case_to_department_queue() (see migration 027)
//    issues a FRESH queue token against the patient's still-open visit
//    (found via ist_date(), so it's IST-correct rather than doing UTC
//    date math here) and flips it straight to the target status.
async function sendCaseToQueueStatus(caseId, queueStatus, auditMessage) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: queueStatus,
    p_audit_message: auditMessage,
    p_user_id: userData?.user?.id || null,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForBiometry(caseId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('id, patient_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: queueEntry, error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: 'Awaiting Biometry',
    p_audit_message: 'Sent for Biometry (from Counselling)',
    p_user_id: userData?.user?.id || null,
  });
  if (error) return { error: error.message };

  // Biometry is patient-level and reused across every future surgical
  // case (readings don't meaningfully change for years) -- ensure a
  // record exists for this PATIENT, not this case. If one already
  // exists (from an earlier case, or a plain OPD order), there's
  // nothing more to do here -- it'll get mapped to this case at IOL
  // Approval time.
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', sc.patient_id)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    await supabase.from('biometry_records').insert({
      patient_id: sc.patient_id, visit_id: queueEntry?.visit_id || null, encounter_id: sc.encounter_id || null,
    });
  }

  return { success: true };
}

// For surgeries where biometry genuinely doesn't apply (retina,
// glaucoma, oculoplasty...) -- a reason is required so there's an
// audit trail for why this case skipped a normally-required step.
export async function skipBiometry(caseId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required to skip Biometry.' };
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: false, biometry_skip_reason: reason.trim() })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Undo a skip -- puts Biometry back as a required step for this case.
export async function unskipBiometry(caseId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: true, biometry_skip_reason: null })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForDilation(caseId) {
  return sendCaseToQueueStatus(caseId, 'Awaiting Dilation', 'Sent for Dilation (from Counselling)');
}

// ── Case creation (called from Consultation when doctor recommends surgery) ──
// Doctor can correct the procedure/eye on a case they marked for
// surgery, as long as Counselling hasn't already started working with
// it -- once package/decision work is underway, changes should go
// through Counselling instead to avoid corrupting what's already locked.
export async function updateSurgicalCase(caseId, procedureName, eye, preOpRequired, notes) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Pending Workup') {
    return { error: `This case has already moved to "${sc.status}" -- further changes should go through Counselling.` };
  }
  const update = { procedure_name: procedureName, eye, notes: notes || null };
  if (preOpRequired !== undefined) {
    update.biometry_required = preOpRequired === 'Biometry' || preOpRequired === 'Both';
    update.fitness_required = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';
  }
  const { error } = await supabase.from('surgical_cases').update(update).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes, decision) {
  const supabase = await createClient();

  if (decision && !DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };

  // Pull surgeon + visit + priority through so the case doesn't start
  // with everything null -- encounters already carries doctor_id.
  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  // BR: one visit, one surgical case -- checked against visit_id (not
  // just this encounter), since a visit can span more than one
  // encounter (e.g. consultation reopened) and the case should still
  // only be created once.
  if (encounter?.visit_id) {
    const { data: existing } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye')
      .eq('visit_id', encounter.visit_id)
      .neq('status', 'Cancelled')
      .limit(1);
    if (existing && existing.length > 0) {
      return { error: `This visit already has a surgical case marked (${existing[0].procedure_name} -- ${existing[0].eye}). Only one is allowed per visit.` };
    }
  }

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  // Doctor's call on what pre-op workup this case actually needs --
  // carried forward to Counselling, which reads biometry_required /
  // fitness_required the same way for both (see readiness() and
  // markReadyForScheduling).
  const biometryRequired = preOpRequired === 'Biometry' || preOpRequired === 'Both';
  const fitnessRequired = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';

  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: procedureName,
    eye,
    priority,
    biometry_required: biometryRequired,
    fitness_required: fitnessRequired,
    notes: notes || null,
    // Patient's initial reaction, captured right here in OPD -- the
    // FIRST step of the surgical journey now, not something deferred to
    // Counselling. 'Accepted' locks immediately (matches setDecision's
    // own locking rule); anything else stays open for front desk to
    // update once the patient calls back, no reason required for that
    // first change.
    decision: decision || null,
    decision_locked: decision === 'Accepted',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Cases list for the Counselling workspace (richer -- surgeon, decision, IOL type) ──
export async function getCounsellingCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender, mobile ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];

  // surgical_cases.biometry_done is a stored flag that (pre-existing
  // gap, found while redesigning Biometry) nothing in this codebase
  // ever actually SET -- it was always false unless biometry was
  // explicitly skipped, silently blocking package selection. Computed
  // live here instead: biometry is patient-level now (reused across
  // cases), so "done" means this PATIENT has a Measured record, not
  // anything scoped to this case's encounter.
  const patientIds = [...new Set((data || []).map((c) => c.patient_id).filter(Boolean))];
  let measuredByPatient = {};
  if (patientIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('id, patient_id, status')
      .in('patient_id', patientIds)
      .eq('status', 'Measured');
    (records || []).forEach((r) => { measuredByPatient[r.patient_id] = r; });
  }
  let anyRecordByPatient = {};
  if (patientIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('id, patient_id, status')
      .in('patient_id', patientIds)
      .neq('status', 'Cancelled');
    (records || []).forEach((r) => { if (!anyRecordByPatient[r.patient_id]) anyRecordByPatient[r.patient_id] = r; });
  }

  // Same batching pattern for the medical fitness referral -- one per
  // case at most (re-referring resets the same row rather than piling
  // up history), so a simple map by surgical_case_id is enough.
  const caseIds = (data || []).map((c) => c.id);
  let fitnessByCase = {};
  if (caseIds.length > 0) {
    const { data: referrals } = await supabase
      .from('medical_fitness_referrals')
      .select('id, surgical_case_id, status, referred_at, fitness_notes')
      .in('surgical_case_id', caseIds);
    (referrals || []).forEach((r) => { fitnessByCase[r.surgical_case_id] = r; });
  }

  return (data || []).map((c) => ({
    ...c,
    biometry_done: !!measuredByPatient[c.patient_id],
    biometry_record: anyRecordByPatient[c.patient_id] || null,
    fitness_referral: fitnessByCase[c.id] || null,
  }));
}

// ── History -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled). Read-only lookup, same underlying data shape
//    as getCounsellingCases minus the biometry/fitness batching, which
//    only matters for cases still in active workup. ──
export async function getCounsellingHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .not('status', 'in', '("Pending Workup","Ready for Scheduling")')
    .order('created_at', { ascending: false })
    .limit(300);
  if (error) return [];
  return data || [];
}

// ── Packages for a case ──
// Previously filtered by the IOL category advised at Biometry -- but
// surgical_cases.iol_category was never actually written anywhere in
// this codebase (a pre-existing gap), so this filter was silently
// hiding every IOL-specific package from the picker the whole time.
// Under the new model, IOL category is chosen alongside the package
// here in Counselling (informed by whatever biometry recommends), and
// formally confirmed later as its own step in IOL Approval -- there
// isn't a single upstream "the" category to filter by before that
// choice is made. Shows everything active; iolCategory is accepted for
// API compatibility but currently unused.
export async function getPackagesForCase(iolCategory) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return data || [];
}

// ── Package selection (BR-SCC-002: only after Biometry & IOL advice) ──
export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('patient_id, biometry_required').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.biometry_required !== false) {
    const { count } = await supabase
      .from('biometry_records')
      .select('id', { count: 'exact', head: true })
      .eq('patient_id', sc.patient_id)
      .eq('status', 'Measured');
    if (!count) return { error: 'BR-SCC-002: Biometry must be complete before selecting a package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId, package_locked: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Changing a package once it's locked needs a reason -- logged as a
// counselling note so there's an audit trail for why it changed.
export async function changePackage(caseId, reason) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('package_locked, master_packages:package_id(name)').eq('id', caseId).single();
  if (sc?.package_locked && (!reason || !reason.trim())) {
    return { error: 'A reason is required to change a locked package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: null, package_locked: false }).eq('id', caseId);
  if (error) return { error: error.message };

  if (sc?.package_locked && reason) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Package unlocked and changed${sc.master_packages?.name ? ` (was: ${sc.master_packages.name})` : ''} -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }
  return { success: true };
}

// ── Patient decision ──
const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

export async function setDecision(caseId, decision, reason) {
  if (!DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('decision, decision_locked').eq('id', caseId).single();

  if (sc?.decision_locked && decision !== sc.decision) {
    if (!reason || !reason.trim()) {
      return { error: 'A reason is required to change a locked decision.' };
    }
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Decision unlocked and changed from "${sc.decision}" to "${decision}" -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  const update = {
    decision, decision_reason: reason || null,
    decision_locked: decision === 'Accepted',
  };
  // Stamped once, the first time this transitions to Accepted -- not
  // touched on any other save, including re-saving Accepted again, so
  // it reflects the actual date the patient said yes, not the last
  // time this row happened to be updated.
  if (decision === 'Accepted' && sc?.decision !== 'Accepted') {
    update.decision_accepted_at = new Date().toISOString();
  }

  const { error } = await supabase.from('surgical_cases').update(update).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Counselling notes log ──
export async function getCaseNotes(caseId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_case_notes')
    .select('id, note, created_at, profiles:created_by ( id, full_name )')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function addCaseNote(caseId, note) {
  if (!note || !note.trim()) return { error: 'Note cannot be empty.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: note.trim(),
    created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Patient education topics (populated by the doctor's plan, M17/M19) ──
export async function getCounsellingItems(encounterId) {
  if (!encounterId) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_counselling_items')
    .select('id, topic, status')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: true });
  if (error) return [];
  return data;
}

export async function toggleCounsellingItem(itemId, done) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').update({ status: done ? 'Done' : 'Pending' }).eq('id', itemId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Post-decision checklist (BR-SCC-004: only after package + Accepted) ──
async function requirePostDecision(supabase, caseId) {
  const { data: sc } = await supabase.from('surgical_cases').select('package_id, decision').eq('id', caseId).single();
  if (!(sc?.package_id && sc.decision === 'Accepted')) {
    return 'BR-SCC-004: Package must be confirmed and the patient decision must be Accepted first.';
  }
  return null;
}

// ── PRE-OP INVESTIGATIONS (usually blood work) ──
// Same master list Consultation's investigation picker uses (dept =
// Investigation in Financial Masters, Biometry excluded since that's
// its own dedicated step above) -- so an order placed here is the same
// kind of thing a doctor orders during a regular consultation, and
// lands in the same Investigation module queue for the lab to process.
export async function getInvestigationMasterOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

// Distinct standard panels (e.g. "Cataract" -> Blood, Sugar, HIV...)
// set up in Financial Masters against Investigation services, so
// Counselling can order a whole panel in one action instead of one
// investigation at a time.
export async function getInvestigationPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('investigation_package').eq('status', 'Active').eq('dept', 'Investigation').not('investigation_package', 'is', null);
  return [...new Set((data || []).map((s) => s.investigation_package).filter(Boolean))].sort();
}

export async function orderInvestigationPackage(caseId, encounterId, packageName) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!packageName) return { error: 'Select a package.' };

  const { data: services, error: svcError } = await supabase
    .from('master_services')
    .select('name')
    .eq('status', 'Active')
    .eq('dept', 'Investigation')
    .eq('investigation_package', packageName);
  if (svcError) return { error: svcError.message };
  if (!services || services.length === 0) return { error: 'No investigations found for this package.' };

  const { error } = await supabase.from('investigation_orders').insert(
    services.map((s) => ({ encounter_id: encounterId, name: s.name, eye: 'N/A', priority: 'Routine' }))
  );
  if (error) return { error: error.message };
  return { success: true, count: services.length };
}

export async function getCounsellingInvestigationOrders(encounterId) {
  const supabase = await createClient();
  if (!encounterId) return [];
  const { data } = await supabase
    .from('investigation_orders')
    .select('*')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function orderCounsellingInvestigation(caseId, encounterId, values) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!values.name?.trim()) return { error: 'Select or enter an investigation.' };

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye || 'OU',
    priority: values.priority || 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeCounsellingInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationsComplete(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ investigations_complete: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFitnessCleared(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Medical fitness is no longer self-certified by the counsellor --
// it's referred to a doctor, who reviews clinical data, orders any
// investigations needed, and clears (or doesn't) via the Medical
// Fitness Dashboard/Workspace. This creates that referral, or -- if
// the case was previously marked Not Fit -- resets the same row back
// to Pending Review rather than creating a duplicate.
export async function referForMedicalFitness(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };

  const { data: sc } = await supabase.from('surgical_cases').select('visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: userData } = await supabase.auth.getUser();
  const { data: existing } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0 && existing[0].status === 'Pending Review') {
    return { error: 'Already referred and awaiting doctor review.' };
  }

  if (existing && existing.length > 0 && existing[0].status === 'Not Fit') {
    const { error } = await supabase.from('medical_fitness_referrals').update({
      status: 'Pending Review', referred_by: userData?.user?.id || null, referred_at: new Date().toISOString(),
      reviewing_doctor_id: null, fitness_notes: null, cleared_by: null, cleared_at: null,
    }).eq('id', existing[0].id);
    if (error) return { error: error.message };
    return { success: true };
  }

  const { error } = await supabase.from('medical_fitness_referrals').insert({
    surgical_case_id: caseId, visit_id: sc.visit_id, encounter_id: sc.encounter_id, referred_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Ready for Scheduling ──
// NOTE: this intentionally does NOT require consent_taken. Per BR-SCC-005,
// consent is taken day-of-surgery (day-care model), not a pre-scheduling
// gate here -- that belongs to the Intraoperative module (M25). This is a
// behavior change from the previous version of this function, which did
// require consent_taken.
export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  if (sc.biometry_required !== false) {
    const { count } = await supabase
      .from('biometry_records')
      .select('id', { count: 'exact', head: true })
      .eq('patient_id', sc.patient_id)
      .eq('status', 'Measured');
    if (!count) return { error: 'VAL-SCC-002: Biometry must be complete.' };

    // Can't book an OT slot without knowing which specific IOL is going
    // in -- that's the surgeon's IOL Approval, a separate step/module
    // from both Biometry (raw device recommendations) and this package
    // selection (billing category only).
    const { data: approval } = await supabase.from('iol_approvals').select('status').eq('surgical_case_id', caseId).maybeSingle();
    if (approval?.status !== 'Approved') return { error: 'VAL-SCC-002: Surgeon IOL Approval must be complete.' };
  }
  if (!sc.package_id) return { error: 'VAL-SCC-002: Select a package first.' };
  if (sc.decision !== 'Accepted') return { error: 'VAL-SCC-002: Patient decision must be Accepted.' };
  if (!sc.fitness_cleared && sc.fitness_required !== false) return { error: 'VAL-SCC-002: Medical fitness must be cleared.' };

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function referBackToDoctor(caseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ status: 'Pending Workup' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Surgeons ──
export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').eq('designation', 'Doctor').eq('status', 'Active');
  return data || [];
}

// ── OT Booking -- last step of the Counselling workspace. Availability is
//    checked against master_ot_sessions.capacity (Financial Masters -- OT
//    Sessions), not free-form date/time like the old standalone OT
//    Scheduling module. Capacity check + insert happen atomically in the
//    book_ot_slot() DB function (see migration ot_booking_functions) so two
//    counsellors booking the same session at once can't both overbook it. ──
export async function getOTAvailability(date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_ot_availability', { p_date: date });
  if (error) return [];
  return data || [];
}

export async function bookOTSlot(caseId, date, sessionId, surgeonId, notes) {
  const supabase = await createClient();
  if (!date) return { error: 'Date is required.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data, error } = await supabase.rpc('book_ot_slot', {
    p_case_id: caseId,
    p_date: date,
    p_session_id: sessionId,
    p_surgeon_id: surgeonId || null,
    p_notes: notes || null,
  });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { success: true };
}



FILEEOF_counselling_actions_js

mkdir -p "app/(main)/surgical-journey"
cat > "app/(main)/surgical-journey/actions.js" << 'FILEEOF_surgical_journey_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { adviseBiometry } from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/counselling/actions';

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
// a fixed required panel. Routes through the same investigation_orders
// table and Investigation module queue Doctor Consultation uses.
// "Further investigations for a surgical case go through the surgery
// module" -- this is that entry point, not a trip back to Consultation.
export async function getInvestigationOptionsForCase() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation').neq('name', 'Biometry');
  return data || [];
}

export async function addInHouseInvestigationForCase(caseId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Select an investigation.' };

  const { data: sc } = await supabase.from('surgical_cases').select('encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!sc.encounter_id) return { error: 'This case has no linked consultation encounter to attach investigations to.' };

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: sc.encounter_id, name: name.trim(), eye: eye || 'OU', priority: 'Routine',
  });
  if (error) return { error: error.message };

  await supabase.from('encounter_audit_log').insert({
    encounter_id: sc.encounter_id,
    message: `Investigation ordered from Surgical Journey: ${name.trim()} (${eye || 'OU'})`,
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

// Every open surgical case (any staff member -- a small setup doesn't
// have per-doctor case ownership walls). "Open" = not yet Completed or
// Cancelled.
export async function getMyActiveSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: false });
  if (error) return [];
  return data || [];
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
  // them up from. Biometry is excluded here (it's patient-level and
  // handled entirely separately above -- has its own dedicated flow,
  // not a plain in-house investigation).
  let inHouseInvestigations = [];
  if (sc.encounter_id) {
    const { data } = await supabase
      .from('investigation_orders')
      .select('*')
      .eq('encounter_id', sc.encounter_id)
      .neq('name', 'Biometry')
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
  if (otSchedule) {
    const { data } = await supabase
      .from('recovery_episodes')
      .select('id, discharge_date')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    recoveryEpisode = data;
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

  const { data: caseNotes } = await supabase
    .from('surgical_case_notes')
    .select('*, profiles:created_by(full_name)')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });

  // The surgeon's final IOL choice -- separate module/step from both
  // Biometry (raw device recommendations) and this page's own package
  // selection (billing category only).
  const { data: iolApproval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  return {
    case: { ...sc, biometry_done: biometryRecords.some((b) => b.status === 'Measured') },
    biometryRecords,
    inHouseInvestigations,
    fitnessReferral: fitnessReferral || null,
    iolApproval: iolApproval || null,
    otSchedule: otSchedule || null,
    recoveryEpisode,
    caseNotes: caseNotes || [],
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
FILEEOF_surgical_journey_actions_js

mkdir -p "app/(main)/surgical-journey/[id]"
cat > "app/(main)/surgical-journey/[id]/workspace.js" << 'FILEEOF_surgical_journey_id_workspace_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import {
  getSurgicalCaseDetail, orderBiometryForCase,
  setIolOrderNotes, editSurgicalCaseDetails, setTreatmentInstructions,
  getInvestigationOptionsForCase, addInHouseInvestigationForCase, removeInHouseInvestigationForCase,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, getPackagesForCase,
  setDecision, referForMedicalFitness, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
} from '@/app/(main)/counselling/actions';
import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

// ── HEADER (editable) ──────────────────────────────────────────────
function CaseHeader({ sc, patient, onAction }) {
  const [editing, setEditing] = useState(false);
  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState(sc.procedure_name);
  const [eye, setEye] = useState(sc.eye || 'OD');
  const [reason, setReason] = useState('');
  const [instructions, setInstructions] = useState(sc.treatment_instructions || '');
  const [savingInstructions, setSavingInstructions] = useState(false);
  const progressed = sc.status !== 'Pending Workup';

  useEffect(() => { if (editing) getSurgeries().then(setSurgeries); }, [editing]);

  function startEdit() {
    setProcedureName(sc.procedure_name); setEye(sc.eye || 'OD'); setReason(''); setEditing(true);
  }

  async function handleSaveInstructions() {
    setSavingInstructions(true);
    await onAction(setTreatmentInstructions)(sc.id, instructions);
    setSavingInstructions(false);
  }

  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--indigo)', color: '#fff' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, opacity: 0.85 }}>{patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile}</div>
        </div>
        {!editing ? (
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 700, fontSize: 14 }}>
              {sc.procedure_name}
              <button
                className="btn btn-sm" style={{ marginLeft: 8, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff', padding: '2px 8px' }}
                onClick={startEdit} title="Edit procedure/eye"
              >
                <i className="ti ti-pencil"></i>
              </button>
            </div>
            <div style={{ fontSize: 12, opacity: 0.85 }}>{EYE_LABEL[sc.eye] || sc.eye}</div>
            <div style={{ fontSize: 10.5, opacity: 0.7, marginTop: 2 }}>
              Advised: {new Date(sc.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
            </div>
          </div>
        ) : null}
      </div>

      {editing && (
        <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
              <option value={sc.procedure_name}>{sc.procedure_name}</option>
              {surgeries.filter((s) => s.name !== sc.procedure_name).map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
            </select>
            <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
              <option value="OD">Right (OD)</option>
              <option value="OS">Left (OS)</option>
              <option value="OU">Both (OU)</option>
            </select>
          </div>
          {progressed && (
            <input
              className="fi fi-sm" style={{ marginBottom: 8 }}
              placeholder={`Reason for changing (required -- case has already moved to "${sc.status}")`}
              value={reason} onChange={(e) => setReason(e.target.value)}
            />
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              className="btn btn-sm btn-primary"
              onClick={async () => {
                const r = await onAction(editSurgicalCaseDetails)(sc.id, procedureName, eye, reason);
                if (r?.error) return;
                setEditing(false);
              }}
            >
              Save
            </button>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={() => setEditing(false)}>Cancel</button>
          </div>
        </div>
      )}

      {/* Further instructions -- tied to the treatment itself (what's
          being done, which eye), not the pre-op investigations note. */}
      <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
        <div style={{ fontSize: 10, fontWeight: 700, opacity: 0.75, textTransform: 'uppercase', marginBottom: 6 }}>Further Instructions</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="fi fi-sm" style={{ flex: 1 }}
            placeholder="Anything else about this treatment worth noting..."
            value={instructions} onChange={(e) => setInstructions(e.target.value)}
          />
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={handleSaveInstructions} disabled={savingInstructions}>
            {savingInstructions ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ num, color, title, done, children, defaultOpen, active }) {
  const [open, setOpen] = useState(!!defaultOpen || !!active);
  return (
    <div
      className="card"
      style={{
        marginBottom: 12,
        border: active ? `2px solid ${color}` : '1px solid var(--g200)',
        background: active ? `color-mix(in srgb, ${color} 10%, white)` : '#fff',
        boxShadow: active ? `0 0 0 3px color-mix(in srgb, ${color} 20%, transparent)` : 'none',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }} onClick={() => setOpen((v) => !v)}>
        <div style={{ width: 24, height: 24, borderRadius: '50%', background: done ? 'var(--green)' : color, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
          {done ? <i className="ti ti-check"></i> : num}
        </div>
        <div style={{ fontWeight: 700, fontSize: 13, flex: 1 }}>
          {title}
          {active && <span className="badge" style={{ marginLeft: 8, background: color, color: '#fff', fontSize: 10 }}><i className="ti ti-arrow-right"></i> Next Step</span>}
        </div>
        <i className={`ti ${open ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ marginTop: 12, paddingLeft: 34 }}>{children}</div>}
    </div>
  );
}

export default function Workspace({ caseId }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getSurgicalCaseDetail(caseId);
    if (result.error) { setError(result.error); return; }
    setData(result);
  }, [caseId]);

  useEffect(() => { refresh(); }, [refresh]);

  function flash(fn) {
    return async (...args) => {
      setError(''); setOk('');
      const result = await fn(...args);
      if (result?.error) { setError(result.error); return result; }
      setOk('Saved.');
      await refresh();
      setTimeout(() => setOk(''), 2000);
      return result;
    };
  }

  if (error && !data) return <div className="msg-err">{error}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = data.case;
  const patient = sc.patients;

  // Drives the "Next Step" highlight -- the first not-yet-done stage in
  // the natural order gets the full-color treatment, everything else
  // stays normal. Reports and Notes aren't part of this sequence (they
  // don't have a natural "done" state -- reports trickle in whenever,
  // notes are an ongoing log), so they're excluded.
  const stepDone = {
    decision: sc.decision === 'Accepted',
    investigations: data.biometryRecords.length > 0,
    package: !!sc.package_id,
    fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
    iolApproval: data.iolApproval?.status === 'Approved',
    iol: !!data.otSchedule,
    advance: !!sc.advance_payment_id,
    dayof: !!data.recoveryEpisode?.discharge_date,
  };
  const currentStep = Object.keys(stepDone).find((k) => !stepDone[k]) || null;

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/surgical-journey')}>
        <i className="ti ti-arrow-left"></i> All Cases
      </button>

      <CaseHeader sc={sc} patient={patient} onAction={flash} />

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      {/* 1. PATIENT DECISION -- the very first step. Investigations (and
          everything after) only unlock once this is Accepted. */}
      <DecisionSection sc={sc} onAction={flash} active={currentStep === 'decision'} />

      {/* 2. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} inHouseInvestigations={data.inHouseInvestigations} onAction={flash} active={currentStep === 'investigations'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} onAction={flash} active={currentStep === 'package'} />

      {/* 4. MEDICAL FITNESS */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} />

      {/* 5. IOL APPROVAL -- separate module: surgeon's final brand/power
          sign-off, based on Biometry's device recommendations. */}
      <IolApprovalSection iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />

      {/* 6. IOL PROCUREMENT + DATE + BOOK */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} onAction={flash} active={currentStep === 'iol'} num={6} />

      {/* 7. ADVANCE */}
      <Section num={7} color="var(--teal)" title="Advance Payment" done={stepDone.advance} active={currentStep === 'advance'}>
        {sc.advance_payment_id ? (
          <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Advance collected.</div>
        ) : (
          <div>
            <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>Not yet collected.</div>
            <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => router.push(`/payments/advance?patientId=${patient.id}&returnTo=surgical-journey`)}>
              <i className="ti ti-cash"></i> Collect Advance
            </button>
          </div>
        )}
      </Section>

      {/* 8. DAY OF SURGERY */}
      <DayOfSurgerySection sc={sc} otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'dayof'} num={8} />

      {/* 9. NOTES / FOLLOW-UP */}
      <NotesSection caseId={sc.id} notes={data.caseNotes} onAction={flash} />
    </div>
  );
}

// ── FITNESS ─────────────────────────────────────────────────────────
// Kept as a real doctor referral/review (same as Counselling), not a
// self-certify checkbox -- clearing a patient for anaesthesia is a
// genuine clinical judgment, not paperwork. Deep-links to the Medical
// Fitness module for the actual review.
function FitnessSection({ sc, fitnessReferral, onAction, active }) {
  const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';
  return (
    <Section num={4} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>Refer to a doctor to review and clear for anaesthesia/surgery.</div>
          <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
            <i className="ti ti-heart-rate-monitor"></i> Refer to Doctor
          </button>
        </div>
      ) : fitnessReferral.status === 'Pending Review' ? (
        <span className="badge b-amber"><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}) -- <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Medical Fitness &rarr;</a></span>
      ) : fitnessReferral.status === 'Cleared' ? (
        <div>
          <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
        </div>
      ) : (
        <div>
          <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
          <div style={{ marginTop: 8 }}>
            <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
              <i className="ti ti-refresh"></i> Refer Again
            </button>
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. ──
function IolApprovalSection({ iolApproval, active }) {
  const approved = iolApproval?.status === 'Approved';
  return (
    <Section num={5} color="var(--indigo)" title="IOL Approval" done={approved} active={active}>
      {approved ? (
        <div style={{ fontSize: 12.5 }}>
          <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
          <div style={{ marginTop: 6 }}>
            {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
          </div>
        </div>
      ) : (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
            The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
          </div>
          <a href="/iol-approval" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
            <i className="ti ti-lens"></i> Open IOL Approval
          </a>
        </div>
      )}
    </Section>
  );
}

// ── 1. INVESTIGATIONS -- flexible and optional, not a fixed required
// panel. Biometry stays its own thing (patient-level, dedicated flow).
// Everything else splits into In-House (routes through our own
// Investigation module, status + View Report) and External (done
// elsewhere -- just upload whatever report comes back, view anytime). ──
function InvestigationsSection({ sc, biometryRecords, inHouseInvestigations, onAction, active }) {
  const [instructions, setInstructions] = useState('');
  const [invOptions, setInvOptions] = useState([]);
  const [selectedInv, setSelectedInv] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const biometryOrdered = biometryRecords.length > 0;
  const decided = sc.decision === 'Accepted';

  useEffect(() => { if (decided) getInvestigationOptionsForCase().then(setInvOptions); }, [decided]);

  if (!decided) {
    return (
      <Section num={2} color="var(--purple)" title="Investigations" done={false}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }

  return (
    <Section num={2} color="var(--purple)" title="Investigations" done={biometryOrdered} active={active}>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 14 }}>
        Optional -- add whatever this case actually needs, not a fixed checklist.
      </div>

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Biometry (both eyes, for IOL power)</div>
        {biometryRecords.length > 0 ? (
          biometryRecords.map((b) => (
            <div key={b.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
              <span>{b.status}{b.verified_at ? ` -- ${new Date(b.verified_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}` : ''}</span>
              <a href="/biometry" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Biometry &rarr;</a>
            </div>
          ))
        ) : (
          <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
            <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Instructions (optional)" value={instructions} onChange={(e) => setInstructions(e.target.value)} />
            <button className="btn btn-sm btn-primary" onClick={() => onAction(orderBiometryForCase)(sc.id, instructions)}>
              <i className="ti ti-ruler-measure"></i> Order Biometry
            </button>
          </div>
        )}
      </div>

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>In-House Investigations</div>
        {inHouseInvestigations.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {inHouseInvestigations.map((inv) => (
              <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
                <span>{inv.name} -- {inv.eye}</span>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${inv.status === 'Available' ? 'b-green' : inv.status === 'Cancelled' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{inv.status}</span>
                  {inv.status === 'Available' && (
                    <a href={`/investigation/${inv.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>View Report</a>
                  )}
                  {inv.status === 'Ordered' && (
                    <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={() => onAction(removeInHouseInvestigationForCase)(inv.id)}>Remove</button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
        <div style={{ display: 'flex', gap: 8 }}>
          <select className="fi fi-sm" style={{ flex: 1 }} value={selectedInv} onChange={(e) => setSelectedInv(e.target.value)}>
            <option value="">Select investigation...</option>
            {invOptions.map((o) => <option key={o.code} value={o.name}>{o.name}</option>)}
          </select>
          <select className="fi fi-sm" style={{ width: 90 }} value={invEye} onChange={(e) => setInvEye(e.target.value)}>
            <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
          </select>
          <button
            className="btn btn-sm btn-primary" disabled={!selectedInv}
            onClick={async () => { const r = await onAction(addInHouseInvestigationForCase)(sc.id, selectedInv, invEye); if (!r?.error) setSelectedInv(''); }}
          >
            <i className="ti ti-plus"></i> Add
          </button>
        </div>
      </div>

      <div>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>External Investigations (done elsewhere)</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Upload whatever report comes back, whenever it comes back -- view anytime.</div>
        <AttachmentUploader entityType="surgical_case" entityId={sc.id} title="" />
      </div>
    </Section>
  );
}

// ── 1. PATIENT DECISION -- the first step. Set by the doctor at
// advise-surgery time in OPD (Consultation), reflected here, and
// updatable by Front Desk once the patient calls back. Uses the same
// locked+reason semantics setDecision already enforces everywhere else
// (locks automatically once Accepted; changing away from a locked
// decision needs a reason). ──
function DecisionSection({ sc, onAction, active }) {
  const [reason, setReason] = useState('');
  const OPTIONS = [
    { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
    { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
    { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
  ];
  return (
    <Section num={1} color="var(--amber)" title="Patient Decision" done={sc.decision === 'Accepted'} active={active}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 8 }}>
        {OPTIONS.map((o) => (
          <button
            key={o.v}
            className="btn btn-sm"
            style={{ background: sc.decision === o.v ? o.color : '', color: sc.decision === o.v ? '#fff' : '', border: sc.decision === o.v ? 'none' : undefined }}
            onClick={() => onAction(setDecision)(sc.id, o.v, reason)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {sc.decision_locked && (
        <input className="fi fi-sm" placeholder="Reason to change decision..." value={reason} onChange={(e) => setReason(e.target.value)} />
      )}
      {sc.decision === 'Accepted' && sc.decision_accepted_at && (
        <div style={{ fontSize: 11.5, color: 'var(--green)', marginTop: 8 }}>
          <i className="ti ti-lock"></i> Accepted on {new Date(sc.decision_accepted_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })} -- locked.
        </div>
      )}
      {sc.decision === 'Wants Time to Decide' && (
        <div style={{ fontSize: 11.5, color: 'var(--amber)', marginTop: 8 }}>
          <i className="ti ti-clock-pause"></i> On Front Desk's follow-up list until this is updated.
        </div>
      )}
      {sc.decision === 'Declined' && (
        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 8 }}>
          <i className="ti ti-x"></i> Patient declined surgery.
        </div>
      )}
      {!sc.decision && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 8 }}>No decision recorded yet.</div>
      )}
    </Section>
  );
}

// ── 3. PACKAGE & IOL DECISION ──────────────────────────────────────
function PackageDecisionSection({ sc, onAction, active }) {
  const [packages, setPackages] = useState([]);
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changing, setChanging] = useState(false);
  const biometryReady = sc.biometry_done || sc.biometry_required === false;

  useEffect(() => {
    if (biometryReady) getPackagesForCase(sc.iol_category).then(setPackages);
  }, [biometryReady, sc.iol_category]);

  if (!biometryReady) {
    return (
      <Section num={3} color="var(--indigo)" title="Package" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Biometry approval first.</div>
      </Section>
    );
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package" done={!!sc.package_id} defaultOpen={biometryReady && !sc.package_id} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Package</div>
        {sc.master_packages ? (
          <div>
            <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: changing ? 8 : 0 }}>
              <span style={{ fontWeight: 600, fontSize: 12.5 }}>{sc.master_packages.name}</span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
                {!changing && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
              </div>
            </div>
            {changing && (
              <div>
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a new package...</option>
                    {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>)}
                  </select>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                  <button
                    className="btn btn-sm btn-primary"
                    disabled={!selectedPackageId || !changeReason.trim()}
                    onClick={async () => {
                      const r = await onAction(changePackage)(sc.id, changeReason);
                      if (r?.error) return;
                      await onAction(selectPackage)(sc.id, selectedPackageId);
                      setChanging(false); setChangeReason(''); setSelectedPackageId('');
                    }}
                  >
                    Confirm Change
                  </button>
                  <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); }}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        ) : (
          <div style={{ display: 'flex', gap: 8 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
              <option value="">Select a package...</option>
              {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>)}
            </select>
            <button className="btn btn-sm btn-primary" disabled={!selectedPackageId} onClick={() => onAction(selectPackage)(sc.id, selectedPackageId)}>Select</button>
          </div>
        )}
      </div>
    </Section>
  );
}

// ── 4. IOL PROCUREMENT + DATE + BOOK SLOT ──────────────────────────
function IolAndBookingSection({ sc, otSchedule, onAction, active, num }) {
  const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  const canBook = sc.status === 'Ready for Scheduling';
  const readyGateMet = sc.package_id && sc.decision === 'Accepted' && (sc.biometry_done || sc.biometry_required === false) && (sc.fitness_cleared || sc.fitness_required === false);

  const [rescheduling, setRescheduling] = useState(false);
  const [rescheduleReason, setRescheduleReason] = useState('');

  if (otSchedule) {
    return (
      <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done active={active}>
        <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>

        {!rescheduling ? (
          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><i className="ti ti-calendar-check"></i> Booked -- {new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}, {otSchedule.master_ot_sessions?.name} session</span>
            {otSchedule.status === 'Scheduled' && <button className="btn btn-sm" onClick={() => setRescheduling(true)}>Reschedule</button>}
          </div>
        ) : (
          <div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
              <input type="date" className="fi fi-sm" value={date} min={new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })} onChange={(e) => setDate(e.target.value)} />
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                {loadingSessions ? <span style={{ fontSize: 12, color: 'var(--g400)' }}>Checking...</span> : sessions.map((s) => {
                  const full = s.remaining <= 0;
                  return (
                    <button key={s.session_id} disabled={full} className="btn btn-sm"
                      style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                      onClick={() => setSessionId(s.session_id)}>
                      {s.name} ({s.remaining} left)
                    </button>
                  );
                })}
              </div>
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
              <button
                className="btn btn-sm btn-primary"
                disabled={!date || !sessionId || !rescheduleReason.trim()}
                onClick={async () => {
                  const r = await onAction(rescheduleOTSlot)(otSchedule.id, date, sessionId, rescheduleReason);
                  if (r?.error) return;
                  setRescheduling(false); setRescheduleReason(''); setDate(''); setSessionId('');
                }}
              >
                Confirm
              </button>
              <button className="btn btn-sm" onClick={() => setRescheduling(false)}>Cancel</button>
            </div>
          </div>
        )}
      </Section>
    );
  }

  return (
    <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done={false} defaultOpen={readyGateMet} active={active}>
      <div style={{ marginBottom: 12 }}>
        <label className="flbl">IOL Order Notes</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>
      </div>

      {!readyGateMet && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Package, decision, biometry, and fitness must all be settled before booking a date.
        </div>
      )}

      {readyGateMet && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 10 }}>
            <div>
              <label className="flbl">Date</label>
              <input type="date" className="fi fi-sm" value={date} min={new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })} onChange={(e) => setDate(e.target.value)} />
            </div>
            <div>
              <label className="flbl">Surgeon</label>
              <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                <option value="">--</option>
                {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </div>
          </div>
          {date && (
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Session</label>
              {loadingSessions ? (
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
              ) : (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {sessions.map((s) => {
                    const full = s.remaining <= 0;
                    return (
                      <button
                        key={s.session_id} disabled={full} className="btn btn-sm"
                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                        onClick={() => setSessionId(s.session_id)}
                      >
                        {s.name} ({s.remaining} left)
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          )}
          <button
            className="btn btn-primary btn-sm"
            disabled={!date || !sessionId}
            onClick={async () => {
              if (!canBook) {
                const r = await onAction(markReadyForScheduling)(sc.id);
                if (r?.error) return;
              }
              await onAction(bookOTSlot)(sc.id, date, sessionId, surgeonId || null, null);
            }}
          >
            <i className="ti ti-calendar-check"></i> Give This Date
          </button>
        </>
      )}
    </Section>
  );
}

// ── 7. DAY OF SURGERY (live status, deep-links only -- OT Intraop and
// Recovery remain their own solid clinical workflows) ──
function DayOfSurgerySection({ sc, otSchedule, recoveryEpisode, router, active, num }) {
  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;

  if (otSchedule) {
    if (otSchedule.status === 'Scheduled') {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
      color = 'var(--blue)';
      action = { label: 'Open in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'Completed') {
      if (recoveryEpisode && !recoveryEpisode.discharge_date) {
        status = 'Surgery done -- in Recovery';
        color = 'var(--teal)';
        action = { label: 'Open in Recovery', onClick: () => router.push('/ot-recovery') };
      } else if (recoveryEpisode?.discharge_date) {
        status = `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
        color = 'var(--green)';
        action = { label: 'Open in Post-Op', onClick: () => router.push('/ot-postop') };
      } else {
        status = 'Surgery completed';
        color = 'var(--green)';
      }
    }
  }

  return (
    <Section num={num} color={color} title="Day of Surgery" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!otSchedule} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, the surgery itself, and discharge all happen in the Operation Theatre / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── 8. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
function NotesSection({ caseId, notes, onAction }) {
  const [text, setText] = useState('');
  return (
    <Section num={9} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
        <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Add a note (e.g. follow-up call outcome)..." value={text} onChange={(e) => setText(e.target.value)} />
        <button
          className="btn btn-sm"
          onClick={async () => { if (!text.trim()) return; await onAction(addCaseNote)(caseId, text); setText(''); }}
        >
          Add
        </button>
      </div>
      {notes.map((n) => (
        <div key={n.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
          <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {n.profiles?.full_name || 'Staff'}:</span> {n.note}
        </div>
      ))}
      {notes.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No notes yet.</div>}
    </Section>
  );
}
FILEEOF_surgical_journey_id_workspace_js

cat > "schema.sql" << 'FILEEOF_schema_sql'



SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";





SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "visit_id" "uuid",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "gross" numeric DEFAULT 0 NOT NULL,
    "gst" numeric DEFAULT 0 NOT NULL,
    "net" numeric DEFAULT 0 NOT NULL,
    "paid" numeric DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "cancelled_at" timestamp with time zone,
    "cancelled_by" "uuid",
    "cancellation_reason" "text",
    "invoice_number" "text",
    "source" "text" DEFAULT 'visit'::"text" NOT NULL,
    "purpose" "text" DEFAULT 'Consultation'::"text" NOT NULL,
    CONSTRAINT "invoices_purpose_check" CHECK (("purpose" = ANY (ARRAY['Consultation'::"text", 'Investigation'::"text", 'Pharmacy'::"text", 'Surgery'::"text", 'Combined'::"text", 'Other'::"text"]))),
    CONSTRAINT "invoices_source_check" CHECK (("source" = ANY (ARRAY['visit'::"text", 'standalone'::"text", 'package'::"text"]))),
    CONSTRAINT "invoices_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Partial'::"text", 'Paid'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."invoices" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer DEFAULT 1) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  svc master_services;
begin
  select * into svc from master_services where code = p_service_code and status = 'Active';
  if svc is null then
    raise exception 'Service not found or inactive';
  end if;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (
    p_invoice_id, svc.code, svc.name, svc.dept, p_qty,
    svc.rate, svc.gst_pct, 0,
    svc.rate * p_qty, round(svc.rate * p_qty * svc.gst_pct / 100, 2),
    round(svc.rate * p_qty * (1 + svc.gst_pct / 100), 2)
  );

  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer DEFAULT 1, "p_disc_type" "text" DEFAULT 'none'::"text", "p_disc_value" numeric DEFAULT 0, "p_disc_reason" "text" DEFAULT NULL::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_name text;
  v_dept text;
  v_rate numeric;
  v_gst_pct numeric;
  v_gross numeric;
  v_disc numeric;
  v_taxable numeric;
  v_gst numeric;
  v_net numeric;
  v_found boolean;
  v_is_package boolean := false;
  v_package_id uuid;
  v_patient_id uuid;
begin
  select name, dept, rate, gst_pct into v_name, v_dept, v_rate, v_gst_pct
  from master_services where code = p_service_code and status = 'Active';
  v_found := found;

  if not v_found then
    select (generic || ' ' || coalesce(strength, '')), 'Pharmacy'::text, coalesce(rate, 0), coalesce(gst_pct, 0)
    into v_name, v_dept, v_rate, v_gst_pct
    from master_drugs where code = p_service_code and status = 'Active';
    v_found := found;
  end if;

  -- Packages live in their own master table (master_packages), not
  -- master_services -- without this branch, package billing (from
  -- Counselling's locked package or the Front Office widget) would
  -- fail with "Service not found" the moment it tried to bill.
  if not v_found then
    select id, name, 'Surgery'::text, price, 0::numeric
    into v_package_id, v_name, v_dept, v_rate, v_gst_pct
    from master_packages where code = p_service_code and status = 'Active';
    v_found := found;
    v_is_package := found;
  end if;

  if not v_found then
    raise exception 'Service not found or inactive';
  end if;

  if p_disc_type <> 'none' and (p_disc_reason is null or trim(p_disc_reason) = '') then
    raise exception 'A discount reason is required whenever a discount is applied.';
  end if;

  v_gross := v_rate * p_qty;

  if p_disc_type = 'pct' then
    v_disc := round(v_gross * p_disc_value / 100, 2);
  elsif p_disc_type = 'fixed' then
    v_disc := least(p_disc_value, v_gross);
  else
    v_disc := 0;
  end if;

  v_taxable := v_gross - v_disc;
  v_gst := round(v_taxable * v_gst_pct / 100, 2);
  v_net := v_taxable + v_gst;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (p_invoice_id, p_service_code, v_name, v_dept, p_qty, v_rate, v_gst_pct, v_disc, v_gross, v_gst, v_net);

  -- Mark the matching surgical case's package as billed regardless of
  -- how the line item got added (Front Office widget prefill, or a
  -- department picked manually) -- previously only the prefill path
  -- did this, so a manually-added package invoice left the case
  -- looking permanently unbilled even after it was fully paid.
  if v_is_package then
    select patient_id into v_patient_id from invoices where id = p_invoice_id;
    if v_patient_id is not null then
      update surgical_cases
      set package_billed = true
      where package_id = v_package_id
        and patient_id = v_patient_id
        and package_locked = true
        and package_billed = false;
    end if;
  end if;

  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_balance numeric;
  v_outstanding numeric;
  v_receipt_number text;
  new_payment payments;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before adjustments can be made.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Adjustment amount must be greater than zero.';
  end if;

  v_balance := get_advance_balance(p_patient_id);
  if p_amount > v_balance then
    raise exception 'Adjustment amount (Rs.%) exceeds available advance balance (Rs.%).', p_amount, v_balance;
  end if;

  select net - paid into v_outstanding from invoices where id = p_invoice_id;
  if v_outstanding is null then
    raise exception 'Invoice not found';
  end if;
  if p_amount > v_outstanding then
    raise exception 'Adjustment amount (Rs.%) exceeds this invoice''s outstanding balance (Rs.%).', p_amount, v_outstanding;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_receipt_number, p_patient_id, p_amount, 'Advance adjusted against invoice', auth.uid(), 'advance_adjustment')
  returning * into new_payment;

  insert into payment_allocations (payment_id, invoice_id, amount)
  values (new_payment.id, p_invoice_id, p_amount);

  -- New, linked debit entry -- the original "Advance Collected" entry
  -- is never touched, per Section 22.11.
  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_payment.id, 'Advance Adjusted', -p_amount, 'Applied against invoice', auth.uid());

  update invoices set paid = paid + p_amount where id = p_invoice_id;
  return recompute_invoice_totals(p_invoice_id);
end;
$$;


ALTER FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_session record;
  v_case record;
  v_booked_count int;
  v_ot_id uuid;
begin
  select * into v_session from master_ot_sessions where id = p_session_id and status = 'Active' for update;
  if not found then
    return jsonb_build_object('error', 'Selected OT session not found or inactive.');
  end if;

  select * into v_case from surgical_cases where id = p_case_id for update;
  if not found then
    return jsonb_build_object('error', 'Surgical case not found.');
  end if;
  if v_case.status <> 'Ready for Scheduling' then
    return jsonb_build_object('error', 'Case is not Ready for Scheduling.');
  end if;

  if p_date < current_date then
    return jsonb_build_object('error', 'Cannot book a date in the past.');
  end if;

  select count(*) into v_booked_count
  from ot_schedule
  where scheduled_date = p_date and session_id = p_session_id and status <> 'Cancelled';

  if v_booked_count >= v_session.capacity then
    return jsonb_build_object(
      'error',
      format('%s session on %s is full (%s/%s booked). Choose another date or session.',
        v_session.name, to_char(p_date, 'DD Mon YYYY'), v_booked_count, v_session.capacity)
    );
  end if;

  insert into ot_schedule (surgical_case_id, surgeon_id, scheduled_date, scheduled_time, session_id, room, notes)
  values (p_case_id, p_surgeon_id, p_date, v_session.start_time, p_session_id, v_session.default_room, nullif(p_notes, ''))
  returning id into v_ot_id;

  update surgical_cases set status = 'Scheduled' where id = p_case_id;

  return jsonb_build_object('success', true, 'ot_schedule_id', v_ot_id);
end;
$$;


ALTER FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  inv invoices;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A cancellation reason is required.';
  end if;

  select * into inv from invoices where id = p_invoice_id;
  if inv is null then
    raise exception 'Invoice not found';
  end if;
  if inv.status = 'Cancelled' then
    raise exception 'This invoice is already cancelled.';
  end if;
  if inv.paid > 0 then
    raise exception 'Cannot cancel an invoice that already has payments recorded against it. Contact an administrator.';
  end if;

  update invoices
  set status = 'Cancelled', cancelled_at = now(), cancelled_by = auth.uid(), cancellation_reason = p_reason
  where id = p_invoice_id
  returning * into inv;

  insert into invoice_modifications (invoice_id, modified_by, action, reason)
  values (p_invoice_id, auth.uid(), 'cancelled', p_reason);

  return inv;
end;
$$;


ALTER FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "appointment_id" "uuid",
    "doctor_id" "uuid",
    "visit_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "status" "text" DEFAULT 'Open'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "closed_at" timestamp with time zone,
    "referral_source" "text",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "visit_number" "text",
    "cancellation_reason" "text",
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "surgery_type" "text",
    CONSTRAINT "visits_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text", 'Emergency'::"text"]))),
    CONSTRAINT "visits_status_check" CHECK (("status" = ANY (ARRAY['Open'::"text", 'Closed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."visits" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  appt appointments;
  new_visit visits;
  existing_visit_count int;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before new visits can be created.';
  end if;

  select * into appt from appointments where id = p_appointment_id;

  if appt is null then
    raise exception 'Appointment not found';
  end if;

  if appt.patient_id is null then
    raise exception 'This appointment has no registered patient yet -- register the patient first, then check in.';
  end if;

  select count(*) into existing_visit_count
  from visits
  where patient_id = appt.patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, appointment_id, doctor_id, visit_type, referral_source, status, visit_number)
  values (appt.patient_id, appt.id, appt.doctor_id, appt.visit_type, 'Appointment', 'Open', next_visit_number())
  returning * into new_visit;

  update appointments set status = 'Checked-in' where id = p_appointment_id;

  if new_visit.visit_type = 'Surgery' then
    update ot_schedule os
    set patient_reported_at = now()
    from surgical_cases sc
    where os.surgical_case_id = sc.id
      and sc.patient_id = new_visit.patient_id
      and os.scheduled_date = ist_date(now())
      and os.status in ('Scheduled', 'In Progress');
  elsif new_visit.visit_type = 'Post-operative Review' then
    perform issue_queue_token(new_visit.id, 'Doctor');
  else
    perform issue_queue_token(new_visit.id, 'Optometry');
  end if;

  return new_visit;
end;
$$;


ALTER FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_closings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "closed_by" "uuid",
    "closed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_revenue" numeric NOT NULL,
    "total_collected" numeric NOT NULL,
    "total_outstanding" numeric NOT NULL,
    "total_invoices" integer NOT NULL,
    "total_visits" integer NOT NULL,
    "notes" "text"
);


ALTER TABLE "public"."day_closings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."close_day"("p_date" "date" DEFAULT NULL::"date", "p_notes" "text" DEFAULT NULL::"text") RETURNS "public"."day_closings"
    LANGUAGE "plpgsql"
    AS $$
declare
  closing day_closings;
  v_revenue numeric;
  v_collected numeric;
  v_outstanding numeric;
  v_invoice_count int;
  v_visit_count int;
  v_date date;
  v_modes_expected int;
  v_modes_reconciled int;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if is_day_closed(v_date) then
    raise exception 'This day has already been closed.';
  end if;

  select count(distinct pm.mode) into v_modes_expected
  from payment_modes pm join payments p on p.id = pm.payment_id
  where ist_date(p.collected_at) = v_date;

  select count(*) into v_modes_reconciled from day_reconciliation where closing_date = v_date;

  if v_modes_expected > 0 and v_modes_reconciled < v_modes_expected then
    raise exception 'Reconciliation is incomplete for %s -- % of % payment modes reconciled. Complete reconciliation before closing.', v_date, v_modes_reconciled, v_modes_expected;
  end if;

  select coalesce(sum(net),0), coalesce(sum(paid),0), coalesce(sum(net - paid),0), count(*)
  into v_revenue, v_collected, v_outstanding, v_invoice_count
  from invoices where ist_date(created_at) = v_date;

  select count(*) into v_visit_count from visits where ist_date(created_at) = v_date;

  insert into day_closings (closing_date, closed_by, total_revenue, total_collected, total_outstanding, total_invoices, total_visits, notes)
  values (v_date, auth.uid(), v_revenue, v_collected, v_outstanding, v_invoice_count, v_visit_count, p_notes)
  returning * into closing;

  return closing;
end;
$$;


ALTER FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "receipt_number" "text" NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "total_amount" numeric NOT NULL,
    "reference" "text",
    "remarks" "text",
    "collected_by" "uuid",
    "collected_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "payment_type" "text" DEFAULT 'invoice_payment'::"text" NOT NULL,
    "advance_type" "text",
    CONSTRAINT "payments_payment_type_check" CHECK (("payment_type" = ANY (ARRAY['invoice_payment'::"text", 'advance'::"text", 'advance_adjustment'::"text", 'credit_note'::"text", 'refund'::"text"])))
);


ALTER TABLE "public"."payments" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_payment payments;
  v_receipt_number text;
  v_mode jsonb;
  v_modes_sum numeric := 0;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before advances can be collected.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount must be greater than zero.';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_modes_sum := v_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_modes_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment mode split (Rs.%) must add up to the amount (Rs.%).', v_modes_sum, p_amount;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, reference, remarks, collected_by, payment_type, advance_type)
  values (v_receipt_number, p_patient_id, p_amount, p_reference, p_remarks, auth.uid(), 'advance', p_advance_type)
  returning * into new_payment;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount)
    values (new_payment.id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_payment.id, 'Advance Collected', p_amount, p_advance_type, auth.uid());

  return new_payment;
end;
$$;


ALTER FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_payment payments;
  v_receipt_number text;
  v_remaining numeric;
  v_invoice_id uuid;
  v_outstanding numeric;
  v_allocate numeric;
  v_mode jsonb;
  v_modes_sum numeric := 0;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before payments can be collected.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Amount collecting must be greater than zero.';
  end if;

  if p_invoice_ids is null or array_length(p_invoice_ids, 1) is null then
    raise exception 'Select at least one invoice to pay.';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_modes_sum := v_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_modes_sum, 2) <> round(p_amount, 2) then
    raise exception 'Payment mode split (Rs.%) must add up to the amount collecting (Rs.%).', v_modes_sum, p_amount;
  end if;

  v_receipt_number := 'RCT' || to_char(now(), 'YY') || '-' || lpad(nextval('receipt_number_seq')::text, 6, '0');

  insert into payments (receipt_number, patient_id, total_amount, reference, remarks, collected_by)
  values (v_receipt_number, p_patient_id, p_amount, p_reference, p_remarks, auth.uid())
  returning * into new_payment;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount)
    values (new_payment.id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  v_remaining := p_amount;
  foreach v_invoice_id in array p_invoice_ids
  loop
    exit when v_remaining <= 0;

    select net - paid into v_outstanding from invoices where id = v_invoice_id;
    if v_outstanding is null or v_outstanding <= 0 then
      continue;
    end if;

    v_allocate := least(v_remaining, v_outstanding);

    insert into payment_allocations (payment_id, invoice_id, amount)
    values (new_payment.id, v_invoice_id, v_allocate);

    update invoices set paid = paid + v_allocate where id = v_invoice_id;
    perform recompute_invoice_totals(v_invoice_id);

    v_remaining := v_remaining - v_allocate;
  end loop;

  -- Anything left over after fully paying off every selected invoice
  -- becomes advance credit, same as collecting advance directly.
  if v_remaining > 0 then
    insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
    values (
      p_patient_id, new_payment.id, 'Advance Collected', v_remaining,
      'Overpayment from Receipt ' || v_receipt_number, auth.uid()
    );
  end if;

  return new_payment;
end;
$$;


ALTER FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."credit_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "credit_note_number" "text" NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "payment_id" "uuid",
    "amount" numeric NOT NULL,
    "reason" "text" NOT NULL,
    "approved_by" "uuid",
    "remarks" "text",
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."credit_notes" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."credit_notes"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_outstanding numeric;
  v_cn_number text;
  new_payment payments;
  new_cn credit_notes;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before credit notes can be issued.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Credit amount must be greater than zero.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required for a credit note.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a credit note.';
  end if;

  select net - paid into v_outstanding from invoices where id = p_invoice_id;
  if v_outstanding is null then
    raise exception 'Invoice not found';
  end if;
  if p_amount > v_outstanding then
    raise exception 'Credit amount (Rs.%) exceeds this invoice''s outstanding balance (Rs.%).', p_amount, v_outstanding;
  end if;

  v_cn_number := next_credit_note_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_cn_number, p_patient_id, p_amount, 'Credit note: ' || p_reason, auth.uid(), 'credit_note')
  returning * into new_payment;

  insert into payment_allocations (payment_id, invoice_id, amount)
  values (new_payment.id, p_invoice_id, p_amount);

  update invoices set paid = paid + p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  insert into credit_notes (credit_note_number, patient_id, invoice_id, payment_id, amount, reason, approved_by, remarks, created_by)
  values (v_cn_number, p_patient_id, p_invoice_id, new_payment.id, p_amount, p_reason, p_approved_by, p_remarks, auth.uid())
  returning * into new_cn;

  return new_cn;
end;
$$;


ALTER FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid" DEFAULT NULL::"uuid", "p_purpose" "text" DEFAULT 'Consultation'::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  inv invoices;
begin
  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source, purpose)
  values (
    p_patient_id, p_visit_id, 'Pending', 0, 0, 0, 0, next_invoice_number(),
    case when p_visit_id is null then 'standalone' else 'visit' end,
    coalesce(p_purpose, 'Consultation')
  )
  returning * into inv;

  return inv;
end;
$$;


ALTER FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text" DEFAULT NULL::"text", "p_priority" "text" DEFAULT 'Routine'::"text", "p_surgery_type" "text" DEFAULT NULL::"text") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_visit visits;
  existing_visit_count int;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before new visits can be created.';
  end if;

  select count(*) into existing_visit_count
  from visits
  where patient_id = p_patient_id and ist_date(created_at) = ist_date(now());

  if existing_visit_count > 0 then
    raise exception 'This patient already has a visit today.';
  end if;

  insert into visits (patient_id, doctor_id, visit_type, referral_source, priority, surgery_type, status, visit_number)
  values (p_patient_id, p_doctor_id, p_visit_type, p_referral_source, coalesce(p_priority, 'Routine'), p_surgery_type, 'Open', next_visit_number())
  returning * into new_visit;

  if new_visit.visit_type = 'Surgery' then
    update ot_schedule os
    set patient_reported_at = now()
    from surgical_cases sc
    where os.surgical_case_id = sc.id
      and sc.patient_id = new_visit.patient_id
      and os.scheduled_date = ist_date(now())
      and os.status in ('Scheduled', 'In Progress');
  else
    -- Post-operative Review patients now route through Optometry too --
    -- refraction and other clinical recording may be needed post-surgery
    -- just like a normal visit. The doctor still keeps the existing
    -- "Call Directly" override (Doctor Dashboard / Post-op module) to
    -- pull them straight in without waiting on Optometry.
    perform issue_queue_token(new_visit.id, 'Optometry');
  end if;

  return new_visit;
end;
$$;


ALTER FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."prescriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "drug_name" "text" NOT NULL,
    "dosage" "text",
    "frequency" "text",
    "duration" "text",
    "eye" "text",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "sent_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    CONSTRAINT "prescriptions_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "prescriptions_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Sent'::"text", 'Dispensed'::"text"])))
);


ALTER TABLE "public"."prescriptions" OWNER TO "postgres";


COMMENT ON COLUMN "public"."prescriptions"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



CREATE OR REPLACE FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") RETURNS "public"."prescriptions"
    LANGUAGE "plpgsql"
    AS $$
declare
  rx prescriptions;
  v_visit_id uuid;
  inv invoices;
  matched master_drugs;
begin
  select * into rx from prescriptions where id = p_prescription_id;
  if rx is null then
    raise exception 'Prescription not found';
  end if;

  update prescriptions set status = 'Dispensed' where id = p_prescription_id returning * into rx;

  if rx.billing_status = 'Billed' then
    return rx;
  end if;

  select visit_id into v_visit_id from encounters where id = rx.encounter_id;

  inv := get_or_create_invoice_for_visit(v_visit_id);

  select * into matched from master_drugs
  where status = 'Active'
    and (rx.drug_name ilike '%' || generic || '%' or rx.drug_name ilike '%' || brand || '%')
  limit 1;

  if matched is not null then
    insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
    values (
      inv.id, matched.code, rx.drug_name, 'Pharmacy', 1,
      matched.rate, matched.gst_pct, 0,
      matched.rate, round(matched.rate * matched.gst_pct / 100, 2),
      round(matched.rate * (1 + matched.gst_pct / 100), 2)
    );
    perform recompute_invoice_totals(inv.id);
    update prescriptions set billing_status = 'Billed', billing_updated_at = now()
      where id = p_prescription_id returning * into rx;
  end if;

  return rx;
end;
$$;


ALTER FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") RETURNS "public"."payments"
    LANGUAGE "plpgsql"
    AS $$
declare
  pay payments;
  v_old_modes jsonb;
  v_new_modes_sum numeric := 0;
  v_mode jsonb;
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to edit a payment.';
  end if;

  select * into pay from payments where id = p_payment_id;
  if pay is null then
    raise exception 'Payment not found';
  end if;

  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    v_new_modes_sum := v_new_modes_sum + (v_mode->>'amount')::numeric;
  end loop;
  if round(v_new_modes_sum, 2) <> round(pay.total_amount, 2) then
    raise exception 'Mode split (Rs.%) must still add up to the original amount collected (Rs.%). To change the amount itself, use Refund or Credit Note instead.', v_new_modes_sum, pay.total_amount;
  end if;

  select coalesce(jsonb_agg(jsonb_build_object('mode', mode, 'amount', amount)), '[]'::jsonb)
  into v_old_modes
  from payment_modes where payment_id = p_payment_id;

  insert into payment_edits (payment_id, old_reference, new_reference, old_remarks, new_remarks, old_modes, new_modes, reason, edited_by)
  values (p_payment_id, pay.reference, p_reference, pay.remarks, p_remarks, v_old_modes, p_modes, p_reason, auth.uid());

  delete from payment_modes where payment_id = p_payment_id;
  for v_mode in select * from jsonb_array_elements(p_modes)
  loop
    insert into payment_modes (payment_id, mode, amount) values (p_payment_id, v_mode->>'mode', (v_mode->>'amount')::numeric);
  end loop;

  update payments set reference = p_reference, remarks = p_remarks where id = p_payment_id returning * into pay;

  return pay;
end;
$$;


ALTER FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric DEFAULT 0) RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  pkg master_packages;
  inv invoices;
  v_paid numeric;
begin
  select * into pkg from master_packages where id = p_package_id and status = 'Active';
  if pkg is null then
    raise exception 'Package not found or inactive';
  end if;

  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source)
  values (p_patient_id, p_visit_id, 'Pending', pkg.price, 0, pkg.price, 0, next_invoice_number(), 'package')
  returning * into inv;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (inv.id, pkg.code, pkg.name, 'Surgery', 1, pkg.price, 0, 0, pkg.price, 0, pkg.price);

  if p_payment_mode = 'full' then
    v_paid := pkg.price;
  else
    if p_advance_amount is null or p_advance_amount <= 0 or p_advance_amount > pkg.price then
      raise exception 'Advance amount must be greater than zero and not exceed the package price.';
    end if;
    v_paid := p_advance_amount;
  end if;

  update invoices set paid = v_paid where id = inv.id;

  return recompute_invoice_totals(inv.id);
end;
$$;


ALTER FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric DEFAULT 0, "p_surgical_case_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  pkg master_packages;
  inv invoices;
  v_paid numeric;
begin
  select * into pkg from master_packages where id = p_package_id and status = 'Active';
  if pkg is null then
    raise exception 'Package not found or inactive';
  end if;

  insert into invoices (patient_id, visit_id, status, gross, gst, net, paid, invoice_number, source)
  values (p_patient_id, p_visit_id, 'Pending', pkg.price, 0, pkg.price, 0, next_invoice_number(), 'package')
  returning * into inv;

  insert into invoice_line_items (invoice_id, service_code, service_name, dept, qty, rate, gst_pct, disc, gross, gst_amount, net)
  values (inv.id, pkg.code, pkg.name, 'Surgery', 1, pkg.price, 0, 0, pkg.price, 0, pkg.price);

  if p_payment_mode = 'full' then
    v_paid := pkg.price;
  else
    if p_advance_amount is null or p_advance_amount <= 0 or p_advance_amount > pkg.price then
      raise exception 'Advance amount must be greater than zero and not exceed the package price.';
    end if;
    v_paid := p_advance_amount;
  end if;

  update invoices set paid = v_paid where id = inv.id;

  if p_surgical_case_id is not null then
    update surgical_cases set package_billed = true where id = p_surgical_case_id;
  end if;

  return recompute_invoice_totals(inv.id);
end;
$$;


ALTER FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") RETURNS numeric
    LANGUAGE "sql" STABLE
    AS $$
  select coalesce(sum(amount), 0) from patient_ledger where patient_id = p_patient_id;
$$;


ALTER FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") RETURNS "public"."visits"
    LANGUAGE "plpgsql"
    AS $$
declare
  existing visits;
  new_visit visits;
begin
  select * into existing from visits
  where patient_id = p_patient_id and ist_date(created_at) = ist_date(now())
  order by created_at desc
  limit 1;

  if found then
    return existing;
  end if;

  new_visit := create_walk_in_visit(p_patient_id, p_doctor_id, 'Post-operative Review', null, 'Routine', null);
  return new_visit;
end;
$$;


ALTER FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_ot_availability"("p_date" "date") RETURNS TABLE("session_id" "uuid", "name" "text", "start_time" time without time zone, "end_time" time without time zone, "default_room" "text", "capacity" integer, "booked" integer, "remaining" integer)
    LANGUAGE "sql" STABLE
    AS $$
  select
    s.id, s.name, s.start_time, s.end_time, s.default_room, s.capacity,
    coalesce(b.cnt, 0)::int as booked,
    (s.capacity - coalesce(b.cnt, 0))::int as remaining
  from master_ot_sessions s
  left join (
    select session_id, count(*) as cnt
    from ot_schedule
    where scheduled_date = p_date and status <> 'Cancelled'
    group by session_id
  ) b on b.session_id = s.id
  where s.status = 'Active'
  order by s.display_order;
$$;


ALTER FUNCTION "public"."get_ot_availability"("p_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
begin
  insert into public.profiles (id, full_name, designation, department)
  values (
    new.id,
    coalesce(new.raw_user_meta_data->>'full_name', new.email),
    coalesce(new.raw_user_meta_data->>'designation', 'Staff'),
    coalesce(new.raw_user_meta_data->>'department', '')
  );
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_day_closed"("p_date" "date") RETURNS boolean
    LANGUAGE "sql" STABLE
    AS $$
  select exists (select 1 from day_closings where closing_date = p_date);
$$;


ALTER FUNCTION "public"."is_day_closed"("p_date" "date") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."queue_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "department" "text" NOT NULL,
    "token" "text" NOT NULL,
    "status" "text" DEFAULT 'Waiting'::"text" NOT NULL,
    "issued_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "called_at" timestamp with time zone,
    "sent_out_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    CONSTRAINT "queue_entries_department_check" CHECK (("department" = ANY (ARRAY['Optometry'::"text", 'Doctor'::"text"]))),
    CONSTRAINT "queue_entries_status_check" CHECK (("status" = ANY (ARRAY['Waiting'::"text", 'Calling'::"text", 'In Consultation'::"text", 'Awaiting Dilation'::"text", 'Awaiting Investigation'::"text", 'Awaiting Biometry'::"text", 'Awaiting Dilation & Investigation'::"text", 'Awaiting Dilation & Biometry'::"text", 'Awaiting Investigation & Biometry'::"text", 'Awaiting Dilation & Investigation & Biometry'::"text", 'Ready for Review'::"text", 'Done'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."queue_entries" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  today_count int;
  new_token text;
  prefix text;
  new_entry queue_entries;
begin
  prefix := case p_department when 'Optometry' then 'O' when 'Doctor' then 'D' else 'X' end;

  select count(*) into today_count
  from queue_entries
  where department = p_department
    and ist_date(issued_at) = ist_date(now());

  new_token := prefix || '-' || lpad((today_count + 1)::text, 2, '0');

  insert into queue_entries (visit_id, department, token, status)
  values (p_visit_id, p_department, new_token, 'Waiting')
  returning * into new_entry;

  return new_entry;
end;
$$;


ALTER FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ist_date"("ts" timestamp with time zone) RETURNS "date"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select (ts at time zone 'Asia/Kolkata')::date;
$$;


ALTER FUNCTION "public"."ist_date"("ts" timestamp with time zone) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_credit_note_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'CN' || yr || '-' || lpad(nextval('credit_note_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_credit_note_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_invoice_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'INV' || yr || '-' || lpad(nextval('invoice_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_invoice_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_package_code"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
begin
  return 'PKG' || lpad(nextval('package_code_seq')::text, 3, '0');
end;
$$;


ALTER FUNCTION "public"."next_package_code"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_refund_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'REF' || yr || '-' || lpad(nextval('refund_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_refund_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_visit_number"() RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  yr text;
begin
  yr := to_char(now(), 'YY');
  return 'V' || yr || '-' || lpad(nextval('visit_number_seq')::text, 6, '0');
end;
$$;


ALTER FUNCTION "public"."next_visit_number"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_openings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "opening_date" "date" NOT NULL,
    "opened_by" "uuid",
    "opened_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "opening_cash_balance" numeric DEFAULT 0 NOT NULL,
    "remarks" "text"
);


ALTER TABLE "public"."day_openings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."open_day"("p_date" "date" DEFAULT NULL::"date", "p_opening_balance" numeric DEFAULT 0, "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."day_openings"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_date date;
  row day_openings;
begin
  v_date := coalesce(p_date, ist_date(now()));

  if exists (select 1 from day_openings where opening_date = v_date) then
    raise exception 'Today has already been opened.';
  end if;

  insert into day_openings (opening_date, opened_by, opening_cash_balance, remarks)
  values (v_date, auth.uid(), p_opening_balance, p_remarks)
  returning * into row;

  return row;
end;
$$;


ALTER FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  entry queue_entries;
begin
  update queue_entries set status = 'Done', completed_at = now()
  where id = p_queue_entry_id and department = 'Optometry'
  returning * into entry;

  if entry is null then
    raise exception 'Queue entry not found';
  end if;

  perform issue_queue_token(entry.visit_id, 'Doctor');

  return entry;
end;
$$;


ALTER FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  totals record;
  inv invoices;
begin
  select coalesce(sum(gross),0) as gross, coalesce(sum(gst_amount),0) as gst, coalesce(sum(net),0) as net
  into totals
  from invoice_line_items where invoice_id = p_invoice_id;

  select * into inv from invoices where id = p_invoice_id;

  update invoices
  set gross = totals.gross,
      gst = totals.gst,
      net = totals.net,
      status = case
        when totals.net <= 0 then 'Paid'
        when inv.paid <= 0 then 'Pending'
        when inv.paid >= totals.net then 'Paid'
        else 'Partial'
      end
  where id = p_invoice_id
  returning * into inv;

  return inv;
end;
$$;


ALTER FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update master_packages
  set price = coalesce((select sum(amount) from package_line_items where package_id = p_package_id), 0)
  where id = p_package_id;
end;
$$;


ALTER FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_refunds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid",
    "invoice_id" "uuid",
    "amount" numeric NOT NULL,
    "reason" "text" NOT NULL,
    "refunded_by" "uuid",
    "refunded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "refund_mode" "text",
    "approved_by" "uuid",
    "refund_payment_id" "uuid",
    "patient_id" "uuid"
);


ALTER TABLE "public"."payment_refunds" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_balance numeric;
  v_refund_number text;
  new_refund_payment payments;
  new_refund payment_refunds;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a refund.';
  end if;

  v_balance := get_advance_balance(p_patient_id);
  if p_amount > v_balance then
    raise exception 'Refund amount (Rs.%) exceeds available advance balance (Rs.%).', p_amount, v_balance;
  end if;

  v_refund_number := next_refund_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_refund_number, p_patient_id, p_amount, 'Refund from advance: ' || p_reason, auth.uid(), 'refund')
  returning * into new_refund_payment;

  if p_refund_mode is not null then
    insert into payment_modes (payment_id, mode, amount) values (new_refund_payment.id, p_refund_mode, p_amount);
  end if;

  insert into patient_ledger (patient_id, payment_id, entry_type, amount, remarks, recorded_by)
  values (p_patient_id, new_refund_payment.id, 'Advance Refunded', -p_amount, p_reason, auth.uid());

  insert into payment_refunds (payment_id, invoice_id, patient_id, amount, reason, refunded_by, refund_mode, approved_by, refund_payment_id)
  values (null, null, p_patient_id, p_amount, p_reason, auth.uid(), p_refund_mode, p_approved_by, new_refund_payment.id)
  returning * into new_refund;

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_allocated numeric;
  v_already_refunded numeric;
  v_refundable numeric;
  new_refund payment_refunds;
  v_patient_id uuid;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  select amount into v_allocated from payment_allocations where payment_id = p_payment_id and invoice_id = p_invoice_id;
  if v_allocated is null then
    raise exception 'This payment was not applied to that invoice.';
  end if;

  select coalesce(sum(amount), 0) into v_already_refunded
  from payment_refunds where payment_id = p_payment_id and invoice_id = p_invoice_id;

  v_refundable := v_allocated - v_already_refunded;
  if p_amount > v_refundable then
    raise exception 'Refund amount (Rs.%) exceeds what remains refundable for this invoice (Rs.%).', p_amount, v_refundable;
  end if;

  insert into payment_refunds (payment_id, invoice_id, amount, reason, refunded_by)
  values (p_payment_id, p_invoice_id, p_amount, p_reason, auth.uid())
  returning * into new_refund;

  update invoices set paid = paid - p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."payment_refunds"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_allocated numeric;
  v_already_refunded numeric;
  v_refundable numeric;
  v_patient_id uuid;
  v_invoice_number text;
  v_refund_number text;
  new_refund payment_refunds;
  new_refund_payment payments;
begin
  if is_day_closed(ist_date(now())) then
    raise exception 'Today has been closed for financial reconciliation. An administrator must reopen it before refunds can be processed.';
  end if;

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A refund reason is required.';
  end if;

  if p_amount is null or p_amount <= 0 then
    raise exception 'Refund amount must be greater than zero.';
  end if;

  if p_approved_by is null then
    raise exception 'An approver is required for a refund.';
  end if;

  select amount into v_allocated from payment_allocations where payment_id = p_payment_id and invoice_id = p_invoice_id;
  if v_allocated is null then
    raise exception 'This payment was not applied to that invoice.';
  end if;

  select coalesce(sum(amount), 0) into v_already_refunded
  from payment_refunds where payment_id = p_payment_id and invoice_id = p_invoice_id;

  v_refundable := v_allocated - v_already_refunded;
  if p_amount > v_refundable then
    raise exception 'Refund amount (Rs.%) exceeds what remains refundable for this invoice (Rs.%).', p_amount, v_refundable;
  end if;

  select patient_id into v_patient_id from payments where id = p_payment_id;
  select invoice_number into v_invoice_number from invoices where id = p_invoice_id;
  v_refund_number := next_refund_number();

  insert into payments (receipt_number, patient_id, total_amount, remarks, collected_by, payment_type)
  values (v_refund_number, v_patient_id, p_amount, 'Refund against ' || coalesce(v_invoice_number, 'invoice') || ': ' || p_reason, auth.uid(), 'refund')
  returning * into new_refund_payment;

  if p_refund_mode is not null then
    insert into payment_modes (payment_id, mode, amount) values (new_refund_payment.id, p_refund_mode, p_amount);
  end if;

  insert into payment_refunds (payment_id, invoice_id, patient_id, amount, reason, refunded_by, refund_mode, approved_by, refund_payment_id)
  values (p_payment_id, p_invoice_id, v_patient_id, p_amount, p_reason, auth.uid(), p_refund_mode, p_approved_by, new_refund_payment.id)
  returning * into new_refund;

  update invoices set paid = paid - p_amount where id = p_invoice_id;
  perform recompute_invoice_totals(p_invoice_id);

  return new_refund;
end;
$$;


ALTER FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patients" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "uhid" "text" NOT NULL,
    "first_name" "text" NOT NULL,
    "last_name" "text" NOT NULL,
    "age" integer,
    "gender" "text",
    "mobile" "text" NOT NULL,
    "address" "text",
    "blood_group" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "date_of_birth" "date",
    "alternate_mobile" "text",
    "city" "text",
    "state" "text",
    "pin_code" "text",
    "id_type" "text",
    "id_number" "text",
    "insurance_scheme" "text",
    "insurance_number" "text",
    "referral_source" "text",
    "preferred_language" "text",
    "remarks" "text",
    CONSTRAINT "mobile_ten_digits" CHECK (("mobile" ~ '^[0-9]{10}$'::"text")),
    CONSTRAINT "patients_gender_check" CHECK (("gender" = ANY (ARRAY['M'::"text", 'F'::"text", 'O'::"text"])))
);


ALTER TABLE "public"."patients" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") RETURNS "public"."patients"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_uhid text;
  new_patient patients;
begin
  new_uhid := 'VEH-' || lpad(nextval('patient_uhid_seq')::text, 5, '0');

  insert into patients (uhid, first_name, last_name, age, gender, mobile, address, blood_group)
  values (new_uhid, p_first_name, p_last_name, p_age, p_gender, p_mobile, p_address, p_blood_group)
  returning * into new_patient;

  return new_patient;
end;
$$;


ALTER FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date" DEFAULT NULL::"date", "p_alternate_mobile" "text" DEFAULT NULL::"text", "p_city" "text" DEFAULT NULL::"text", "p_state" "text" DEFAULT NULL::"text", "p_pin_code" "text" DEFAULT NULL::"text", "p_id_type" "text" DEFAULT NULL::"text", "p_id_number" "text" DEFAULT NULL::"text", "p_insurance_scheme" "text" DEFAULT NULL::"text", "p_insurance_number" "text" DEFAULT NULL::"text", "p_referral_source" "text" DEFAULT NULL::"text", "p_preferred_language" "text" DEFAULT NULL::"text", "p_remarks" "text" DEFAULT NULL::"text") RETURNS "public"."patients"
    LANGUAGE "plpgsql"
    AS $$
declare
  new_uhid text;
  new_patient patients;
begin
  new_uhid := 'VEH-' || lpad(nextval('patient_uhid_seq')::text, 5, '0');

  insert into patients (
    uhid, first_name, last_name, age, gender, mobile, address, blood_group,
    date_of_birth, alternate_mobile, city, state, pin_code,
    id_type, id_number, insurance_scheme, insurance_number,
    referral_source, preferred_language, remarks
  )
  values (
    new_uhid, initcap(trim(p_first_name)), initcap(trim(p_last_name)), p_age, p_gender, p_mobile, p_address, p_blood_group,
    p_date_of_birth, p_alternate_mobile, initcap(trim(p_city)), p_state, p_pin_code,
    p_id_type, p_id_number, p_insurance_scheme, p_insurance_number,
    p_referral_source, p_preferred_language, p_remarks
  )
  returning * into new_patient;

  return new_patient;
end;
$$;


ALTER FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_invoice_id uuid;
begin
  select invoice_id into v_invoice_id from invoice_line_items where id = p_line_item_id;
  delete from invoice_line_items where id = p_line_item_id;
  return recompute_invoice_totals(v_invoice_id);
end;
$$;


ALTER FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text" DEFAULT NULL::"text") RETURNS "public"."invoices"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_invoice_id uuid;
  v_service_name text;
begin
  select invoice_id, service_name into v_invoice_id, v_service_name
  from invoice_line_items where id = p_line_item_id;

  if v_invoice_id is null then
    raise exception 'Line item not found';
  end if;

  if p_reason is not null and trim(p_reason) <> '' then
    insert into invoice_modifications (invoice_id, modified_by, action, reason, details)
    values (v_invoice_id, auth.uid(), 'line_item_removed', p_reason, v_service_name);
  end if;

  delete from invoice_line_items where id = p_line_item_id;
  return recompute_invoice_totals(v_invoice_id);
end;
$$;


ALTER FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to reopen a closed day.';
  end if;

  insert into day_closing_reopens (closing_date, reason, reopened_by)
  values (p_date, p_reason, auth.uid());

  delete from day_closings where closing_date = p_date;
end;
$$;


ALTER FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_reconciliation" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "mode" "text" NOT NULL,
    "expected" numeric DEFAULT 0 NOT NULL,
    "actual" numeric DEFAULT 0 NOT NULL,
    "variance" numeric DEFAULT 0 NOT NULL,
    "reason" "text",
    "approved_by" "uuid",
    "saved_by" "uuid",
    "saved_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."day_reconciliation" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text" DEFAULT NULL::"text", "p_approved_by" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."day_reconciliation"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_variance numeric;
  row day_reconciliation;
begin
  v_variance := p_actual - p_expected;

  if abs(v_variance) > 0.01 and (p_reason is null or trim(p_reason) = '') then
    raise exception 'A variance reason is required when actual does not match expected (Rs.%).', v_variance;
  end if;

  insert into day_reconciliation (closing_date, mode, expected, actual, variance, reason, approved_by, saved_by)
  values (p_closing_date, p_mode, p_expected, p_actual, v_variance, p_reason, p_approved_by, auth.uid())
  on conflict (closing_date, mode) do update
    set expected = excluded.expected, actual = excluded.actual, variance = excluded.variance,
        reason = excluded.reason, approved_by = excluded.approved_by, saved_by = excluded.saved_by, saved_at = now()
  returning * into row;

  return row;
end;
$$;


ALTER FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid" DEFAULT NULL::"uuid") RETURNS "public"."queue_entries"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_patient_id uuid;
  v_encounter_id uuid;
  v_visit_id uuid;
  v_new_entry queue_entries;
begin
  select patient_id, encounter_id into v_patient_id, v_encounter_id
  from surgical_cases where id = p_case_id;

  if v_patient_id is null then
    raise exception 'Case not found.';
  end if;

  -- Most recent visit for this patient dated today (IST) -- deliberately
  -- NOT filtering by queue_entries status, since visits.status stays
  -- 'Open' regardless of whether its queue entries are Done.
  select id into v_visit_id
  from visits
  where patient_id = v_patient_id
    and ist_date(created_at) = ist_date(now())
  order by created_at desc
  limit 1;

  if v_visit_id is null then
    raise exception 'No visit found for this patient today -- they need to check in at Front Office first.';
  end if;

  v_new_entry := issue_queue_token(v_visit_id, 'Doctor');

  update queue_entries
  set status = p_queue_status, sent_out_at = now()
  where id = v_new_entry.id
  returning * into v_new_entry;

  insert into encounter_audit_log (encounter_id, message, created_by)
  values (v_encounter_id, p_audit_message, p_user_id);

  return v_new_entry;
end;
$$;


ALTER FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_surgical_case_iol_category"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  if new.status = 'Approved' and new.final_iol_category is not null then
    update public.surgical_cases
    set iol_category = new.final_iol_category,
        biometry_done = true
    where encounter_id = new.encounter_id
      and (iol_category is distinct from new.final_iol_category or biometry_done = false);
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_surgical_case_iol_category"() OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."appointments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid",
    "patient_name_temp" "text",
    "mobile_temp" "text",
    "doctor_id" "uuid",
    "appointment_date" "date" NOT NULL,
    "appointment_time" time without time zone NOT NULL,
    "visit_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "remarks" "text",
    "status" "text" DEFAULT 'Booked'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "appointments_business_hours" CHECK ((("appointment_time" >= '10:00:00'::time without time zone) AND ("appointment_time" <= '18:00:00'::time without time zone))),
    CONSTRAINT "appointments_status_check" CHECK (("status" = ANY (ARRAY['Booked'::"text", 'Checked-in'::"text", 'Cancelled'::"text", 'No-show'::"text"]))),
    CONSTRAINT "appointments_visit_type_check" CHECK (("visit_type" = ANY (ARRAY['New Consultation'::"text", 'Follow-up'::"text", 'Investigation Only'::"text", 'Post-operative Review'::"text", 'Emergency'::"text", 'Procedure'::"text"])))
);


ALTER TABLE "public"."appointments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."biometry_iol_versions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "biometry_record_id" "uuid" NOT NULL,
    "version_no" integer NOT NULL,
    "power" "text",
    "formula" "text",
    "status" "text" DEFAULT 'Approved'::"text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "biometry_iol_versions_status_check" CHECK (("status" = ANY (ARRAY['Approved'::"text", 'Superseded'::"text"])))
);


ALTER TABLE "public"."biometry_iol_versions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."biometry_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "surgeon_id" "uuid",
    "procedure_name" "text",
    "surgical_eye" "text",
    "status" "text" DEFAULT 'Awaiting Biometry'::"text" NOT NULL,
    "measurements" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verify_device" "text",
    "verify_remarks" "text",
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "target_refraction" "text",
    "formula_results" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "selected_formula" "text",
    "final_iol_power" "text",
    "final_iol_category" "text",
    "final_iol_catalog_id" "uuid",
    "surgeon_notes" "text",
    "approved_by" "uuid",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    "invoice_id" "uuid",
    "doctor_instructions" "text",
    "surgical_case_id" "uuid",
    CONSTRAINT "biometry_records_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "biometry_records_status_check" CHECK (("status" = ANY (ARRAY['Awaiting Biometry'::"text", 'Measured'::"text", 'Calculated'::"text", 'Approved'::"text", 'Cancelled'::"text"]))),
    CONSTRAINT "biometry_records_surgical_eye_check" CHECK (("surgical_eye" = ANY (ARRAY['RE'::"text", 'LE'::"text", 'OU'::"text"])))
);


ALTER TABLE "public"."biometry_records" OWNER TO "postgres";


COMMENT ON COLUMN "public"."biometry_records"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



COMMENT ON COLUMN "public"."biometry_records"."surgical_case_id" IS 'Optional link back to the surgical case this record originated from
   (set by Counselling''s "Send for Biometry"). NULL for standalone
   OPD-ordered biometry, which is equally valid and does not involve a
   surgical case at all.';



CREATE TABLE IF NOT EXISTS "public"."clinical_attachments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entity_type" "text" NOT NULL,
    "entity_id" "uuid" NOT NULL,
    "file_name" "text" NOT NULL,
    "storage_path" "text" NOT NULL,
    "file_size" bigint,
    "mime_type" "text",
    "uploaded_by" "uuid",
    "uploaded_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."clinical_attachments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."clinical_examinations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "external_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "external_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "anterior_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "anterior_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "cdr_re" "text",
    "cdr_le" "text",
    "gonio_re" "text",
    "gonio_le" "text",
    "disc_appearance" "text",
    "glaucoma_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "posterior_findings" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "posterior_status" "text" DEFAULT 'Not started'::"text" NOT NULL,
    "remarks_re" "text",
    "remarks_le" "text",
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "clinical_examinations_anterior_status_check" CHECK (("anterior_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_external_status_check" CHECK (("external_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_glaucoma_status_check" CHECK (("glaucoma_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Done'::"text"]))),
    CONSTRAINT "clinical_examinations_posterior_status_check" CHECK (("posterior_status" = ANY (ARRAY['Not started'::"text", 'In progress'::"text", 'Normal'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."clinical_examinations" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."credit_note_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."credit_note_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."day_closing_reopens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "closing_date" "date" NOT NULL,
    "reason" "text" NOT NULL,
    "reopened_by" "uuid",
    "reopened_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."day_closing_reopens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."diagnoses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text" DEFAULT 'primary'::"text" NOT NULL,
    "eye" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    CONSTRAINT "diagnoses_category_check" CHECK (("category" = ANY (ARRAY['primary'::"text", 'secondary'::"text", 'associated'::"text", 'systemic'::"text"])))
);


ALTER TABLE "public"."diagnoses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."doctor_repeat_findings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "re_va" "text",
    "le_va" "text",
    "re_iop" numeric,
    "le_iop" numeric,
    "re_sph" "text",
    "le_sph" "text",
    "re_cyl" "text",
    "le_cyl" "text",
    "notes" "text",
    "recorded_by" "uuid",
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."doctor_repeat_findings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."encounter_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."encounter_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."encounters" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "doctor_id" "uuid",
    "chief_complaint" "text",
    "status" "text" DEFAULT 'In Consultation'::"text" NOT NULL,
    "started_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "chief_complaint_chips" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "hx_duration" "text",
    "hx_laterality" "text",
    "hx_hopi" "text",
    "ocular_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "medical_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "family_history" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "hx_drug_allergy" "text",
    "patient_instructions" "text",
    "encounter_type" "text" DEFAULT 'New Consultation'::"text" NOT NULL,
    "visit_outcome" "text",
    CONSTRAINT "encounters_encounter_type_check" CHECK (("encounter_type" = ANY (ARRAY['New Consultation'::"text", 'Follow-up'::"text"]))),
    CONSTRAINT "encounters_status_check" CHECK (("status" = ANY (ARRAY['In Consultation'::"text", 'Completed'::"text"])))
);


ALTER TABLE "public"."encounters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hospital_settings" (
    "id" boolean DEFAULT true NOT NULL,
    "name" "text" DEFAULT 'VEDA EYE HOSPITAL'::"text",
    "unit_line" "text" DEFAULT 'A UNIT OF VEDA MEDITECH OPC PVT LTD'::"text",
    "regn_no" "text" DEFAULT 'UK/HDR/DRA/2026/1014'::"text",
    "address_line1" "text" DEFAULT 'Kankhal Road, Vishnu Garden Lane 1,'::"text",
    "address_line2" "text" DEFAULT 'Above Sharma Imaging, Singhdwar,'::"text",
    "city_state_pin" "text" DEFAULT 'Haridwar, Uttarakhand-PIN:249404'::"text",
    "phone" "text" DEFAULT '01334-322523/+91-9084736880'::"text",
    "email" "text" DEFAULT 'admin@vedaeyehospital.com'::"text",
    "terms_text" "text" DEFAULT 'Invoice due & Payable on Receipt.'::"text",
    "logo_data_url" "text",
    "case_sheet_hide_header" boolean DEFAULT false NOT NULL,
    "glasses_rx_hide_header" boolean DEFAULT false NOT NULL,
    "print_letterhead_space_cm" numeric DEFAULT 5 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid",
    CONSTRAINT "hospital_settings_singleton" CHECK ("id")
);


ALTER TABLE "public"."hospital_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."investigation_orders" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "eye" "text",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "status" "text" DEFAULT 'Ordered'::"text" NOT NULL,
    "billed" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "result_notes" "text",
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "result_data" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verification_checklist" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "verified_by" "uuid",
    "verified_at" timestamp with time zone,
    "unable_reason" "text",
    "billing_status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "billing_note" "text",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    "invoice_id" "uuid",
    "started_at" timestamp with time zone,
    "started_by" "uuid",
    CONSTRAINT "investigation_orders_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['Pending'::"text", 'Billed'::"text", 'Denied'::"text", 'Deferred'::"text"]))),
    CONSTRAINT "investigation_orders_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text"]))),
    CONSTRAINT "investigation_orders_status_check" CHECK (("status" = ANY (ARRAY['Ordered'::"text", 'In Progress'::"text", 'Completed'::"text", 'Available'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."investigation_orders" OWNER TO "postgres";


COMMENT ON COLUMN "public"."investigation_orders"."result_data" IS 'Type-specific measurement fields, e.g. {"cmt-re": "245", "rnfl": "85"} for OCT.';



COMMENT ON COLUMN "public"."investigation_orders"."verification_checklist" IS 'Which verification checklist items were checked at verify time, e.g. {"Scan quality acceptable": true}.';



COMMENT ON COLUMN "public"."investigation_orders"."billing_status" IS 'Front Office billing state: Pending (not yet actioned), Billed (invoiced), Denied (patient declined), Deferred (patient will return later).';



CREATE TABLE IF NOT EXISTS "public"."invoice_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "service_code" "text",
    "service_name" "text" NOT NULL,
    "dept" "text",
    "qty" integer DEFAULT 1 NOT NULL,
    "rate" numeric NOT NULL,
    "gst_pct" numeric DEFAULT 0 NOT NULL,
    "disc" numeric DEFAULT 0 NOT NULL,
    "gross" numeric NOT NULL,
    "gst_amount" numeric NOT NULL,
    "net" numeric NOT NULL
);


ALTER TABLE "public"."invoice_line_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoice_modifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "modified_by" "uuid",
    "modified_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action" "text" NOT NULL,
    "reason" "text" NOT NULL,
    "details" "text",
    CONSTRAINT "invoice_modifications_action_check" CHECK (("action" = ANY (ARRAY['line_item_removed'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."invoice_modifications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."invoice_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."invoice_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_clinical_observations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_clinical_observations_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_clinical_observations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_data_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "master_table" "text" NOT NULL,
    "record_code" "text" NOT NULL,
    "action" "text" NOT NULL,
    "detail" "text",
    "changed_by" "uuid",
    "changed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_data_audit_log_action_check" CHECK (("action" = ANY (ARRAY['Create'::"text", 'Edit'::"text", 'Deactivate'::"text", 'Reactivate'::"text"])))
);


ALTER TABLE "public"."master_data_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_diagnoses" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_diagnoses_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_diagnoses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_drugs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "brand" "text",
    "generic" "text" NOT NULL,
    "strength" "text",
    "form" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "rate" numeric DEFAULT 0,
    "gst_pct" numeric DEFAULT 12,
    CONSTRAINT "master_drugs_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_drugs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_history_options" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "category" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text" NOT NULL,
    CONSTRAINT "master_history_options_category_check" CHECK (("category" = ANY (ARRAY['chief_complaint'::"text", 'ocular_history'::"text", 'medical_history'::"text", 'family_history'::"text"]))),
    CONSTRAINT "master_history_options_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_history_options" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_iol_catalog" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "brand" "text" NOT NULL,
    "model" "text" NOT NULL,
    "manufacturer" "text",
    "category" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "origin" "text",
    CONSTRAINT "master_iol_catalog_category_check" CHECK (("category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "master_iol_catalog_origin_check" CHECK (("origin" = ANY (ARRAY['Indian'::"text", 'Imported'::"text"]))),
    CONSTRAINT "master_iol_catalog_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_iol_catalog" OWNER TO "postgres";


COMMENT ON COLUMN "public"."master_iol_catalog"."origin" IS 'Indian or Imported make of this specific IOL SKU.';



CREATE TABLE IF NOT EXISTS "public"."master_iop_methods" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_iop_methods_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_iop_methods" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_ot_sessions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "start_time" time without time zone NOT NULL,
    "end_time" time without time zone NOT NULL,
    "default_room" "text",
    "capacity" integer DEFAULT 4 NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_ot_sessions_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_ot_sessions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_packages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "price" numeric NOT NULL,
    "includes" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "iol_category" "text",
    "origin" "text",
    "surgery_id" "uuid",
    CONSTRAINT "master_packages_iol_category_check" CHECK (("iol_category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "master_packages_origin_check" CHECK (("origin" = ANY (ARRAY['Indian'::"text", 'Imported'::"text"]))),
    CONSTRAINT "master_packages_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_packages" OWNER TO "postgres";


COMMENT ON COLUMN "public"."master_packages"."iol_category" IS 'Matches biometry_records.final_iol_category. Package is only shown during
   counselling once biometry has advised this IOL type. NULL = not IOL-
   specific (e.g. Glaucoma surgery package), shown regardless of IOL type.';



COMMENT ON COLUMN "public"."master_packages"."origin" IS 'Indian or Imported IOL make -- price tier within an iol_category.
   NULL for non-IOL packages.';



CREATE TABLE IF NOT EXISTS "public"."master_procedures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    CONSTRAINT "master_procedures_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_procedures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_services" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "dept" "text" NOT NULL,
    "rate" numeric NOT NULL,
    "gst_pct" numeric DEFAULT 0 NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "investigation_package" "text",
    CONSTRAINT "master_services_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_services" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_surgeries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "category" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_surgeries_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_surgeries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."master_surgical_consumables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "code" "text" NOT NULL,
    "name" "text" NOT NULL,
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "master_surgical_consumables_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text"])))
);


ALTER TABLE "public"."master_surgical_consumables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."medical_fitness_referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "referred_by" "uuid",
    "referred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "reviewing_doctor_id" "uuid",
    "status" "text" DEFAULT 'Pending Review'::"text" NOT NULL,
    "fitness_notes" "text",
    "cleared_by" "uuid",
    "cleared_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "medical_fitness_referrals_status_check" CHECK (("status" = ANY (ARRAY['Pending Review'::"text", 'Cleared'::"text", 'Not Fit'::"text"])))
);


ALTER TABLE "public"."medical_fitness_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_assessments" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'Draft'::"text" NOT NULL,
    "va_scale" "text" DEFAULT 'Snellen'::"text" NOT NULL,
    "re_dist_unaided" "text",
    "re_dist_glasses" "text",
    "re_dist_ph" "text",
    "re_near_unaided" "text",
    "le_dist_unaided" "text",
    "le_dist_glasses" "text",
    "le_dist_ph" "text",
    "le_near_unaided" "text",
    "ref_pd" "text",
    "ref_vd" "text",
    "ref_obj_re_sph" "text",
    "ref_obj_re_cyl" "text",
    "ref_obj_re_axis" "text",
    "ref_obj_le_sph" "text",
    "ref_obj_le_cyl" "text",
    "ref_obj_le_axis" "text",
    "ref_subj_re_sph" "text",
    "ref_subj_re_cyl" "text",
    "ref_subj_re_axis" "text",
    "ref_subj_le_sph" "text",
    "ref_subj_le_cyl" "text",
    "ref_subj_le_axis" "text",
    "ref_final_re_sph" "text",
    "ref_final_re_cyl" "text",
    "ref_final_re_axis" "text",
    "ref_final_re_add" "text",
    "ref_final_le_sph" "text",
    "ref_final_le_cyl" "text",
    "ref_final_le_axis" "text",
    "ref_final_le_add" "text",
    "iop_method" "text" DEFAULT 'Non-Contact Tonometer (NCT)'::"text",
    "iop_time" "text",
    "add_k1" "text",
    "add_k2" "text",
    "add_axial_length" "text",
    "add_pachymetry" "text",
    "add_white_to_white" "text",
    "add_schirmer" "text",
    "add_color_vision" "text",
    "add_ocular_motility" "text",
    "add_syringing" "text",
    "observation_chips" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "observations_text" "text",
    "section_va_done" boolean DEFAULT false NOT NULL,
    "section_refraction_done" boolean DEFAULT false NOT NULL,
    "section_iop_done" boolean DEFAULT false NOT NULL,
    "section_additional_done" boolean DEFAULT false NOT NULL,
    "section_obs_done" boolean DEFAULT false NOT NULL,
    "recorded_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    CONSTRAINT "optometry_assessments_status_check" CHECK (("status" = ANY (ARRAY['Draft'::"text", 'Completed'::"text"]))),
    CONSTRAINT "optometry_assessments_va_scale_check" CHECK (("va_scale" = ANY (ARRAY['Snellen'::"text", 'LogMAR'::"text", 'ETDRS'::"text"])))
);


ALTER TABLE "public"."optometry_assessments" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assessment_id" "uuid" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid"
);


ALTER TABLE "public"."optometry_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."optometry_iop_readings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "assessment_id" "uuid" NOT NULL,
    "eye" "text" NOT NULL,
    "value" numeric NOT NULL,
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "recorded_by" "uuid",
    CONSTRAINT "optometry_iop_readings_eye_check" CHECK (("eye" = ANY (ARRAY['RE'::"text", 'LE'::"text"]))),
    CONSTRAINT "optometry_iop_readings_value_check" CHECK ((("value" > (0)::numeric) AND ("value" <= (80)::numeric)))
);


ALTER TABLE "public"."optometry_iop_readings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_consumables" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "added_by" "uuid",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ot_intraop_consumables" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "kind" "text" NOT NULL,
    "name" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "management" "text",
    "outcome" "text",
    "added_by" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ot_intraop_events_kind_check" CHECK (("kind" = ANY (ARRAY['Event'::"text", 'Complication'::"text"]))),
    CONSTRAINT "ot_intraop_events_severity_check" CHECK (("severity" = ANY (ARRAY['Mild'::"text", 'Moderate'::"text", 'Severe'::"text"])))
);


ALTER TABLE "public"."ot_intraop_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_intraop_records" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "checkin_items" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "checkin_completed_at" timestamp with time zone,
    "procedure_name" "text",
    "procedure_eye" "text",
    "assistant_surgeon" "text",
    "ot_nurse" "text",
    "procedure_status" "text",
    "procedure_start_time" time without time zone,
    "procedure_end_time" time without time zone,
    "abandon_reason" "text",
    "anaesthesia_type" "text",
    "anaesthetist" "text",
    "anaesthesia_start" time without time zone,
    "anaesthesia_end" time without time zone,
    "anaesthesia_remarks" "text",
    "anaesthesia_recorded_at" timestamp with time zone,
    "implant_manufacturer" "text",
    "implant_model" "text",
    "implant_power" "text",
    "implant_serial" "text",
    "implant_expiry" "date",
    "implant_eye" "text",
    "variance_reason" "text",
    "operative_notes" "text",
    "surgical_outcome" "text",
    "outcome_remarks" "text",
    "recovery_destination" "text",
    "recovery_monitoring" "text",
    "recovery_instructions" "text",
    "recovery_concerns" "text",
    "transferred_at" timestamp with time zone,
    "completed_at" timestamp with time zone,
    "completed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "ot_intraop_records_procedure_status_check" CHECK (("procedure_status" = ANY (ARRAY['Completed'::"text", 'Partially Completed'::"text", 'Converted'::"text", 'Abandoned'::"text"])))
);


ALTER TABLE "public"."ot_intraop_records" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_schedule" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "surgeon_id" "uuid",
    "scheduled_date" "date" NOT NULL,
    "scheduled_time" time without time zone,
    "status" "text" DEFAULT 'Scheduled'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "session_id" "uuid",
    "room" "text",
    "sequence_number" integer,
    "expected_duration_minutes" integer DEFAULT 30,
    "cancellation_reason" "text",
    "cancellation_remarks" "text",
    "cancelled_by" "uuid",
    "cancelled_at" timestamp with time zone,
    "reschedule_count" integer DEFAULT 0 NOT NULL,
    "patient_reported_at" timestamp with time zone,
    CONSTRAINT "ot_schedule_status_check" CHECK (("status" = ANY (ARRAY['Scheduled'::"text", 'In Progress'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."ot_schedule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ot_schedule_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "action" "text" NOT NULL,
    "detail" "text",
    "changed_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."ot_schedule_audit_log" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."package_code_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."package_code_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."package_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "package_id" "uuid" NOT NULL,
    "description" "text" NOT NULL,
    "amount" numeric DEFAULT 0 NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."package_line_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."patient_ledger" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "payment_id" "uuid",
    "entry_type" "text" NOT NULL,
    "amount" numeric NOT NULL,
    "remarks" "text",
    "recorded_by" "uuid",
    "recorded_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "patient_ledger_entry_type_check" CHECK (("entry_type" = ANY (ARRAY['Advance Collected'::"text", 'Advance Adjusted'::"text", 'Advance Refunded'::"text"])))
);


ALTER TABLE "public"."patient_ledger" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."patient_uhid_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."patient_uhid_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "amount" numeric NOT NULL
);


ALTER TABLE "public"."payment_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_edits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "old_reference" "text",
    "new_reference" "text",
    "old_remarks" "text",
    "new_remarks" "text",
    "old_modes" "jsonb",
    "new_modes" "jsonb",
    "reason" "text" NOT NULL,
    "edited_by" "uuid",
    "edited_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."payment_edits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_modes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "payment_id" "uuid" NOT NULL,
    "mode" "text" NOT NULL,
    "amount" numeric NOT NULL,
    CONSTRAINT "payment_modes_mode_check" CHECK (("mode" = ANY (ARRAY['Cash'::"text", 'Card'::"text", 'UPI'::"text", 'Cheque'::"text", 'Bank Transfer'::"text"])))
);


ALTER TABLE "public"."payment_modes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."pharmacy_queue" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "prescription_id" "uuid",
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "dispensed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "pharmacy_queue_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Dispensed'::"text"])))
);


ALTER TABLE "public"."pharmacy_queue" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_counselling_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "topic" "text" NOT NULL,
    "status" "text" DEFAULT 'Pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_counselling_items_status_check" CHECK (("status" = ANY (ARRAY['Pending'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_counselling_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "after_period" "text" NOT NULL,
    "visit_type" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "clinic" "text" DEFAULT 'General'::"text" NOT NULL,
    "instructions" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_followups_visit_type_check" CHECK (("visit_type" = ANY (ARRAY['Routine'::"text", 'Post-operative'::"text", 'Urgent'::"text"])))
);


ALTER TABLE "public"."plan_followups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_optical_advice" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "advice" "text" NOT NULL,
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_optical_advice_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_optical_advice" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_procedures" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "eye" "text",
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    "notes" "text",
    "billing_status" "text" DEFAULT 'Pending'::"text",
    "billed" boolean DEFAULT false,
    "invoice_id" "uuid",
    "billing_updated_by" "uuid",
    "billing_updated_at" timestamp with time zone,
    CONSTRAINT "plan_procedures_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_procedures" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."plan_referrals" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "encounter_id" "uuid" NOT NULL,
    "destination" "text" NOT NULL,
    "reason" "text",
    "status" "text" DEFAULT 'Planned'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_by" "uuid",
    CONSTRAINT "plan_referrals_status_check" CHECK (("status" = ANY (ARRAY['Planned'::"text", 'Done'::"text"])))
);


ALTER TABLE "public"."plan_referrals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."print_templates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "template_key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "html" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "updated_by" "uuid"
);


ALTER TABLE "public"."print_templates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."profiles" (
    "id" "uuid" NOT NULL,
    "full_name" "text" NOT NULL,
    "designation" "text" NOT NULL,
    "department" "text",
    "status" "text" DEFAULT 'Active'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "code" "text",
    "registration_no" "text",
    CONSTRAINT "profiles_status_check" CHECK (("status" = ANY (ARRAY['Active'::"text", 'Inactive'::"text", 'Locked'::"text"])))
);


ALTER TABLE "public"."profiles" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."receipt_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."receipt_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_complications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "severity" "text" NOT NULL,
    "management" "text",
    "outcome" "text",
    "added_by" "uuid",
    "occurred_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "recovery_complications_severity_check" CHECK (("severity" = ANY (ARRAY['Mild'::"text", 'Moderate'::"text", 'Severe'::"text"])))
);


ALTER TABLE "public"."recovery_complications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_episodes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "ot_schedule_id" "uuid" NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "visit_id" "uuid",
    "admission_date" "date",
    "surgery_date" "date",
    "discharge_date" "date",
    "recovery_start" time without time zone,
    "recovery_end" time without time zone,
    "consciousness" "text",
    "pain_level" "text",
    "nausea" "text",
    "dressing_status" "text",
    "escalation_required" boolean DEFAULT false NOT NULL,
    "escalation_reason" "text",
    "observations" "text",
    "discharge_checklist" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "discharge_instructions" "text",
    "discharge_notes" "text",
    "discharged_by" "uuid",
    "discharged_at" timestamp with time zone,
    "closure_status" "text",
    "closure_outcome" "text",
    "closure_remarks" "text",
    "closed_by" "uuid",
    "closed_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."recovery_episodes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_followups" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "visit_label" "text" NOT NULL,
    "scheduled_date" "date" NOT NULL,
    "status" "text" DEFAULT 'Scheduled'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    "rescheduled_count" integer DEFAULT 0 NOT NULL,
    "visit_id" "uuid",
    "encounter_id" "uuid",
    CONSTRAINT "recovery_followups_status_check" CHECK (("status" = ANY (ARRAY['Scheduled'::"text", 'Due'::"text", 'Completed'::"text"])))
);


ALTER TABLE "public"."recovery_followups" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recovery_medications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "recovery_episode_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "sig" "text" NOT NULL,
    "reason" "text",
    "added_by" "uuid",
    "added_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."recovery_medications" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."refund_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."refund_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."surgical_case_notes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "surgical_case_id" "uuid" NOT NULL,
    "note" "text" NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."surgical_case_notes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."surgical_cases" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "patient_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "procedure_name" "text" NOT NULL,
    "eye" "text",
    "package_id" "uuid",
    "status" "text" DEFAULT 'Pending Workup'::"text" NOT NULL,
    "consent_taken" boolean DEFAULT false NOT NULL,
    "biometry_done" boolean DEFAULT false NOT NULL,
    "fitness_cleared" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "package_billed" boolean DEFAULT false NOT NULL,
    "visit_id" "uuid",
    "surgeon_id" "uuid",
    "priority" "text" DEFAULT 'Routine'::"text" NOT NULL,
    "iol_category" "text",
    "decision" "text",
    "decision_reason" "text",
    "investigations_complete" boolean DEFAULT false NOT NULL,
    "advance_payment_id" "uuid",
    "biometry_required" boolean DEFAULT true NOT NULL,
    "biometry_skip_reason" "text",
    "package_locked" boolean DEFAULT false NOT NULL,
    "decision_locked" boolean DEFAULT false NOT NULL,
    "fitness_required" boolean DEFAULT true,
    "fitness_skip_reason" "text",
    "proceed_status" "text" DEFAULT 'Deciding'::"text" NOT NULL,
    "iol_order_notes" "text",
    "last_reminder_sent_at" timestamp with time zone,
    "reminder_count" integer DEFAULT 0 NOT NULL,
    "treatment_instructions" "text",
    "decision_accepted_at" timestamp with time zone,
    CONSTRAINT "surgical_cases_decision_check" CHECK (("decision" = ANY (ARRAY['Accepted'::"text", 'Wants Time to Decide'::"text", 'Discuss with Family'::"text", 'Financial Constraint'::"text", 'Declined'::"text", 'Second Opinion'::"text", 'Other'::"text"]))),
    CONSTRAINT "surgical_cases_iol_category_check" CHECK (("iol_category" = ANY (ARRAY['Monofocal'::"text", 'Monofocal Toric'::"text", 'Multifocal'::"text", 'EDOF'::"text"]))),
    CONSTRAINT "surgical_cases_priority_check" CHECK (("priority" = ANY (ARRAY['Routine'::"text", 'Urgent'::"text", 'Emergency'::"text"]))),
    CONSTRAINT "surgical_cases_proceed_status_check" CHECK (("proceed_status" = ANY (ARRAY['Deciding'::"text", 'Awaiting Return'::"text", 'Proceeding'::"text"]))),
    CONSTRAINT "surgical_cases_status_check" CHECK (("status" = ANY (ARRAY['Pending Workup'::"text", 'Ready for Scheduling'::"text", 'Scheduled'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."surgical_cases" OWNER TO "postgres";


COMMENT ON COLUMN "public"."surgical_cases"."proceed_status" IS 'Deciding: just advised, no decision yet. Awaiting Return: patient said
   they will come back another day for workup/decision. Proceeding:
   patient is moving forward now (same visit or already returned).';
COMMENT ON COLUMN "public"."surgical_cases"."iol_order_notes" IS 'Free text -- e.g. "Ordered Alcon monofocal +21D from XYZ Optics,
   expected Friday". Simple by design, no structured procurement
   tracking yet.';
COMMENT ON COLUMN "public"."surgical_cases"."iol_category" IS 'Denormalized from biometry_records.final_iol_category once Biometry is
   Approved -- lets the counselling package picker filter Master Data
   packages without joining to biometry_records every time.';



COMMENT ON COLUMN "public"."surgical_cases"."advance_payment_id" IS 'Set once an advance is collected in M11 against the package chosen here.';



CREATE SEQUENCE IF NOT EXISTS "public"."visit_number_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."visit_number_seq" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."workflow_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "visit_id" "uuid" NOT NULL,
    "encounter_id" "uuid",
    "kind" "text" NOT NULL,
    "status" "text" DEFAULT 'Requested'::"text" NOT NULL,
    "requested_by" "uuid",
    "requested_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_by" "uuid",
    "resolved_at" timestamp with time zone,
    CONSTRAINT "workflow_requests_kind_check" CHECK (("kind" = ANY (ARRAY['Biometry'::"text", 'Medical Fitness'::"text", 'Counselling'::"text"]))),
    CONSTRAINT "workflow_requests_status_check" CHECK (("status" = ANY (ARRAY['Requested'::"text", 'Completed'::"text", 'Cancelled'::"text"])))
);


ALTER TABLE "public"."workflow_requests" OWNER TO "postgres";


ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clinical_attachments"
    ADD CONSTRAINT "clinical_attachments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_encounter_id_key" UNIQUE ("encounter_id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_credit_note_number_key" UNIQUE ("credit_note_number");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_closing_reopens"
    ADD CONSTRAINT "day_closing_reopens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_closing_date_key" UNIQUE ("closing_date");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_opening_date_key" UNIQUE ("opening_date");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_closing_date_mode_key" UNIQUE ("closing_date", "mode");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."diagnoses"
    ADD CONSTRAINT "diagnoses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hospital_settings"
    ADD CONSTRAINT "hospital_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_invoice_number_key" UNIQUE ("invoice_number");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_clinical_observations"
    ADD CONSTRAINT "master_clinical_observations_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_clinical_observations"
    ADD CONSTRAINT "master_clinical_observations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_data_audit_log"
    ADD CONSTRAINT "master_data_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_diagnoses"
    ADD CONSTRAINT "master_diagnoses_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_diagnoses"
    ADD CONSTRAINT "master_diagnoses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_drugs"
    ADD CONSTRAINT "master_drugs_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_drugs"
    ADD CONSTRAINT "master_drugs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_history_options"
    ADD CONSTRAINT "master_history_options_category_code_key" UNIQUE ("category", "code");



ALTER TABLE ONLY "public"."master_history_options"
    ADD CONSTRAINT "master_history_options_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_iol_catalog"
    ADD CONSTRAINT "master_iol_catalog_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_iol_catalog"
    ADD CONSTRAINT "master_iol_catalog_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_iop_methods"
    ADD CONSTRAINT "master_iop_methods_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_iop_methods"
    ADD CONSTRAINT "master_iop_methods_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_ot_sessions"
    ADD CONSTRAINT "master_ot_sessions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_procedures"
    ADD CONSTRAINT "master_procedures_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_procedures"
    ADD CONSTRAINT "master_procedures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_services"
    ADD CONSTRAINT "master_services_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_services"
    ADD CONSTRAINT "master_services_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_surgeries"
    ADD CONSTRAINT "master_surgeries_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_surgeries"
    ADD CONSTRAINT "master_surgeries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."master_surgical_consumables"
    ADD CONSTRAINT "master_surgical_consumables_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."master_surgical_consumables"
    ADD CONSTRAINT "master_surgical_consumables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_visit_id_key" UNIQUE ("visit_id");



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_ot_schedule_id_key" UNIQUE ("ot_schedule_id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."package_line_items"
    ADD CONSTRAINT "package_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."patients"
    ADD CONSTRAINT "patients_uhid_key" UNIQUE ("uhid");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_modes"
    ADD CONSTRAINT "payment_modes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_receipt_number_key" UNIQUE ("receipt_number");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_encounter_id_key" UNIQUE ("encounter_id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_template_key_key" UNIQUE ("template_key");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_code_key" UNIQUE ("code");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."queue_entries"
    ADD CONSTRAINT "queue_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_ot_schedule_id_key" UNIQUE ("ot_schedule_id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_visit_number_key" UNIQUE ("visit_number");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_pkey" PRIMARY KEY ("id");



CREATE INDEX "credit_notes_invoice_idx" ON "public"."credit_notes" USING "btree" ("invoice_id");



CREATE INDEX "credit_notes_patient_idx" ON "public"."credit_notes" USING "btree" ("patient_id", "created_at");



CREATE INDEX "doctor_repeat_findings_encounter_idx" ON "public"."doctor_repeat_findings" USING "btree" ("encounter_id", "recorded_at");



CREATE INDEX "encounter_audit_log_encounter_idx" ON "public"."encounter_audit_log" USING "btree" ("encounter_id", "created_at");



CREATE INDEX "idx_appointments_doctor_id" ON "public"."appointments" USING "btree" ("doctor_id");



CREATE INDEX "idx_appointments_patient_id" ON "public"."appointments" USING "btree" ("patient_id");



CREATE INDEX "idx_appt_date" ON "public"."appointments" USING "btree" ("appointment_date");



CREATE INDEX "idx_biometry_iol_versions_created_by" ON "public"."biometry_iol_versions" USING "btree" ("created_by");



CREATE INDEX "idx_biometry_iol_versions_record" ON "public"."biometry_iol_versions" USING "btree" ("biometry_record_id");



CREATE INDEX "idx_biometry_records_approved_by" ON "public"."biometry_records" USING "btree" ("approved_by");



CREATE INDEX "idx_biometry_records_billing_updated_by" ON "public"."biometry_records" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_biometry_records_encounter_id" ON "public"."biometry_records" USING "btree" ("encounter_id");



CREATE INDEX "idx_biometry_records_final_iol_catalog_id" ON "public"."biometry_records" USING "btree" ("final_iol_catalog_id");



CREATE INDEX "idx_biometry_records_invoice_id" ON "public"."biometry_records" USING "btree" ("invoice_id");



CREATE INDEX "idx_biometry_records_status" ON "public"."biometry_records" USING "btree" ("status");



CREATE INDEX "idx_biometry_records_surgeon_id" ON "public"."biometry_records" USING "btree" ("surgeon_id");



CREATE INDEX "idx_biometry_records_verified_by" ON "public"."biometry_records" USING "btree" ("verified_by");



CREATE INDEX "idx_biometry_records_visit" ON "public"."biometry_records" USING "btree" ("visit_id");



CREATE INDEX "idx_clinical_attachments_entity" ON "public"."clinical_attachments" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_clinical_attachments_uploaded_by" ON "public"."clinical_attachments" USING "btree" ("uploaded_by");



CREATE INDEX "idx_clinical_examinations_recorded_by" ON "public"."clinical_examinations" USING "btree" ("recorded_by");



CREATE INDEX "idx_credit_notes_approved_by" ON "public"."credit_notes" USING "btree" ("approved_by");



CREATE INDEX "idx_credit_notes_created_by" ON "public"."credit_notes" USING "btree" ("created_by");



CREATE INDEX "idx_credit_notes_payment_id" ON "public"."credit_notes" USING "btree" ("payment_id");



CREATE INDEX "idx_day_closing_reopens_reopened_by" ON "public"."day_closing_reopens" USING "btree" ("reopened_by");



CREATE INDEX "idx_day_closings_closed_by" ON "public"."day_closings" USING "btree" ("closed_by");



CREATE INDEX "idx_day_openings_opened_by" ON "public"."day_openings" USING "btree" ("opened_by");



CREATE INDEX "idx_day_reconciliation_approved_by" ON "public"."day_reconciliation" USING "btree" ("approved_by");



CREATE INDEX "idx_day_reconciliation_saved_by" ON "public"."day_reconciliation" USING "btree" ("saved_by");



CREATE INDEX "idx_doctor_repeat_findings_recorded_by" ON "public"."doctor_repeat_findings" USING "btree" ("recorded_by");



CREATE INDEX "idx_encounter_audit_log_created_by" ON "public"."encounter_audit_log" USING "btree" ("created_by");



CREATE INDEX "idx_encounters_doctor_id" ON "public"."encounters" USING "btree" ("doctor_id");



CREATE INDEX "idx_encounters_visit_id" ON "public"."encounters" USING "btree" ("visit_id");



CREATE INDEX "idx_hospital_settings_updated_by" ON "public"."hospital_settings" USING "btree" ("updated_by");



CREATE INDEX "idx_investigation_orders_billing_updated_by" ON "public"."investigation_orders" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_investigation_orders_completed_by" ON "public"."investigation_orders" USING "btree" ("completed_by");



CREATE INDEX "idx_investigation_orders_encounter_id" ON "public"."investigation_orders" USING "btree" ("encounter_id");



CREATE INDEX "idx_investigation_orders_invoice_id" ON "public"."investigation_orders" USING "btree" ("invoice_id");



CREATE INDEX "idx_investigation_orders_started_by" ON "public"."investigation_orders" USING "btree" ("started_by");



CREATE INDEX "idx_investigation_orders_verified_by" ON "public"."investigation_orders" USING "btree" ("verified_by");



CREATE INDEX "idx_invoice_line_items_invoice_id" ON "public"."invoice_line_items" USING "btree" ("invoice_id");



CREATE INDEX "idx_invoice_modifications_invoice_id" ON "public"."invoice_modifications" USING "btree" ("invoice_id");



CREATE INDEX "idx_invoice_modifications_modified_by" ON "public"."invoice_modifications" USING "btree" ("modified_by");



CREATE INDEX "idx_invoices_cancelled_by" ON "public"."invoices" USING "btree" ("cancelled_by");



CREATE INDEX "idx_invoices_patient_id" ON "public"."invoices" USING "btree" ("patient_id");



CREATE INDEX "idx_invoices_visit_id" ON "public"."invoices" USING "btree" ("visit_id");



CREATE INDEX "idx_master_data_audit_log_changed_by" ON "public"."master_data_audit_log" USING "btree" ("changed_by");



CREATE INDEX "idx_master_history_options_category_status" ON "public"."master_history_options" USING "btree" ("category", "status");



CREATE INDEX "idx_master_iol_catalog_category" ON "public"."master_iol_catalog" USING "btree" ("category", "status");



CREATE INDEX "idx_master_packages_surgery_id" ON "public"."master_packages" USING "btree" ("surgery_id");



CREATE INDEX "idx_medical_fitness_referrals_cleared_by" ON "public"."medical_fitness_referrals" USING "btree" ("cleared_by");



CREATE INDEX "idx_medical_fitness_referrals_encounter_id" ON "public"."medical_fitness_referrals" USING "btree" ("encounter_id");



CREATE INDEX "idx_medical_fitness_referrals_referred_by" ON "public"."medical_fitness_referrals" USING "btree" ("referred_by");



CREATE INDEX "idx_medical_fitness_referrals_reviewing_doctor_id" ON "public"."medical_fitness_referrals" USING "btree" ("reviewing_doctor_id");



CREATE INDEX "idx_medical_fitness_referrals_surgical_case_id" ON "public"."medical_fitness_referrals" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_mfr_status" ON "public"."medical_fitness_referrals" USING "btree" ("status");



CREATE INDEX "idx_mfr_visit" ON "public"."medical_fitness_referrals" USING "btree" ("visit_id");



CREATE INDEX "idx_optometry_assessments_completed_by" ON "public"."optometry_assessments" USING "btree" ("completed_by");



CREATE INDEX "idx_optometry_assessments_recorded_by" ON "public"."optometry_assessments" USING "btree" ("recorded_by");



CREATE INDEX "idx_optometry_audit_log_created_by" ON "public"."optometry_audit_log" USING "btree" ("created_by");



CREATE INDEX "idx_optometry_iop_readings_recorded_by" ON "public"."optometry_iop_readings" USING "btree" ("recorded_by");



CREATE INDEX "idx_ot_intraop_consumables_added_by" ON "public"."ot_intraop_consumables" USING "btree" ("added_by");



CREATE INDEX "idx_ot_intraop_consumables_ot_schedule_id" ON "public"."ot_intraop_consumables" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_intraop_events_added_by" ON "public"."ot_intraop_events" USING "btree" ("added_by");



CREATE INDEX "idx_ot_intraop_events_schedule" ON "public"."ot_intraop_events" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_intraop_records_completed_by" ON "public"."ot_intraop_records" USING "btree" ("completed_by");



CREATE INDEX "idx_ot_intraop_records_surgical_case_id" ON "public"."ot_intraop_records" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_ot_schedule_audit_log_changed_by" ON "public"."ot_schedule_audit_log" USING "btree" ("changed_by");



CREATE INDEX "idx_ot_schedule_audit_log_ot_schedule_id" ON "public"."ot_schedule_audit_log" USING "btree" ("ot_schedule_id");



CREATE INDEX "idx_ot_schedule_cancelled_by" ON "public"."ot_schedule" USING "btree" ("cancelled_by");



CREATE INDEX "idx_ot_schedule_date" ON "public"."ot_schedule" USING "btree" ("scheduled_date");



CREATE INDEX "idx_ot_schedule_session" ON "public"."ot_schedule" USING "btree" ("session_id");



CREATE INDEX "idx_ot_schedule_surgeon_id" ON "public"."ot_schedule" USING "btree" ("surgeon_id");



CREATE INDEX "idx_ot_schedule_surgical_case_id" ON "public"."ot_schedule" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_patient_ledger_patient_id" ON "public"."patient_ledger" USING "btree" ("patient_id");



CREATE INDEX "idx_patient_ledger_payment_id" ON "public"."patient_ledger" USING "btree" ("payment_id");



CREATE INDEX "idx_patient_ledger_recorded_by" ON "public"."patient_ledger" USING "btree" ("recorded_by");



CREATE INDEX "idx_patients_mobile" ON "public"."patients" USING "btree" ("mobile");



CREATE INDEX "idx_payment_allocations_invoice_id" ON "public"."payment_allocations" USING "btree" ("invoice_id");



CREATE INDEX "idx_payment_allocations_payment_id" ON "public"."payment_allocations" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_edits_edited_by" ON "public"."payment_edits" USING "btree" ("edited_by");



CREATE INDEX "idx_payment_modes_payment_id" ON "public"."payment_modes" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_refunds_approved_by" ON "public"."payment_refunds" USING "btree" ("approved_by");



CREATE INDEX "idx_payment_refunds_invoice_id" ON "public"."payment_refunds" USING "btree" ("invoice_id");



CREATE INDEX "idx_payment_refunds_patient_id" ON "public"."payment_refunds" USING "btree" ("patient_id");



CREATE INDEX "idx_payment_refunds_payment_id" ON "public"."payment_refunds" USING "btree" ("payment_id");



CREATE INDEX "idx_payment_refunds_refund_payment_id" ON "public"."payment_refunds" USING "btree" ("refund_payment_id");



CREATE INDEX "idx_payment_refunds_refunded_by" ON "public"."payment_refunds" USING "btree" ("refunded_by");



CREATE INDEX "idx_payments_collected_by" ON "public"."payments" USING "btree" ("collected_by");



CREATE INDEX "idx_payments_patient_id" ON "public"."payments" USING "btree" ("patient_id");



CREATE INDEX "idx_pharmacy_queue_patient_id" ON "public"."pharmacy_queue" USING "btree" ("patient_id");



CREATE INDEX "idx_pharmacy_queue_prescription_id" ON "public"."pharmacy_queue" USING "btree" ("prescription_id");



CREATE INDEX "idx_plan_counselling_items_created_by" ON "public"."plan_counselling_items" USING "btree" ("created_by");



CREATE INDEX "idx_plan_counselling_items_encounter_id" ON "public"."plan_counselling_items" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_followups_created_by" ON "public"."plan_followups" USING "btree" ("created_by");



CREATE INDEX "idx_plan_optical_advice_created_by" ON "public"."plan_optical_advice" USING "btree" ("created_by");



CREATE INDEX "idx_plan_optical_advice_encounter_id" ON "public"."plan_optical_advice" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_procedures_billing_updated_by" ON "public"."plan_procedures" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_plan_procedures_created_by" ON "public"."plan_procedures" USING "btree" ("created_by");



CREATE INDEX "idx_plan_procedures_encounter_id" ON "public"."plan_procedures" USING "btree" ("encounter_id");



CREATE INDEX "idx_plan_procedures_invoice_id" ON "public"."plan_procedures" USING "btree" ("invoice_id");



CREATE INDEX "idx_plan_referrals_created_by" ON "public"."plan_referrals" USING "btree" ("created_by");



CREATE INDEX "idx_plan_referrals_encounter_id" ON "public"."plan_referrals" USING "btree" ("encounter_id");



CREATE INDEX "idx_prescriptions_billing_updated_by" ON "public"."prescriptions" USING "btree" ("billing_updated_by");



CREATE INDEX "idx_prescriptions_encounter_id" ON "public"."prescriptions" USING "btree" ("encounter_id");



CREATE INDEX "idx_print_templates_updated_by" ON "public"."print_templates" USING "btree" ("updated_by");



CREATE INDEX "idx_queue_dept_status" ON "public"."queue_entries" USING "btree" ("department", "status");



CREATE INDEX "idx_queue_visit" ON "public"."queue_entries" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_complications_added_by" ON "public"."recovery_complications" USING "btree" ("added_by");



CREATE INDEX "idx_recovery_complications_recovery_episode_id" ON "public"."recovery_complications" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_recovery_episodes_case" ON "public"."recovery_episodes" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_recovery_episodes_closed_by" ON "public"."recovery_episodes" USING "btree" ("closed_by");



CREATE INDEX "idx_recovery_episodes_discharged_by" ON "public"."recovery_episodes" USING "btree" ("discharged_by");



CREATE INDEX "idx_recovery_episodes_visit_id" ON "public"."recovery_episodes" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_followups_encounter_id" ON "public"."recovery_followups" USING "btree" ("encounter_id");



CREATE INDEX "idx_recovery_followups_recovery_episode_id" ON "public"."recovery_followups" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_recovery_followups_visit_id" ON "public"."recovery_followups" USING "btree" ("visit_id");



CREATE INDEX "idx_recovery_medications_added_by" ON "public"."recovery_medications" USING "btree" ("added_by");



CREATE INDEX "idx_recovery_medications_recovery_episode_id" ON "public"."recovery_medications" USING "btree" ("recovery_episode_id");



CREATE INDEX "idx_surgical_case_notes_created_by" ON "public"."surgical_case_notes" USING "btree" ("created_by");



CREATE INDEX "idx_surgical_case_notes_surgical_case_id" ON "public"."surgical_case_notes" USING "btree" ("surgical_case_id");



CREATE INDEX "idx_surgical_cases_advance_payment_id" ON "public"."surgical_cases" USING "btree" ("advance_payment_id");



CREATE INDEX "idx_surgical_cases_encounter_id" ON "public"."surgical_cases" USING "btree" ("encounter_id");



CREATE INDEX "idx_surgical_cases_package_id" ON "public"."surgical_cases" USING "btree" ("package_id");



CREATE INDEX "idx_surgical_cases_patient_id" ON "public"."surgical_cases" USING "btree" ("patient_id");



CREATE INDEX "idx_surgical_cases_surgeon_id" ON "public"."surgical_cases" USING "btree" ("surgeon_id");



CREATE INDEX "idx_surgical_cases_visit_id" ON "public"."surgical_cases" USING "btree" ("visit_id");



CREATE INDEX "idx_visits_appointment_id" ON "public"."visits" USING "btree" ("appointment_id");



CREATE INDEX "idx_visits_cancelled_by" ON "public"."visits" USING "btree" ("cancelled_by");



CREATE INDEX "idx_visits_doctor_id" ON "public"."visits" USING "btree" ("doctor_id");



CREATE INDEX "idx_visits_patient" ON "public"."visits" USING "btree" ("patient_id");



CREATE INDEX "idx_workflow_requests_encounter_id" ON "public"."workflow_requests" USING "btree" ("encounter_id");



CREATE INDEX "idx_workflow_requests_requested_by" ON "public"."workflow_requests" USING "btree" ("requested_by");



CREATE INDEX "idx_workflow_requests_resolved_by" ON "public"."workflow_requests" USING "btree" ("resolved_by");



CREATE INDEX "master_data_audit_log_idx" ON "public"."master_data_audit_log" USING "btree" ("master_table", "changed_at");



CREATE UNIQUE INDEX "one_primary_diagnosis_per_encounter" ON "public"."diagnoses" USING "btree" ("encounter_id") WHERE (("category" = 'primary'::"text") AND ("status" = 'Active'::"text"));



CREATE UNIQUE INDEX "one_visit_per_patient_per_day" ON "public"."visits" USING "btree" ("patient_id", "public"."ist_date"("created_at"));



CREATE INDEX "optometry_audit_log_assessment_idx" ON "public"."optometry_audit_log" USING "btree" ("assessment_id", "created_at");



CREATE INDEX "optometry_iop_readings_assessment_idx" ON "public"."optometry_iop_readings" USING "btree" ("assessment_id", "eye", "recorded_at");



CREATE INDEX "package_line_items_package_idx" ON "public"."package_line_items" USING "btree" ("package_id", "sort_order");



CREATE INDEX "payment_edits_payment_idx" ON "public"."payment_edits" USING "btree" ("payment_id", "edited_at");



CREATE INDEX "workflow_requests_visit_idx" ON "public"."workflow_requests" USING "btree" ("visit_id", "status");



CREATE OR REPLACE TRIGGER "trg_sync_surgical_case_iol_category" AFTER INSERT OR UPDATE ON "public"."biometry_records" FOR EACH ROW EXECUTE FUNCTION "public"."sync_surgical_case_iol_category"();



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."appointments"
    ADD CONSTRAINT "appointments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_biometry_record_id_fkey" FOREIGN KEY ("biometry_record_id") REFERENCES "public"."biometry_records"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."biometry_iol_versions"
    ADD CONSTRAINT "biometry_iol_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_final_iol_catalog_id_fkey" FOREIGN KEY ("final_iol_catalog_id") REFERENCES "public"."master_iol_catalog"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."biometry_records"
    ADD CONSTRAINT "biometry_records_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."clinical_attachments"
    ADD CONSTRAINT "clinical_attachments_uploaded_by_fkey" FOREIGN KEY ("uploaded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."clinical_examinations"
    ADD CONSTRAINT "clinical_examinations_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."credit_notes"
    ADD CONSTRAINT "credit_notes_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."day_closing_reopens"
    ADD CONSTRAINT "day_closing_reopens_reopened_by_fkey" FOREIGN KEY ("reopened_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_closings"
    ADD CONSTRAINT "day_closings_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_openings"
    ADD CONSTRAINT "day_openings_opened_by_fkey" FOREIGN KEY ("opened_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."day_reconciliation"
    ADD CONSTRAINT "day_reconciliation_saved_by_fkey" FOREIGN KEY ("saved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."diagnoses"
    ADD CONSTRAINT "diagnoses_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."doctor_repeat_findings"
    ADD CONSTRAINT "doctor_repeat_findings_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounter_audit_log"
    ADD CONSTRAINT "encounter_audit_log_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."encounters"
    ADD CONSTRAINT "encounters_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."hospital_settings"
    ADD CONSTRAINT "hospital_settings_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_started_by_fkey" FOREIGN KEY ("started_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."investigation_orders"
    ADD CONSTRAINT "investigation_orders_verified_by_fkey" FOREIGN KEY ("verified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."invoice_modifications"
    ADD CONSTRAINT "invoice_modifications_modified_by_fkey" FOREIGN KEY ("modified_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."master_data_audit_log"
    ADD CONSTRAINT "master_data_audit_log_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."master_packages"
    ADD CONSTRAINT "master_packages_surgery_id_fkey" FOREIGN KEY ("surgery_id") REFERENCES "public"."master_surgeries"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_cleared_by_fkey" FOREIGN KEY ("cleared_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_referred_by_fkey" FOREIGN KEY ("referred_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_reviewing_doctor_id_fkey" FOREIGN KEY ("reviewing_doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."medical_fitness_referrals"
    ADD CONSTRAINT "medical_fitness_referrals_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_assessments"
    ADD CONSTRAINT "optometry_assessments_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_assessment_id_fkey" FOREIGN KEY ("assessment_id") REFERENCES "public"."optometry_assessments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."optometry_audit_log"
    ADD CONSTRAINT "optometry_audit_log_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_assessment_id_fkey" FOREIGN KEY ("assessment_id") REFERENCES "public"."optometry_assessments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."optometry_iop_readings"
    ADD CONSTRAINT "optometry_iop_readings_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_consumables"
    ADD CONSTRAINT "ot_intraop_consumables_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_events"
    ADD CONSTRAINT "ot_intraop_events_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_intraop_records"
    ADD CONSTRAINT "ot_intraop_records_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule_audit_log"
    ADD CONSTRAINT "ot_schedule_audit_log_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_session_id_fkey" FOREIGN KEY ("session_id") REFERENCES "public"."master_ot_sessions"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."ot_schedule"
    ADD CONSTRAINT "ot_schedule_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."package_line_items"
    ADD CONSTRAINT "package_line_items_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "public"."master_packages"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."patient_ledger"
    ADD CONSTRAINT "patient_ledger_recorded_by_fkey" FOREIGN KEY ("recorded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."payment_allocations"
    ADD CONSTRAINT "payment_allocations_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_edited_by_fkey" FOREIGN KEY ("edited_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_edits"
    ADD CONSTRAINT "payment_edits_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_modes"
    ADD CONSTRAINT "payment_modes_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_payment_id_fkey" FOREIGN KEY ("payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_refund_payment_id_fkey" FOREIGN KEY ("refund_payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."payment_refunds"
    ADD CONSTRAINT "payment_refunds_refunded_by_fkey" FOREIGN KEY ("refunded_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_collected_by_fkey" FOREIGN KEY ("collected_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."payments"
    ADD CONSTRAINT "payments_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."pharmacy_queue"
    ADD CONSTRAINT "pharmacy_queue_prescription_id_fkey" FOREIGN KEY ("prescription_id") REFERENCES "public"."prescriptions"("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_counselling_items"
    ADD CONSTRAINT "plan_counselling_items_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_followups"
    ADD CONSTRAINT "plan_followups_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_optical_advice"
    ADD CONSTRAINT "plan_optical_advice_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."plan_procedures"
    ADD CONSTRAINT "plan_procedures_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."plan_referrals"
    ADD CONSTRAINT "plan_referrals_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_billing_updated_by_fkey" FOREIGN KEY ("billing_updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."prescriptions"
    ADD CONSTRAINT "prescriptions_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."print_templates"
    ADD CONSTRAINT "print_templates_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."profiles"
    ADD CONSTRAINT "profiles_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."queue_entries"
    ADD CONSTRAINT "queue_entries_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_complications"
    ADD CONSTRAINT "recovery_complications_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_closed_by_fkey" FOREIGN KEY ("closed_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_discharged_by_fkey" FOREIGN KEY ("discharged_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_ot_schedule_id_fkey" FOREIGN KEY ("ot_schedule_id") REFERENCES "public"."ot_schedule"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."recovery_episodes"
    ADD CONSTRAINT "recovery_episodes_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."recovery_followups"
    ADD CONSTRAINT "recovery_followups_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_added_by_fkey" FOREIGN KEY ("added_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."recovery_medications"
    ADD CONSTRAINT "recovery_medications_recovery_episode_id_fkey" FOREIGN KEY ("recovery_episode_id") REFERENCES "public"."recovery_episodes"("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."surgical_case_notes"
    ADD CONSTRAINT "surgical_case_notes_surgical_case_id_fkey" FOREIGN KEY ("surgical_case_id") REFERENCES "public"."surgical_cases"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_advance_payment_id_fkey" FOREIGN KEY ("advance_payment_id") REFERENCES "public"."payments"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_package_id_fkey" FOREIGN KEY ("package_id") REFERENCES "public"."master_packages"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_surgeon_id_fkey" FOREIGN KEY ("surgeon_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."surgical_cases"
    ADD CONSTRAINT "surgical_cases_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_appointment_id_fkey" FOREIGN KEY ("appointment_id") REFERENCES "public"."appointments"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_doctor_id_fkey" FOREIGN KEY ("doctor_id") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."visits"
    ADD CONSTRAINT "visits_patient_id_fkey" FOREIGN KEY ("patient_id") REFERENCES "public"."patients"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_encounter_id_fkey" FOREIGN KEY ("encounter_id") REFERENCES "public"."encounters"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "public"."profiles"("id");



ALTER TABLE ONLY "public"."workflow_requests"
    ADD CONSTRAINT "workflow_requests_visit_id_fkey" FOREIGN KEY ("visit_id") REFERENCES "public"."visits"("id");



ALTER TABLE "public"."appointments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."biometry_iol_versions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."biometry_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clinical_attachments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."clinical_examinations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."credit_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_closing_reopens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_closings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_openings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."day_reconciliation" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."diagnoses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."doctor_repeat_findings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."encounter_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."encounters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hospital_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."investigation_orders" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoice_line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoice_modifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_clinical_observations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_data_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_diagnoses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_drugs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_history_options" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_iol_catalog" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_iop_methods" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_ot_sessions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_packages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_procedures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_services" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_surgeries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."master_surgical_consumables" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."medical_fitness_referrals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_assessments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."optometry_iop_readings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_consumables" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_intraop_records" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_schedule" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."ot_schedule_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."package_line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patient_ledger" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."patients" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_allocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_edits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_modes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_refunds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payments" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."pharmacy_queue" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_counselling_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_followups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_optical_advice" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_procedures" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."plan_referrals" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."prescriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."print_templates" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."profiles" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."queue_entries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_complications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_episodes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_followups" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."recovery_medications" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "staff_all_access" ON "public"."appointments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."biometry_iol_versions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."biometry_records" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."clinical_attachments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."clinical_examinations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."credit_notes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_closing_reopens" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_closings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_openings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."day_reconciliation" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."diagnoses" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."doctor_repeat_findings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."encounter_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."encounters" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."hospital_settings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."investigation_orders" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoice_line_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoice_modifications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."invoices" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_clinical_observations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_data_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_diagnoses" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_drugs" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_history_options" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_iol_catalog" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_iop_methods" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_ot_sessions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_packages" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_procedures" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_services" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_surgeries" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."master_surgical_consumables" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."medical_fitness_referrals" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_assessments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."optometry_iop_readings" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_consumables" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_events" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_intraop_records" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_schedule" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."ot_schedule_audit_log" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."package_line_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."patient_ledger" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."patients" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_allocations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_edits" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_modes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payment_refunds" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."payments" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."pharmacy_queue" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_counselling_items" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_followups" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_optical_advice" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_procedures" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."plan_referrals" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."prescriptions" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."print_templates" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."profiles" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."queue_entries" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_complications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_episodes" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_followups" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."recovery_medications" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."surgical_case_notes" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."surgical_cases" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."visits" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "staff_all_access" ON "public"."workflow_requests" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."surgical_case_notes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."surgical_cases" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."workflow_requests" ENABLE ROW LEVEL SECURITY;




ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";


GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";






















































































































































GRANT ALL ON TABLE "public"."invoices" TO "anon";
GRANT ALL ON TABLE "public"."invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."invoices" TO "service_role";



GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_invoice_line_item"("p_invoice_id" "uuid", "p_service_code" "text", "p_qty" integer, "p_disc_type" "text", "p_disc_value" numeric, "p_disc_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."apply_advance_adjustment"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."book_ot_slot"("p_case_id" "uuid", "p_date" "date", "p_session_id" "uuid", "p_surgeon_id" "uuid", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_invoice"("p_invoice_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON TABLE "public"."visits" TO "anon";
GRANT ALL ON TABLE "public"."visits" TO "authenticated";
GRANT ALL ON TABLE "public"."visits" TO "service_role";



GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_in_appointment"("p_appointment_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."day_closings" TO "anon";
GRANT ALL ON TABLE "public"."day_closings" TO "authenticated";
GRANT ALL ON TABLE "public"."day_closings" TO "service_role";



GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."close_day"("p_date" "date", "p_notes" "text") TO "service_role";



GRANT ALL ON TABLE "public"."payments" TO "anon";
GRANT ALL ON TABLE "public"."payments" TO "authenticated";
GRANT ALL ON TABLE "public"."payments" TO "service_role";



GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."collect_advance"("p_patient_id" "uuid", "p_advance_type" "text", "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."collect_payment"("p_patient_id" "uuid", "p_invoice_ids" "uuid"[], "p_amount" numeric, "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON TABLE "public"."credit_notes" TO "anon";
GRANT ALL ON TABLE "public"."credit_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."credit_notes" TO "service_role";



GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_credit_note"("p_patient_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_approved_by" "uuid", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_invoice_for_visit"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_purpose" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_walk_in_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid", "p_visit_type" "text", "p_referral_source" "text", "p_priority" "text", "p_surgery_type" "text") TO "service_role";



GRANT ALL ON TABLE "public"."prescriptions" TO "anon";
GRANT ALL ON TABLE "public"."prescriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."prescriptions" TO "service_role";



GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."dispense_prescription_and_bill"("p_prescription_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."edit_payment_clerical"("p_payment_id" "uuid", "p_modes" "jsonb", "p_reference" "text", "p_remarks" "text", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "anon";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric) TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_package_invoice"("p_patient_id" "uuid", "p_visit_id" "uuid", "p_package_id" "uuid", "p_payment_mode" "text", "p_advance_amount" numeric, "p_surgical_case_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_advance_balance"("p_patient_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_or_create_postop_review_visit"("p_patient_id" "uuid", "p_doctor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_ot_availability"("p_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_day_closed"("p_date" "date") TO "service_role";



GRANT ALL ON TABLE "public"."queue_entries" TO "anon";
GRANT ALL ON TABLE "public"."queue_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."queue_entries" TO "service_role";



GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."issue_queue_token"("p_visit_id" "uuid", "p_department" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "anon";
GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."ist_date"("ts" timestamp with time zone) TO "service_role";



GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_credit_note_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_package_code"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_package_code"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_package_code"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_refund_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "anon";
GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."next_visit_number"() TO "service_role";



GRANT ALL ON TABLE "public"."day_openings" TO "anon";
GRANT ALL ON TABLE "public"."day_openings" TO "authenticated";
GRANT ALL ON TABLE "public"."day_openings" TO "service_role";



GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."open_day"("p_date" "date", "p_opening_balance" numeric, "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optometry_complete"("p_queue_entry_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_invoice_totals"("p_invoice_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recompute_package_price"("p_package_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."payment_refunds" TO "anon";
GRANT ALL ON TABLE "public"."payment_refunds" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_refunds" TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_advance"("p_patient_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."refund_payment"("p_payment_id" "uuid", "p_invoice_id" "uuid", "p_amount" numeric, "p_reason" "text", "p_refund_mode" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."patients" TO "anon";
GRANT ALL ON TABLE "public"."patients" TO "authenticated";
GRANT ALL ON TABLE "public"."patients" TO "service_role";



GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."register_patient"("p_first_name" "text", "p_last_name" "text", "p_age" integer, "p_gender" "text", "p_mobile" "text", "p_address" "text", "p_blood_group" "text", "p_date_of_birth" "date", "p_alternate_mobile" "text", "p_city" "text", "p_state" "text", "p_pin_code" "text", "p_id_type" "text", "p_id_number" "text", "p_insurance_scheme" "text", "p_insurance_number" "text", "p_referral_source" "text", "p_preferred_language" "text", "p_remarks" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."remove_invoice_line_item"("p_line_item_id" "uuid", "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reopen_day"("p_date" "date", "p_reason" "text") TO "service_role";



GRANT ALL ON TABLE "public"."day_reconciliation" TO "anon";
GRANT ALL ON TABLE "public"."day_reconciliation" TO "authenticated";
GRANT ALL ON TABLE "public"."day_reconciliation" TO "service_role";



GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."save_reconciliation"("p_closing_date" "date", "p_mode" "text", "p_expected" numeric, "p_actual" numeric, "p_reason" "text", "p_approved_by" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_case_to_department_queue"("p_case_id" "uuid", "p_queue_status" "text", "p_audit_message" "text", "p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_surgical_case_iol_category"() TO "service_role";


















GRANT ALL ON TABLE "public"."appointments" TO "anon";
GRANT ALL ON TABLE "public"."appointments" TO "authenticated";
GRANT ALL ON TABLE "public"."appointments" TO "service_role";



GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "anon";
GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."biometry_iol_versions" TO "service_role";



GRANT ALL ON TABLE "public"."biometry_records" TO "anon";
GRANT ALL ON TABLE "public"."biometry_records" TO "authenticated";
GRANT ALL ON TABLE "public"."biometry_records" TO "service_role";



GRANT ALL ON TABLE "public"."clinical_attachments" TO "anon";
GRANT ALL ON TABLE "public"."clinical_attachments" TO "authenticated";
GRANT ALL ON TABLE "public"."clinical_attachments" TO "service_role";



GRANT ALL ON TABLE "public"."clinical_examinations" TO "anon";
GRANT ALL ON TABLE "public"."clinical_examinations" TO "authenticated";
GRANT ALL ON TABLE "public"."clinical_examinations" TO "service_role";



GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."credit_note_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."day_closing_reopens" TO "anon";
GRANT ALL ON TABLE "public"."day_closing_reopens" TO "authenticated";
GRANT ALL ON TABLE "public"."day_closing_reopens" TO "service_role";



GRANT ALL ON TABLE "public"."diagnoses" TO "anon";
GRANT ALL ON TABLE "public"."diagnoses" TO "authenticated";
GRANT ALL ON TABLE "public"."diagnoses" TO "service_role";



GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "anon";
GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "authenticated";
GRANT ALL ON TABLE "public"."doctor_repeat_findings" TO "service_role";



GRANT ALL ON TABLE "public"."encounter_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."encounter_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."encounter_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."encounters" TO "anon";
GRANT ALL ON TABLE "public"."encounters" TO "authenticated";
GRANT ALL ON TABLE "public"."encounters" TO "service_role";



GRANT ALL ON TABLE "public"."hospital_settings" TO "anon";
GRANT ALL ON TABLE "public"."hospital_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."hospital_settings" TO "service_role";



GRANT ALL ON TABLE "public"."investigation_orders" TO "anon";
GRANT ALL ON TABLE "public"."investigation_orders" TO "authenticated";
GRANT ALL ON TABLE "public"."investigation_orders" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_line_items" TO "anon";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_modifications" TO "anon";
GRANT ALL ON TABLE "public"."invoice_modifications" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_modifications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."invoice_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."master_clinical_observations" TO "anon";
GRANT ALL ON TABLE "public"."master_clinical_observations" TO "authenticated";
GRANT ALL ON TABLE "public"."master_clinical_observations" TO "service_role";



GRANT ALL ON TABLE "public"."master_data_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."master_data_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."master_data_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."master_diagnoses" TO "anon";
GRANT ALL ON TABLE "public"."master_diagnoses" TO "authenticated";
GRANT ALL ON TABLE "public"."master_diagnoses" TO "service_role";



GRANT ALL ON TABLE "public"."master_drugs" TO "anon";
GRANT ALL ON TABLE "public"."master_drugs" TO "authenticated";
GRANT ALL ON TABLE "public"."master_drugs" TO "service_role";



GRANT ALL ON TABLE "public"."master_history_options" TO "anon";
GRANT ALL ON TABLE "public"."master_history_options" TO "authenticated";
GRANT ALL ON TABLE "public"."master_history_options" TO "service_role";



GRANT ALL ON TABLE "public"."master_iol_catalog" TO "anon";
GRANT ALL ON TABLE "public"."master_iol_catalog" TO "authenticated";
GRANT ALL ON TABLE "public"."master_iol_catalog" TO "service_role";



GRANT ALL ON TABLE "public"."master_iop_methods" TO "anon";
GRANT ALL ON TABLE "public"."master_iop_methods" TO "authenticated";
GRANT ALL ON TABLE "public"."master_iop_methods" TO "service_role";



GRANT ALL ON TABLE "public"."master_ot_sessions" TO "anon";
GRANT ALL ON TABLE "public"."master_ot_sessions" TO "authenticated";
GRANT ALL ON TABLE "public"."master_ot_sessions" TO "service_role";



GRANT ALL ON TABLE "public"."master_packages" TO "anon";
GRANT ALL ON TABLE "public"."master_packages" TO "authenticated";
GRANT ALL ON TABLE "public"."master_packages" TO "service_role";



GRANT ALL ON TABLE "public"."master_procedures" TO "anon";
GRANT ALL ON TABLE "public"."master_procedures" TO "authenticated";
GRANT ALL ON TABLE "public"."master_procedures" TO "service_role";



GRANT ALL ON TABLE "public"."master_services" TO "anon";
GRANT ALL ON TABLE "public"."master_services" TO "authenticated";
GRANT ALL ON TABLE "public"."master_services" TO "service_role";



GRANT ALL ON TABLE "public"."master_surgeries" TO "anon";
GRANT ALL ON TABLE "public"."master_surgeries" TO "authenticated";
GRANT ALL ON TABLE "public"."master_surgeries" TO "service_role";



GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "anon";
GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "authenticated";
GRANT ALL ON TABLE "public"."master_surgical_consumables" TO "service_role";



GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "anon";
GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."medical_fitness_referrals" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_assessments" TO "anon";
GRANT ALL ON TABLE "public"."optometry_assessments" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_assessments" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."optometry_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "anon";
GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "authenticated";
GRANT ALL ON TABLE "public"."optometry_iop_readings" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_consumables" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_events" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_events" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_events" TO "service_role";



GRANT ALL ON TABLE "public"."ot_intraop_records" TO "anon";
GRANT ALL ON TABLE "public"."ot_intraop_records" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_intraop_records" TO "service_role";



GRANT ALL ON TABLE "public"."ot_schedule" TO "anon";
GRANT ALL ON TABLE "public"."ot_schedule" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_schedule" TO "service_role";



GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."ot_schedule_audit_log" TO "service_role";



GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."package_code_seq" TO "service_role";



GRANT ALL ON TABLE "public"."package_line_items" TO "anon";
GRANT ALL ON TABLE "public"."package_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."package_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."patient_ledger" TO "anon";
GRANT ALL ON TABLE "public"."patient_ledger" TO "authenticated";
GRANT ALL ON TABLE "public"."patient_ledger" TO "service_role";



GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."patient_uhid_seq" TO "service_role";



GRANT ALL ON TABLE "public"."payment_allocations" TO "anon";
GRANT ALL ON TABLE "public"."payment_allocations" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_allocations" TO "service_role";



GRANT ALL ON TABLE "public"."payment_edits" TO "anon";
GRANT ALL ON TABLE "public"."payment_edits" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_edits" TO "service_role";



GRANT ALL ON TABLE "public"."payment_modes" TO "anon";
GRANT ALL ON TABLE "public"."payment_modes" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_modes" TO "service_role";



GRANT ALL ON TABLE "public"."pharmacy_queue" TO "anon";
GRANT ALL ON TABLE "public"."pharmacy_queue" TO "authenticated";
GRANT ALL ON TABLE "public"."pharmacy_queue" TO "service_role";



GRANT ALL ON TABLE "public"."plan_counselling_items" TO "anon";
GRANT ALL ON TABLE "public"."plan_counselling_items" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_counselling_items" TO "service_role";



GRANT ALL ON TABLE "public"."plan_followups" TO "anon";
GRANT ALL ON TABLE "public"."plan_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_followups" TO "service_role";



GRANT ALL ON TABLE "public"."plan_optical_advice" TO "anon";
GRANT ALL ON TABLE "public"."plan_optical_advice" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_optical_advice" TO "service_role";



GRANT ALL ON TABLE "public"."plan_procedures" TO "anon";
GRANT ALL ON TABLE "public"."plan_procedures" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_procedures" TO "service_role";



GRANT ALL ON TABLE "public"."plan_referrals" TO "anon";
GRANT ALL ON TABLE "public"."plan_referrals" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_referrals" TO "service_role";



GRANT ALL ON TABLE "public"."print_templates" TO "anon";
GRANT ALL ON TABLE "public"."print_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."print_templates" TO "service_role";



GRANT ALL ON TABLE "public"."profiles" TO "anon";
GRANT ALL ON TABLE "public"."profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."profiles" TO "service_role";



GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."receipt_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_complications" TO "anon";
GRANT ALL ON TABLE "public"."recovery_complications" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_complications" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_episodes" TO "anon";
GRANT ALL ON TABLE "public"."recovery_episodes" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_episodes" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_followups" TO "anon";
GRANT ALL ON TABLE "public"."recovery_followups" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_followups" TO "service_role";



GRANT ALL ON TABLE "public"."recovery_medications" TO "anon";
GRANT ALL ON TABLE "public"."recovery_medications" TO "authenticated";
GRANT ALL ON TABLE "public"."recovery_medications" TO "service_role";



GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."refund_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."surgical_case_notes" TO "anon";
GRANT ALL ON TABLE "public"."surgical_case_notes" TO "authenticated";
GRANT ALL ON TABLE "public"."surgical_case_notes" TO "service_role";



GRANT ALL ON TABLE "public"."surgical_cases" TO "anon";
GRANT ALL ON TABLE "public"."surgical_cases" TO "authenticated";
GRANT ALL ON TABLE "public"."surgical_cases" TO "service_role";



GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."visit_number_seq" TO "service_role";



GRANT ALL ON TABLE "public"."workflow_requests" TO "anon";
GRANT ALL ON TABLE "public"."workflow_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."workflow_requests" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";































FILEEOF_schema_sql

echo "Files written. Run: npm run build"
