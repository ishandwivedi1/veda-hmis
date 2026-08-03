#!/bin/bash
set -e

echo 'Applying: fix Scheduling Queue not refreshing after a patient is scheduled...'

mkdir -p 'app/(main)/ot-schedule'

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
      {activeTab === 'workspace' && selectedCaseId && <WorkspaceTab caseId={selectedCaseId} onDone={handleWorkspaceDone} onUpdate={() => { refreshDash(); refreshQueue(); }} />}
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

export default function WorkspaceTab({ caseId, onDone, onUpdate }) {
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
echo '  git add "app/(main)/ot-schedule/page.js" "app/(main)/ot-schedule/workspace-tab.js"'
echo '  git commit -m "Fix OT Scheduling Queue not refreshing after a patient is scheduled/rescheduled"'
echo '  git push'
