#!/usr/bin/env bash
set -e

echo 'Applying: check-in requires an active visit today; Surgery visits land on Patient Check-In with a landing resolver'

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/actions.js" << 'VEDAEOF'
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
    .select('*, master_ot_sessions(name), surgical_cases(surgery_code, procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
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

  const CASE_SELECT = '*, master_ot_sessions(name), surgical_cases(id, surgery_code, procedure_name, eye, package_billed, package_discount, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))';

  // Scheduled (not yet checked in) is now strictly locked to scheduled_date
  // === today -- not "on or before today" as it used to be. A case
  // scheduled for tomorrow shouldn't be checkable-in today, and a case
  // scheduled days ago that was never checked in has genuinely been
  // missed -- it needs an actual reschedule via OT Schedule, not a
  // silent same-day check-in here. In Progress is NOT date-restricted:
  // once a patient is already checked in, the case must stay reachable
  // to finish even if it runs past midnight.
  const [{ data: scheduledToday, error: scheduledError }, { data: inProgress, error: inProgressError }, { data: completedToday, error: completedError }] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select(CASE_SELECT)
      .eq('status', 'Scheduled')
      .eq('scheduled_date', todayIst)
      .order('sequence_number', { ascending: true, nullsFirst: false }),
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
  if (scheduledError || inProgressError || completedError) return [];

  const cases = [...(scheduledToday || []), ...(inProgress || []), ...(completedToday || [])].filter((b) => b.surgical_cases);

  const balanceByPatient = {};
  const patientIds = [...new Set(cases.map((b) => b.surgical_cases.patient_id).filter(Boolean))];
  await Promise.all(patientIds.map(async (pid) => {
    const { data: bal } = await supabase.rpc('get_advance_balance', { p_patient_id: pid });
    balanceByPatient[pid] = bal || 0;
  }));

  // hasVisitToday only matters for cases still awaiting check-in
  // (Scheduled) -- an In Progress/Completed case has already cleared
  // that gate by definition. Computed per-patient once, not per-case.
  const visitTodayByPatient = {};
  const scheduledPatientIds = [...new Set((scheduledToday || []).map((b) => b.surgical_cases?.patient_id).filter(Boolean))];
  await Promise.all(scheduledPatientIds.map(async (pid) => {
    visitTodayByPatient[pid] = await hasActiveVisitToday(supabase, pid, todayIst);
  }));

  return cases.map((b) => {
    // Net payable = package price minus whatever discount was recorded
    // at Package Selection / Payment step in Surgical Journey --
    // matches netPackageAmount there exactly (surgical-journey/[id]/workspace.js).
    // Previously this used the raw package price with no discount
    // applied, so a discounted patient always showed an inflated
    // "amount to collect" here at check-in.
    const packagePrice = Number(b.surgical_cases.master_packages?.price || 0);
    const packageDiscount = Number(b.surgical_cases.package_discount || 0);
    const netPackageAmount = Math.max(0, packagePrice - packageDiscount);
    const advanceBalance = balanceByPatient[b.surgical_cases.patient_id] || 0;
    const isScheduled = b.status === 'Scheduled';
    return {
      ...b,
      packagePrice,
      packageDiscount,
      netPackageAmount,
      advanceBalance,
      amountPayable: Math.max(0, netPackageAmount - advanceBalance),
      advanceCleared: netPackageAmount <= 0 || advanceBalance >= netPackageAmount,
      hasVisitToday: isScheduled ? !!visitTodayByPatient[b.surgical_cases.patient_id] : true,
    };
  });
}

// ── ACTIVE VISIT TODAY -- checked in at the front desk (Visits module)
// today, not just scheduled in OT. These are two genuinely separate
// facts that used to only ever get compared by accident: a surgery
// visit could be created without the patient ever landing anywhere
// near Check-In, and Check-In itself never actually verified a visit
// existed at all. This closes that gap directly.
async function hasActiveVisitToday(supabase, patientId, todayIst) {
  if (!patientId) return false;
  const { data: openVisits } = await supabase.from('visits').select('id, created_at').eq('patient_id', patientId).eq('status', 'Open');
  return (openVisits || []).some((v) => new Date(v.created_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) === todayIst);
}

