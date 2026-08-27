'use client';

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import { searchPatients } from '../patient-timeline/actions';
import { getOpdProcedureLists, getCombinedSchedule, getOpdProcedureHistory } from './actions';

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function daysAgo(dateStr) {
  const diff = Date.now() - new Date(dateStr).getTime();
  const days = Math.floor(diff / (1000 * 60 * 60 * 24));
  if (days <= 0) return 'today';
  if (days === 1) return '1 day ago';
  return `${days} days ago`;
}

function CaseRow({ c, color, onOpen }) {
  return (
    <div onClick={() => onOpen(c.patient.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
      <div style={{ width: 34, height: 34, borderRadius: '50%', background: color, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
        {c.patient.first_name?.charAt(0)}
      </div>
      <div style={{ flex: 1 }}>
        <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(c.patient)}</span>
        {color === 'var(--amber)' && <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>Advised {daysAgo(c.created_at)}</span>}
        {c.status === 'Scheduled' && <span className="badge b-blue" style={{ marginLeft: 6, fontSize: 10 }}>Date booked, unpaid</span>}
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
          {c.patient.uhid} -- {c.name} {c.eye ? `(${c.eye})` : ''}{c.scheduled_date ? ` -- ${fmtDate(c.scheduled_date)}` : ''}
        </div>
      </div>
      <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
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
              <span style={{ fontSize: 13, flex: 1 }}><strong>{formatPatientName(e.patient)}</strong> -- {e.name} {e.eye ? `(${e.eye})` : ''}</span>
              <span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.status}</span>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

function HistoryView({ rows, loading, onOpen, onClose }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((c) => {
        const q = search.trim().toLowerCase();
        return `${formatPatientName(c.patient)}`.toLowerCase().includes(q) || (c.patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title" style={{ margin: 0 }}><i className="ti ti-history" style={{ color: 'var(--green)' }}></i> OPD Procedures History <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span></div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
          <button className="btn" onClick={onClose}><i className="ti ti-x"></i> Close</button>
        </div>
      </div>

      <div className="card">
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && filtered.length === 0 && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No completed, done, or cancelled procedures yet.</div>}
        {!loading && filtered.map((c) => (
          <div key={c.id} onClick={() => onOpen(c.patient.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: c.status === 'Cancelled' ? 'var(--g400)' : 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {c.patient?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(c.patient)}</span>
              <span className={`badge ${c.status === 'Cancelled' ? 'b-gray' : 'b-green'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status === 'Done' ? 'Completed (same day)' : c.status}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {c.patient?.uhid} -- {c.name} {c.eye ? `(${c.eye})` : ''}{c.completed_at ? ` -- ${fmtDate(c.completed_at.slice(0, 10))}` : ''}
              </div>
            </div>
            <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── OPD Procedures "All Cases" landing -- patient-first search up
// top, plus the same Active Cases / Awaiting Confirmation / Completed
// Today classification Surgical Journey uses: Awaiting Confirmation is
// no-advance-paid-yet regardless of decision or booking status (the
// list worth chasing), Active Cases is everyone with money down,
// Completed Today is self-explanatory. Selecting any patient (search
// result or a case row) navigates to their own dedicated workspace
// route (/opd-procedures/[patientId]), same pattern as Surgical
// Journey's per-case workspace.
export default function OpdProceduresPage() {
  const router = useRouter();
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [lists, setLists] = useState({ active: [], awaitingConfirmation: [], completedToday: [] });
  const [loading, setLoading] = useState(true);
  const [showCalendar, setShowCalendar] = useState(false);
  const [calendarRows, setCalendarRows] = useState([]);
  const [calendarLoading, setCalendarLoading] = useState(true);
  const [showHistory, setShowHistory] = useState(false);
  const [historyRows, setHistoryRows] = useState([]);
  const [historyLoading, setHistoryLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLists(await getOpdProcedureLists());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  useEffect(() => {
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => setResults(await searchPatients(q)), 300);
    return () => clearTimeout(t);
  }, [query]);

  function openCalendar() {
    setShowCalendar(true);
    setCalendarLoading(true);
    getCombinedSchedule().then((rows) => { setCalendarRows(rows); setCalendarLoading(false); });
  }

  function openHistory() {
    setShowHistory(true);
    setHistoryLoading(true);
    getOpdProcedureHistory().then((rows) => { setHistoryRows(rows); setHistoryLoading(false); });
  }

  function openPatient(patientId) {
    router.push(`/opd-procedures/${patientId}`);
  }

  if (showCalendar) return <CalendarView rows={calendarRows} loading={calendarLoading} onClose={() => setShowCalendar(false)} />;
  if (showHistory) return <HistoryView rows={historyRows} loading={historyLoading} onOpen={openPatient} onClose={() => setShowHistory(false)} />;

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title" style={{ margin: 0 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> OPD Procedures</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn" style={{ fontSize: 12 }} onClick={openHistory}><i className="ti ti-history"></i> History</button>
            <button className="btn" style={{ fontSize: 12 }} onClick={openCalendar}><i className="ti ti-calendar"></i> Procedure &amp; OT Calendar</button>
          </div>
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
                  <strong>{formatPatientName(p)}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {lists.awaitingConfirmation.length > 0 && (
        <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-clock-pause" style={{ color: 'var(--amber)' }}></i> Awaiting Confirmation
            <span className="badge b-amber" style={{ marginLeft: 8 }}>{lists.awaitingConfirmation.length}</span>
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            No advance paid yet -- not confirmed even if a date's already been booked. Worth a call if it's been a while.
          </div>
          {lists.awaitingConfirmation.map((c) => <CaseRow key={c.id} c={c} color="var(--amber)" onOpen={openPatient} />)}
        </div>
      )}

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Active Cases
          <span className="badge b-gray" style={{ marginLeft: 8 }}>{lists.active.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && lists.active.map((c) => <CaseRow key={c.id} c={c} color="var(--indigo)" onOpen={openPatient} />)}
        {!loading && lists.active.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No active OPD Procedure cases right now.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today
          <span className="badge b-green" style={{ marginLeft: 8 }}>{lists.completedToday.length}</span>
        </div>
        {!loading && lists.completedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nobody completed yet today.</div>
        )}
        {!loading && lists.completedToday.map((c) => <CaseRow key={c.id} c={c} color="var(--green)" onOpen={openPatient} />)}
      </div>
    </div>
  );
}
