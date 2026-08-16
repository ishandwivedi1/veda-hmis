#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
#
# BIOMETRY REDESIGN -- full rollout. This is a large, multi-session
# change: Biometry is now patient-level (reused across every future
# surgical case, no eye selection anywhere -- always both eyes), the
# app no longer calculates IOL power itself (records what the device
# printout says instead), and IOL Approval is now its own separate
# module where the surgeon signs off on the specific brand/power to use
# for a given case.
#
# DB changes ALREADY applied to both production (flzysyzhaecaqbmdcuao)
# and training (ffaddzpwnbizhvhujlse) in earlier turns this session --
# biometry_records redesigned (patient_id added; surgical_eye,
# procedure_name, formula_results, selected_formula, final_iol_*,
# surgeon_notes, approved_by/at, surgical_case_id all dropped), plus two
# new tables: biometry_iol_recommendations (the device's own printed
# brand/power table) and iol_approvals (the surgeon's case-specific
# sign-off). No SQL to run manually -- schema.sql is included here only
# to keep your repo in sync with the live database.
#
# WHAT THIS SCRIPT COVERS (code side):
#   - Biometry module: fully rewritten. One page (no more 3-tab
#     Measure->Calculate->Approve), both-eyes measurements, IOL
#     recommendation entry pulling brands from Clinical Masters,
#     mandatory report upload. calculation-tab.js and approval-tab.js
#     are gone (fully obsolete now).
#   - New IOL Approval module (/iol-approval): pending queue, approved-
#     today list, an approve modal showing the biometry recommendation
#     table with one-click "use this" per brand.
#   - Counselling: sendForBiometry simplified (no eye-fanout needed
#     anymore). Found and fixed TWO pre-existing dead bugs while
#     redesigning this: surgical_cases.biometry_done was never written
#     anywhere in the codebase (package selection was silently broken
#     unless biometry was explicitly skipped), and iol_category
#     filtering was silently hiding every IOL-specific package from the
#     picker for the same reason. Both now compute live instead of
#     trusting a flag nothing ever set. markReadyForScheduling now also
#     requires an Approved IOL before a case can be booked.
#   - OT Intraop: planned IOL now sourced from iol_approvals (not the
#     old biometry approval fields); eye confirmed sourced from
#     surgical_cases.eye, set by the doctor, per your instruction.
#   - Doctor Dashboard: the "Biometry Approvals" widget, which called a
#     function that no longer exists and would have crashed this
#     high-traffic page outright, replaced with an "IOL Approvals"
#     widget backed by the new module.
#   - OT Recovery, Investigation Queue, Biometry History, Consultation,
#     Surgical Journey (including a new IOL Approval step added to the
#     journey stepper), and two Print Templates functions (Discharge
#     Summary, Biometry Report -- one of which had a query that would
#     have crashed outright via an embedded relationship on a dropped
#     foreign key) all updated to match.
#
# Verified: every touched file individually cross-checked for imports
# pointing at their real source file (the lesson from two earlier
# broken deploys this session), and a full-codebase sweep for any
# remaining reference to a dropped column or removed function came back
# clean before this script was written.
#
# NOT covered (flagged, not started): print-templates/page.js's
# PLACEHOLDER_REFERENCE list still names some old field strings --
# purely a documentation list for the template editor UI, not a live
# query, so no crash risk, just cosmetically stale. Low priority.

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

export async function markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  const supabase = await createClient();

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

  const { error } = await supabase.from('surgical_cases').update({
    decision, decision_reason: reason || null,
    decision_locked: decision === 'Accepted',
  }).eq('id', caseId);
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
  // Substring match, not exact -- the catalog entry is named
  // "Biometry (Procedure Charge)", not literally "Biometry".
  return (data || []).filter((s) => !s.name.toLowerCase().includes('biometry'));
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

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/actions.js" << 'FILEEOF_ot_intraop_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { ensureRecoveryEpisode } from '../ot-recovery/actions';
import { getSurgicalConsumablesMaster } from '../master-data/actions';

// Same Surgical Consumables Clinical Master used to seed both the
// Patient Check-In dropdown and the Intraoperative Management
// quick-pick list -- one source, two input styles for two different
// moments in the workflow.
export async function getConsumableOptions() {
  const all = await getSurgicalConsumablesMaster();
  return all.filter((c) => c.status === 'Active');
}

// ── HISTORY: completed OT cases -- everything BEFORE today. Today's
// completed cases stay on the live Dashboard (see getOTCaseList) until
// the day rolls over, so a completed case doesn't just vanish the
// moment it's marked done. ──
export async function getOTIntraopHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .eq('status', 'Completed')
    .lt('scheduled_date', todayIst)
    .order('scheduled_date', { ascending: false });
  if (error) return [];

  const ids = (data || []).map((b) => b.id);
  let intraopByBooking = {};
  if (ids.length > 0) {
    const { data: records } = await supabase.from('ot_intraop_records').select('ot_schedule_id, surgical_outcome, completed_at, completed_by').in('ot_schedule_id', ids);
    const completedByIds = [...new Set((records || []).map((r) => r.completed_by).filter(Boolean))];
    let doctorMap = {};
    if (completedByIds.length > 0) {
      const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', completedByIds);
      (profiles || []).forEach((p) => { doctorMap[p.id] = p.full_name; });
    }
    (records || []).forEach((r) => { intraopByBooking[r.ot_schedule_id] = { ...r, completedByName: doctorMap[r.completed_by] || '--' }; });
  }

  return (data || []).filter((b) => b.surgical_cases).map((b) => ({ ...b, intraopSummary: intraopByBooking[b.id] || null }));
}

// ── CASE SELECTOR ──
// Today's (and any overdue) bookings that haven't been completed or
// cancelled, PLUS today's already-completed cases -- so a case doesn't
// disappear from the Dashboard the instant it's marked Completed. It
// only moves to History (getOTIntraopHistory) once the day rolls over.
// Also computes, per case, the package price and the patient's current
// advance balance -- Open is gated on the advance fully covering the
// package (surgery billing itself now happens later, at discharge, via
// the Surgery Billing widget on the Billing Dashboard -- not here).
export async function getOTCaseList() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  const [{ data: pending, error: pendingError }, { data: completedToday, error: completedError }] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select('*, master_ot_sessions(name), surgical_cases(id, procedure_name, eye, package_billed, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
      .in('status', ['Scheduled', 'In Progress'])
      .lte('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true })
      .order('sequence_number', { ascending: true, nullsFirst: false }),
    supabase
      .from('ot_schedule')
      .select('*, master_ot_sessions(name), surgical_cases(id, procedure_name, eye, package_billed, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
      .eq('status', 'Completed')
      .eq('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true }),
  ]);
  if (pendingError || completedError) return [];

  const cases = [...(pending || []), ...(completedToday || [])].filter((b) => b.surgical_cases);

  const balanceByPatient = {};
  const patientIds = [...new Set(cases.map((b) => b.surgical_cases.patient_id).filter(Boolean))];
  await Promise.all(patientIds.map(async (pid) => {
    const { data: bal } = await supabase.rpc('get_advance_balance', { p_patient_id: pid });
    balanceByPatient[pid] = bal || 0;
  }));

  return cases.map((b) => {
    const packagePrice = Number(b.surgical_cases.master_packages?.price || 0);
    const advanceBalance = balanceByPatient[b.surgical_cases.patient_id] || 0;
    return {
      ...b,
      packagePrice,
      advanceBalance,
      amountPayable: Math.max(0, packagePrice - advanceBalance),
      advanceCleared: packagePrice <= 0 || advanceBalance >= packagePrice,
    };
  });
}

// ── PATIENT REPORTED TO OT -- the surgery patient doesn't route through
//    Optometry or Doctor Consultation queues on the day of surgery; this
//    is how OT staff record that they've physically arrived, straight
//    from the Dashboard widget or the workspace header. ──
export async function markPatientReported(otScheduleId) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_schedule').update({ patient_reported_at: new Date().toISOString() }).eq('id', otScheduleId);
  if (error) return { error: error.message };
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_schedule_audit_log').insert({ ot_schedule_id: otScheduleId, action: 'Patient Reported', detail: 'Patient marked as reported to OT', changed_by: userData?.user?.id || null });
  return { success: true };
}

export async function unmarkPatientReported(otScheduleId) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_schedule').update({ patient_reported_at: null }).eq('id', otScheduleId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FULL CASE DETAIL ──
export async function getOTCaseDetail(otScheduleId) {
  const supabase = await createClient();
  const { data: booking, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(*, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name), master_packages:package_id(name))')
    .eq('id', otScheduleId)
    .single();
  if (error) return { error: error.message };

  const sc = booking.surgical_cases;

  // Planned IOL comes from the surgeon's IOL Approval (a separate
  // module/step now) -- NOT from biometry_records, which only holds
  // the device's raw per-brand recommendations and no longer has any
  // "approved" concept of its own. Matched by surgical_case_id (a real
  // FK), not visit_id -- eye comes from sc.eye directly, set by the
  // doctor, not from biometry at all (biometry doesn't track eye
  // anymore since it's always done for both).
  const [{ data: approval }, { data: intraop }, { data: consumables }, { data: events }] = await Promise.all([
    supabase.from('iol_approvals').select('*, master_iol_catalog(brand, model, manufacturer, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('ot_intraop_records').select('*').eq('ot_schedule_id', otScheduleId).maybeSingle(),
    supabase.from('ot_intraop_consumables').select('*').eq('ot_schedule_id', otScheduleId).order('added_at'),
    supabase.from('ot_intraop_events').select('*').eq('ot_schedule_id', otScheduleId).order('occurred_at'),
  ]);

  // Consent form uploads -- one attachment lookup per type.
  const consentForms = {};
  await Promise.all(CONSENT_FORM_TYPES.map(async (f) => {
    const { data: files } = await supabase
      .from('clinical_attachments')
      .select('*')
      .eq('entity_type', `ot_consent_${f.key}`)
      .eq('entity_id', otScheduleId)
      .order('uploaded_at', { ascending: false })
      .limit(1);
    consentForms[f.key] = files && files.length > 0 ? files[0] : null;
  }));

  return {
    booking, biometryPlans: approval ? [approval] : [],
    intraop: intraop || null,
    consumables: consumables || [],
    events: (events || []).filter((e) => e.kind === 'Event'),
    complications: (events || []).filter((e) => e.kind === 'Complication'),
    consentForms,
  };
}

async function ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId) {
  const { data: existing } = await supabase.from('ot_intraop_records').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('ot_intraop_records').insert({ ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId }).select('id').single();
  if (error) return null;
  return created.id;
}

