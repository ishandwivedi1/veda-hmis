#!/usr/bin/env bash
set -e

echo 'Applying: net-discounted check-in amount, IOL Approval sidebar icon fix, and OT/Intraop dashboard heading updates'

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
    return {
      ...b,
      packagePrice,
      packageDiscount,
      netPackageAmount,
      advanceBalance,
      amountPayable: Math.max(0, netPackageAmount - advanceBalance),
      advanceCleared: netPackageAmount <= 0 || advanceBalance >= netPackageAmount,
    };
  });
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
async function assertCheckinDayLock(supabase, otScheduleId) {
  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date, status').eq('id', otScheduleId).single();
  if (!booking) return { error: 'OT booking not found.' };
  if (booking.status !== 'Scheduled') return null;

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  if (booking.scheduled_date !== todayIst) {
    const detail = booking.scheduled_date > todayIst
      ? `this surgery is scheduled for ${booking.scheduled_date}, which hasn't arrived yet`
      : `this surgery was scheduled for ${booking.scheduled_date} and was never checked in on that day`;
    return { error: `Check-in is locked -- ${detail}. Check-in can only happen on the scheduled day itself. Use OT Schedule to reschedule this case if the date needs to change.` };
  }
  return null;
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
          const canOpen = c.advanceCleared;
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
                {!canOpen && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>Advance Due: Rs.{c.amountPayable.toFixed(0)}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.surgery_code ? `${sc.surgery_code} -- ` : ''}{patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              {canOpen ? (
                <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
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

mkdir -p "app/(main)/ot-schedule"
cat > "app/(main)/ot-schedule/page.js" << 'VEDAEOF'
'use client';

import { useState, useEffect, useCallback, Fragment, Suspense } from 'react';
import {
  getScheduledOT, getOTHistory, getOTAvailability, rescheduleOTSlot, completeOT, undoCompleteOT,
  searchPatientsForDirectSurgery, getPackagesForDirectSurgery, getSurgeonsForDirectSurgery, registerSurgeryDirect,
} from './actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import OTCalendar from './ot-calendar';

const STATUS_BADGE = { Scheduled: 'b-blue', 'In Progress': 'b-amber', Completed: 'b-green', Cancelled: 'b-red' };

function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function RescheduleForm({ booking, onDone }) {
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [reason, setReason] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!date) { setError('Pick a new date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setSaving(true);
    const result = await rescheduleOTSlot(booking.id, date, sessionId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div style={{ padding: '10px 0', borderTop: '1px dashed var(--g200)' }}>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
        <div>
          <label className="flbl">New Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">Reason (optional)</label>
          <input className="fi fi-sm" placeholder="e.g. Patient requested, surgeon unavailable..." value={reason} onChange={(e) => setReason(e.target.value)} />
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

      <div style={{ display: 'flex', gap: 6 }}>
        <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Saving...' : 'Confirm Reschedule'}</button>
        <button className="btn btn-sm" onClick={() => onDone(false)} disabled={saving}>Cancel</button>
      </div>
    </div>
  );
}

function ScheduledOTTab() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);
  const [reschedulingId, setReschedulingId] = useState(null);

  const refresh = useCallback(async () => {
    setSchedule(await getScheduledOT());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId, patientName) {
    if (!window.confirm(`Mark ${patientName}'s surgery as Complete? This should only be done AFTER the surgery has actually happened -- it will move out of Scheduled and cannot be easily undone once intraoperative details are recorded.`)) return;
    await completeOT(otId, caseId);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Patients Scheduled for Surgery
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{schedule.length}</span>
      </div>

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {schedule.map((s) => (
              <Fragment key={s.id}>
                <tr>
                  <td>{fmtDate(s.scheduled_date)}</td>
                  <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                  <td>{s.room || '--'}</td>
                  <td>
                    {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                  </td>
                  <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                  <td>{s.profiles?.full_name || '--'}</td>
                  <td>
                    <span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span>
                    {s.reschedule_count > 0 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>(rescheduled {s.reschedule_count}x)</span>}
                  </td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-sm" onClick={() => setReschedulingId(reschedulingId === s.id ? null : s.id)}>
                        <i className="ti ti-calendar-time"></i> Reschedule
                      </button>
                      <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id, `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`)}>Complete</button>
                    </div>
                  </td>
                </tr>
                {reschedulingId === s.id && (
                  <tr>
                    <td colSpan={8} style={{ padding: 0, border: 'none' }}>
                      <RescheduleForm booking={s} onDone={(saved) => { setReschedulingId(null); if (saved) refresh(); }} />
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {schedule.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

function OTHistoryTab() {
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [undoingId, setUndoingId] = useState(null);
  const [undoError, setUndoError] = useState('');

  const refresh = useCallback(() => {
    getOTHistory().then((data) => { setHistory(data); setLoading(false); });
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleUndo(s) {
    const name = `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`;
    if (!window.confirm(`Undo the Complete on ${name}'s surgery and move it back to Scheduled?`)) return;
    setUndoError('');
    setUndoingId(s.id);
    const result = await undoCompleteOT(s.id, s.surgical_case_id);
    setUndoingId(null);
    if (result.error) { setUndoError(result.error); return; }
    refresh();
  }

  const filtered = search.trim()
    ? history.filter((s) => {
        const q = search.trim().toLowerCase();
        const p = s.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : history;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> OT History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Patients no longer in the active schedule -- currently in surgery, completed, or cancelled.
      </div>
      {undoError && <div className="msg-err" style={{ marginBottom: 10 }}>{undoError}</div>}

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {filtered.map((s) => (
              <tr key={s.id}>
                <td>{fmtDate(s.scheduled_date)}</td>
                <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                <td>
                  {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                </td>
                <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                <td>{s.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span></td>
                <td>
                  {s.status === 'Completed' && (
                    <button className="btn btn-sm" onClick={() => handleUndo(s)} disabled={undoingId === s.id} title="Undo an accidental Complete click">
                      {undoingId === s.id ? 'Undoing...' : <><i className="ti ti-arrow-back-up"></i> Undo</>}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>Nothing here yet.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── REGISTER SURGERY DIRECTLY ──────────────────────────────────────────
// Fast-track for a patient whose surgical decision was made outside
// today's Doctor -> Counselling pipeline: a returning patient whose
// surgery was arranged before HMIS existed, an external referral, an
// emergency. Creates the surgical case AND books the OT slot in one go,
// with biometry & medical fitness recorded as skipped-with-a-reason
// rather than the app pretending they went through the normal workup.
function RegisterSurgeryDirectForm({ onDone }) {
  const [patientQuery, setPatientQuery] = useState('');
  const [patientResults, setPatientResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searching, setSearching] = useState(false);

  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState('');
  const [eye, setEye] = useState('');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState('');
  const [priority, setPriority] = useState('Routine');
  const [workupNote, setWorkupNote] = useState('');

  const [packages, setPackages] = useState([]);
  const [packageId, setPackageId] = useState('');

  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getSurgeries().then(setSurgeries);
    getSurgeonsForDirectSurgery().then(setSurgeons);
    getPackagesForDirectSurgery().then(setPackages);
  }, []);

  useEffect(() => {
    if (!patientQuery.trim()) { setPatientResults([]); return; }
    setSearching(true);
    const t = setTimeout(() => {
      searchPatientsForDirectSurgery(patientQuery.trim()).then((rows) => { setPatientResults(rows); setSearching(false); });
    }, 300);
    return () => clearTimeout(t);
  }, [patientQuery]);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!selectedPatient) { setError('Select a patient.'); return; }
    if (!procedureName) { setError('Select the procedure.'); return; }
    if (!workupNote.trim()) { setError('Explain where biometry & fitness clearance came from -- required so this case has an honest audit trail.'); return; }
    if (!packageId) { setError('Select a billing package.'); return; }
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }

    setSaving(true);
    const result = await registerSurgeryDirect({
      patientId: selectedPatient.id, procedureName, eye: eye || null, surgeonId: surgeonId || null,
      priority, workupNote, packageId, date, sessionId, notes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Register Surgery Directly
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>
        For a patient whose surgery was decided outside today's Doctor / Counselling flow -- a returning patient from before HMIS existed, an external referral, or an emergency. Biometry & medical fitness are recorded as not-required-in-system with your reason, not faked.
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Patient</label>
        {selectedPatient ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
            <span className="badge b-blue">{selectedPatient.uhid}</span>
            <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
            <span style={{ color: 'var(--g400)', fontSize: 11 }}>{selectedPatient.mobile}</span>
            <button type="button" className="btn btn-sm" onClick={() => { setSelectedPatient(null); setPatientQuery(''); }}>Change</button>
          </div>
        ) : (
          <>
            <input className="fi fi-sm" placeholder="Search by name, UHID, or mobile..." value={patientQuery} onChange={(e) => setPatientQuery(e.target.value)} />
            {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>Searching...</div>}
            {patientResults.length > 0 && (
              <div style={{ marginTop: 6, border: '1px solid var(--g100)', borderRadius: 8, maxHeight: 180, overflowY: 'auto' }}>
                {patientResults.map((p) => (
                  <div
                    key={p.id}
                    onClick={() => { setSelectedPatient(p); setPatientResults([]); }}
                    style={{ padding: '8px 10px', fontSize: 12.5, cursor: 'pointer', borderBottom: '1px solid var(--g100)' }}
                  >
                    <span className="badge b-blue" style={{ marginRight: 6 }}>{p.uhid}</span>
                    {p.first_name} {p.last_name} <span style={{ color: 'var(--g400)' }}>-- {p.mobile}</span>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Procedure</label>
          <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
            <option value="">Select...</option>
            {surgeries.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Eye</label>
          <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
            <option value="">--</option>
            <option value="RE">RE</option>
            <option value="LE">LE</option>
          </select>
        </div>
      </div>

      {procedureName && (
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: -6, marginBottom: 12 }}>
          For a bilateral case, register each eye separately (they're normally booked into different OT sessions/dates anyway) -- submit this form once per eye.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">--</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Priority</label>
          <select className="fi fi-sm" value={priority} onChange={(e) => setPriority(e.target.value)}>
            <option value="Routine">Routine</option>
            <option value="Urgent">Urgent</option>
            <option value="Emergency">Emergency</option>
          </select>
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Where did biometry & medical fitness clearance come from?</label>
        <input className="fi fi-sm" placeholder='e.g. "Done before HMIS -- surgery decided 1 month ago", "External hospital referral, reports attached", "Emergency"' value={workupNote} onChange={(e) => setWorkupNote(e.target.value)} />
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Billing Package</label>
        <select className="fi fi-sm" value={packageId} onChange={(e) => setPackageId(e.target.value)}>
          <option value="">Select...</option>
          {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- ₹{p.price}</option>)}
        </select>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">OT Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{date ? 'No active OT sessions configured.' : 'Pick a date first.'}</div>
          ) : (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id} type="button" disabled={full} onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    {s.name} ({s.remaining} left)
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label className="flbl">Notes (optional)</label>
        <input className="fi fi-sm" placeholder="Anything else worth recording..." value={notes} onChange={(e) => setNotes(e.target.value)} />
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Registering...' : <><i className="ti ti-check"></i> Register & Book OT Slot</>}
        </button>
        <button className="btn" onClick={() => onDone(false)}>Cancel</button>
      </div>
    </div>
  );
}

export default function OTSchedulePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <OTScheduleInner />
    </Suspense>
  );
}

function OTScheduleInner() {
  const [activeTab, setActiveTab] = useState('scheduled');
  const [showDirectForm, setShowDirectForm] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 10, marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 480 }}>
          <button
            type="button"
            onClick={() => setActiveTab('scheduled')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'scheduled' ? '#fff' : 'transparent', color: activeTab === 'scheduled' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'scheduled' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar-event"></i> Scheduled OT
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('calendar')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'calendar' ? '#fff' : 'transparent', color: activeTab === 'calendar' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'calendar' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar"></i> Calendar
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('history')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'history' ? '#fff' : 'transparent', color: activeTab === 'history' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'history' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-history"></i> OT History
          </button>
        </div>

        <button type="button" className="btn" style={{ borderColor: 'var(--amber)', color: 'var(--amber)' }} onClick={() => setShowDirectForm(!showDirectForm)}>
          <i className="ti ti-calendar-plus"></i> {showDirectForm ? 'Close' : 'Register Surgery Directly'}
        </button>
      </div>

      {showDirectForm && (
        <RegisterSurgeryDirectForm
          onDone={(saved) => {
            setShowDirectForm(false);
            if (saved) { setActiveTab('scheduled'); setRefreshKey((k) => k + 1); }
          }}
        />
      )}

      {activeTab === 'scheduled' && <ScheduledOTTab key={refreshKey} />}
      {activeTab === 'calendar' && <OTCalendar />}
      {activeTab === 'history' && <OTHistoryTab />}
    </div>
  );
}
VEDAEOF
echo "Wrote app/(main)/ot-schedule/page.js"

mkdir -p "app/components"
cat > "app/components/AppShell.js" << 'VEDAEOF'
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
  { href: '/iol-approval', label: 'IOL Approval', icon: 'ti-aperture', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/patient-checkin', label: 'Patient Check-In', icon: 'ti-clipboard-check', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Intraoperative Management', icon: 'ti-building-hospital', section: 'Surgical' },
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
  { match: /^\/patient-checkin/, title: 'Patient Check-In' },
  { match: /^\/ot-intraop/, title: 'Intraoperative Management' },
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
VEDAEOF
echo "Wrote app/components/AppShell.js"

echo 'Running next build to verify...'
npm run build

echo 'Build succeeded. Staging and committing...'
git add "app/(main)/ot-intraop/actions.js" "app/(main)/ot-intraop/page.js" "app/(main)/ot-schedule/page.js" "app/components/AppShell.js"
git commit -m "Check-in amount now net of package discount; fix IOL Approval sidebar icon (ti-lens was invalid, now ti-aperture); rename OT Schedule and Intraop dashboard headings (Patients Scheduled for Surgery / Patients Checked In for Surgery / Patients Operated Today)"
git push

echo 'Done. Deployed via Vercel auto-deploy on push to main.'
