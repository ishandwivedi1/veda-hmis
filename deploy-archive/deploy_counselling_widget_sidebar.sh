#!/bin/bash
set -e
echo "Applying: Awaiting Patient Acceptance widget, sidebar heading contrast, remove Workflow Monitor"

cat > "app/(main)/counselling/actions.js" << 'PYEOF_7040182694639437545'
'use server';

import { createClient } from '@/lib/supabase-server';

// This file replaces the old "Surgical Coordination" module's actions file.
// OT Scheduling (formerly its own module at app/(main)/ot-schedule) has been
// merged into Counselling: booking a slot is now the last step of the
// counselling workspace (see bookOTSlot/getOTAvailability below), and the
// OT Calendar (getOTSchedule/completeOT) is now the 3rd tab of this page
// instead of a standalone route.
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

  const { data: sc } = await supabase.from('surgical_cases').select('id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: queueEntry, error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: 'Awaiting Biometry',
    p_audit_message: 'Sent for Biometry (from Counselling)',
    p_user_id: userData?.user?.id || null,
  });
  if (error) return { error: error.message };

  // Also create the biometry_records stub right away (mirrors
  // getOrCreateBiometryRecord in the Biometry module) so the Counselling
  // dashboard reflects "Awaiting Biometry" immediately instead of only
  // after the technician opens the queue entry -- and so the technician
  // finds it already there rather than creating a fresh one.
  const visitId = queueEntry?.visit_id;
  if (visitId) {
    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id')
      .eq('visit_id', visitId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (!existing || existing.length === 0) {
      const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();
      await supabase.from('biometry_records').insert({ visit_id: visitId, encounter_id: sc.encounter_id || null, surgeon_id: visit?.doctor_id || null });
    }
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

  // surgical_cases and biometry_records are siblings linked only by
  // encounter_id (no direct FK Supabase can auto-embed), so this is a
  // separate batch query rather than a nested select. Used to tell
  // "Surgery Advised" (nobody has sent for biometry yet) apart from
  // "Awaiting Biometry" (sent, technician hasn't finished it) on the
  // dashboard -- both are biometry_done = false, but they're different
  // stages for the counsellor.
  const encounterIds = [...new Set((data || []).map((c) => c.encounter_id).filter(Boolean))];
  let biometryByEncounter = {};
  if (encounterIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('id, encounter_id, status')
      .in('encounter_id', encounterIds);
    (records || []).forEach((r) => { biometryByEncounter[r.encounter_id] = r; });
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
    biometry_record: biometryByEncounter[c.encounter_id] || null,
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

// ── Packages, filtered by the IOL type advised at Biometry ──
// iol_category/origin live on master_packages (Master Data, M29). A package
// with iol_category = NULL is not IOL-specific (e.g. Glaucoma surgery) and
// is shown regardless of what was advised. Filtered in JS rather than a
// PostgREST .or() filter to avoid escaping issues with values like
// "Monofocal Toric" that contain a space.
export async function getPackagesForCase(iolCategory) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return (data || []).filter((p) => !p.iol_category || p.iol_category === iolCategory);
}

// ── Package selection (BR-SCC-002: only after Biometry & IOL advice) ──
export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('biometry_done, biometry_required').eq('id', caseId).single();
  if (!sc?.biometry_done && sc?.biometry_required !== false) {
    return { error: 'BR-SCC-002: Biometry & IOL type advice must be complete before selecting a package.' };
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

  if (!sc.biometry_done && sc.biometry_required !== false) return { error: 'VAL-SCC-002: Biometry & IOL type advice must be complete.' };
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

// ── OT Calendar -- now the 3rd tab of the Counselling module (was the
//    standalone /ot-schedule page). ──
export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles!ot_schedule_surgeon_id_fkey(full_name)')
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data;
}

export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

PYEOF_7040182694639437545

cat > "app/(main)/counselling/page.js" << 'PYEOF_554951404225466407'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getCounsellingCases, getCounsellingHistory, getPackagesForCase, selectPackage, changePackage,
  setDecision, getCaseNotes, addCaseNote, getCounsellingItems, toggleCounsellingItem,
  markReadyForScheduling, referBackToDoctor,
  referForMedicalFitness,
  sendForBiometry, skipBiometry, unskipBiometry,
  getSurgeons, getOTAvailability, bookOTSlot, getOTSchedule, completeOT,
} from './actions';

// Biometry is satisfied either by actually being done, or by having
// been explicitly marked not required for this case (retina, glaucoma,
// oculoplasty...). Every gate that used to check biometry_done alone
// now goes through this.
function biometrySatisfied(sc) {
  return sc.biometry_done || sc.biometry_required === false;
}

function fitnessSatisfied(sc) {
  return sc.fitness_cleared || sc.fitness_required === false;
}

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function readiness(sc) {
  const items = [
    { key: 'surgeryRec', label: 'Surgery Recommended', done: true },
    { key: 'biometry', label: sc.biometry_required === false ? 'Biometry & IOL Type Advised (M23) -- Skipped' : 'Biometry & IOL Type Advised (M23)', done: biometrySatisfied(sc) },
    { key: 'fitness', label: sc.fitness_required === false ? 'Medical Fitness -- Not Required' : 'Medical Fitness', done: fitnessSatisfied(sc) },
    { key: 'advance', label: 'Advance Payment', done: !!sc.advance_payment_id },
  ];
  const done = items.filter((i) => i.done).length;
  return { items, pct: Math.round((done / items.length) * 100) };
}

function PackagePicker({ sc, onUpdate }) {
  const [packages, setPackages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!biometrySatisfied(sc)) { setLoading(false); return; }
    getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoading(false); });
  }, [sc.biometry_done, sc.biometry_required, sc.iol_category]);

  if (!biometrySatisfied(sc)) {
    return (
      <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 12.5, background: 'var(--g50)', borderRadius: 'var(--r)' }}>
        <i className="ti ti-lock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }}></i>
        Complete Biometry &amp; IOL type advice (M23) before presenting packages.
      </div>
    );
  }

  if (sc.master_packages) {
    return (
      <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{sc.master_packages.name}</div>
          <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 14 }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</div>
        </div>
        {sc.package_locked && (
          <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 6 }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</div>
        )}
        {error && <div className="msg-err" style={{ marginTop: 8 }}>{error}</div>}
        <button
          className="btn btn-sm"
          style={{ marginTop: 8 }}
          onClick={async () => {
            setError('');
            let reason = null;
            if (sc.package_locked) {
              reason = window.prompt(`Package is locked (currently "${sc.master_packages.name}"). Enter a reason to change it:`);
              if (reason === null) return;
              if (!reason.trim()) { setError('A reason is required to change a locked package.'); return; }
            }
            const result = await changePackage(sc.id, reason);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
        >
          Change package
        </button>
      </div>
    );
  }

  if (loading) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
        Showing packages for IOL type: <strong>{sc.iol_category}</strong> (from Master Data)
      </div>
      {packages.length === 0 && (
        <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)' }}>
          No packages found for IOL type "{sc.iol_category}" in Master Data. Add one under Financial Masters &gt; Packages.
        </div>
      )}
      {packages.map((p) => (
        <button
          key={p.id}
          onClick={async () => {
            setError('');
            const result = await selectPackage(sc.id, p.id);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
          style={{ display: 'block', width: '100%', textAlign: 'left', border: '1.5px solid var(--g200)', borderRadius: 'var(--r)', padding: 12, marginBottom: 8, background: '#fff', cursor: 'pointer', fontFamily: 'inherit' }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
              {p.name}
              {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{p.origin}</span>}
            </div>
            <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(p.price).toLocaleString('en-IN')}</div>
          </div>
          {p.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{p.includes}</div>}
        </button>
      ))}
    </div>
  );
}