// ── CHECK-IN DAY LOCK -- server-side gate, not just a list filter. The
// Patient Check-In page is deep-linkable straight into a specific case
// via ?otScheduleId= (from Surgical Journey), which bypasses
// getOTCaseList entirely -- so the date rule has to be enforced again
// here, or a stale/deep-linked tab could still check a patient in (or
// even complete surgery-adjacent steps) on the wrong day. Only applies
// while status is still 'Scheduled' -- once check-in is actually
// completed and the case has moved to 'In Progress', it must be free
// to keep going regardless of the clock.
//
// Two independent conditions, both required: (1) today is the actual
// scheduled OT day, and (2) the patient has an active (Open) visit
// created today in the Visits module -- i.e. they've genuinely arrived
// and been registered today, not just that OT Schedule happens to say
// "today". A patient can't be checked in on the strength of the OT
// booking alone.
async function assertCheckinDayLock(supabase, otScheduleId) {
  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date, status, surgical_cases(patient_id)').eq('id', otScheduleId).single();
  if (!booking) return { error: 'OT booking not found.' };
  if (booking.status !== 'Scheduled') return null;

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  if (booking.scheduled_date !== todayIst) {
    const detail = booking.scheduled_date > todayIst
      ? `this surgery is scheduled for ${booking.scheduled_date}, which hasn't arrived yet`
      : `this surgery was scheduled for ${booking.scheduled_date} and was never checked in on that day`;
    return { error: `Check-in is locked -- ${detail}. Check-in can only happen on the scheduled day itself. Use OT Schedule to reschedule this case if the date needs to change.` };
  }

  const hasVisit = await hasActiveVisitToday(supabase, booking.surgical_cases?.patient_id, todayIst);
  if (!hasVisit) {
    return { error: 'Check-in is locked -- this patient has no active visit today. Create a visit for them (Visit Type: Surgery) in Visits before checking in.' };
  }

  return null;
}

