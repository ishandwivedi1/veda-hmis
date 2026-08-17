#!/bin/bash
set -e
echo "Deploying: Surgical Journey - unlock steps 2-7 on patient assent, lock check-in/intraop until Payment"

cat > "app/(main)/counselling/actions.js" << 'VEDA_EOF_1'
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

// ── Package selection -- no longer hard-gated on Biometry being
// Measured first (Surgical Journey unlocks this as soon as the patient
// has given assent in Step 1; Counselling's own flow picks a package
// even earlier, alongside deciding). Each module enforces its own
// UI-level gate; this action stays permissive so it works for both.
// discount is an absolute Rs. amount off the package's list price,
// recorded alongside the selection since it's decided at the same
// moment ("sometimes we need to give discount also"). Net payable
// (price - discount) is what the Payment step checks the collected
// advance against. ──
export async function selectPackage(caseId, packageId, discount = 0) {
  const supabase = await createClient();
  const disc = Number(discount) || 0;
  if (disc < 0) return { error: 'Discount cannot be negative.' };

  const { data: sc } = await supabase.from('surgical_cases').select('patient_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: pkg } = await supabase.from('master_packages').select('price').eq('id', packageId).single();
  if (pkg && disc > Number(pkg.price)) return { error: 'Discount cannot exceed the package price.' };

  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId, package_locked: true, package_discount: disc }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Change an already-locked package's discount without changing the
// package itself (e.g. management approves a bigger discount later).
// Always requires a reason -- same audit-trail pattern as changePackage
// and setDecision -- logged as a case note. ──
export async function updatePackageDiscount(caseId, discount, reason) {
  const supabase = await createClient();
  const disc = Number(discount);
  if (Number.isNaN(disc) || disc < 0) return { error: 'Enter a valid discount amount.' };
  if (!reason || !reason.trim()) return { error: 'A reason is required to change the discount.' };

  const { data: sc } = await supabase
    .from('surgical_cases')
    .select('package_id, package_discount, master_packages:package_id(name, price)')
    .eq('id', caseId)
    .single();
  if (!sc?.package_id) return { error: 'No package selected for this case.' };
  if (disc > Number(sc.master_packages.price)) return { error: 'Discount cannot exceed the package price.' };

  const { error } = await supabase.from('surgical_cases').update({ package_discount: disc }).eq('id', caseId);
  if (error) return { error: error.message };

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: `Package discount changed from Rs.${Number(sc.package_discount || 0).toLocaleString('en-IN')} to Rs.${disc.toLocaleString('en-IN')} (${sc.master_packages?.name || 'package'}) -- Reason: ${reason.trim()}`,
    created_by: userData?.user?.id || null,
  });
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

  const { error } = await supabase.from('surgical_cases').update({ package_id: null, package_locked: false, package_discount: 0 }).eq('id', caseId);
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

// Medical fitness enters the workflow automatically once an OT date is
// booked (see ensureFitnessReferral / bookOTSlot above) -- no manual
// "Refer to Doctor" step needed anywhere.

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
  // Medical Fitness clearance now happens *after* the OT date is
  // booked (closer to the actual surgery date is more clinically
  // useful than clearing weeks in advance), so it's intentionally not
  // gated here anymore -- see FitnessSection in Surgical Journey.

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

// Shared core used both by the (now-removed-from-UI) manual referral
// path and by the auto-referral that fires once an OT date is booked.
async function ensureFitnessReferral(supabase, caseId) {
  const { data: sc } = await supabase.from('surgical_cases').select('visit_id, encounter_id, fitness_required').eq('id', caseId).single();
  if (!sc || sc.fitness_required === false) return;

  const { data: existing } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0 && (existing[0].status === 'Pending Review' || existing[0].status === 'Cleared')) return;

  const { data: userData } = await supabase.auth.getUser();

  if (existing && existing.length > 0 && existing[0].status === 'Not Fit') {
    await supabase.from('medical_fitness_referrals').update({
      status: 'Pending Review', referred_by: userData?.user?.id || null, referred_at: new Date().toISOString(),
      reviewing_doctor_id: null, fitness_notes: null, cleared_by: null, cleared_at: null,
    }).eq('id', existing[0].id);
    return;
  }

  await supabase.from('medical_fitness_referrals').insert({
    surgical_case_id: caseId, visit_id: sc.visit_id, encounter_id: sc.encounter_id, referred_by: userData?.user?.id || null,
    referred_at: new Date().toISOString(), status: 'Pending Review',
  });
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

  // Medical Fitness now enters the workflow automatically once a
  // surgery date exists, instead of needing a separate "Refer to
  // Doctor" click -- closer to the actual surgery date is when
  // clearance is clinically useful anyway.
  await ensureFitnessReferral(supabase, caseId);

  return { success: true };
}



