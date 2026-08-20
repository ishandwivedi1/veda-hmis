'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardHistory } from './actions';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { getPostOpTurnedUpToday } from '@/app/(main)/ot-postop/actions';

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

// Same list-row language as the OPD Doctor Dashboard's widgets (Waiting
// in Optometry / IOL Approvals / Medical Fitness) -- a patient line with
// context underneath and a right-aligned action button, so a surgeon
// reads this dashboard exactly like they already read the OPD one.
function WidgetRow({ title, subtitle, badge, badgeClass, onClick, actionLabel, actionIcon }) {
  return (
    <div onClick={onClick} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
      <div>
        {title}
        {badge && <span className={`badge ${badgeClass || 'b-gray'}`} style={{ marginLeft: 6, fontSize: 10 }}>{badge}</span>}
        <div style={{ fontSize: 11, color: 'var(--g500)' }}>{subtitle}</div>
      </div>
      <button className="btn btn-sm btn-primary" onClick={(e) => { e.stopPropagation(); onClick(); }}>
        <i className={`ti ${actionIcon}`}></i> {actionLabel}
      </button>
    </div>
  );
}

function WidgetCard({ icon, iconColor, title, count, hint, children, empty }) {
  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title"><i className={`ti ${icon}`} style={{ color: iconColor }}></i> {title}<span className="badge b-gray">{count}</span></div>
      </div>
      {hint && <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>{hint}</div>}
      {count > 0 ? children : <div style={{ fontSize: 12, color: 'var(--g400)' }}>{empty}</div>}
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
// of the surgical pipeline, then a grid of workflow-stage widgets, one
// per place a surgical case actually needs a person to act on it. Every
// widget row opens the record directly, same as the OPD Dashboard's
// Doctor Queue / IOL Approvals / Medical Fitness widgets do.
function DashboardTab({ scheduled, active, history, iolApprovals, postOpToday, error, onOpenScheduled, onOpenIntraop, onOpenRecovery, onOpenIol, onOpenPostOp }) {
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

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 20, marginBottom: 20 }}>
        <WidgetCard icon="ti-lens" iconColor="var(--indigo)" title="IOL Approval" count={iolApprovals.length} hint="Only a doctor can approve." empty="Nothing awaiting approval.">
          {iolApprovals.map((b) => (
            <WidgetRow
              key={b.caseId}
              title={`${b.patient?.first_name} ${b.patient?.last_name}`}
              badge={b.eye} badgeClass="b-indigo"
              subtitle={`${b.patient?.uhid || ''} -- ${b.procedureName || ''}`}
              onClick={onOpenIol}
              actionLabel="Approve" actionIcon="ti-lens"
            />
          ))}
        </WidgetCard>

        <WidgetCard icon="ti-clipboard-check" iconColor="var(--amber)" title="Patient Check-In" count={todayScheduled.length} hint="Scheduled for today, not yet checked in." empty="No one due for check-in today.">
          {todayScheduled.map((b) => (
            <WidgetRow
              key={b.id}
              title={patientName(b.surgical_cases)}
              badge={b.surgical_cases?.eye} badgeClass="b-amber"
              subtitle={`${b.surgical_cases?.patients?.uhid || ''} -- ${b.surgical_cases?.procedure_name || ''}`}
              onClick={() => onOpenScheduled(b)}
              actionLabel="Check In" actionIcon="ti-arrow-right"
            />
          ))}
        </WidgetCard>

        <WidgetCard icon="ti-scalpel" iconColor="var(--blue)" title="Intraoperative Management" count={inOt.length} hint="Checked in and in OT right now." empty="No one currently in OT.">
          {inOt.map((b) => (
            <WidgetRow
              key={b.id}
              title={patientName(b.surgical_cases)}
              badge={b.surgical_cases?.eye} badgeClass="b-blue"
              subtitle={`${b.surgical_cases?.patients?.uhid || ''} -- ${b.surgical_cases?.procedure_name || ''}`}
              onClick={() => onOpenIntraop(b)}
              actionLabel="Open" actionIcon="ti-arrow-right"
            />
          ))}
        </WidgetCard>

        <WidgetCard icon="ti-bed" iconColor="var(--purple)" title="Recovery & Discharge" count={inRecovery.length} hint="Surgery done, not yet discharged." empty="No one currently in recovery.">
          {inRecovery.map((b) => (
            <WidgetRow
              key={b.id}
              title={patientName(b.surgical_cases)}
              badge={b.surgical_cases?.eye} badgeClass="b-purple"
              subtitle={`${b.surgical_cases?.patients?.uhid || ''} -- ${b.surgical_cases?.procedure_name || ''}`}
              onClick={() => onOpenRecovery(b)}
              actionLabel="Open" actionIcon="ti-arrow-right"
            />
          ))}
        </WidgetCard>

        <WidgetCard icon="ti-stethoscope" iconColor="var(--teal)" title="Post-Op" count={postOpToday.length} hint="Turned up today for post-op review." empty="No post-op reviews today.">
          {postOpToday.map((e) => (
            <WidgetRow
              key={e.id}
              title={patientName(e.surgical_cases)}
              badge={e.surgical_cases?.eye} badgeClass="b-teal"
              subtitle={`${e.surgical_cases?.patients?.uhid || ''} -- ${e.surgical_cases?.procedure_name || ''}`}
              onClick={() => onOpenPostOp(e)}
              actionLabel="Open" actionIcon="ti-arrow-right"
            />
          ))}
        </WidgetCard>
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
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    try {
      const [s, a, h, iol, postOp] = await Promise.all([
        getSurgeryDashboardScheduled(),
        getSurgeryDashboardActive(),
        getSurgeryDashboardHistory(),
        getPendingIolApprovals(),
        getPostOpTurnedUpToday(),
      ]);
      const firstError = s.error || a.error || h.error;
      setScheduled(s.rows); setActive(a.rows); setHistory(h.rows);
      setIolApprovals(iol || []);
      setPostOpToday(postOp || []);
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

  // Scheduled -- always send to Patient Check-In (matches the "Register
  // Surgery / Check-In" entry point Surgery-type visits already land on).
  function openScheduled(booking) {
    router.push(`/patient-checkin?otScheduleId=${booking.id}`);
  }

  function openIntraop(booking) {
    router.push(`/ot-intraop?otScheduleId=${booking.id}`);
  }

  function openRecovery(booking) {
    if (booking.recoveryEpisodeId) router.push(`/ot-recovery?episodeId=${booking.recoveryEpisodeId}`);
  }

  function openIol() {
    router.push('/iol-approval');
  }

  function openPostOp(episode) {
    router.push(`/ot-postop?episodeId=${episode.id}`);
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
        <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Every surgical case, and exactly where it needs attention -- across IOL Approval, Check-In, OT, Recovery, and Post-Op.</div>
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
          error={error}
          onOpenScheduled={openScheduled} onOpenIntraop={openIntraop} onOpenRecovery={openRecovery}
          onOpenIol={openIol} onOpenPostOp={openPostOp}
        />
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openHistory} />}
    </div>
  );
}
