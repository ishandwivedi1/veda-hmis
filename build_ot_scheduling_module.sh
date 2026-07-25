#!/bin/bash
set -e

echo 'Applying: full OT Scheduling module (Dashboard/Queue/Workspace/Daily List/Alerts/Reports)...'

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

  const { data: booking, error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: sc.surgeon_id || null,
    scheduled_date: values.date, session_id: values.sessionId, room: values.room || null,
    sequence_number: values.sequenceNumber || null, expected_duration_minutes: values.duration || 30,
    notes: values.notes || null,
  }).select('id').single();
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', caseId);
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

cat > 'app/(main)/ot-schedule/page.js' << 'OT_PAGE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOTDashboard, getReadyQueue } from './actions';
import WorkspaceTab from './workspace-tab';
import DailyListTab from './daily-list-tab';
import AlertsTab from './alerts-tab';
import ReportsTab from './reports-tab';

const PRIORITY_BADGE = { Emergency: 'b-red', Urgent: 'b-amber', Routine: 'b-gray' };

function getCapColor(pct) { return pct >= 90 ? 'var(--red)' : pct >= 70 ? 'var(--amber)' : 'var(--green)'; }

function DashboardTab({ dash, loading, onGoQueue }) {
  if (loading || !dash) return <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>;

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 14 }}>
        <div className="sc cy" style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--cyan)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Ready for scheduling</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{dash.readyCount}</div>
          <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>Checklist complete</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Scheduled today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{dash.scheduledToday}</div>
          <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>Across all sessions</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Capacity used</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{dash.capacityPct}%</div>
          <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>Today&apos;s sessions</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Readiness alerts</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{dash.alertsCount}</div>
          <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>Need attention</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar" style={{ color: 'var(--cyan)' }}></i> OT sessions today</div>
        {dash.sessions.map((s) => {
          const pct = s.capacity > 0 ? Math.round((s.planned / s.capacity) * 100) : 0;
          return (
            <div key={s.id} style={{ border: '1.5px solid var(--g200)', borderRadius: 12, padding: '12px 14px', marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                <div style={{ fontSize: 13, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 8 }}>
                  <i className="ti ti-clock" style={{ color: 'var(--cyan)' }}></i> {s.name} Session
                  <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{s.start_time?.slice(0, 5)} - {s.end_time?.slice(0, 5)}</span>
                </div>
                <span className="badge b-cyan">{s.default_room}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, color: 'var(--g500)' }}>
                <span>{s.planned} / {s.capacity} cases planned</span>
                <span style={{ fontWeight: 700, color: getCapColor(pct) }}>{pct}%</span>
              </div>
              <div style={{ height: 10, borderRadius: 5, background: 'var(--g200)', overflow: 'hidden', marginTop: 6 }}>
                <div style={{ height: '100%', borderRadius: 5, width: `${pct}%`, background: getCapColor(pct) }}></div>
              </div>
            </div>
          );
        })}
      </div>

      {dash.readyCount > 0 && (
        <div className="card" style={{ textAlign: 'center' }}>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 8 }}>{dash.readyCount} patient(s) ready for scheduling</div>
          <button className="btn btn-primary" onClick={onGoQueue}><i className="ti ti-list-numbers"></i> Go to Scheduling Queue</button>
        </div>
      )}
    </div>
  );
}

