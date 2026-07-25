#!/bin/bash
set -e

echo 'Applying: Assign Surgeon dropdown (from Doctors Master) in OT Schedule Surgery form...'

mkdir -p 'app/(main)/ot-schedule'

cat > 'app/(main)/ot-schedule/actions.js' << 'OT_ACTIONS_EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

// ── SESSIONS (master data) ──
export async function getOTSessions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_ot_sessions').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}

// ── SURGEON OPTIONS (Doctors Master) ──
// Same source as Clinical Masters > Doctors, so the surgeon list here
// stays consistent with the rest of the app rather than a separate ad
// hoc query.
export async function getSurgeonOptions() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, code, full_name')
    .or('designation.ilike.%ophthalmologist%,designation.ilike.%doctor%')
    .eq('status', 'Active')
    .order('full_name');
  return data || [];
}

// ── READY FOR SCHEDULING QUEUE ──
// Reads directly off surgical_cases.status -- the exact same "Ready for
// Scheduling" status Counselling's markReadyForScheduling already sets
// once package/decision/biometry/fitness are all satisfied. Nothing
// re-derived here; OT just consumes the result.
export async function getReadyQueue() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(id, first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(id, full_name)')
    .eq('status', 'Ready for Scheduling')
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── DASHBOARD ──
export async function getOTDashboard() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: sessions }, { data: todayBookings }, readyCount] = await Promise.all([
    supabase.from('master_ot_sessions').select('*').eq('status', 'Active').order('display_order'),
    supabase.from('ot_schedule').select('*, surgical_cases(procedure_name, eye, priority)').eq('scheduled_date', today).neq('status', 'Cancelled'),
    supabase.from('surgical_cases').select('id', { count: 'exact', head: true }).eq('status', 'Ready for Scheduling').then((r) => r.count || 0),
  ]);

  const bookingsBySession = {};
  (todayBookings || []).forEach((b) => {
    if (!b.session_id) return;
    (bookingsBySession[b.session_id] = bookingsBySession[b.session_id] || []).push(b);
  });

  const sessionSummary = (sessions || []).map((s) => {
    const bookings = bookingsBySession[s.id] || [];
    return {
      ...s,
      planned: bookings.length,
      completed: bookings.filter((b) => b.status === 'Completed').length,
      cancelled: 0, // cancelled bookings are excluded from todayBookings by design
    };
  });

  const totalCapacity = sessionSummary.reduce((s, x) => s + x.capacity, 0);
  const totalPlanned = sessionSummary.reduce((s, x) => s + x.planned, 0);

  const alerts = await getOTAlerts();

  return {
    readyCount,
    scheduledToday: (todayBookings || []).length,
    capacityPct: totalCapacity > 0 ? Math.round((totalPlanned / totalCapacity) * 100) : 0,
    alertsCount: alerts.length,
    sessions: sessionSummary,
  };
}