VEDA_EOF_1

mkdir -p "app/(main)/surgical-journey/[id]"
cat > "app/(main)/surgical-journey/[id]/workspace.js" << 'VEDA_EOF_2'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import {
  getSurgicalCaseDetail,
  setIolOrderNotes, editSurgicalCaseDetails, setTreatmentInstructions,
  getInvestigationOptionsForCase, addInHouseInvestigationForCase, removeInHouseInvestigationForCase,
  addExternalTest, removeExternalTest,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
  setDecision, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
} from '@/app/(main)/counselling/actions';
import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
import { openPopup } from '@/lib/popup';

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
          {sc.surgery_code && <div style={{ fontSize: 11, opacity: 0.75, marginTop: 2 }}><i className="ti ti-hash"></i> {sc.surgery_code}</div>}
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

  // Net payable for the Payment step = package list price minus
  // whatever discount was recorded at Package Selection. Advance
  // balance is the patient's live held-advance total (M11), not the
  // old advance_payment_id flag, which nothing in the app ever
  // actually set.
  const netPackageAmount = sc.master_packages ? Math.max(0, Number(sc.master_packages.price) - Number(sc.package_discount || 0)) : 0;
  const advanceBalance = Number(data.advanceBalance || 0);

  // Drives the "Next Step" highlight -- the first not-yet-done stage in
  // the natural order gets the full-color treatment, everything else
  // stays normal. Reports and Notes aren't part of this sequence (they
  // don't have a natural "done" state -- reports trickle in whenever,
  // notes are an ongoing log), so they're excluded.
  const stepDone = {
    decision: sc.decision === 'Accepted',
    investigations: data.biometryRecords.length > 0,
    package: !!sc.package_id,
    iolApproval: data.iolApproval?.status === 'Approved',
    iol: !!data.otSchedule,
    fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
    payment: netPackageAmount > 0 && advanceBalance >= netPackageAmount - 0.01,
    checkin: !!data.checkinCompletedAt,
    intraop: !!data.recoveryEpisode?.discharge_date,
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

      {/* 1. PATIENT DECISION -- the very first step. Once the patient
          gives assent (Accepted), Investigations through Payment (steps
          2-7) all unlock together -- no interdependency between them.
          Patient Check-In and beyond stay locked until Payment is
          complete. */}
      <DecisionSection sc={sc} onAction={flash} active={currentStep === 'decision'} />

      {/* 2. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} inHouseInvestigations={data.inHouseInvestigations} externalTests={data.externalTests} onAction={flash} active={currentStep === 'investigations'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} onAction={flash} active={currentStep === 'package'} />

      {/* 4. IOL APPROVAL -- separate module: surgeon's final brand/power
          sign-off, based on Biometry's device recommendations. */}
      <IolApprovalSection sc={sc} iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />

      {/* 5. IOL PROCUREMENT + DATE + BOOK */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} iolApproval={data.iolApproval} onAction={flash} active={currentStep === 'iol'} num={5} />

      {/* 6. MEDICAL FITNESS -- comes after the surgery date is booked
          (pre-anaesthesia clearance closer to the actual surgery date
          is more clinically useful than clearing weeks in advance). */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={6} />

      {/* 7. PAYMENT */}
      <Section num={7} color="var(--teal)" title="Payment" done={stepDone.payment} active={currentStep === 'payment'}>
        {sc.decision !== 'Accepted' ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
        ) : !sc.master_packages ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Select a package first to determine the amount payable.</div>
        ) : (
          <div>
            <div style={{ background: 'var(--g50)', borderRadius: 8, padding: 10, marginBottom: 10, fontSize: 12.5 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>Package price</span><span>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
              </div>
              {Number(sc.package_discount || 0) > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)' }}>
                  <span>Discount</span><span>&minus; Rs.{Number(sc.package_discount).toLocaleString('en-IN')}</span>
                </div>
              )}
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, borderTop: '1px solid var(--g200)', marginTop: 6, paddingTop: 6 }}>
                <span>Net payable</span><span>Rs.{netPackageAmount.toLocaleString('en-IN')}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6 }}>
                <span>Advance received</span><span style={{ fontWeight: 600, color: 'var(--purple)' }}>Rs.{advanceBalance.toLocaleString('en-IN')}</span>
              </div>
            </div>
            {stepDone.payment ? (
              <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Paid in full.</div>
            ) : (
              <div>
                <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>
                  Balance due: <strong style={{ color: 'var(--amber)' }}>Rs.{Math.max(0, netPackageAmount - advanceBalance).toLocaleString('en-IN')}</strong>
                </div>
                <button
                  className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
                  onClick={() => router.push(`/payments/advance?patientId=${patient.id}&amount=${Math.max(0, netPackageAmount - advanceBalance)}&returnTo=surgical-journey`)}
                >
                  <i className="ti ti-cash"></i> Collect Advance
                </button>
              </div>
            )}
          </div>
        )}
      </Section>

      {/* 8. PATIENT CHECK-IN */}
      <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} router={router} active={currentStep === 'checkin'} num={8} />

      {/* 9. INTRAOPERATIVE MANAGEMENT */}
      <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'intraop'} num={9} />

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
function FitnessSection({ sc, fitnessReferral, onAction, active, num }) {
  const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';
  if (sc.decision !== 'Accepted') {
    return (
      <Section num={num} color="var(--red)" title="Medical Fitness" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }
  return (
    <Section num={num} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>
          <i className="ti ti-info-circle"></i> Will appear in the Medical Fitness module automatically once the OT date is booked.
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
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>
            <i className="ti ti-info-circle"></i> Doctor can review again from the <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Medical Fitness module</a>.
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. ──
function IolApprovalSection({ sc, iolApproval, active }) {
  const approved = iolApproval?.status === 'Approved';
  if (sc.decision !== 'Accepted') {
    return (
      <Section num={5} color="var(--indigo)" title="IOL Approval" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }
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
// elsewhere -- add multiple named tests, upload/view each one's report
// separately, and print the whole list as a referral slip). ──
function InvestigationsSection({ sc, biometryRecords, inHouseInvestigations, externalTests, onAction, active }) {
  const [invOptions, setInvOptions] = useState([]);
  const [selectedInv, setSelectedInv] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [extTestName, setExtTestName] = useState('');
  const [expandedTestId, setExpandedTestId] = useState(null);
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
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>In-House Investigations</div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>Anything we do ourselves -- including Biometry, whatever the doctor feels this case needs.</div>
        {inHouseInvestigations.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {inHouseInvestigations.map((inv) => {
              const isBiometry = inv.name.toLowerCase() === 'biometry';
              const bioRecord = isBiometry ? biometryRecords[0] : null;
              return (
                <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
                  <span>{inv.name} -- {inv.eye}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${inv.status === 'Available' ? 'b-green' : inv.status === 'Cancelled' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{inv.status}</span>
                    {isBiometry ? (
                      <a href={bioRecord?.id ? `/biometry/${bioRecord.id}` : '/biometry'} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
                        {bioRecord?.status === 'Measured' ? 'View Report' : 'Open Biometry'}
                      </a>
                    ) : inv.status === 'Available' ? (
                      <a href={`/investigation/${inv.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>View Report</a>
                    ) : inv.status === 'Ordered' ? (
                      <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={() => onAction(removeInHouseInvestigationForCase)(inv.id)}>Remove</button>
                    ) : null}
                  </div>
                </div>
              );
            })}
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
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
          <div style={{ fontWeight: 600, fontSize: 12 }}>External Investigations</div>
          {externalTests.length > 0 && (
            <a href={`/external-investigation-referral-print/${sc.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Referral
            </a>
          )}
        </div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 8 }}>Blood work, HIV test, etc -- not done in-house. Add each test, upload its report whenever it comes back.</div>

        {externalTests.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {externalTests.map((t) => (
              <div key={t.id} style={{ background: 'var(--g50)', borderRadius: 6, marginBottom: 4 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', fontSize: 12, cursor: 'pointer' }} onClick={() => setExpandedTestId(expandedTestId === t.id ? null : t.id)}>
                  <span>{t.test_name}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className="badge b-gray" style={{ fontSize: 10 }}>{t.attachmentCount > 0 ? `${t.attachmentCount} file${t.attachmentCount > 1 ? 's' : ''}` : 'No report yet'}</span>
                    <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={(e) => { e.stopPropagation(); onAction(removeExternalTest)(t.id); }}>Remove</button>
                    <i className={`ti ${expandedTestId === t.id ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
                  </div>
                </div>
                {expandedTestId === t.id && (
                  <div style={{ padding: '0 8px 10px' }}>
                    <AttachmentUploader entityType="external_investigation" entityId={t.id} title="" />
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "CBC", "HIV Test", "RBS"' value={extTestName} onChange={(e) => setExtTestName(e.target.value)} />
          <button
            className="btn btn-sm btn-primary" disabled={!extTestName.trim()}
            onClick={async () => { const r = await onAction(addExternalTest)(sc.id, extTestName); if (!r?.error) setExtTestName(''); }}
          >
            <i className="ti ti-plus"></i> Add Test
          </button>
        </div>
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
  const [loadingPackages, setLoadingPackages] = useState(true);
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [discountInput, setDiscountInput] = useState('');
  const [selecting, setSelecting] = useState(false);
  const [selectError, setSelectError] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changeDiscountInput, setChangeDiscountInput] = useState('');
  const [changing, setChanging] = useState(false);
  const [editingDiscount, setEditingDiscount] = useState(false);
  const [discountEditValue, setDiscountEditValue] = useState('');
  const [discountEditReason, setDiscountEditReason] = useState('');
  const [discountError, setDiscountError] = useState('');
  const [savingDiscount, setSavingDiscount] = useState(false);
  const decided = sc.decision === 'Accepted';

  useEffect(() => {
    if (decided) getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoadingPackages(false); });
  }, [decided, sc.iol_category]);

  if (!decided) {
    return (
      <Section num={3} color="var(--indigo)" title="Package" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }

  const selectedPreview = packages.find((p) => p.id === selectedPackageId);
  const discountNum = Number(discountInput) || 0;
  const netPreview = selectedPreview ? Math.max(0, Number(selectedPreview.price) - discountNum) : null;
  const currentDiscount = Number(sc.package_discount || 0);
  const currentNet = sc.master_packages ? Math.max(0, Number(sc.master_packages.price) - currentDiscount) : 0;

  async function handleSelect() {
    setSelectError('');
    if (!selectedPackageId) { setSelectError('Choose a package first.'); return; }
    if (discountNum < 0) { setSelectError('Discount cannot be negative.'); return; }
    setSelecting(true);
    const result = await onAction(selectPackage)(sc.id, selectedPackageId, discountNum);
    setSelecting(false);
    if (result?.error) { setSelectError(result.error); return; }
    setDiscountInput('');
  }

  async function handleSaveDiscount() {
    setDiscountError('');
    if (!discountEditReason.trim()) { setDiscountError('Reason is required.'); return; }
    setSavingDiscount(true);
    const result = await onAction(updatePackageDiscount)(sc.id, Number(discountEditValue) || 0, discountEditReason);
    setSavingDiscount(false);
    if (result?.error) { setDiscountError(result.error); return; }
    setEditingDiscount(false); setDiscountEditReason('');
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package" done={!!sc.package_id} defaultOpen={decided && !sc.package_id} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Package</div>
        {sc.master_packages ? (
          <div>
            <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, marginBottom: (changing || editingDiscount) ? 8 : 0 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontWeight: 600, fontSize: 12.5 }}>{sc.master_packages.name}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
                  {!changing && !editingDiscount && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
                </div>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, color: 'var(--g600)' }}>
                <span>Discount: {currentDiscount > 0 ? `Rs.${currentDiscount.toLocaleString('en-IN')}` : 'None'}</span>
                <span style={{ fontWeight: 700 }}>Net: Rs.{currentNet.toLocaleString('en-IN')}</span>
              </div>
              {!changing && !editingDiscount && (
                <button className="btn btn-sm" style={{ marginTop: 6 }} onClick={() => { setEditingDiscount(true); setDiscountEditValue(currentDiscount || ''); }}>
                  <i className="ti ti-percentage"></i> Edit discount
                </button>
              )}
            </div>

            {editingDiscount && (
              <div>
                {discountError && <div className="msg-err" style={{ marginBottom: 8 }}>{discountError}</div>}
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount amount (Rs.)" value={discountEditValue} onChange={(e) => setDiscountEditValue(e.target.value)} />
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for discount change..." value={discountEditReason} onChange={(e) => setDiscountEditReason(e.target.value)} />
                  <button className="btn btn-sm btn-primary" disabled={savingDiscount} onClick={handleSaveDiscount}>
                    {savingDiscount ? 'Saving...' : 'Save'}
                  </button>
                  <button className="btn btn-sm" onClick={() => { setEditingDiscount(false); setDiscountError(''); }}>Cancel</button>
                </div>
              </div>
            )}

            {changing && (
              <div>
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a new package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={changeDiscountInput} onChange={(e) => setChangeDiscountInput(e.target.value)} />
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                  <button
                    className="btn btn-sm btn-primary"
                    disabled={!selectedPackageId || !changeReason.trim()}
                    onClick={async () => {
                      const r = await onAction(changePackage)(sc.id, changeReason);
                      if (r?.error) return;
                      await onAction(selectPackage)(sc.id, selectedPackageId, Number(changeDiscountInput) || 0);
                      setChanging(false); setChangeReason(''); setSelectedPackageId(''); setChangeDiscountInput('');
                    }}
                  >
                    Confirm Change
                  </button>
                  <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); setChangeDiscountInput(''); }}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        ) : loadingPackages ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>
        ) : (
          <div>
            {selectError && <div className="msg-err" style={{ marginBottom: 8 }}>{selectError}</div>}
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
              Packages from Financial Masters &gt; Surgery.
            </div>
            {packages.length === 0 ? (
              <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)', background: 'var(--g50)', borderRadius: 8 }}>
                No active packages found. Add one under Financial Masters &gt; Surgery.
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
                  <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={discountInput} onChange={(e) => setDiscountInput(e.target.value)} />
                  <button className="btn btn-sm btn-primary" disabled={!selectedPackageId || selecting} onClick={handleSelect}>
                    <i className="ti ti-check"></i> {selecting ? 'Selecting...' : 'Select'}
                  </button>
                </div>
                {selectedPreview && (
                  <div style={{ border: '1.5px solid var(--g200)', borderRadius: 8, padding: 10 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
                        {selectedPreview.name}
                        {selectedPreview.origin && <span className={`badge ${selectedPreview.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{selectedPreview.origin}</span>}
                      </div>
                      <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(selectedPreview.price).toLocaleString('en-IN')}</div>
                    </div>
                    {selectedPreview.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{selectedPreview.includes}</div>}
                    {discountNum > 0 && (
                      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, paddingTop: 6, borderTop: '1px solid var(--g200)' }}>
                        <span style={{ color: 'var(--red)' }}>Discount: Rs.{discountNum.toLocaleString('en-IN')}</span>
                        <span style={{ fontWeight: 700 }}>Net: Rs.{netPreview.toLocaleString('en-IN')}</span>
                      </div>
                    )}
                  </div>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </Section>
  );
}

// ── 4. IOL PROCUREMENT + DATE + BOOK SLOT ──────────────────────────
function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, num }) {
  const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [sessionName, setSessionName] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  // The date+session picker lives in the OT Schedule module's own
  // Calendar tab (prior bookings visible there, one place instead of
  // duplicating a calendar here) -- opened as a real popup window, and
  // the chosen slot comes back via postMessage instead of a page
  // redirect, since this is a multi-step form the user shouldn't lose.
  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== 'ot-slot-picked' || e.data.caseId !== sc.id) return;
      setDate(e.data.date);
      setSessionId(e.data.sessionId);
      setSessionName(e.data.sessionName || '');
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [sc.id]);

  function openCalendarPicker() {
    const label = encodeURIComponent(`${sc.patients?.first_name || ''} ${sc.patients?.last_name || ''} -- ${sc.procedure_name || ''} (${sc.eye || ''})`.trim());
    openPopup(`/ot-calendar-picker?pickFor=${sc.id}&pickLabel=${label}`, `ot-calendar-${sc.id}`, { width: 460, height: 680 });
  }

  const canBook = sc.status === 'Ready for Scheduling';
  const readyGateMet = sc.decision === 'Accepted';

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
            <div style={{ marginBottom: 8 }}>
              {date ? (
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
                  <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
                  <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
                </div>
              ) : (
                <button className="btn btn-sm" onClick={openCalendarPicker}>
                  <i className="ti ti-calendar"></i> Open OT Calendar
                </button>
              )}
            </div>
            {date && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Session</label>
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
            )}
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
              <button
                className="btn btn-sm btn-primary"
                disabled={!date || !sessionId || !rescheduleReason.trim()}
                onClick={async () => {
                  const r = await onAction(rescheduleOTSlot)(otSchedule.id, date, sessionId, rescheduleReason);
                  if (r?.error) return;
                  setRescheduling(false); setRescheduleReason(''); setDate(''); setSessionId(''); setSessionName('');
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
          <i className="ti ti-info-circle"></i> Waiting on Patient Decision first.
        </div>
      )}

      {readyGateMet && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 8, marginBottom: 10 }}>
            <div>
              <label className="flbl">Surgeon</label>
              <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                <option value="">--</option>
                {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </div>
          </div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Date</label>
            {date ? (
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
                <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
                <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
              </div>
            ) : (
              <button className="btn btn-sm" onClick={openCalendarPicker}>
                <i className="ti ti-calendar"></i> Open OT Calendar
              </button>
            )}
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

// ── 7. PATIENT CHECK-IN (live status, deep-link only) ──
function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, router, active, num }) {
  if (!paymentDone) {
    return (
      <Section num={num} color="var(--g400)" title="Patient Check-In" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Complete Payment first.</div>
      </Section>
    );
  }

  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;
  const done = !!checkinCompletedAt;

  if (otSchedule) {
    if (done) {
      status = 'Checked in';
      color = 'var(--green)';
      action = { label: 'View in Patient Check-In', onClick: () => router.push('/patient-checkin') };
    } else {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- not yet checked in`;
      color = 'var(--blue)';
      action = { label: 'Open in Patient Check-In', onClick: () => router.push('/patient-checkin') };
    }
  }

  return (
    <Section num={num} color={color} title="Patient Check-In" done={done} defaultOpen={!!otSchedule && !done} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, and pre-op checklist all happen in the Patient Check-In module -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── 8. INTRAOPERATIVE MANAGEMENT (live status, deep-links only -- OT
// Intraop and Recovery remain their own solid clinical workflows;
// Recovery/Post-Op are a natural continuation of this same chain, so
// their status is shown here too rather than yet another section) ──
function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpisode, router, active, num }) {
  let status = 'Waiting on Patient Check-In';
  let color = 'var(--g400)';
  let action = null;
  const locked = !checkinCompletedAt;

  if (otSchedule && checkinCompletedAt) {
    if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in Intraoperative Management', onClick: () => router.push('/ot-intraop') };
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
    } else {
      status = 'Checked in -- ready for OT';
      color = 'var(--blue)';
      action = { label: 'Open in Intraoperative Management', onClick: () => router.push('/ot-intraop') };
    }
  }

  return (
    <Section num={num} color={color} title="Intraoperative Management" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!checkinCompletedAt} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      {locked ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> Complete Patient Check-In first.</div>
      ) : (
        <>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            The surgery itself and discharge happen in the Intraoperative Management / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
          </div>
          {action && (
            <button className="btn btn-sm btn-primary" onClick={action.onClick}>
              <i className="ti ti-arrow-right"></i> {action.label}
            </button>
          )}
        </>
      )}
    </Section>
  );
}

// ── 9. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
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
VEDA_EOF_2

echo "Files written. No DB migration needed for this change."
echo "Deploy script done."