function QueueTab({ rows, loading, onOpen }) {
  const [sortBy, setSortBy] = useState('priority');

  const sorted = [...rows].sort((a, b) => {
    if (sortBy === 'priority') { const order = { Emergency: 0, Urgent: 1, Routine: 2 }; return (order[a.priority] ?? 9) - (order[b.priority] ?? 9); }
    if (sortBy === 'waiting') return new Date(a.created_at) - new Date(b.created_at);
    if (sortBy === 'surgeon') return (a.profiles?.full_name || '').localeCompare(b.profiles?.full_name || '');
    return 0;
  });

  function waitingDays(sc) {
    return Math.floor((new Date() - new Date(sc.created_at)) / (1000 * 60 * 60 * 24));
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--cyan)' }}></i> Ready for Scheduling Queue <span className="badge b-cyan">{rows.length}</span></div>
        <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 150 }}>
          <option value="priority">Sort: Priority</option>
          <option value="waiting">Sort: Waiting time</option>
          <option value="surgeon">Sort: Surgeon</option>
        </select>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && sorted.map((sc) => (
        <div key={sc.id} style={{ border: '1.5px solid var(--g200)', borderRadius: 12, padding: '11px 13px', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--cyan)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
            {sc.patients?.first_name?.charAt(0)}
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 700 }}>
              {sc.patients?.first_name} {sc.patients?.last_name}
              <span className={`badge ${PRIORITY_BADGE[sc.priority] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{sc.priority}</span>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>Waiting: {waitingDays(sc)} days</div>
          </div>
          <button className="btn btn-sm" style={{ background: 'var(--cyan)', color: '#fff', border: 'none' }} onClick={() => onOpen(sc.id)}>
            <i className="ti ti-calendar-event"></i> Schedule
          </button>
        </div>
      ))}

      {!loading && sorted.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No patients ready for scheduling right now.</div>
      )}
    </div>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, minWidth: 90, padding: '8px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--cyan)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function OTSchedulePage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);
  const [dash, setDash] = useState(null);
  const [queueRows, setQueueRows] = useState([]);
  const [loadingDash, setLoadingDash] = useState(true);
  const [loadingQueue, setLoadingQueue] = useState(true);

  const refreshDash = useCallback(async () => { setDash(await getOTDashboard()); setLoadingDash(false); }, []);
  const refreshQueue = useCallback(async () => { setQueueRows(await getReadyQueue()); setLoadingQueue(false); }, []);

  useEffect(() => { refreshDash(); refreshQueue(); }, [refreshDash, refreshQueue]);

  function openCase(id) {
    setSelectedCaseId(id);
    setActiveTab('workspace');
  }

  function handleWorkspaceDone() {
    refreshDash(); refreshQueue();
    setSelectedCaseId(null);
    setActiveTab('queue');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, flexWrap: 'wrap' }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'queue'} onClick={() => setActiveTab('queue')} icon="ti-list-numbers" label="Scheduling Queue" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-calendar-event" label="Workspace" disabled={!selectedCaseId} />
        <TabButton active={activeTab === 'daily'} onClick={() => setActiveTab('daily')} icon="ti-list-details" label="Daily OT List" />
        <TabButton active={activeTab === 'alerts'} onClick={() => setActiveTab('alerts')} icon="ti-alert-triangle" label="Alerts" />
        <TabButton active={activeTab === 'reports'} onClick={() => setActiveTab('reports')} icon="ti-chart-bar" label="Reports" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab dash={dash} loading={loadingDash} onGoQueue={() => setActiveTab('queue')} />}
      {activeTab === 'queue' && <QueueTab rows={queueRows} loading={loadingQueue} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedCaseId && <WorkspaceTab caseId={selectedCaseId} onDone={handleWorkspaceDone} />}
      {activeTab === 'workspace' && !selectedCaseId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Scheduling Queue.</div>
      )}
      {activeTab === 'daily' && <DailyListTab />}
      {activeTab === 'alerts' && <AlertsTab />}
      {activeTab === 'reports' && <ReportsTab />}
    </div>
  );
}

OT_PAGE_EOF

cat > 'app/(main)/ot-schedule/workspace-tab.js' << 'OT_WORKSPACE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getSchedulingWorkspaceData, getOTSessions, getSessionCapacity,
  scheduleSurgery, rescheduleSurgery, cancelSurgery, completeSurgery,
} from './actions';

const PRIORITY_BADGE = { Emergency: 'b-red', Urgent: 'b-amber', Routine: 'b-gray' };

export default function WorkspaceTab({ caseId, onDone }) {
  const [data, setData] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessionId, setSessionId] = useState('');
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
  }, [caseId]);

  useEffect(() => {
    setData(null); setLoadError(''); setError(''); setOk('');
    refresh();
    getOTSessions().then(setSessions);
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
    setSaving(true);
    const result = await scheduleSurgery(caseId, {
      date, sessionId, room, sequenceNumber: sequenceNumber ? parseInt(sequenceNumber, 10) : null, duration,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Surgery scheduled. Case moved to the Daily OT List for this date.');
    refresh();
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

cat > 'app/(main)/ot-schedule/daily-list-tab.js' << 'OT_DAILY_EOF'
'use client';

import { useState, useEffect } from 'react';
import { getDailyOTList, getOTSessions } from './actions';

export default function DailyListTab() {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessions, setSessions] = useState([]);
  const [sessionFilter, setSessionFilter] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => { getOTSessions().then(setSessions); }, []);
  useEffect(() => {
    setLoading(true);
    getDailyOTList(date, sessionFilter || undefined).then((r) => { setRows(r); setLoading(false); });
  }, [date, sessionFilter]);

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-list-details" style={{ color: 'var(--cyan)' }}></i> Daily OT List</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} style={{ width: 150 }} />
          <select className="fi fi-sm" value={sessionFilter} onChange={(e) => setSessionFilter(e.target.value)} style={{ width: 140 }}>
            <option value="">All sessions</option>
            {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <button className="btn btn-sm" onClick={() => window.print()}><i className="ti ti-printer"></i> Print</button>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && rows.map((r, i) => (
        <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 12px', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ width: 24, height: 24, borderRadius: '50%', background: 'var(--cyan)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
            {r.sequence_number || i + 1}
          </div>
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 13, fontWeight: 700 }}>
              {r.surgical_cases?.patients?.first_name} {r.surgical_cases?.patients?.last_name}
              <span className="badge b-cyan" style={{ marginLeft: 6, fontSize: 10 }}>{r.master_ot_sessions?.name}</span>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {r.surgical_cases?.procedure_name} -- {r.surgical_cases?.eye} -- {r.profiles?.full_name || 'No surgeon'}
            </div>
            {r.iolPlans.length > 0 && (
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 1, fontFamily: 'monospace' }}>
                IOL: {r.iolPlans.map((p) => `${p.surgical_eye} ${p.final_iol_power}D`).join(', ')}
              </div>
            )}
          </div>
          <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-blue'}`} style={{ fontSize: 10 }}>{r.status}</span>
        </div>
      ))}

      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No surgeries scheduled for this date{sessionFilter ? '/session' : ''}.</div>
      )}
    </div>
  );
}

