'use server';

import { createClient } from '@/lib/supabase-server';

// ============================================================================
// DO NOT DELETE OR MOVE THIS FILE.
//
// The Counselling *page* (app/(main)/counselling/page.js) was removed from
// the sidebar nav and the Front Office Dashboard link on 2026-08-22 -- its
// responsibilities were absorbed into Surgical Journey's own workspace.
// But THIS FILE is not the Counselling page's private backend -- it is the
// shared engine for the entire surgical case lifecycle, imported directly
// by other live modules:
//
//   Consultation (app/consultation/[id]/consultation-form.js):
//     markForSurgery, updateSurgicalCase, setDecision
//
//   Surgical Journey (app/(main)/surgical-journey/[id]/workspace.js):
//     selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
//     setDecision, markReadyForScheduling, bookOTSlot, getSurgeons
//
//   Surgical Journey (app/(main)/surgical-journey/actions.js):
//     markForSurgery, setDecision
//
// Deleting or moving this file breaks surgery creation, package/billing
// selection, the Ready-for-Scheduling gate, and OT slot booking across the
// whole app -- not just Counselling. If a future cleanup wants this file
// gone, first re-point every import above at wherever its logic moves to,
// then verify with a full build before removing anything.
//
// A handful of functions below (biometry skip/unskip with an audit reason,
// counselling-specific investigation ordering, case notes, the counselling
// case list/history, mark-fitness-cleared, mark-investigations-complete,
// refer-back-to-doctor) are genuinely only used by the now-unlinked
// Counselling page and have no other caller -- those are safe to remove
// later if/when the page itself is deleted, unlike everything listed above.
// ============================================================================
//
// This file replaces the old "Surgical Coordination" module's actions file.
// Booking an OT slot is the last step of the counselling workspace (see
// bookOTSlot/getOTAvailability below). The calendar view itself, plus
// rescheduling and OT History, now live in their own module at
// app/(main)/ot-schedule (getScheduledOT/getOTHistory/rescheduleOTSlot/
// completeOT), not here.
// The following exports are used by OTHER modules and MUST keep the same
// name + signature:
//   markForSurgery(patientId, encounterId, procedureName, eye, investigations, notes, decision, linkedCaseId)
//     -- linkedCaseId (added 2026-08) is optional: pass an existing
//        surgical_cases.id on the SAME visit to mark this new procedure
//        as part of a combined surgery with it (e.g. Cataract with
//        Anti-VEGF Injection). Both cases end up sharing a
//        combo_group_id, which bookOTSlot uses to always schedule them
//        into the identical OT sitting together. Omit for the normal
//        single-procedure case -- nothing changes for existing callers.
//   getComboSiblings(caseId) -- returns the other procedure(s) sharing
//        this case's combo_group_id, [] for a standalone case.
//   markForSurgeryBatch(patientId, encounterId, procedures, investigations, notes, decision)
//        -- procedures is [{name, eye}, ...]. Primary entry point for
//        advising a COMBINED surgery in one shot -- every procedure is
//        created together sharing one combo_group_id, with IDENTICAL
//        investigations/notes/decision from the start (added 2026-08,
//        replaces calling markForSurgery twice, which let the two
//        procedures' investigations drift out of sync).
//   markSameDaySurgicalEval(encounterId, wantsEval) -- flags every
//        surgical case on this encounter as wanting same-day surgical
//        evaluation, so they show on the Surgeon Dashboard today even
//        though the OPD visit itself isn't a surgical-track visit type.
//   updateSurgicalCase(caseId, procedureName, eye, investigations, notes)
//     -- imported by app/(main)/consultation/[id]/consultation-form.js
//     -- investigations is [{name, eye}], the doctor's indicative pre-op
//        investigations (see consultation-form.js's "Pre Op Requirement"
//        field), stored on indicative_investigations. NOT auto-ordered
//        here -- Surgical Journey's Investigations step reads that
//        column and shows them as one-click suggestions; the actual
//        investigation_orders row only gets created when someone acts
//        on it there (see lib/surgicalCaseInvestigations.js and
//        surgical-journey/[id]/workspace.js's InvestigationsSection).
//     -- fitness_required is always true (every surgical case needs
//        Medical Fitness clearance) -- no per-case choice.
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
export async function updateSurgicalCase(caseId, procedureName, eye, investigations, notes) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Pending Workup') {
    return { error: `This case has already moved to "${sc.status}" -- further changes should go through Counselling.` };
  }

  const cleanInvestigations = (investigations || []).filter((i) => i?.name?.trim());
  const update = { procedure_name: procedureName, eye, notes: notes || null };
  if (investigations !== undefined) {
    update.indicative_investigations = cleanInvestigations;
    update.biometry_required = cleanInvestigations.some((i) => i.name.trim().toLowerCase() === 'biometry');
  }

  const { error } = await supabase.from('surgical_cases').update(update).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// linkedCaseId is optional -- when provided, this new procedure is
