'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { getOTCaseList } from '../ot-intraop/actions';
import { DashboardTab, TabButton } from '../ot-intraop/page';
import Workspace from '../ot-intraop/workspace';

// Patient Check-In is split out from what used to be the combined
// "Operation Theatre" module (Patient Check-In + Intraoperative
// Management as two tabs in one screen) into its own module. The
// underlying case list, data, and check-in checklist itself are
// unchanged -- only the navigation/entry point is split; Intraoperative
// Management lives at /ot-intraop.
//
// Deep-linkable via ?otScheduleId=... -- Surgical Journey's Patient
// Check-In step links straight here with the case's OT schedule id so
// it opens the patient's own record instead of dropping onto the
// Dashboard for a manual pick.
function PatientCheckinInner() {
  const searchParams = useSearchParams();
  const deepLinkId = searchParams.get('otScheduleId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);

  useEffect(() => { refreshCases(); }, [refreshCases]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 360 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-check" label="Workspace" disabled={!selectedId} />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} returnTo="patient-checkin" variant="checkin" />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="checkin" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard.</div>
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
