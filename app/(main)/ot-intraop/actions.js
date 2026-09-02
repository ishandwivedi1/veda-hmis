'use server';

import { createClient } from '@/lib/supabase-server';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { ensureRecoveryEpisode } from '../ot-recovery/actions';
import { getSurgicalConsumablesMaster } from '../master-data/actions';
import { getCaseProcedures } from '@/app/(main)/counselling/actions';

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
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, salutation, last_name, uhid), profiles:surgeon_id(full_name))')
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

// ── CHECK-IN HISTORY: every case checked in before today, regardless of
// whether the surgery itself has happened yet -- distinct from
// getOTIntraopHistory (which tracks completed SURGERIES). Today's
// checked-in patients stay on the live Dashboard's "Checked-In
// Patients (Today)" list until the day rolls over. ──
export async function getCheckinHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(surgery_code, procedure_name, eye, patients:patient_id(first_name, salutation, last_name, uhid), profiles:surgeon_id(full_name))')
    .lt('scheduled_date', todayIst)
    .order('scheduled_date', { ascending: false });
  if (error) return [];

  const ids = (data || []).map((b) => b.id);
  let intraopByBooking = {};
  if (ids.length > 0) {
    const { data: records } = await supabase.from('ot_intraop_records').select('ot_schedule_id, checkin_completed_at').in('ot_schedule_id', ids).not('checkin_completed_at', 'is', null);
    (records || []).forEach((r) => { intraopByBooking[r.ot_schedule_id] = r; });
  }

  return (data || [])
    .filter((b) => b.surgical_cases && intraopByBooking[b.id])
    .map((b) => ({ ...b, checkinSummary: intraopByBooking[b.id] }));
}


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

  const CASE_SELECT = '*, master_ot_sessions(name), surgical_cases(id, surgery_code, procedure_name, eye, package_billed, package_discount, patient_id, master_packages:package_id(price), patients:patient_id(first_name, salutation, last_name, uhid, age, gender), profiles:surgeon_id(full_name))';

  // Scheduled (not yet checked in) covers two buckets now: today's
  // normal queue, and anything overdue (scheduled_date in the past,
  // still 'Scheduled', never checked in) -- surfaced separately and
  // flagged isOverdue so it doesn't just blend into today's queue.
  // These are exactly the cases the new late-check-in flow exists for
  // (see completeCheckin's overrideReason) -- they need to be findable
  // here, not invisible just because their day already passed. A case
  // scheduled for tomorrow still isn't checkable-in today, so future
  // dates are excluded from both. In Progress is NOT date-restricted:
  // once a patient is already checked in, the case must stay reachable
  // to finish even if it runs past midnight.
  const [{ data: scheduledToday, error: scheduledError }, { data: overdueScheduled, error: overdueError }, { data: inProgress, error: inProgressError }, { data: completedToday, error: completedError }] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'Scheduled')
      .eq('scheduled_date', todayIst)
      .order('sequence_number', { ascending: true, nullsFirst: false }),
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'Scheduled')
      .lt('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true }),
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'In Progress')
      .order('scheduled_date', { ascending: true })
      .order('sequence_number', { ascending: true, nullsFirst: false }),
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'Completed')
      .eq('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true }),
  ]);
  if (scheduledError || overdueError || inProgressError || completedError) return [];

  const cases = [...(scheduledToday || []), ...(overdueScheduled || []), ...(inProgress || []), ...(completedToday || [])].filter((b) => b.surgical_cases);
  const overdueIds = new Set((overdueScheduled || []).map((b) => b.id));

  // Additional procedures within the same surgery (see
  // surgical_case_procedures) each keep their own package/price and
  // their own package_billed too -- summed in here so a
  // discounted-but-otherwise-billed additional procedure doesn't let
  // the case look "advance cleared" while part of the surgery is still
  // unpaid, and conversely so an ALREADY-billed additional procedure
  // doesn't keep demanding an advance for money that's already been
  // collected on its own invoice.
  const caseIds = [...new Set(cases.map((b) => b.surgical_cases.id))];
  const extraByCase = {};
  const unbilledExtraByCase = {};
  if (caseIds.length > 0) {
    const { data: extraProcs } = await supabase
      .from('surgical_case_procedures')
      .select('surgical_case_id, package_discount, package_billed, master_packages:package_id(price)')
      .in('surgical_case_id', caseIds);
    (extraProcs || []).forEach((p) => {
      const net = Math.max(0, Number(p.master_packages?.price || 0) - Number(p.package_discount || 0));
      extraByCase[p.surgical_case_id] = (extraByCase[p.surgical_case_id] || 0) + net;
      if (!p.package_billed) unbilledExtraByCase[p.surgical_case_id] = (unbilledExtraByCase[p.surgical_case_id] || 0) + net;
    });
  }

  const balanceByPatient = {};
  const patientIds = [...new Set(cases.map((b) => b.surgical_cases.patient_id).filter(Boolean))];
  await Promise.all(patientIds.map(async (pid) => {
    const { data: bal } = await supabase.rpc('get_advance_balance', { p_patient_id: pid });
    balanceByPatient[pid] = bal || 0;
  }));

  // hasVisit only matters for cases still awaiting check-in (Scheduled,
  // today or overdue) -- an In Progress/Completed case has already
  // cleared that gate by definition. Computed per-patient once, not
  // per-case.
  const visitByPatient = {};
  const awaitingCheckinPatientIds = [...new Set([...(scheduledToday || []), ...(overdueScheduled || [])].map((b) => b.surgical_cases?.patient_id).filter(Boolean))];
  await Promise.all(awaitingCheckinPatientIds.map(async (pid) => {
    visitByPatient[pid] = await hasActiveVisit(supabase, pid);
  }));

  return cases.map((b) => {
    // Net payable = package price minus whatever discount was recorded
    // at Package Selection / Payment step in Surgical Journey --
    // matches netPackageAmount there exactly (surgical-journey/[id]/workspace.js).
    const packagePrice = Number(b.surgical_cases.master_packages?.price || 0);
    const packageDiscount = Number(b.surgical_cases.package_discount || 0);
    const primaryNet = Math.max(0, packagePrice - packageDiscount);
    const netPackageAmount = primaryNet + (extraByCase[b.surgical_cases.id] || 0);
    // A surgery can be paid two legitimate ways: an advance collected
    // up front (patient_ledger, checked via advanceBalance), or billed
    // directly on an invoice with no advance at all (package_billed
    // flips true the moment ANY invoice line references this case's
    // package -- see markPackageBilled in billing/actions.js, called
    // regardless of which route got it there). unbilledNet is only the
    // portion NOT already covered that way -- the primary package if
    // sc.package_billed is still false, plus whichever additional
    // procedures haven't been billed yet -- so advance is only ever
    // asked to cover what's actually still outstanding.
    const unbilledNet = (b.surgical_cases.package_billed ? 0 : primaryNet) + (unbilledExtraByCase[b.surgical_cases.id] || 0);
    const advanceBalance = balanceByPatient[b.surgical_cases.patient_id] || 0;
    const isScheduled = b.status === 'Scheduled';
    return {
      ...b,
      packagePrice,
      packageDiscount,
      netPackageAmount,
      advanceBalance,
      amountPayable: Math.max(0, unbilledNet - advanceBalance),
      advanceCleared: unbilledNet <= 0 || advanceBalance >= unbilledNet,
      hasVisitToday: isScheduled ? !!visitByPatient[b.surgical_cases.patient_id] : true,
      isOverdue: overdueIds.has(b.id),
    };
  });
}