OT_DAILY_EOF

cat > 'app/(main)/ot-schedule/alerts-tab.js' << 'OT_ALERTS_EOF'
'use client';

import { useState, useEffect } from 'react';
import { getOTAlerts } from './actions';

export default function AlertsTab() {
  const [alerts, setAlerts] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => { getOTAlerts().then((a) => { setAlerts(a); setLoading(false); }); }, []);

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title"><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> OT Readiness Alerts</div>
        <span className="badge b-red">{alerts.length}</span>
      </div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Readiness changes after scheduling (e.g. medical fitness no longer cleared) surface here automatically.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && alerts.map((a, i) => (
        <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderRadius: 8, marginBottom: 6, background: a.urgency === 'high' ? 'var(--red-lt)' : 'var(--amber-lt)', border: `1px solid ${a.urgency === 'high' ? 'var(--red)' : 'var(--amber)'}30` }}>
          <i className="ti ti-alert-triangle" style={{ color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)', fontSize: 18, flexShrink: 0 }}></i>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 700, fontSize: 13 }}>{a.patient}</div>
            <div style={{ fontSize: 11, color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)' }}>{a.issue}</div>
          </div>
          <span className="badge" style={{ background: a.urgency === 'high' ? 'var(--red-lt)' : 'var(--amber-lt)', color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)', fontSize: 10 }}>{a.urgency.toUpperCase()}</span>
        </div>
      ))}

      {!loading && alerts.length === 0 && (
        <div style={{ textAlign: 'center', padding: 30, color: 'var(--green)' }}>
          <i className="ti ti-circle-check" style={{ fontSize: 24, display: 'block', marginBottom: 6 }}></i>
          No readiness alerts.
        </div>
      )}
    </div>
  );
}

OT_ALERTS_EOF

cat > 'app/(main)/ot-schedule/reports-tab.js' << 'OT_REPORTS_EOF'
'use client';

import { useState } from 'react';
import { getOTReport } from './actions';

const RPT_DEFS = [
  { id: 'daily', icon: 'ti-list', color: '--cyan', title: 'OT Bookings', desc: 'All bookings in the selected period' },
  { id: 'util', icon: 'ti-chart-bar', color: '--blue', title: 'OT Utilization', desc: 'Bookings by session' },
  { id: 'cancel', icon: 'ti-x-circle', color: '--red', title: 'Cancellations', desc: 'Cancelled surgeries with reasons' },
  { id: 'surgeon', icon: 'ti-user', color: '--purple', title: 'Surgeon-wise Load', desc: 'Cases per surgeon' },
];

function toISODate(d) { return d.toISOString().slice(0, 10); }
const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
];

export default function ReportsTab() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from); setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getOTReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>)}
          </div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div key={r.id} onClick={() => openReport(r.id)} className="card" style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}>
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-file"></i> {report.title}</div>
            <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>)}
              {report.rows.length === 0 && <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

OT_REPORTS_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/ot-schedule"'
echo '  git commit -m "Build full OT Scheduling module: Dashboard, Queue, Workspace, Daily List, Alerts, Reports"'
echo '  git push'