// explicitly being advised TOGETHER with an existing surgical case on
// the same visit (e.g. Cataract advised first, then Anti-VEGF Injection
// added as a combined procedure). Both cases end up sharing the same
// combo_group_id, which is what keeps them locked to the same OT
// sitting at booking time (see bookOTSlot below) -- this is the one
// explicit exception to the "one visit, one surgical case" rule.
export async function markForSurgery(patientId, encounterId, procedureName, eye, investigations, notes, decision, linkedCaseId) {
  const supabase = await createClient();

  if (decision && !DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };

  // Pull surgeon + visit + priority through so the case doesn't start
  // with everything null -- encounters already carries doctor_id.
  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  let comboGroupId = null;
  // When combining, investigations and decision are ALWAYS inherited
  // from the linked case, not whatever was passed in for this call --
  // both procedures in a combined surgery are done in a single
  // sitting, so they share ONE pre-op investigation set and ONE
  // patient decision, not two independently-entered ones that could
  // silently drift apart (this is exactly what broke investigations
  // not carrying forward to Surgical Journey for the second
  // procedure). The caller's own investigations/decision arguments are
  // ignored on this path.
  let inheritedInvestigations = null;
  let inheritedDecision = null;
  if (linkedCaseId) {
    const { data: linked } = await supabase
      .from('surgical_cases')
      .select('id, visit_id, combo_group_id, status, indicative_investigations, decision')
      .eq('id', linkedCaseId)
      .neq('status', 'Cancelled')
      .maybeSingle();
    if (!linked || linked.visit_id !== encounter?.visit_id) {
      return { error: 'Could not find the procedure to combine with on this visit.' };
    }
    if (linked.status !== 'Pending Workup') {
      return { error: `That procedure has already moved to "${linked.status}" -- combined procedures can only be added while both are still Pending Workup.` };
    }
    comboGroupId = linked.combo_group_id;
    if (!comboGroupId) {
      comboGroupId = crypto.randomUUID();
      await supabase.from('surgical_cases').update({ combo_group_id: comboGroupId }).eq('id', linked.id);
    }
    inheritedInvestigations = linked.indicative_investigations || [];
    inheritedDecision = linked.decision || null;
  } else if (encounter?.visit_id) {
    // BR: one visit, one surgical case -- checked against visit_id (not
    // just this encounter), since a visit can span more than one
    // encounter (e.g. consultation reopened) and the case should still
    // only be created once. The one exception is an explicit combined
    // procedure (linkedCaseId above), e.g. Cataract with Anti-VEGF
    // Injection performed together.
    const { data: existing } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye')
      .eq('visit_id', encounter.visit_id)
      .neq('status', 'Cancelled')
      .limit(1);
    if (existing && existing.length > 0) {
      return { error: `This visit already has a surgical case marked (${existing[0].procedure_name} -- ${existing[0].eye}). Use "Add Combined Procedure" if these are being performed together, or only one is allowed per visit.` };
    }
  }

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  // Doctor's call on what pre-op investigations this case actually
  // needs, picked from the same Investigations master list used
  // elsewhere in Consultation (see consultation-form.js's "Pre Op
  // Requirement" field) -- Biometry is just one more entry in that
  // list, not a separate hardcoded flag. biometry_required is derived
  // from whether "Biometry" is among them. These are indicative only --
  // NOT auto-ordered here. Surgical Journey's Investigations step reads
  // indicative_investigations to show them as one-click suggestions;
  // the actual investigation_orders row only gets created when someone
  // acts on that suggestion there (see addInHouseInvestigationForCase).
  // Medical Fitness clearance is required for every surgical case, no
  // per-case choice.
  const cleanInvestigations = linkedCaseId ? inheritedInvestigations : (investigations || []).filter((i) => i?.name?.trim());
  const biometryRequired = cleanInvestigations.some((i) => i.name.trim().toLowerCase() === 'biometry');
  const effectiveDecision = linkedCaseId ? inheritedDecision : (decision || null);

  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: procedureName,
    eye,
    priority,
    biometry_required: biometryRequired,
    fitness_required: true,
    indicative_investigations: cleanInvestigations,
    notes: notes || null,
    combo_group_id: comboGroupId,
    // Patient's initial reaction, captured right here in OPD -- the
    // FIRST step of the surgical journey now, not something deferred to
    // Counselling. 'Accepted' locks immediately (matches setDecision's
    // own locking rule); anything else stays open for front desk to
    // update once the patient calls back, no reason required for that
    // first change.
    decision: effectiveDecision,
    decision_locked: effectiveDecision === 'Accepted',
  });
  if (error) return { error: error.message };

  return { success: true };
}