// ── SURGERY LANDING RESOLVER -- where a patient should go when a
// Surgery-type visit gets created for them (see visits/new/page.js,
// which now sends every Surgery visit straight to Patient Check-In
// instead of the Front Office Dashboard). This is the single place
// that answers "what's actually going on with this patient's surgery
// today" so staff aren't left guessing:
//   - an OT booking that matches today -> hand back its id so the
//     caller can go straight into the normal check-in workspace.
//   - a booking that exists but for a different day -> flag it as
//     needing a reschedule decision, with enough detail to act on.
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

  const todayMatch = schedules.find((s) => s.status === 'In Progress' || (s.status === 'Scheduled' && s.scheduled_date === todayIst));
  if (todayMatch) return { otScheduleId: todayMatch.id };

  // Nothing lines up with today -- surface the nearest booking so staff
  // can decide right here whether it needs to move to today or stay
  // where it is.
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
    supabase.from('iol_approvals').select('*, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
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
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({ checkin_items: checkinItems }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeCheckin(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();
  const lock = await assertCheckinDayLock(supabase, otScheduleId);
  if (lock) return lock;
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
VEDAEOF
echo "Wrote app/(main)/ot-intraop/actions.js"

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/page.js" << 'VEDAEOF'
'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { getOTCaseList, getOTIntraopHistory, markPatientReported, unmarkPatientReported } from './actions';
import Workspace from './workspace';

const STATUS_BADGE = { Scheduled: 'b-amber', 'In Progress': 'b-blue' };

export function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--red)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export function DashboardTab({ cases, loading, onOpen, onRefresh, returnTo = 'ot-intraop', variant = 'intraop' }) {
  const [busyId, setBusyId] = useState(null);

  async function handleToggleReported(e, otId, currentlyReported) {
    e.stopPropagation();
    setBusyId(otId);
    if (currentlyReported) await unmarkPatientReported(otId);
    else await markPatientReported(otId);
    setBusyId(null);
    onRefresh();
  }

  // Patient Check-In cares about a different split than Intraoperative
  // Management: "checked in" here just means check-in is done (status
  // moves Scheduled -> In Progress the moment check-in completes, see
  // completeCheckin), not that the surgery itself is finished.
  //
  // Intraoperative Management's own top section is deliberately
  // narrower than Patient Check-In's -- it only cares about patients
  // who have ALREADY been checked in (status 'In Progress') and are
  // ready for/in the OT. A patient still sitting at 'Scheduled' hasn't
  // been checked in yet and has no business showing up here as
  // "pending" -- that confusion is exactly what Patient Check-In's own
  // Dashboard exists to resolve; Intraop shouldn't duplicate it.
  const isCheckin = variant === 'checkin';
  const topCases = isCheckin ? cases.filter((c) => c.status === 'Scheduled') : cases.filter((c) => c.status === 'In Progress');
  const bottomCases = isCheckin ? cases.filter((c) => c.status !== 'Scheduled') : cases.filter((c) => c.status === 'Completed');
  const topTitle = isCheckin ? 'Pending Check-In' : 'Patients Checked In for Surgery';
  const bottomTitle = isCheckin ? 'Checked-In Patients (Today)' : 'Patients Operated Today';
  const bottomSubtitle = isCheckin ? 'Already checked in and handed off to the OT team.' : 'Moves to OT History tomorrow -- still editable from here today if a correction is needed.';

  const counts = {
    Scheduled: cases.filter((c) => c.status === 'Scheduled').length,
    'In Progress': cases.filter((c) => c.status === 'In Progress').length,
    Completed: cases.filter((c) => c.status === 'Completed').length,
  };

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Scheduled, not checked in</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Scheduled}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In Progress</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts['In Progress']}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Completed today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Completed}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Total today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--red)' }}></i> {topTitle}</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && topCases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          const noVisitToday = c.hasVisitToday === false;
          const canOpen = c.advanceCleared && !noVisitToday;
          return (
            <div
              key={c.id}
              onClick={canOpen ? () => onOpen(c.id) : undefined}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: canOpen ? 'pointer' : 'default' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--red)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status}</span>
                <button
                  type="button"
                  className={`badge ${c.patient_reported_at ? 'b-green' : 'b-gray'}`}
                  style={{ marginLeft: 6, fontSize: 10, border: 'none', cursor: 'pointer' }}
                  disabled={busyId === c.id}
                  onClick={(e) => handleToggleReported(e, c.id, !!c.patient_reported_at)}
                  title={c.patient_reported_at ? `Reported at ${new Date(c.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Click to mark patient as reported'}
                >
                  {busyId === c.id ? '...' : c.patient_reported_at ? 'Reported' : 'Mark Reported'}
                </button>
                {noVisitToday && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>No Visit Today</span>}
                {!noVisitToday && !canOpen && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>Advance Due: Rs.{c.amountPayable.toFixed(0)}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.surgery_code ? `${sc.surgery_code} -- ` : ''}{patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              {canOpen ? (
                <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
              ) : noVisitToday ? (
                <Link
                  href={`/visits/new?patientId=${sc.patient_id}&visitType=Surgery`}
                  onClick={(e) => e.stopPropagation()}
                  className="btn btn-sm"
                  style={{ background: 'var(--red)', color: '#fff', border: 'none', textDecoration: 'none' }}
                  title="This patient has no active visit today -- create one before check-in can proceed"
                >
                  <i className="ti ti-door-enter"></i> Create Visit
                </Link>
              ) : (
                <Link
                  href={`/payments/advance?patientId=${sc.patient_id}&amount=${c.amountPayable.toFixed(2)}&returnTo=${returnTo}`}
                  onClick={(e) => e.stopPropagation()}
                  className="btn btn-sm"
                  style={{ background: 'var(--amber)', color: '#fff', border: 'none', textDecoration: 'none' }}
                  title="Collect the advance needed before this case can be opened"
                >
                  <i className="ti ti-cash"></i> Collect Advance -- Rs.{c.amountPayable.toFixed(0)}
                </Link>
              )}
            </div>
          );
        })}
        {!loading && topCases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>{isCheckin ? 'No patients pending check-in.' : 'No pending OT cases for today.'}</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> {bottomTitle}</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>{bottomSubtitle}</div>
        {!loading && bottomCases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div
              key={c.id}
              onClick={() => onOpen(c.id)}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${isCheckin ? (STATUS_BADGE[c.status] || 'b-gray') : 'b-green'}`} style={{ marginLeft: 8, fontSize: 10 }}>{isCheckin ? c.status : 'Completed'}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.surgery_code ? `${sc.surgery_code} -- ` : ''}{patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              <button className="btn btn-sm"><i className="ti ti-edit"></i> View / Edit</button>
            </div>
          );
        })}
        {!loading && bottomCases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>{isCheckin ? 'Nothing checked in yet today.' : 'Nothing completed yet today.'}</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((r) => {
        const q = search.trim().toLowerCase();
        const patient = r.surgical_cases?.patients;
        return `${patient?.first_name} ${patient?.last_name}`.toLowerCase().includes(q) || (patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Completed OT Cases</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Date</th><th>Patient</th><th>Procedure</th><th>Outcome</th><th>Completed By</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => {
              const sc = r.surgical_cases;
              const patient = sc?.patients;
              return (
                <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td><strong>{patient?.first_name} {patient?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>{sc?.procedure_name} ({sc?.eye})</td>
                  <td><span className="badge b-green" style={{ fontSize: 10 }}>{r.intraopSummary?.surgical_outcome || '--'}</span></td>
                  <td style={{ fontSize: 12 }}>{r.intraopSummary?.completedByName || '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              );
            })}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

// Deep-linkable via ?otScheduleId=... -- Surgical Journey's
// Intraoperative Management step links straight here with the case's
// OT schedule id so it opens the patient's own record instead of
// dropping onto the Dashboard for a manual pick.
function OTIntraopInner() {
  const searchParams = useSearchParams();
  const deepLinkId = searchParams.get('otScheduleId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getOTIntraopHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-building-hospital" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} />}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="intraop" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

export default function OTIntraopPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <OTIntraopInner />
    </Suspense>
  );
}
VEDAEOF
echo "Wrote app/(main)/ot-intraop/page.js"

mkdir -p "app/(main)/visits"
cat > "app/(main)/visits/actions.js" << 'VEDAEOF'
'use server';

import { after } from 'next/server';
import { createClient } from '@/lib/supabase-server';
import { sendVisitConfirmationWhatsApp, formatVisitDateIST } from '@/lib/whatsapp';

// Fetches a single patient for pre-filling the New Visit form when
// arriving via a "Create Visit" link from the Patients list, so the
// front desk doesn't have to search for someone they already had open.
export async function getPatientById(patientId) {
  if (!patientId) return null;
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  return data || null;
}

export async function getDoctorOptionsForVisit() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name')
    .eq('designation', 'Doctor')
    .eq('status', 'Active')
    .order('full_name');
  return data || [];
}

// Core send logic -- always synchronous, always returns a real result.
// Used directly by resendVisitWhatsApp (manual button, needs real
// success/error feedback) and wrapped by deferVisitWhatsApp below for
// the automatic triggers (visit creation), which must never block.
async function sendVisitWhatsAppCore(visit, triggeredBy) {
  const supabase = await createClient();
  const { data: patient } = await supabase
    .from('patients')
    .select('id, first_name, last_name, mobile')
    .eq('id', visit.patient_id)
    .single();

  if (!patient || !patient.mobile) return { success: false, error: 'Patient has no mobile number on file.' };

  return sendVisitConfirmationWhatsApp({
    name: `${patient.first_name} ${patient.last_name}`.trim(),
    visitNumber: visit.visit_number,
    visitDate: formatVisitDateIST(visit.created_at),
    mobile: patient.mobile,
    patientDbId: patient.id,
    visitDbId: visit.id,
    meta: { module: 'visit', triggeredBy: triggeredBy || null },
  });
}

// Deferred wrapper for createWalkInVisit / checkInAppointment -- schedules
// the send to run after the response via after(), so visit creation
// returns immediately and is never blocked or failed by the WhatsApp send.
function deferVisitWhatsApp(visit, triggeredBy) {
  after(async () => {
    try {
      await sendVisitWhatsAppCore(visit, triggeredBy);
    } catch (waErr) {
      console.error('WhatsApp visit confirmation send failed:', waErr.message);
    }
  });
}

export async function checkInAppointment(appointmentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('check_in_appointment', {
    p_appointment_id: appointmentId,
  });

  if (error) {
    return { error: error.message };
  }

  const { data: { user } } = await supabase.auth.getUser();
  deferVisitWhatsApp(data, user?.id);

  return { visit: data };
}

export async function createWalkInVisit(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('create_walk_in_visit', {
    p_patient_id: values.patientId,
    p_doctor_id: values.doctorId || null,
    p_visit_type: values.visitType,
    p_referral_source: values.referralSource || null,
    p_priority: values.priority || 'Routine',
    p_surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  });

  if (error) {
    return { error: error.message };
  }

  const { data: { user } } = await supabase.auth.getUser();
  deferVisitWhatsApp(data, user?.id);

  // create_walk_in_visit's Surgery branch only ATTACHES this visit to an
  // OT case that was already scheduled for today -- it can't create one.
  // If nothing matches (patient's surgery was arranged before HMIS
  // existed, an external referral, staff skipped Counselling, etc.),
  // that attach step silently touches zero rows and the visit still
  // gets created successfully, leaving the patient invisible in OT
  // Schedule with no indication anything went wrong. Surface that here
  // instead of letting it be discovered later in OT.
  let surgeryNotScheduled = false;
  let otScheduleId = null;
  if (values.visitType === 'Surgery' && data?.patient_id) {
    const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    const { data: cases } = await supabase.from('surgical_cases').select('id').eq('patient_id', data.patient_id).neq('status', 'Cancelled');
    const caseIds = (cases || []).map((c) => c.id);
    if (caseIds.length === 0) {
      surgeryNotScheduled = true;
    } else {
      const { data: match } = await supabase
        .from('ot_schedule')
        .select('id')
        .in('surgical_case_id', caseIds)
        .eq('scheduled_date', todayIst)
        .in('status', ['Scheduled', 'In Progress'])
        .limit(1);
      surgeryNotScheduled = !match || match.length === 0;
      otScheduleId = match && match.length > 0 ? match[0].id : null;
    }
  }

  return { visit: data, surgeryNotScheduled, otScheduleId };
}

export async function getSurgeryTypeOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name');
  return data || [];
}

// Resend the visit confirmation WhatsApp message -- used by a manual
// "Resend WhatsApp confirmation" control, e.g. if the automatic send
// failed or the patient's mobile number was corrected since.
export async function resendVisitWhatsApp(visitId) {
  if (!visitId) return { error: 'Missing visit id.' };

  const supabase = await createClient();
  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, patient_id, created_at')
    .eq('id', visitId)
    .single();

  if (error) return { error: error.message };
  if (!visit) return { error: 'Visit not found.' };

  const { data: { user } } = await supabase.auth.getUser();
  const whatsapp = await sendVisitWhatsAppCore(visit, user?.id);

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Surgery'];

// Doctor / visit type / priority can be corrected after check-in --
// front desk mistakes happen. Scoped to Open visits only; a closed or
// cancelled visit is a historical record and shouldn't be edited.
export async function updateVisit(visitId, values) {
  const supabase = await createClient();

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is ${visit.status} and can no longer be edited.` };
  if (values.visitType && !VISIT_TYPES.includes(values.visitType)) return { error: 'Invalid visit type.' };

  const { error } = await supabase.from('visits').update({
    doctor_id: values.doctorId || null,
    visit_type: values.visitType,
    priority: values.priority || 'Routine',
    surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  }).eq('id', visitId);
  if (error) return { error: error.message };
  return { success: true };
}

// Cancelling a visit is permanent and needs a reason on record -- also
// pulls the patient out of whatever queue they're still sitting in
// (Optometry/Doctor), since there's nothing left for them to wait for.
// Blocked if the visit already has money collected against it, since
// that needs to go through Invoice Modification instead of silently
// orphaning a paid invoice.
export async function cancelVisit(visitId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is already ${visit.status}.` };

  const { data: invoices } = await supabase.from('invoices').select('id, status, paid').eq('visit_id', visitId);
  const hasPayment = (invoices || []).some((inv) => Number(inv.paid) > 0);
  if (hasPayment) {
    return { error: 'This visit already has payment collected against it -- cancel or modify the invoice first, via Invoice Modification.' };
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('visits').update({
    status: 'Cancelled',
    cancellation_reason: reason.trim(),
    cancelled_by: userData?.user?.id || null,
    cancelled_at: new Date().toISOString(),
  }).eq('id', visitId);
  if (error) return { error: error.message };

  await supabase
    .from('queue_entries')
    .update({ status: 'Cancelled' })
    .eq('visit_id', visitId)
    .not('status', 'in', '("Done","Cancelled")');

  return { success: true };
}
VEDAEOF
echo "Wrote app/(main)/visits/actions.js"

mkdir -p "app/(main)/visits/new"
cat > "app/(main)/visits/new/page.js" << 'VEDAEOF'
'use client';

import { useState, useEffect, Suspense } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit, getSurgeryTypeOptions, getPatientById } from '@/app/(main)/visits/actions';

export default function NewVisitPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <NewVisitForm />
    </Suspense>
  );
}

function NewVisitForm() {
  const searchParams = useSearchParams();
  const prefillPatientId = searchParams.get('patientId');
  const prefillVisitType = searchParams.get('visitType');

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);
  const [prefillLoading, setPrefillLoading] = useState(!!prefillPatientId);
  const [prefillError, setPrefillError] = useState('');

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState(prefillVisitType === 'Surgery' ? 'Surgery' : 'New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [surgeryType, setSurgeryType] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
    getSurgeryTypeOptions().then(setSurgeryTypes);
  }, []);

  useEffect(() => {
    if (!prefillPatientId) return;
    let cancelled = false;
    setPrefillLoading(true);
    getPatientById(prefillPatientId).then((patient) => {
      if (cancelled) return;
      setPrefillLoading(false);
      if (patient) {
        setSelectedPatient(patient);
      } else {
        setPrefillError('Could not load that patient -- search for them below instead.');
      }
    });
    return () => { cancelled = true; };
  }, [prefillPatientId]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
    setSearched(true);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); setSearched(false); return; }
    const t = setTimeout(async () => {
      const results = await searchPatientsForBooking(q);
      setSearchResults(results);
      setSearched(true);
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function goToFullRegistration() {
    const isMobile = /^\d{6,}$/.test(searchQuery.trim());
    const params = new URLSearchParams({
      returnTo: 'visit',
      prefillFirstName: isMobile ? '' : searchQuery.trim().split(' ')[0] || '',
      prefillLastName: isMobile ? '' : searchQuery.trim().split(' ').slice(1).join(' ') || '',
      prefillMobile: isMobile ? searchQuery.trim() : '',
    });
    router.push(`/patients/new?${params.toString()}`);
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient) {
      setError('Search and select a registered patient.');
      return;
    }
    if (visitType === 'Surgery' && !surgeryType) {
      setError('Select the type of surgery.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
      referralSource,
      priority,
      surgeryType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    // Surgery visits now always land on Patient Check-In -- that's the
    // single place a surgical patient's day-of status gets resolved,
    // whether or not today happens to be their scheduled OT day. If
    // today's booking was found, deep-link straight into it (zero extra
    // clicks, same as before); otherwise Patient Check-In's own landing
    // resolver (?patientId=) takes over and shows staff exactly what's
    // going on -- a booking for a different day that may need
    // rescheduling, or no case at all needing "Register Surgery
    // Directly". Non-Surgery visits are unaffected.
    if (visitType === 'Surgery') {
      if (result.otScheduleId) {
        router.push(`/patient-checkin?otScheduleId=${result.otScheduleId}`);
      } else {
        router.push(`/patient-checkin?patientId=${selectedPatient.id}`);
      }
      return;
    }

    router.push('/front-office-dashboard?visitCreated=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Create Walk-in Visit
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          For patients arriving without a prior appointment.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {prefillError && <div className="msg-err">{prefillError}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {prefillLoading ? (
              <div style={{ padding: '8px 12px', color: 'var(--g500)', fontSize: 13 }}>
                <i className="ti ti-loader-2"></i> Loading patient...
              </div>
            ) : selectedPatient ? (
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--blue-lt)',
                  padding: '8px 12px',
                  borderRadius: 8,
                }}
              >
                <span>
                  <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
                  {' -- '}
                  {selectedPatient.uhid}
                </span>
                <button
                  type="button"
                  className="btn"
                  style={{ padding: '4px 10px' }}
                  onClick={() => setSelectedPatient(null)}
                >
                  Change
                </button>
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    className="fi"
                    value={searchQuery}
                    onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }}
                    placeholder="Type to search..."
                  />
                  <button type="button" className="btn" onClick={handleSearch}>
                    Search
                  </button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                    {searchResults.map((p) => (
                      <div
                        key={p.id}
                        onClick={() => pickPatient(p)}
                        style={{
                          padding: '8px 12px',
                          cursor: 'pointer',
                          borderBottom: '1px solid var(--g100)',
                          fontSize: 13,
                        }}
                      >
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                      </div>
                    ))}
                  </div>
                )}
                {searched && searchResults.length === 0 && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={goToFullRegistration}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Register this patient
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: visitType === 'Surgery' ? '1fr 1fr 1fr' : '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => { setVisitType(e.target.value); if (e.target.value !== 'Surgery') setSurgeryType(''); }}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Surgery</option>
              </select>
            </div>
            {visitType === 'Surgery' && (
              <div>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Referral source</label>
              <select className="fi" value={referralSource} onChange={(e) => setReferralSource(e.target.value)}>
                <option>Walk-in</option>
                <option>Doctor referral</option>
                <option>Camp / outreach</option>
                <option>Previous patient</option>
              </select>
            </div>
            <div>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option>
                <option>Urgent</option>
                <option>Emergency</option>
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Creating...' : 'Create Visit'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/front-office-dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}
VEDAEOF
echo "Wrote app/(main)/visits/new/page.js"

mkdir -p "app/(main)/patient-checkin"
cat > "app/(main)/patient-checkin/page.js" << 'VEDAEOF'
'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { getOTCaseList, getCheckinHistory, getSurgeryLandingForPatient } from '../ot-intraop/actions';
import { getPatientById } from '../visits/actions';
import { DashboardTab, TabButton } from '../ot-intraop/page';
import Workspace from '../ot-intraop/workspace';

// Every check-in completed before today -- distinct from Intraoperative
// Management's History (which tracks completed SURGERIES). A patient
// checked in yesterday but not yet operated on still needs to show up
// here so staff can find and correct their check-in record.
function CheckinHistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((r) => {
        const q = search.trim().toLowerCase();
        const patient = r.surgical_cases?.patients;
        return `${patient?.first_name} ${patient?.last_name}`.toLowerCase().includes(q) || (patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Checked-In Patients</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Date</th><th>Patient</th><th>Procedure</th><th>Session</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => {
              const sc = r.surgical_cases;
              const patient = sc?.patients;
              return (
                <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td><strong>{patient?.first_name} {patient?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>{sc?.procedure_name} ({sc?.eye})</td>
                  <td style={{ fontSize: 12 }}>{r.master_ot_sessions?.name || '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              );
            })}
            {filtered.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No checked-in patients found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── LANDING RESOLVER -- where a Surgery-type visit sends the patient
// when today isn't a clean match to an OT booking. This is the whole
// point of routing every Surgery visit here rather than the Front
// Office Dashboard: instead of the patient silently landing nowhere
// useful (or an easy-to-miss one-off warning on the New Visit form),
// staff see exactly what's going on and can act on it immediately --
// reschedule an existing booking to today, or register the surgery
// directly if no case exists at all.
function LandingResolver({ patientId, landing, patient, onGoDashboard }) {
  return (
    <div className="card" style={{ borderColor: 'var(--amber)' }}>
      <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 4, color: 'var(--amber)' }}>
        <i className="ti ti-alert-triangle" style={{ marginRight: 6 }}></i>
        {landing.needsReschedule ? "This surgery isn't scheduled for today" : 'No surgical case found for this patient'}
      </div>
      {patient && (
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 12 }}>
          <strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid} -- {patient.mobile}
        </div>
      )}

      {landing.needsReschedule && (
        <div style={{ fontSize: 13, color: 'var(--g600)', lineHeight: 1.6, marginBottom: 6 }}>
          {landing.procedureName ? `${landing.procedureName} (${landing.eye})` : 'This surgical case'} is currently scheduled for{' '}
          <strong>{new Date(`${landing.scheduledDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</strong>
          {landing.sessionName ? ` (${landing.sessionName} session)` : ''} -- not today. A visit was created for this patient today, but check-in can only happen on the actual scheduled day.
          Decide whether this booking needs to move to today (Reschedule) or the patient came in for something else.
        </div>
      )}
      {landing.noCase && (
        <div style={{ fontSize: 13, color: 'var(--g600)', lineHeight: 1.6, marginBottom: 6 }}>
          A visit was created for this patient today as Surgery type, but there's no surgical case on file for them at all. This usually means the surgical decision was made outside today's Doctor / Counselling flow -- e.g. a returning patient whose surgery was arranged before HMIS existed, or an external referral.
          Use OT Schedule's <strong>&quot;Register Surgery Directly&quot;</strong> to add their case and slot them in.
        </div>
      )}

      <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
        <a href="/ot-schedule" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-calendar-event"></i> Go to OT Schedule
        </a>
        <button className="btn" onClick={onGoDashboard}>Back to Check-In Dashboard</button>
      </div>
    </div>
  );
}

// Patient Check-In is split out from what used to be the combined
// "Operation Theatre" module (Patient Check-In + Intraoperative
// Management as two tabs in one screen) into its own module. The
// underlying case list, data, and check-in checklist itself are
// unchanged -- only the navigation/entry point is split; Intraoperative
// Management lives at /ot-intraop.
//
// Deep-linkable two ways:
//   - ?otScheduleId=... -- Surgical Journey's Patient Check-In step
//     links straight here with the case's OT schedule id so it opens
//     the patient's own record instead of dropping onto the Dashboard
//     for a manual pick.
//   - ?patientId=... -- every Surgery-type visit (Visits -> New Visit)
//     lands here now, whether or not today happens to be the patient's
//     scheduled OT day. getSurgeryLandingForPatient resolves which of
//     those it is; a same-day match silently becomes the normal
//     ?otScheduleId= flow above, anything else shows LandingResolver.
function PatientCheckinInner() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const deepLinkId = searchParams.get('otScheduleId');
  const landingPatientId = searchParams.get('patientId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [landing, setLanding] = useState(null);
  const [landingPatient, setLandingPatient] = useState(null);
  const [landingLoading, setLandingLoading] = useState(!!landingPatientId && !deepLinkId);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getCheckinHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  useEffect(() => {
    if (!landingPatientId || deepLinkId) return;
    let cancelled = false;
    (async () => {
      const [result, patient] = await Promise.all([getSurgeryLandingForPatient(landingPatientId), getPatientById(landingPatientId)]);
      if (cancelled) return;
      setLandingPatient(patient);
      if (result.otScheduleId && !result.needsReschedule) {
        // Clean same-day match -- go straight into the normal workspace
        // flow, no need to show the resolver at all.
        setSelectedId(result.otScheduleId);
        setActiveTab('workspace');
        router.replace(`/patient-checkin?otScheduleId=${result.otScheduleId}`);
      } else {
        setLanding(result);
      }
      setLandingLoading(false);
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [landingPatientId, deepLinkId]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setLanding(null);
    setActiveTab('dashboard');
  }

  if (landingLoading) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Checking today's surgery schedule for this patient...</div>;
  }

  if (landing) {
    return <LandingResolver patientId={landingPatientId} landing={landing} patient={landingPatient} onGoDashboard={() => { setLanding(null); router.replace('/patient-checkin'); }} />;
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-check" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} returnTo="patient-checkin" variant="checkin" />}
      {activeTab === 'history' && <CheckinHistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="checkin" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

export default function PatientCheckinPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <PatientCheckinInner />
    </Suspense>
  );
}
VEDAEOF
echo "Wrote app/(main)/patient-checkin/page.js"

echo 'Running next build to verify...'
npm run build

echo 'Build succeeded. Staging and committing...'
git add "app/(main)/ot-intraop/actions.js" "app/(main)/ot-intraop/page.js" "app/(main)/visits/actions.js" "app/(main)/visits/new/page.js" "app/(main)/patient-checkin/page.js"
git commit -m "Check-in now requires an active visit today (not just a matching OT date); Surgery-type visits always land on Patient Check-In, with a landing resolver for cases not scheduled today"
git push

echo 'Done. Deployed via Vercel auto-deploy on push to main.'