// ── CHECK-IN ──
export async function saveCheckinItems(otScheduleId, surgicalCaseId, checkinItems) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({ checkin_items: checkinItems }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeCheckin(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  const consentsOk = await requiredConsentsUploaded(supabase, otScheduleId);
  if (!consentsOk) return { error: 'Upload all required consent forms before completing check-in.' };

  const { data: intraop } = await supabase.from('ot_intraop_records').select('checkin_items').eq('id', recordId).single();
  const checked = Object.values(intraop?.checkin_items || {}).filter(Boolean).length;
  if (checked < CHECKIN_ITEMS.length - 1) return { error: `Complete all check-in items first (${checked}/${CHECKIN_ITEMS.length - 1}).` };

  // VAL-OT-IOL-001: if an approved IOL exists for this case, its power
  // and manufacturer must both be present. Check-in is the last point
  // this can still be corrected -- discovering it missing only after
  // the implant is already in the eye is too late to act on. A case
  // with no approval at all is left alone (non-IOL procedures
  // legitimately have none). Sourced from iol_approvals now, not
  // biometry_records -- biometry no longer has an "approved" concept
  // of its own.
  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('eye, power, master_iol_catalog:iol_catalog_id(manufacturer)')
    .eq('surgical_case_id', surgicalCaseId)
    .eq('status', 'Approved')
    .maybeSingle();
  if (approval && (!approval.power || !approval.master_iol_catalog?.manufacturer)) {
    const missing = !approval.power ? 'power' : 'manufacturer';
    return { error: `Approved IOL for ${approval.eye} is missing its ${missing} -- fix this in IOL Approval before check-in can be completed.` };
  }

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_intraop_records').update({ checkin_completed_at: new Date().toISOString() }).eq('id', recordId);
  await supabase.from('ot_schedule').update({ status: 'In Progress' }).eq('id', otScheduleId);
  await supabase.from('ot_schedule_audit_log').insert({ ot_schedule_id: otScheduleId, action: 'Check-In', detail: 'OT check-in completed', changed_by: userData?.user?.id || null });
  return { success: true };
}

async function requiredConsentsUploaded(supabase, otScheduleId) {
  const required = CONSENT_FORM_TYPES.filter((f) => f.required);
  for (const f of required) {
    const { count } = await supabase.from('clinical_attachments').select('id', { count: 'exact', head: true }).eq('entity_type', `ot_consent_${f.key}`).eq('entity_id', otScheduleId);
    if (!count) return false;
  }
  return true;
}

// ── ANAESTHESIA ──
export async function recordAnaesthesia(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({
    anaesthesia_type: values.type, anaesthetist: values.doctor || null,
    anaesthesia_start: values.start || null, anaesthesia_end: values.end || null,
    anaesthesia_remarks: values.remarks || null, anaesthesia_recorded_at: new Date().toISOString(),
  }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEDURE / IMPLANT / NOTES / OUTCOME / RECOVERY (draft save) ──
export async function saveIntraopDraft(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update(values).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CONSUMABLES ──
export async function addConsumable(otScheduleId, name) {
  const supabase = await createClient();
  if (!name?.trim()) return { error: 'Consumable name is required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('ot_intraop_consumables').insert({ ot_schedule_id: otScheduleId, name: name.trim(), added_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeConsumable(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_intraop_consumables').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EVENTS / COMPLICATIONS ──
export async function addIntraopEvent(otScheduleId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Description is required.' };
  if (values.kind === 'Complication' && !values.management?.trim()) {
    return { error: 'VAL-OT-004: Management is mandatory when recording a complication.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('ot_intraop_events').insert({
    ot_schedule_id: otScheduleId, kind: values.kind, name: values.name.trim(), severity: values.severity,
    management: values.management?.trim() || null, outcome: values.outcome?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIntraopEvent(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_intraop_events').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── COMPLETE SURGERY ──
// This is the completion path OT Scheduling deliberately deferred --
// updates both ot_schedule and the surgical_case, exactly the "future
// module" that was promised when Mark Completed was removed from there.
export async function completeSurgery(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();

  if (!values.implantPower || !values.implantSerial) {
    // Non-IOL procedures can skip this -- checked by the caller passing
    // skipImplant when there's no biometry plan at all.
    if (!values.skipImplant) return { error: 'VAL-OT-003: Implant power and serial/batch number are mandatory.' };
  }
  if (!values.recoveryInstructions) return { error: 'VAL-OT-005: Recovery handover (post-operative instructions) must be documented.' };
  if (!values.surgicalOutcome) return { error: 'VAL-OT-005: Surgical outcome must be recorded.' };
  const needsRemarks = ['Converted Procedure', 'Procedure Deferred', 'Procedure Abandoned'].includes(values.surgicalOutcome);
  if (needsRemarks && !values.outcomeRemarks) {
    return { error: `Remarks are required when the outcome is "${values.surgicalOutcome}".` };
  }
  if (values.variancePresent && !values.varianceReason) {
    return { error: 'AUTO-OT-003: Implant power differs from approved plan -- variance reason required.' };
  }

  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  // Was this already completed before? Determines whether this call is
  // the original completion or a correction to one -- both go through
  // this same function (the "Save Changes" button when unlocked reuses
  // it), but they should read differently in the audit trail.
  const { data: before } = await supabase.from('ot_intraop_records').select('completed_at').eq('id', recordId).maybeSingle();
  const isCorrection = !!before?.completed_at;

  const { data: userData } = await supabase.auth.getUser();

  const { error: recError } = await supabase.from('ot_intraop_records').update({
    implant_manufacturer: values.implantManufacturer || null, implant_model: values.implantModel || null, implant_catalog_id: values.implantCatalogId || null,
    implant_power: values.implantPower || null, implant_category: values.implantCategory || null, implant_serial: values.implantSerial || null,
    implant_expiry: values.implantExpiry || null, implant_eye: values.implantEye || null,
    variance_reason: values.varianceReason || null,
    operative_notes: values.operativeNotes || null,
    surgical_outcome: values.surgicalOutcome || null, outcome_remarks: values.outcomeRemarks || null,
    recovery_destination: values.recoveryDestination || null, recovery_monitoring: values.recoveryMonitoring || null,
    recovery_instructions: values.recoveryInstructions || null, recovery_concerns: values.recoveryConcerns || null,
    // Only stamp completed_at/completed_by the FIRST time -- a
    // correction shouldn't rewrite when the surgery was actually
    // completed or by whom; that's preserved in the audit log instead.
    ...(isCorrection ? {} : { completed_at: new Date().toISOString(), completed_by: userData?.user?.id || null }),
  }).eq('id', recordId);
  if (recError) return { error: recError.message };

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  // Completing surgery and handing over to Recovery are the same real
  // moment -- create the Recovery episode right here instead of a
  // separate "Transfer to Recovery" step.
  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date').eq('id', otScheduleId).single();
  const { data: caseRow } = await supabase.from('surgical_cases').select('visit_id').eq('id', surgicalCaseId).single();
  if (booking && caseRow) await ensureRecoveryEpisode(otScheduleId, surgicalCaseId, caseRow.visit_id, booking.scheduled_date);

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: isCorrection ? 'Corrected After Completion' : 'Completed',
    detail: isCorrection
      ? `Intraop record corrected after completion -- outcome: ${values.surgicalOutcome || '--'}`
      : `Surgery completed -- outcome: ${values.surgicalOutcome || '--'} -- handed over to Recovery (${values.recoveryDestination || '--'})`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── TRANSFER TO RECOVERY (handover, doesn't complete the surgery) ──
export async function transferToRecovery(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  if (!values.recoveryInstructions?.trim()) return { error: 'Document post-operative instructions before transfer.' };
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  const { error } = await supabase.from('ot_intraop_records').update({
    recovery_destination: values.recoveryDestination || null, recovery_monitoring: values.recoveryMonitoring || null,
    recovery_instructions: values.recoveryInstructions.trim(), recovery_concerns: values.recoveryConcerns || null,
    transferred_at: new Date().toISOString(),
  }).eq('id', recordId);
  if (error) return { error: error.message };

  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date').eq('id', otScheduleId).single();
  const { data: sc } = await supabase.from('surgical_cases').select('visit_id').eq('id', surgicalCaseId).single();
  if (booking && sc) await ensureRecoveryEpisode(otScheduleId, surgicalCaseId, sc.visit_id, booking.scheduled_date);

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Transferred to Recovery',
    detail: `Destination: ${values.recoveryDestination || '--'}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

FILEEOF_ot_intraop_actions_js

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/workspace.js" << 'FILEEOF_ot_intraop_workspace_js'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  getOTCaseDetail,
  saveCheckinItems, completeCheckin, recordAnaesthesia, saveIntraopDraft,
  addConsumable, removeConsumable, addIntraopEvent, removeIntraopEvent,
  completeSurgery, getConsumableOptions, markPatientReported, unmarkPatientReported,
} from './actions';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { uploadAttachment, deleteAttachment } from '@/lib/attachments';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const STEPS = ['Check-In', 'Anaesthesia', 'Surgery', 'Implant', 'Recovery'];
const EVENT_QUICK = ['Small Pupil', 'Zonular Weakness', 'Difficult Capsulorhexis', 'Iris Prolapse', 'Floppy Iris Syndrome'];
const COMPL_QUICK = ['Posterior Capsular Rupture', 'Dropped Nucleus', 'Vitreous Loss', 'Wound Leak', 'Endothelial Trauma'];
const CONSENT_INDEX = CHECKIN_ITEMS.indexOf('Consent availability verified');
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function fmtTime(secs) {
  const m = String(Math.floor(secs / 60)).padStart(2, '0');
  const s = String(secs % 60).padStart(2, '0');
  return `${m}:${s}`;
}

export default function Workspace({ otScheduleId, onBack }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [log, setLog] = useState([]);
  const [seconds, setSeconds] = useState(0);
  const timerRef = useRef(null);

  const [checkinChecked, setCheckinChecked] = useState({});
  const [uploadingKey, setUploadingKey] = useState(null);
  const [subTab, setSubTab] = useState('checkin');
  const initializedTabRef = useRef(false);

  const [anaesType, setAnaesType] = useState('Topical');
  const [anaesDoctor, setAnaesDoctor] = useState('');
  const [anaesStart, setAnaesStart] = useState('');
  const [anaesEnd, setAnaesEnd] = useState('');
  const [anaesRemarks, setAnaesRemarks] = useState('');

  const [imMfr, setImMfr] = useState('');
  const [imModel, setImModel] = useState('');
  const [imCatalogId, setImCatalogId] = useState('');
  const [imIolMode, setImIolMode] = useState('catalog'); // 'catalog' | 'other'
  const [imPower, setImPower] = useState('');
  const [imCategory, setImCategory] = useState('');
  const [imSerial, setImSerial] = useState('');
  const [imExpiry, setImExpiry] = useState('');
  const [imEye, setImEye] = useState('OD');
  const [varianceReason, setVarianceReason] = useState('');

  const [consumableName, setConsumableName] = useState('');
  const [consumableOptions, setConsumableOptions] = useState([]);
  const [iolCatalog, setIolCatalog] = useState([]);
  const [checkinConsumableId, setCheckinConsumableId] = useState('');
  const [eventName, setEventName] = useState('');
  const [eventSeverity, setEventSeverity] = useState('Mild');
  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [opNotes, setOpNotes] = useState('');
  const [surgicalOutcome, setSurgicalOutcome] = useState('Successful');
  const [outcomeRemarks, setOutcomeRemarks] = useState('');

  const [recoveryDest, setRecoveryDest] = useState('Recovery Bay 1');
  const [recoveryMonitor, setRecoveryMonitor] = useState('');
  const [recoveryInstructions, setRecoveryInstructions] = useState('');
  const [recoveryConcerns, setRecoveryConcerns] = useState('');
  const [saving, setSaving] = useState(false);
  const [unlocked, setUnlocked] = useState(false);

  function addLog(msg) {
    setLog((prev) => [`${new Date().toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })} -- ${msg}`, ...prev].slice(0, 20));
  }

  const refresh = useCallback(async () => {
    const result = await getOTCaseDetail(otScheduleId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    if (!initializedTabRef.current) {
      initializedTabRef.current = true;
      if (result.intraop?.checkin_completed_at || result.booking.status === 'Completed') setSubTab('intraop');
    }
    const io = result.intraop;
    if (io) {
      setCheckinChecked(io.checkin_items || {});
      setAnaesType(io.anaesthesia_type || 'Topical');
      setAnaesDoctor(io.anaesthetist || '');
      setAnaesStart(io.anaesthesia_start || '');
      setAnaesEnd(io.anaesthesia_end || '');
      setAnaesRemarks(io.anaesthesia_remarks || '');
      setImMfr(io.implant_manufacturer || '');
      setImModel(io.implant_model || '');
      setImCatalogId(io.implant_catalog_id || '');
      // Records saved before the catalog dropdown existed have
      // manufacturer/model as free text with no catalog link -- default
      // to "Other" mode so that data is immediately visible instead of
      // silently disappearing behind an unselected dropdown.
      setImIolMode(io.implant_catalog_id ? 'catalog' : (io.implant_manufacturer || io.implant_model) ? 'other' : 'catalog');
      setImPower(io.implant_power || result.biometryPlans[0]?.power || '');
      setImCategory(io.implant_category || result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImSerial(io.implant_serial || '');
      setImExpiry(io.implant_expiry || '');
      // Eye to be implanted is always derived from the Surgery section
      // (surgical_cases.eye, set by the doctor in Diagnosis & Plan) --
      // never from Biometry, which can legitimately be done for a
      // different/single eye even on a bilateral case. Surgery section
      // takes priority over a previously-saved implant_eye too, so a
      // stale value from before this derivation existed can't linger.
      setImEye(result.booking.surgical_cases.eye || io.implant_eye || 'OD');
      setVarianceReason(io.variance_reason || '');
      setOpNotes(io.operative_notes || '');
      setSurgicalOutcome(io.surgical_outcome || 'Successful');
      setOutcomeRemarks(io.outcome_remarks || '');
      setRecoveryDest(io.recovery_destination || 'Recovery Bay 1');
      setRecoveryMonitor(io.recovery_monitoring || '');
      setRecoveryInstructions(io.recovery_instructions || '');
      setRecoveryConcerns(io.recovery_concerns || '');
    } else {
      setImPower(result.biometryPlans[0]?.power || '');
      setImCategory(result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImEye(result.booking.surgical_cases.eye || 'OD');
    }
  }, [otScheduleId]);

  useEffect(() => {
    refresh();
    getConsumableOptions().then(setConsumableOptions);
    getActiveIolCatalog().then(setIolCatalog);
    initializedTabRef.current = false;
    setSubTab('checkin');
    setSeconds(0);
    setUnlocked(false);
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(timerRef.current);
  }, [otScheduleId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const { booking, biometryPlans, intraop, consumables, events, complications, consentForms } = data;
  const sc = booking.surgical_cases;
  const patient = sc.patients;
  const isCompleted = booking.status === 'Completed';
  // Once completed, the intraoperative fields are locked for reference
  // unless explicitly unlocked -- same "Unlock to Edit" pattern as a
  // completed Doctor Consultation, so a genuine correction (wrong
  // implant serial typed in, outcome remarks need fixing) doesn't
  // require a database intervention.
  const isReadOnly = isCompleted && !unlocked;
  const currentStep = isCompleted ? 4 : intraop?.checkin_completed_at ? (intraop?.anaesthesia_recorded_at ? (intraop?.completed_at ? 4 : 2) : 1) : 0;

  const requiredConsentsOk = CONSENT_FORM_TYPES.filter((f) => f.required).every((f) => consentForms[f.key]);
  const manualCheckinDone = CHECKIN_ITEMS.filter((_, i) => i !== CONSENT_INDEX).every((_, i) => {
    const realIdx = i >= CONSENT_INDEX ? i + 1 : i;
    return checkinChecked[realIdx];
  });

  async function handleUploadConsent(key, file) {
    if (!file) return;
    setUploadingKey(key);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', `ot_consent_${key}`);
    formData.append('entityId', otScheduleId);
    const result = await uploadAttachment(formData);
    setUploadingKey(null);
    if (result.error) { setError(result.error); return; }
    addLog(`Consent uploaded: ${CONSENT_FORM_TYPES.find((f) => f.key === key)?.label}`);
    refresh();
  }

  async function handleRemoveConsent(key) {
    const file = consentForms[key];
    if (!file) return;
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  function toggleCheckinItem(i) {
    if (i === CONSENT_INDEX) return;
    const updated = { ...checkinChecked, [i]: !checkinChecked[i] };
    setCheckinChecked(updated);
    saveCheckinItems(otScheduleId, sc.id, updated);
  }

  async function handleToggleReported() {
    if (booking.patient_reported_at) await unmarkPatientReported(otScheduleId);
    else { await markPatientReported(otScheduleId); addLog('Patient marked as reported to OT'); }
    refresh();
  }

  async function handleCompleteCheckin() {
    setError('');
    const result = await completeCheckin(otScheduleId, sc.id);
    if (result.error) { setError(result.error); return; }
    addLog('OT Check-In completed');
    setOk('Check-in complete -- patient confirmed in OT.');
    await refresh();
    setSubTab('intraop');
  }

  async function handleRecordAnaesthesia() {
    setError('');
    const result = await recordAnaesthesia(otScheduleId, sc.id, { type: anaesType, doctor: anaesDoctor, start: anaesStart, end: anaesEnd, remarks: anaesRemarks });
    if (result.error) { setError(result.error); return; }
    addLog(`Anaesthesia recorded: ${anaesType}`);
    refresh();
  }

  async function handleAddConsumable(name) {
    const value = name || consumableName;
    if (!value.trim()) return;
    await addConsumable(otScheduleId, value);
    setConsumableName('');
    addLog(`Consumable: ${value}`);
    refresh();
  }

  async function handleAddEvent() {
    if (!eventName.trim()) return;
    const result = await addIntraopEvent(otScheduleId, { kind: 'Event', name: eventName, severity: eventSeverity });
    if (result.error) { setError(result.error); return; }
    setEventName('');
    addLog(`Event: ${eventName} (${eventSeverity})`);
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addIntraopEvent(otScheduleId, { kind: 'Complication', name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    addLog(`COMPLICATION: ${complName} (${complSeverity})`);
    refresh();
  }

  async function handleSaveDraft() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveIntraopDraft(otScheduleId, sc.id, {
      implant_manufacturer: imMfr || null, implant_model: imModel || null, implant_catalog_id: imCatalogId || null,
      implant_power: imPower || null, implant_category: imCategory || null, implant_serial: imSerial || null, implant_expiry: imExpiry || null,
      implant_eye: imEye, variance_reason: varianceReason || null, operative_notes: opNotes || null,
      surgical_outcome: surgicalOutcome || null, outcome_remarks: outcomeRemarks || null,
      recovery_destination: recoveryDest || null, recovery_monitoring: recoveryMonitor || null,
      recovery_instructions: recoveryInstructions || null, recovery_concerns: recoveryConcerns || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    addLog('Draft saved');
    setOk('Draft saved -- documentation preserved.');
    refresh();
  }

  const plannedPlan = biometryPlans[0];
  const plannedPower = plannedPlan?.power;
  const plannedCategory = plannedPlan?.master_iol_catalog?.category;
  // eye now comes from the same source on both sides (surgical_cases.eye)
  // -- iol_approvals.eye is set from it directly at approval time, and
  // imEye is derived from it here too, so this stays as a defensive
  // check rather than something that can meaningfully drift anymore.
  const plannedEyeNorm = plannedPlan?.eye || null;
  const plannedSpecificIol = plannedPlan?.master_iol_catalog
    ? `${plannedPlan.master_iol_catalog.manufacturer || ''} ${plannedPlan.master_iol_catalog.brand || ''} ${plannedPlan.master_iol_catalog.model || ''}`.trim().toLowerCase()
    : '';
  const actualSpecificIol = `${imMfr} ${imModel}`.trim().toLowerCase();

  const eyeMismatch = plannedEyeNorm && imEye && plannedEyeNorm !== imEye;
  const powerMismatch = plannedPower && imPower && String(plannedPower) !== String(imPower);
  const categoryMismatch = plannedCategory && imCategory && plannedCategory !== imCategory;
  // ID-based comparison when both sides have a catalog entry selected --
  // far more reliable than comparing reconstructed text. Falls back to
  // text comparison only when one side has no catalog link at all (an
  // older record, or a plan/implant that was custom-typed).
  const specificIolMismatch = (plannedPlan?.iol_catalog_id && imCatalogId)
    ? plannedPlan.iol_catalog_id !== imCatalogId
    : !!(plannedSpecificIol && actualSpecificIol && plannedSpecificIol !== actualSpecificIol);
  const variancePresent = !!(plannedPlan && (eyeMismatch || powerMismatch || categoryMismatch || specificIolMismatch));

  async function handleCompleteSurgery() {
    setError(''); setOk('');
    const wasAlreadyCompleted = isCompleted;
    const result = await completeSurgery(otScheduleId, sc.id, {
      implantPower: imPower, implantCategory: imCategory, implantSerial: imSerial, implantManufacturer: imMfr, implantModel: imModel, implantCatalogId: imCatalogId, implantExpiry: imExpiry, implantEye: imEye,
      skipImplant: biometryPlans.length === 0,
      recoveryInstructions, recoveryDestination: recoveryDest, recoveryMonitoring: recoveryMonitor, recoveryConcerns,
      variancePresent, varianceReason,
      operativeNotes: opNotes, surgicalOutcome, outcomeRemarks,
    });
    if (result.error) { setError(result.error); return; }
    clearInterval(timerRef.current);
    if (wasAlreadyCompleted) {
      addLog('INTRAOP RECORD CORRECTED -- changes saved after completion');
      setOk('Changes saved.');
      setUnlocked(false);
    } else {
      addLog('SURGERY COMPLETED -- OT Case marked complete, handed over to Recovery');
      setOk('Surgery completed and handed over to Recovery. Case marked Completed in OT Scheduling.');
    }
    refresh();
  }

  return (
    <div>
      <div style={{ background: isCompleted ? 'linear-gradient(135deg,#14532d,#157a4f)' : 'linear-gradient(135deg,#7f1d1d,#991b1b)', borderRadius: 12, padding: '11px 18px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{booking.id.slice(0, 8)}</div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name} -- {booking.master_ot_sessions?.name}</div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isCompleted ? 'Surgery Completed' : booking.status}</span>
          {isCompleted && (
            <button
              type="button"
              className="btn btn-sm"
              style={{
                borderColor: 'rgba(255,255,255,.3)',
                background: unlocked ? 'rgba(251,191,36,.35)' : 'rgba(255,255,255,.1)',
                color: '#fff',
              }}
              onClick={() => setUnlocked((v) => !v)}
            >
              <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i> {unlocked ? 'Lock' : 'Unlock to Edit'}
            </button>
          )}
          {!isCompleted && (
            <button
              type="button"
              className="btn btn-sm"
              style={{
                borderColor: 'rgba(255,255,255,.3)',
                background: booking.patient_reported_at ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.1)',
                color: '#fff',
              }}
              onClick={handleToggleReported}
              title={booking.patient_reported_at ? `Reported at ${new Date(booking.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Mark patient as reported to OT'}
            >
              <i className={`ti ${booking.patient_reported_at ? 'ti-check' : 'ti-door-enter'}`}></i> {booking.patient_reported_at ? 'Patient Reported' : 'Mark Reported'}
            </button>
          )}
          {!isCompleted && (
            <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '6px 12px' }}>
              <div style={{ fontSize: 9, opacity: .7, textTransform: 'uppercase' }}>OT Duration</div>
              <div style={{ fontSize: 17, fontWeight: 700, fontFamily: 'monospace' }}>{fmtTime(seconds)}</div>
            </div>
          )}
          <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
        </div>
      </div>

      {isCompleted && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed surgery -- changes save immediately and are logged.'
              : 'This surgery is completed. Viewing read-only for reference.'}
          </span>
        </div>
      )}

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '210px 1fr 220px', gap: 14 }}>
        {/* LEFT: Timeline */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 10 }}>OT Timeline</div>
            {STEPS.map((s, i) => (
              <div key={s} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0', borderBottom: i < STEPS.length - 1 ? '1px solid var(--g100)' : 'none' }}>
                <div style={{ width: 26, height: 26, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, flexShrink: 0, border: '2px solid', borderColor: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : 'var(--g200)', background: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : '#fff', color: i <= currentStep ? '#fff' : 'var(--g300)' }}>
                  <i className={`ti ${i < currentStep ? 'ti-check' : i === currentStep ? 'ti-player-play' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
                </div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{s}</div>
              </div>
            ))}
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Event log</div>
            <div style={{ fontSize: 10, color: 'var(--g500)', maxHeight: 200, overflowY: 'auto' }}>
              {log.map((l, i) => <div key={i} style={{ padding: '3px 0', borderBottom: '1px solid var(--g100)' }}>{l}</div>)}
            </div>
          </div>
        </div>

        {/* CENTER: sections */}
        <div>
          {/* Big-visibility case summary */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--red)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-scalpel"></i> Procedure</div>
              <div style={{ fontSize: 15, fontWeight: 700, lineHeight: 1.2 }}>{sc.procedure_name}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--blue)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-eye"></i> Eye</div>
              <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--blue)' }}>{sc.eye}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--green)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-package"></i> Package</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2, color: sc.master_packages ? 'inherit' : 'var(--g400)' }}>{sc.master_packages?.name || 'No package'}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--indigo)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-stethoscope"></i> Surgeon</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2 }}>{sc.profiles?.full_name || 'Not assigned'}</div>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <button
              type="button"
              onClick={() => setSubTab('checkin')}
              style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'checkin' ? '#fff' : 'transparent', color: subTab === 'checkin' ? 'var(--red)' : 'var(--g500)', cursor: 'pointer', boxShadow: subTab === 'checkin' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
            >
              <i className="ti ti-clipboard-check"></i> Patient Check-In
            </button>
            <button
              type="button"
              onClick={() => (intraop?.checkin_completed_at || isCompleted) && setSubTab('intraop')}
              disabled={!intraop?.checkin_completed_at && !isCompleted}
              title={!intraop?.checkin_completed_at && !isCompleted ? 'Complete Patient Check-In first' : ''}
              style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'intraop' ? '#fff' : 'transparent', color: !intraop?.checkin_completed_at && !isCompleted ? 'var(--g300)' : subTab === 'intraop' ? 'var(--red)' : 'var(--g500)', cursor: !intraop?.checkin_completed_at && !isCompleted ? 'not-allowed' : 'pointer', boxShadow: subTab === 'intraop' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
            >
              <i className="ti ti-building-hospital"></i> Intraoperative Management {!intraop?.checkin_completed_at && !isCompleted && <i className="ti ti-lock" style={{ fontSize: 10 }}></i>}
            </button>
          </div>

          {subTab === 'checkin' && (
          <>
          {/* Consent Forms */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-file-check" style={{ color: 'var(--green)' }}></i> Consent Forms</div>
              <span className={`badge ${requiredConsentsOk ? 'b-green' : 'b-gray'}`}>{CONSENT_FORM_TYPES.filter((f) => f.required && consentForms[f.key]).length}/{CONSENT_FORM_TYPES.filter((f) => f.required).length}</span>
            </div>
            {CONSENT_FORM_TYPES.map((f) => {
              const file = consentForms[f.key];
              return (
                <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, border: '2px solid var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, background: file ? 'var(--green)' : '#fff', borderColor: file ? 'var(--green)' : 'var(--g300)' }}>
                    {file && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12.5, fontWeight: 600 }}>{f.label} {!f.required && <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(optional)</span>}</div>
                    <div style={{ fontSize: 11, color: file ? 'var(--g500)' : 'var(--g400)', marginTop: 1 }}>
                      {file ? <><i className="ti ti-paperclip"></i> {file.file_name}</> : 'Not uploaded yet'}
                    </div>
                  </div>
                  {file ? (
                    <div style={{ display: 'flex', gap: 4 }}>
                      {file.url && <a href={file.url} target="_blank" rel="noopener noreferrer" className="btn btn-sm">View</a>}
                      <button className="btn btn-sm" onClick={() => handleRemoveConsent(f.key)}><i className="ti ti-x"></i></button>
                    </div>
                  ) : (
                    <label className="btn btn-sm btn-primary" style={{ cursor: 'pointer', marginBottom: 0 }}>
                      {uploadingKey === f.key ? 'Uploading...' : <><i className="ti ti-upload"></i> Upload</>}
                      <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadConsent(f.key, e.target.files?.[0])} disabled={uploadingKey === f.key} />
                    </label>
                  )}
                </div>
              );
            })}
          </div>

          {/* Check-In */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--blue)' }}></i> OT Check-In</div>
              <span className={`badge ${intraop?.checkin_completed_at ? 'b-green' : 'b-gray'}`}>{intraop?.checkin_completed_at ? 'Complete' : `${Object.values(checkinChecked).filter(Boolean).length}/${CHECKIN_ITEMS.length}`}</span>
            </div>
            {CHECKIN_ITEMS.map((item, i) => (
              i === CONSENT_INDEX ? (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', background: requiredConsentsOk ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: requiredConsentsOk ? 'var(--green)' : '#fff', border: '2px solid', borderColor: requiredConsentsOk ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{requiredConsentsOk && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item} <span style={{ fontSize: 10, color: 'var(--g400)' }}>(auto -- from Consent Forms above)</span></span>
                </div>
              ) : (
                <div key={i} onClick={() => !isReadOnly && toggleCheckinItem(i)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isReadOnly ? 'default' : 'pointer', background: checkinChecked[i] ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: checkinChecked[i] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checkinChecked[i] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checkinChecked[i] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item}</span>
                </div>
              )
            ))}
            {!intraop?.checkin_completed_at && !isCompleted && (!manualCheckinDone || !requiredConsentsOk) && (
              <div style={{ fontSize: 11, color: 'var(--amber)', marginTop: 8 }}>
                <i className="ti ti-info-circle"></i> Complete all items above{!requiredConsentsOk ? ' and upload required consent forms' : ''} to check in.
              </div>
            )}
          </div>

          {/* Implant Verification */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-disc" style={{ color: 'var(--indigo)' }}></i> Implant Verification</div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div style={{ border: '1.5px solid var(--g200)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Approved IOL Plan</div>
                {plannedPlan ? (
                  <div style={{ fontSize: 12 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>Eye</span><strong>{EYE_LABEL[plannedPlan.eye] || plannedPlan.eye}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>IOL Power</span><strong>{plannedPower || '--'} D</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>IOL Category</span><strong>{plannedCategory || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>Specific IOL</span><strong style={{ textAlign: 'right' }}>{plannedPlan.master_iol_catalog ? `${plannedPlan.master_iol_catalog.manufacturer} ${plannedPlan.master_iol_catalog.brand || ''} ${plannedPlan.master_iol_catalog.model || ''}`.trim() : '--'}</strong></div>
                  </div>
                ) : <div style={{ fontSize: 11, color: 'var(--g400)' }}>No IOL plan (non-IOL procedure)</div>}
              </div>

              <div style={{ border: '1.5px solid', borderColor: variancePresent ? 'var(--red)' : 'var(--green)', background: variancePresent ? 'var(--red-lt)' : 'var(--green-lt)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>Actual Implanted IOL</div>
                  {plannedPlan && <strong style={{ fontSize: 11, color: variancePresent ? 'var(--red)' : 'var(--green)' }}>{variancePresent ? 'VARIANCE' : 'Perfect Match'}</strong>}
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">Eye implanted</label>
                  <select className="fi fi-sm" value={imEye} onChange={(e) => setImEye(e.target.value)} disabled={isReadOnly} style={{ borderColor: eyeMismatch ? 'var(--red)' : undefined }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Power (D)</label>
                  <input className="fi fi-sm" value={imPower} onChange={(e) => setImPower(e.target.value)} disabled={isReadOnly} style={{ borderColor: powerMismatch ? 'var(--red)' : undefined }} />
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Category</label>
                  <select className="fi fi-sm" value={imCategory} onChange={(e) => setImCategory(e.target.value)} disabled={isReadOnly} style={{ borderColor: categoryMismatch ? 'var(--red)' : undefined }}>
                    <option value="">-- Select --</option>
                    <option>Monofocal</option>
                    <option>Monofocal Toric</option>
                    <option>Multifocal</option>
                    <option>EDOF</option>
                  </select>
                </div>
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                    <label className="flbl">Specific IOL (Manufacturer &amp; Brand)</label>
                    {!isReadOnly && (
                      <button
                        type="button"
                        onClick={() => setImIolMode(imIolMode === 'catalog' ? 'other' : 'catalog')}
                        style={{ border: 'none', background: 'none', color: 'var(--blue)', fontSize: 10.5, cursor: 'pointer', padding: 0 }}
                      >
                        {imIolMode === 'catalog' ? 'Not in catalog? Type it in' : 'Pick from catalog instead'}
                      </button>
                    )}
                  </div>
                  {imIolMode === 'catalog' ? (
                    <>
                      <select
                        className="fi fi-sm"
                        value={imCatalogId}
                        onChange={(e) => {
                          const item = iolCatalog.find((c) => c.id === e.target.value);
                          setImCatalogId(e.target.value);
                          setImMfr(item?.manufacturer || '');
                          setImModel(item ? `${item.brand}${item.model ? ' ' + item.model : ''}` : '');
                        }}
                        disabled={isReadOnly}
                        style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }}
                      >
                        <option value="">-- Select IOL --</option>
                        {(imCategory ? iolCatalog.filter((c) => c.category === imCategory) : iolCatalog).map((c) => (
                          <option key={c.id} value={c.id}>{c.manufacturer} -- {c.brand}{c.model ? ` ${c.model}` : ''} ({c.code})</option>
                        ))}
                      </select>
                      {imCategory && iolCatalog.length > 0 && iolCatalog.filter((c) => c.category === imCategory).length === 0 && (
                        <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 2 }}>No catalog IOLs under &quot;{imCategory}&quot; -- showing full catalog instead.</div>
                      )}
                    </>
                  ) : (
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Manufacturer" value={imMfr} onChange={(e) => { setImMfr(e.target.value); setImCatalogId(''); }} disabled={isReadOnly} style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }} />
                      <input className="fi fi-sm" placeholder="Model" value={imModel} onChange={(e) => { setImModel(e.target.value); setImCatalogId(''); }} disabled={isReadOnly} style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }} />
                    </div>
                  )}
                </div>
              </div>
            </div>

            {variancePresent && (
              <div style={{ marginBottom: 10 }}>
                <label className="flbl">Variance reason (mandatory to proceed)</label>
                <input className="fi fi-sm" value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isReadOnly} placeholder="Document reason for deviation from the approved plan..." />
              </div>
            )}

            <div style={{ borderTop: '1px dashed var(--g200)', paddingTop: 10 }}>
              <div style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Serial / Batch (from the implanted unit's label)</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                <div><label className="flbl">Serial / Batch number</label><input className="fi fi-sm" value={imSerial} onChange={(e) => setImSerial(e.target.value)} disabled={isReadOnly} /></div>
                <div><label className="flbl">Expiry date</label><input type="date" className="fi fi-sm" value={imExpiry} onChange={(e) => setImExpiry(e.target.value)} disabled={isReadOnly} /></div>
              </div>
            </div>
          </div>

          {/* Anaesthesia */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-injection" style={{ color: 'var(--teal)' }}></i> Anaesthesia</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Anaesthesia type</label><select className="fi fi-sm" value={anaesType} onChange={(e) => setAnaesType(e.target.value)} disabled={isReadOnly}><option>Topical</option><option>Peribulbar</option><option>Retrobulbar</option><option>Local with Sedation</option><option>General</option></select></div>
              <div><label className="flbl">Anaesthetist</label><input className="fi fi-sm" value={anaesDoctor} onChange={(e) => setAnaesDoctor(e.target.value)} disabled={isReadOnly} placeholder="If applicable" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Start time</label><input type="time" className="fi fi-sm" value={anaesStart} onChange={(e) => setAnaesStart(e.target.value)} disabled={isReadOnly} /></div>
              <div><label className="flbl">End time</label><input type="time" className="fi fi-sm" value={anaesEnd} onChange={(e) => setAnaesEnd(e.target.value)} disabled={isReadOnly} /></div>
            </div>
            <input className="fi fi-sm" value={anaesRemarks} onChange={(e) => setAnaesRemarks(e.target.value)} disabled={isReadOnly} placeholder="Sedation details / special remarks..." />
            {!intraop?.anaesthesia_recorded_at && !isCompleted && (
              <button className="btn btn-sm" style={{ background: 'var(--blue)', color: '#fff', border: 'none', marginTop: 8 }} onClick={handleRecordAnaesthesia}><i className="ti ti-check"></i> Record anaesthesia</button>
            )}
            {intraop?.anaesthesia_recorded_at && <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 6 }}><i className="ti ti-check"></i> Recorded</div>}
          </div>

          {/* Surgical Consumables -- pre-op selection via dropdown from
              the Clinical Master; same underlying list as the quick-pick
              badges in Intraoperative Management. */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-box" style={{ color: 'var(--amber)' }}></i> Surgical Consumables</div>
            {!isCompleted && (
              <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                <select className="fi fi-sm" style={{ flex: 1 }} value={checkinConsumableId} onChange={(e) => setCheckinConsumableId(e.target.value)}>
                  <option value="">-- Select consumable --</option>
                  {consumableOptions.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
                </select>
                <button
                  className="btn btn-sm"
                  style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
                  onClick={() => {
                    const selected = consumableOptions.find((c) => c.id === checkinConsumableId);
                    if (!selected) return;
                    handleAddConsumable(selected.name);
                    setCheckinConsumableId('');
                  }}
                >
                  <i className="ti ti-plus"></i> Add
                </button>
              </div>
            )}
            {consumables.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-box" style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{c.name}</span>
                {!isCompleted && <button onClick={() => removeConsumable(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
            {consumables.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>None selected yet.</div>}
          </div>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={onBack}><i className="ti ti-arrow-left"></i> Back to Dashboard</button>
            {intraop?.checkin_completed_at || isCompleted ? (
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Checked In</span>
            ) : (
              <button className="btn btn-primary" onClick={handleCompleteCheckin} disabled={!manualCheckinDone || !requiredConsentsOk}>
                <i className="ti ti-check"></i> Check In
              </button>
            )}
          </div>
          </>
          )}

          {subTab === 'intraop' && (
          <>
          {/* Consumables */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-box" style={{ color: 'var(--amber)' }}></i> Consumables</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {consumableOptions.map((c) => <span key={c.id} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isReadOnly && handleAddConsumable(c.name)}>{c.name}</span>)}
            </div>
            {!isReadOnly && (
              <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} value={consumableName} onChange={(e) => setConsumableName(e.target.value)} placeholder="Consumable name..." />
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => handleAddConsumable()}><i className="ti ti-plus"></i> Add</button>
              </div>
            )}
            {consumables.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-box" style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{c.name}</span>
                {!isReadOnly && <button onClick={() => removeConsumable(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Events */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Intraoperative Events</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {EVENT_QUICK.map((e) => <span key={e} className="badge b-amber" style={{ cursor: 'pointer' }} onClick={() => setEventName(e)}>{e}</span>)}
            </div>
            {!isReadOnly && (
              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: 8, marginBottom: 8 }}>
                <input className="fi fi-sm" value={eventName} onChange={(e) => setEventName(e.target.value)} placeholder="Event description..." />
                <select className="fi fi-sm" value={eventSeverity} onChange={(e) => setEventSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddEvent}><i className="ti ti-plus"></i></button>
              </div>
            )}
            {events.map((e) => (
              <div key={e.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginBottom: 6, fontSize: 12, border: '1px solid var(--g200)', background: e.severity === 'Severe' ? 'var(--red-lt)' : e.severity === 'Moderate' ? 'var(--amber-lt)' : 'var(--g50)' }}>
                <div style={{ flex: 1 }}><strong>{e.name}</strong> <span className={`badge ${e.severity === 'Severe' ? 'b-red' : e.severity === 'Moderate' ? 'b-amber' : 'b-gray'}`} style={{ fontSize: 10 }}>{e.severity}</span></div>
                {!isReadOnly && <button onClick={() => removeIntraopEvent(e.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Complications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Complications</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {COMPL_QUICK.map((c) => <span key={c} className="badge b-red" style={{ cursor: 'pointer' }} onClick={() => setComplName(c)}>{c}</span>)}
            </div>
            {!isReadOnly && (
              <>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication..." />
                  <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management (required)" />
                  <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome (if known)" />
                </div>
                <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
              </>
            )}
            {complications.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginTop: 8, fontSize: 12, border: '1px solid var(--g200)', background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)' }}>
                <div style={{ flex: 1 }}>
                  <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
                  <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>Management: {c.management}</div>
                  {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
                </div>
                {!isReadOnly && <button onClick={() => removeIntraopEvent(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Operative Notes</div>
            <textarea className="fi fi-sm" rows={3} value={opNotes} onChange={(e) => setOpNotes(e.target.value)} disabled={isReadOnly} placeholder="Free-text operative narrative..." />
          </div>

          {/* Outcome */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--green)' }}></i> Surgical Outcome</div>
            <select className="fi fi-sm" value={surgicalOutcome} onChange={(e) => setSurgicalOutcome(e.target.value)} disabled={isReadOnly} style={{ marginBottom: 8 }}>
              <option>Successful</option><option>Successful with Complication</option><option>Converted Procedure</option><option>Procedure Deferred</option><option>Procedure Abandoned</option>
            </select>
            <input className="fi fi-sm" value={outcomeRemarks} onChange={(e) => setOutcomeRemarks(e.target.value)} disabled={isReadOnly} placeholder="Additional remarks..." />
          </div>

          {/* Recovery */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Recovery Handover</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery destination</label><select className="fi fi-sm" value={recoveryDest} onChange={(e) => setRecoveryDest(e.target.value)} disabled={isReadOnly}><option>Recovery Bay 1</option><option>Recovery Bay 2</option><option>Day Care Ward</option></select></div>
              <div><label className="flbl">Required monitoring</label><input className="fi fi-sm" value={recoveryMonitor} onChange={(e) => setRecoveryMonitor(e.target.value)} disabled={isReadOnly} placeholder="e.g. Vitals q15min x1hr" /></div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Post-operative instructions</label>
              <textarea className="fi fi-sm" rows={2} value={recoveryInstructions} onChange={(e) => setRecoveryInstructions(e.target.value)} disabled={isReadOnly} placeholder="e.g. Eye shield overnight. Moxifloxacin QID..." />
            </div>
            <input className="fi fi-sm" value={recoveryConcerns} onChange={(e) => setRecoveryConcerns(e.target.value)} disabled={isReadOnly} placeholder="Immediate concerns (if any)..." />
          </div>

          {!isCompleted && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={handleSaveDraft} disabled={saving}>
                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Draft'}
              </button>
              <button className="btn btn-primary" onClick={handleCompleteSurgery}>
                <i className="ti ti-circle-check"></i> Surgery Complete
              </button>
            </div>
          )}
          {isCompleted && !unlocked && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Surgery Completed</span>
            </div>
          )}
          {isCompleted && unlocked && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={() => { setUnlocked(false); refresh(); }}>
                <i className="ti ti-x"></i> Discard & Lock
              </button>
              <button className="btn btn-primary" style={{ background: 'var(--amber)', borderColor: 'var(--amber)' }} onClick={handleCompleteSurgery}>
                <i className="ti ti-device-floppy"></i> Save Changes
              </button>
            </div>
          )}
          </>
          )}
        </div>

        {/* RIGHT: status panel */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>OT Case Status</div>
            <div style={{ padding: 10, background: 'var(--blue-lt)', borderRadius: 8, textAlign: 'center' }}>
              <div style={{ fontSize: 11, color: 'var(--blue)', fontWeight: 700 }}>{STEPS[currentStep]}</div>
              <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>Step {currentStep + 1} of {STEPS.length}</div>
            </div>
          </div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Quick Stats</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Events</span><strong>{events.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Complications</span><strong style={{ color: complications.length ? 'var(--red)' : 'inherit' }}>{complications.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Consumables</span><strong>{consumables.length}</strong></div>
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Completion Checklist</div>
            {[
              { label: 'Implant information complete', done: biometryPlans.length === 0 || !!(imPower && imSerial) },
              { label: 'Recovery handover documented', done: !!recoveryInstructions },
            ].map((it) => (
              <div key={it.label} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className={`ti ${it.done ? 'ti-circle-check' : 'ti-circle'}`} style={{ color: it.done ? 'var(--green)' : 'var(--g300)' }}></i> {it.label}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

FILEEOF_ot_intraop_workspace_js

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/actions.js" << 'FILEEOF_ot_recovery_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs } from '../master-data/actions';

// Same Pharmacy drug list used in Financial Masters -- so post-op
// medication is picked from the real catalog, not free text. Label
// leads with Name (brand), not Salt Composition (generic) -- this is
// what ends up stored as the medication name and printed on the
// Discharge Summary.
export async function getDrugOptions() {
  const all = await getDrugs();
  return all
    .filter((d) => d.status === 'Active' && d.brand)
    .map((d) => ({ id: d.id, label: `${d.brand}${d.strength ? ` ${d.strength}` : ''}${d.generic ? ` (${d.generic})` : ''}` }));
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
// Dashboard vs History split). ──
export async function getRecoveryCaseList() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .or(`discharge_date.is.null,discharge_date.eq.${todayIst}`)
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

FILEEOF_ot_recovery_actions_js

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/workspace.js" << 'FILEEOF_ot_recovery_workspace_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, removeRecoveryMedication, confirmDischarge, getDrugOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';
import { openPrintPopup } from '@/lib/printPopup';

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
  const [medName, setMedName] = useState('');
  const [drugOptions, setDrugOptions] = useState([]);
  const [dischargeDate, setDischargeDate] = useState(new Date().toISOString().slice(0, 10));
  const [medSig, setMedSig] = useState('');
  const [medReason, setMedReason] = useState('');
  const [showMedForm, setShowMedForm] = useState(false);

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
    setDischargeDate(e.discharge_date || new Date().toISOString().slice(0, 10));
    if (!e.discharge_date) {
      setFollowupPlan((prev) => (prev.length > 0 ? prev : defaultFollowupPlan(e.discharge_date || new Date().toISOString().slice(0, 10))));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); }, [episodeId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { episode, sc, intraop, biometryPlans, meds, followups } = data;
  const patient = sc.patients;
  const isDischarged = !!episode.discharge_date;
  const isClosed = !!episode.closure_status;

  function toggleChecklistItem(key) {
    if (isClosed) return;
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
    const result = await addRecoveryMedication(episodeId, medName, medSig, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedSig(''); setMedReason(''); setShowMedForm(false);
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

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          {/* Surgical summary read-only */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
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
              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={isClosed} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={isClosed}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={isClosed}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={isClosed}><option>No</option><option>Yes</option></select></div>
            </div>
            {escalation && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Escalation reason</label>
                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={isClosed} placeholder="Document reason for escalation..." />
              </div>
            )}
            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={isClosed} placeholder="Clinical observations / immediate concerns..." />
          </div>

          {/* Discharge checklist */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--green)' }}></i> Discharge Readiness Checklist</div>
              <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
            </div>
            {DISCHARGE_ITEMS.map((item) => (
              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isClosed ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          {/* Medications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
            {meds.map((m) => (
              <div key={m.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
                <span style={{ flex: 1 }}><strong>{m.name}</strong> -- {m.sig}</span>
                {!isClosed && <button onClick={() => removeRecoveryMedication(m.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
            {meds.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
            {!isClosed && (
              <>
                {!showMedForm ? (
                  <button className="btn btn-sm btn-primary" style={{ marginTop: 8 }} onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                ) : (
                  <div style={{ marginTop: 8 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                      <select className="fi fi-sm" value={medName} onChange={(e) => setMedName(e.target.value)}>
                        <option value="">-- Select medicine --</option>
                        {drugOptions.map((d) => <option key={d.id} value={d.label}>{d.label}</option>)}
                      </select>
                      <input className="fi fi-sm" value={medSig} onChange={(e) => setMedSig(e.target.value)} placeholder="Dose/Freq/Duration" />
                    </div>
                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6 }} />
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-sm btn-primary" onClick={handleAddMedicine}>Add</button>
                      <button className="btn btn-sm" onClick={() => setShowMedForm(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </>
            )}
          </div>

          {/* Discharge instructions */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
            </div>
            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={isClosed} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
          </div>

          {/* Discharge notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={isClosed} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
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
        </div>
      )}
    </div>
  );
}

FILEEOF_ot_recovery_workspace_js

mkdir -p "app/(main)/investigation"
cat > "app/(main)/investigation/actions.js" << 'FILEEOF_investigation_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

// ── QUEUE (Ordered + In Progress, grouped by visit) plus today's KPI
// stats for the Queue screen's summary cards. ──
export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data: pending, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return { groups: [], stats: { ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 } };

  // Payment status is about the invoice, not just whether Front Office
  // ticked "billed" -- an invoice can be raised and still unpaid, so
  // this looks at the actual invoice net/paid amounts.
  const invoiceIds = [...new Set((pending || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  const groups = {};
  (pending || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient: io.encounters.visits.patients, items: [] };
    }
    groups[visitId].items.push({ ...io, kind: 'investigation', payment: paymentInfo(io) });
  });

  // Biometry is structurally its own thing (device measurements, IOL
  // recommendations, surgeon approval -- not a text-field investigation),
  // so it stays in its own table and dedicated workspace/dashboard. But
  // per the doctor's actual usage, it belongs in the same "what's
  // outstanding for this patient" queue as any other investigation, not
  // off in a separate module people forget to check. Only "Awaiting
  // Biometry" is pending now -- "Measured" means done (there's no more
  // Calculated/Approved in between; those concepts moved to the
  // separate IOL Approval module).
  const { data: bio } = await supabase
    .from('biometry_records')
    .select('*, visits(id, patients(first_name, last_name, uhid))')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  const bioInvoiceIds = [...new Set((bio || []).map((r) => r.invoice_id).filter(Boolean))];
  let bioInvoiceMap = invoiceMap;
  if (bioInvoiceIds.length > 0) {
    const { data: moreInvoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', bioInvoiceIds);
    (moreInvoices || []).forEach((inv) => { bioInvoiceMap[inv.id] = inv; });
  }
  function bioPaymentInfo(r) {
    if (r.billing_status !== 'Billed' || !r.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = bioInvoiceMap[r.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  (bio || []).forEach((r) => {
    // Biometry is patient-level and reusable now, not visit-scoped, so
    // visit_id can legitimately be null (e.g. ordered a while back, or
    // a case registered directly). Skip merging into this per-visit
    // queue in that case -- it still shows up in Biometry's own queue
    // either way.
    const visitId = r.visit_id;
    const patient = r.visits?.patients;
    if (!visitId || !patient) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient, items: [] };
    }
    groups[visitId].items.push({
      id: r.id, kind: 'biometry', name: 'Biometry', eye: 'OU', priority: 'Routine',
      status: r.status, created_at: r.created_at, payment: bioPaymentInfo(r),
    });
  });

  const ordered = (pending || []).filter((i) => i.status === 'Ordered').length;
  const inProgress = (pending || []).filter((i) => i.status === 'In Progress').length;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: todayOrders } = await supabase
    .from('investigation_orders')
    .select('id, status, verified_at, created_at')
    .gte('created_at', todayStart.toISOString());

  const availableToday = (todayOrders || []).filter((o) => o.status === 'Available' && o.verified_at && new Date(o.verified_at) >= todayStart).length;
  const totalToday = (todayOrders || []).length;

  return { groups: Object.values(groups), stats: { ordered, inProgress, availableToday, totalToday } };
}

// ── TODAY'S INVESTIGATIONS -- for the Dashboard widget (patient, test
// name, billing status, view/print). IST-bounded so "today" matches
// the front desk's actual working day rather than UTC midnight.
// Returns everything ordered today regardless of status -- the page
// splits pending vs completed client-side (see investigation/page.js). ──
export async function getTodaysInvestigations() {
  const supabase = await createClient();
  const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIST}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIST}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, visits(patients(first_name, last_name, uhid)))')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .order('created_at', { ascending: false });
  if (error) return [];

  const invoiceIds = [...new Set((data || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  return (data || [])
    .filter((io) => io.encounters?.visits?.patients)
    .map((io) => ({
      id: io.id,
      name: io.name,
      eye: io.eye,
      status: io.status,
      patient: io.encounters.visits.patients,
      payment: paymentInfo(io),
    }));
}


// ── WORKSPACE: single order detail, with patient/doctor context ──
export async function getInvestigationDetail(id, viewOnly) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)))')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  // Opening the order to work on it (not just viewing) is the "start" --
  // no separate button needed. Timestamped with whoever opened it.
  if (!viewOnly && data.status === 'Ordered') {
    const { data: userData } = await supabase.auth.getUser();
    const startedAt = new Date().toISOString();
    await supabase.from('investigation_orders').update({
      status: 'In Progress', started_at: startedAt, started_by: userData?.user?.id || null,
    }).eq('id', id);
    data.status = 'In Progress';
    data.started_at = startedAt;
    data.started_by = userData?.user?.id || null;
  }

  let doctorName = '--';
  if (data.encounters?.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.encounters.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  let startedByName = null;
  if (data.started_by) {
    const { data: tech } = await supabase.from('profiles').select('full_name').eq('id', data.started_by).maybeSingle();
    startedByName = tech?.full_name || null;
  }

  return { order: data, doctorName, startedByName };
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({ status: 'In Progress' })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_started', { name: order?.name });
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later, patient stays in the queue.
export async function saveInvestigationDraft(id, resultData, remarks) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('investigation_orders')
    .update({ result_data: resultData, result_notes: remarks })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, resultData, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_data: resultData,
      result_notes: remarks || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  // This is the moment that actually matters for the patient's timeline
  // -- results are entered and they're walking back to the doctor with
  // the report. Verification (below) is a separate QA checklist step
  // that can happen much later, sometimes by someone else entirely, so
  // it shouldn't be what closes out "In Investigation" time.
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_completed', { name: order?.name });
  return { success: true };
}

// Verification is the gate between "technically done" and "visible to
// the doctor" -- status jumps straight to Available once every checklist
// item is confirmed (there's no separate persisted "Verified" state;
// it's a visual timeline step on the way to Available).
// Same "combine, don't overwrite" logic doctorSendOut uses -- a patient
// can be Awaiting more than one thing at once, so resolving Investigation
// should only clear that part, not silently blow away Biometry/Dilation
// if they're still pending.
async function resolveAwaitingPart(supabase, visitId, part) {
  if (!visitId) return;
  const { data: entry } = await supabase
    .from('queue_entries').select('id, status')
    .eq('visit_id', visitId).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!entry || !entry.status?.startsWith('Awaiting')) return;

  const remaining = entry.status.replace('Awaiting ', '').split(' & ').filter((l) => l !== part);
  const newStatus = remaining.length > 0 ? `Awaiting ${remaining.join(' & ')}` : 'Ready for Review';
  await supabase.from('queue_entries').update({ status: newStatus }).eq('id', entry.id);
}

export async function verifyInvestigation(id, checklist) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const allChecked = Object.values(checklist).every(Boolean) && Object.keys(checklist).length > 0;
  if (!allChecked) return { error: 'All verification items must be checked before verifying.' };

  const { data: order } = await supabase.from('investigation_orders').select('name, encounter_id, encounters(visit_id)').eq('id', id).maybeSingle();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Available',
      verification_checklist: checklist,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };

  await resolveAwaitingPart(supabase, order?.encounters?.visit_id, 'Investigation');

  return { success: true };
}

export async function markUnableToPerform(id, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  const { error } = await supabase
    .from('investigation_orders')
    .update({ status: 'Cancelled', unable_reason: reason })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every investigation lands here the moment it's ordered from
// Consultation, regardless of lab status -- Front Office bills as soon
// as the doctor orders it, it doesn't wait on the lab. Grouped by visit
// the same way the lab's own Queue screen is, so it reads the same way.
export async function getPendingInvestigationBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    const visit = io.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

async function setInvestigationBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationDenied(id, note) {
  return setInvestigationBillingStatus(id, 'Denied', note);
}

export async function markInvestigationDeferred(id, note) {
  return setInvestigationBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetInvestigationBilling(id) {
  return setInvestigationBillingStatus(id, 'Pending', null);
}

// ── HISTORY ──
// Every investigation ever ordered, regardless of status -- filtering
// happens client-side (patient/type dropdowns) since a single-hospital
// dataset is small enough that a broad fetch is simpler and fast enough,
// same approach the rest of this module already takes.
export async function getInvestigationHistory(fromDate, toDate) {
  const supabase = await createClient();
  let query = supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(id, first_name, last_name, uhid)))')
    .order('created_at', { ascending: false })
    .limit(500);

  // Applied before the row cap so a date range reaches further back
  // than the default "most recent 500" would otherwise allow.
  if (fromDate) query = query.gte('created_at', `${fromDate}T00:00:00`);
  if (toDate) query = query.lte('created_at', `${toDate}T23:59:59`);

  const { data, error } = await query;
  if (error) return { error: error.message };

  const doctorIds = (data || []).map((o) => o.encounters?.doctor_id).filter(Boolean);
  const staffIds = (data || []).flatMap((o) => [o.completed_by, o.verified_by]).filter(Boolean);
  const allIds = [...new Set([...doctorIds, ...staffIds])];

  let profileMap = {};
  if (allIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', allIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }

  const rows = (data || []).map((o) => ({
    ...o,
    doctorName: profileMap[o.encounters?.doctor_id] || '--',
    performedByName: profileMap[o.verified_by] || profileMap[o.completed_by] || '--',
  }));

  return { rows };
}

// ── LONGITUDINAL COMPARISON ──
export async function searchPatientsForInvestigation(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getInvestigationComparisonData(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters!inner(id, visit_id, visits!inner(id, patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .in('status', ['Completed', 'Available'])
    .order('created_at', { ascending: true });
  if (error) return { error: error.message };
  return { rows: data || [] };
}

// ── REPORTS ──
export async function getInvestigationReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const fromIso = `${fromDate}T00:00:00`;
  const toIso = `${toDate}T23:59:59`;

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, doctor_id, visits(id, patients(first_name, last_name, uhid)))')
    .gte('created_at', fromIso)
    .lte('created_at', toIso)
    .order('created_at', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  const doctorIds = [...new Set((data || []).map((o) => o.encounters?.doctor_id).filter(Boolean))];
  let profileMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const doctorName = (o) => profileMap[o.encounters?.doctor_id] || '--';
  const patientName = (o) => {
    const p = o.encounters?.visits?.patients;
    return p ? `${p.first_name} ${p.last_name} (${p.uhid})` : '--';
  };

  if (reportId === 'register') {
    return {
      title: 'Daily Investigation Register',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: (data || []).map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'type_summary') {
    const counts = {};
    (data || []).forEach((o) => {
      const n = (o.name || '').toLowerCase();
      const type = n.includes('oct') ? 'OCT' : (n.includes('visual field') || n.includes(' vf')) ? 'Visual Field' : n.includes('fundus') ? 'Fundus Photography' : 'External Report';
      counts[type] = (counts[type] || 0) + 1;
    });
    return {
      title: 'Investigation Type Summary',
      headers: ['Type', 'Count'],
      rows: Object.entries(counts).map(([type, count]) => ({ cols: [type, count] })),
    };
  }

  if (reportId === 'pending') {
    const pending = (data || []).filter((o) => o.status === 'Ordered' || o.status === 'In Progress');
    return {
      title: 'Pending Investigations',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: pending.map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'quality') {
    const cancelled = (data || []).filter((o) => o.status === 'Cancelled');
    const total = (data || []).length;
    const rows = cancelled.map((o) => ({
      cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.unable_reason || '--'],
    }));
    rows.push({ cols: [`Total ordered in period: ${total}`, `Unable to perform: ${cancelled.length}`, '', ''] });
    return {
      title: 'Quality Report -- Unable to Perform',
      headers: ['Date', 'Patient', 'Investigation', 'Reason'],
      rows,
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

FILEEOF_investigation_actions_js

mkdir -p "app/(main)/biometry/history"
cat > "app/(main)/biometry/history/page.js" << 'FILEEOF_biometry_history_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryHistory } from '../actions';

function bestReading(sets) {
  if (!Array.isArray(sets) || sets.length === 0) return {};
  return sets.find((s) => s.axl && s.k1 && s.k2 && s.acd) || sets[0] || {};
}

export default function BiometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patients, setPatients] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const router = useRouter();

  const refresh = useCallback(async (filter) => {
    const result = await getBiometryHistory(filter || undefined);
    setRows(result.rows);
    setPatients(result.patients);
  }, []);

  useEffect(() => { refresh(patientFilter); }, [patientFilter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Biometry History</div>
          <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
            <option value="">All patients</option>
            {patients.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
          One record per patient, reused across every future surgical case -- readings don't meaningfully change for years. IOL brand/power recommendations and the surgeon's final approval are on each record's own page.
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date</th><th>Patient</th><th>RE: AXL / K1/K2 / ACD</th><th>LE: AXL / K1/K2 / ACD</th><th>Device</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.patients;
              const reReading = bestReading(r.measurements?.re);
              const leReading = bestReading(r.measurements?.le);
              return (
                <tr key={r.id} onClick={() => router.push(`/biometry/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.updated_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td>
                    <strong>{patient?.first_name} {patient?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{reReading.axl || '--'} / {reReading.k1 || '--'}/{reReading.k2 || '--'} / {reReading.acd || '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{leReading.axl || '--'} / {leReading.k1 || '--'}/{leReading.k2 || '--'} / {leReading.acd || '--'}</td>
                  <td style={{ fontSize: 11 }}>{r.verify_device || '--'}</td>
                  <td><span className="badge b-green">{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
FILEEOF_biometry_history_page_js

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/actions.js" << 'FILEEOF_biometry_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──────────────────────────────────────────────────────────
// Biometry is patient-level now, not visit/case-level -- a session is
// reused across every future surgical case for that patient. The queue
// just lists records not yet Measured, regardless of which visit
// originally ordered them.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measuredToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.patients)
    .map((r) => ({
      recordId: r.id,
      patientId: r.patient_id,
      patient: r.patients,
      status: r.status,
      doctorInstructions: r.doctor_instructions,
    }));

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const { data: measuredToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC);

  const stats = {
    awaiting: rows.length,
    measuredToday: (measuredToday || []).length,
  };

  return { rows, stats };
}

// ── COMPLETED TODAY -- Measured records from today, so a session
// doesn't disappear from the Queue the instant it's done. Moves to
// History once the day rolls over -- same Dashboard/History split used
// elsewhere. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC)
    .lte('updated_at', endUTC)
    .order('updated_at', { ascending: false });
  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ recordId: r.id, patientId: r.patient_id, patient: r.patients, status: r.status }));
}

// Finds an existing biometry record for this PATIENT -- reused across
// every future surgical case (readings don't meaningfully change for
// years), so this is a lookup-or-create against patient_id, not
// visit_id like most other "ensure a record" functions in this app.
export async function getOrCreateBiometryRecord(patientId, visitId, encounterId) {
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid, age, gender)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  const { data: recommendations } = await supabase
    .from('biometry_iol_recommendations')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('biometry_record_id', id)
    .order('created_at', { ascending: true });

  return { record: data, recommendations: recommendations || [] };
}

// Persists measurement readings without changing status -- technician
// can leave and resume later.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

// Marks the session done -- requires at least one complete reading for
// EACH eye (biometry is always done for both eyes now) and at least
// one IOL recommendation row entered, plus the device report attached
// (checked by the caller via AttachmentUploader's own listing, not
// re-verified here -- consistent with how other modules treat
// attachments as informational rather than a hard DB gate).
export async function markBiometryMeasured(id, measurements, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const reHasComplete = (measurements.re || []).some(isComplete);
  const leHasComplete = (measurements.le || []).some(isComplete);
  if (!reHasComplete || !leHasComplete) {
    return { error: 'At least one complete reading (AXL, K1, K2, ACD) is required for BOTH eyes.' };
  }

  const { count } = await supabase
    .from('biometry_iol_recommendations')
    .select('id', { count: 'exact', head: true })
    .eq('biometry_record_id', id);
  if (!count) return { error: 'Add at least one IOL recommendation from the device printout before marking as measured.' };

  const devicesUsed = [...new Set([...(measurements.re || []), ...(measurements.le || [])].map((s) => s.device).filter(Boolean))];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Measured',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks || null,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  if (data?.visit_id) await logJourneyEvent(supabase, data.visit_id, 'biometry_completed');
  return { success: true };
}

// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
// The device's own printed table -- for each brand/model it evaluated,
// what power it recommends per eye. This app records what the printout
// says; it does not calculate anything itself.
export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
  const supabase = await createClient();
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
  const { error } = await supabase.from('biometry_iol_recommendations').insert({
    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    re_power: rePower || null, le_power: lePower || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIolRecommendation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── HISTORY -- cross-patient, Measured or Cancelled. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ patientId: r.patient_id, patient: r.patients, items: [r] }));
}

async function setBiometryBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markBiometryDenied(id, note) {
  return setBiometryBillingStatus(id, 'Denied', note);
}

export async function markBiometryDeferred(id, note) {
  return setBiometryBillingStatus(id, 'Deferred', note);
}

export async function resetBiometryBilling(id) {
  return setBiometryBillingStatus(id, 'Pending', null);
}
FILEEOF_biometry_actions_js

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/page.js" << 'FILEEOF_biometry_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryQueue, getBiometryCompletedToday } from './actions';

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function BiometryQueuePage() {
  const [rows, setRows] = useState([]);
  const [completedToday, setCompletedToday] = useState([]);
  const [stats, setStats] = useState({ awaiting: 0, measuredToday: 0 });
  const [error, setError] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getBiometryQueue();
    setRows(result.rows);
    setStats(result.stats);
    setCompletedToday(await getBiometryCompletedToday());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Awaiting biometry" value={stats.awaiting} sub="Not yet measured" color="var(--indigo)" />
        <KpiCard label="Measured today" value={stats.measuredToday} sub="Sessions completed today" color="var(--green)" />
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Biometry is always done for both eyes and is reusable across every future surgical case for this patient -- readings don't meaningfully change for years. Surgeon IOL approval for a specific case happens in its own module.
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Biometry Queue</div>
          <button className="btn btn-sm" onClick={() => router.push('/biometry/history')}>
            <i className="ti ti-history"></i> History
          </button>
        </div>
        {rows.map((row) => (
          <div key={row.recordId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{row.patient?.first_name} {row.patient?.last_name}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{row.status}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {row.patient?.uhid}{row.doctorInstructions ? ` -- ${row.doctorInstructions}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => router.push(`/biometry/${row.recordId}`)}>
              <i className="ti ti-ruler-measure"></i> Measure
            </button>
          </div>
        ))}
        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            Nothing pending -- all caught up.
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Measured Today</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still viewable from here today.</div>
        {completedToday.map((row) => (
          <div key={row.recordId} onClick={() => router.push(`/biometry/${row.recordId}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{row.patient?.first_name} {row.patient?.last_name}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Measured</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>{row.patient?.uhid}</div>
            </div>
            <button className="btn btn-sm"><i className="ti ti-eye"></i> View</button>
          </div>
        ))}
        {completedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing measured yet today.</div>
        )}
      </div>
    </div>
  );
}
FILEEOF_biometry_page_js

mkdir -p "app/(main)/biometry/[id]"
cat > "app/(main)/biometry/[id]/page.js" << 'FILEEOF_biometry_id_page_js'
import BiometryWorkspace from './workspace';

export default async function BiometryWorkspacePage({ params }) {
  const { id } = await params;
  return <BiometryWorkspace recordId={id} />;
}
FILEEOF_biometry_id_page_js

mkdir -p "app/(main)/biometry/[id]"
cat > "app/(main)/biometry/[id]/workspace.js" << 'FILEEOF_biometry_id_workspace_js'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
  addIolRecommendation, removeIolRecommendation,
} from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];
const DEVICES = ['ZEISS IOLMaster 700', 'Haag-Streit Lenstar', 'NIDEK AL-Scan', 'Manual A-Scan'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

function emptySet(device) {
  return { device, axl: '', k1: '', k2: '', acd: '', lt: '', wtw: '' };
}
function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, disabled, headColor, headBg }) {
  const [newDevice, setNewDevice] = useState(DEVICES[0]);
  return (
    <div>
      <div style={{ padding: '8px 12px', fontSize: 12, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, background: headBg, color: headColor, borderRadius: '8px 8px 0 0' }}>
        <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {label}
      </div>
      <div style={{ border: '1px solid var(--g200)', borderTop: 'none', borderRadius: '0 0 8px 8px', padding: '10px 12px' }}>
        {sets.length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)', padding: '4px 0' }}>No readings yet.</div>}
        {sets.map((set, idx) => (
          <div key={idx} style={{ marginBottom: 10, paddingBottom: 10, borderBottom: idx < sets.length - 1 || !disabled ? '1px dashed var(--g200)' : 'none' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
              <span className={`badge ${isComplete(set) ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>
                <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
              </span>
              {!disabled && <button className="btn" style={{ padding: '1px 7px', fontSize: 10 }} onClick={() => onRemoveSet(eyeKey, idx)}>Remove</button>}
            </div>
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <input
                    type="text" value={set[f.key] || ''} onChange={(e) => onFieldChange(eyeKey, idx, f.key, e.target.value)}
                    disabled={disabled} placeholder="--"
                    style={{ width: 90, padding: '4px 7px', border: '1.5px solid var(--g200)', borderRadius: 8, fontSize: 12, textAlign: 'right' }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--g400)' }}>{f.unit}</span>
                </div>
              </div>
            ))}
          </div>
        ))}
        {!disabled && (
          <div style={{ display: 'flex', gap: 6 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={newDevice} onChange={(e) => setNewDevice(e.target.value)}>
              {DEVICES.map((d) => <option key={d}>{d}</option>)}
            </select>
            <button className="btn btn-sm" onClick={() => onAddSet(eyeKey, newDevice)}><i className="ti ti-plus"></i> Add reading</button>
          </div>
        )}
      </div>
    </div>
  );
}

function RecommendationsSection({ recordId, recommendations, catalog, disabled, onSaved }) {
  const [catalogId, setCatalogId] = useState('');
  const [rePower, setRePower] = useState('');
  const [lePower, setLePower] = useState('');
  const [error, setError] = useState('');

  async function handleAdd() {
    setError('');
    const result = await addIolRecommendation(recordId, catalogId, rePower, lePower);
    if (result.error) { setError(result.error); return; }
    setCatalogId(''); setRePower(''); setLePower('');
    onSaved();
  }

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> IOL Recommendations (from device printout)</div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
        For each IOL brand/model the device evaluated, enter the power it recommends per eye -- transcribed straight from the printout, not calculated here.
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}

      {recommendations.length > 0 && (
        <table className="tbl" style={{ marginBottom: 10 }}>
          <thead><tr><th>Brand / Model</th><th>RE Power</th><th>LE Power</th><th></th></tr></thead>
          <tbody>
            {recommendations.map((r) => (
              <tr key={r.id}>
                <td>{r.master_iol_catalog?.brand} {r.master_iol_catalog?.model}</td>
                <td>{r.re_power ?? '--'}</td>
                <td>{r.le_power ?? '--'}</td>
                <td>
                  {!disabled && (
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeIolRecommendation(r.id); onSaved(); }}>
                      <i className="ti ti-trash"></i>
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {!disabled && (
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 8 }}>
          <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
            <option value="">Select brand/model...</option>
            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
          </select>
          <input className="fi fi-sm" placeholder="RE power" value={rePower} onChange={(e) => setRePower(e.target.value)} />
          <input className="fi fi-sm" placeholder="LE power" value={lePower} onChange={(e) => setLePower(e.target.value)} />
          <button className="btn btn-sm btn-primary" onClick={handleAdd}><i className="ti ti-plus"></i></button>
        </div>
      )}
    </div>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [recommendations, setRecommendations] = useState([]);
  const [catalog, setCatalog] = useState([]);
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [remarks, setRemarks] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  async function refresh() {
    const result = await getBiometryDetail(recordId);
    if (result.error) { setLoadError(result.error); return; }
    setRecord(result.record);
    setRecommendations(result.recommendations);
    const m = result.record.measurements || {};
    setMeasurements({
      re: Array.isArray(m.re) ? m.re : (m.re && Object.keys(m.re).length ? [{ ...m.re, device: result.record.verify_device || 'Unspecified' }] : []),
      le: Array.isArray(m.le) ? m.le : (m.le && Object.keys(m.le).length ? [{ ...m.le, device: result.record.verify_device || 'Unspecified' }] : []),
    });
    setRemarks(result.record.verify_remarks || '');
  }

  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.patients;
  const isMeasured = record.status === 'Measured';
  const canEdit = !isMeasured;

  function setFieldInSet(eyeKey, idx, fieldKey, value) {
    setMeasurements((prev) => {
      const list = [...(prev[eyeKey] || [])];
      list[idx] = { ...list[idx], [fieldKey]: value };
      return { ...prev, [eyeKey]: list };
    });
  }
  function addSet(eyeKey, device) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: [...(prev[eyeKey] || []), emptySet(device)] }));
  }
  function removeSet(eyeKey, idx) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: (prev[eyeKey] || []).filter((_, i) => i !== idx) }));
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveBiometryDraft(recordId, measurements);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved.');
  }

  async function handleMarkMeasured() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await markBiometryMeasured(recordId, measurements, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Marked as measured.');
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#3730a3)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Biometry (both eyes)</div>
        </div>
        <span className="badge" style={{ background: isMeasured ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.15)', color: '#fff', fontSize: 11 }}>{record.status}</span>
      </div>

      {record.doctor_instructions && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12 }}>
          <i className="ti ti-notes"></i> <strong>Doctor's instructions:</strong> {record.doctor_instructions}
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isMeasured ? 'b-green' : 'b-gray'}`}>{isMeasured ? 'Measured' : 'Not measured'}</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Biometry is always done for both eyes. Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken.
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
          <div style={{ borderRight: '1px solid var(--g200)' }}>
            <EyeSets label="Right Eye (OD)" eyeKey="re" sets={measurements.re || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--blue)" headBg="var(--blue-lt)" />
          </div>
          <div>
            <EyeSets label="Left Eye (OS)" eyeKey="le" sets={measurements.le || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--teal)" headBg="var(--teal-lt)" />
          </div>
        </div>
      </div>

      <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-check" style={{ color: 'var(--green)' }}></i> Mark as Measured</div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleMarkMeasured} disabled={saving}>
              <i className="ti ti-check"></i> Mark as Measured
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
          </div>
        </div>
      )}

      {isMeasured && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measured{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Ready for Surgeon IOL Approval when a surgical case needs it.
          </div>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        <button className="btn" onClick={() => router.push('/biometry')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}
FILEEOF_biometry_id_workspace_js

mkdir -p "app/(main)/iol-approval"
cat > "app/(main)/iol-approval/actions.js" << 'FILEEOF_iol_approval_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';

// The surgeon's sign-off on the specific IOL brand/model/power to
// actually use for a surgical case -- separate from Biometry (which
// just records the device's raw recommendations) and Counselling
// (which picks the billing package/category). Eye comes from
// surgical_cases.eye (set by the doctor); power comes from whichever
// brand row in biometry_iol_recommendations the surgeon picks.

// ── QUEUE: cases needing approval ──────────────────────────────────
// A case needs this once biometry is Measured for the patient and
// there's no Approved iol_approvals row yet for the case.
export async function getPendingIolApprovals() {
  const supabase = await createClient();

  const { data: cases, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name, iol_category)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .neq('biometry_required', false);
  if (error) return [];

  const patientIds = [...new Set((cases || []).map((c) => c.patient_id).filter(Boolean))];
  if (patientIds.length === 0) return [];

  const { data: measured } = await supabase
    .from('biometry_records')
    .select('id, patient_id')
    .in('patient_id', patientIds)
    .eq('status', 'Measured');
  const measuredByPatient = {};
  (measured || []).forEach((m) => { measuredByPatient[m.patient_id] = m.id; });

  const caseIds = (cases || []).map((c) => c.id);
  const { data: approvals } = await supabase
    .from('iol_approvals')
    .select('surgical_case_id, status')
    .in('surgical_case_id', caseIds);
  const approvalByCase = {};
  (approvals || []).forEach((a) => { approvalByCase[a.surgical_case_id] = a.status; });

  return (cases || [])
    .filter((c) => measuredByPatient[c.patient_id] && approvalByCase[c.id] !== 'Approved')
    .map((c) => ({
      caseId: c.id,
      patient: c.patients,
      procedureName: c.procedure_name,
      eye: c.eye,
      packageName: c.master_packages?.name || null,
      biometryRecordId: measuredByPatient[c.patient_id],
      approvalStatus: approvalByCase[c.id] || 'Pending',
    }));
}

export async function getApprovedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('iol_approvals')
    .select('*, surgical_cases(id, procedure_name, eye, patients:patient_id(first_name, last_name, uhid)), master_iol_catalog(brand, model)')
    .eq('status', 'Approved')
    .gte('approved_at', startUTC)
    .lte('approved_at', endUTC)
    .order('approved_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((a) => a.surgical_cases);
}

// ── DETAIL: a case's recommendation table + current approval ──────
export async function getIolApprovalDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid, age, gender), master_packages:package_id(name, iol_category)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: biometry } = await supabase
    .from('biometry_records')
    .select('id, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recommendations = [];
  if (biometry) {
    const { data } = await supabase
      .from('biometry_iol_recommendations')
      .select('*, master_iol_catalog(id, brand, model, manufacturer, category)')
      .eq('biometry_record_id', biometry.id)
      .order('created_at', { ascending: true });
    recommendations = data || [];
  }

  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  return { case: sc, biometry, recommendations, approval: approval || null };
}

// ── APPROVE ─────────────────────────────────────────────────────────
export async function approveIol(caseId, biometryRecordId, iolCatalogId, power, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  if (approverProfile?.designation !== 'Doctor') return { error: 'Only a doctor can approve an IOL.' };

  const { data: sc } = await supabase.from('surgical_cases').select('eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!power) return { error: 'Power is required.' };

  const { data: existing } = await supabase.from('iol_approvals').select('id').eq('surgical_case_id', caseId).maybeSingle();

  const payload = {
    surgical_case_id: caseId, biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    eye: sc.eye, power, surgeon_id: userData?.user?.id || null, status: 'Approved',
    approved_at: new Date().toISOString(), notes: notes || null, updated_at: new Date().toISOString(),
  };

  const { error } = existing
    ? await supabase.from('iol_approvals').update(payload).eq('id', existing.id)
    : await supabase.from('iol_approvals').insert(payload);
  if (error) return { error: error.message };
  return { success: true };
}
FILEEOF_iol_approval_actions_js

mkdir -p "app/(main)/iol-approval"
cat > "app/(main)/iol-approval/page.js" << 'FILEEOF_iol_approval_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingIolApprovals, getApprovedToday, getIolApprovalDetail, approveIol } from './actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function ApproveModal({ item, onClose, onDone }) {
  const [detail, setDetail] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [catalogId, setCatalogId] = useState('');
  const [power, setPower] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getIolApprovalDetail(item.caseId).then(setDetail);
    getActiveIolCatalog().then(setCatalog);
  }, [item.caseId]);

  const eyeKey = item.eye === 'OD' ? 're_power' : item.eye === 'OS' ? 'le_power' : null;

  function pickRecommendation(rec) {
    setCatalogId(rec.master_iol_catalog.id);
    setPower(eyeKey ? (rec[eyeKey] ?? '') : '');
  }

  async function handleApprove() {
    setError('');
    if (!detail?.biometry) { setError('No measured biometry on file for this patient.'); return; }
    setSaving(true);
    const result = await approveIol(item.caseId, detail.biometry.id, catalogId, power, notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100, padding: 16 }} onClick={onClose}>
      <div className="card" style={{ width: 520, maxWidth: '95vw', maxHeight: '90vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-lens" style={{ color: 'var(--indigo)' }}></i> IOL Approval
        </div>
        <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 12 }}>
          {item.patient?.first_name} {item.patient?.last_name} ({item.patient?.uhid}) -- {item.procedureName} -- {EYE_LABEL[item.eye] || item.eye}
          {item.packageName && <> -- Package: {item.packageName}</>}
        </div>

        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

        {!detail ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)' }}>Loading...</div>
        ) : !detail.biometry ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--red)' }}>No measured biometry on file for this patient.</div>
        ) : (
          <>
            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Device Recommendations</div>
            {detail.recommendations.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 10 }}>No recommendations recorded on the biometry report.</div>
            )}
            <table className="tbl" style={{ marginBottom: 14 }}>
              <thead><tr><th>Brand / Model</th><th>RE</th><th>LE</th><th></th></tr></thead>
              <tbody>
                {detail.recommendations.map((r) => (
                  <tr key={r.id} style={{ background: catalogId === r.master_iol_catalog.id ? 'var(--indigo-lt, var(--blue-lt))' : 'transparent' }}>
                    <td>{r.master_iol_catalog.brand} {r.master_iol_catalog.model}</td>
                    <td>{r.re_power ?? '--'}</td>
                    <td>{r.le_power ?? '--'}</td>
                    <td>
                      <button className="btn btn-sm" onClick={() => pickRecommendation(r)}>
                        {catalogId === r.master_iol_catalog.id ? <i className="ti ti-check"></i> : 'Use this'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Confirm Choice for {EYE_LABEL[item.eye] || item.eye}</div>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
                <option value="">Select brand/model...</option>
                {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
              </select>
              <input className="fi fi-sm" placeholder="Power" value={power} onChange={(e) => setPower(e.target.value)} />
            </div>
            <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={onClose}>Cancel</button>
              <button className="btn btn-primary" onClick={handleApprove} disabled={saving || !catalogId || !power}>
                {saving ? 'Approving...' : 'Approve'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function IolApprovalPage() {
  const [pending, setPending] = useState([]);
  const [approvedToday, setApprovedToday] = useState([]);
  const [loading, setLoading] = useState(true);
  const [approving, setApproving] = useState(null);

  const refresh = useCallback(async () => {
    setPending(await getPendingIolApprovals());
    setApprovedToday(await getApprovedToday());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>IOL Approval</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>The surgeon's final sign-off on which IOL brand/model/power to actually use, per case.</div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Pending Approval
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pending.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && pending.map((item) => (
          <div key={item.caseId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {item.patient?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{item.patient?.first_name} {item.patient?.last_name}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[item.eye] || item.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {item.patient?.uhid} -- {item.procedureName}{item.packageName ? ` -- ${item.packageName}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => setApproving(item)}>
              <i className="ti ti-lens"></i> Approve
            </button>
          </div>
        ))}
        {!loading && pending.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing pending approval.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Approved Today</div>
        {approvedToday.map((a) => (
          <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {a.surgical_cases?.patients?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{a.surgical_cases?.patients?.first_name} {a.surgical_cases?.patients?.last_name}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              </div>
            </div>
          </div>
        ))}
        {approvedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>

      {approving && (
        <ApproveModal item={approving} onClose={() => setApproving(null)} onDone={() => { setApproving(null); refresh(); }} />
      )}
    </div>
  );
}
FILEEOF_iol_approval_page_js

mkdir -p "app/(main)/doctor-dashboard"
cat > "app/(main)/doctor-dashboard/page.js" << 'FILEEOF_doctor_dashboard_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDoctorDashboardData, getDoctorHistory } from './actions';
import { doctorCallNext, doctorCallSpecific, doctorMarkReady, doctorCallDirect } from '@/app/(main)/queue/actions';
import PostOpWorkspace from '@/app/(main)/ot-postop/workspace';
import { getOpenPostOpEpisodeForPatient } from '@/app/(main)/ot-postop/actions';
import { useRouter } from 'next/navigation';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { WorkspaceTab as MedicalFitnessWorkspace } from '@/app/(main)/medical-fitness/page';
import { getMedicalFitnessToday } from '@/app/(main)/medical-fitness/actions';
import { VISIT_TYPE_COLOR } from '@/lib/visit-types';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}



function TokenBadge({ token, color }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: color || 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

function VisitTypeBadge({ type }) {
  if (!type) return null;
  return (
    <span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})20`, color: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, marginLeft: 6, fontSize: 10 }}>
      {type}
    </span>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--blue)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ active, intermediate, completed, optometryWaiting, biometryApprovals, medicalFitnessToday, visitTypeCounts, totalVisitsToday, error, onRunAction, onOpen, onOpenBiometry, onOpenMedicalFitness }) {
  const inConsultation = active.find((e) => e.status === 'In Consultation');
  const waitingCount = active.filter((e) => e.status === 'Waiting' || e.status === 'Ready for Review').length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Consultation</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{inConsultation ? 1 : 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>With doctor now</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting for Doctor</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>In doctor queue</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Intermediate</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{intermediate.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Dilation / Investigation</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Completed Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{completed.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Encounters closed</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-head">
            <div className="card-title" style={{ color: 'var(--blue)' }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue<span className="badge b-gray">{active.length}</span></div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => onRunAction(doctorCallNext)} disabled={!!inConsultation}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {inConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={inConsultation.token} color="var(--blue)" />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(inConsultation)}</span>
                <VisitTypeBadge type={inConsultation.visits?.visit_type} />
              </div>
              <div style={{ marginBottom: 8 }}>
                <span className={`badge ${waitBadgeClass(elapsedMin(inConsultation.called_at || inConsultation.issued_at))}`}>
                  <i className="ti ti-clock"></i> In consultation {elapsedMin(inConsultation.called_at || inConsultation.issued_at)}m
                </span>
              </div>
              <button className="btn btn-primary btn-sm" onClick={() => onOpen(inConsultation)}>
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </button>
            </div>
          )}

          {active.filter((e) => e.id !== inConsultation?.id).map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} color={e.status === 'Ready for Review' ? 'var(--green)' : 'var(--amber)'} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                  <VisitTypeBadge type={e.visits?.visit_type} />
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Ready for Review' ? 'b-green' : 'b-amber'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}><i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallSpecific, e.id)} disabled={!!inConsultation}>Call</button>
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* INTERMEDIATE QUEUE -- side by side with Doctor Queue, not
            buried further down, since it's just as time-sensitive
            (patients sent out for Dilation/Investigation/Biometry who
            need to be pulled back in). */}
        <div className="card">
          <div className="card-head">
            <div className="card-title" style={{ color: 'var(--purple)' }}><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> Intermediate Queue<span className="badge b-gray">{intermediate.length}</span></div>
          </div>
          {intermediate.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.status} -- {elapsedMin(e.sent_out_at)}m</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorMarkReady, e.id)}>Mark Ready</button>
            </div>
          ))}
          {intermediate.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              No one in Dilation, Investigation, or Biometry.
            </div>
          )}
        </div>

        {/* COMPLETED TODAY -- moved in alongside Doctor Queue and
            Intermediate Queue (was buried in the lower grid) so all
            three time-sensitive lists sit in one row, equally sized. */}
        <div className="card">
          <div className="card-head">
            <div className="card-title" style={{ color: 'var(--green)' }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today<span className="badge b-green">{completed.length}</span></div>
          </div>
          {completed.slice(0, 8).map((e) => (
            <div
              key={e.id}
              onClick={() => onOpen(e)}
              style={{ display: 'block', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span><span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span> {patientName(e)}<VisitTypeBadge type={e.visits?.visit_type} /></span>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                {e.completed_at ? new Date(e.completed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' }) : '--'}
              </div>
            </div>
          ))}
          {completed.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing completed yet today.</div>}
        </div>
      </div>

      {/* Everything else -- side by side in pairs rather than one long
          vertical stack. */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* VISIT TYPE BREAKDOWN -- same widget as Front Office Dashboard */}
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
          </div>
          {Object.keys(visitTypeCounts || {}).length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
          )}
          {Object.entries(visitTypeCounts || {}).map(([type, count]) => (
            <div key={type} style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
              </div>
              <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                <div style={{
                  width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                  height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                }}></div>
              </div>
            </div>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Waiting in Optometry<span className="badge b-gray">{optometryWaiting.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Pull a patient straight into consultation without waiting for their optometry workup -- useful for quick reviews or referrals.
          </div>
          {optometryWaiting.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.issued_at)}m waiting in Optometry</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallDirect, e.id)} disabled={!!inConsultation}>
                <i className="ti ti-arrow-right"></i> Call Directly
              </button>
            </div>
          ))}
          {optometryWaiting.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No one currently waiting in Optometry.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-lens" style={{ color: 'var(--indigo)' }}></i> IOL Approvals<span className="badge b-gray">{biometryApprovals.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Only a doctor can approve. Opens IOL Approval.</div>
          {biometryApprovals.map((b) => (
            <div key={b.caseId} onClick={() => onOpenBiometry()} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {b.patient?.first_name} {b.patient?.last_name}
                <span className="badge b-indigo" style={{ marginLeft: 6, fontSize: 10 }}>{b.eye}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{b.patient?.uhid} -- {b.procedureName}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-lens"></i> Approve</button>
            </div>
          ))}
          {biometryApprovals.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing awaiting approval.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness<span className="badge b-gray">{medicalFitnessToday.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's referrals only.</div>
          {medicalFitnessToday.map((r) => (
            <div key={r.id} onClick={() => onOpenMedicalFitness(r.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {r.visits?.patients?.first_name} {r.visits?.patients?.last_name}
                <VisitTypeBadge type={r.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Review</button>
            </div>
          ))}
          {medicalFitnessToday.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending today.</div>}
        </div>
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.visits?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Consultation History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Token</th><th>Patient</th><th>Visit Type</th><th>Completed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e)} style={{ cursor: 'pointer' }}>
                <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{e.token}</td>
                <td>
                  <strong>{patientName(e)}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 11 }}>{e.visits?.visit_type || '--'}</td>
                <td style={{ fontSize: 11 }}>{e.completed_at ? new Date(e.completed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed consultations found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorDashboardPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState('dashboard');
  const [postOpEpisodeId, setPostOpEpisodeId] = useState(null);
  const [medFitnessId, setMedFitnessId] = useState(null);
  const [active, setActive] = useState([]);
  const [intermediate, setIntermediate] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [optometryWaiting, setOptometryWaiting] = useState([]);
  const [biometryApprovals, setBiometryApprovals] = useState([]);
  const [medicalFitnessToday, setMedicalFitnessToday] = useState([]);
  const [visitTypeCounts, setVisitTypeCounts] = useState({});
  const [totalVisitsToday, setTotalVisitsToday] = useState(0);
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const [result, biometryApprovals, medicalFitness] = await Promise.all([
      getDoctorDashboardData(),
      getPendingIolApprovals(),
      getMedicalFitnessToday(),
    ]);
    setActive(result.active);
    setIntermediate(result.intermediate);
    setCompleted(result.completed);
    setOptometryWaiting(result.optometryWaiting);
    setVisitTypeCounts(result.visitTypeCounts);
    setTotalVisitsToday(result.totalVisitsToday);
    setBiometryApprovals(biometryApprovals);
    setMedicalFitnessToday(medicalFitness);
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistory(await getDoctorHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => {
    refresh();
    refreshHistory();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh, refreshHistory]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  async function openConsultation(entry) {
    if (entry.visits?.visit_type === 'Post-operative Review') {
      const episodeId = await getOpenPostOpEpisodeForPatient(entry.visits.patients.id);
      if (!episodeId) {
        setError('This is marked as a Post-operative Review visit, but no open post-op episode was found for this patient.');
        return;
      }
      setPostOpEpisodeId(episodeId);
      setMedFitnessId(null);
      setActiveTab('workspace');
      return;
    }
    // Opens in its own window, which closes itself once the doctor
    // finishes this sitting (Save Draft / Send for Dilation / Send for
    // Investigation / Complete Encounter) -- see finishAndClose() in
    // consultation-form.js. Reuses the same window name so repeated
    // "Call" clicks don't spawn a pile of windows. Polls for the window
    // closing so the dashboard refreshes immediately rather than
    // waiting on the 15s interval.
    const win = window.open(`/consultation/${entry.id}`, 'doctor-consultation-window');
    if (win) {
      const poll = setInterval(() => {
        if (win.closed) { clearInterval(poll); refresh(); }
      }, 800);
    }
  }

  function openBiometry() {
    router.push('/iol-approval');
  }

  function openMedicalFitness(id) {
    setPostOpEpisodeId(null); setBiometryId(null);
    setMedFitnessId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh(); refreshHistory();
    setPostOpEpisodeId(null);
    setMedFitnessId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      {activeTab !== 'workspace' && (
        <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-text" label="Workspace" disabled={!postOpEpisodeId && !medFitnessId} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
      )}

      {activeTab === 'dashboard' && (
        <DashboardTab
          active={active} intermediate={intermediate} completed={completed} optometryWaiting={optometryWaiting}
          biometryApprovals={biometryApprovals} medicalFitnessToday={medicalFitnessToday}
          visitTypeCounts={visitTypeCounts} totalVisitsToday={totalVisitsToday}
          error={error} onRunAction={runAction} onOpen={openConsultation}
          onOpenBiometry={openBiometry} onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'workspace' && postOpEpisodeId && (
        <PostOpWorkspace episodeId={postOpEpisodeId} onBack={handleBack} onUpdate={() => {}} />
      )}
      {activeTab === 'workspace' && medFitnessId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <MedicalFitnessWorkspace referralId={medFitnessId} onDone={handleBack} />
        </div>
      )}
      {activeTab === 'workspace' && !postOpEpisodeId && !medFitnessId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard or History.</div>
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openConsultation} />}
    </div>
  );
}

FILEEOF_doctor_dashboard_page_js

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

// Patients who said they'd come back another day and haven't yet
// (proceed_status stays 'Awaiting Return' until someone either moves
// them to Proceeding or the case is cancelled). Ordered oldest-first so
// the ones most overdue for a follow-up call surface at the top.
export async function getAwaitingReturnCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile)')
    .eq('proceed_status', 'Awaiting Return')
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
  getSurgicalCaseDetail, orderBiometryForCase, setPreOpPanelNotes,
  setProceedStatus, setIolOrderNotes, editSurgicalCaseDetails,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, getPackagesForCase,
  setDecision, referForMedicalFitness, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
} from '@/app/(main)/counselling/actions';
import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];
const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

// ── HEADER (editable) ──────────────────────────────────────────────
function CaseHeader({ sc, patient, onAction }) {
  const [editing, setEditing] = useState(false);
  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState(sc.procedure_name);
  const [eye, setEye] = useState(sc.eye || 'OD');
  const [reason, setReason] = useState('');
  const progressed = sc.status !== 'Pending Workup';

  useEffect(() => { if (editing) getSurgeries().then(setSurgeries); }, [editing]);

  function startEdit() {
    setProcedureName(sc.procedure_name); setEye(sc.eye || 'OD'); setReason(''); setEditing(true);
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
    investigations: data.biometryRecords.length > 0,
    proceeding: sc.proceed_status === 'Proceeding',
    package: !!sc.package_id && sc.decision === 'Accepted',
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

      {/* 1. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} onAction={flash} active={currentStep === 'investigations'} />

      {/* 2. PROCEED STATUS */}
      <ProceedSection sc={sc} onAction={flash} active={currentStep === 'proceeding'} />

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

      {/* 8. REPORTS */}
      <Section num={8} color="var(--blue)" title="Reports (Biometry printout, blood work, etc.)" done={false}>
        <AttachmentUploader entityType="surgical_case" entityId={sc.id} title="" />
      </Section>

      {/* 9. DAY OF SURGERY */}
      <DayOfSurgerySection sc={sc} otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'dayof'} num={9} />

      {/* 10. NOTES / FOLLOW-UP */}
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

// ── 1. INVESTIGATIONS ──────────────────────────────────────────────
function InvestigationsSection({ sc, biometryRecords, onAction, active }) {
  const [instructions, setInstructions] = useState('');
  const [panelNotes, setPanelNotes] = useState(sc.notes || '');
  const biometryOrdered = biometryRecords.length > 0;

  return (
    <Section num={1} color="var(--purple)" title="Investigations (Biometry + Pre-Op Panel)" done={biometryOrdered} defaultOpen={!biometryOrdered} active={active}>
      <div style={{ marginBottom: 14 }}>
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

      <div>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Pre-Op Panel (blood work, done externally -- just note where, report comes in later)</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Sent to XYZ Lab for CBC/RBS/ECG"' value={panelNotes} onChange={(e) => setPanelNotes(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setPreOpPanelNotes)(sc.id, panelNotes)}>Save</button>
        </div>
      </div>
    </Section>
  );
}

// ── 2. PROCEED STATUS ──────────────────────────────────────────────
function ProceedSection({ sc, onAction, active }) {
  const OPTIONS = [
    { v: 'Deciding', label: 'Still deciding', color: 'var(--g500)' },
    { v: 'Awaiting Return', label: 'Will come back another day', color: 'var(--amber)' },
    { v: 'Proceeding', label: 'Proceeding now', color: 'var(--green)' },
  ];
  return (
    <Section num={2} color="var(--amber)" title="Is the patient proceeding?" done={sc.proceed_status === 'Proceeding'} active={active}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        {OPTIONS.map((o) => (
          <button
            key={o.v}
            className="btn btn-sm"
            style={{ background: sc.proceed_status === o.v ? o.color : '', color: sc.proceed_status === o.v ? '#fff' : '', border: sc.proceed_status === o.v ? 'none' : undefined }}
            onClick={() => onAction(setProceedStatus)(sc.id, o.v)}
          >
            {o.label}
          </button>
        ))}
      </div>
    </Section>
  );
}

// ── 3. PACKAGE & IOL DECISION ──────────────────────────────────────
function PackageDecisionSection({ sc, onAction, active }) {
  const [packages, setPackages] = useState([]);
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [decisionReason, setDecisionReason] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changing, setChanging] = useState(false);
  const biometryReady = sc.biometry_done || sc.biometry_required === false;

  useEffect(() => {
    if (biometryReady) getPackagesForCase(sc.iol_category).then(setPackages);
  }, [biometryReady, sc.iol_category]);

  if (!biometryReady) {
    return (
      <Section num={3} color="var(--indigo)" title="Package &amp; IOL Decision" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Biometry approval first.</div>
      </Section>
    );
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package &amp; IOL Decision" done={!!sc.package_id && sc.decision === 'Accepted'} defaultOpen={biometryReady && !sc.package_id} active={active}>
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

      <div>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Patient Decision</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
          {DECISIONS.map((d) => (
            <button
              key={d} className="btn btn-sm"
              style={{ background: sc.decision === d ? 'var(--indigo)' : '', color: sc.decision === d ? '#fff' : '' }}
              onClick={() => onAction(setDecision)(sc.id, d, decisionReason)}
            >
              {d}
            </button>
          ))}
        </div>
        {sc.decision_locked && <input className="fi fi-sm" placeholder="Reason to change decision..." value={decisionReason} onChange={(e) => setDecisionReason(e.target.value)} />}
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
    <Section num={10} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
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

mkdir -p "app/(main)/consultation"
cat > "app/(main)/consultation/actions.js" << 'FILEEOF_consultation_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';
import { isCurrentUserAdmin } from '@/lib/authz';

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let encounter;
  if (entry.status === 'Done') {
    // Most recent encounter for this visit, any status -- not combining
    // .limit() with .maybeSingle() here, since that pairing isn't used
    // anywhere else in this codebase (getOrCreateBiometryRecord uses the
    // same array + length check instead for exactly this kind of lookup).
    const { data: encounters, error: encListError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .order('started_at', { ascending: false })
      .limit(1);
    if (encListError) return { error: encListError.message };
    encounter = encounters && encounters.length > 0 ? encounters[0] : null;
  } else {
    const { data: activeEncounter, error: encActiveError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .eq('status', 'In Consultation')
      .maybeSingle();
    if (encActiveError) return { error: encActiveError.message };
    encounter = activeEncounter;
  }

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    // For a completed (Done) queue entry there's nothing to auto-create --
    // if no encounter exists, the visit genuinely has no clinical record.
    // Auto-creating only makes sense for an active/new consultation.
    if (entry.status === 'Done') {
      return { error: 'No clinical record found for this completed visit.' };
    }
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await addAudit(supabase, encounter.id, 'Encounter started', userData?.user?.id);
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const patientId = entry.visits.patients.id;

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // encounter_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw }, { data: biometryRecords }, { data: surgicalCases },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('workflow_requests').select('*').eq('visit_id', visitId).order('requested_at', { ascending: false }),
    supabase.from('encounter_audit_log').select('*').eq('encounter_id', encounter.id).order('created_at', { ascending: false }),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounter.id).maybeSingle(),
    // Longitudinal (cross-visit) diagnosis history: every diagnosis this
    // patient has, across all their encounters, via visits -> encounters.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, status, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    // Biometry gets its own dedicated section in Diagnosis & Plan (not
    // folded into Investigations) -- same reasoning as its own
    // Financial Masters department: it's structurally its own thing.
    supabase.from('biometry_records').select('id, status, doctor_instructions, billing_status').eq('patient_id', patientId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
    // So "Mark for Surgery" can show what's already been marked instead
    // of silently reverting to a blank button after saving. Scoped by
    // visit_id (one visit, one surgical case), not just this encounter,
    // since a visit can span more than one encounter.
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  // Follow-up Template: same consultation engine, just extra context --
  // a patient is a "follow-up" the moment they have any prior encounter
  // at all, on a different visit, regardless of whether that encounter
  // was ever formally completed (an abandoned/in-progress note still
  // means this isn't their first time being seen).
  const priorEncounters = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorCompletedEncounters = priorEncounters.filter((e) => e.status === 'Completed');
  const isFollowUp = priorEncounters.length > 0;

  if (isFollowUp && encounter.encounter_type !== 'Follow-up') {
    await supabase.from('encounters').update({ encounter_type: 'Follow-up' }).eq('id', encounter.id);
    encounter.encounter_type = 'Follow-up';
  }

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: isAdmin ? (auditLog || []) : [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
    biometryRecords: biometryRecords || [],
    surgicalCases: surgicalCases || [],
    isLocked: encounter.status === 'Completed',
    isFollowUp, priorEncounterId: priorCompletedEncounters[0]?.id || null,
    isAdmin,
  };
}

// ── FOLLOW-UP TEMPLATE CONTEXT ──
// Everything the Follow-up template needs beyond what getConsultationData
// already returns: the visit timeline, patient snapshot, and a summary
// of the immediately preceding visit. Only called when isFollowUp is true.
export async function getFollowUpContext(patientId, currentVisitId, currentEncounterId) {
  const supabase = await createClient();

  const { data: visitsRaw } = await supabase
    .from('visits')
    .select('id, visit_number, encounters(id, started_at, completed_at, chief_complaint, status)')
    .eq('patient_id', patientId);

  const allPriorEncounters = (visitsRaw || [])
    .flatMap((v) => (v.encounters || []).map((e) => ({ ...e, visitId: v.id, visitNumber: v.visit_number })))
    .filter((e) => e.id !== currentEncounterId)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorEncounters = allPriorEncounters.filter((e) => e.status === 'Completed');

  // Map each prior visit back to its Doctor queue entry, so the
  // timeline can open it read-only -- same lookup pattern Patient
  // Timeline already uses.
  const priorVisitIds = [...new Set(allPriorEncounters.map((e) => e.visitId))];
  let queueEntryByVisit = {};
  if (priorVisitIds.length > 0) {
    const { data: entries } = await supabase.from('queue_entries').select('id, visit_id').in('visit_id', priorVisitIds).eq('department', 'Doctor');
    (entries || []).forEach((e) => { queueEntryByVisit[e.visit_id] = e.id; });
  }

  // Timeline shows every prior visit, including ones that were never
  // finalized -- still useful context, just labeled as such.
  const timeline = allPriorEncounters.slice(0, 15).map((e) => ({
    encounterId: e.id, date: e.started_at, chiefComplaint: e.chief_complaint,
    status: e.status, queueEntryId: queueEntryByVisit[e.visitId] || null,
  }));

  const lastEncounter = priorEncounters[0] || null;
  let snapshot = {
    lastVisitDate: lastEncounter?.started_at || null,
    currentDiagnoses: [], currentMedications: [], allergy: null,
    lastVision: null, lastIop: null, surgicalStatus: null,
    previousVisitSummary: null,
    noCompletedPriorVisit: !lastEncounter,
  };
  let newInvestigations = [];

  if (lastEncounter) {
    // Investigations ordered (anywhere -- Counselling, a walk-in
    // Investigation visit, etc.) since the last consultation, with
    // results ready -- these are easy to miss since they don't
    // necessarily belong to *this* encounter's own Investigations list.
    const allEncounterIds = (visitsRaw || []).flatMap((v) => (v.encounters || []).map((e) => e.id));
    if (allEncounterIds.length > 0) {
      const { data: recentInv } = await supabase
        .from('investigation_orders')
        .select('*')
        .in('encounter_id', allEncounterIds)
        .neq('encounter_id', currentEncounterId)
        .eq('status', 'Available')
        .gt('created_at', lastEncounter.started_at)
        .order('created_at', { ascending: false });
      newInvestigations = recentInv || [];
    }
    const [{ data: fullEncounter }, { data: diagnoses }, { data: medications }, { data: assessment }, { data: advice }, { data: fu }] = await Promise.all([
      supabase.from('encounters').select('hx_drug_allergy').eq('id', lastEncounter.id).maybeSingle(),
      supabase.from('diagnoses').select('*').eq('encounter_id', lastEncounter.id).eq('status', 'Active').order('created_at'),
      supabase.from('prescriptions').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('optometry_assessments').select('*').eq('visit_id', lastEncounter.visitId).eq('status', 'Completed').maybeSingle(),
      supabase.from('plan_optical_advice').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('plan_followups').select('*').eq('encounter_id', lastEncounter.id).maybeSingle(),
    ]);

    let lastIop = null;
    if (assessment) {
      const { data: iopReadings } = await supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: false }).limit(1);
      lastIop = iopReadings?.[0] || null;
    }

    const { data: recentSurgicalCase } = await supabase
      .from('surgical_cases').select('procedure_name, eye, status')
      .eq('patient_id', patientId).neq('status', 'Cancelled')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();

    snapshot = {
      lastVisitDate: lastEncounter.started_at,
      currentDiagnoses: diagnoses || [],
      currentMedications: medications || [],
      allergy: fullEncounter?.hx_drug_allergy || null,
      lastVision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
      lastIop,
      surgicalStatus: recentSurgicalCase || null,
      previousVisitSummary: {
        date: lastEncounter.started_at,
        diagnoses: diagnoses || [],
        medications: medications || [],
        advice: advice || [],
        followupPlan: fu || null,
        vision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
        iop: lastIop,
      },
    };
  }

  return { timeline, snapshot, newInvestigations };
}

// ── VISIT OUTCOME ──
export async function saveVisitOutcome(encounterId, outcome) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ visit_outcome: outcome }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CARRY FORWARD a prior diagnosis into the current encounter ──
export async function carryForwardDiagnosis(encounterId, diagnosis) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId, name: diagnosis.name, category: diagnosis.category, eye: diagnosis.eye, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}
export async function saveExamination(examinationId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Examination saved', userData?.user?.id);
  return { success: true };
}

// ── STRUCTURED HISTORY (Section 11.9) ──
// Batched save, same pattern as Examination -- not per-keystroke.
export async function saveHistory(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({
      chief_complaint: fields.chiefComplaint,
      chief_complaint_chips: fields.chiefComplaintChips,
      hx_duration: fields.hxDuration,
      hx_laterality: fields.hxLaterality,
      hx_hopi: fields.hxHopi,
      ocular_history: fields.ocularHistory,
      medical_history: fields.medicalHistory,
      family_history: fields.familyHistory,
      drug_history: fields.drugHistory,
      allergy: fields.allergy,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DOCTOR EDITS OPTOMETRY FINDINGS DIRECTLY (in-place override) ──
// The doctor edits the optometrist's own assessment record. Every
// changed field is written to that assessment's audit log (the same
// log the optometrist sees in Optometry History) as a before/after
// entry, so the optometrist can see exactly what was changed and by
// whom -- without a separate shadow record.
const OPTOM_FIELD_LABELS = {
  va_scale: 'VA Scale',
  re_dist_unaided: 'RE Dist Unaided', re_dist_glasses: 'RE Dist Glasses', re_dist_ph: 'RE Dist Pinhole', re_near_unaided: 'RE Near Unaided',
  le_dist_unaided: 'LE Dist Unaided', le_dist_glasses: 'LE Dist Glasses', le_dist_ph: 'LE Dist Pinhole', le_near_unaided: 'LE Near Unaided',
  ref_pd: 'PD', ref_vd: 'VD',
  ref_obj_re_sph: 'RE Obj Sph', ref_obj_re_cyl: 'RE Obj Cyl', ref_obj_re_axis: 'RE Obj Axis',
  ref_obj_le_sph: 'LE Obj Sph', ref_obj_le_cyl: 'LE Obj Cyl', ref_obj_le_axis: 'LE Obj Axis',
  ref_subj_re_sph: 'RE Subj Sph', ref_subj_re_cyl: 'RE Subj Cyl', ref_subj_re_axis: 'RE Subj Axis',
  ref_subj_le_sph: 'LE Subj Sph', ref_subj_le_cyl: 'LE Subj Cyl', ref_subj_le_axis: 'LE Subj Axis',
  ref_final_re_sph: 'RE Final Sph', ref_final_re_cyl: 'RE Final Cyl', ref_final_re_axis: 'RE Final Axis', ref_final_re_add: 'RE Final Add',
  ref_final_le_sph: 'LE Final Sph', ref_final_le_cyl: 'LE Final Cyl', ref_final_le_axis: 'LE Final Axis', ref_final_le_add: 'LE Final Add',
  iop_method: 'IOP Method', iop_time: 'IOP Time',
  add_k1: 'Keratometry K1', add_k2: 'Keratometry K2', add_axial_length: 'Axial Length', add_pachymetry: 'Pachymetry',
  add_white_to_white: 'White-to-White', add_schirmer: 'Schirmer', add_color_vision: 'Color Vision',
  add_ocular_motility: 'Ocular Motility', add_syringing: 'Syringing',
  observation_chips: 'Observation Tags', observations_text: 'Observations',
};

export async function updateOptometryFindings(assessmentId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: current, error: fetchError } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('id', assessmentId)
    .single();
  if (fetchError) return { error: fetchError.message };

  const changes = [];
  const updatePayload = {};
  Object.keys(OPTOM_FIELD_LABELS).forEach((key) => {
    if (fields[key] === undefined) return;
    const oldVal = current[key];
    const newVal = fields[key];
    const oldStr = Array.isArray(oldVal) ? oldVal.join(', ') : (oldVal ?? '');
    const newStr = Array.isArray(newVal) ? newVal.join(', ') : (newVal ?? '');
    if (oldStr === newStr) return;
    updatePayload[key] = newVal;
    changes.push({ label: OPTOM_FIELD_LABELS[key], oldStr: oldStr || '--', newStr: newStr || '--' });
  });

  if (changes.length === 0) return { success: true, changedCount: 0 };

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...updatePayload, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  for (const c of changes) {
    await supabase.from('optometry_audit_log').insert({
      assessment_id: assessmentId,
      message: `Doctor override -- ${c.label}: "${c.oldStr}" -> "${c.newStr}"`,
      created_by: doctorId,
    });
  }

  if (encounterId) {
    await addAudit(supabase, encounterId, `Optometry findings overridden -- ${changes.length} field(s) changed`, doctorId);
  }

  return { success: true, changedCount: changes.length };
}

// Lets the doctor start an optometry assessment directly when the
// patient never went through Optometry -- same table, just created and
// initially owned from the consultation side instead of the queue.
export async function createOptometryAssessmentForVisit(visitId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .insert({ visit_id: visitId, recorded_by: doctorId, completed_by: doctorId, status: 'Completed', completed_at: new Date().toISOString() })
    .select()
    .single();
  if (error) return { error: error.message };

  await supabase.from('optometry_audit_log').insert({ assessment_id: assessment.id, message: 'Assessment started by Doctor -- no prior Optometry visit', created_by: doctorId });
  if (encounterId) await addAudit(supabase, encounterId, 'Optometry assessment created directly by doctor', doctorId);

  return { assessment };
}


// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye}, ${values.category})`, userData?.user?.id);
  return { success: true };
}

export async function removeDiagnosis(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Diagnosis removed', userData?.user?.id);
  return { success: true };
}

export async function updateDiagnosisNotes(id, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').update({ notes: notes?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Prescription added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

// Tapering schedule -- same drug and dosage-per-administration across
// steps (that's how tapering actually works clinically: the amount per
// dose stays the same, e.g. 1 drop, only the frequency reduces over
// time), each step a separate row sharing one taper_group_id so they
// render and print as a single continuous instruction, not N unrelated
// prescriptions.
export async function addTaperedPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: s.frequency,
    duration: s.duration,
    eye: values.eye,
    taper_group_id: taperGroupId,
    taper_step: i + 1,
  }));

  const { error } = await supabase.from('prescriptions').insert(rows);
  if (error) return { error: error.message };
  const summary = steps.map((s) => `${s.frequency} x${s.duration}`).join(' -> ');
  await addAudit(supabase, encounterId, `Tapering schedule added: ${values.drugName} (${values.eye}) -- ${summary}`, userData?.user?.id);
  return { success: true };
}

export async function removeTaperGroup(taperGroupId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: rows } = await supabase.from('prescriptions').select('drug_name, eye').eq('taper_group_id', taperGroupId).limit(1);
  const { error } = await supabase.from('prescriptions').delete().eq('taper_group_id', taperGroupId);
  if (error) return { error: error.message };
  if (rows?.[0]) await addAudit(supabase, encounterId, `Tapering schedule removed: ${rows[0].drug_name} (${rows[0].eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePrescription(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Prescription removed', userData?.user?.id);
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Investigation ordered: ${values.name} (${values.eye}, ${values.priority})`, userData?.user?.id);
  return { success: true };
}

export async function removeInvestigation(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Investigation removed', userData?.user?.id);
  return { success: true };
}

// ── WORKFLOW REQUESTS (Biometry / Medical Fitness / Counselling) ──
// Independent, non-exclusive toggles -- a visit can have more than one
// open at a time, unlike Dilation/Investigation which move the queue
// entry itself. Toggling an already-open request cancels it.
export async function toggleWorkflowRequest(visitId, encounterId, kind) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: existing } = await supabase
    .from('workflow_requests')
    .select('*')
    .eq('visit_id', visitId)
    .eq('kind', kind)
    .eq('status', 'Requested')
    .maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('workflow_requests')
      .update({ status: 'Cancelled', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
      .eq('id', existing.id);
    if (error) return { error: error.message };
    await addAudit(supabase, encounterId, `Workflow request cancelled: ${kind}`, userData?.user?.id);
    return { success: true, active: false };
  }

  const { error } = await supabase.from('workflow_requests').insert({
    visit_id: visitId, encounter_id: encounterId, kind, requested_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Workflow requested: ${kind}`, userData?.user?.id);
  return { success: true, active: true };
}

// Mark a workflow request (Biometry/Fitness/Counselling) as done --
// used by whichever staff member actually completes it (e.g. the
// counsellor marking a Counselling request resolved).
export async function completeWorkflowRequest(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('workflow_requests')
    .update({ status: 'Completed', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
    .eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Workflow request marked complete', userData?.user?.id);
  return { success: true };
}

// ── MANAGEMENT PLAN EXPANSION (Ch.14) ──
export async function addOpticalAdvice(encounterId, advice) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_optical_advice').insert({ encounter_id: encounterId, advice, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Optical advice added: ${advice}`, userData?.user?.id);
  return { success: true };
}

export async function removeOpticalAdvice(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_optical_advice').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Optical advice removed', null);
  return { success: true };
}

export async function addProcedure(encounterId, name, eye, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, notes: notes || null, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Minor Procedure planned: ${name} (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function removeProcedure(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_procedures').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Procedure removed', null);
  return { success: true };
}

export async function addReferral(encounterId, destination, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_referrals').insert({ encounter_id: encounterId, destination, reason, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Referral added: ${destination}`, userData?.user?.id);
  return { success: true };
}

export async function removeReferral(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_referrals').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Referral removed', null);
  return { success: true };
}

export async function addCounsellingItem(encounterId, topic) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_counselling_items').insert({ encounter_id: encounterId, topic, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Counselling topic added: ${topic}`, userData?.user?.id);
  return { success: true };
}

