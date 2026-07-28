#!/bin/bash
set -e
echo "Applying: OT collects advance only; Surgery Billing widget at discharge; editable surgery fields"

cat > "app/(main)/ot-intraop/actions.js" << 'PYEOF_9026531225534470113'
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

// ── HISTORY: completed OT cases ──
export async function getOTIntraopHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .eq('status', 'Completed')
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
// cancelled -- the natural set of cases someone would walk in and open.
// Also computes, per case, the package price and the patient's current
// advance balance -- Open is gated on the advance fully covering the
// package (surgery billing itself now happens later, at discharge, via
// the Surgery Billing widget on the Billing Dashboard -- not here).
export async function getOTCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(id, procedure_name, eye, package_billed, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .in('status', ['Scheduled', 'In Progress'])
    .lte('scheduled_date', new Date().toISOString().slice(0, 10))
    .order('scheduled_date', { ascending: true })
    .order('sequence_number', { ascending: true, nullsFirst: false });
  if (error) return [];

  const cases = (data || []).filter((b) => b.surgical_cases);

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

  const [{ data: biometry }, { data: intraop }, { data: consumables }, { data: events }] = await Promise.all([
    supabase.from('biometry_records').select('*, master_iol_catalog(brand, model, manufacturer)').eq('visit_id', sc.visit_id).eq('status', 'Approved').order('approved_at', { ascending: false }),
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
    booking, biometryPlans: biometry || [],
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

  // VAL-OT-IOL-001: if an approved IOL plan exists for this visit, its
  // power and manufacturer must both be present. Check-in is the last
  // point this can still be corrected -- discovering a missing power or
  // manufacturer only after the implant is already in the eye is too
  // late to do anything useful with the information. A case with no
  // approved plan at all is left alone (non-IOL procedures legitimately
  // have none).
  const { data: sc } = await supabase.from('surgical_cases').select('visit_id').eq('id', surgicalCaseId).single();
  if (sc) {
    const { data: biometryPlans } = await supabase
      .from('biometry_records')
      .select('surgical_eye, final_iol_power, master_iol_catalog:final_iol_catalog_id(manufacturer)')
      .eq('visit_id', sc.visit_id)
      .eq('status', 'Approved');
    const badPlan = (biometryPlans || []).find((p) => !p.final_iol_power || !p.master_iol_catalog?.manufacturer);
    if (badPlan) {
      const missing = !badPlan.final_iol_power ? 'power' : 'manufacturer';
      return { error: `Approved IOL plan for ${badPlan.surgical_eye} is missing its ${missing} -- fix this in Biometry before check-in can be completed.` };
    }
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

  const { data: userData } = await supabase.auth.getUser();

  const { error: recError } = await supabase.from('ot_intraop_records').update({
    implant_manufacturer: values.implantManufacturer || null, implant_model: values.implantModel || null,
    implant_power: values.implantPower || null, implant_serial: values.implantSerial || null,
    implant_expiry: values.implantExpiry || null, implant_eye: values.implantEye || null,
    variance_reason: values.varianceReason || null,
    operative_notes: values.operativeNotes || null,
    surgical_outcome: values.surgicalOutcome || null, outcome_remarks: values.outcomeRemarks || null,
    recovery_destination: values.recoveryDestination || null, recovery_monitoring: values.recoveryMonitoring || null,
    recovery_instructions: values.recoveryInstructions || null, recovery_concerns: values.recoveryConcerns || null,
    completed_at: new Date().toISOString(), completed_by: userData?.user?.id || null,
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
    ot_schedule_id: otScheduleId, action: 'Completed',
    detail: `Surgery completed -- outcome: ${values.surgicalOutcome || '--'} -- handed over to Recovery (${values.recoveryDestination || '--'})`,
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

PYEOF_9026531225534470113

cat > "app/(main)/ot-intraop/page.js" << 'PYEOF_8473880182961137241'
'use client';

import { useState, useEffect, useCallback } from 'react';
import Link from 'next/link';
import { getOTCaseList, getOTIntraopHistory, markPatientReported, unmarkPatientReported } from './actions';
import Workspace from './workspace';

const STATUS_BADGE = { Scheduled: 'b-amber', 'In Progress': 'b-blue' };

function TabButton({ active, onClick, icon, label, disabled }) {
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

function DashboardTab({ cases, loading, onOpen, onRefresh }) {
  const [busyId, setBusyId] = useState(null);

  async function handleToggleReported(e, otId, currentlyReported) {
    e.stopPropagation();
    setBusyId(otId);
    if (currentlyReported) await unmarkPatientReported(otId);
    else await markPatientReported(otId);
    setBusyId(null);
    onRefresh();
  }

  const counts = {
    Scheduled: cases.filter((c) => c.status === 'Scheduled').length,
    'In Progress': cases.filter((c) => c.status === 'In Progress').length,
  };

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Scheduled, not checked in</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Scheduled}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In Progress</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts['In Progress']}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Total open cases</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--red)' }}></i> Today&apos;s OT Cases</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => {
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
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              {canOpen ? (
                <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
              ) : (
                <Link
                  href={`/payments/advance?patientId=${sc.patient_id}&amount=${c.amountPayable.toFixed(2)}&returnTo=ot-intraop`}
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
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No OT cases scheduled for today.</div>
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

export default function OTIntraopPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
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
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

PYEOF_8473880182961137241

cat > "app/(main)/payments/advance/advance-tab.js" << 'PYEOF_6754528184118788745'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import { searchPatientsForPayment, getAdvanceBalance, collectAdvance, getCurrentBalancesByPatient, getLedgerHistory, getTodaysVisits, getPatientById } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const ADVANCE_TYPES = ['Surgery Advance', 'General Advance', 'Package Advance', 'Other'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

const RETURN_LABELS = { 'ot-intraop': 'Operation Theatre' };

export default function AdvanceTab() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const urlPatientId = searchParams.get('patientId');
  const urlAmount = searchParams.get('amount');
  const returnTo = searchParams.get('returnTo');
  const autofillDoneFor = useRef(null);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [currentBalance, setCurrentBalance] = useState(0);

  const [advanceType, setAdvanceType] = useState('Surgery Advance');
  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);

  // Same simplification as Collect Payment: in the common single-mode
  // case, the mode amount always matches the amount field -- no need to
  // type the same number twice.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(null);

  const [balances, setBalances] = useState([]);
  const [history, setHistory] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const refreshSidebar = useCallback(async () => {
    setBalances(await getCurrentBalancesByPatient());
    setHistory(await getLedgerHistory());
  }, []);

  useEffect(() => { refreshSidebar(); }, [refreshSidebar]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  // Arrived from OT Dashboard's "Collect Advance" button -- patient and
  // suggested amount (package price minus whatever advance already
  // exists) are already known, so skip the search step entirely.
  useEffect(() => {
    if (!urlPatientId) return;
    if (autofillDoneFor.current === urlPatientId) return;
    autofillDoneFor.current = urlPatientId;
    (async () => {
      const result = await getPatientById(urlPatientId);
      if (result.error) { setError(result.error); return; }
      await pickPatient(result.patient);
      if (urlAmount) setAmount(urlAmount);
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlPatientId, urlAmount]);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setCurrentBalance(await getAdvanceBalance(p.id));
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setSuccess(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectAdvance(selectedPatient.id, advanceType, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(result.payment);
    refreshSidebar();
  }

  // Collecting via a returnTo link (e.g. from OT Dashboard) means the
  // natural next step is back there, not sitting on this form.
  useEffect(() => {
    if (!success || !returnTo) return;
    const timer = setTimeout(() => router.push(`/${returnTo}`), 2500);
    return () => clearTimeout(timer);
  }, [success, returnTo, router]);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance Collection
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Advance collected without invoice. Balance held in Patient Ledger and adjusted against future invoices.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {success ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Advance collected -- Receipt <strong>{success.receipt_number}</strong> -- Rs.{success.total_amount}
            <div style={{ marginTop: 10, display: 'flex', gap: 8, alignItems: 'center' }}>
              {returnTo ? (
                <>
                  <button className="btn btn-sm btn-primary" onClick={() => router.push(`/${returnTo}`)}>
                    <i className="ti ti-arrow-left"></i> Back to {RETURN_LABELS[returnTo] || returnTo}
                  </button>
                  <span style={{ fontSize: 11, color: 'var(--g400)' }}>Returning automatically...</span>
                </>
              ) : (
                <button className="btn btn-sm" onClick={reset}>Collect another advance</button>
              )}
            </div>
          </div>
        ) : !selectedPatient ? (
          <div>
            <label className="flbl">Patient *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            <div style={{ background: 'var(--purple-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 12, marginTop: 6 }}>Current advance: <strong style={{ color: 'var(--purple)' }}>Rs.{currentBalance}</strong></div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Advance type</label>
                <select className="fi" value={advanceType} onChange={(e) => setAdvanceType(e.target.value)}>
                  {ADVANCE_TYPES.map((t) => <option key={t}>{t}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
            </div>

            <label className="flbl">Payment mode(s) *</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="e.g. Surgery scheduled 30 Jun..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect advance'}
            </button>
          </div>
        )}
      </div>

      <div>
        <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />

        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Current Balance by Patient
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Balance</th></tr></thead>
            <tbody>
              {balances.map((b, i) => (
                <tr key={i}><td>{b.patient?.first_name} {b.patient?.last_name}</td><td style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{b.balance.toFixed(2)}</td></tr>
              ))}
              {balances.length === 0 && <tr><td colSpan={2} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No advances held.</td></tr>}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Transaction History
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Immutable record -- entries are never edited, only added to.
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Type</th><th>Amount</th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td>{h.patients?.first_name} {h.patients?.last_name}</td>
                  <td><span className={`badge ${h.entry_type === 'Advance Collected' ? 'b-green' : 'b-amber'}`}>{h.entry_type}</span></td>
                  <td style={{ fontWeight: 600 }}>Rs.{Math.abs(h.amount).toFixed(2)}</td>
                </tr>
              ))}
              {history.length === 0 && <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}


PYEOF_6754528184118788745

cat > "app/(main)/billing/actions.js" << 'PYEOF_9122428608960856357'
'use server';

import { createClient } from '@/lib/supabase-server';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';

// Same IST-boundary approach as Cash Management -- a plain date string
// compared against a timestamptz column is interpreted at UTC midnight
// by Postgres, not IST midnight, so "today's revenue" would otherwise
// drift by up to 5.5 hours depending on the time of day.
function istDayBoundsUTC() {
  const d = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  return {
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

// ── WS-086: BILLING DASHBOARD -- Recent Invoices + Outstanding Invoices.
// (Revenue-by-department and the daily revenue/collected/cancelled
// stats moved to the Cash Management dashboard.) ──
export async function getBillingDashboardData() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [{ data: todaysInvoices }, { data: allOutstanding }] = await Promise.all([
    supabase
      .from('invoices')
      .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
      .gte('created_at', startUTC)
      .lte('created_at', endUTC)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false }),
    supabase
      .from('invoices')
      .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
      .in('status', ['Pending', 'Partial'])
      .order('created_at', { ascending: true }),
  ]);

  const outstandingInvoices = allOutstanding || [];
  const outstandingTotal = outstandingInvoices.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);

  return {
    todaysInvoices: todaysInvoices || [],
    outstandingInvoices,
    outstandingTotal,
  };
}

// ── TODAY'S VISITS (with per-visit billing status) -- moved here from
// Front Office Dashboard, since New Invoice / Modify are billing
// actions. Front Office keeps its own read-only version of this same
// list without these actions. ──
export async function getTodaysVisitsWithBillingStatus() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: visits } = await supabase
    .from('visits')
    .select('*, patients(id, first_name, last_name, uhid), profiles!doctor_id(full_name)')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .order('created_at', { ascending: false });

  const visitIds = (visits || []).map((v) => v.id);
  const billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, net, paid, status').in('visit_id', visitIds);
    const grouped = {};
    (invoices || []).forEach((inv) => {
      if (!grouped[inv.visit_id]) grouped[inv.visit_id] = [];
      grouped[inv.visit_id].push(inv);
    });
    Object.entries(grouped).forEach(([visitId, invs]) => {
      const active = invs.filter((i) => i.status !== 'Cancelled');
      const outstanding = active.reduce((s, i) => s + Math.max(0, Number(i.net) - Number(i.paid)), 0);
      const allPaid = active.length > 0 && active.every((i) => i.status === 'Paid');
      billingByVisit[visitId] = {
        count: active.length,
        outstanding,
        label: active.length === 0 ? '--' : allPaid ? 'Paid' : `Rs.${outstanding.toLocaleString('en-IN')} due`,
        badge: active.length === 0 ? 'b-gray' : allPaid ? 'b-green' : 'b-red',
      };
    });
  }

  return { visits: visits || [], billingByVisit };
}

export async function getTodaysVisitsForBilling() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

// Lists every invoice already on a visit -- used both by New Invoice
// (to show what exists before deciding to create another) and by
// Invoice Modification (to jump straight to a visit's invoice(s)
// instead of a generic search).
export async function getInvoicesForVisit(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('invoices')
    .select('*, patients(id, first_name, last_name, uhid, mobile)')
    .eq('visit_id', visitId)
    .order('created_at', { ascending: false });
  if (error) return { error: error.message };
  return { invoices: data || [] };
}

// Always creates a brand new invoice -- creating one is now always a
// deliberate action (the "New Invoice" button + a chosen purpose), so
// there's no "get or reuse" ambiguity here. Adding to an existing
// invoice happens through Invoice Modification instead.
export async function createInvoiceForVisit(patientId, visitId, purpose) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_invoice_for_visit', {
    p_patient_id: patientId,
    p_visit_id: visitId || null,
    p_purpose: purpose || 'Consultation',
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data: services } = await supabase.from('master_services').select('*').eq('status', 'Active');
  const { data: drugs } = await supabase.from('master_drugs').select('*').eq('status', 'Active');
  const { data: packages } = await supabase.from('master_packages').select('*').eq('status', 'Active');

  // Drugs live in their own master (managed under Master Data -> Drugs)
  // but bill under the Pharmacy department -- mapped here rather than
  // duplicated into master_services, so Master Data stays the one
  // place to manage drug pricing.
  const drugsAsServices = (drugs || []).map((d) => ({
    code: d.code,
    name: `${d.generic}${d.strength ? ' ' + d.strength : ''}${d.brand ? ' (' + d.brand + ')' : ''}`,
    dept: 'Pharmacy',
    rate: d.rate,
    gst_pct: d.gst_pct,
    status: d.status,
  }));

  // Same mapping for packages -- their own master (Financial Masters ->
  // Surgery tab), billed under the Surgery department. Without this the
  // Surgery dropdown in New Invoice has nothing to show, even though
  // add_invoice_line_item already knows how to look packages up.
  const packagesAsServices = (packages || []).map((p) => ({
    code: p.code,
    name: p.name,
    dept: 'Surgery',
    rate: p.price,
    gst_pct: 0,
    status: p.status,
  }));

  return [...(services || []), ...drugsAsServices, ...packagesAsServices].sort((a, b) => a.name.localeCompare(b.name));
}

export async function addLineItem(invoiceId, serviceCode, qty, discType, discValue, discReason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
    p_disc_type: discType || 'none',
    p_disc_value: discValue || 0,
    p_disc_reason: discReason || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// For ad-hoc line items with no catalog entry behind them -- currently
// only the consolidated "OPD Procedure Consumables" pharmacy line
// (medicines clubbed into one line + total, since there's no pharmacy
// license yet to itemize them). Always qty 1, no GST/discount.
export async function addCustomLineItem(invoiceId, serviceName, amount, dept) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_custom_line_item', {
    p_invoice_id: invoiceId,
    p_service_name: serviceName,
    p_amount: amount,
    p_dept: dept || 'Pharmacy',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── NEW INVOICE (standalone, not tied to visit creation) ──
export async function searchPatientsForInvoice(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getMostRecentVisitForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return data || null;
}
export async function getVisitWithPatient(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('visits')
    .select('*, patients(id, first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();
  if (error) return { error: error.message };
  return { visit: data };
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED INVESTIGATIONS" WIDGET ──
// Takes the investigation_orders selected on the dashboard and turns
// each into a draft line item by matching its free-text name against
// the Investigation department of the service catalog. A name that
// doesn't match anything (e.g. it was typed instead of picked from
// master data back in Consultation) is returned as unmatched so the
// front desk can still see it and add it manually rather than it
// silently vanishing from the invoice.
export async function getInvestigationOrdersForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: orders, error } = await supabase
    .from('investigation_orders')
    .select('id, name, eye, priority, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: catalog } = await supabase.from('master_services').select('*').eq('dept', 'Investigation').eq('status', 'Active');

  const items = (orders || []).map((io) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === io.name.toLowerCase());
    return {
      invOrderId: io.id,
      name: io.name,
      eye: io.eye,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

// Called once the invoice carrying these investigations is actually
// saved (finalized or draft) -- flips them out of the Front Office
// queue and remembers which invoice they landed on, so the Queue can
// show real payment status rather than just "billed".
export async function markInvestigationOrdersBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      billing_status: 'Billed',
      billed: true,
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE WIDGET DATA -- grouped by visit, same shape as
//    getPendingInvestigationBilling() in the investigation module. ──
export async function getPendingProcedureBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .eq('billing_status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((p) => {
    const visitId = p.encounters?.visit_id;
    const visit = p.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(p);
  });

  return Object.values(groups);
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED MINOR PROCEDURES" WIDGET ──
// Same pattern as getInvestigationOrdersForBilling -- matches each
// plan_procedures row against the Minor Procedure department of the
// service catalog by name.
export async function getProceduresForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: orders, error } = await supabase
    .from('plan_procedures')
    .select('id, name, eye, notes, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: catalog } = await supabase.from('master_services').select('*').eq('dept', 'Minor Procedure').eq('status', 'Active');

  const items = (orders || []).map((p) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === p.name.toLowerCase());
    return {
      procedureId: p.id,
      name: p.name,
      eye: p.eye,
      notes: p.notes,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

export async function markProceduresBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_procedures')
    .update({
      billing_status: 'Billed',
      billed: true,
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PREFILL FROM FRONT OFFICE'S "PRESCRIBED MEDICINES" WIDGET ──
// Same idea as investigation prefill, but matched against master_drugs
// the same fuzzy way the pharmacy's own auto-bill RPC does (drug_name
// containing the generic or brand name), since prescriptions are
// free-text ("Timolol 0.5% eye drops") rather than a catalog code.
export async function getPrescriptionsForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: prescriptions, error } = await supabase
    .from('prescriptions')
    .select('id, drug_name, eye, billing_status')
    .in('id', ids);
  if (error) return { error: error.message };

  const { data: drugs } = await supabase.from('master_drugs').select('*').eq('status', 'Active');

  const items = (prescriptions || []).map((rx) => {
    const nameLower = rx.drug_name.toLowerCase();
    const match = (drugs || []).find(
      (d) => (d.generic && nameLower.includes(d.generic.toLowerCase())) || (d.brand && nameLower.includes(d.brand.toLowerCase()))
    );
    return {
      rxId: rx.id,
      name: rx.drug_name,
      eye: rx.eye,
      matched: !!match,
      serviceCode: match?.code || null,
      rate: match?.rate ?? null,
      gstPct: match?.gst_pct ?? null,
    };
  });

  return { items };
}

// Called once the invoice carrying these prescriptions is actually
// saved -- flips them out of the Front Office queue. When the patient
// later reaches Pharmacy, dispense_prescription_and_bill sees
// billing_status = 'Billed' and skips adding a second line item.
export async function markPrescriptionsBilled(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('prescriptions')
    .update({
      billing_status: 'Billed',
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PREFILL FROM FRONT OFFICE'S "BIOMETRY" WIDGET ──
// Unlike investigations/prescriptions, there's exactly one fixed
// billing line for any biometry -- Biometry's own dedicated Financial
// Masters department (separate from Investigation for clarity).
// ── PACKAGE BILLING (Front Office widget) ──
// Package gets locked in Counselling; this is the real invoicing path
// for it -- goes through New Invoice -> Finalize -> Collect Payment like
// everything else, unlike the old generate_package_invoice RPC which
// used to mark the invoice paid directly with no actual payment
// collected (see package-billing-tab.js).
export async function getPendingPackageBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(id, code, name, price)')
    .eq('package_locked', true)
    .eq('package_billed', false)
    .not('package_id', 'is', null);
  if (error) return [];
  return (data || []).filter((sc) => sc.master_packages);
}

// ── Surgery Billing panel (New Invoice) -- Surgery/Eye/Doctor fields
// shown alongside the Package selection, whether prefilled from an
// existing surgical_case (automatic route) or filled in by hand
// (manual route). ──
export async function getSurgeryBillingOptions() {
  const supabase = await createClient();
  const [{ data: surgeries }, { data: doctors }] = await Promise.all([
    supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name'),
    supabase.from('profiles').select('id, full_name').eq('designation', 'Doctor').eq('status', 'Active').order('full_name'),
  ]);
  return { surgeries: surgeries || [], doctors: doctors || [] };
}

// Only used for a manually-entered Surgery bill (no linked
// surgical_case) -- renderInvoiceHtml falls back to these when it can't
// find a case for the invoice's visit.
export async function setManualSurgeryDetails(invoiceId, surgeryName, surgeryEye, surgeonId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('invoices')
    .update({ manual_surgery_name: surgeryName || null, manual_surgery_eye: surgeryEye || null, manual_surgeon_id: surgeonId || null })
    .eq('id', invoiceId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGERY BILLING widget (Billing Dashboard) -- patients who've been
// discharged but whose surgery package still hasn't been billed. This
// is now the actual moment the full surgery invoice gets generated --
// advance was already collected pre-op (OT Dashboard), so this is
// "settle the rest." ──
export async function getDischargedUnbilledSurgeries() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('discharge_date, surgical_cases!inner(id, procedure_name, eye, package_billed, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name, price))')
    .not('discharge_date', 'is', null)
    .eq('surgical_cases.package_billed', false)
    .order('discharge_date', { ascending: true });
  if (error) return [];
  return (data || []).filter((r) => r.surgical_cases);
}
export async function getPackageForBilling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('package_id, procedure_name, eye, surgeon_id, profiles:surgeon_id(full_name), master_packages:package_id(code, name, price)').eq('id', caseId).maybeSingle();
  if (!sc?.master_packages) return { item: null };

  const { data: breakupItems } = await supabase
    .from('package_line_items')
    .select('description, amount')
    .eq('package_id', sc.package_id)
    .order('sort_order');

  return {
    item: {
      caseId, name: sc.master_packages.name, matched: true,
      serviceCode: sc.master_packages.code, rate: sc.master_packages.price, gstPct: 0,
      breakup: breakupItems || [],
      surgeryName: sc.procedure_name, surgeryEye: sc.eye, surgeonId: sc.surgeon_id, surgeonName: sc.profiles?.full_name || null,
    },
  };
}

// Called once the invoice carrying this package is actually saved --
// flips it out of the Front Office queue.
export async function markPackageBilled(caseId, invoiceId) {
  const supabase = await createClient();
  if (!caseId) return { success: true };
  const { error } = await supabase.from('surgical_cases').update({ package_billed: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getBiometryForBilling(ids) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { items: [] };

  const { data: service } = await supabase
    .from('master_services')
    .select('code, name, rate, gst_pct')
    .eq('status', 'Active')
    .eq('dept', 'Biometry')
    .limit(1)
    .maybeSingle();

  if (!service) {
    return { items: ids.map((id) => ({ bioId: id, name: 'Biometry', matched: false })) };
  }

  return {
    items: ids.map((id) => ({
      bioId: id, name: service.name, matched: true,
      serviceCode: service.code, rate: service.rate, gstPct: service.gst_pct,
    })),
  };
}

// Called once the invoice carrying this biometry is actually saved --
// flips it out of the Front Office queue.
export async function markBiometryBilled(ids, invoiceId) {
  const supabase = await createClient();
  if (!ids || ids.length === 0) return { success: true };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: 'Billed',
      invoice_id: invoiceId || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .in('id', ids);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getInvoiceById(invoiceId) {
  const supabase = await createClient();
  const { data: invoice, error } = await supabase.from('invoices').select('*, patients(id, first_name, last_name, uhid, mobile)').eq('id', invoiceId).single();
  if (error) return { error: error.message };
  const { data: lineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');
  return { invoice, lineItems: lineItems || [] };
}

export async function removeLineItem(lineItemId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId, p_reason: reason || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function cancelInvoice(invoiceId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('cancel_invoice', { p_invoice_id: invoiceId, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

// ── PACKAGE BILLING ──
export async function getPostSurgicalPendingPackages() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('surgical_cases')
    .select('*, patients(id, first_name, last_name, uhid), master_packages(id, name, price)')
    .eq('status', 'Completed')
    .eq('package_billed', false);
  return data || [];
}

export async function getActivePackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function searchPatientsForPackage(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function generatePackageInvoice(patientId, packageId, paymentMode, advanceAmount, surgicalCaseId) {
  const supabase = await createClient();

  // Surgery bill can only be generated once the patient has actually
  // been discharged (hospital policy). This blocks the invoice itself,
  // not advance collection -- a pre-op advance still goes through the
  // separate Advance tab in Payments (collectAdvance), unaffected here.
  if (surgicalCaseId) {
    const { data: episode } = await supabase
      .from('recovery_episodes')
      .select('discharge_date')
      .eq('surgical_case_id', surgicalCaseId)
      .maybeSingle();
    if (!episode || !episode.discharge_date) {
      return { error: 'The surgery bill can only be generated after the patient has been discharged. To collect a pre-op advance instead, use the Advance tab in Payments.' };
    }
  }

  if (advanceAmount && Number(advanceAmount) > 0) {
    const blocked = await requireDayOpen();
    if (blocked) return blocked;
  }

  const { data: visit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data, error } = await supabase.rpc('generate_package_invoice', {
    p_patient_id: patientId,
    p_visit_id: visit?.id || null,
    p_package_id: packageId,
    p_payment_mode: paymentMode,
    p_advance_amount: advanceAmount || 0,
    p_surgical_case_id: surgicalCaseId || null,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── INVOICE DETAILS (search + history) ──
export async function getTodaysInvoicesForModification() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function searchInvoices(query, deptFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
    .order('created_at', { ascending: false })
    .limit(50);

  if (query) {
    // First try to match by patient -- invoices don't carry patient
    // name/uhid directly, so we resolve matching patient ids first.
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    if (ids.length === 0) return [];
    q = q.in('patient_id', ids);
  }

  const { data: invoices } = await q;
  if (!invoices || invoices.length === 0) return [];

  if (!deptFilter) return invoices;

  // Department filter is per-line-item, not per-invoice -- keep only
  // invoices that have at least one line item in that department.
  const invoiceIds = invoices.map((i) => i.id);
  const { data: lines } = await supabase.from('invoice_line_items').select('invoice_id, dept').in('invoice_id', invoiceIds).eq('dept', deptFilter);
  const matchingIds = new Set((lines || []).map((l) => l.invoice_id));
  return invoices.filter((i) => matchingIds.has(i.id));
}

// NOTE: recordPayment/record_payment was removed (Migration 36) --
// it bypassed the real payment ledger (payments/payment_modes/
// payment_allocations), leaving invoices.paid inconsistent with
// actual receipts. Use Collect Payment (payments/collect) instead,
// which properly creates a full payment record.



PYEOF_9122428608960856357

cat > "app/(main)/billing/page.js" << 'PYEOF_3503107238966572110'
import Link from 'next/link';
import BillingTabs from './billing-tabs';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus, getDischargedUnbilledSurgeries } from './actions';
import RecentInvoicesTable from './recent-invoices-table';
import PendingBillingWidget from './pending-billing-widget';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

export default async function BillingDashboardPage() {
  const [data, todaysVisitsData, dischargedUnbilled] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
    getDischargedUnbilledSurgeries(),
  ]);
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />

      {/* SURGERY BILLING -- discharged patients whose surgery package
          hasn't been billed yet. Advance was already collected pre-op
          (OT Dashboard); this is where the full invoice actually gets
          generated. */}
      {dischargedUnbilled.length > 0 && (
        <div className="card" style={{ marginBottom: 20, border: '1.5px solid var(--red)' }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery Billing
            <span className="badge b-red" style={{ marginLeft: 8 }}>{dischargedUnbilled.length}</span>
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            Discharged, package not yet billed. Click a patient to open New Invoice, prefilled and editable.
          </div>
          <table className="tbl">
            <thead><tr><th>Discharged</th><th>Patient</th><th>Surgery</th><th>Package</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {dischargedUnbilled.map((r) => {
                const sc = r.surgical_cases;
                return (
                  <tr key={sc.id}>
                    <td style={{ fontSize: 12 }}>{new Date(r.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                    <td>
                      <strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong>
                      <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span>
                    </td>
                    <td style={{ fontSize: 12 }}>{sc.procedure_name} ({sc.eye})</td>
                    <td style={{ fontSize: 12 }}>{sc.master_packages?.name || '--'}</td>
                    <td style={{ fontWeight: 600 }}>{RUPEE(sc.master_packages?.price)}</td>
                    <td>
                      <Link href={`/billing/new?pkgCaseId=${sc.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> Bill Now
                      </Link>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* TODAY'S VISITS + PENDING BILLING side by side */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <table className="tbl">
            <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
            <tbody>
              {todaysVisits.map((v) => {
                const billing = billingByVisit[v.id] || { count: 0, label: '--', badge: 'b-gray' };
                return (
                  <tr key={v.id}>
                    <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                    <td>{new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td>
                      <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                      <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                    </td>
                    <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                    <td>{v.profiles?.full_name || '--'}</td>
                    <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                    <td>
                      {billing.badge === 'b-red' && v.patients?.id ? (
                        <Link href={`/payments/collect?patientId=${v.patients.id}`} className="badge b-red" style={{ textDecoration: 'none', cursor: 'pointer' }}>
                          {billing.label}
                        </Link>
                      ) : (
                        <span className={`badge ${billing.badge}`}>{billing.label}</span>
                      )}
                      {billing.count > 1 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>({billing.count} invoices)</span>}
                    </td>
                    <td>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                          <i className="ti ti-receipt"></i> New Invoice
                        </Link>
                        {billing.count > 0 && (
                          <Link href={`/billing/cancel?visitId=${v.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                            <i className="ti ti-edit"></i> Modify
                          </Link>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {todaysVisits.length === 0 && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <PendingBillingWidget />
      </div>

      {/* RECENT INVOICES + OUTSTANDING */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        <RecentInvoicesTable invoices={data.todaysInvoices} />

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Outstanding Invoices</div>
            <span className="badge b-amber">{data.outstandingInvoices.length} pending</span>
          </div>
          <div style={{ maxHeight: 320, overflowY: 'auto' }}>
            {data.outstandingInvoices.map((inv) => (
              <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <div style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{inv.patients?.uhid} -- {inv.purpose || '--'}</div>
                </div>
                <div style={{ textAlign: 'right' }}>
                  <div style={{ fontWeight: 700, color: 'var(--red)' }}>{RUPEE(Number(inv.net) - Number(inv.paid))}</div>
                  <Link href={`/payments/collect?patientId=${inv.patient_id}&invoiceId=${inv.id}`} style={{ fontSize: 11, color: 'var(--blue)', textDecoration: 'none' }}>
                    Collect &rarr;
                  </Link>
                </div>
              </div>
            ))}
            {data.outstandingInvoices.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>Nothing outstanding.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
PYEOF_3503107238966572110

cat > "app/(main)/billing/new/new-invoice-tab.js" << 'PYEOF_1033067313226935572'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  getMostRecentVisitForPatient,
  getVisitWithPatient,
  getInvoicesForVisit,
  createInvoiceForVisit,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  getTodaysVisitsForBilling,
  getInvestigationOrdersForBilling,
  markInvestigationOrdersBilled,
  getPrescriptionsForBilling,
  markPrescriptionsBilled,
  getBiometryForBilling,
  markBiometryBilled,
  getProceduresForBilling,
  markProceduresBilled,
  getPackageForBilling,
  markPackageBilled,
  getSurgeryBillingOptions,
  setManualSurgeryDetails,
} from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure', 'Surgery', 'Pharmacy'];
const DEFAULT_PURPOSE = 'Consultation';

// Mirrors add_invoice_line_item's math exactly, so the running totals
// shown before committing match what the database will compute.
function computeLine(svc, qty, discType, discValue) {
  const gross = svc.rate * qty;
  let disc = 0;
  if (discType === 'pct') disc = Math.round((gross * discValue / 100) * 100) / 100;
  else if (discType === 'fixed') disc = Math.min(discValue, gross);
  const taxable = gross - disc;
  const gst = Math.round((taxable * svc.gst_pct / 100) * 100) / 100;
  const net = taxable + gst;
  return { gross, disc, gst, net };
}

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);

  // Context: who we're billing. Never written to the database by
  // itself -- picking, browsing, or changing your mind is always free.
  const [contextPatient, setContextPatient] = useState(null);
  const [contextVisit, setContextVisit] = useState(null);
  const [existingInvoices, setExistingInvoices] = useState([]);

  // Draft line items live only in this component's state until
  // Finalize or Save Draft. Nothing is persisted before that.
  const [draftLines, setDraftLines] = useState([]);
  const [packageBreakup, setPackageBreakup] = useState(null);

  // Surgery Billing panel -- Surgery / Operated Eye / Doctor. Locked
  // (read-only) when fetched from an existing surgical_case (the
  // automatic route from OT/Counselling); editable when billing Surgery
  // manually with no linked case.
  const [surgeryName, setSurgeryName] = useState('');
  const [surgeryEyeField, setSurgeryEyeField] = useState('');
  const [surgeryDoctorId, setSurgeryDoctorId] = useState('');
  const [surgeryOptions, setSurgeryOptions] = useState([]);
  const [surgeryDoctorOptions, setSurgeryDoctorOptions] = useState([]);
  const nextTempId = useRef(1);

  const [catalog, setCatalog] = useState([]);
  const [dept, setDept] = useState('');
  const [selectedServiceCode, setSelectedServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [error, setError] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);
  const [unmatchedInvestigations, setUnmatchedInvestigations] = useState([]);
  const [unmatchedPrescriptions, setUnmatchedPrescriptions] = useState([]);
  const [unmatchedBiometry, setUnmatchedBiometry] = useState([]);
  const [unmatchedProcedures, setUnmatchedProcedures] = useState([]);
  const router = useRouter();
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const urlInvOrderIds = searchParams.get('invOrderIds');
  const urlRxIds = searchParams.get('rxIds');
  const urlBioIds = searchParams.get('bioIds');
  const urlProcIds = searchParams.get('procIds');
  const urlPkgCaseId = searchParams.get('pkgCaseId');
  const contextLoadedFor = useRef(null);
  const invOrdersLoadedFor = useRef(null);
  const rxLoadedFor = useRef(null);
  const bioLoadedFor = useRef(null);
  const procLoadedFor = useRef(null);
  const pkgLoadedFor = useRef(null);

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
    getTodaysVisitsForBilling().then(setTodaysVisits);
    getSurgeryBillingOptions().then(({ surgeries, doctors }) => { setSurgeryOptions(surgeries); setSurgeryDoctorOptions(doctors); });
  }, []);

  useEffect(() => {
    if (!urlVisitId) return;
    if (contextLoadedFor.current === urlVisitId) return;
    contextLoadedFor.current = urlVisitId;
    (async () => {
      const details = await getVisitWithPatient(urlVisitId);
      if (details.error) { setError(details.error); return; }
      setContextPatient(details.visit.patients);
      setContextVisit(details.visit);
      const invResult = await getInvoicesForVisit(urlVisitId);
      setExistingInvoices(invResult.invoices || []);
    })();
  }, [urlVisitId]);

  // Prefill from Front Office's "Prescribed Investigations" widget --
  // waits for the visit/patient context above to land first (it needs
  // patient to exist before there's anywhere to add lines to), then
  // turns each selected investigation order into a draft line item.
  useEffect(() => {
    if (!urlInvOrderIds || !contextPatient) return;
    if (invOrdersLoadedFor.current === urlInvOrderIds) return;
    invOrdersLoadedFor.current = urlInvOrderIds;
    (async () => {
      const ids = urlInvOrderIds.split(',').filter(Boolean);
      const result = await getInvestigationOrdersForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedInvestigations(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceInvOrderId: i.invOrderId,
            serviceCode: i.serviceCode, serviceName: `${i.name} (${i.eye})`, dept: 'Investigation',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlInvOrderIds, contextPatient]);

  // Prefill from Front Office's "Prescribed Minor Procedures" widget --
  // same pattern as investigations above, matched against the Minor
  // Procedure department of the service catalog.
  useEffect(() => {
    if (!urlProcIds || !contextPatient) return;
    if (procLoadedFor.current === urlProcIds) return;
    procLoadedFor.current = urlProcIds;
    (async () => {
      const ids = urlProcIds.split(',').filter(Boolean);
      const result = await getProceduresForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedProcedures(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceProcId: i.procedureId,
            serviceCode: i.serviceCode, serviceName: `${i.name} (${i.eye})`, dept: 'Minor Procedure',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlProcIds, contextPatient]);

  // Prefill from Front Office's "Prescribed Medicines" widget -- same
  // pattern as investigations above, matched against the drug catalog.
  // Stored itemized (one line per drug) so Invoice Details still shows
  // exactly what was billed -- the print/PDF copy is what collapses
  // these into a single "OPD Procedure Consumables" line, since there's
  // no pharmacy license yet to show individual drug names externally.
  useEffect(() => {
    if (!urlRxIds || !contextPatient) return;
    if (rxLoadedFor.current === urlRxIds) return;
    rxLoadedFor.current = urlRxIds;
    (async () => {
      const ids = urlRxIds.split(',').filter(Boolean);
      const result = await getPrescriptionsForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedPrescriptions(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceRxId: i.rxId,
            serviceCode: i.serviceCode, serviceName: `${i.name}${i.eye ? ' (' + i.eye + ')' : ''}`, dept: 'Pharmacy',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlRxIds, contextPatient]);

  // Prefill from Front Office's "Biometry" widget -- always exactly one
  // fixed-price line, no name-matching needed.
  useEffect(() => {
    if (!urlBioIds || !contextPatient) return;
    if (bioLoadedFor.current === urlBioIds) return;
    bioLoadedFor.current = urlBioIds;
    (async () => {
      const ids = urlBioIds.split(',').filter(Boolean);
      const result = await getBiometryForBilling(ids);
      if (result.error) { setError(result.error); return; }

      const matched = (result.items || []).filter((i) => i.matched);
      const unmatched = (result.items || []).filter((i) => !i.matched);
      setUnmatchedBiometry(unmatched);

      setDraftLines((prev) => [
        ...prev,
        ...matched.map((i) => {
          const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
          return {
            tempId: nextTempId.current++,
            sourceBioId: i.bioId,
            serviceCode: i.serviceCode, serviceName: i.name, dept: 'Biometry',
            qty: 1, rate: i.rate, gstPct: i.gstPct,
            discType: 'none', discValue: 0, discReason: '',
            ...computed,
          };
        }),
      ]);
    })();
  }, [urlBioIds, contextPatient]);

  // Prefill from Front Office's "Package Billing" widget -- the package
  // locked in Counselling, billed the same way as everything else
  // (through this screen -> Finalize -> Collect Payment), unlike the
  // old auto-pay Package Billing tab.
  useEffect(() => {
    if (!urlPkgCaseId || !contextPatient) return;
    if (pkgLoadedFor.current === urlPkgCaseId) return;
    pkgLoadedFor.current = urlPkgCaseId;
    (async () => {
      const result = await getPackageForBilling(urlPkgCaseId);
      if (result.error) { setError(result.error); return; }
      if (!result.item) return;
      const i = result.item;
      setPackageBreakup(i.breakup && i.breakup.length > 0 ? i.breakup : null);
      setSurgeryName(i.surgeryName || '');
      setSurgeryEyeField(i.surgeryEye || '');
      setSurgeryDoctorId(i.surgeonId || '');
      const computed = computeLine({ rate: i.rate, gst_pct: i.gstPct }, 1, 'none', 0);
      setDraftLines((prev) => [
        ...prev,
        {
          tempId: nextTempId.current++,
          sourcePkgCaseId: i.caseId,
          serviceCode: i.serviceCode, serviceName: i.name, dept: 'Surgery',
          qty: 1, rate: i.rate, gstPct: i.gstPct,
          discType: 'none', discValue: 0, discReason: '',
          ...computed,
        },
      ]);
    })();
  }, [urlPkgCaseId, contextPatient]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvoice(searchQuery.trim());
    setSearchResults(results);
  }

  async function pickPatient(p) {
    setError('');
    setSearchResults([]);
    setSearchQuery('');
    setContextPatient(p);
    const visit = await getMostRecentVisitForPatient(p.id);
    setContextVisit(visit);
    if (visit) {
      const invResult = await getInvoicesForVisit(visit.id);
      setExistingInvoices(invResult.invoices || []);
    } else {
      setExistingInvoices([]);
    }
  }

  async function pickVisit(v) {
    setError('');
    setContextPatient(v.patients);
    setContextVisit(v);
    const invResult = await getInvoicesForVisit(v.id);
    setExistingInvoices(invResult.invoices || []);
  }

  function handleDeptChange(e) {
    setDept(e.target.value);
    setSelectedServiceCode('');
    setRate('');
    setGstPct('');
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setSelectedServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  function handleAddLine() {
    setError('');
    if (!selectedServiceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const svc = catalog.find((s) => s.code === selectedServiceCode);
    const q = parseInt(qty, 10) || 1;
    const dv = parseFloat(discValue) || 0;
    const computed = computeLine(svc, q, discType, dv);

    setDraftLines((prev) => [...prev, {
      tempId: nextTempId.current++,
      serviceCode: svc.code, serviceName: svc.name, dept: svc.dept,
      qty: q, rate: svc.rate, gstPct: svc.gst_pct,
      discType, discValue: dv, discReason,
      ...computed,
    }]);

    setDept(''); setSelectedServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
  }

  function handleRemoveLine(tempId) {
    setDraftLines((prev) => prev.filter((l) => l.tempId !== tempId));
  }

  // The one moment anything gets written -- creates the invoice, then
  // every draft line item on it, in order.
  async function commitInvoice() {
    setError('');
    if (draftLines.length === 0) { setError('Add at least one line item before saving.'); return null; }
    setSubmitting(true);

    // purpose drives the "Department" shown in Billing Dashboard /
    // Revenue by Department -- it must reflect what's actually being
    // billed, not always default to Consultation. Surgery takes
    // priority if present (it's what also decides which print template
    // renders), otherwise whichever department was billed first.
    const deptsPresent = draftLines.map((l) => l.dept);
    const purpose = deptsPresent.includes('Surgery') ? 'Surgery' : (deptsPresent[0] || DEFAULT_PURPOSE);

    const created = await createInvoiceForVisit(contextPatient.id, contextVisit?.id || null, purpose);
    if (created.error) { setSubmitting(false); setError(created.error); return null; }

    for (const line of draftLines) {
      const result = await addLineItem(created.invoice.id, line.serviceCode, line.qty, line.discType, line.discValue, line.discReason);
      if (result.error) {
        setSubmitting(false);
        setError(`Invoice created, but failed adding ${line.serviceName}: ${result.error}. Finish it from Invoice Details.`);
        return null;
      }
    }

    const details = await getInvoiceById(created.invoice.id);

    const billedInvOrderIds = draftLines.map((l) => l.sourceInvOrderId).filter(Boolean);
    if (billedInvOrderIds.length > 0) await markInvestigationOrdersBilled(billedInvOrderIds, created.invoice.id);
    const billedProcIds = draftLines.map((l) => l.sourceProcId).filter(Boolean);
    if (billedProcIds.length > 0) await markProceduresBilled(billedProcIds, created.invoice.id);

    const billedRxIds = draftLines.map((l) => l.sourceRxId).filter(Boolean);
    if (billedRxIds.length > 0) await markPrescriptionsBilled(billedRxIds);

    const billedBioIds = draftLines.map((l) => l.sourceBioId).filter(Boolean);
    if (billedBioIds.length > 0) await markBiometryBilled(billedBioIds, created.invoice.id);

    const billedPkgCaseId = draftLines.find((l) => l.sourcePkgCaseId)?.sourcePkgCaseId;
    if (billedPkgCaseId) await markPackageBilled(billedPkgCaseId, created.invoice.id);

    // Fields are always editable now (whether prefilled from a case via
    // the automatic route, or entered by hand), so whatever's in the
    // form at commit time is what should print -- save it whenever a
    // Surgery line was actually added. dept has already been reset by
    // now (cleared after each Add), so this checks the actual lines
    // added rather than current form state.
    const hasSurgeryLine = draftLines.some((l) => l.dept === 'Surgery');
    if (hasSurgeryLine && surgeryName) {
      await setManualSurgeryDetails(created.invoice.id, surgeryName, surgeryEyeField, surgeryDoctorId);
    }

    setSubmitting(false);
    return details.invoice;
  }

  async function handleFinalize() {
    const inv = await commitInvoice();
    if (!inv) return;
    if (Number(inv.net) <= 0) {
      // Nothing to collect (e.g. fully discounted) -- the invoice is
      // already Paid, so there's no payment to send anyone to.
      router.push(`/billing/details?q=${contextPatient.uhid}`);
      return;
    }
    router.push(`/payments/collect?patientId=${contextPatient.id}&invoiceId=${inv.id}`);
  }

  async function handleSaveDraft() {
    const inv = await commitInvoice();
    if (!inv) return;
    router.push('/billing/details');
  }

  function startOver() {
    setContextPatient(null);
    setContextVisit(null);
    setExistingInvoices([]);
    setDraftLines([]);
    setUnmatchedInvestigations([]);
    setUnmatchedPrescriptions([]);
    setUnmatchedBiometry([]);
    setSurgeryName('');
    setSurgeryEyeField('');
    setSurgeryDoctorId('');
    contextLoadedFor.current = null;
    invOrdersLoadedFor.current = null;
    rxLoadedFor.current = null;
    bioLoadedFor.current = null;
    procLoadedFor.current = null;
    pkgLoadedFor.current = null;
    router.push('/billing/new');
  }

  const totals = draftLines.reduce((acc, l) => ({
    gross: acc.gross + l.gross, gst: acc.gst + l.gst, net: acc.net + l.net,
  }), { gross: 0, gst: 0, net: 0 });

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Invoice
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!contextPatient ? (
          <div>
            <label className="flbl">Find patient (name, UHID, or mobile)</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : (
          <div>
            {existingInvoices.length > 0 && (
              <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> This visit also has {existingInvoices.length} other invoice{existingInvoices.length > 1 ? 's' : ''}
                {contextVisit && <> -- <a href={`/billing/cancel?visitId=${contextVisit.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>view / modify them</a></>}
              </div>
            )}
            {unmatchedInvestigations.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedInvestigations.length} prescribed investigation{unmatchedInvestigations.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced service and weren&apos;t added automatically -- add manually below: {unmatchedInvestigations.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedPrescriptions.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedPrescriptions.length} prescribed medicine{unmatchedPrescriptions.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced drug and weren&apos;t added automatically -- add manually below: {unmatchedPrescriptions.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedProcedures.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> {unmatchedProcedures.length} prescribed minor procedure{unmatchedProcedures.length > 1 ? 's' : ''} couldn&apos;t be matched to a priced service and weren&apos;t added automatically -- add manually below: {unmatchedProcedures.map((i) => i.name).join(', ')}
              </div>
            )}
            {unmatchedBiometry.length > 0 && (
              <div className="msg-err" style={{ fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-alert-triangle"></i> No active "Biometry" service found in Financial Masters -- add the charge manually below.
              </div>
            )}
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span>
                <strong>{contextPatient.first_name} {contextPatient.last_name}</strong> -- {contextPatient.uhid}
                <span style={{ marginLeft: 8 }} className="badge b-gray">Draft -- not saved yet</span>
              </span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Department *</label>
                <select className="fi" value={dept} onChange={handleDeptChange}>
                  <option value="">-- Select --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Service *</label>
                <select className="fi" value={selectedServiceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">{dept ? '-- Select --' : '-- Select dept first --'}</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
                </select>
              </div>
            </div>

            {(dept === 'Surgery' || draftLines.some((l) => l.dept === 'Surgery')) && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', marginBottom: 8 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                  <i className="ti ti-scalpel"></i> Surgery Billing Details
                  <span style={{ fontWeight: 400, color: 'var(--g400)', marginLeft: 6 }}>(prefilled from patient record where available -- edit if needed)</span>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                  <div>
                    <label className="flbl">Surgery</label>
                    <select className="fi fi-sm" value={surgeryName} onChange={(e) => setSurgeryName(e.target.value)}>
                      <option value="">-- Select surgery --</option>
                      {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                    </select>
                  </div>
                  <div>
                    <label className="flbl">Operated Eye</label>
                    <select className="fi fi-sm" value={surgeryEyeField} onChange={(e) => setSurgeryEyeField(e.target.value)}>
                      <option value="">-- Select --</option>
                      <option value="OD">Right (OD)</option>
                      <option value="OS">Left (OS)</option>
                      <option value="OU">Both (OU)</option>
                    </select>
                  </div>
                  <div>
                    <label className="flbl">Doctor</label>
                    <select className="fi fi-sm" value={surgeryDoctorId} onChange={(e) => setSurgeryDoctorId(e.target.value)}>
                      <option value="">-- Select doctor --</option>
                      {surgeryDoctorOptions.map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                    </select>
                  </div>
                </div>
                <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 6 }}>
                  Package is billed as the line item below (Service dropdown, filtered to Surgery) -- these three fields print on the Surgery Bill alongside it.
                </div>
              </div>
            )}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Qty</label>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
              </div>
              <div>
                <label className="flbl">Unit rate (Rs.)</label>
                <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
              </div>
              <div>
                <label className="flbl">GST %</label>
                <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
              <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                <option value="none">No discount</option>
                <option value="pct">Percentage (%)</option>
                <option value="fixed">Fixed (Rs.)</option>
              </select>
              <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
              <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
            </div>

            <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
              <i className="ti ti-plus"></i> Add line item
            </button>

            {packageBreakup && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', marginBottom: 16, background: 'var(--g50)' }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>
                  <i className="ti ti-list-details"></i> Package Breakup <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(reference only -- the invoice still bills the package as one line item; won't print unless "Include package breakup" is chosen when printing)</span>
                </div>
                {packageBreakup.map((b, idx) => (
                  <div key={idx} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '2px 0' }}>
                    <span style={{ color: 'var(--g600)' }}>{b.description}</span>
                    <span style={{ fontWeight: 600 }}>Rs.{Number(b.amount).toLocaleString('en-IN')}</span>
                  </div>
                ))}
              </div>
            )}

            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Rate</th><th>Disc</th><th>GST</th><th>Net</th><th></th></tr></thead>
              <tbody>
                {draftLines.map((li) => (
                  <tr key={li.tempId}>
                    <td>{li.serviceName}{(li.sourceInvOrderId || li.sourceRxId || li.sourceBioId || li.sourceProcId || li.sourcePkgCaseId) && <span className="badge b-purple" style={{ marginLeft: 6, fontSize: 9 }}>Prescribed</span>}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.rate}</td>
                    <td>{li.disc > 0 ? `Rs.${li.disc}` : '--'}</td>
                    <td>Rs.{li.gst.toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{li.net.toFixed(2)}</td>
                    <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(li.tempId)}>Remove</button></td>
                  </tr>
                ))}
                {draftLines.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet -- nothing is saved until you finalize or save draft.</td></tr>
                )}
              </tbody>
            </table>

            <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
              <button className="btn btn-green" onClick={handleFinalize} disabled={submitting}>
                <i className="ti ti-circle-check"></i> {submitting ? 'Saving...' : 'Finalize invoice'}
              </button>
              <button className="btn" onClick={handleSaveDraft} disabled={submitting}>
                <i className="ti ti-device-floppy"></i> {submitting ? 'Saving...' : 'Save draft'}
              </button>
            </div>
          </div>
        )}
      </div>

      <div>
        {!urlVisitId && (
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to bill against it.</div>
            {todaysVisits.map((v) => (
              <div
                key={v.id}
                onClick={() => pickVisit(v)}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
              >
                <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
                <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
              </div>
            ))}
            {todaysVisits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
          </div>
        )}

        {contextPatient && (
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Running Total
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Gross</span><span>Rs.{totals.gross.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>GST</span><span>Rs.{totals.gst.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Net Total</span><span>Rs.{totals.net.toFixed(2)}</span></div>
              <div style={{ marginTop: 8, fontSize: 11, color: 'var(--g400)' }}>Not saved until you finalize or save draft.</div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}


PYEOF_1033067313226935572

cat > "app/(main)/billing/pending-billing-widget.js" << 'PYEOF_5592137602346015149'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingInvestigationBilling, markInvestigationDenied, markInvestigationDeferred, resetInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingProcedureBilling } from '@/app/(main)/billing/actions';
import { getPendingPrescriptionsForFrontOffice, markPrescriptionDenied, markPrescriptionDeferred, resetPrescriptionBilling } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling, markBiometryDenied, markBiometryDeferred, resetBiometryBilling } from '@/app/(main)/biometry/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

const TYPE_META = {
  Investigation: { icon: 'ti-flask', color: 'var(--teal)' },
  Procedure: { icon: 'ti-tool', color: 'var(--blue)' },
  Pharmacy: { icon: 'ti-pill', color: 'var(--purple)' },
  Biometry: { icon: 'ti-ruler-measure', color: 'var(--indigo)' },
};

// One row of items within a patient's card for a single pending-billing
// type (e.g. their pending investigations). Handles its own defer/deny/
// reset actions where that type supports them.
function TypeSection({ type, group, busyId, onDefer, onDeny, onReset, onBillNow, renderItem }) {
  const meta = TYPE_META[type];
  return (
    <div style={{ marginTop: 8, paddingTop: 8, borderTop: '1px dashed var(--g200)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: meta.color }}>
          <i className={`ti ${meta.icon}`}></i> {type}
        </span>
        <button className="btn btn-sm" style={{ fontSize: 10, padding: '2px 8px' }} onClick={() => onBillNow(group)}>
          <i className="ti ti-receipt"></i> Bill Now
        </button>
      </div>
      {group.items.map((item) => (
        <div key={item.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12, flexWrap: 'wrap', gap: 4 }}>
          <div>
            {renderItem(item)}
            {item.billing_status && <span className={`badge ${BILLING_BADGE[item.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{item.billing_status}</span>}
          </div>
          {item.billing_status && (
            <div style={{ display: 'flex', gap: 4 }}>
              {item.billing_status === 'Pending' && onDefer && (
                <>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onDefer(item.id)}>
                    <i className="ti ti-clock"></i>
                  </button>
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === item.id} onClick={() => onDeny(item.id)}>
                    <i className="ti ti-x"></i>
                  </button>
                </>
              )}
              {item.billing_status === 'Deferred' && onReset && (
                <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === item.id} onClick={() => onReset(item.id)}>
                  Reset
                </button>
              )}
            </div>
          )}
        </div>
      ))}
    </div>
  );
}

export default function PendingBillingWidget() {
  const [investigations, setInvestigations] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [pharmacy, setPharmacy] = useState([]);
  const [biometry, setBiometry] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState(null);
  const router = useRouter();

  const load = useCallback(async () => {
    const [inv, proc, rx, bio] = await Promise.all([
      getPendingInvestigationBilling(),
      getPendingProcedureBilling(),
      getPendingPrescriptionsForFrontOffice(),
      getPendingBiometryBilling(),
    ]);
    setInvestigations(inv);
    setProcedures(proc);
    setPharmacy(rx);
    setBiometry(bio);
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function withBusy(id, fn) {
    setBusyId(id);
    await fn(id);
    await load();
    setBusyId(null);
  }

  // Group everything by patient id -- package billing has no visitId, so
  // patient id is the only key common to all five sources.
  const byPatient = {};
  function ensurePatient(patient) {
    if (!patient?.id) return null;
    if (!byPatient[patient.id]) byPatient[patient.id] = { patient, types: {} };
    return byPatient[patient.id];
  }

  investigations.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Investigation = g; });
  procedures.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Procedure = g; });
  pharmacy.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Pharmacy = g; });
  biometry.forEach((g) => { const p = ensurePatient(g.patient); if (p) p.types.Biometry = g; });

  const patients = Object.values(byPatient);
  const totalItems = patients.reduce((s, p) => s + Object.values(p.types).reduce((s2, g) => s2 + g.items.length, 0), 0);

  function billNowFor(type, group) {
    const ids = group.items.map((i) => i.id).join(',');
    const param = { Investigation: 'invOrderIds', Procedure: 'procIds', Pharmacy: 'rxIds', Biometry: 'bioIds' }[type];
    router.push(`/billing/new?visitId=${group.visitId}&${param}=${ids}`);
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-clipboard-list" style={{ color: 'var(--red)' }}></i> Pending Billing</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Everything prescribed or recommended for a patient, not yet billed -- grouped by patient across investigations, procedures, pharmacy, biometry, and packages.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && patients.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- everything is billed.</div>
      )}

      {!loading && patients.map(({ patient, types }) => (
        <div key={patient.id} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 6, flexWrap: 'wrap' }}>
            <div style={{ fontWeight: 600, fontSize: 13 }}>{patient.first_name} {patient.last_name}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{patient.uhid}</div>
            <div style={{ display: 'flex', gap: 4, marginLeft: 'auto' }}>
              {Object.keys(types).map((type) => (
                <span key={type} className="badge" style={{ background: `${TYPE_META[type].color}20`, color: TYPE_META[type].color, fontSize: 9 }}>{type}</span>
              ))}
            </div>
          </div>

          {types.Investigation && (
            <TypeSection
              type="Investigation" group={types.Investigation} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markInvestigationDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markInvestigationDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetInvestigationBilling)}
              onBillNow={(g) => billNowFor('Investigation', g)}
              renderItem={(io) => <>{io.name} <span style={{ color: 'var(--g400)' }}>({io.eye})</span></>}
            />
          )}
          {types.Procedure && (
            <TypeSection
              type="Procedure" group={types.Procedure} busyId={busyId}
              onBillNow={(g) => billNowFor('Procedure', g)}
              renderItem={(p) => <>{p.name} <span style={{ color: 'var(--g400)' }}>({p.eye})</span>{p.notes && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.notes}</div>}</>}
            />
          )}
          {types.Pharmacy && (
            <TypeSection
              type="Pharmacy" group={types.Pharmacy} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markPrescriptionDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markPrescriptionDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetPrescriptionBilling)}
              onBillNow={(g) => billNowFor('Pharmacy', g)}
              renderItem={(rx) => <>{rx.drug_name} <span style={{ color: 'var(--g400)' }}>({rx.eye})</span></>}
            />
          )}
          {types.Biometry && (
            <TypeSection
              type="Biometry" group={types.Biometry} busyId={busyId}
              onDefer={(id) => withBusy(id, (x) => markBiometryDeferred(x, 'Patient asked to come back later'))}
              onDeny={(id) => withBusy(id, (x) => markBiometryDenied(x, 'Patient declined at Front Office'))}
              onReset={(id) => withBusy(id, resetBiometryBilling)}
              onBillNow={(g) => billNowFor('Biometry', g)}
              renderItem={() => <>Biometry</>}
            />
          )}
        </div>
      ))}
    </div>
  );
}
PYEOF_5592137602346015149

cat > "app/print-templates/actions.js" << 'PYEOF_1197692373035022558'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';

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
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Chief Complaint</div>\n    <div style=\"font-size: 12.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\"></th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Left Eye (LE)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">IOP (mmHg)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n      {{#if hasRefraction}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px; font-weight: 600;\">Refraction (Sph/Cyl/Axis)</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{re_refraction}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{le_refraction}}</td>\n      </tr>\n      {{/if}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 12.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 6px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{drug}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{dosage}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{duration}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Advice</div>\n    <div style=\"font-size: 12.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #123a66; margin-bottom: 16px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n"
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Printed for a completed investigation -- findings, notes, technician/verifier sign-off.' },
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
  visit: { created_at: '2026-06-01T00:00:00Z' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, dischargeDate: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  dischargeDate: '2026-06-11T00:00:00Z',
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
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes',
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    ref_final_re_sph: '-2.00', ref_final_re_cyl: '-0.50', ref_final_re_axis: '90',
    ref_final_le_sph: '-1.50', ref_final_le_cyl: '-0.25', ref_final_le_axis: '85',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
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
  let dischargeDate = null;
  if (isSurgery && invoice.visit_id) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    const { data: surgicalCase } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye, surgeon_id')
      .eq('visit_id', invoice.visit_id)
      .neq('status', 'Cancelled')
      .maybeSingle();

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
    if (surgicalCase) {
      // The package's own line-item breakup is tied to whatever package
      // was actually billed, not the case's current one either.
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
      const { data: episode } = await supabase
        .from('recovery_episodes')
        .select('discharge_date')
        .eq('surgical_case_id', surgicalCase.id)
        .maybeSingle();
      dischargeDate = episode?.discharge_date || null;
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
    dischargeDate,
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

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, dischargeDate, packageBreakup }) {
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
    eye: surgeryEye || '--',
    package_name: packageName || '--',
    package_code: packageCode || '--',
    discharge_date: fmtDate(dischargeDate),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
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
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function refractionStr(sph, cyl, axis) {
  if (!sph && !cyl && !axis) return '--';
  return `${sph || '--'} / ${cyl || '--'} x ${axis || '--'}`;
}

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, diagnoses, prescriptions, followup }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const hasRefraction = !!(assessment?.ref_final_re_sph || assessment?.ref_final_le_sph);

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

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

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,

    hasVision: !!assessment,
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    hasRefraction,
    re_refraction: refractionStr(assessment?.ref_final_re_sph, assessment?.ref_final_re_cyl, assessment?.ref_final_re_axis),
    le_refraction: refractionStr(assessment?.ref_final_le_sph, assessment?.ref_final_le_cyl, assessment?.ref_final_le_axis),

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: prescriptions.map((p) => ({ drug: p.drug, eye: p.eye, dosage: p.dosage, frequency: p.frequency, duration: p.duration })),

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

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', sc?.visit_id).eq('status', 'Approved'),
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
    biometry: biometry || [],
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
      eye: p.surgical_eye,
      text: `${intraop?.implant_power || p.final_iol_power} D -- ${p.final_iol_category}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
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
PYEOF_1197692373035022558

echo "Files written. Run: npm run build"