function EducationPanel({ encounterId }) {
  const [items, setItems] = useState([]);

  const refresh = useCallback(() => {
    getCounsellingItems(encounterId).then(setItems);
  }, [encounterId]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-book" style={{ color: 'var(--teal)' }}></i> Patient education</div></div>
      {items.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No education topics logged from the doctor's plan.</div>}
      {items.map((item) => (
        <button
          key={item.id}
          onClick={async () => { await toggleCounsellingItem(item.id, item.status !== 'Done'); refresh(); }}
          style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', padding: '6px 4px', background: 'none', border: 'none', cursor: 'pointer', fontFamily: 'inherit', fontSize: 12.5 }}
        >
          <span style={{
            width: 16, height: 16, borderRadius: 4, border: '1.5px solid var(--g300)',
            background: item.status === 'Done' ? 'var(--teal)' : '#fff', borderColor: item.status === 'Done' ? 'var(--teal)' : 'var(--g300)',
            color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, flexShrink: 0,
          }}>
            {item.status === 'Done' ? '✓' : ''}
          </span>
          {item.topic}
        </button>
      ))}
    </div>
  );
}

function NotesPanel({ caseId }) {
  const [notes, setNotes] = useState([]);
  const [text, setText] = useState('');

  const refresh = useCallback(() => { getCaseNotes(caseId).then(setNotes); }, [caseId]);
  useEffect(() => { refresh(); }, [refresh]);

  async function handleSave() {
    if (!text.trim()) return;
    await addCaseNote(caseId, text);
    setText('');
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Counselling notes</div></div>
      <textarea className="fi" rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="e.g. Patient wants surgery after 1 week..." />
      <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSave}>Save note</button>
      <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
        {notes.map((n) => (
          <div key={n.id} style={{ fontSize: 11, background: 'var(--g50)', borderRadius: 'var(--r)', padding: '6px 8px' }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' })} -- {n.profiles?.full_name || 'Staff'}: </span>
            {n.note}
          </div>
        ))}
      </div>
    </div>
  );
}

// Numbered, collapsible section -- same visual pattern as AsmtSection in
// Optometry History ([assessmentId]/assessment-viewer.js): numbered
// colored circle, title, chevron toggle.
function CounsellingSection({ num, color, title, badge, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {badge}
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

// ── Book Surgery Slot -- last step of Counselling, replaces the old
//    standalone OT Scheduling module. Picking a date loads that date's OT
//    sessions (Morning/Midday/Afternoon etc, from Financial Masters) with
//    live booked/remaining counts so the counsellor books strictly within
//    capacity. ──
function BookSurgerySlot({ sc, onUpdate }) {
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [notes, setNotes] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [booking, setBooking] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleBook() {
    setError('');
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setBooking(true);
    const result = await bookOTSlot(sc.id, date, sessionId, surgeonId, notes);
    setBooking(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 10 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">-- Surgeon --</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Surgery Date</label>
          <input type="date" className="fi" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
      </div>

      {date && (
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      borderColor: selected ? 'transparent' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}
                    </div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      <input className="fi" placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} style={{ marginBottom: 10 }} />

      <button className="btn btn-primary btn-sm" onClick={handleBook} disabled={booking || !date || !sessionId}>
        {booking ? 'Booking...' : 'Confirm Surgery Slot'}
      </button>
    </div>
  );
}

function CaseWorkspace({ sc, onUpdate }) {
  const [error, setError] = useState('');
  const [ancillaryMsg, setAncillaryMsg] = useState(null); // { type: 'error'|'success', text }
  const [sendingBiometry, setSendingBiometry] = useState(false);
  const [openSections, setOpenSections] = useState({ surgery: true, biometry: true, decision: true, fitness: true });
  const { items, pct } = readiness(sc);
  const stage2Unlocked = !!sc.package_id && sc.decision === 'Accepted';
  const [referringFitness, setReferringFitness] = useState(false);

  async function handleReferFitness() {
    setError('');
    setReferringFitness(true);
    const result = await referForMedicalFitness(sc.id);
    setReferringFitness(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleDecision(d) {
    setError('');
    let reason = null;
    if (sc.decision_locked && d !== sc.decision) {
      reason = window.prompt(`Decision is locked (currently "${sc.decision}"). Enter a reason to change it to "${d}":`);
      if (reason === null) return; // cancelled
      if (!reason.trim()) { setError('A reason is required to change a locked decision.'); return; }
    }
    const result = await setDecision(sc.id, d, reason);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleSendForBiometry() {
    setAncillaryMsg(null);
    setSendingBiometry(true);
    const result = await sendForBiometry(sc.id);
    setSendingBiometry(false);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    setAncillaryMsg({ type: 'success', text: 'Sent -- patient will show as Awaiting Biometry in the Biometry queue.' });
    onUpdate();
  }

  async function handleSkipBiometry() {
    const reason = window.prompt('Why is Biometry not required for this case? (e.g. Retina surgery -- no IOL power needed)');
    if (reason === null) return;
    setAncillaryMsg(null);
    const result = await skipBiometry(sc.id, reason);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  async function handleUnskipBiometry() {
    setAncillaryMsg(null);
    const result = await unskipBiometry(sc.id);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  const advancePaid = !!sc.advance_payment_id;
  const fitnessItem = items.find((i) => i.key === 'fitness');

  return (
    <div style={{ marginBottom: 16 }}>
      {/* PATIENT STRIP -- fixed at top of the workspace, same visual language as Optometry History */}
      <div style={{
        position: 'sticky', top: 0, zIndex: 5,
        background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '12px 16px', color: '#fff',
        marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14,
      }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {sc.patients?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{sc.patients?.first_name} {sc.patients?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{sc.patients?.age} -- {sc.patients?.gender} -- {sc.patients?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.procedure_name} -- {sc.eye}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.priority}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.profiles?.full_name || 'Unassigned surgeon'}
            </span>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>IOL Type Advised</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc.iol_category || (sc.biometry_required === false ? 'Not applicable' : 'Pending biometry')}</div>
          <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`} style={{ marginTop: 4 }}>{sc.status}</span>
          <div style={{ fontSize: 10, opacity: .7, marginTop: 4 }}>{pct}% ready</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {/* 1. SURGERY ADVISED */}
      <CounsellingSection num={1} color="var(--g500)" title="Surgery Advised" open={openSections.surgery} onToggle={() => toggleSection('surgery')}
        badge={<span className="badge b-green"><i className="ti ti-check"></i> Done</span>}>
        <div style={{ fontSize: 12.5, color: 'var(--g600)' }}>
          <div><strong>{sc.procedure_name}</strong> -- {sc.eye} -- {sc.priority}</div>
          <div style={{ color: 'var(--g500)', marginTop: 4 }}>Surgeon: {sc.profiles?.full_name || 'Unassigned'}</div>
        </div>
      </CounsellingSection>

      {/* 2. BIOMETRY */}
      <CounsellingSection num={2} color="var(--blue)" title="Biometry" open={openSections.biometry} onToggle={() => toggleSection('biometry')}
        badge={
          sc.biometry_done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : sc.biometry_required === false
            ? <span className="badge b-purple">Not Required</span>
            : sc.biometry_record
            ? <span className="badge b-blue">Awaiting Technician</span>
            : <span className="badge b-amber">Not sent</span>
        }>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {sc.biometry_done ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Biometry Complete -- {sc.iol_category}</span>
          ) : sc.biometry_required === false ? (
            <>
              <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required -- {sc.biometry_skip_reason}</span>
              <button className="btn btn-sm" onClick={handleUnskipBiometry} style={{ fontSize: 11 }}>Undo -- make required again</button>
            </>
          ) : sc.biometry_record ? (
            <>
              <span className="badge b-blue"><i className="ti ti-clock"></i> Biometry Requested -- Awaiting Technician</span>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry} style={{ fontSize: 11 }}>
                {sendingBiometry ? 'Sending...' : 'Send again'}
              </button>
            </>
          ) : (
            <>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry}>
                <i className="ti ti-ruler-measure"></i> {sendingBiometry ? 'Sending...' : 'Send for Biometry'}
              </button>
              <button className="btn btn-sm" onClick={handleSkipBiometry} style={{ fontSize: 11 }}>
                <i className="ti ti-player-skip-forward"></i> Not required for this surgery
              </button>
            </>
          )}
          {ancillaryMsg && (
            <span style={{ fontSize: 11.5, color: ancillaryMsg.type === 'error' ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>
              {ancillaryMsg.text}
            </span>
          )}
        </div>
      </CounsellingSection>

      {/* 3. PATIENT DECISION -- package + decision, with Advance Payment as a sub-point */}
      <CounsellingSection num={3} color="var(--purple)" title="Patient Decision" open={openSections.decision} onToggle={() => toggleSection('decision')}
        badge={
          sc.decision === 'Accepted'
            ? <span className="badge b-green"><i className="ti ti-check"></i> Accepted</span>
            : sc.decision
            ? <span className="badge b-amber">{sc.decision}</span>
            : <span className="badge b-gray">Pending</span>
        }>
        <div style={{ marginBottom: 16 }}>
          <label className="flbl">Package</label>
          <PackagePicker sc={sc} onUpdate={onUpdate} />
        </div>

        <div style={{ marginBottom: 16 }}>
          <label className="flbl">
            Decision {sc.decision_locked && <span style={{ color: 'var(--amber)', fontWeight: 400, textTransform: 'none' }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</span>}
          </label>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {DECISIONS.map((d) => (
              <button
                key={d}
                onClick={() => handleDecision(d)}
                className="btn btn-sm"
                style={sc.decision === d ? {
                  background: d === 'Accepted' ? 'var(--green)' : d === 'Declined' ? 'var(--red)' : 'var(--purple)',
                  color: '#fff', borderColor: 'transparent',
                } : {}}
              >
                {d}
              </button>
            ))}
          </div>
        </div>

        {/* Sub-point: Advance Payment */}
        <div style={{ borderLeft: '3px solid var(--g200)', paddingLeft: 12, marginTop: 4 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 6 }}>
            3a. Advance Payment
          </div>
          {advancePaid ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Advance Paid</span>
          ) : (
            <span className="badge b-amber">Not yet collected -- via Billing (M11)</span>
          )}
        </div>
      </CounsellingSection>

      {/* 4. MEDICAL FITNESS */}
      <CounsellingSection num={4} color="var(--amber)" title="Medical Fitness" open={openSections.fitness} onToggle={() => toggleSection('fitness')}
        badge={
          fitnessItem?.done && sc.fitness_required === false
            ? <span className="badge b-purple">Not Required</span>
            : fitnessItem?.done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : <span className="badge b-amber">Pending</span>
        }>
        {!stage2Unlocked ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Locked until package confirmed and decision is Accepted.</div>
        ) : sc.fitness_required === false && !sc.fitness_referral ? (
          <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case -- per doctor's advice at consultation</span>
        ) : (
          <>
            {!sc.fitness_referral && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                  Refer this patient to a doctor to review clinical data, order any investigations needed, and clear for surgery.
                </div>
                <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                  <i className="ti ti-heart-rate-monitor"></i> {referringFitness ? 'Referring...' : 'Refer to Doctor'}
                </button>
              </div>
            )}
            {sc.fitness_referral?.status === 'Pending Review' && (
              <span className="badge b-amber"><i className="ti ti-clock"></i> Referred to doctor -- awaiting review ({new Date(sc.fitness_referral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })})</span>
            )}
            {sc.fitness_referral?.status === 'Cleared' && (
              <div>
                <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
              </div>
            )}
            {sc.fitness_referral?.status === 'Not Fit' && (
              <div>
                <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
                <div style={{ marginTop: 8 }}>
                  <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                    <i className="ti ti-refresh"></i> {referringFitness ? 'Referring...' : 'Refer Again'}
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </CounsellingSection>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <EducationPanel encounterId={sc.encounter_id} />
        <NotesPanel caseId={sc.id} />
      </div>

      {/* BOOK SURGERY SLOT -- only once Ready for Scheduling */}
      {sc.status === 'Ready for Scheduling' && (
        <CounsellingSection num="OT" color="var(--indigo)" title="Book Surgery Slot" open onToggle={() => {}}
          badge={<span className="badge b-green"><i className="ti ti-check"></i> Ready</span>}>
          <BookSurgerySlot sc={sc} onUpdate={onUpdate} />
        </CounsellingSection>
      )}

      {sc.status === 'Scheduled' && (
        <div className="msg-success" style={{ marginBottom: 16 }}>
          <i className="ti ti-circle-check"></i> Surgery slot booked -- see the OT Calendar tab.
        </div>
      )}

      <div style={{ display: 'flex', gap: 8 }}>
        <button
          className="btn btn-sm"
          onClick={async () => { await referBackToDoctor(sc.id); onUpdate(); }}
        >
          Refer back to doctor
        </button>
        {sc.status === 'Pending Workup' && (
          <button className="btn btn-primary btn-sm" onClick={handleReady}>Ready for Scheduling (VAL-SCC-002)</button>
        )}
      </div>
    </div>
  );
}

// ── Pre-op counselling stage, derived from real columns (not stored --
//    surgical_cases.status stays limited to Pending Workup / Ready for
//    Scheduling / Scheduled / Completed / Cancelled, since OT Scheduling
//    relies on those exact values). This just groups cases for the
//    dashboard so the counsellor can see where each patient actually is. ──
const STAGES = [
  { key: 'surgery_advised',     label: 'Surgery Advised',                badge: 'b-gray'   },
  { key: 'awaiting_biometry',   label: 'Awaiting Biometry',              badge: 'b-blue'   },
  { key: 'awaiting_package',    label: 'Awaiting Package Presentation',  badge: 'b-teal'   },
  { key: 'awaiting_decision',   label: 'Waiting for Patient Decision',   badge: 'b-amber'  },
  { key: 'financial_constraint',label: 'Financial Constraint',           badge: 'b-red'    },
  { key: 'finalised',           label: 'Finalised -- Prep Pending',      badge: 'b-purple' },
  { key: 'ready',               label: 'Ready for Scheduling',           badge: 'b-green'  },
  { key: 'declined',            label: 'Declined',                       badge: 'b-gray'   },
];
const STAGE_MAP = Object.fromEntries(STAGES.map((s) => [s.key, s]));

function getStage(sc) {
  if (sc.status === 'Ready for Scheduling') return 'ready';
  if (!sc.biometry_done && sc.biometry_required !== false) return sc.biometry_record ? 'awaiting_biometry' : 'surgery_advised';
  if (!sc.package_id) return 'awaiting_package';
  if (sc.decision === 'Declined') return 'declined';
  if (sc.decision === 'Financial Constraint') return 'financial_constraint';
  if (sc.decision === 'Accepted') return 'finalised';
  return 'awaiting_decision'; // null, Wants Time to Decide, Discuss with Family, Second Opinion, Other
}

function daysWaiting(sc) {
  return Math.floor((Date.now() - new Date(sc.created_at).getTime()) / 86400000);
}

function KpiCard({ label, value, sub, color, active, onClick }) {
  return (
    <button
      onClick={onClick}
      className="card"
      style={{ borderLeft: `3px solid ${color}`, marginBottom: 0, textAlign: 'left', cursor: 'pointer', background: active ? 'var(--g50)' : '#fff', fontFamily: 'inherit' }}
    >
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </button>
  );
}

function AwaitingAcceptanceWidget({ cases }) {
  const rows = cases
    .filter((sc) => sc.status === 'Pending Workup' && sc.decision !== 'Accepted' && sc.decision !== 'Declined')
    .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));

  if (rows.length === 0) return null;

  return (
    <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--amber)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-phone-outgoing" style={{ color: 'var(--amber)' }}></i> Awaiting Patient Acceptance
        <span className="badge b-amber" style={{ marginLeft: 8 }}>{rows.length}</span>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Advised surgery but haven&apos;t accepted yet -- call to follow up.
      </div>
      {rows.map((sc) => {
        const dw = daysWaiting(sc);
        return (
          <div key={sc.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ flex: 1, minWidth: 0 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</span>
              {sc.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>{sc.priority}</span>}
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye}
                {sc.decision ? ` -- ${sc.decision}` : ''}
              </div>
            </div>
            <a href={`tel:${sc.patients?.mobile}`} style={{ fontSize: 12.5, fontWeight: 700, color: 'var(--blue)', textDecoration: 'none', whiteSpace: 'nowrap' }}>
              <i className="ti ti-phone"></i> {sc.patients?.mobile || 'No number on file'}
            </a>
            <div style={{ textAlign: 'right', fontSize: 10, color: dw > 7 ? 'var(--red)' : dw > 3 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 60 }}>
              {dw === 0 ? 'Today' : `${dw}d`}
            </div>
          </div>
        );
      })}
    </div>
  );
}

function CounsellingDashboard({ cases, onOpen }) {
  const [stageFilter, setStageFilter] = useState('');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  const counts = STAGES.reduce((acc, s) => { acc[s.key] = 0; return acc; }, {});
  cases.forEach((sc) => { counts[getStage(sc)]++; });

  let rows = cases.map((sc) => ({ sc, stage: getStage(sc) }));
  if (stageFilter) rows = rows.filter((r) => r.stage === stageFilter);
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter(({ sc }) =>
      `${sc.patients?.first_name} ${sc.patients?.last_name}`.toLowerCase().includes(q) ||
      (sc.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  rows.sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.sc.created_at) - new Date(b.sc.created_at);
    if (sortBy === 'newest') return new Date(b.sc.created_at) - new Date(a.sc.created_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.sc.priority] ?? 9) - (order[b.sc.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div>
      <AwaitingAcceptanceWidget cases={cases} />

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
        <KpiCard label="Active cases" value={cases.filter((sc) => sc.status !== 'Ready for Scheduling').length + counts.ready} sub="All pre-op stages" color="var(--indigo)" active={!stageFilter} onClick={() => setStageFilter('')} />
        <KpiCard label="Waiting on patient" value={counts.awaiting_decision + counts.financial_constraint} sub="Decision or finance pending" color="var(--amber)" active={stageFilter === 'awaiting_decision'} onClick={() => setStageFilter('awaiting_decision')} />
        <KpiCard label="Finalised -- prep pending" value={counts.finalised} sub="Accepted, tests/fitness pending" color="var(--purple)" active={stageFilter === 'finalised'} onClick={() => setStageFilter('finalised')} />
        <KpiCard label="Ready for scheduling" value={counts.ready} sub="Go to OT Scheduling" color="var(--green)" active={stageFilter === 'ready'} onClick={() => setStageFilter('ready')} />
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Counselling Queue</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
            <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
              <option value="oldest">Oldest first</option>
              <option value="newest">Newest first</option>
              <option value="priority">Priority</option>
            </select>
          </div>
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
          <button className={`btn btn-sm ${!stageFilter ? 'btn-primary' : ''}`} onClick={() => setStageFilter('')}>All ({cases.length})</button>
          {STAGES.map((s) => (
            <button key={s.key} className={`btn btn-sm ${stageFilter === s.key ? 'btn-primary' : ''}`} onClick={() => setStageFilter(s.key)}>
              {s.label} ({counts[s.key]})
            </button>
          ))}
        </div>

        {rows.map(({ sc, stage }) => {
          const dw = daysWaiting(sc);
          return (
            <div key={sc.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--purple)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {sc.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</span>
                <span className={`badge ${STAGE_MAP[stage].badge}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_MAP[stage].label}</span>
                {sc.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{sc.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.iol_category || 'IOL type pending'} -- {sc.profiles?.full_name || 'Unassigned surgeon'}
                </div>
              </div>
              <div style={{ textAlign: 'right', fontSize: 10, color: dw > 7 ? 'var(--red)' : dw > 3 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                {dw === 0 ? 'Today' : `${dw}d waiting`}
              </div>
              <button className="btn btn-sm btn-primary" onClick={() => onOpen(sc.id)}>
                <i className="ti ti-arrow-right"></i> Open
              </button>
            </div>
          );
        })}

        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {cases.length === 0 ? 'No cases pending counselling. Mark a patient for surgery from their Consultation.' : 'No cases match this filter.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ── OT Calendar tab -- the read-only schedule + Complete action that used
//    to be the whole of the standalone OT Scheduling page. Booking itself
//    now happens inline in each case's workspace (BookSurgerySlot above). ──
function OTCalendar() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setSchedule(await getOTSchedule());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId) {
    await completeOT(otId, caseId);
    refresh();
  }

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading OT calendar...</div>;

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> OT Calendar
      </div>
      <table className="tbl">
        <thead>
          <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {schedule.map((s) => (
            <tr key={s.id}>
              <td>{new Date(s.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
              <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
              <td>{s.room || '--'}</td>
              <td>{s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}</td>
              <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
              <td>{s.profiles?.full_name || '--'}</td>
              <td><span className={`badge ${s.status === 'Completed' ? 'b-green' : 'b-blue'}`}>{s.status}</span></td>
              <td>
                {s.status === 'Scheduled' && (
                  <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id)}>Complete</button>
                )}
              </td>
            </tr>
          ))}
          {schedule.length === 0 && (
            <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

// ── History tab -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled, etc). Read-only lookup, same pattern as the
//    History tabs elsewhere in the app (Post-op, Investigation,
//    Optometry). Opens the same CaseWorkspace as an active case -- its
//    action buttons already only render for statuses that are still
//    actionable, so a past case naturally shows as read-only. ──
function HistoryTab({ cases, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? cases.filter((sc) => {
        const q = search.trim().toLowerCase();
        const p = sc.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : cases;

  const STATUS_BADGE = { Scheduled: 'b-blue', Completed: 'b-green', Cancelled: 'b-red' };

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Counselling History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Decision</th><th>Status</th><th>Date</th><th></th></tr></thead>
          <tbody>
            {filtered.map((sc) => (
              <tr key={sc.id} onClick={() => onOpen(sc.id)} style={{ cursor: 'pointer' }}>
                <td><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{sc.procedure_name} ({sc.eye})</td>
                <td style={{ fontSize: 12 }}>{sc.profiles?.full_name || '--'}</td>
                <td style={{ fontSize: 12 }}>{sc.decision || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[sc.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{sc.status}</span></td>
                <td style={{ fontSize: 11 }}>{sc.created_at ? new Date(sc.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No past cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function CounsellingPage() {
  const [cases, setCases] = useState([]);
  const [historyCases, setHistoryCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);

  const refresh = useCallback(async () => {
    setCases(await getCounsellingCases());
    setLoading(false);
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistoryCases(await getCounsellingHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refresh(); refreshHistory(); }, [refresh, refreshHistory]);

  function openCase(id) {
    setSelectedCaseId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refresh(); refreshHistory();
  }

  const selectedCase = cases.find((sc) => sc.id === selectedCaseId) || historyCases.find((sc) => sc.id === selectedCaseId) || null;

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading counselling cases...</div>;

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 540 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-messages" label="Workspace" disabled={!selectedCase} />
        <TabButton active={activeTab === 'otcalendar'} onClick={() => setActiveTab('otcalendar')} icon="ti-calendar-event" label="OT Calendar" />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <CounsellingDashboard cases={cases} onOpen={openCase} />}

      {activeTab === 'workspace' && selectedCase && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => setActiveTab('dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Dashboard
          </button>
          <CaseWorkspace sc={selectedCase} onUpdate={handleUpdate} />
        </div>
      )}

      {activeTab === 'workspace' && !selectedCase && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Dashboard tab.
        </div>
      )}

      {activeTab === 'otcalendar' && <OTCalendar />}

      {activeTab === 'history' && <HistoryTab cases={historyCases} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}

PYEOF_554951404225466407

cat > "app/components/AppShell.js" << 'PYEOF_7888684078191241620'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

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
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
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
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery' },
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

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      <div className="sidebar">
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
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
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
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
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



PYEOF_7888684078191241620

cat > "app/globals.css" << 'PYEOF_5471070161042699649'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

/* ── DESIGN TOKENS ──
   Ophthalmic Navy + brass-gold signature, grounded in the subject: a
   slit-lamp instrument palette (deep, precise, calm) with the warm
   brass of an iris used sparingly as the one accent. Semantic badge
   colors (blue/green/red/amber/purple/indigo/cyan/teal) keep their
   existing meaning across the app -- only the values are refined. */
:root {
  --blue: #1e4e8c; --blue-lt: #e7eff8; --blue-dk: #123a66; --blue-mid: #3e71b3;
  --green: #157a4f; --green-lt: #e3f5ec;
  --red: #b3261e; --red-lt: #fbe9e7;
  --amber: #a15c00; --amber-lt: #fbf0dc;
  --purple: #6d28a8; --purple-lt: #f1e7fb;
  --indigo: #3730a3; --indigo-lt: #e7e5fb;
  --cyan: #0b7285; --cyan-lt: #e0f5f8;
  --teal: #0e6b60; --teal-lt: #e1f5f1;
  --g50: #f8f9fa; --g100: #f1f3f5; --g200: #e3e6ea; --g300: #cbd0d6;
  --g400: #97a0aa; --g500: #62707c; --g600: #46525c; --g700: #303a42; --g800: #1c242b; --g900: #10161b;

  /* Signature accent -- the "iris" brass. Used sparingly: logo mark,
     active-nav underline glow, a handful of celebratory highlights.
     Never used for functional/semantic meaning (that's --amber). */
  --accent: #a6791f; --accent-lt: #f6ecd7; --accent-dk: #7d5a12;

  --r: 10px; --r-lg: 16px; --r-sm: 7px;

  --shadow-sm: 0 1px 2px rgba(16, 22, 27, .05), 0 1px 1px rgba(16, 22, 27, .03);
  --shadow-md: 0 4px 14px rgba(16, 22, 27, .07), 0 1px 3px rgba(16, 22, 27, .05);
  --shadow-lg: 0 12px 32px rgba(16, 22, 27, .12), 0 2px 8px rgba(16, 22, 27, .06);

  --font-display-stack: 'Sora', 'Segoe UI', sans-serif;
  --font-body-stack: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

html, body { height: 100%; }
html { -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }

body {
  font-family: var(--font-body-stack);
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
  line-height: 1.5;
}

/* Visible keyboard focus everywhere -- quality floor, not optional. */
a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible, [tabindex]:focus-visible {
  outline: 2px solid var(--blue-mid);
  outline-offset: 2px;
  border-radius: 4px;
}

/* Quiet, deliberate scrollbars instead of default browser chrome. */
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--g300); border-radius: 20px; border: 2px solid var(--g50); }
::-webkit-scrollbar-thumb:hover { background: var(--g400); }

/* ── APP SHELL ── */
.app-layout { display: flex; height: 100vh; overflow: hidden; }

/* Dark navy sidebar -- deliberately different register from the rest of
   the (light) app, like an instrument panel: gives the eye a clear,
   permanent anchor for "where am I" that never gets confused with page
   content. Gold accent (--accent) marks the active module. */
.sidebar {
  width: 236px;
  background: #0f1b2e;
  border-right: 1px solid rgba(255, 255, 255, .06);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  overflow-y: auto;
  min-height: 0;
}
.sb-logo {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 20px 18px;
  border-bottom: 1px solid rgba(255, 255, 255, .08);
  margin-bottom: 4px;
}
.sb-logo-icon {
  width: 36px; height: 36px;
  border-radius: 50%;
  flex-shrink: 0;
  position: relative;
  background:
    radial-gradient(circle at 50% 50%, var(--accent) 0 5px, transparent 5.5px),
    conic-gradient(from 0deg, var(--blue-dk), var(--blue) 35%, var(--blue-mid) 60%, var(--blue-dk) 100%);
  box-shadow: inset 0 0 0 2px rgba(255, 255, 255, .22), 0 0 0 1px rgba(255, 255, 255, .06);
}
.sb-name { font-family: var(--font-display-stack); font-weight: 700; font-size: 14px; letter-spacing: .1px; color: #fff; }
.sb-sub { font-size: 10.5px; color: rgba(255, 255, 255, .45); margin-top: 1px; }
.sb-sec { padding: 16px 18px 7px; font-size: 13.5px; font-weight: 800; color: rgba(255, 255, 255, .62); text-transform: uppercase; letter-spacing: .7px; }
.sb-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 16px 8px 15px;
  margin: 1px 8px;
  font-size: 13.5px;
  font-weight: 500;
  color: rgba(255, 255, 255, .88);
  cursor: pointer;
  border-left: 3px solid transparent;
  border-radius: 0 var(--r-sm) var(--r-sm) 0;
  text-decoration: none;
  transition: background .12s ease, color .12s ease;
}
.sb-item:hover { background: rgba(255, 255, 255, .06); color: #fff; }
.sb-item.active { background: rgba(166, 121, 31, .18); color: #fff; border-left-color: var(--accent); font-weight: 700; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; font-size: 14px; }

.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; height: 100vh; overflow: hidden; }
.topbar {
  background: #fff;
  border-bottom: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  padding: 14px 26px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  position: relative;
  z-index: 5;
  flex-shrink: 0;
}
.top-title { font-family: var(--font-display-stack); font-size: 16.5px; font-weight: 700; color: var(--g900); letter-spacing: -.1px; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 2px; }
.content-area { flex: 1; overflow-y: auto; padding: 26px; min-height: 0; }

/* ── CARDS ── */
.card {
  background: #fff;
  border: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  border-radius: var(--r-lg);
  padding: 20px;
  margin-bottom: 16px;
}
.card:last-child { margin-bottom: 0; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-family: var(--font-display-stack); font-size: 14px; font-weight: 700; color: var(--g900); display: flex; align-items: center; gap: 8px; letter-spacing: -.1px; }

/* ── BUTTONS ── */
.btn {
  padding: 9px 16px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid var(--g200);
  background: #fff;
  color: var(--g700);
  font-family: var(--font-body-stack);
  transition: background .12s ease, border-color .12s ease, box-shadow .12s ease, transform .08s ease;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.btn:hover { background: var(--g50); border-color: var(--g300); }
.btn:active { transform: translateY(1px); }
.btn:disabled { opacity: .5; cursor: not-allowed; transform: none; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-primary:hover { background: var(--blue-dk); box-shadow: var(--shadow-md); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-green:hover { filter: brightness(.92); }
.btn-danger { background: var(--red); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-danger:hover { filter: brightness(.92); }
.btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: var(--r-sm); }

/* ── BADGES ── */
.badge {
  padding: 2.5px 10px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .1px;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.b-blue { background: var(--blue-lt); color: var(--blue-dk); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-indigo { background: var(--indigo-lt); color: var(--indigo); }
.b-cyan { background: var(--cyan-lt); color: var(--cyan); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi {
  width: 100%;
  padding: 9px 12px;
  border: 1.5px solid var(--g200);
  border-radius: var(--r);
  font-size: 13px;
  font-family: var(--font-body-stack);
  background: #fff;
  color: var(--g800);
  transition: border-color .12s ease, box-shadow .12s ease;
}
.fi:focus { outline: none; border-color: var(--blue-mid); box-shadow: 0 0 0 3px var(--blue-lt); }
.fi:disabled { background: var(--g50); color: var(--g400); cursor: not-allowed; }
.fi-sm { padding: 6px 10px; font-size: 12px; }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }

/* Errors and warnings are easy to miss as a quiet inline line, especially
   on long forms -- they now float as an unmissable toast instead,
   regardless of where on the page they're rendered. Success/info stay
   in-flow since they're not the complaint and floating every positive
   confirmation would just add noise. This is pure CSS -- the exact same
   {error && <div className="msg-err">...} pattern used everywhere in the
   app automatically gets this treatment with zero code changes. */
@keyframes msgSlideIn {
  from { opacity: 0; transform: translateX(36px) scale(.97); }
  to { opacity: 1; transform: translateX(0) scale(1); }
}
@keyframes msgShake {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-5px); }
  40% { transform: translateX(5px); }
  60% { transform: translateX(-3px); }
  80% { transform: translateX(3px); }
}

.msg-err, .msg-warn {
  position: fixed;
  right: 26px;
  z-index: 1000;
  min-width: 300px;
  max-width: 440px;
  background: #fff;
  padding: 13px 18px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 10px;
  box-shadow: var(--shadow-lg);
  margin-bottom: 0;
}
.msg-err {
  top: 78px;
  color: var(--red);
  border: 1.5px solid var(--red);
  border-left: 5px solid var(--red);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1), msgShake .4s ease .3s;
}
.msg-err::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--red); color: #fff; font-weight: 800; font-size: 13px;
}
.msg-warn {
  top: 146px;
  color: var(--amber);
  border: 1.5px solid var(--amber);
  border-left: 5px solid var(--amber);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1);
}
.msg-warn::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--amber); color: #fff; font-weight: 800; font-size: 13px;
}

.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
.msg-success, .msg-ok { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }

@media (max-width: 860px) {
  .msg-err, .msg-warn { left: 16px; right: 16px; max-width: none; }
}

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 9px 10px; color: var(--g500); font-weight: 700; font-size: 10.5px; text-transform: uppercase; letter-spacing: .4px; background: var(--g50); border-bottom: 1.5px solid var(--g200); }
.tbl th:first-child { border-top-left-radius: var(--r-sm); }
.tbl th:last-child { border-top-right-radius: var(--r-sm); }
.tbl td { padding: 10px; border-bottom: 1px solid var(--g100); color: var(--g700); }
.tbl tbody tr { transition: background .1s ease; }
.tbl tbody tr:hover { background: var(--g50); }

/* ── PRINT ── */
@media print {
  .no-print { display: none !important; }
  body { background: #fff; }
  .card { box-shadow: none; }
}

/* ── SMALL SCREENS -- light touch, not a full mobile rework ── */
@media (max-width: 860px) {
  .sidebar { width: 68px; }
  .sb-name, .sb-sub, .sb-sec, .sb-item span:not(.sb-icon-wrap) { display: none; }
  .sb-item { justify-content: center; padding: 10px 0; margin: 1px 6px; }
  .sb-logo { justify-content: center; padding: 16px 0; }
  .content-area { padding: 16px; }
  .topbar { padding: 12px 16px; }
}
PYEOF_5471070161042699649

echo "Files written. Run: npm run build"