// ── WORKSPACE: full detail for scheduling a specific case ──
export async function getSchedulingWorkspaceData(caseId) {
  const supabase = await createClient();
  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(id, first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(id, full_name)')
    .eq('id', caseId)
    .single();
  if (error) return { error: error.message };

  // Approved IOL Plan -- read-only here, owned by the Biometry module.
  const { data: biometry } = await supabase
    .from('biometry_records')
    .select('*, master_iol_catalog(brand, model, manufacturer)')
    .eq('visit_id', sc.visit_id)
    .eq('status', 'Approved')
    .order('approved_at', { ascending: false });

  // Any existing (non-cancelled) booking for this case -- workspace
  // shows it pre-filled instead of a blank scheduling form.
  const { data: existingBooking } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name, start_time, end_time, default_room, capacity)')
    .eq('surgical_case_id', caseId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  return { case: sc, biometryPlans: biometry || [], existingBooking: existingBooking || null };
}

// ── CAPACITY CHECK ──
export async function getSessionCapacity(date, sessionId, excludeBookingId) {
  const supabase = await createClient();
  let query = supabase.from('ot_schedule').select('id', { count: 'exact', head: true })
    .eq('scheduled_date', date).eq('session_id', sessionId).neq('status', 'Cancelled');
  if (excludeBookingId) query = query.neq('id', excludeBookingId);
  const { count } = await query;
  return count || 0;
}

// ── SCHEDULE ──
export async function scheduleSurgery(caseId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('status, surgeon_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Ready for Scheduling') return { error: 'BR-OTS-001: This case is not marked Ready for Scheduling.' };
  if (!values.date) return { error: 'Surgery date is required.' };
  if (!values.sessionId) return { error: 'Session is required.' };
  if (!values.surgeonId) return { error: 'Assign a surgeon before scheduling.' };

  const { data: booking, error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: values.surgeonId,
    scheduled_date: values.date, session_id: values.sessionId, room: values.room || null,
    sequence_number: values.sequenceNumber || null, expected_duration_minutes: values.duration || 30,
    notes: values.notes || null,
  }).select('id').single();
  if (otError) return { error: otError.message };

  // Keep the case's own surgeon_id in sync too -- other screens
  // (resource check, reports) read it from the case, not just the booking.
  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled', surgeon_id: values.surgeonId }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: booking.id, action: 'Scheduled',
    detail: `Scheduled for ${values.date}, session ${values.sessionId}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── RESCHEDULE (same booking preserved, per BR/Section 18.13) ──
export async function rescheduleSurgery(otScheduleId, values) {
  const supabase = await createClient();
  if (!values.reason) return { error: 'A reschedule reason is required.' };
  const { data: userData } = await supabase.auth.getUser();

  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date, session_id, reschedule_count').eq('id', otScheduleId).single();
  if (!booking) return { error: 'Booking not found.' };

  const { error } = await supabase.from('ot_schedule').update({
    scheduled_date: values.date, session_id: values.sessionId,
    reschedule_count: (booking.reschedule_count || 0) + 1,
  }).eq('id', otScheduleId);
  if (error) return { error: error.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Rescheduled',
    detail: `From ${booking.scheduled_date} -> ${values.date} -- Reason: ${values.reason}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── CANCEL (booking cancelled, case goes back to the queue) ──
export async function cancelSurgery(otScheduleId, caseId, values) {
  const supabase = await createClient();
  if (!values.reason) return { error: 'A cancellation reason is required.' };
  const { data: userData } = await supabase.auth.getUser();

  const { error: otError } = await supabase.from('ot_schedule').update({
    status: 'Cancelled', cancellation_reason: values.reason, cancellation_remarks: values.remarks || null,
    cancelled_by: userData?.user?.id || null, cancelled_at: new Date().toISOString(),
  }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Cancelled',
    detail: `Reason: ${values.reason}${values.remarks ? ` -- ${values.remarks}` : ''}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

export async function completeSurgery(otScheduleId, caseId) {
  const supabase = await createClient();
  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };
  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };
  return { success: true };
}

// ── DAILY OT LIST ──
export async function getDailyOTList(date, sessionId) {
  const supabase = await createClient();
  let query = supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, priority, visit_id, patients:patient_id(first_name, last_name, uhid)), profiles:surgeon_id(full_name)')
    .eq('scheduled_date', date)
    .neq('status', 'Cancelled')
    .order('sequence_number', { ascending: true, nullsFirst: false });
  if (sessionId) query = query.eq('session_id', sessionId);
  const { data, error } = await query;
  if (error) return [];

  // Pull the approved IOL plan for each row's visit so the printed/daily
  // list shows it inline, same as the prototype.
  const visitIds = [...new Set((data || []).map((b) => b.surgical_cases?.visit_id).filter(Boolean))];
  let iolByVisit = {};
  if (visitIds.length > 0) {
    const { data: plans } = await supabase.from('biometry_records').select('visit_id, final_iol_power, final_iol_category, surgical_eye').eq('status', 'Approved').in('visit_id', visitIds);
    (plans || []).forEach((p) => { (iolByVisit[p.visit_id] = iolByVisit[p.visit_id] || []).push(p); });
  }

  return (data || []).map((b) => ({ ...b, iolPlans: iolByVisit[b.surgical_cases?.visit_id] || [] }));
}

// ── ALERTS ──
// Real, data-driven checks rather than the prototype's canned scenarios:
// scheduled cases where something readiness-related has changed since
// they were queued.
export async function getOTAlerts() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const { data: upcoming } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, surgical_case_id, surgical_cases(procedure_name, eye, fitness_cleared, patients:patient_id(first_name, last_name))')
    .gte('scheduled_date', today)
    .neq('status', 'Cancelled')
    .neq('status', 'Completed');

  const alerts = [];
  (upcoming || []).forEach((b) => {
    const sc = b.surgical_cases;
    if (!sc) return;
    const name = `${sc.patients?.first_name || ''} ${sc.patients?.last_name || ''}`.trim();
    if (!sc.fitness_cleared) {
      alerts.push({ patient: name, issue: 'Medical fitness no longer cleared for this case', urgency: 'high', bookingId: b.id });
    }
  });

  return alerts;
}

// ── REPORTS ──
export async function getOTReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid)), profiles:surgeon_id(full_name)')
    .gte('scheduled_date', fromDate)
    .lte('scheduled_date', toDate)
    .order('scheduled_date', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  if (reportId === 'daily') {
    return {
      title: 'OT Bookings',
      headers: ['Date', 'Session', 'Patient', 'Procedure', 'Surgeon', 'Status'],
      rows: (data || []).map((b) => ({
        cols: [b.scheduled_date, b.master_ot_sessions?.name || '--', `${b.surgical_cases?.patients?.first_name} ${b.surgical_cases?.patients?.last_name}`, `${b.surgical_cases?.procedure_name} (${b.surgical_cases?.eye})`, b.profiles?.full_name || '--', b.status],
      })),
    };
  }

  if (reportId === 'util') {
    const bySession = {};
    (data || []).filter((b) => b.status !== 'Cancelled').forEach((b) => {
      const name = b.master_ot_sessions?.name || 'Unassigned';
      bySession[name] = (bySession[name] || 0) + 1;
    });
    return {
      title: 'OT Utilization by Session',
      headers: ['Session', 'Bookings'],
      rows: Object.entries(bySession).map(([name, count]) => ({ cols: [name, count] })),
    };
  }

  if (reportId === 'cancel') {
    const cancelled = (data || []).filter((b) => b.status === 'Cancelled');
    return {
      title: 'Cancellations',
      headers: ['Date', 'Patient', 'Procedure', 'Reason', 'Remarks'],
      rows: cancelled.map((b) => ({
        cols: [b.scheduled_date, `${b.surgical_cases?.patients?.first_name} ${b.surgical_cases?.patients?.last_name}`, b.surgical_cases?.procedure_name, b.cancellation_reason || '--', b.cancellation_remarks || '--'],
      })),
    };
  }

  if (reportId === 'surgeon') {
    const bySurgeon = {};
    (data || []).filter((b) => b.status !== 'Cancelled').forEach((b) => {
      const name = b.profiles?.full_name || 'Unassigned';
      bySurgeon[name] = (bySurgeon[name] || 0) + 1;
    });
    return {
      title: 'Surgeon-wise Load',
      headers: ['Surgeon', 'Cases'],
      rows: Object.entries(bySurgeon).map(([name, count]) => ({ cols: [name, count] })),
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

OT_ACTIONS_EOF

cat > 'app/(main)/ot-schedule/workspace-tab.js' << 'OT_WORKSPACE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getSchedulingWorkspaceData, getOTSessions, getSessionCapacity, getSurgeonOptions,
  scheduleSurgery, rescheduleSurgery, cancelSurgery, completeSurgery,
} from './actions';

const PRIORITY_BADGE = { Emergency: 'b-red', Urgent: 'b-amber', Routine: 'b-gray' };

export default function WorkspaceTab({ caseId, onDone, onUpdate }) {
  const [data, setData] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [surgeons, setSurgeons] = useState([]);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessionId, setSessionId] = useState('');
  const [surgeonId, setSurgeonId] = useState('');
  const [room, setRoom] = useState('');
  const [sequenceNumber, setSequenceNumber] = useState('');
  const [duration, setDuration] = useState(30);
  const [capacityInfo, setCapacityInfo] = useState(null);
  const [saving, setSaving] = useState(false);

  const [showReschedule, setShowReschedule] = useState(false);
  const [reschDate, setReschDate] = useState('');
  const [reschSessionId, setReschSessionId] = useState('');
  const [reschReason, setReschReason] = useState('');

  const [showCancel, setShowCancel] = useState(false);
  const [cancelReason, setCancelReason] = useState('Patient Declined');
  const [cancelRemarks, setCancelRemarks] = useState('');

  const refresh = useCallback(async () => {
    const result = await getSchedulingWorkspaceData(caseId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    if (result.case?.surgeon_id) setSurgeonId(result.case.surgeon_id);
  }, [caseId]);

  useEffect(() => {
    setData(null); setLoadError(''); setError(''); setOk(''); setSurgeonId('');
    refresh();
    getOTSessions().then(setSessions);
    getSurgeonOptions().then(setSurgeons);
  }, [caseId, refresh]);

  useEffect(() => {
    if (!sessionId || !date) { setCapacityInfo(null); return; }
    getSessionCapacity(date, sessionId).then((count) => {
      const session = sessions.find((s) => s.id === sessionId);
      setCapacityInfo({ count, capacity: session?.capacity || 0 });
    });
  }, [date, sessionId, sessions]);

  useEffect(() => {
    if (sessions.length > 0 && !sessionId) {
      setSessionId(sessions[0].id);
      setRoom(sessions[0].default_room || '');
    }
  }, [sessions, sessionId]);

  async function handleSchedule() {
    setError(''); setOk('');
    if (!surgeonId) { setError('Assign a surgeon before scheduling.'); return; }
    setSaving(true);
    const result = await scheduleSurgery(caseId, {
      date, sessionId, surgeonId, room, sequenceNumber: sequenceNumber ? parseInt(sequenceNumber, 10) : null, duration,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Surgery scheduled. Case moved to the Daily OT List for this date.');
    refresh();
    onUpdate();
  }

  async function handleReschedule() {
    setError('');
    if (!reschReason.trim()) { setError('A reschedule reason is required.'); return; }
    setSaving(true);
    const result = await rescheduleSurgery(data.existingBooking.id, { date: reschDate, sessionId: reschSessionId, reason: reschReason });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowReschedule(false);
    setOk('Rescheduled -- same booking preserved, history logged.');
    refresh();
    onUpdate();
  }

  async function handleCancel() {
    setError('');
    setSaving(true);
    const result = await cancelSurgery(data.existingBooking.id, caseId, { reason: cancelReason, remarks: cancelRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowCancel(false);
    onDone();
  }

  async function handleComplete() {
    setSaving(true);
    const result = await completeSurgery(data.existingBooking.id, caseId);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { case: sc, biometryPlans, existingBooking } = data;
  const patient = sc.patients;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e7490,#0891b2)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- {patient?.mobile} -- {sc.profiles?.full_name || 'No surgeon assigned'}</div>
        </div>
        <span className={`badge ${PRIORITY_BADGE[sc.priority] || 'b-gray'}`} style={{ fontSize: 11 }}>{sc.priority}</span>
      </div>

      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}
      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-clipboard-list" style={{ color: 'var(--blue)' }}></i> Approved Surgical Plan (read-only)</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Eye</span><span className="badge b-blue" style={{ fontSize: 10 }}>{sc.eye}</span></div>
            {biometryPlans.length === 0 && (
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>No approved IOL plan on record (non-IOL procedure, or Biometry not yet approved).</div>
            )}
            {biometryPlans.map((p) => (
              <div key={p.id} style={{ marginTop: 8, padding: 8, background: 'var(--g50)', borderRadius: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--indigo)', marginBottom: 4 }}>{p.surgical_eye} -- Approved IOL Plan</div>
                <div style={{ fontSize: 11.5, fontFamily: 'monospace' }}>{p.final_iol_power} D -- {p.selected_formula} -- {p.final_iol_category}</div>
                {p.master_iol_catalog && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.master_iol_catalog.brand} {p.master_iol_catalog.model}</div>}
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Changes to IOL plan require the Biometry module -- read-only here.</div>
          </div>

          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-tool" style={{ color: 'var(--purple)' }}></i> Resource Check</div>
            <div className="rd-item done" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, marginBottom: 4, fontSize: 12, background: 'var(--green-lt)', color: 'var(--green)' }}>
              <i className="ti ti-circle-check"></i> Surgeon -- {sc.profiles?.full_name || 'Not assigned'}
            </div>
            <div className="rd-item" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, marginBottom: 4, fontSize: 12, background: biometryPlans.length > 0 || sc.eye === 'N/A' ? 'var(--green-lt)' : 'var(--amber-lt)', color: biometryPlans.length > 0 || sc.eye === 'N/A' ? 'var(--green)' : 'var(--amber)' }}>
              <i className={`ti ${biometryPlans.length > 0 ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i> Approved IOL -- {biometryPlans.length > 0 ? `${biometryPlans.length} eye(s) ready` : 'None on record'}
            </div>
            <div className="rd-item done" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, fontSize: 12, background: 'var(--green-lt)', color: 'var(--green)' }}>
              <i className="ti ti-circle-check"></i> Medical Fitness -- Cleared
            </div>
          </div>
        </div>

        <div>
          {!existingBooking ? (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-calendar-event" style={{ color: 'var(--cyan)' }}></i> Schedule Surgery</div>
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Assign Surgeon</label>
                <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                  <option value="">-- Select surgeon --</option>
                  {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}{s.code ? ` (${s.code})` : ''}</option>)}
                </select>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div><label className="flbl">Surgery Date</label><input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} /></div>
                <div>
                  <label className="flbl">Session</label>
                  <select className="fi fi-sm" value={sessionId} onChange={(e) => { setSessionId(e.target.value); const s = sessions.find((x) => x.id === e.target.value); setRoom(s?.default_room || ''); }}>
                    {sessions.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.start_time?.slice(0, 5)}-{s.end_time?.slice(0, 5)})</option>)}
                  </select>
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div><label className="flbl">OT Room</label><input className="fi fi-sm" value={room} onChange={(e) => setRoom(e.target.value)} /></div>
                <div><label className="flbl">Sequence #</label><input type="number" min="1" className="fi fi-sm" value={sequenceNumber} onChange={(e) => setSequenceNumber(e.target.value)} placeholder="Auto if blank" /></div>
              </div>
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Expected Duration</label>
                <select className="fi fi-sm" value={duration} onChange={(e) => setDuration(parseInt(e.target.value, 10))}>
                  <option value={20}>20 min</option><option value={30}>30 min</option><option value={45}>45 min</option><option value={60}>60 min</option>
                </select>
              </div>
              {capacityInfo && (
                <div className={`msg-${capacityInfo.count >= capacityInfo.capacity ? 'warn' : 'info'}`} style={{ fontSize: 11, marginBottom: 8 }}>
                  <i className="ti ti-info-circle"></i>
                  {capacityInfo.count}/{capacityInfo.capacity} cases planned for this session
                  {capacityInfo.count >= capacityInfo.capacity && ' -- at capacity, scheduling will still go through but double-check with the OT coordinator.'}
                </div>
              )}
              <button className="btn btn-primary" style={{ width: '100%' }} onClick={handleSchedule} disabled={saving}>
                <i className="ti ti-calendar-check"></i> {saving ? 'Scheduling...' : 'Schedule Surgery'}
              </button>
            </div>
          ) : (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-calendar-event" style={{ color: 'var(--cyan)' }}></i> Scheduled</div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Date</span><strong>{new Date(existingBooking.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Session</span><strong>{existingBooking.master_ot_sessions?.name}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Room</span><strong>{existingBooking.room || '--'}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Status</span><span className="badge b-blue">{existingBooking.status}</span></div>
              {existingBooking.reschedule_count > 0 && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 6 }}>Rescheduled {existingBooking.reschedule_count}x</div>}

              <div style={{ display: 'flex', gap: 6, marginTop: 12, flexWrap: 'wrap' }}>
                {existingBooking.status === 'Scheduled' && (
                  <>
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleComplete} disabled={saving}>
                      <i className="ti ti-check"></i> Mark Completed
                    </button>
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => { setReschDate(existingBooking.scheduled_date); setReschSessionId(existingBooking.session_id); setShowReschedule(true); }}>
                      <i className="ti ti-calendar-time"></i> Reschedule
                    </button>
                    <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={() => setShowCancel(true)}>
                      <i className="ti ti-x"></i> Cancel
                    </button>
                  </>
                )}
              </div>

              {showReschedule && (
                <div style={{ marginTop: 12, padding: 10, background: 'var(--amber-lt)', borderRadius: 8 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Reschedule</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                    <input type="date" className="fi fi-sm" value={reschDate} onChange={(e) => setReschDate(e.target.value)} />
                    <select className="fi fi-sm" value={reschSessionId} onChange={(e) => setReschSessionId(e.target.value)}>
                      {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                    </select>
                  </div>
                  <select className="fi fi-sm" value={reschReason} onChange={(e) => setReschReason(e.target.value)} style={{ marginBottom: 8 }}>
                    <option value="">-- Reason --</option>
                    <option>Patient Request</option><option>Surgeon Unavailable</option><option>Medical Issue</option>
                    <option>Equipment Failure</option><option>Emergency Case</option><option>Public Holiday</option>
                  </select>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={handleReschedule} disabled={saving}>Confirm</button>
                    <button className="btn btn-sm" onClick={() => setShowReschedule(false)}>Cancel</button>
                  </div>
                </div>
              )}

              {showCancel && (
                <div style={{ marginTop: 12, padding: 10, background: 'var(--red-lt)', borderRadius: 8 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Cancel Surgery</div>
                  <select className="fi fi-sm" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} style={{ marginBottom: 8 }}>
                    <option>Patient Declined</option><option>Medical Contraindication</option><option>No-show</option>
                    <option>OT Breakdown</option><option>Lens Unavailable</option><option>Clinical Reassessment Required</option>
                  </select>
                  <textarea className="fi fi-sm" rows={2} placeholder="Remarks (optional)" value={cancelRemarks} onChange={(e) => setCancelRemarks(e.target.value)} style={{ marginBottom: 8 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleCancel} disabled={saving}>Confirm Cancellation</button>
                    <button className="btn btn-sm" onClick={() => setShowCancel(false)}>Close</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

OT_WORKSPACE_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/ot-schedule/actions.js" "app/(main)/ot-schedule/workspace-tab.js"'
echo '  git commit -m "Add Assign Surgeon (Doctors Master) to OT Schedule Surgery form"'
echo '  git push'
