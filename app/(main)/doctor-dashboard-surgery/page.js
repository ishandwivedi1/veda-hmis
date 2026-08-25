'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardHistory } from './actions';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { getPostOpTurnedUpToday } from '@/app/(main)/ot-postop/actions';
import { getSurgicalCaseLists } from '@/app/(main)/surgical-journey/actions';
import { getMedicalFitnessQueue } from '@/app/(main)/medical-fitness/actions';

function patientName(sc) {
  const p = sc?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

// IST "today" as YYYY-MM-DD, matching the date-only columns (scheduled_date,
// discharge_date) coming back from Postgres -- string comparison is exact.
function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function StatCard({ label, value, caption, color }) {
  return (
    <div className="card" style={{ borderTop: `3px solid ${color}` }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{value}</div>
      <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{caption}</div>
    </div>
  );
}

// A pure count tile -- no patient names, no per-row list. The whole
// card is a single click-through straight into the relevant workflow
// page (Check-In, Intraop, Recovery, Post-Op, etc.), same as tapping a
// stat card. Replaces the earlier per-patient WidgetRow list: the
// surgeon wants "how many, and take me there," not a name list here.
function WorkflowTile({ icon, iconColor, title, count, hint, onClick }) {
  return (
    <div
      onClick={onClick}
      className="card"
      style={{ cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}
    >
      <div>
        <div className="card-title" style={{ marginBottom: 4 }}><i className={`ti ${icon}`} style={{ color: iconColor }}></i> {title}</div>
        {hint && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{hint}</div>}
      </div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, flexShrink: 0 }}>
        <div style={{ fontSize: 26, fontWeight: 800, color: 'var(--g800)' }}>{count}</div>
        <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
      </div>
    </div>
  );
}

// Same click-through tile, but for Surgical Journey specifically --
// shows two counts side by side (Active cases -- advance paid, or
// surgery already done -- and cases Awaiting Confirmation -- no
// advance paid yet, regardless of decision or booking status) since
// that's the one place on this dashboard the surgeon asked to see
// both numbers at a glance, not just one.
function DualCountTile({ icon, iconColor, title, hint, items, onClick }) {
  return (
    <div onClick={onClick} className="card" style={{ cursor: 'pointer' }}>
      <div style={{ display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' }}>
        <div>
          <div className="card-title" style={{ marginBottom: 4 }}><i className={`ti ${icon}`} style={{ color: iconColor }}></i> {title}</div>
          {hint && <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>{hint}</div>}
        </div>
        <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
      </div>
      <div style={{ display: 'flex', gap: 24 }}>
        {items.map((it) => (
          <div key={it.label}>
            <div style={{ fontSize: 24, fontWeight: 800, color: it.color || 'var(--g800)' }}>{it.value}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)' }}>{it.label}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

const STAGE_COLORS = {
  'Scheduled': 'var(--amber)',
  'Checked-In / In OT': 'var(--blue)',
  'In Recovery': 'var(--purple)',
  'Discharged': 'var(--green)',
};

function StageBadge({ stage }) {
  const c = STAGE_COLORS[stage] || 'var(--g400)';
  return <span className="badge" style={{ background: `${c}20`, color: c, fontWeight: 700 }}>{stage}</span>;
}

function CaseRow({ sc, dateLabel, dateValue, stage, onClick }) {
  return (
    <tr onClick={onClick} style={{ cursor: 'pointer' }}>
      <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{sc.surgery_code || '--'}</td>
      <td>
        <strong>{patientName(sc)}</strong>
        <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span>
      </td>
      <td style={{ fontSize: 12 }}>{sc.procedure_name}{sc.eye ? ` (${sc.eye})` : ''}</td>
      <td style={{ fontSize: 11 }}>{sc.profiles?.full_name || '--'}</td>
      <td style={{ fontSize: 11 }}>{dateLabel}: {fmtDate(dateValue)}</td>
      <td><StageBadge stage={stage} /></td>
      <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
    </tr>
  );
}

// ── DASHBOARD -- OPD-style: a top row of stat cards for today's shape
// of the surgical pipeline, then a row of count tiles, one per place a
// surgical case actually needs a person to act on it. Deliberately no
// patient names here -- each tile is just a count, and clicking it
// takes the surgeon straight to that workflow page to pick a patient.
function DashboardTab({ scheduled, active, history, iolApprovals, postOpToday, surgicalJourneyActive, awaitingReturnCases, medicalFitnessQueue, error, onOpenScheduled, onOpenIntraop, onOpenRecovery, onOpenIol, onOpenPostOp, onOpenSurgicalJourney, onOpenMedicalFitness }) {
  const today = todayIst();
  const todayScheduled = useMemo(() => scheduled.filter((b) => b.scheduled_date === today), [scheduled, today]);
  const inOt = useMemo(() => active.filter((b) => b.stage === 'Checked-In / In OT'), [active]);
  const inRecovery = useMemo(() => active.filter((b) => b.stage === 'In Recovery'), [active]);
  const dischargedToday = useMemo(() => history.filter((e) => e.discharge_date === today), [history, today]);

  return (
    <div>
      {error && <div className="msg-err" style={{ marginBottom: 16 }}><i className="ti ti-alert-triangle"></i> {error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <StatCard label="Scheduled Today" value={todayScheduled.length} caption="Awaiting check-in" color="var(--amber)" />
        <StatCard label="In OT" value={inOt.length} caption="Checked in, intraoperative" color="var(--blue)" />
        <StatCard label="In Recovery" value={inRecovery.length} caption="Discharge pending" color="var(--purple)" />
        <StatCard label="Discharged Today" value={dischargedToday.length} caption="Completed today" color="var(--green)" />
      </div>

      {/* 7 tiles across 4 columns -- lands as two rows (4 + 3) instead of
          spilling into an odd third row at 3 columns. */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <DualCountTile
          icon="ti-route" iconColor="var(--indigo)" title="Surgical Workflow" hint="Advance paid vs. still awaiting confirmation."
          items={[
            { label: 'Active', value: surgicalJourneyActive.length, color: 'var(--indigo)' },
            { label: 'Awaiting Confirmation', value: awaitingReturnCases.length, color: 'var(--amber)' },
          ]}
          onClick={onOpenSurgicalJourney}
        />
        <WorkflowTile icon="ti-heartbeat" iconColor="var(--red)" title="Medical Fitness" count={medicalFitnessQueue.length} hint="Referred, fitness clearance pending." onClick={onOpenMedicalFitness} />
        <WorkflowTile icon="ti-lens" iconColor="var(--indigo)" title="IOL Approval" count={iolApprovals.length} hint="Only a doctor can approve." onClick={onOpenIol} />
        <WorkflowTile icon="ti-clipboard-check" iconColor="var(--amber)" title="Patient Check-In" count={todayScheduled.length} hint="Scheduled for today, not yet checked in." onClick={onOpenScheduled} />
        <WorkflowTile icon="ti-scalpel" iconColor="var(--blue)" title="Intraoperative Management" count={inOt.length} hint="Checked in and in OT right now." onClick={onOpenIntraop} />
        <WorkflowTile icon="ti-bed" iconColor="var(--purple)" title="Recovery & Discharge" count={inRecovery.length} hint="Surgery done, not yet discharged." onClick={onOpenRecovery} />
        <WorkflowTile icon="ti-stethoscope" iconColor="var(--teal)" title="Post-Op" count={postOpToday.length} hint="Turned up today for post-op review." onClick={onOpenPostOp} />
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = rows.filter((e) => {
    if (!search.trim()) return true;
    const q = search.toLowerCase();
    const sc = e.surgical_cases;
    return patientName(sc).toLowerCase().includes(q) || sc.patients?.uhid?.toLowerCase().includes(q) || sc.surgery_code?.toLowerCase().includes(q) || sc.procedure_name?.toLowerCase().includes(q);
  });

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--green)' }}></i> Completed & Discharged Surgeries</div>
        <input className="fi fi-sm" placeholder="Search patient, UHID, surgery ID..." value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 220 }} />
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <table className="tbl">
          <thead><tr><th>Surgery ID</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Discharged</th><th>Stage</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <CaseRow key={e.id} sc={e.surgical_cases} stage="Discharged" dateLabel="Discharged" dateValue={e.discharge_date} onClick={() => onOpen(e)} />
            ))}
            {filtered.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed surgeries found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorSurgeryDashboardPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState('dashboard');
  const [scheduled, setScheduled] = useState([]);
  const [active, setActive] = useState([]);
  const [history, setHistory] = useState([]);
  const [iolApprovals, setIolApprovals] = useState([]);
  const [postOpToday, setPostOpToday] = useState([]);
  const [surgicalJourneyActive, setSurgicalJourneyActive] = useState([]);
  const [awaitingReturnCases, setAwaitingReturnCases] = useState([]);
  const [medicalFitnessQueue, setMedicalFitnessQueue] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    try {
      const [s, a, h, iol, postOp, surgicalCaseLists, medFitness] = await Promise.all([
        getSurgeryDashboardScheduled(),
        getSurgeryDashboardActive(),
        getSurgeryDashboardHistory(),
        getPendingIolApprovals(),
        getPostOpTurnedUpToday(),
        getSurgicalCaseLists(),
        getMedicalFitnessQueue(),
      ]);
      const firstError = s.error || a.error || h.error;
      setScheduled(s.rows); setActive(a.rows); setHistory(h.rows);
      setIolApprovals(iol || []);
      setPostOpToday(postOp || []);
      setSurgicalJourneyActive(surgicalCaseLists.active || []);
      setAwaitingReturnCases(surgicalCaseLists.awaitingConfirmation || []);
      setMedicalFitnessQueue(medFitness || []);
      setError(firstError || '');
      setLoadingHistory(false);
      if (firstError) console.error('Surgery Dashboard load error:', firstError);
    } catch (e) {
      // Belt-and-braces: even if a Server Action call itself fails
      // (network drop, deploy mid-flight, etc.) rather than returning
      // its own { error }, this still guarantees loading clears and
      // something visible shows up instead of an infinite spinner.
      console.error('Surgery Dashboard refresh failed:', e);
      setError(e?.message || 'Failed to load Surgery Dashboard.');
      setLoadingHistory(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  // Every tile below is a pure count -- no patient names shown on this
  // dashboard -- so clicking always lands on the workflow page's own
  // list/queue, not a specific patient's record. The surgeon picks the
  // patient from there.
  function openScheduled() {
    router.push('/patient-checkin');
  }

  function openIntraop() {
    router.push('/ot-intraop');
  }

  function openRecovery() {
    router.push('/ot-recovery');
  }

  function openIol() {
    router.push('/iol-approval');
  }

  function openMedicalFitness() {
    router.push('/medical-fitness');
  }

  function openPostOp() {
    router.push('/ot-postop');
  }

  function openSurgicalJourney() {
    router.push('/surgical-journey');
  }

  // History -- Recovery & Discharge workspace already renders discharged
  // episodes fine (Recovery's own History tab uses the same component).
  function openHistory(episode) {
    router.push(`/ot-recovery?episodeId=${episode.id}`);
  }

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 800, color: 'var(--g800)' }}>Surgery Dashboard</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Every surgical case, and exactly where it needs attention -- across Surgical Workflow, Medical Fitness, IOL Approval, Check-In, OT, Recovery, and Post-Op.</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520, flex: 1 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
        <button className="btn btn-sm" style={{ marginLeft: 16 }} onClick={() => router.push('/doctor-dashboard')}>
          <i className="ti ti-stethoscope"></i> OPD Dashboard
        </button>
      </div>

      {activeTab === 'dashboard' && (
        <DashboardTab
          scheduled={scheduled} active={active} history={history}
          iolApprovals={iolApprovals} postOpToday={postOpToday}
          surgicalJourneyActive={surgicalJourneyActive} awaitingReturnCases={awaitingReturnCases}
          medicalFitnessQueue={medicalFitnessQueue}
          error={error}
          onOpenScheduled={openScheduled} onOpenIntraop={openIntraop} onOpenRecovery={openRecovery}
          onOpenIol={openIol} onOpenPostOp={openPostOp} onOpenSurgicalJourney={openSurgicalJourney}
          onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openHistory} />}
    </div>
  );
}