export async function removeCounsellingItem(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Counselling topic removed', null);
  return { success: true };
}

// Any plan item (optical/procedure/referral/counselling) marked done --
// used from the Action Tracker tab.
export async function completePlanItem(table, id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ status: 'Done' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Plan item marked done', null);
  return { success: true };
}

// Follow-up is one record per encounter -- upsert by encounter_id.
export async function saveFollowup(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_followups')
    .upsert(
      { encounter_id: encounterId, after_period: fields.after, visit_type: fields.type, clinic: fields.clinic, instructions: fields.instructions, created_by: userData?.user?.id || null },
      { onConflict: 'encounter_id' }
    );
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Follow-up scheduled: ${fields.after} -- ${fields.type}`, userData?.user?.id);
  return { success: true };
}

export async function savePatientInstructions(encounterId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ patient_instructions: instructions }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Encounter completed', userData?.user?.id);

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'dilate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Dilation', userData?.user?.id);
  return result;
}

export async function sendForInvestigationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'investigate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Investigation', userData?.user?.id);
  return result;
}

// Minor Procedures are performed by the doctor directly, in the same
// sitting -- unlike Dilation/Investigation/Biometry there's no separate
// department to route the patient to, so this just confirms the
// procedure(s) for the audit trail. Billing already picks them up the
// moment they're added (billing_status defaults to 'Pending'); this
// doesn't change that.
export async function sendForProcedureFromConsultation(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Sent for Procedure', userData?.user?.id);
  return { success: true };
}

// Shared by both the "Add" button (advises Biometry without moving the
// patient anywhere yet) and "Send for Biometry" (which also routes the
// queue) -- creates the record if none exists yet for that eye, or
// Biometry is patient-level now, not visit/case-level, and always
// covers both eyes -- one session is reused across every future
// surgical case for that patient (readings don't meaningfully change
// for years). "Advise" just ensures a record exists for this patient,
// updating instructions if one already does.
async function ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: created } = await supabase.from('biometry_records').insert({
      patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null,
      doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// The "Add" step -- advises Biometry is needed (records instructions,
// if any) without moving the patient's queue position at all. Mirrors
// exactly how Investigations work: "Add" saves the order, "Send for
// Investigation" is a separate, later action that routes the patient.
export async function adviseBiometry(patientId, visitId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions);
  await addAudit(supabase, encounterId, 'Biometry advised', userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, patientId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, 'Sent for Biometry', userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  await ensureBiometryRecord(supabase, patientId, entry?.visit_id || null, encounterId, instructions);

  return result;
}

// For updating instructions on a biometry record that's already been
// sent -- eye is fixed once a record exists (changing it would mean a
// different physical record, not editing this one), but instructions
// can still be corrected/added at any point before the technician
// finishes.
// Doctor can remove a mistakenly-added/sent biometry request (wrong
// eye, duplicate, etc.) -- but only while it's still unbilled. Once
// Front Office has billed it, removing the record here would leave an
// invoice line with nothing behind it, so that has to go through
// billing's own modification flow instead.
export async function removeBiometryRecord(id, encounterId) {
  const supabase = await createClient();
  const { data: record } = await supabase.from('biometry_records').select('billing_status').eq('id', id).maybeSingle();
  if (!record) return { error: 'Record not found.' };
  if (record.billing_status === 'Billed') {
    return { error: 'This has already been billed and cannot be removed here -- use Billing to modify the invoice first.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('biometry_records').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Biometry request removed', userData?.user?.id);
  return { success: true };
}

export async function updateBiometryInstructions(id, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_records').update({ doctor_instructions: instructions?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function saveDraft(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Consultation saved as draft', userData?.user?.id);
  return { success: true };
}

FILEEOF_consultation_actions_js

mkdir -p "app/consultation/[id]"
cat > "app/consultation/[id]/consultation-form.js" << 'FILEEOF_consultation_form_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addTaperedPrescription,
  removeTaperGroup,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  sendForBiometryFromConsultation,
  adviseBiometry,
  updateBiometryInstructions,
  removeBiometryRecord,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  sendForProcedureFromConsultation,
  addReferral,
  removeReferral,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
  saveDraft,
  getFollowUpContext,
  saveVisitOutcome,
  carryForwardDiagnosis,
} from '@/app/(main)/consultation/actions';
import { openPopup } from '@/lib/popup';
import { markForSurgery, updateSurgicalCase } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getDosageOptions, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import OptometryWorkspace from '@/app/(main)/optometry/[id]/optometry-workspace';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';
import { openPrintPopup } from '@/lib/printPopup';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

function DiagnosisRow({ d, index, encounterId, onRemove }) {
  const [notes, setNotes] = useState(d.notes || '');
  const [saved, setSaved] = useState(true);

  async function handleBlur() {
    if (notes === (d.notes || '')) return;
    await updateDiagnosisNotes(d.id, notes);
    setSaved(true);
  }

  return (
    <div style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
        <span>
          <span style={{ color: 'var(--g400)', fontWeight: 700, marginRight: 4 }}>{index + 1}.</span>
          <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
        </span>
        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={onRemove}>Remove</button>
      </div>
      <input
        className="fi fi-sm"
        style={{ marginTop: 5, marginLeft: 18, width: 'calc(100% - 18px)' }}
        placeholder="Doctor notes for this diagnosis (optional)"
        value={notes}
        onChange={(e) => { setNotes(e.target.value); setSaved(false); }}
        onBlur={handleBlur}
      />
      {!saved && <div style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 18, marginTop: 2 }}>Unsaved -- click away to save</div>}
    </div>
  );
}

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// Section group divider for Diagnosis & Plan -- numbered circle badge,
// same visual language as the numbered sections in Optometry Assessment,
// so the two clinical screens feel consistent.
function GroupHeader({ num, color, title }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '4px 0 12px' }}>
      <span style={{ width: 24, height: 24, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>{num}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)' }}>{title}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--g200)' }}></div>
    </div>
  );
}

export default function ConsultationForm({ queueEntryId, hideHistoryTracker = false, onBack, backLabel = 'Dashboard' }) {
  const [data, setData] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [visitOutcome, setVisitOutcome] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('optometry');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week' },
    { frequency: 'TDS', duration: '1 week' },
    { frequency: 'BD', duration: '1 week' },
    { frequency: 'OD', duration: '1 week' },
  ]);
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const invPriority = 'Routine'; // selector removed -- no longer needed
  const [bioInstructions, setBioInstructions] = useState('');
  const [editingBioId, setEditingBioId] = useState(null);
  const [editBioInstructions, setEditBioInstructions] = useState('');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [procNotes, setProcNotes] = useState('');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  // Master Data options for the Diagnosis/Prescription/Investigation
  // dropdowns -- fetched once on mount, not re-fetched on every add/remove.
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);
  const [rxDrugTypeId, setRxDrugTypeId] = useState(null);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg, dg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      setDosageOptions(dg);
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && !s.name.toLowerCase().includes('biometry')));
      setProcedureOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Minor Procedure'));
      setSurgeryOptions(sg.filter((s) => s.status === 'Active'));
    })();
  }, []);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    setVisitOutcome(data.encounter.visit_outcome || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
    if (data.biometryRecords && data.biometryRecords.length > 0) {
      const first = data.biometryRecords[0];
      setBioInstructions(first.doctor_instructions || '');
    }
  }, [data]);

  async function handleAdviseBiometry() {
    setError('');
    const result = await adviseBiometry(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id, bioInstructions);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  function startEditBioInstructions(record) {
    setEditingBioId(record.id);
    setEditBioInstructions(record.doctor_instructions || '');
  }

  async function saveBioInstructions(id) {
    await updateBiometryInstructions(id, editBioInstructions);
    setEditingBioId(null);
    refresh();
  }

  async function handleRemoveBiometry(id) {
    setError('');
    const result = await removeBiometryRecord(id, data.encounter.id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVisitOutcomeChange(outcome) {
    setVisitOutcome(outcome);
    await saveVisitOutcome(data.encounter.id, outcome);
  }

  async function handleCarryForward(priorDiagnosis) {
    setError('');
    const result = await carryForwardDiagnosis(data.encounter.id, priorDiagnosis);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  // Type-ahead for the Prescription drug field -- matches on brand or
  // generic name, case-insensitive substring, capped to keep the list
  // scannable. Falls back to free-text (rxDrug itself) when nothing
  // matches, or to the full Browse dropdown if the doctor wants to look
  // rather than type.
  const rxSuggestions = rxDrug.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(rxDrug.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(rxDrug.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectRxDrug(d) {
    setRxDrug(d.brand);
    setRxDrugTypeId(d.drug_type_id || null);
    setRxDosage('');
    setShowRxSuggestions(false);
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
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    if (!rxDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxEye, steps: taperSteps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setShowTaperBuilder(false);
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName) { setError('Select a procedure.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye, procNotes);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    setProcNotes('');
    refresh();
  }

  async function handleSendForProcedure() {
    setError('');
    setLoading(true);
    const result = await sendForProcedureFromConsultation(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  // This page is meant to be opened in its own window (see doctor-dashboard's
  // "Call"/"Call Next" and ot-postop's "Start Review"), closing itself the
  // moment the doctor is done with this sitting -- window.close() only
  // works on script-opened windows, so this quietly falls back to
  // navigating back to the queue if it was opened by direct navigation
  // instead (e.g. a bookmark or typed URL).
  function finishAndClose() {
    window.close();
    router.push('/queue');
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  // Escape hatch for a visit that genuinely can't go through the normal
  // completion path -- patient left before being seen, token called but
  // nobody responded, etc. Doesn't touch the diagnosis requirement for
  // any other visit; just closes this one with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a diagnosis.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp, surgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryNotes('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
    setEditSurgeryNotes(sc.notes || '');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp, editSurgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : kind === 'biometry'
      ? await sendForBiometryFromConsultation(queueEntryId, data.entry.visits.patients.id, data.encounter.id, bioInstructions)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    // Biometry stays on the page -- a doctor may still need to add
    // diagnoses, order investigations, etc. in the same sitting. Dilation
    // and Investigation keep the existing "done with this patient for
    // now" behavior since that wasn't something you flagged.
    if (kind === 'biometry') { refresh(); return; }
    finishAndClose();
  }

  async function handleSaveDraft() {
    setError('');
    setLoading(true);
    const result = await saveDraft(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  const isReadOnly = data.isLocked && !unlocked;
  // Already routed to the technician if the current queue status
  // mentions Biometry (including compound statuses like "Awaiting
  // Investigation & Biometry" -- see doctorSendOut).
  const bioSent = data.entry?.status?.includes('Biometry') || false;

  return (
    <div style={{ maxWidth: 1440, margin: '0 auto', padding: '20px 26px' }}>
      {/* STICKY HEADER + TABS -- frozen at the top of the scroll area so
          the patient's identity and which tab you're on never scroll out
          of view, no matter how long the tab's content gets. */}
      <div style={{ position: 'sticky', top: 0, zIndex: 20, background: 'var(--g50)', paddingBottom: 10, marginBottom: 6 }}>
        {onBack && (
          <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> {backLabel}
          </button>
        )}
        <div style={{
          background: 'linear-gradient(135deg, var(--blue-dk), var(--blue))', borderRadius: 'var(--r-lg)',
          padding: '14px 20px', color: '#fff', boxShadow: 'var(--shadow-md)', marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 16,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: '50%', background: 'rgba(255,255,255,.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800, flexShrink: 0,
            fontFamily: 'var(--font-display-stack)',
          }}>
            {patient.first_name?.charAt(0)?.toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
              {patient.first_name} {patient.last_name}
              {data.isFollowUp && <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontSize: 10.5 }}>Follow-up Visit</span>}
            </div>
            <div style={{ fontSize: 12, opacity: .85, marginTop: 2 }}>
              {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- Token {data.entry.token}
            </div>
          </div>
          <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.16)', borderRadius: 10, padding: '6px 16px', flexShrink: 0 }}>
            <div style={{ fontSize: 9.5, opacity: .8, textTransform: 'uppercase', letterSpacing: '.5px' }}>Duration</div>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'monospace' }}>{elapsedMin(data.encounter.started_at)}m</div>
          </div>
        </div>

        {/* TABS */}
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
          <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
          <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
          <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
          {!hideHistoryTracker && <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />}
        </div>
      </div>

      {data.isFollowUp && followUpContext && (
        <PatientSnapshotBar snapshot={followUpContext.snapshot} />
      )}

      {data.isLocked && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed consultation -- changes save immediately.'
              : 'This consultation is completed. Viewing read-only for reference.'}
          </span>
          <button className="btn btn-sm" onClick={() => setUnlocked((v) => !v)}>
            {unlocked ? 'Lock' : 'Unlock to Edit'}
          </button>
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        {/* CONTEXT SIDEBAR -- patient history (previous visit, timeline,
            investigations) plus this encounter's own status/tasks/audit
            log, all in one place so the main column has full width. */}
        <div>
          <ContextSidebar
            patientId={patient.id}
            previousVisitSummary={data.isFollowUp && followUpContext ? followUpContext.snapshot.previousVisitSummary : null}
            encounter={data.encounter}
            auditLog={data.auditLog}
            isAdmin={data.isAdmin}
            openInvestigations={openInvestigations}
            activeWorkflows={activeWorkflows}
            pendingRx={pendingRx}
            wfItems={WF_ITEMS}
          />
        </div>

        {/* MAIN COLUMN -- tab content only; the tab bar itself now lives
            in the sticky header above so it freezes along with the
            patient identity bar. */}
        <div>
          {/* Tab content and the actions bar below are wrapped in a native
              <fieldset disabled> when the encounter is locked -- this
              cascades to every nested input/select/button in the embedded
              OptometryWorkspace, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'optometry' && (
            <OptometryWorkspace queueEntryId={queueEntryId} embedded />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              <GroupHeader num={1} color="var(--purple)" title="Investigations" />

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>
                {data.isFollowUp && followUpContext && (
                  <NewInvestigationsSinceLastVisit
                    investigations={followUpContext.newInvestigations}
                    matchInvestigationType={matchInvestigationType}
                    summarizeResultData={summarizeResultData}
                  />
                )}
                {data.investigations.map((i) => {
                  const type = matchInvestigationType(i.name);
                  const hasResults = i.status === 'Available';
                  return (
                    <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
                        <span>
                          <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                        </span>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                          {hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {hasResults && (
                        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3 }}>{summarizeResultData(type, i.result_data)}</div>
                      )}
                      {i.status === 'Cancelled' && i.unable_reason && (
                        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}><i className="ti ti-alert-triangle"></i> Unable to perform -- {i.unable_reason}</div>
                      )}
                    </div>
                  );
                })}
                {data.investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No investigations ordered yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setInvName(e.target.value); }}>
                  <option value="">-- Pick from Investigations master (or type below) --</option>
                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              <GroupHeader num={2} color="var(--indigo)" title="Biometry" />
              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                  Device measurements, IOL power calculation, and surgeon approval -- its own dedicated workflow, separate from lab investigations.
                </div>

                {bioSent ? (
                  <>
                    <div style={{ marginBottom: 6 }}>
                      <span className="badge b-green"><i className="ti ti-check"></i> Sent for Biometry</span>
                    </div>
                    {data.biometryRecords.map((r) => (
                      <div key={r.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                          <span className={`badge ${r.status === 'Measured' ? 'b-green' : 'b-amber'}`}>
                            {r.status}
                          </span>
                          <a href={`/biometry/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 12, textDecoration: 'none' }}>
                            <i className="ti ti-external-link"></i> Open Biometry
                          </a>
                          {editingBioId !== r.id && (
                            <button className="btn" style={{ fontSize: 11 }} onClick={() => startEditBioInstructions(r)}>
                              <i className="ti ti-edit"></i> {r.doctor_instructions ? 'Edit instructions' : 'Add instructions'}
                            </button>
                          )}
                          {r.billing_status !== 'Billed' ? (
                            <button className="btn" style={{ fontSize: 11, color: 'var(--red)' }} onClick={() => handleRemoveBiometry(r.id)}>
                              <i className="ti ti-trash"></i> Remove
                            </button>
                          ) : (
                            <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                          )}
                        </div>
                        {editingBioId === r.id ? (
                          <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                            <input className="fi" style={{ flex: 1 }} placeholder="Instructions for technician" value={editBioInstructions} onChange={(e) => setEditBioInstructions(e.target.value)} />
                            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => saveBioInstructions(r.id)}>Save</button>
                            <button className="btn" style={{ fontSize: 12 }} onClick={() => setEditingBioId(null)}>Cancel</button>
                          </div>
                        ) : r.doctor_instructions && (
                          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 4 }}><i className="ti ti-notes"></i> {r.doctor_instructions}</div>
                        )}
                      </div>
                    ))}
                  </>
                ) : (
                  <>
                    {data.biometryRecords.length > 0 && (
                      <div style={{ marginBottom: 10 }}>
                        {data.biometryRecords.map((r) => (
                          <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4, flexWrap: 'wrap' }}>
                            <span className="badge b-indigo"><i className="ti ti-check"></i> Advised</span>
                            {r.billing_status !== 'Billed' ? (
                              <button className="btn" style={{ fontSize: 10 }} onClick={() => handleRemoveBiometry(r.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i> Remove
                              </button>
                            ) : (
                              <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                            )}
                          </div>
                        ))}
                        <span style={{ fontSize: 11, color: 'var(--g500)' }}>Adjust below if needed, then use &quot;Send for Biometry&quot; at the bottom.</span>
                      </div>
                    )}
                    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                      <div style={{ flex: 1, minWidth: 200 }}>
                        <label className="flbl">Instructions for technician (optional)</label>
                        <input className="fi" placeholder="e.g. prior RK surgery, dense cataract" value={bioInstructions} onChange={(e) => setBioInstructions(e.target.value)} />
                      </div>
                      <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAdviseBiometry}>
                        {data.biometryRecords.length > 0 ? 'Update' : 'Add'}
                      </button>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>
                      Adding here records the advice -- use &quot;Send for Biometry&quot; below when you&apos;re ready to actually route the patient.
                    </div>
                  </>
                )}
              </div>

              <GroupHeader num={3} color="var(--teal)" title="Diagnosis" />

              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
                {data.isFollowUp && followUpContext && !isReadOnly && (
                  <CarryForwardDiagnoses
                    priorDiagnoses={followUpContext.snapshot.currentDiagnoses}
                    alreadyAdded={data.diagnoses}
                    onCarryForward={handleCarryForward}
                  />
                )}
                {data.diagnoses.map((d, idx) => (
                  <DiagnosisRow key={d.id} d={d} index={idx} encounterId={data.encounter.id} onRemove={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }} />
                ))}
                {data.diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setDxName(e.target.value); }}>
                  <option value="">-- Pick from Diagnoses master (or type below) --</option>
                  {diagnosisOptions.map((d) => <option key={d.id} value={d.name}>{d.name}{d.category ? ` (${d.category})` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              <GroupHeader num={4} color="var(--blue)" title="Treatment" />

              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Prescription</div>
                {data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && !isReadOnly && (
                  <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Continue from last visit</div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {followUpContext.snapshot.currentMedications
                        .filter((m) => !data.prescriptions.some((r) => r.drug_name === m.drug_name && r.eye === m.eye))
                        .map((m) => (
                          <button
                            key={m.id}
                            className="btn btn-sm"
                            onClick={async () => {
                              await addPrescription(data.encounter.id, { drugName: m.drug_name, dosage: m.dosage, frequency: m.frequency, duration: m.duration, eye: m.eye });
                              refresh();
                            }}
                          >
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye})
                          </button>
                        ))}
                    </div>
                  </div>
                )}
                {(() => {
                  // Group rows sharing a taper_group_id into one block
                  // (ordered by taper_step); everything else renders as
                  // a normal single-line prescription, same as before.
                  const seen = new Set();
                  const items = [];
                  data.prescriptions.forEach((r) => {
                    if (r.taper_group_id) {
                      if (seen.has(r.taper_group_id)) return;
                      seen.add(r.taper_group_id);
                      const steps = data.prescriptions
                        .filter((x) => x.taper_group_id === r.taper_group_id)
                        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
                      items.push({ type: 'taper', key: r.taper_group_id, steps });
                    } else {
                      items.push({ type: 'single', key: r.id, row: r });
                    }
                  });
                  return items.map((item) => item.type === 'single' ? (
                    <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>
                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye}
                      </span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ) : (
                    <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <span style={{ fontSize: 13 }}>
                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye}
                          <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering Schedule</span>
                        </span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>
                      </div>
                      <div style={{ fontSize: 12.5, marginTop: 4, color: 'var(--g700)' }}>
                        {item.steps.map((s, i) => (
                          <span key={s.id}>
                            {i > 0 && <i className="ti ti-arrow-right" style={{ margin: '0 4px', color: 'var(--g400)' }}></i>}
                            {s.frequency} <span style={{ color: 'var(--g500)' }}>x {s.duration}</span>
                          </span>
                        ))}
                        <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
                      </div>
                    </div>
                  ));
                })()}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr auto', gap: 6, marginTop: 10, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span>Drug</span><span>Dosage</span><span>Frequency</span><span>Duration</span><span>Eye</span><span></span>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 4, flexWrap: 'wrap', alignItems: 'flex-start' }}>
                  <div style={{ position: 'relative', flex: '2 1 160px' }}>
                    <input
                      className="fi"
                      placeholder="Type to search medicines, or enter a new name"
                      value={rxDrug}
                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setShowRxSuggestions(true); }}
                      onFocus={() => setShowRxSuggestions(true)}
                      onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
                      style={{ width: '100%' }}
                    />
                    {showRxSuggestions && rxDrug.trim().length > 0 && (
                      <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 230, overflowY: 'auto', marginTop: 3 }}>
                        {rxSuggestions.length > 0 ? rxSuggestions.map((d) => (
                          <div key={d.id} onMouseDown={() => selectRxDrug(d)} style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 12.5, borderBottom: '1px solid var(--g100)' }}>
                            <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
                            {d.master_drug_types?.name && <span style={{ marginLeft: 6, fontSize: 10.5, color: 'var(--purple)' }}>{d.master_drug_types.name}</span>}
                          </div>
                        )) : (
                          <div style={{ padding: '8px 12px', fontSize: 12, color: 'var(--g500)' }}>
                            No match in Pharmacy master.{' '}
                            <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 11 }} onMouseDown={() => { setShowRxBrowseAll(true); setShowRxSuggestions(false); }}>Browse full list</button>
                            {' '}or keep typing to prescribe as free text.
                          </div>
                        )}
                      </div>
                    )}
                    {showRxBrowseAll && (
                      <select className="fi" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
                        if (!e.target.value) return;
                        const picked = drugOptions.find((d) => d.brand === e.target.value);
                        if (picked) selectRxDrug(picked);
                        setShowRxBrowseAll(false);
                      }}>
                        <option value="">-- Browse full Pharmacy master --</option>
                        {drugOptions.filter((d) => d.brand).map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                      </select>
                    )}
                  </div>
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option value="">-- Dosage --</option>
                    {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => (
                      <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                    ))}
                    {/* Generic fallback -- shown when the drug has no type assigned yet (free-typed name, or a master drug still missing its Type in Financial Masters) so the field never comes up empty. */}
                    {!rxDrugTypeId && (
                      <>
                        <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                      </>
                    )}
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>

                {!showTaperBuilder ? (
                  <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => setShowTaperBuilder(true)}>
                    <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                  </button>
                ) : (
                  <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug, Dosage &amp; Eye entered above; frequency reduces step by step below
                    </div>
                    {taperSteps.map((s, i) => (
                      <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                        <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                        <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                          <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                        </select>
                        <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                          <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
                        </select>
                        {taperSteps.length > 2 && (
                          <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
                        )}
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                      <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                      <button className="btn btn-sm btn-primary" onClick={handleAddTaperSchedule}>Save Tapering Schedule</button>
                      <button className="btn btn-sm" onClick={() => setShowTaperBuilder(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                  {data.opticalAdvice.map((o) => (
                    <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{o.advice}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                    {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                      <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                    ))}
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Minor Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                      {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{p.notes}</div>}
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select minor procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name} -- Rs.{p.rate}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 110 }}>
                      <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                  </div>
                  <input className="fi fi-sm" placeholder="Notes (optional)" value={procNotes} onChange={(e) => setProcNotes(e.target.value)} />
                </div>
              </div>

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery</div>

                {data.surgicalCases.length > 0 ? (
                  <div>
                    {data.surgicalCases.map((sc) => (
                      <div key={sc.id}>
                        {editingSurgicalCaseId === sc.id ? (
                          <div style={{ padding: '8px 0' }}>
                            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                              <select className="fi" value={editSurgeryProcedure} onChange={(e) => setEditSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                                <option value="">-- Select surgery --</option>
                                {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                              </select>
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 110 }}>
                                <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Pre-op Required</label>
                              <select className="fi" value={editSurgeryPreOp} onChange={(e) => setEditSurgeryPreOp(e.target.value)}>
                                <option value="None">None</option>
                                <option value="Biometry">Biometry</option>
                                <option value="Medical Fitness">Medical Fitness</option>
                                <option value="Both">Both</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Notes</label>
                              <input className="fi" placeholder="Any notes for this surgery recommendation..." value={editSurgeryNotes} onChange={(e) => setEditSurgeryNotes(e.target.value)} />
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ padding: '6px 0' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                              <span style={{ flex: 1 }}>
                                <strong>{sc.procedure_name}</strong> -- {sc.eye === 'OD' ? 'Right (OD)' : sc.eye === 'OS' ? 'Left (OS)' : sc.eye === 'OU' ? 'Both (OU)' : sc.eye}
                                <span style={{ marginLeft: 8, fontSize: 10.5, color: 'var(--g500)' }}>
                                  Pre-op: {sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None'}
                                </span>
                              </span>
                              <span className="badge b-blue" style={{ fontSize: 10 }}>{sc.status}</span>
                              {sc.status === 'Pending Workup' && (
                                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => startEditSurgicalCase(sc)}>
                                  <i className="ti ti-edit"></i> Edit
                                </button>
                              )}
                            </div>
                            {sc.notes && (
                              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3, marginLeft: 22 }}><i className="ti ti-notes"></i> {sc.notes}</div>
                            )}
                          </div>
                        )}
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select surgery --</option>
                        {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 110 }}>
                        <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Pre-op Required</label>
                      <select className="fi" value={surgeryPreOp} onChange={(e) => setSurgeryPreOp(e.target.value)}>
                        <option value="None">None</option>
                        <option value="Biometry">Biometry</option>
                        <option value="Medical Fitness">Medical Fitness</option>
                        <option value="Both">Both</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              <GroupHeader num={5} color="var(--amber)" title="Patient Management" />

              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                  {data.referrals.map((r) => (
                    <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                    <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Destination --</option>
                      <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                    </select>
                    <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                    <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                      <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                    </select>
                    <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                      <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                    </select>
                    <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                      <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                    </select>
                  </div>
                  <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                  <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                  {fuSaved && (
                    <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                      Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                    </div>
                  )}
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {data.isFollowUp && (
            <VisitOutcomeSelector value={visitOutcome} onChange={handleVisitOutcomeChange} disabled={isReadOnly} />
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn" onClick={handleSaveDraft} disabled={loading}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            {data.investigations.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
                Send for Investigation
              </button>
            )}
            {!bioSent && data.biometryRecords.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('biometry')} disabled={loading}>
                <i className="ti ti-ruler-measure"></i> Send for Biometry
              </button>
            )}
            {data.procedures.length > 0 && (
              <button className="btn" onClick={handleSendForProcedure} disabled={loading}>
                <i className="ti ti-tool"></i> Send for Procedure
              </button>
            )}
          </div>

          {/* Escape hatch -- for a visit that genuinely can't reach the
              diagnosis requirement above (patient left, no-show after
              being called, etc). Kept visually separate from the main
              actions so it isn't a tempting shortcut for normal visits. */}
          {!isReadOnly && (
            <div className="card" style={{ marginTop: 8 }}>
              {!showForceClose ? (
                <button className="btn" style={{ fontSize: 12, color: 'var(--g500)' }} onClick={() => setShowForceClose(true)}>
                  <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
                </button>
              ) : (
                <div>
                  <label className="flbl">Why can&apos;t this visit be completed normally? *</label>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <input className="fi" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                      {forceClosing ? 'Closing...' : 'Confirm'}
                    </button>
                    <button className="btn" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
          </fieldset>

          {/* PRINT ACTIONS -- deliberately kept OUTSIDE the <fieldset
              disabled={isReadOnly}> above. Printing a case sheet / visit
              summary doesn't change any data, so a completed (locked)
              encounter should still allow printing without requiring
              "Unlock to Edit" first. */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <button onClick={() => openPrintPopup(`/opd-case-sheet-print/${data.encounter.id}`)} className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </button>
            <button onClick={() => openPrintPopup(`/visit-summary-print/${data.encounter.id}`)} className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

FILEEOF_consultation_form_js

mkdir -p "app/components"
cat > "app/components/AppShell.js" << 'FILEEOF_appshell_js'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState, useRef } from 'react';
import { createClient } from '@/lib/supabase-browser';
import { updateHeartbeat } from '@/app/(main)/users/actions';

// 30 minutes of no mouse/keyboard/touch activity -> automatic sign-out.
// Balances security (unattended shared terminals in a hospital) against
// not interrupting a doctor mid-consultation for a shorter window.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const CHECK_INTERVAL_MS = 60 * 1000;

const NAV_ITEMS = [
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/inventory', label: 'Inventory', icon: 'ti-boxes', section: 'Inventory' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/surgical-journey', label: 'Surgical Journey', icon: 'ti-route', section: 'Surgical' },
  { href: '/iol-approval', label: 'IOL Approval', icon: 'ti-lens', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration', adminOnly: true },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Patient Flow' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/inventory/, title: 'Inventory' },
  { match: /^\/surgical-journey/, title: 'Surgical Journey' },
  { match: /^\/iol-approval/, title: 'IOL Approval' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery & Discharge' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  // Every navigation should close the drawer -- without this, tapping
  // a link would leave it sitting open over the new page underneath.
  useEffect(() => { setMobileNavOpen(false); }, [pathname]);

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  // Idle auto-logout + "who's online" heartbeat. Checked on an interval,
  // AND immediately whenever the tab becomes visible again -- browsers
  // (Chrome especially) heavily throttle setInterval in backgrounded
  // tabs, sometimes to firing only once every several minutes or less,
  // so the interval alone can miss the 30-minute mark while the tab
  // sits unfocused. visibilitychange isn't subject to that throttling
  // and fires exactly when someone switches back to the tab, so it
  // catches what the interval missed. It doesn't count as "activity"
  // itself -- only real mouse/keyboard/touch input resets the clock.
  const lastActivityRef = useRef(Date.now());
  useEffect(() => {
    const markActive = () => { lastActivityRef.current = Date.now(); };
    const events = ['mousemove', 'keydown', 'mousedown', 'scroll', 'touchstart'];
    events.forEach((e) => window.addEventListener(e, markActive, { passive: true }));

    const checkIdle = async () => {
      const idleMs = Date.now() - lastActivityRef.current;
      if (idleMs >= IDLE_TIMEOUT_MS) {
        await supabase.auth.signOut();
        router.push('/login?reason=idle');
        router.refresh();
      } else {
        updateHeartbeat();
      }
    };

    const onVisible = () => { if (document.visibilityState === 'visible') checkIdle(); };
    document.addEventListener('visibilitychange', onVisible);

    updateHeartbeat(); // immediately on mount, not just on the first interval tick -- extra safety net beyond the login-page write

    const interval = setInterval(checkIdle, CHECK_INTERVAL_MS);

    return () => {
      events.forEach((e) => window.removeEventListener(e, markActive));
      document.removeEventListener('visibilitychange', onVisible);
      clearInterval(interval);
    };
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const visibleNavItems = NAV_ITEMS.filter((i) => !i.adminOnly || profile?.designation === 'Administrator');
  const sections = [...new Set(visibleNavItems.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = visibleNavItems
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      {mobileNavOpen && <div className="mobile-nav-backdrop" onClick={() => setMobileNavOpen(false)}></div>}

      <div className={`sidebar ${mobileNavOpen ? 'mobile-open' : ''}`}>
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {visibleNavItems.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <button
              className="mobile-menu-btn btn"
              style={{ padding: '7px 10px', flexShrink: 0 }}
              onClick={() => setMobileNavOpen(true)}
              aria-label="Open menu"
            >
              <i className="ti ti-menu-2"></i>
            </button>
            <div>
              <div className="top-title">{pageTitle}</div>
              <div className="top-sub">Veda Eye Hospital</div>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div className="topbar-userinfo" style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}
FILEEOF_appshell_js

mkdir -p "app/print-templates"
cat > "app/print-templates/actions.js" << 'FILEEOF_print_templates_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';
import { plainFrequency, groupPrescriptionsForPrint } from '@/lib/prescriptionFormatting';

// ── Editable print templates ──────────────────────────────────────────
// Each template's HTML lives here as a code-level DEFAULT (versioned,
// reviewable) which the database can override once someone edits and
// saves it from the Print Templates admin page. getPrintTemplate()
// always returns *something renderable* -- the DB row if one exists,
// otherwise this default -- so there's never a missing-template state.
//
// Hospital-wide info (name, address, logo, etc) is deliberately NOT
// hardcoded into these templates -- it lives in hospital_settings and
// gets merged into the render context, edited once as a proper form
// rather than hunted down inside every template's HTML.
//
// Templates use Handlebars {field} tokens ({{field}} for the one
// HTML field, the logo). All formatting (currency, dates) happens in
// the *data-building* functions below, so editors only ever see plain
// tokens, never format-string logic.

const DEFAULT_TEMPLATES = {
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<style>\n  @media print {\n    @page { size: A4; margin: 8mm 10mm; }\n  }\n</style>\n<div style=\"max-width: 800px; margin: 0 auto; padding: 10px 16px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 10.5px; line-height: 1.3;\">\n\n  {{#if hide_header}}\n  <!-- Header hidden -- printing on pre-printed letterhead. Blank space\n       left at top matches the pad's own header height. -->\n  <div style=\"height: {{header_space_cm}}cm;\"></div>\n  {{else}}\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 3px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 16px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 9px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 8.5px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 9px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n  {{/if}}\n\n  <div style=\"text-align: center; font-size: 13px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 4px 0; margin: 5px 0 6px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 8px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Chief Complaint</div>\n    <div style=\"font-size: 10.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n    {{#if hx_hopi}}<div style=\"font-size: 10px; color: #444; margin-top: 3px;\">{{hx_hopi}}</div>{{/if}}\n  </div>\n  {{/if}}\n\n  <!-- STRUCTURED HISTORY -->\n  {{#if hasHistory}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">History</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each historyLines}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 130px; color: #444; vertical-align: top;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{text}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#if hasViUnaided}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViGlasses}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViPh}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Pinhole)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_ph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_ph}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViNear}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Near)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_near}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_near}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasIop}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg){{#if iop_method}} -- {{iop_method}}{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n      {{/if}}\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasDistRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{dist_rx_source}}) -- Distance</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasNearRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{near_rx_source}}) -- Near</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADDITIONAL PRE-OP TESTS -->\n  {{#if hasAdditionalTests}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Additional Tests</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each additionalTests}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- OPTOMETRY OBSERVATIONS -->\n  {{#if hasOptObservations}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Optometry Observations</div>\n    <div style=\"font-size: 10.5px;\">{{optObservations}}</div>\n  </div>\n  {{/if}}\n\n  <!-- EXAMINATION -->\n  {{#if hasExamination}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Examination Findings</div>\n\n    {{#if hasExternal}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">External Examination</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each externalRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasAnterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Anterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each anteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasPosterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Posterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each posteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasApplanation}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Applanation Tonometry</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (OD)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (OS)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_le}}</td>\n      </tr>\n    </table>\n    {{/if}}\n\n    {{#if hasGonioscopy}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Gonioscopy</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each gonioscopyRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#unless hasExternal}}{{#unless hasAnterior}}{{#unless hasPosterior}}{{#unless hasApplanation}}{{#unless hasGonioscopy}}\n    <div style=\"font-size: 10px; color: #666; margin-bottom: 3px;\">External Examination and Anterior Segment -- all findings within normal limits. No Posterior Segment, Applanation Tonometry, or Gonioscopy data recorded.</div>\n    {{/unless}}{{/unless}}{{/unless}}{{/unless}}{{/unless}}\n\n    {{#if hasExamExtra}}\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Clinical Remarks</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each examExtra}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 10.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 8.5px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 3px; text-align: center; font-size: 9px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Advice</div>\n    <div style=\"font-size: 10.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 5px 10px; font-size: 10.5px; color: #123a66; margin-bottom: 8px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 14px;\">\n    <tr>\n      <td style=\"font-size: 10px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 10px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 9px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 8px; font-size: 9px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  glasses_prescription: `<div style="max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  {{#if hide_header}}
  <!-- Header hidden -- printing on pre-printed letterhead / prescription
       pad. Blank space left at the top matches the pad's own header
       height so the printed content starts below it. -->
  <div style="height: {{header_space_cm}}cm;"></div>
  {{else}}
  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>
  {{/if}}

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    SPECTACLE PRESCRIPTION
  </div>

  <!-- PATIENT / RX INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444;">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>{{rx_date}}</strong></td></tr>
          <tr><td style="color: #444;">VA SCALE</td><td>: <strong>{{va_scale}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  {{#if hasDistRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Distance</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#if hasNearRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Near</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#unless hasDistRx}}{{#unless hasNearRx}}
  <div style="padding: 20px; text-align: center; color: #9ca3af; font-size: 12px; border: 1px dashed #d1d5db; border-radius: 8px; margin-bottom: 16px;">
    No Final Rx recorded for this assessment.
  </div>
  {{/unless}}{{/unless}}

  <table style="width: 60%; margin-bottom: 20px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444;">IPD (Interpupillary Distance)</td>
      <td style="padding: 4px 0; text-align: right; font-weight: 700;">{{ipd}}</td>
    </tr>
  </table>

  <div style="background: #eef2f7; border-left: 3px solid #1e4e8c; padding: 8px 12px; font-size: 11.5px; color: #444; margin-bottom: 30px;">
    This prescription is valid for 6 months from the date of issue. Please carry this slip to your optician.
  </div>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 50%; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;">
          <div style="font-weight: 600;">{{optometrist_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Optometrist</div>
        </div>
      </td>
      <td style="width: 50%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;">
          <div style="font-weight: 600;">{{doctor_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{doctor_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  biometry_report: `<div style="max-width: 720px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    IOL BIOMETRY &amp; POWER CALCULATION REPORT
  </div>

  <!-- PATIENT / SURGICAL INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 55%; padding: 10px 14px; vertical-align: top; font-size: 12px; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444; padding: 2px 0;">PATIENT ID</td><td style="padding: 2px 0;">: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">NAME</td><td style="padding: 2px 0;">: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">AGE/GENDER</td><td style="padding: 2px 0;">: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">VISIT NO</td><td style="padding: 2px 0;">: <strong>{{visit_number}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 45%; padding: 10px 14px; vertical-align: top; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 90px; color: #444; padding: 2px 0;">DATE</td><td style="padding: 2px 0;">: <strong>{{report_date}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">PROCEDURE</td><td style="padding: 2px 0;">: <strong>{{procedure_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">EYE</td><td style="padding: 2px 0;">: <strong>{{surgical_eye}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">SURGEON</td><td style="padding: 2px 0;">: <strong>{{surgeon_name}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <!-- BIOMETRY READINGS -->
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Biometry Readings</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 50%; vertical-align: top; padding-right: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Right Eye (RE / OD) -- Oculus Dexter</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasReReadings}}
          {{#each reSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
      <td style="width: 50%; vertical-align: top; padding-left: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Left Eye (LE / OS) -- Oculus Sinister</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasLeReadings}}
          {{#each leSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
    </tr>
  </table>

  <!-- IOL POWER CALCULATION -->
  {{#if hasFormulaResults}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Power Calculation</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
    <tr style="background: #e9edf2;">
      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Formula</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">IOL Power</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">Predicted Refraction</th>
    </tr>
    {{#each formulaResults}}
    <tr style="{{#if isSelected}}background: #f0fdf4; font-weight: 700;{{/if}}">
      <td style="border: 1px solid #999; padding: 7px;">{{name}}{{#if isSelected}} <span style="color: #16a34a;">(Selected)</span>{{/if}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{power}} D</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{refraction}}</td>
    </tr>
    {{/each}}
  </table>
  {{/if}}

  <!-- FINAL APPROVED PLAN -->
  <div style="font-size: 13px; font-weight: 700; color: #16a34a; margin-bottom: 8px; text-transform: uppercase;">Final Approved Plan</div>
  <table style="width: 100%; border: 1.5px solid #16a34a; border-collapse: collapse; margin-bottom: 18px; background: #f0fdf4;">
    <tr>
      <td style="padding: 10px 14px; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 160px; color: #444; padding: 3px 0;">Final IOL Power</td><td style="padding: 3px 0;"><strong>{{final_iol_power}} D</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Formula Used</td><td style="padding: 3px 0;"><strong>{{final_iol_formula}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">IOL Category</td><td style="padding: 3px 0;"><strong>{{final_iol_category}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Lens</td><td style="padding: 3px 0;"><strong>{{final_iol_lens}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Target Refraction</td><td style="padding: 3px 0;"><strong>{{target_refraction}}</strong></td></tr>
          {{#if surgeon_notes}}
          <tr><td style="color: #444; padding: 3px 0; vertical-align: top;">Surgeon Notes</td><td style="padding: 3px 0;">{{surgeon_notes}}</td></tr>
          {{/if}}
          <tr><td style="color: #444; padding: 3px 0;">Approved On</td><td style="padding: 3px 0;">{{approved_date}}</td></tr>
        </table>
      </td>
    </tr>
  </table>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
          <div style="font-weight: 600;">{{surgeon_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{surgeon_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n",
  medicine_prescription: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    MEDICINE PRESCRIPTION\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">VISIT NO</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DATE</td><td>: <strong>{{print_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Medicines Prescribed</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 7px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">How Often</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; font-weight: 600;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 9px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 7px; text-align: center; font-size: 11.5px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{else}}\n  <div style=\"font-size: 12.5px; color: #9ca3af; margin-bottom: 14px;\">No medicines prescribed for this visit.</div>\n  {{/if}}\n\n  <div style=\"background: #eef4fb; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12px; color: #123a66; margin-bottom: 20px;\">\n    Please take medicines exactly as instructed above. If you have any doubt about how to use a medicine, ask the pharmacist before you leave.\n  </div>\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>Dr. {{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n"
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'glasses_prescription', name: 'Glasses Prescription', description: 'Printed from the Optometry screen -- Final Rx spectacle prescription for the patient / optician.' },
  { key: 'biometry_report', name: 'Biometry Report', description: 'Printed from Surgeon Approval (Biometry) -- raw biometry readings, IOL power calculation, and the final approved plan.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Printed for a completed investigation -- findings, notes, technician/verifier sign-off.' },
  { key: 'medicine_prescription', name: 'Medicine Prescription', description: 'Printed from Pharmacy -- the medicine list on its own, independent of the bill, for the patient to keep or take elsewhere.' },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Printed at Post-op discharge -- procedure, IOL, medications, instructions, follow-up schedule.' },
];

// ── Hospital Settings -- the "actual fields to edit" form (name,
//    address, logo, etc), shared across every template. Singleton row
//    (id is always `true`). ──
export async function getHospitalSettings() {
  const supabase = await createClient();
  const { data } = await supabase.from('hospital_settings').select('*').eq('id', true).maybeSingle();
  return data || {};
}

export async function saveHospitalSettings(fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('hospital_settings').update({
    ...fields, updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }).eq('id', true);
  if (error) return { error: error.message };
  return { success: true };
}

function logoHtml(settings) {
  if (settings?.logo_data_url) {
    return `<img src="${settings.logo_data_url}" style="width: 88px; height: 88px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="88" height="88" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
    <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>
    <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>
    <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>
  </svg>`;
}

export async function listPrintTemplates() {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('template_key, updated_at, updated_by, profiles(full_name)');
  const byKey = {};
  (data || []).forEach((r) => { byKey[r.template_key] = r; });
  return PRINT_TEMPLATE_CATALOG.map((t) => ({
    ...t,
    customized: !!byKey[t.key],
    updatedAt: byKey[t.key]?.updated_at || null,
    updatedBy: byKey[t.key]?.profiles?.full_name || null,
  }));
}

export async function getPrintTemplate(key) {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('html, updated_at').eq('template_key', key).maybeSingle();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  return {
    key,
    name: catalog?.name || key,
    html: data?.html || DEFAULT_TEMPLATES[key] || '<div>No template found.</div>',
    isCustomized: !!data,
    updatedAt: data?.updated_at || null,
  };
}

export async function savePrintTemplate(key, html) {
  const supabase = await createClient();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('print_templates').upsert({
    template_key: key, name: catalog?.name || key, html,
    updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }, { onConflict: 'template_key' });
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetPrintTemplate(key) {
  const supabase = await createClient();
  const { error } = await supabase.from('print_templates').delete().eq('template_key', key);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Preview arbitrary (possibly unsaved) template HTML against sample
//    data -- lets the editor see changes before committing them. ──
export async function previewTemplateHtml(key, html) {
  try {
    const compiled = Handlebars.compile(html);
    return { html: compiled(await getSampleData(key)) };
  } catch (e) {
    return { error: `Template error: ${e.message}` };
  }
}

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  const settings = await getHospitalSettings();
  if (key === 'invoice_opd') return buildInvoiceContext(settings, SAMPLE_OPD_RAW);
  if (key === 'invoice_surgery') return buildInvoiceContext(settings, SAMPLE_SURGERY_RAW);
  if (key === 'receipt') return buildReceiptContext(settings, SAMPLE_RECEIPT_RAW);
  if (key === 'receipt_advance') return buildReceiptContext(settings, SAMPLE_ADVANCE_RAW);
  if (key === 'opd_case_sheet') return buildOpdCaseSheetContext(settings, SAMPLE_CASE_SHEET_RAW);
  if (key === 'glasses_prescription') return buildGlassesPrescriptionContext(settings, SAMPLE_GLASSES_RX_RAW);
  if (key === 'biometry_report') return buildBiometryReportContext(settings, SAMPLE_BIOMETRY_RAW);
  if (key === 'discharge_summary') return buildDischargeSummaryContext(settings, SAMPLE_DISCHARGE_RAW);
  if (key === 'investigation_report') return SAMPLE_INVESTIGATION_CONTEXT(settings);
  return {};
}

const SAMPLE_DISCHARGE_RAW = {
  patient: { uhid: 'VEH-00004', first_name: 'Utkarsh', last_name: 'Prakash', mobile: '9876543210', age: 62, gender: 'M' },
  surgeon: { full_name: 'Nisha Bachkheti' },
  procedureName: 'Phaco Cataract Surgery', eye: 'OD',
  episode: {
    admission_date: '2026-06-10', surgery_date: '2026-06-10', discharge_date: '2026-06-11',
    discharge_notes: 'Uneventful surgery. Patient tolerated procedure well.',
    discharge_instructions: 'Avoid rubbing the eye. No water contact for 1 week. Use dark glasses outdoors. Report immediately for redness, pain, or sudden vision loss.',
  },
  intraop: { implant_power: '21.5', implant_manufacturer: 'Alcon', implant_model: 'AcrySof IQ' },
  biometry: [{ surgical_eye: 'OD', final_iol_power: '21.5', final_iol_category: 'Monofocal' }],
  meds: [
    { name: 'Moxifloxacin 0.5%', sig: '1 drop QID x 1 week, then taper' },
    { name: 'Prednisolone Acetate 1%', sig: '1 drop QID x 2 weeks, then taper' },
  ],
  followups: [
    { visit_label: 'Post-op Day 1', scheduled_date: '2026-06-12', status: 'Completed' },
    { visit_label: 'Post-op Week 1', scheduled_date: '2026-06-18', status: 'Scheduled' },
    { visit_label: 'Post-op Month 1', scheduled_date: '2026-07-11', status: 'Scheduled' },
  ],
};

function SAMPLE_INVESTIGATION_CONTEXT(settings) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),
    patient_id: 'VEH-00004', patient_name: 'Utkarsh Prakash', patient_age: 62, patient_gender: 'M', patient_mobile: '9876543210',
    investigation_name: 'OCT Macula', investigation_type: 'OCT', eye: 'OD',
    doctor_name: 'Nisha Bachkheti', ordered_date: '04 Jun 2026', completed_date: '05 Jun 2026',
    isUnable: false, unable_reason: null,
    hasFields: true,
    fields: [
      { label: 'Central Macular Thickness (OD)', value: '245 um' },
      { label: 'RNFL Thickness', value: 'Average 85 um' },
      { label: 'Signal Strength', value: '8/10' },
    ],
    hasNotes: true, result_notes: 'Scan quality good. No macular edema noted.',
    technician_name: 'Rohit Pratap', hasVerifiedBy: true, verified_by_name: 'Nisha Bachkheti',
  };
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_number: 'V26-000042' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  packageBreakup: [
    { description: 'Surgeon fee', amount: 15000 },
    { description: 'IOL (Standard Monofocal)', amount: 8000 },
    { description: 'OT charges', amount: 7000 },
    { description: 'Consumables & disposables', amount: 3000 },
    { description: 'Pre-op investigations', amount: 2000 },
  ],
};

const SAMPLE_RECEIPT_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970' },
  payment: {
    receipt_number: 'VEH/RECEIPT/-0054', collected_at: '2026-06-03T00:00:00Z', total_amount: 300,
    payment_type: 'invoice_payment', reference: null, remarks: null,
  },
  collector: { full_name: 'Front Desk' },
  modes: [{ mode: 'Cash', amount: 300 }],
  allocations: [{ amount: 300, invoices: { invoice_number: 'VEH-BILL-0143' } }],
};

const SAMPLE_ADVANCE_RAW = {
  ...SAMPLE_RECEIPT_RAW,
  payment: {
    receipt_number: 'VEH/RECEIPT/-0060', collected_at: '2026-06-15T00:00:00Z', total_amount: 10000,
    payment_type: 'advance', reference: null, remarks: null,
  },
  modes: [{ mode: 'UPI', amount: 10000 }],
  allocations: [],
};

const SAMPLE_CASE_SHEET_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  encounter: {
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes', hx_hopi: 'Gradual, painless, progressive blurring of vision, worse for distance.',
    ocular_history: ['Diabetic Retinopathy screening -- 2024'], medical_history: ['Diabetes Mellitus Type 2'], family_history: ['Glaucoma -- father'],
    drug_history: ['Metformin 500mg BD'], allergy: ['Sulfa drugs'],
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    re_dist_ph: '6/6', le_dist_ph: '6/6', re_near_unaided: 'N8', le_near_unaided: 'N6',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '', ref_final_re_near_axis: '', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
    iop_method: 'NCT', add_k1_re: '43.5', add_k1_le: '43.7', add_k2_re: '44.2', add_k2_le: '44.4', add_axial_length_re: '23.4 mm', add_axial_length_le: '23.3 mm',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  examination: {
    external_findings: {}, anterior_findings: { Lens: { re: 'NS2', le: 'NS1', re_custom: '', le_custom: '' } }, posterior_findings: { without: { Disc: { re: 'Healthy', le: 'Healthy' }, CDR: { re: '0.4', le: '0.3' } }, with: {} },
    applanation_re: '16', applanation_le: '15',
    gonioscopy_findings: { angle_re: 'Open Angle', angle_le: 'Open Angle' },
  },
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// Deliberately includes one eye with SPH-only (no CYL/AXIS) so the
// preview shows how a spherical-only Rx renders cleanly.
const SAMPLE_GLASSES_RX_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', age: 39, gender: 'Male' },
  assessment: {
    created_at: '2026-06-01T00:00:00Z', va_scale: 'Snellen', ref_pd: '62mm',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '-0.50', ref_final_re_near_axis: '90', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
  },
  optometrist: { full_name: 'Rohit Pratap' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
};

const SAMPLE_BIOMETRY_RAW = {
  patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
  visit: { visit_number: 'VN26-000112' },
  record: {
    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Approved',
    created_at: '2026-06-01T00:00:00Z', approved_at: '2026-06-02T00:00:00Z',
    measurements: {
      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', lt: '4.50', wtw: '11.80' }],
      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', lt: '4.48', wtw: '11.75' }],
    },
    formula_results: [
      { name: 'Barrett Universal II', power: '21.5', refraction: '-0.15' },
      { name: 'SRK/T', power: '21.0', refraction: '-0.30' },
    ],
    selected_formula: 'Barrett Universal II',
    final_iol_power: '21.5', final_iol_category: 'Monofocal', target_refraction: '-0.15 D',
    surgeon_notes: 'Aim for slight myopia. Standard monofocal, no toric correction needed.',
  },
  surgeon: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ', manufacturer: 'Alcon Laboratories' },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, visit_number, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: rawLineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');

  // The invoice itself stays itemized (individual medicine names/rates
  // visible in Invoice Details) -- no pharmacy license yet, so only the
  // printed/PDF copy collapses every Pharmacy-dept line into one "OPD
  // Procedure Consumables" line at qty 1 for the combined total.
  const pharmacyLines = (rawLineItems || []).filter((li) => li.dept === 'Pharmacy');
  const nonPharmacyLines = (rawLineItems || []).filter((li) => li.dept !== 'Pharmacy');
  const pharmacyTotal = pharmacyLines.reduce((s, li) => s + Number(li.net), 0);
  const lineItems = pharmacyLines.length > 0
    ? [...nonPharmacyLines, { service_name: 'OPD Procedure Consumables', dept: 'Pharmacy', qty: 1, rate: pharmacyTotal, disc: 0, net: pharmacyTotal }]
    : nonPharmacyLines;

  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (rawLineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let packageCode = null;
  let surgeryName = null;
  let surgeryCode = null;
  let surgeryEye = null;
  let surgeonForBill = null; // Surgery Bill shows the operating surgeon, not the visit's consulting doctor
  let packageBreakup = [];
  let breakupAvailable = false;
  if (isSurgery) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created -- no visit_id
    // needed for this part at all.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    // Enrichment only -- a surgical case registered directly (OT
    // Schedule's "Register Surgery Directly") or billed without a visit
    // selected has no visit_id to look this up by. That's fine: the
    // manual_surgery_* fields below (always saved at billing time,
    // whether prefilled from a case or typed by hand) cover exactly
    // this situation, which is why they exist.
    let surgicalCase = null;
    if (invoice.visit_id) {
      const { data } = await supabase
        .from('surgical_cases')
        .select('id, procedure_name, eye, surgeon_id')
        .eq('visit_id', invoice.visit_id)
        .neq('status', 'Cancelled')
        .maybeSingle();
      surgicalCase = data;
    }

    // Surgery/Eye/Doctor are always editable in New Invoice now (whether
    // prefilled from a case or entered by hand), and whatever was
    // confirmed at billing time is saved onto the invoice itself
    // (manual_surgery_*). That takes priority over the surgical case,
    // which is live data that can keep changing after the bill was
    // printed -- same reasoning as the package name/code above.
    surgeryName = invoice.manual_surgery_name || surgicalCase?.procedure_name || null;
    surgeryEye = invoice.manual_surgery_eye || surgicalCase?.eye || null;
    const surgeonId = invoice.manual_surgeon_id || surgicalCase?.surgeon_id || null;
    if (surgeonId) {
      const { data: surgeon } = await supabase.from('profiles').select('full_name, registration_no').eq('id', surgeonId).maybeSingle();
      surgeonForBill = surgeon || null;
    }
    if (surgeryName) {
      // surgical_cases stores the surgery as free text (matched from the
      // Clinical Masters -- Surgery list at the time it was picked), not
      // a foreign key, so the code is looked up by name here.
      const { data: surgery } = await supabase.from('master_surgeries').select('code').eq('name', surgeryName).maybeSingle();
      surgeryCode = surgery?.code || null;
    }
    // Breakup lookup is keyed off packageCode (the invoice's own line
    // item, always available for a surgery invoice) -- not the
    // surgical case, so this works regardless of whether one was found.
    if (packageCode) {
      const { data: pkgForBreakup } = await supabase.from('master_packages').select('id').eq('code', packageCode).maybeSingle();
      if (pkgForBreakup) {
        const { data: breakupItems } = await supabase
          .from('package_line_items')
          .select('description, amount')
          .eq('package_id', pkgForBreakup.id)
          .order('sort_order');
        breakupAvailable = (breakupItems || []).length > 0;
        // Only actually included in the printed HTML when explicitly
        // requested (e.g. an insurance copy) -- most prints should stay
        // as the single package line item, no itemized breakup.
        if (includeBreakup) packageBreakup = breakupItems || [];
      }
    }
  }

  const settings = await getHospitalSettings();
  const context = buildInvoiceContext(settings, {
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: isSurgery ? (surgeonForBill || invoice.visits?.profiles) : invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    packageCode,
    surgeryName,
    surgeryCode,
    surgeryEye,
    packageBreakup,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context), breakupAvailable };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

// Same mapping used in OT Intraop's workspace -- kept identical so an eye
// code reads the same way everywhere in the app, including on printouts.
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
function fmtEye(code) {
  if (!code) return '--';
  return EYE_LABEL[code] || code;
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, packageBreakup }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    terms_text: settings.terms_text || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',
    surgery_name: surgeryName || '--',
    surgery_code: surgeryCode || '--',
    eye: fmtEye(surgeryEye),
    package_name: packageName || '--',
    package_code: packageCode || '--',
    // Discharge date always mirrors the visit date -- day-care surgery
    // discharge happens the same day, and the printed bill should never
    // show a different (or missing) date from a separately recorded
    // recovery episode.
    discharge_date: fmtDate(visit?.created_at),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_number: visit?.visit_number || '--',
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1,
      name: (li.dept === 'Surgery' && li.service_code) ? `${li.service_name} (${li.service_code})` : li.service_name,
      qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    // Optional itemized breakup of what a surgery package includes --
    // not part of the accounting (the invoice still has one net line
    // item for the package), just a printed reference so staff can show
    // a patient what's covered when asked. Only present when a package
    // with a saved breakup was actually billed.
    has_breakup: (packageBreakup || []).length > 0,
    package_breakup: (packageBreakup || []).map((b) => ({ description: b.description, amount: inr(b.amount) })),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}

const PAYMENT_TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

// ── Renders the actual receipt HTML for a given paymentId. Picks the
//    Advance Receipt variant when payment_type is 'advance' (a fresh
//    advance collection, not yet applied to any invoice); everything
//    else (a regular payment, or an advance being adjusted against an
//    invoice) uses the standard Payment Receipt. ──
export async function renderReceiptHtml(paymentId) {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(uhid, first_name, last_name, mobile), profiles:collected_by(full_name)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: 'Receipt not found.' };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const settings = await getHospitalSettings();
  const context = buildReceiptContext(settings, {
    patient: {
      patient_code: payment.patients?.uhid, first_name: payment.patients?.first_name, last_name: payment.patients?.last_name,
      mobile: payment.patients?.mobile,
    },
    payment,
    collector: payment.profiles,
    modes: modes || [],
    allocations: allocations || [],
  });

  const templateKey = payment.payment_type === 'advance' ? 'receipt_advance' : 'receipt';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildReceiptContext(settings, { patient, payment, collector, modes, allocations }) {
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_id: patient.patient_code || '--',
    patient_mobile: patient.mobile || '--',

    receipt_no: payment.receipt_number,
    receipt_date: fmtDate(payment.collected_at),
    payment_type_label: PAYMENT_TYPE_LABEL[payment.payment_type] || payment.payment_type,
    collected_by: collector?.full_name || '--',

    amount_received: inr(payment.total_amount),
    amount_in_words: amountInWords(payment.total_amount),

    hasAllocations: (allocations || []).length > 0,
    allocations: (allocations || []).map((a) => ({ invoiceNumber: a.invoices?.invoice_number || '--', amount: inr(a.amount) })),

    modes: (modes || []).map((m) => ({ mode: m.mode, amount: inr(m.amount) })),

    reference: payment.reference || null,
    remarks: payment.remarks || null,
  };
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

function twoDigitWords(n) {
  if (n < 20) return ONES[n];
  return `${TENS[Math.floor(n / 10)]}${n % 10 ? ' ' + ONES[n % 10] : ''}`;
}
function threeDigitWords(n) {
  if (n < 100) return twoDigitWords(n);
  return `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? ' ' + twoDigitWords(n % 100) : ''}`;
}

// Indian numbering (lakh/crore), matching how amounts are normally
// written out on Indian receipts.
function amountInWords(amount) {
  let n = Math.round(Number(amount || 0));
  if (n === 0) return 'Rupees Zero Only';
  const parts = [];
  const crore = Math.floor(n / 10000000); n %= 10000000;
  const lakh = Math.floor(n / 100000); n %= 100000;
  const thousand = Math.floor(n / 1000); n %= 1000;
  const hundred = n;
  if (crore) parts.push(`${threeDigitWords(crore)} Crore`);
  if (lakh) parts.push(`${threeDigitWords(lakh)} Lakh`);
  if (thousand) parts.push(`${threeDigitWords(thousand)} Thousand`);
  if (hundred) parts.push(threeDigitWords(hundred));
  return `Rupees ${parts.join(' ')} Only`;
}

// ── Renders the OPD Case Sheet for a given encounterId -- the
//    patient-facing handout: chief complaint, vision/IOP/refraction,
//    diagnosis, prescription, advice, and follow-up. ──
export async function renderOpdCaseSheetHtml(encounterId) {
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(id, created_at, visit_type, doctor_id, patients(uhid, first_name, last_name, mobile, age, gender), profiles:doctor_id(full_name, registration_no))')
    .eq('id', encounterId)
    .single();
  if (error || !encounter) return { error: 'Consultation not found.' };

  const visit = encounter.visits;

  const { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visit?.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let iopReadings = [];
  if (assessment) {
    const { data: readings } = await supabase.from('optometry_iop_readings').select('eye, value').eq('assessment_id', assessment.id);
    iopReadings = readings || [];
  }

  const { data: examination } = await supabase.from('clinical_examinations').select('*').eq('encounter_id', encounterId).maybeSingle();

  const { data: diagnoses } = await supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: prescriptions } = await supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: followup } = await supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle();

  const settings = await getHospitalSettings();
  const context = buildOpdCaseSheetContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      mobile: visit?.patients?.mobile, age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    encounter,
    visit,
    doctor: visit?.profiles,
    assessment,
    iopReadings,
    examination,
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── GLASSES PRESCRIPTION -- printed from the Optometry screen. Always
//    the Final Rx (the accepted prescription, not the working
//    Objective/Subjective values). Rows are only shown when at least
//    one eye has an SPH recorded; CYL/AXIS are shown blank (not "0.00")
//    when only the spherical power was given, since axis is meaningless
//    without a cylinder. ──
function fmtRxVal(v) {
  return v || '--';
}

// Falls back Final Rx -> Subjective -> Objective when the earlier one
// wasn't filled in for that eye/distance -- for the internal OPD case
// sheet only. A patient's Distance refraction is very often recorded
// in the Subjective or Objective tab and never re-typed into Final Rx,
// which otherwise makes it silently vanish from the printed sheet even
// though it was genuinely measured. Falls back per whole row (not per
// individual SPH/CYL/AXIS field) so figures from different refraction
// types are never mixed together in one row, and the source actually
// used is labeled on the printout rather than implied to be "Final".
// A distance/near refraction row can be entirely valid with SPH left
// blank (plano/zero) while the real correction sits in CYL+AXIS -- pure
// astigmatism with no spherical component is clinically common. Only
// checking SPH for "was this row filled in" silently drops exactly
// that case, so every field is checked here.
function rowHasData(assessment, prefix) {
  return !!(assessment?.[`${prefix}_sph`] || assessment?.[`${prefix}_cyl`] || assessment?.[`${prefix}_axis`] || assessment?.[`${prefix}_va`]);
}

const REFRACTION_SOURCE_LABEL = { final: 'Final Rx', subj: 'Subjective', obj: 'Objective (Auto-Rx)' };
function pickRxRow(assessment, eye, distNear) {
  for (const type of ['final', 'subj', 'obj']) {
    const prefix = `ref_${type}_${eye}_${distNear}`;
    if (rowHasData(assessment, prefix)) {
      return { cells: buildRxCells(assessment, prefix), source: type };
    }
  }
  return { cells: buildRxCells(assessment, `ref_final_${eye}_${distNear}`), source: 'final' };
}

function buildRxCells(assessment, prefix) {
  const sph = assessment?.[`${prefix}_sph`];
  const cyl = assessment?.[`${prefix}_cyl`];
  const axis = assessment?.[`${prefix}_axis`];
  const va = assessment?.[`${prefix}_va`];
  return {
    sph: fmtRxVal(sph),
    // Only spherical power is common in real prescriptions -- axis is
    // meaningless without a cylinder, so both stay blank together.
    cyl: cyl ? cyl : '--',
    axis: cyl ? fmtRxVal(axis) : '--',
    va: fmtRxVal(va),
  };
}

function buildGlassesPrescriptionContext(settings, { patient, assessment, optometrist, doctor }) {
  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');

  const hasDistRx = rowHasData(assessment, 'ref_final_re_dist') || rowHasData(assessment, 'ref_final_le_dist');
  const hasNearRx = rowHasData(assessment, 'ref_final_re_near') || rowHasData(assessment, 'ref_final_le_near');

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed prescription pad (hospital header already
    // on the paper) -- hide the digital header and leave blank space
    // matching the pad's own header height instead.
    hide_header: !!settings.glasses_rx_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    rx_date: fmtDate(assessment?.created_at),
    va_scale: assessment?.va_scale || 'Snellen',

    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,

    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,

    ipd: assessment?.ref_pd || '--',
    optometrist_name: optometrist?.full_name || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',
  };
}

export async function renderGlassesPrescriptionHtml(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select('*, visits(id, doctor_id, patients(uhid, first_name, last_name, age, gender), profiles:doctor_id(full_name, registration_no)), profiles:recorded_by(full_name)')
    .eq('id', assessmentId)
    .single();
  if (error || !assessment) return { error: 'Optometry assessment not found.' };

  const visit = assessment.visits;
  const settings = await getHospitalSettings();
  const context = buildGlassesPrescriptionContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    assessment,
    optometrist: assessment.profiles,
    doctor: visit?.profiles,
  });

  const template = await getPrintTemplate('glasses_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── BIOMETRY REPORT -- printed from Surgeon Approval once the IOL plan
//    is approved. Shows the raw biometry readings (per eye, per device --
//    a technician may have taken more than one reading, e.g. a manual
//    A-scan fallback for a dense cataract) alongside the calculated
//    formula results and the final approved plan. ──
function buildBiometryReadingSets(sets) {
  return (Array.isArray(sets) ? sets : []).map((s) => ({
    device: s.device || 'Unspecified device',
    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', lt: s.lt || '--', wtw: s.wtw || '--',
  }));
}

function buildBiometryReportContext(settings, { patient, visit, record, surgeon, catalogItem }) {
  const reSets = buildBiometryReadingSets(record.measurements?.re);
  const leSets = buildBiometryReadingSets(record.measurements?.le);

  const formulaResults = (record.formula_results || []).map((r) => ({
    name: r.name, power: r.power || '--', refraction: r.refraction || '--',
    isSelected: r.name === record.selected_formula,
  }));

  const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_id: patient.uhid || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    visit_number: visit?.visit_number || '--',
    report_date: fmtDate(record.approved_at || record.created_at),

    procedure_name: record.procedure_name || '--',
    surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
    surgeon_name: surgeon?.full_name || '--',
    surgeon_regn_no: surgeon?.registration_no || '--',

    hasReReadings: reSets.length > 0,
    reSets,
    hasLeReadings: leSets.length > 0,
    leSets,

    hasFormulaResults: formulaResults.length > 0,
    formulaResults,

    isApproved: record.status === 'Approved',
    final_iol_power: record.final_iol_power || '--',
    final_iol_formula: record.selected_formula || '--',
    final_iol_category: record.final_iol_category || '--',
    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}${catalogItem.manufacturer ? ` (${catalogItem.manufacturer})` : ''}`.trim() : '--',
    target_refraction: record.target_refraction || '--',
    surgeon_notes: record.surgeon_notes || null,
    approved_date: record.approved_at ? fmtDate(record.approved_at) : '--',
  };
}

export async function renderBiometryReportHtml(recordId) {
  const supabase = await createClient();

  const { data: record, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(uhid, first_name, last_name, age, gender))')
    .eq('id', recordId)
    .single();
  if (error || !record) return { error: 'Biometry record not found.' };

  let surgeon = null;
  if (record.verified_by) {
    const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', record.verified_by).maybeSingle();
    surgeon = doc;
  }

  const settings = await getHospitalSettings();
  const context = buildBiometryReportContext(settings, {
    patient: record.visits?.patients || {},
    visit: record.visits,
    record,
    surgeon,
    catalogItem: null,
  });

  const template = await getPrintTemplate('biometry_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// Each structure's first/baseline template option is its "normal" value
// (mirrors EXT_TEMPLATES/ANT_TEMPLATES/POST_TEMPLATES in the Examination
// tab -- kept in sync manually since the template lists live client-side).
const EXAM_NORMAL_VALUE = {
  Lids: 'Normal', Adnexa: 'Normal', Lacrimal: 'Patent', Motility: 'Full',
  Conjunctiva: 'Normal', Cornea: 'Clear', 'Anterior Chamber': 'Deep & Quiet', Iris: 'Normal Pattern', Pupil: 'Round & Reactive', Lens: 'Clear',
  Vitreous: 'Clear', Disc: 'Healthy', Macula: 'Normal', Vessels: 'Normal', 'Peripheral Retina': 'Attached',
};

const EXAM_STRUCT_LABEL = { CDR: 'C.D Ratio' };

// Pivoted RE/LE rows (label | RE | LE), matching the Vision & Intraocular
// Pressure table's layout rather than one row per eye.
//
// mode 'abnormalOnly' (External Examination, Anterior Segment): a
// structure is only shown when at least one eye deviates from normal --
// a case sheet listing every structure as "Normal" is noise. The other
// eye still shows "Normal" alongside it for a complete row.
//
// mode 'anyData' (Posterior Segment): shown whenever either eye has
// anything recorded at all, normal or not -- Posterior/CDR findings are
// specialist, surgery-relevant readings a doctor wants on the printed
// record regardless of whether they happen to be normal.
//
// Handles both the current staged shape ({without:{...}, with:{...}})
// and the legacy flat shape from before dilatation staging existed.
function summarizeExamRegionPivoted(findingsJson, structs, mode) {
  const isStaged = findingsJson && (findingsJson.without || findingsJson.with);
  const stages = isStaged
    ? [['without', 'Without Dilatation'], ['with', 'With Dilatation']]
    : [[null, null]];

  const rows = [];
  stages.forEach(([stageKey, stageLabel]) => {
    const stageData = stageKey ? findingsJson[stageKey] : findingsJson;
    structs.forEach((struct) => {
      const f = stageData?.[struct] || {};
      const reRaw = f.re || '';
      const leRaw = f.le || '';
      const reCustom = f.re_custom || '';
      const leCustom = f.le_custom || '';
      const normal = EXAM_NORMAL_VALUE[struct];
      const reIsNormal = (!reRaw || reRaw === normal) && !reCustom;
      const leIsNormal = (!leRaw || leRaw === normal) && !leCustom;

      if (mode === 'abnormalOnly') {
        if (reIsNormal && leIsNormal) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || 'Normal',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || 'Normal',
        });
      } else {
        if (!reRaw && !leRaw && !reCustom && !leCustom) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || '--',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || '--',
        });
      }
    });
  });
  return rows;
}

const GONIO_ROW_DEFS = [
  { key: 'angle', label: 'Angle Configuration' },
  { key: 'ptm', label: 'PTM Pigmentation' },
  { key: 'iris', label: 'Iris Configuration' },
];

// Same pivoted RE/LE shape as summarizeExamRegionPivoted, but Gonioscopy
// is stored flat ({angle_re, angle_le, ...}) rather than per-structure,
// so it needs its own row builder. Shown whenever either eye has
// anything recorded.
function buildGonioscopyRows(gonioFindings) {
  const rows = [];
  if (!gonioFindings) return rows;
  // Gonioscopy used to be recorded in two passes (without/with dilatation);
  // it's now a single flat pass. Legacy staged records: read "without"
  // first (it was always the primary pass), falling back to "with" so
  // nothing already recorded is lost.
  const flat = (gonioFindings.without || gonioFindings.with) ? (gonioFindings.without || gonioFindings.with) : gonioFindings;
  GONIO_ROW_DEFS.forEach(({ key, label }) => {
    const re = flat[`${key}_re`];
    const le = flat[`${key}_le`];
    if (!re && !le) return;
    rows.push({ structure: label, re: re || '--', le: le || '--' });
  });
  return rows;
}

// Frequency-shorthand translation and taper-schedule grouping is
// imported at the top of this file (lib/prescriptionFormatting.js).

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, examination, diagnoses, prescriptions, followup }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const distReRow = pickRxRow(assessment, 're', 'dist');
  const distLeRow = pickRxRow(assessment, 'le', 'dist');
  const nearReRow = pickRxRow(assessment, 're', 'near');
  const nearLeRow = pickRxRow(assessment, 'le', 'near');
  const distRe = distReRow.cells;
  const distLe = distLeRow.cells;
  const nearRe = nearReRow.cells;
  const nearLe = nearLeRow.cells;
  const cellHasData = (c) => c.sph !== '--' || c.cyl !== '--' || c.axis !== '--' || c.va !== '--';
  const hasDistRx = cellHasData(distRe) || cellHasData(distLe);
  const hasNearRx = cellHasData(nearRe) || cellHasData(nearLe);
  // Whichever eye actually supplied the row decides the label -- if
  // both eyes came from the same source this is just that source; if
  // they differed (rare), RE's source wins since it's listed first.
  const distSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(distRe) ? distReRow.source : distLeRow.source];
  const nearSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(nearRe) ? nearReRow.source : nearLeRow.source];

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

  // ── HISTORY -- Chief Complaint already existed; Ocular/Medical/Family/
  // Drug History and Allergy were captured on the encounter but never
  // made it onto the printed case sheet. ──
  const historyLines = [
    { label: 'Ocular History', items: encounter.ocular_history },
    { label: 'Medical History', items: encounter.medical_history },
    { label: 'Family History', items: encounter.family_history },
    { label: 'Drug History', items: encounter.drug_history },
    { label: 'Allergy', items: encounter.allergy },
  ].filter((h) => h.items && h.items.length > 0).map((h) => ({ label: h.label, text: h.items.join(', ') }));

  // ── OPTOMETRY -- previously only unaided/glasses vision, IOP, and
  // final refraction ("readings") made it onto the case sheet. Pinhole,
  // near vision, IOP method, additional pre-op tests, and the
  // optometrist's own recorded observations were captured but never
  // printed. ──
  const additionalTests = [
    { label: 'K1 (RE/LE)', value: (assessment?.add_k1_re || assessment?.add_k1_le) ? `${assessment?.add_k1_re || '--'} / ${assessment?.add_k1_le || '--'}` : null },
    { label: 'K2 (RE/LE)', value: (assessment?.add_k2_re || assessment?.add_k2_le) ? `${assessment?.add_k2_re || '--'} / ${assessment?.add_k2_le || '--'}` : null },
    { label: 'Axial Length (RE/LE)', value: (assessment?.add_axial_length_re || assessment?.add_axial_length_le) ? `${assessment?.add_axial_length_re || '--'} / ${assessment?.add_axial_length_le || '--'}` : null },
    { label: 'Pachymetry (RE/LE)', value: (assessment?.add_pachymetry_re || assessment?.add_pachymetry_le) ? `${assessment?.add_pachymetry_re || '--'} / ${assessment?.add_pachymetry_le || '--'}` : null },
    { label: 'Schirmer (RE/LE)', value: (assessment?.add_schirmer_re || assessment?.add_schirmer_le) ? `${assessment?.add_schirmer_re || '--'} / ${assessment?.add_schirmer_le || '--'}` : null },
    { label: 'Color Vision (RE/LE)', value: (assessment?.add_color_vision_re || assessment?.add_color_vision_le) ? `${assessment?.add_color_vision_re || '--'} / ${assessment?.add_color_vision_le || '--'}` : null },
    { label: 'Syringing (RE/LE)', value: (assessment?.add_syringing_re || assessment?.add_syringing_le) ? `${assessment?.add_syringing_re || '--'} / ${assessment?.add_syringing_le || '--'}` : null },
  ].filter((t) => t.value);

  // ── EXAMINATION -- doctor's own clinical exam (External / Anterior /
  // Posterior Segment) was captured but not printed at all. Normal
  // findings are deliberately left off -- only what's actually abnormal
  // is worth a doctor's or reviewer's attention on the printed sheet. ──
  const externalRows = examination ? summarizeExamRegionPivoted(examination.external_findings, ['Lids', 'Adnexa', 'Lacrimal', 'Motility'], 'abnormalOnly') : [];
  const anteriorRows = examination ? summarizeExamRegionPivoted(examination.anterior_findings, ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'], 'abnormalOnly') : [];
  const posteriorRows = examination ? summarizeExamRegionPivoted(examination.posterior_findings, ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'], 'anyData') : [];
  const hasApplanation = !!(examination?.applanation_re || examination?.applanation_le);
  const gonioscopyRows = examination ? buildGonioscopyRows(examination.gonioscopy_findings) : [];

  const examExtra = [
    { label: 'Remarks (RE)', value: examination?.remarks_re },
    { label: 'Remarks (LE)', value: examination?.remarks_le },
  ].filter((e) => e.value);

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed letterhead (hospital header already on
    // the paper) -- hide the digital header and leave blank space
    // matching the letterhead's own header height instead.
    hide_header: !!settings.case_sheet_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || (encounter.chief_complaint_chips || []).join(', ') || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,
    hx_hopi: encounter.hx_hopi || null,
    hasHistory: historyLines.length > 0,
    historyLines,

    hasVision: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided || assessment?.re_dist_glasses || assessment?.le_dist_glasses || assessment?.re_dist_ph || assessment?.le_dist_ph || assessment?.re_near_unaided || assessment?.le_near_unaided || reIop != null || leIop != null),
    hasViUnaided: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided),
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    hasViGlasses: !!(assessment?.re_dist_glasses || assessment?.le_dist_glasses),
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    hasViPh: !!(assessment?.re_dist_ph || assessment?.le_dist_ph),
    re_vision_ph: assessment?.re_dist_ph || '--',
    le_vision_ph: assessment?.le_dist_ph || '--',
    hasViNear: !!(assessment?.re_near_unaided || assessment?.le_near_unaided),
    re_vision_near: assessment?.re_near_unaided || '--',
    le_vision_near: assessment?.le_near_unaided || '--',
    hasIop: reIop != null || leIop != null,
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    iop_method: assessment?.iop_method || null,
    hasDistRx,
    dist_rx_source: distSourceLabel,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    hasNearRx,
    near_rx_source: nearSourceLabel,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    hasAdditionalTests: additionalTests.length > 0,
    additionalTests,
    hasOptObservations: false,
    optObservations: '',

    hasExamination: externalRows.length > 0 || anteriorRows.length > 0 || posteriorRows.length > 0 || hasApplanation || gonioscopyRows.length > 0 || examExtra.length > 0,
    hasExternal: externalRows.length > 0,
    externalRows,
    hasAnterior: anteriorRows.length > 0,
    anteriorRows,
    hasPosterior: posteriorRows.length > 0,
    posteriorRows,
    hasApplanation,
    applanation_re: examination?.applanation_re || '--',
    applanation_le: examination?.applanation_le || '--',
    hasGonioscopy: gonioscopyRows.length > 0,
    gonioscopyRows,
    hasExamExtra: examExtra.length > 0,
    examExtra,

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: groupPrescriptionsForPrint(prescriptions),

    advice: encounter.patient_instructions || null,
    followup_text: followupParts.length > 0 ? followupParts.join(' ') : null,
  };
}

// ── DISCHARGE SUMMARY -- printed from Post-op / Recovery once a patient
//    has been discharged. Mirrors what used to be a hardcoded page
//    (app/discharge-summary-print) so it's now editable like every
//    other print template and picks up hospital branding/logo. ──
export async function renderDischargeSummaryHtml(episodeId) {
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, visit_id, patients:patient_id(uhid, first_name, last_name, mobile, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error || !episode) return { error: 'Episode not found.' };
  if (!episode.discharge_date) return { error: "This patient hasn't been discharged yet." };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, not
    // biometry_records (which no longer has any "approved" concept).
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc?.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  const settings = await getHospitalSettings();
  const context = buildDischargeSummaryContext(settings, {
    patient: sc?.patients,
    surgeon: sc?.profiles,
    procedureName: sc?.procedure_name,
    eye: sc?.eye,
    episode,
    intraop,
    biometry: approval ? [approval] : [],
    meds: meds || [],
    followups: followups || [],
  });

  const template = await getPrintTemplate('discharge_summary');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildDischargeSummaryContext(settings, { patient, surgeon, procedureName, eye, episode, intraop, biometry, meds, followups }) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    surgeon_name: surgeon?.full_name || '--',
    admission_date: fmtDate(episode.admission_date),
    surgery_date: fmtDate(episode.surgery_date),
    discharge_date: fmtDate(episode.discharge_date),

    procedure_name: procedureName, eye,
    iol_lines: biometry.map((p) => ({
      eye: p.eye,
      text: `${intraop?.implant_power || p.power} D -- ${p.master_iol_catalog?.category || ''}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
    })),

    hasMedications: meds.length > 0,
    medications: meds.map((m) => ({ name: m.name, sig: m.sig })),

    hasDischargeNotes: !!episode.discharge_notes,
    discharge_notes: episode.discharge_notes,
    discharge_instructions: episode.discharge_instructions || 'As advised by the surgeon.',

    followups: followups.map((f) => ({ visit_label: f.visit_label, date: fmtDate(f.scheduled_date), status: f.status })),
  };
}

// ── INVESTIGATION REPORT -- printed for a completed (or unable-to-
//    perform) investigation order. Field labels mirror exactly what
//    the Investigation Workspace saves (investigation-types.js), so
//    the printed report always matches what's on screen. ──
export async function renderInvestigationHtml(orderId) {
  const supabase = await createClient();

  const { data: order, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, doctor_id, visits(patients(uhid, first_name, last_name, mobile, age, gender)), profiles:doctor_id(full_name))')
    .eq('id', orderId)
    .single();
  if (error || !order) return { error: 'Investigation not found.' };

  const [{ data: completedBy }, { data: verifiedBy }] = await Promise.all([
    order.completed_by ? supabase.from('profiles').select('full_name').eq('id', order.completed_by).maybeSingle() : Promise.resolve({ data: null }),
    order.verified_by ? supabase.from('profiles').select('full_name').eq('id', order.verified_by).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const settings = await getHospitalSettings();
  const patient = order.encounters?.visits?.patients;
  const type = matchInvestigationType(order.name);
  const fields = getFullFieldValues(type, order.result_data);

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    investigation_name: order.name, investigation_type: type, eye: order.eye,
    doctor_name: order.encounters?.profiles?.full_name || '--',
    ordered_date: fmtDate(order.created_at), completed_date: order.completed_at ? fmtDate(order.completed_at) : '--',

    isUnable: order.status === 'Cancelled' && !!order.unable_reason,
    unable_reason: order.unable_reason,

    hasFields: fields.length > 0,
    fields,

    hasNotes: !!order.result_notes,
    result_notes: order.result_notes,

    technician_name: completedBy?.full_name || '--',
    hasVerifiedBy: !!verifiedBy?.full_name,
    verified_by_name: verifiedBy?.full_name || null,
  };

  const template = await getPrintTemplate('investigation_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICINE PRESCRIPTION -- printed from Pharmacy, independent of
//    the bill. This is the patient-facing dosage sheet: what to take,
//    how much, how often (in plain language, not medical shorthand),
//    and for how long -- not prices or invoice numbers. Reuses the
//    same plainFrequency()/groupPrescriptionsForPrint() logic as the
//    OPD Case Sheet's own Prescription section, so the two always
//    read identically wherever a patient sees them. ──
export async function renderMedicinePrescriptionHtml(visitId) {
  const supabase = await createClient();

  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, doctor_id, patients(uhid, first_name, last_name, age, gender, mobile), profiles:doctor_id(full_name, registration_no)')
    .eq('id', visitId)
    .single();
  if (error || !visit) return { error: 'Visit not found.' };

  const { data: rows } = await supabase
    .from('prescriptions')
    .select('drug_name, eye, dosage, frequency, duration, taper_group_id, taper_step, encounters!inner(visit_id)')
    .eq('encounters.visit_id', visitId)
    .order('created_at', { ascending: true });

  const prescriptions = groupPrescriptionsForPrint(
    (rows || []).map((r) => ({ drug: r.drug_name, eye: r.eye, dosage: r.dosage, frequency: r.frequency, duration: r.duration, taper_group_id: r.taper_group_id, taper_step: r.taper_step }))
  );

  const settings = await getHospitalSettings();
  const patient = visit.patients;

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid || '--', patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_mobile: patient?.mobile || '--',
    visit_number: visit.visit_number || '--',
    print_date: fmtDate(new Date().toISOString()),

    doctor_name: visit.profiles?.full_name || '--',
    doctor_regn_no: visit.profiles?.registration_no || '--',

    hasPrescriptions: prescriptions.length > 0,
    prescriptions,
  };

  const template = await getPrintTemplate('medicine_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}
FILEEOF_print_templates_actions_js

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