// ── Primary "advise surgery" entry point for a COMBINED surgery, e.g.
// Cataract with Anti-VEGF Injection performed in a single sitting.
// Unlike calling markForSurgery once per procedure, this creates every
// procedure in ONE action so investigations, notes, and the patient's
// decision are genuinely defined ONCE and identical across every
// linked case from the moment they're created -- no risk of the
// second procedure silently ending up with different (or missing)
// investigations than the first. procedures is [{name, eye}, ...];
// pass a single-item array for a normal, non-combined surgery (same
// result as calling markForSurgery once with no linkedCaseId). ──
export async function markForSurgeryBatch(patientId, encounterId, procedures, investigations, notes, decision) {
  const supabase = await createClient();

  const cleanProcedures = (procedures || []).filter((p) => p?.name?.trim());
  if (cleanProcedures.length === 0) return { error: 'At least one procedure is required.' };
  if (decision && !DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };

  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  // BR: one visit, one surgical CASE GROUP -- a combined surgery still
  // counts as one advice event for this rule, same as a single
  // procedure would.
  if (encounter?.visit_id) {
    const { data: existing } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye')
      .eq('visit_id', encounter.visit_id)
      .neq('status', 'Cancelled')
      .limit(1);
    if (existing && existing.length > 0) {
      return { error: `This visit already has a surgical case marked (${existing[0].procedure_name} -- ${existing[0].eye}). Only one surgical advice is allowed per visit.` };
    }
  }

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  const cleanInvestigations = (investigations || []).filter((i) => i?.name?.trim());
  const biometryRequired = cleanInvestigations.some((i) => i.name.trim().toLowerCase() === 'biometry');
  const comboGroupId = cleanProcedures.length > 1 ? crypto.randomUUID() : null;

  const rows = cleanProcedures.map((p) => ({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: p.name,
    eye: p.eye,
    priority,
    biometry_required: biometryRequired,
    fitness_required: true,
    indicative_investigations: cleanInvestigations,
    notes: notes || null,
    combo_group_id: comboGroupId,
    decision: decision || null,
    decision_locked: decision === 'Accepted',
  }));

  const { error } = await supabase.from('surgical_cases').insert(rows);
  if (error) return { error: error.message };

  return { success: true };
}

// Asked at OPD visit completion, right after a surgery is advised --
// some patients undergo surgical evaluation the SAME day, independent
// of whether they've decided to go ahead. Without this flag they'd
// only ever show up on the Surgical Journey screen today, since their
// actual OPD visit_type (New Consultation, Follow-up, etc.) isn't one
// of SURGICAL_TRACK_VISIT_TYPES -- that's normally what makes a
// patient appear in the Surgeon Dashboard's Surgical Evaluation
// section (see getSurgicalEvaluationArrivalsToday). Applies to every
// surgical case created on this encounter, since a combined surgery
// advises more than one procedure together and both should show up.
export async function markSameDaySurgicalEval(encounterId, wantsEval) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('surgical_cases')
    .update({ same_day_surgical_eval: !!wantsEval })
    .eq('encounter_id', encounterId)
    .neq('status', 'Cancelled');
  if (error) return { error: error.message };
  return { success: true };
}

