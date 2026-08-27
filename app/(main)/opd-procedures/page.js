'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatients } from '../patient-timeline/actions';
import { getTodayOpdProcedurePatients, getCombinedSchedule } from './actions';

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function TodayShortcuts({ groups, loading, onSelect }) {
  if (loading || groups.length === 0) return null;
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 10 }}>Today&apos;s OPD Procedure Patients</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {groups.map((g) => (
          <button key={g.patient.id} type="button" className="btn" style={{ fontSize: 12, textAlign: 'left' }} onClick={() => onSelect(g.patient.id)}>
            <strong>{g.patient.first_name} {g.patient.last_name}</strong>
            <span style={{ color: 'var(--g400)', marginLeft: 6 }}>{g.patient.uhid}</span>
            <span style={{ marginLeft: 8, color: 'var(--g500)' }}>{g.items.map((i) => i.status).join(', ')}</span>
          </button>
        ))}
      </div>
    </div>
  );
}

function CalendarView({ rows, loading, onClose }) {
  const grouped = {};
  rows.forEach((r) => { (grouped[r.date] = grouped[r.date] || []).push(r); });
  const dates = Object.keys(grouped).sort();

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
        <div className="card-title" style={{ margin: 0 }}><i className="ti ti-calendar" style={{ color: 'var(--blue)' }}></i> Combined OPD Procedure &amp; OT Calendar</div>
        <button className="btn" onClick={onClose}><i className="ti ti-x"></i> Close</button>
      </div>
      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
      {!loading && dates.length === 0 && <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing scheduled.</div>}
      {!loading && dates.map((date) => (
        <div key={date} className="card" style={{ marginBottom: 10 }}>
          <div style={{ fontWeight: 700, fontSize: 13, marginBottom: 8 }}>{fmtDate(date)}</div>
          {grouped[date].map((e) => (
            <div key={`${e.kind}-${e.id}`} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '6px 0', borderTop: '1px solid var(--g100)' }}>
              <span style={{ fontSize: 10, fontWeight: 700, padding: '2px 8px', borderRadius: 10, color: '#fff', background: e.kind === 'Surgery' ? 'var(--blue)' : 'var(--teal, #0d9488)' }}>{e.kind}</span>
              <span style={{ fontSize: 12, width: 60, color: 'var(--g500)' }}>{e.time ? e.time.slice(0, 5) : '--'}</span>
              <span style={{ fontSize: 13, flex: 1 }}><strong>{e.patient?.first_name} {e.patient?.last_name}</strong> -- {e.name} {e.eye ? `(${e.eye})` : ''}</span>
              <span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.status}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

// ── OPD Procedures "All Cases" landing -- patient-first entry point.
// Selecting a patient (search result or a today's shortcut) navigates
// to their own dedicated workspace route (/opd-procedures/[patientId]),
// the same pattern Surgical Journey uses for its per-case workspace --
// a real page, openable in a new tab, with its own "All Cases" back link.
export default function OpdProceduresPage() {
  const router = useRouter();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [todayGroups, setTodayGroups] = useState([]);
  const [todayLoading, setTodayLoading] = useState(true);
  const [showCalendar, setShowCalendar] = useState(false);
  const [calendarRows, setCalendarRows] = useState([]);
  const [calendarLoading, setCalendarLoading] = useState(true);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => setResults(await searchPatients(q)), 300);
    return () => clearTimeout(t);
  }, [query]);

  useEffect(() => {
    (async () => { setTodayGroups(await getTodayOpdProcedurePatients()); setTodayLoading(false); })();
  }, []);

  function openCalendar() {
    setShowCalendar(true);
    setCalendarLoading(true);
    getCombinedSchedule().then((rows) => { setCalendarRows(rows); setCalendarLoading(false); });
  }

  function openPatient(patientId) {
    router.push(`/opd-procedures/${patientId}`);
  }

  if (showCalendar) return <CalendarView rows={calendarRows} loading={calendarLoading} onClose={() => setShowCalendar(false)} />;

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title" style={{ margin: 0 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> OPD Procedures</div>
          <button className="btn" style={{ fontSize: 12 }} onClick={openCalendar}><i className="ti ti-calendar"></i> Procedure &amp; OT Calendar</button>
        </div>
        <div style={{ position: 'relative' }}>
          <input className="fi" placeholder="Search patient by name or UHID to view their OPD Procedure journey..." value={query} onChange={(e) => setQuery(e.target.value)} />
          {results.length > 0 && (
            <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, zIndex: 10, boxShadow: '0 4px 16px rgba(0,0,0,.1)' }}>
              {results.map((p) => (
                <div
                  key={p.id}
                  onClick={() => openPatient(p.id)}
                  style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 13, borderBottom: '1px solid var(--g100)' }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g50)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = '#fff')}
                >
                  <strong>{p.first_name} {p.last_name}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <TodayShortcuts groups={todayGroups} loading={todayLoading} onSelect={openPatient} />

      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
        Search for a patient above to open their OPD Procedure journey, or pick one of today&apos;s shortcuts.
      </div>
    </div>
  );
}
