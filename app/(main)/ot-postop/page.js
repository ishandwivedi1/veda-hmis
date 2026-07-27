'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPostOpCaseList, getPostOpTurnedUpToday, getPostOpHistory } from './actions';
import Workspace from './workspace';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--purple)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function daysWaiting(dischargeDate) {
  if (!dischargeDate) return 0;
  return Math.floor((new Date() - new Date(`${dischargeDate}T00:00:00`)) / (1000 * 60 * 60 * 24));
}

function PatientRow({ c, onClick, accentColor, rightLabel, actionLabel, actionIcon }) {
  const sc = c.surgical_cases;
  const patient = sc.patients;
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
      <div style={{ width: 34, height: 34, borderRadius: '50%', background: accentColor, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
        {patient?.first_name?.charAt(0)}
      </div>
      <div style={{ flex: 1 }}>
        <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
        <span className="badge b-purple" style={{ marginLeft: 8, fontSize: 10 }}>Post-op</span>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
          {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
        </div>
      </div>
      <div style={{ fontSize: 10, color: 'var(--g400)', width: 90, textAlign: 'right' }}>{rightLabel}</div>
      <button className="btn btn-sm btn-primary" style={accentColor === 'var(--green)' ? { background: 'var(--green)', borderColor: 'transparent' } : undefined}>
        <i className={`ti ${actionIcon}`}></i> {actionLabel}
      </button>
    </div>
  );
}

function TurnedUpTodayTab({ cases, loading, onOpen }) {
  return (
    <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--green)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-user-check" style={{ color: 'var(--green)' }}></i> Turned Up Today for Review
        <span className="badge b-green" style={{ marginLeft: 8 }}>{cases.length}</span>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Only patients with an actual visit today -- opens in the full workspace so you can start the review.
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
      {!loading && cases.map((c) => (
        <PatientRow
          key={c.id}
          c={c}
          onClick={() => onOpen(c.id, false)}
          accentColor="var(--green)"
          rightLabel="Checked in today"
          actionLabel="Start Review"
          actionIcon="ti-clipboard-text"
        />
      ))}
      {!loading && cases.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20, fontSize: 12.5 }}>No post-op patients have checked in yet today.</div>
      )}
    </div>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(1, 1fr)', gap: 10, marginBottom: 14, maxWidth: 260 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Open post-op episodes</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 2 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Patients Pending Review (Not Yet Checked In)</div>
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
          Read-only -- opens for viewing only. Use "Turned Up Today" above to actually start a review.
        </div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => (
          <PatientRow
            key={c.id}
            c={c}
            onClick={() => onOpen(c.id, true)}
            accentColor="var(--purple)"
            rightLabel={`${daysWaiting(c.discharge_date)}d since discharge`}
            actionLabel="View"
            actionIcon="ti-eye"
          />
        ))}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No open post-op episodes.</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Closed Episodes</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Outcome</th><th>Closed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e.id, true)} style={{ cursor: 'pointer' }}>
                <td><strong>{e.surgical_cases?.patients?.first_name} {e.surgical_cases?.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.surgical_cases?.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{e.surgical_cases?.procedure_name} ({e.surgical_cases?.eye})</td>
                <td><span className="badge b-purple" style={{ fontSize: 10 }}>{e.closure_status}</span></td>
                <td style={{ fontSize: 12 }}>{e.closure_outcome}</td>
                <td style={{ fontSize: 11 }}>{e.closed_at ? new Date(e.closed_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No closed episodes yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function PostOpPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [workspaceReadOnly, setWorkspaceReadOnly] = useState(false);
  const [cases, setCases] = useState([]);
  const [turnedUpToday, setTurnedUpToday] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingTurnedUp, setLoadingTurnedUp] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getPostOpCaseList()); setLoadingCases(false); }, []);
  const refreshTurnedUp = useCallback(async () => { setTurnedUpToday(await getPostOpTurnedUpToday()); setLoadingTurnedUp(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getPostOpHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshTurnedUp(); refreshHistory(); }, [refreshCases, refreshTurnedUp, refreshHistory]);

  function openCase(id, readOnly) {
    setSelectedId(id);
    setWorkspaceReadOnly(!!readOnly);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-list" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && (
        <>
          <TurnedUpTodayTab cases={turnedUpToday} loading={loadingTurnedUp} onOpen={openCase} />
          <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />
        </>
      )}
      {activeTab === 'workspace' && selectedId && (
        <Workspace episodeId={selectedId} readOnly={workspaceReadOnly} onBack={handleBack} onUpdate={handleUpdate} />
      )}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}
