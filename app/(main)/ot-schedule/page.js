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

