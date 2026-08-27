'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter, useSearchParams } from 'next/navigation';
import { getOTCaseList, getCheckinHistory, getSurgeryLandingForPatient } from '../ot-intraop/actions';
import { getPatientById } from '../visits/actions';
import { DashboardTab, TabButton } from '../ot-intraop/page';
import Workspace from '../ot-intraop/workspace';

// Every check-in completed before today -- distinct from Intraoperative
// Management's History (which tracks completed SURGERIES). A patient
// checked in yesterday but not yet operated on still needs to show up
// here so staff can find and correct their check-in record.
function CheckinHistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((r) => {
        const q = search.trim().toLowerCase();
        const patient = r.surgical_cases?.patients;
        return `${formatPatientName(patient)}`.toLowerCase().includes(q) || (patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Checked-In Patients</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Date</th><th>Patient</th><th>Procedure</th><th>Session</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => {
              const sc = r.surgical_cases;
              const patient = sc?.patients;
              return (
                <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td><strong>{formatPatientName(patient)}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>{sc?.procedure_name} ({sc?.eye})</td>
                  <td style={{ fontSize: 12 }}>{r.master_ot_sessions?.name || '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              );
            })}
            {filtered.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No checked-in patients found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── LANDING RESOLVER -- where a Surgery-type visit sends the patient
// when today isn't a clean match to an OT booking. This is the whole
// point of routing every Surgery visit here rather than the Front
// Office Dashboard: instead of the patient silently landing nowhere
// useful (or an easy-to-miss one-off warning on the New Visit form),
// staff see exactly what's going on and can act on it immediately --
// reschedule an existing booking to today, or register the surgery
// directly if no case exists at all.
function LandingResolver({ patientId, landing, patient, onGoDashboard }) {
  return (
    <div className="card" style={{ borderColor: 'var(--amber)' }}>
      <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 4, color: 'var(--amber)' }}>
        <i className="ti ti-alert-triangle" style={{ marginRight: 6 }}></i>
        {landing.needsReschedule ? "This surgery isn't scheduled for today" : 'No surgical case found for this patient'}
      </div>
      {patient && (
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 12 }}>
          <strong>{formatPatientName(patient)}</strong> -- {patient.uhid} -- {patient.mobile}
        </div>
      )}

      {landing.needsReschedule && (
        <div style={{ fontSize: 13, color: 'var(--g600)', lineHeight: 1.6, marginBottom: 6 }}>
          {landing.procedureName ? `${landing.procedureName} (${landing.eye})` : 'This surgical case'} is currently scheduled for{' '}
          <strong>{new Date(`${landing.scheduledDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</strong>
          {landing.sessionName ? ` (${landing.sessionName} session)` : ''} -- not today. A visit was created for this patient today, but check-in can only happen on the actual scheduled day.
          Decide whether this booking needs to move to today (Reschedule) or the patient came in for something else.
        </div>
      )}
      {landing.noCase && (
        <div style={{ fontSize: 13, color: 'var(--g600)', lineHeight: 1.6, marginBottom: 6 }}>
          A visit was created for this patient today as Surgery type, but there's no surgical case on file for them at all. This usually means the surgical decision was made outside today's Doctor / Counselling flow -- e.g. a returning patient whose surgery was arranged before HMIS existed, or an external referral.
          Use OT Schedule's <strong>&quot;Register Surgery Directly&quot;</strong> to add their case and slot them in.
        </div>
      )}

      <div style={{ display: 'flex', gap: 10, marginTop: 16 }}>
        <a href="/ot-schedule" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-calendar-event"></i> Go to OT Schedule
        </a>
        <button className="btn" onClick={onGoDashboard}>Back to Check-In Dashboard</button>
      </div>
    </div>
  );
}

// Patient Check-In is split out from what used to be the combined
// "Operation Theatre" module (Patient Check-In + Intraoperative
// Management as two tabs in one screen) into its own module. The
// underlying case list, data, and check-in checklist itself are
// unchanged -- only the navigation/entry point is split; Intraoperative
// Management lives at /ot-intraop.
//
// Deep-linkable two ways:
//   - ?otScheduleId=... -- Surgical Journey's Patient Check-In step
//     links straight here with the case's OT schedule id so it opens
//     the patient's own record instead of dropping onto the Dashboard
//     for a manual pick.
//   - ?patientId=... -- every Surgery-type visit (Visits -> New Visit)
//     lands here now, whether or not today happens to be the patient's
//     scheduled OT day. getSurgeryLandingForPatient resolves which of
//     those it is; a same-day match silently becomes the normal
//     ?otScheduleId= flow above, anything else shows LandingResolver.
function PatientCheckinInner() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const deepLinkId = searchParams.get('otScheduleId');
  const landingPatientId = searchParams.get('patientId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [landing, setLanding] = useState(null);
  const [landingPatient, setLandingPatient] = useState(null);
  const [landingLoading, setLandingLoading] = useState(!!landingPatientId && !deepLinkId);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getCheckinHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  useEffect(() => {
    if (!landingPatientId || deepLinkId) return;
    let cancelled = false;
    (async () => {
      const [result, patient] = await Promise.all([getSurgeryLandingForPatient(landingPatientId), getPatientById(landingPatientId)]);
      if (cancelled) return;
      setLandingPatient(patient);
      if (result.otScheduleId && !result.needsReschedule) {
        // Clean same-day match -- go straight into the normal workspace
        // flow, no need to show the resolver at all.
        setSelectedId(result.otScheduleId);
        setActiveTab('workspace');
        router.replace(`/patient-checkin?otScheduleId=${result.otScheduleId}`);
      } else {
        setLanding(result);
      }
      setLandingLoading(false);
    })();
    return () => { cancelled = true; };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [landingPatientId, deepLinkId]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setLanding(null);
    setActiveTab('dashboard');
  }

  if (landingLoading) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Checking today's surgery schedule for this patient...</div>;
  }

  if (landing) {
    return <LandingResolver patientId={landingPatientId} landing={landing} patient={landingPatient} onGoDashboard={() => { setLanding(null); router.replace('/patient-checkin'); }} />;
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-check" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} returnTo="patient-checkin" variant="checkin" />}
      {activeTab === 'history' && <CheckinHistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="checkin" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
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