// ── ACTIVE VISIT CHECK -- an open visit in the Visits module, not just
// a scheduled OT booking. These are two genuinely separate facts that
// used to only ever get compared by accident: a surgery visit could
// be created without the patient ever landing anywhere near Check-In,
// and Check-In itself never actually verified a visit existed at all.
// This closes that gap directly. No longer scoped to "created today"
// -- any currently open visit counts, so a visit still open from the
// real surgery day satisfies this just as well as a fresh one.
async function hasActiveVisit(supabase, patientId) {
  if (!patientId) return false;
  const { count } = await supabase.from('visits').select('id', { count: 'exact', head: true }).eq('patient_id', patientId).eq('status', 'Open');
  return (count || 0) > 0;
}

// ── CHECK-IN DATE GATE -- server-side, not just a list filter. The
// Patient Check-In page is deep-linkable straight into a specific case
// via ?otScheduleId= (from Surgical Journey), which bypasses
// getOTCaseList entirely -- so the date rule has to be enforced again
// here, or a stale/deep-linked tab could still check a patient in on
// the wrong day. Only applies while status is still 'Scheduled' --
// once check-in is actually completed and the case has moved to 'In
// Progress', it must be free to keep going regardless of the clock
// (same for everything after it -- Intraop, Recovery, Discharge are
// already fully date-independent).
//
// A FUTURE scheduled_date is still a hard block -- a surgery can't be
// checked in before its own day arrives. A PAST scheduled_date is no
// longer blocked here -- staff can fill in check-in fields (checklist,
// consents, anaesthesia, IOL verification) for a surgery that's
// overdue, so a late entry can be prepared. The actual commit point,
// completeCheckin, is where a past date requires an explicit reason
// instead of being silently allowed through -- see there for why.
//
// The active-visit requirement is no longer "created today" either --
// any currently open visit for this patient satisfies it, so a visit
// still open from the real surgery day works just as well as a fresh
// one made today.
async function assertCheckinDayLock(supabase, otScheduleId) {
  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date, status, surgical_cases(patient_id)').eq('id', otScheduleId).single();
  if (!booking) return { error: 'OT booking not found.' };
  if (booking.status !== 'Scheduled') return null;

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  if (booking.scheduled_date > todayIst) {
    return { error: `Check-in is locked -- this surgery is scheduled for ${booking.scheduled_date}, which hasn't arrived yet.` };
  }

  const hasVisit = await hasActiveVisit(supabase, booking.surgical_cases?.patient_id);
  if (!hasVisit) {
    return { error: 'Check-in is locked -- this patient has no active visit. Create a visit for them (Visit Type: Surgery) in Visits before checking in.' };
  }

  return null;
}