// ── Combined surgery -- other procedures sharing this case's
// combo_group_id (e.g. this case is Cataract, sibling is Anti-VEGF
// Injection). Returns [] for a standalone case. Used to show the
// linkage everywhere a single case is displayed, so staff never
// mistake a combined surgery for two unrelated ones. ──
export async function getComboSiblings(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('combo_group_id').eq('id', caseId).maybeSingle();
  if (!sc?.combo_group_id) return [];
  const { data } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, status')
    .eq('combo_group_id', sc.combo_group_id)
    .neq('id', caseId)
    .neq('status', 'Cancelled');
  return data || [];
}

// ── Cases list for the Counselling workspace (richer -- surgeon, decision, IOL type) ──
export async function getCounsellingCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason, combo_group_id,
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
      iol_category, decision, decision_reason, combo_group_id,
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
  const { data: sc } = await supabase.from('surgical_cases').select('id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  // No prerequisite checks -- biometry, IOL approval, package selection,
  // and patient decision are no longer required to give an OT date.
  // Removed 2026-08-22 at explicit request: this platform covers every
  // surgery type, many of which never needed these checks in the first
  // place, and the checks were blocking booking even for cases that
  // genuinely didn't need them.
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

// Combined surgeries (e.g. Cataract with Anti-VEGF Injection) are
// always locked to the same OT sitting -- booking one of them books
// every sibling sharing its combo_group_id, atomically, into the
// identical date/session/room via book_ot_slot_combo. A standalone
// case (no combo_group_id) goes through the original single-case
// book_ot_slot exactly as before -- nothing changes for the normal
// case.
export async function bookOTSlot(caseId, date, sessionId, surgeonId, notes) {
  const supabase = await createClient();
  if (!date) return { error: 'Date is required.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data: sc } = await supabase.from('surgical_cases').select('combo_group_id').eq('id', caseId).maybeSingle();

  let caseIds = [caseId];
  if (sc?.combo_group_id) {
    const { data: siblings } = await supabase
      .from('surgical_cases')
      .select('id, status')
      .eq('combo_group_id', sc.combo_group_id)
      .neq('status', 'Cancelled');

    // A sibling that's already moved past scheduling (Scheduled,
    // Completed, ...) can't be folded into a fresh booking -- that
    // would silently re-book or duplicate an already-scheduled
    // procedure. Anything still Pending Workup is auto-promoted to
    // Ready for Scheduling right here (same no-prerequisite-checks
    // behavior as markReadyForScheduling below) so staff don't have to
    // separately click through every linked procedure before booking
    // once, together, covers all of them.
    const alreadyProgressed = (siblings || []).find((s) => s.id !== caseId && !['Pending Workup', 'Ready for Scheduling'].includes(s.status));
    if (alreadyProgressed) {
      return { error: 'One of the combined procedures has already moved past scheduling -- this combined booking cannot proceed automatically.' };
    }
    const toPromote = (siblings || []).filter((s) => s.status === 'Pending Workup').map((s) => s.id);
    if (toPromote.length > 0) {
      await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).in('id', toPromote);
    }
    caseIds = (siblings || []).map((s) => s.id);
    if (!caseIds.includes(caseId)) caseIds.push(caseId);
  }

  if (caseIds.length === 1) {
    const { data, error } = await supabase.rpc('book_ot_slot', {
      p_case_id: caseId,
      p_date: date,
      p_session_id: sessionId,
      p_surgeon_id: surgeonId || null,
      p_notes: notes || null,
    });
    if (error) return { error: error.message };
    if (data?.error) return { error: data.error };
  } else {
    const { data, error } = await supabase.rpc('book_ot_slot_combo', {
      p_case_ids: caseIds,
      p_date: date,
      p_session_id: sessionId,
      p_surgeon_id: surgeonId || null,
      p_notes: notes || null,
    });
    if (error) return { error: error.message };
    if (data?.error) return { error: data.error };
  }

  // Medical Fitness now enters the workflow automatically once a
  // surgery date exists, instead of needing a separate "Refer to
  // Doctor" click -- closer to the actual surgery date is when
  // clearance is clinically useful anyway. Every procedure in a combo
  // gets its own referral -- one clearance visit still covers both in
  // practice, but each keeps its own tracked record.
  for (const id of caseIds) {
    await ensureFitnessReferral(supabase, id);
  }

  return { success: true };
}



