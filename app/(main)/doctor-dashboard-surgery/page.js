'use client';

import { useState, useEffect, useCallback } from 'react';
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

function TabButton({ active, onClick, icon, label, count }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
      {typeof count === 'number' && <span className="badge b-gray" style={{ marginLeft: 6 }}>{count}</span>}
    </button>
  );
}

function StageBadge({ stage }) {
  const colors = {
    'Scheduled': 'var(--amber)',
    'Checked-In / In OT': 'var(--blue)',
    'In Recovery': 'var(--purple)',
    'Discharged': 'var(--green)',
  };
  const c = colors[stage] || 'var(--g400)';
  return <span className="badge" style={{ background: `${c}20`, color: c }}>{stage}</span>;
}

function CaseRow({ sc, booking, rightLabel, dateLabel, dateValue, stage, onClick }) {
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

function ScheduledTab({ rows, loading, onOpen }) {
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-event" style={{ color: 'var(--amber)' }}></i> Upcoming Scheduled Surgeries</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <table className="tbl">
          <thead><tr><th>Surgery ID</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>OT Date</th><th>Stage</th><th></th></tr></thead>
          <tbody>
            {rows.map((b) => (
              <CaseRow key={b.id} sc={b.surgical_cases} stage="Scheduled" dateLabel="OT Date" dateValue={b.scheduled_date} onClick={() => onOpen(b)} />
            ))}
            {rows.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No upcoming scheduled surgeries.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

function ActiveTab({ rows, loading, onOpen }) {
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--blue)' }}></i> Patients on the Surgical Journey Today</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <table className="tbl">
          <thead><tr><th>Surgery ID</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>OT Date</th><th>Stage</th><th></th></tr></thead>
          <tbody>
            {rows.map((b) => (
              <CaseRow key={b.id} sc={b.surgical_cases} stage={b.stage} dateLabel="OT Date" dateValue={b.scheduled_date} onClick={() => onOpen(b)} />
            ))}
            {rows.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No cases currently checked in, in OT, or in recovery.</td></tr>}
          </tbody>
        </table>
      )}
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
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--green)' }}></i> Completed Surgeries</div>
        <input className="input" style={{ maxWidth: 240, fontSize: 12 }} placeholder="Search patient, UHID, surgery ID..." value={search} onChange={(e) => setSearch(e.target.value)} />
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
  const [activeTab, setActiveTab] = useState('scheduled');
  const [scheduled, setScheduled] = useState([]);
  const [active, setActive] = useState([]);
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const [s, a, h] = await Promise.all([getSurgeryDashboardScheduled(), getSurgeryDashboardActive(), getSurgeryDashboardHistory()]);
    setScheduled(s); setActive(a); setHistory(h);
    setLoading(false);
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

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 560, flex: 1 }}>
          <TabButton active={activeTab === 'scheduled'} onClick={() => setActiveTab('scheduled')} icon="ti-calendar-event" label="Scheduled" count={scheduled.length} />
          <TabButton active={activeTab === 'active'} onClick={() => setActiveTab('active')} icon="ti-building-hospital" label="Active" count={active.length} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" count={history.length} />
        </div>
        <button className="btn btn-sm" style={{ marginLeft: 16 }} onClick={() => router.push('/doctor-dashboard')}>
          <i className="ti ti-stethoscope"></i> OPD Dashboard
        </button>
      </div>

      {activeTab === 'scheduled' && <ScheduledTab rows={scheduled} loading={loading} onOpen={openScheduled} />}
      {activeTab === 'active' && <ActiveTab rows={active} loading={loading} onOpen={openActive} />}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loading} onOpen={openHistory} />}
    </div>
  );
}