// ── SURGERY LANDING RESOLVER -- where a patient should go when a
// Surgery-type visit gets created for them (see visits/new/page.js,
// which now sends every Surgery visit straight to Patient Check-In
// instead of the Front Office Dashboard). This is the single place
// that answers "what's actually going on with this patient's surgery"
// so staff aren't left guessing:
//   - an OT booking that's today or overdue -> hand back its id so the
//     caller can go straight into the normal check-in workspace
//     (overdue still requires a reason at actual check-in completion,
//     enforced by completeCheckin -- this resolver doesn't need to
//     know that, it just needs to route there instead of detouring).
//   - a booking scheduled for the FUTURE -> flag it as needing a
//     reschedule decision, with enough detail to act on -- you
//     genuinely can't check in before the day arrives.
//   - no surgical case at all -> flag that OT Schedule's "Register
//     Surgery Directly" is what's actually needed here.
export async function getSurgeryLandingForPatient(patientId) {
  const supabase = await createClient();
  if (!patientId) return { noCase: true };
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  const { data: cases } = await supabase.from('surgical_cases').select('id, procedure_name, eye').eq('patient_id', patientId).neq('status', 'Cancelled');
  const caseIds = (cases || []).map((c) => c.id);
  if (caseIds.length === 0) return { noCase: true };

  const { data: schedules } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, status, surgical_case_id, master_ot_sessions(name)')
    .in('surgical_case_id', caseIds)
    .in('status', ['Scheduled', 'In Progress'])
    .order('scheduled_date', { ascending: true });
  if (!schedules || schedules.length === 0) return { noCase: true };

  const checkinableMatch = schedules.find((s) => s.status === 'In Progress' || (s.status === 'Scheduled' && s.scheduled_date <= todayIst));
  if (checkinableMatch) return { otScheduleId: checkinableMatch.id };

  // Nothing checkin-able -- every remaining booking is in the future.
  // Surface the nearest one so staff can decide right here whether it
  // needs to move sooner or stay where it is.
  const next = schedules[0];
  const caseInfo = (cases || []).find((c) => c.id === next.surgical_case_id);
  return {
    needsReschedule: true,
    otScheduleId: next.id,
    scheduledDate: next.scheduled_date,
    sessionName: next.master_ot_sessions?.name || null,
    procedureName: caseInfo?.procedure_name || null,
    eye: caseInfo?.eye || null,
  };
}


