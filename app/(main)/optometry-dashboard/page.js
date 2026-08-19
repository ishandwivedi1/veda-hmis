'use client';

import dynamic from 'next/dynamic';
import { Suspense, useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { getOptometryDashboardData } from './actions';
import { getOptometryHistory } from '@/app/(main)/optometry-history/actions';
import { optometryCallNext, optometryCallSpecific } from '@/app/(main)/queue/actions';

// Workspace (Final Rx entry, ~1200 lines) and the read-only History
// detail viewer (~420 lines) are the two heavy pieces of this module.
// Loaded on demand with next/dynamic + ssr:false so the Dashboard tab
// -- which is what most people land on -- never pulls their code or
// hydration cost into the initial page load. Neither needs SSR: both
// only render once a specific queue entry / assessment is selected,
// client-side, after the hub has already mounted.
const OptometryWorkspace = dynamic(() => import('@/app/(main)/optometry/[id]/optometry-workspace'), {
  ssr: false,
  loading: () => <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading workspace...</div>,
});
const AssessmentViewer = dynamic(() => import('@/app/(main)/optometry-history/[assessmentId]/assessment-viewer'), {
  ssr: false,
  loading: () => <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading assessment...</div>,
});

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function TokenBadge({ token }) {
  return (
    <span style={{ fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: 'var(--g900)', color: '#fff', padding: '3px 9px', borderRadius: 6, marginRight: 8 }}>
      {token}
    </span>
  );
}

// ── DASHBOARD ─────────────────────────────────────────────────────
function DashboardTab({ active, completed, onOpen, refresh }) {
  const [error, setError] = useState('');

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  const waitingCount = active.filter((e) => e.status === 'Waiting').length;
  const callingCount = active.filter((e) => e.status === 'Calling').length;
  const editableCount = completed.filter((e) => !e.locked).length;
  const lockedCount = completed.filter((e) => e.locked).length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Progress</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{callingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Editable Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{editableCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Posted, not yet seen by doctor</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--g400)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Locked Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{lockedCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Doctor has opened these</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
              <span className="badge b-gray">{active.length}</span>
            </div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>
          {active.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6, background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent' }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Calling' ? 'b-blue' : 'b-gray'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}>
                    <i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m
                  </span>
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn btn-sm" onClick={() => runAction(optometryCallSpecific, e.id)}>Call</button>
              )}
              {e.status === 'Calling' && (
                <button className="btn btn-primary btn-sm" onClick={() => onOpen(e.id)}>Start Assessment</button>
              )}
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-clipboard-check" style={{ color: 'var(--purple)' }}></i> Completed Today
              <span className="badge b-gray">{completed.length}</span>
            </div>
          </div>
          {completed.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.locked ? 'b-gray' : 'b-green'}`}>{e.locked ? 'Locked -- doctor viewing' : 'Editable'}</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => onOpen(e.id)}>{e.locked ? 'View' : 'Edit'}</button>
            </div>
          ))}
          {completed.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>Nothing completed yet today</div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── HISTORY ───────────────────────────────────────────────────────
function HistoryTab() {
  const [rows, setRows] = useState([]);
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const [viewingId, setViewingId] = useState(null);

  const refresh = useCallback(async (status) => {
    setLoading(true);
    const result = await getOptometryHistory(status || undefined);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setError('');
    setRows(result.rows);
  }, []);

  useEffect(() => { refresh(filter); }, [filter, refresh]);

  if (viewingId) {
    return <AssessmentViewer assessmentId={viewingId} onBack={() => setViewingId(null)} />;
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Assessment History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <select className="fi" style={{ width: 'auto', padding: '9px 12px' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="">All</option>
            <option value="Completed">Completed</option>
            <option value="Draft">Draft</option>
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date/Time</th><th>Patient</th><th>Visit</th><th>VA RE</th><th>VA LE</th><th>IOP RE</th><th>IOP LE</th><th>Status</th><th>By</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const iopReHigh = typeof r.iopRe === 'number' && r.iopRe > 21;
              const iopLeHigh = typeof r.iopLe === 'number' && r.iopLe > 21;
              const by = r.status === 'Completed' ? (r.completed_by_profile?.full_name || '--') : (r.recorded_by_profile?.full_name || '--');
              const dt = new Date(r.completed_at || r.updated_at || r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
              return (
                <tr key={r.id} onClick={() => setViewingId(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{dt}</td>
                  <td>
                    <strong>{patientName(r)}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.visits?.visit_number || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.re_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.le_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600, color: iopReHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopRe ?? '--'}{iopReHigh ? ' !' : ''}</td>
                  <td style={{ fontWeight: 600, color: iopLeHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopLe ?? '--'}{iopLeHigh ? ' !' : ''}</td>
                  <td>
                    <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-amber'}`}>{r.status}</span>
                    {r.hasDoctorCorrection && (
                      <span className="badge" style={{ marginLeft: 6, background: 'rgba(220,38,38,0.1)', color: 'var(--red)' }} title="Doctor recorded a differing finding for this visit">
                        <i className="ti ti-alert-triangle" style={{ fontSize: 11 }}></i> Correction
                      </span>
                    )}
                  </td>
                  <td style={{ fontSize: 12 }}>{by}</td>
                </tr>
              );
            })}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No assessments found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// Deep-linkable via ?queueEntryId=... -- Queue's "Optometry" section
// links straight here so calling a token opens the Workspace tab for
// that entry instead of dropping onto the Dashboard for a manual pick.
function OptometryHubInner() {
  const searchParams = useSearchParams();
  const deepLinkQueueEntryId = searchParams.get('queueEntryId');

  const [activeTab, setActiveTab] = useState(deepLinkQueueEntryId ? 'workspace' : 'dashboard');
  const [selectedQueueEntryId, setSelectedQueueEntryId] = useState(deepLinkQueueEntryId || null);
  const [active, setActive] = useState([]);
  const [completed, setCompleted] = useState([]);

  const refresh = useCallback(async () => {
    const { active, completed } = await getOptometryDashboardData();
    setActive(active);
    setCompleted(completed);
  }, []);

  // Live-queue polling only runs while the Dashboard tab is actually
  // visible -- no point refetching queue state in the background every
  // 15s while someone is heads-down in the Workspace or History tab.
  useEffect(() => {
    if (activeTab !== 'dashboard') return;
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [activeTab, refresh]);

  function openWorkspace(queueEntryId) {
    setSelectedQueueEntryId(queueEntryId);
    setActiveTab('workspace');
  }

  // Called by the Workspace itself after Complete Assessment / Force
  // Close / Back to Queue -- resets the hub's own tab state directly
  // instead of relying on a route push landing on an already-mounted
  // instance of this same page (see goToDashboard's comment in
  // optometry-workspace.js for why that silently did nothing).
  function handleWorkspaceDone() {
    setSelectedQueueEntryId(null);
    setActiveTab('dashboard');
    refresh();
  }

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>Optometry</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>Queue, Final Rx entry, and completed assessment history.</div>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 420 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-eye-check" label="Workspace" disabled={!selectedQueueEntryId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab active={active} completed={completed} onOpen={openWorkspace} refresh={refresh} />}
      {activeTab === 'workspace' && selectedQueueEntryId && <OptometryWorkspace queueEntryId={selectedQueueEntryId} onDone={handleWorkspaceDone} />}
      {activeTab === 'workspace' && !selectedQueueEntryId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select an entry from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab />}
    </div>
  );
}

export default function OptometryDashboardPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <OptometryHubInner />
    </Suspense>
  );
}
