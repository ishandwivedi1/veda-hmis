#!/usr/bin/env bash
set -euo pipefail

echo "Applying: Surgery Dashboard redesign -- unified Today tab, today badges, professional polish"

mkdir -p "$(dirname "app/(main)/doctor-dashboard-surgery/page.js")"
cat > "app/(main)/doctor-dashboard-surgery/page.js" << 'VEDA_EOF_MARKER'
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardHistory } from './actions';

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

function TabButton({ active, onClick, icon, label, count, highlight }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '9px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none', position: 'relative' }}
    >
      <i className={`ti ${icon}`}></i> {label}
      {typeof count === 'number' && (
        <span className="badge" style={{ marginLeft: 6, background: highlight && count > 0 ? 'var(--teal)' : 'var(--g200)', color: highlight && count > 0 ? '#fff' : 'var(--g600)' }}>
          {count}
        </span>
      )}
    </button>
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

function TodayBadge() {
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 3, padding: '2px 7px', borderRadius: 20, fontSize: 10, fontWeight: 700, background: 'var(--teal)', color: '#fff', marginLeft: 6 }}>
      <i className="ti ti-point-filled" style={{ fontSize: 10 }}></i> TODAY
    </span>
  );
}

function CaseRow({ sc, dateLabel, dateValue, stage, isToday, onClick }) {
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
      <td>
        <StageBadge stage={stage} />
        {isToday && <TodayBadge />}
      </td>
      <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
    </tr>
  );
}

function EmptyRow({ label }) {
  return (
    <tr>
      <td colSpan={7} style={{ padding: '32px 16px', textAlign: 'center', color: 'var(--g400)' }}>
        <i className="ti ti-mood-empty" style={{ fontSize: 22, display: 'block', marginBottom: 6, color: 'var(--g300)' }}></i>
        {label}
      </td>
    </tr>
  );
}

function CaseTable({ rows, emptyLabel, dateLabel, children }) {
  return (
    <table className="tbl">
      <thead><tr><th>Surgery ID</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>{dateLabel}</th><th>Stage</th><th></th></tr></thead>
      <tbody>
        {children}
        {rows.length === 0 && <EmptyRow label={emptyLabel} />}
      </tbody>
    </table>
  );
}

// ── TODAY -- everything touching today's surgical activity in one
// place, regardless of which stage a case is currently at. This is the
// dashboard's default view specifically so a patient who was scheduled,
// operated, and discharged all in the same day (a fast same-day case)
// is never only reachable via a tab someone wouldn't think to check --
// nothing about today's list depends on remembering which bucket a
// case has moved into since this morning.
function TodayTab({ todayScheduled, active, todayDischarged, loading, onOpen }) {
  const rows = [
    ...todayScheduled.map((b) => ({ kind: 'scheduled', b })),
    ...active.map((b) => ({ kind: 'active', b })),
    ...todayDischarged.map((e) => ({ kind: 'history', b: e })),
  ];

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-sun-high" style={{ color: 'var(--teal)' }}></i> Today's Surgical Activity</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <CaseTable rows={rows} dateLabel="Date" emptyLabel="Nothing scheduled, in progress, or discharged today.">
          {rows.map(({ kind, b }) => {
            if (kind === 'scheduled') {
              return <CaseRow key={`sch-${b.id}`} sc={b.surgical_cases} stage="Scheduled" dateLabel="OT Date" dateValue={b.scheduled_date} isToday onClick={() => onOpen('scheduled', b)} />;
            }
            if (kind === 'active') {
              return <CaseRow key={`act-${b.id}`} sc={b.surgical_cases} stage={b.stage} dateLabel="OT Date" dateValue={b.scheduled_date} isToday={b.scheduled_date === todayIst()} onClick={() => onOpen('active', b)} />;
            }
            return <CaseRow key={`his-${b.id}`} sc={b.surgical_cases} stage="Discharged" dateLabel="Discharged" dateValue={b.discharge_date} isToday onClick={() => onOpen('history', b)} />;
          })}
        </CaseTable>
      )}
    </div>
  );
}

function ScheduledTab({ rows, loading, onOpen }) {
  const today = todayIst();
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-event" style={{ color: 'var(--amber)' }}></i> Upcoming Scheduled Surgeries</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <CaseTable rows={rows} dateLabel="OT Date" emptyLabel="No upcoming scheduled surgeries.">
          {rows.map((b) => (
            <CaseRow key={b.id} sc={b.surgical_cases} stage="Scheduled" dateLabel="OT Date" dateValue={b.scheduled_date} isToday={b.scheduled_date === today} onClick={() => onOpen(b)} />
          ))}
        </CaseTable>
      )}
    </div>
  );
}

