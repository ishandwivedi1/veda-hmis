'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardHistory } from './actions';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { getPostOpTurnedUpToday, getPostOpCaseList } from '@/app/(main)/ot-postop/actions';

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

function daysSinceDischarge(dischargeDate) {
  if (!dischargeDate) return 0;
  return Math.floor((new Date() - new Date(`${dischargeDate}T00:00:00`)) / (1000 * 60 * 60 * 24));
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
function DashboardTab({ scheduled, active, history, iolApprovals, postOpToday, postOpPending, error, onOpenScheduled, onOpenIntraop, onOpenRecovery, onOpenIol, onOpenPostOp, onOpenAwaitingReturn }) {
  const today = todayIst();
  const todayScheduled = useMemo(() => scheduled.filter((b) => b.scheduled_date === today), [scheduled, today]);
  const inOt = useMemo(() => active.filter((b) => b.stage === 'Checked-In / In OT'), [active]);
  const inRecovery = useMemo(() => active.filter((b) => b.stage === 'In Recovery'), [active]);
  const dischargedToday = useMemo(() => history.filter((e) => e.discharge_date === today), [history, today]);
  // "Awaiting Return" -- discharged from surgery, follow-up review still
  // pending (recovery_episodes.closure_status IS NULL, same signal the
  // Post-Op module itself uses), and not already accounted for by the
  // "turned up today" widget so a patient never shows in both places at
  // once. Sorted longest-waiting first so an overdue follow-up surfaces
  // at the top.
  const awaitingReturn = useMemo(() => {
    const todayIds = new Set(postOpToday.map((e) => e.id));
    return postOpPending
      .filter((e) => !todayIds.has(e.id))
      .map((e) => ({ ...e, daysSince: daysSinceDischarge(e.discharge_date) }))
      .sort((a, b) => b.daysSince - a.daysSince);
  }, [postOpPending, postOpToday]);

  return (
    <div>
      {error && <div className="msg-err" style={{ marginBottom: 16 }}><i className="ti ti-alert-triangle"></i> {error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 16, marginBottom: 20 }}>
        <StatCard label="Scheduled Today" value={todayScheduled.length} caption="Awaiting check-in" color="var(--amber)" />
        <StatCard label="In OT" value={inOt.length} caption="Checked in, intraoperative" color="var(--blue)" />
        <StatCard label="In Recovery" value={inRecovery.length} caption="Discharge pending" color="var(--purple)" />
        <StatCard label="Awaiting Return" value={awaitingReturn.length} caption="Post-op follow-up pending" color="var(--red)" />
        <StatCard label="Discharged Today" value={dischargedToday.length} caption="Completed today" color="var(--green)" />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 20, marginBottom: 20 }}>
        <WorkflowTile icon="ti-lens" iconColor="var(--indigo)" title="IOL Approval" count={iolApprovals.length} hint="Only a doctor can approve." onClick={onOpenIol} />
        <WorkflowTile icon="ti-clipboard-check" iconColor="var(--amber)" title="Patient Check-In" count={todayScheduled.length} hint="Scheduled for today, not yet checked in." onClick={onOpenScheduled} />
        <WorkflowTile icon="ti-scalpel" iconColor="var(--blue)" title="Intraoperative Management" count={inOt.length} hint="Checked in and in OT right now." onClick={onOpenIntraop} />
        <WorkflowTile icon="ti-bed" iconColor="var(--purple)" title="Recovery & Discharge" count={inRecovery.length} hint="Surgery done, not yet discharged." onClick={onOpenRecovery} />
        <WorkflowTile icon="ti-stethoscope" iconColor="var(--teal)" title="Post-Op" count={postOpToday.length} hint="Turned up today for post-op review." onClick={onOpenPostOp} />
        <WorkflowTile icon="ti-clock-hour-4" iconColor="var(--red)" title="Awaiting Return" count={awaitingReturn.length} hint="Discharged, follow-up review not yet done." onClick={onOpenAwaitingReturn} />
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
  const [postOpPending, setPostOpPending] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    try {
      const [s, a, h, iol, postOp, postOpAll] = await Promise.all([
        getSurgeryDashboardScheduled(),
        getSurgeryDashboardActive(),
        getSurgeryDashboardHistory(),
        getPendingIolApprovals(),
        getPostOpTurnedUpToday(),
        getPostOpCaseList(),
      ]);
      const firstError = s.error || a.error || h.error;
      setScheduled(s.rows); setActive(a.rows); setHistory(h.rows);
      setIolApprovals(iol || []);
      setPostOpToday(postOp || []);
      setPostOpPending(postOpAll || []);
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

  function openPostOp() {
    router.push('/ot-postop');
  }

  function openAwaitingReturn() {
    router.push('/ot-postop');
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
        <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Every surgical case, and exactly where it needs attention -- across IOL Approval, Check-In, OT, Recovery, Post-Op, and Awaiting Return.</div>
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
          iolApprovals={iolApprovals} postOpToday={postOpToday} postOpPending={postOpPending}
          error={error}
          onOpenScheduled={openScheduled} onOpenIntraop={openIntraop} onOpenRecovery={openRecovery}
          onOpenIol={openIol} onOpenPostOp={openPostOp} onOpenAwaitingReturn={openAwaitingReturn}
        />
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openHistory} />}
    </div>
  );
}