// ── PATIENT REPORTED TO OT -- the surgery patient doesn't route through
//    Optometry or Doctor Consultation queues on the day of surgery; this
//    is how OT staff record that they've physically arrived, straight
//    from the Dashboard widget or the workspace header. ──
export async function markPatientReported(otScheduleId) {
  const supabase = await createClient();
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
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
    .select('*, master_ot_sessions(name), surgical_cases(*, patients:patient_id(id, first_name, salutation, last_name, uhid, age, gender), profiles:surgeon_id(full_name), master_packages:package_id(name))')
    .eq('id', otScheduleId)
    .single();
  if (error) return { error: error.message };

  const sc = booking.surgical_cases;
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  // Planned IOL comes from the surgeon's IOL Approval (a separate
  // module/step now) -- NOT from biometry_records, which only holds
  // the device's raw per-brand recommendations and no longer has any
  // "approved" concept of its own. Matched by surgical_case_id (a real
  // FK), not visit_id -- eye comes from sc.eye directly, set by the
  // doctor, not from biometry at all (biometry doesn't track eye
  // anymore since it's always done for both).
  //
  // Everything here only depends on booking/sc, already available from
  // the fetch above -- all fetched together in one wave (including
  // consent forms, the day-lock check, and additional procedures)
  // instead of several sequential round-trips one after another.
  const [
    { data: approval }, { data: intraop }, { data: consumables }, { data: events },
    consentForms, activeVisit, caseProcedures,
  ] = await Promise.all([
    supabase.from('iol_approvals').select('*, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('ot_intraop_records').select('*').eq('ot_schedule_id', otScheduleId).maybeSingle(),
    supabase.from('ot_intraop_consumables').select('*').eq('ot_schedule_id', otScheduleId).order('added_at'),
    supabase.from('ot_intraop_events').select('*').eq('ot_schedule_id', otScheduleId).order('occurred_at'),

    // Consent form uploads -- one attachment lookup per type.
    (async () => {
      const forms = {};
      await Promise.all(CONSENT_FORM_TYPES.map(async (f) => {
        const { data: files } = await supabase
          .from('clinical_attachments')
          .select('*')
          .eq('entity_type', `ot_consent_${f.key}`)
          .eq('entity_id', otScheduleId)
          .order('uploaded_at', { ascending: false })
          .limit(1);
        forms[f.key] = files && files.length > 0 ? files[0] : null;
      }));
      return forms;
    })(),

    // Same fact assertCheckinDayLock enforces server-side on every save
    // -- fetched here too so the workspace can show the lock as the
    // very first thing on load, before the person starts filling
    // anything in, instead of only discovering it from an error after
    // clicking Save.
    hasActiveVisit(supabase, sc?.patient_id),

    // Additional procedures within the same surgery (e.g. Anti-VEGF
    // Injection alongside a Cataract case) -- shown alongside the
    // primary procedure at Check-In and in Intraoperative Management.
    sc?.id ? getCaseProcedures(sc.id) : Promise.resolve([]),
  ]);

  return {
    booking, biometryPlans: approval ? [approval] : [],
    intraop: intraop || null,
    consumables: consumables || [],
    events: (events || []).filter((e) => e.kind === 'Event'),
    complications: (events || []).filter((e) => e.kind === 'Complication'),
    consentForms,
    hasActiveVisit: activeVisit,
    caseProcedures,
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
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({ checkin_items: checkinItems }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeCheckin(otScheduleId, surgicalCaseId, overrideReason) {
  const supabase = await createClient();
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;

  // A PAST scheduled_date is allowed through assertCheckinDayLock (see
  // its comment) so staff can prepare a late entry, but this is the
  // actual commit point -- the one place a genuinely missed surgery
  // and a legitimately late-logged one need a person to tell them
  // apart. An overdue check-in requires an explicit reason, which gets
  // logged to the OT audit trail below -- same override-with-reason
  // pattern used elsewhere in this app (e.g. changing a locked
  // surgical decision). Draft saves before this point (checklist
  // items, consents, anaesthesia, IOL verification) don't ask again.
  const { data: bookingRow } = await supabase.from('ot_schedule').select('scheduled_date').eq('id', otScheduleId).single();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const isOverdue = bookingRow && bookingRow.scheduled_date < todayIst;
  if (isOverdue && !overrideReason?.trim()) {
    return {
      needsOverrideReason: true,
      scheduledDate: bookingRow.scheduled_date,
      error: `This surgery was scheduled for ${bookingRow.scheduled_date} and wasn't checked in that day. Enter a reason to check in now.`,
    };
  }

  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  const consentsOk = await requiredConsentsUploaded(supabase, otScheduleId);
  if (!consentsOk) return { error: 'Upload all required consent forms before completing check-in.' };

  const { data: intraop } = await supabase.from('ot_intraop_records').select('checkin_items').eq('id', recordId).single();
  const checked = Object.values(intraop?.checkin_items || {}).filter(Boolean).length;
  if (checked < CHECKIN_ITEMS.length - 1) return { error: `Complete all check-in items first (${checked}/${CHECKIN_ITEMS.length - 1}).` };

  // VAL-OT-IOL-001: if an approved IOL exists for this case, its power
  // and brand must both be present. Check-in is the last point this can
  // still be corrected -- discovering it missing only after the implant
  // is already in the eye is too late to act on. A case with no
  // approval at all is left alone (non-IOL procedures legitimately have
  // none). Sourced from iol_approvals now, not biometry_records --
  // biometry no longer has an "approved" concept of its own.
  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('eye, power, master_iol_catalog:iol_catalog_id(brand)')
    .eq('surgical_case_id', surgicalCaseId)
    .eq('status', 'Approved')
    .maybeSingle();
  if (approval && (!approval.power || !approval.master_iol_catalog?.brand)) {
    const missing = !approval.power ? 'power' : 'brand';
    return { error: `Approved IOL for ${approval.eye} is missing its ${missing} -- fix this in IOL Approval before check-in can be completed.` };
  }

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_intraop_records').update({ checkin_completed_at: new Date().toISOString() }).eq('id', recordId);
  await supabase.from('ot_schedule').update({ status: 'In Progress' }).eq('id', otScheduleId);
  const auditDetail = isOverdue
    ? `OT check-in completed late (originally scheduled ${bookingRow.scheduled_date}) -- reason: ${overrideReason.trim()}`
    : 'OT check-in completed';
  await supabase.from('ot_schedule_audit_log').insert({ ot_schedule_id: otScheduleId, action: 'Check-In', detail: auditDetail, changed_by: userData?.user?.id || null });
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
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
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

// ── CHECK-IN IOL VERIFICATION -- confirms the physical IOL on hand
// matches the surgeon's approved plan, BEFORE surgery starts. Distinct
// from implant_* (what was actually implanted, recorded in Intraop --
// can differ if a complication forces a substitution mid-case). ──
export async function saveCheckinIolVerification(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({
    verified_iol_manufacturer: values.manufacturer || null,
    verified_iol_model: values.model || null,
    verified_iol_catalog_id: values.catalogId || null,
    verified_iol_power: values.power || null,
    verified_iol_category: values.category || null,
    verified_iol_serial: values.serial || null,
    verified_iol_expiry: values.expiry || null,
    verified_iol_eye: values.eye || null,
    verified_iol_at: new Date().toISOString(),
  }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}


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