function ActiveTab({ rows, loading, onOpen }) {
  const today = todayIst();
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--blue)' }}></i> Checked In, In OT, or In Recovery</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <CaseTable rows={rows} dateLabel="OT Date" emptyLabel="No cases currently checked in, in OT, or in recovery.">
          {rows.map((b) => (
            <CaseRow key={b.id} sc={b.surgical_cases} stage={b.stage} dateLabel="OT Date" dateValue={b.scheduled_date} isToday={b.scheduled_date === today} onClick={() => onOpen(b)} />
          ))}
        </CaseTable>
      )}
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const today = todayIst();
  const filtered = rows.filter((e) => {
    if (!search.trim()) return true;
    const q = search.toLowerCase();
    const sc = e.surgical_cases;
    return patientName(sc).toLowerCase().includes(q) || sc.patients?.uhid?.toLowerCase().includes(q) || sc.surgery_code?.toLowerCase().includes(q) || sc.procedure_name?.toLowerCase().includes(q);
  });

  return (
    <div className="card">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--green)' }}></i> Completed &amp; Discharged Surgeries</div>
        <input className="input" style={{ maxWidth: 240, fontSize: 12 }} placeholder="Search patient, UHID, surgery ID..." value={search} onChange={(e) => setSearch(e.target.value)} />
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <CaseTable rows={filtered} dateLabel="Discharged" emptyLabel={search ? 'No completed surgeries match your search.' : 'No completed surgeries found.'}>
          {filtered.map((e) => (
            <CaseRow key={e.id} sc={e.surgical_cases} stage="Discharged" dateLabel="Discharged" dateValue={e.discharge_date} isToday={e.discharge_date === today} onClick={() => onOpen(e)} />
          ))}
        </CaseTable>
      )}
    </div>
  );
}

export default function DoctorSurgeryDashboardPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState('today');
  const [scheduled, setScheduled] = useState([]);
  const [active, setActive] = useState([]);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');
  const [lastRefreshed, setLastRefreshed] = useState(null);

  const refresh = useCallback(async () => {
    try {
      const [s, a, h] = await Promise.all([getSurgeryDashboardScheduled(), getSurgeryDashboardActive(), getSurgeryDashboardHistory()]);
      const firstError = s.error || a.error || h.error;
      setScheduled(s.rows); setActive(a.rows); setHistory(h.rows);
      setError(firstError || '');
      setLastRefreshed(new Date());
      if (firstError) console.error('Surgery Dashboard load error:', firstError);
    } catch (e) {
      // Belt-and-braces: even if the Server Action call itself fails
      // (network drop, deploy mid-flight, etc.) rather than returning
      // its own { error }, this still guarantees loading clears and
      // something visible shows up instead of an infinite spinner.
      console.error('Surgery Dashboard refresh failed:', e);
      setError(e?.message || 'Failed to load Surgery Dashboard.');
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  const today = todayIst();
  const todayScheduled = useMemo(() => scheduled.filter((b) => b.scheduled_date === today), [scheduled, today]);
  const todayDischarged = useMemo(() => history.filter((e) => e.discharge_date === today), [history, today]);
  const todayCount = todayScheduled.length + active.length + todayDischarged.length;

  // Scheduled -- always send to Patient Check-In (matches the "Register
  // Surgery / Check-In" entry point Surgery-type visits already land on).
  function openScheduled(booking) {
    router.push(`/patient-checkin?otScheduleId=${booking.id}`);
  }

  // Active -- Checked-In / In OT goes to Intraop, In Recovery goes to
  // Recovery & Discharge, keyed off the same stage computed server-side.
  function openActive(booking) {
    if (booking.stage === 'In Recovery' && booking.recoveryEpisodeId) {
      router.push(`/ot-recovery?episodeId=${booking.recoveryEpisodeId}`);
    } else {
      router.push(`/ot-intraop?otScheduleId=${booking.id}`);
    }
  }

  // History -- Recovery & Discharge workspace already renders discharged
  // episodes fine (Recovery's own History tab uses the same component).
  function openHistory(episode) {
    router.push(`/ot-recovery?episodeId=${episode.id}`);
  }

  function openToday(kind, booking) {
    if (kind === 'scheduled') return openScheduled(booking);
    if (kind === 'active') return openActive(booking);
    return openHistory(booking);
  }

  return (
    <div>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontSize: 18, fontWeight: 800, color: 'var(--g800)' }}>Surgery Dashboard</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>
          Every surgical case across its full journey -- scheduled, in progress, and discharged.
          {lastRefreshed && <span style={{ marginLeft: 8, color: 'var(--g400)' }}><i className="ti ti-refresh" style={{ fontSize: 11 }}></i> Updated {lastRefreshed.toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</span>}
        </div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16, flexWrap: 'wrap', gap: 10 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, flex: 1, minWidth: 480 }}>
          <TabButton active={activeTab === 'today'} onClick={() => setActiveTab('today')} icon="ti-sun-high" label="Today" count={todayCount} highlight />
          <TabButton active={activeTab === 'scheduled'} onClick={() => setActiveTab('scheduled')} icon="ti-calendar-event" label="Scheduled" count={scheduled.length} />
          <TabButton active={activeTab === 'active'} onClick={() => setActiveTab('active')} icon="ti-building-hospital" label="Active" count={active.length} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" count={history.length} />
        </div>
        <button className="btn btn-sm" onClick={() => router.push('/doctor-dashboard')}>
          <i className="ti ti-stethoscope"></i> OPD Dashboard
        </button>
      </div>

      {error && (
        <div className="msg-err" style={{ marginBottom: 12 }}>
          <i className="ti ti-alert-triangle"></i> {error}
        </div>
      )}

      {activeTab === 'today' && <TodayTab todayScheduled={todayScheduled} active={active} todayDischarged={todayDischarged} loading={loading} onOpen={openToday} />}
      {activeTab === 'scheduled' && <ScheduledTab rows={scheduled} loading={loading} onOpen={openScheduled} />}
      {activeTab === 'active' && <ActiveTab rows={active} loading={loading} onOpen={openActive} />}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loading} onOpen={openHistory} />}
    </div>
  );
}
VEDA_EOF_MARKER

echo "Files written. Run: npm run build   (then git add/commit/push)"