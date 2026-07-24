'use client';

import { useState, useEffect, useCallback } from 'react';
import { getRecoveryCaseList, getRecoveryHistory } from './actions';
import Workspace from './workspace';
import EpisodeTracker from './episode-tracker';
import QualityIndicators from './quality-indicators';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--teal)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  const inRecovery = cases.filter((c) => !c.discharge_date).length;
  const discharged = cases.filter((c) => c.discharge_date).length;

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--teal)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In recovery</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{inRecovery}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Discharged, episode open</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{discharged}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Total open episodes</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Patients in Recovery / Post-op</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--teal)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${c.discharge_date ? 'b-green' : 'b-amber'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.discharge_date ? 'Discharged' : 'Recovery'}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
                </div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No patients currently in recovery.</div>
        )}
      </div>
    </div>
  );
}

export default function RecoveryPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getRecoveryCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getRecoveryHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, flexWrap: 'wrap' }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-bed" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'episodes'} onClick={() => setActiveTab('episodes')} icon="ti-list" label="Episode Tracker" disabled={!selectedId} />
        <TabButton active={activeTab === 'quality'} onClick={() => setActiveTab('quality')} icon="ti-chart-bar" label="Quality Indicators" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace episodeId={selectedId} onBack={handleBack} onUpdate={handleUpdate} onGoEpisodes={() => setActiveTab('episodes')} />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'episodes' && selectedId && <EpisodeTracker episodeId={selectedId} onUpdate={handleUpdate} />}
      {activeTab === 'episodes' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Open a patient in Workspace first.</div>
      )}
      {activeTab === 'quality' && <QualityIndicators />}

      {!loadingHistory && history.length > 0 && activeTab === 'dashboard' && (
        <div className="card" style={{ marginTop: 14 }}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Recently Closed Episodes</div>
          {history.slice(0, 5).map((h) => (
            <div key={h.id} onClick={() => openCase(h.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer', fontSize: 12 }}>
              <span style={{ flex: 1 }}><strong>{h.surgical_cases.patients?.first_name} {h.surgical_cases.patients?.last_name}</strong> -- {h.surgical_cases.procedure_name}</span>
              <span className="badge b-purple" style={{ fontSize: 10 }}>{h.closure_status}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

