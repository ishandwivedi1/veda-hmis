'use client';

import { Suspense, useState, useEffect, useCallback, useRef } from 'react';
import { searchPatients } from '../patient-timeline/actions';
import {
  getPatientOpdProcedureJourney,
  getTodayOpdProcedurePatients,
  getCombinedSchedule,
  setOpdProcedureDecision,
  scheduleOpdProcedure,
  checkInOpdProcedure,
  completeOpdProcedure,
  cancelOpdProcedure,
} from './actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

const STAGE = {
  AwaitingDecision: { label: 'Awaiting Decision', color: 'var(--amber)' },
  FollowUp: { label: 'Follow Up', color: 'var(--amber)' },
  Scheduled: { label: 'Scheduled', color: 'var(--blue)' },
  'Checked In': { label: 'Checked In', color: 'var(--indigo)' },
  Completed: { label: 'Completed', color: 'var(--green)' },
  Done: { label: 'Completed (same day)', color: 'var(--green)' },
  Cancelled: { label: 'Cancelled', color: 'var(--g400)' },
  Declined: { label: 'Declined', color: 'var(--g400)' },
};

function stageFor(p) {
  if (p.status === 'Cancelled') return STAGE.Cancelled;
  if (p.decision === 'Declined') return STAGE.Declined;
  if (p.status === 'Completed') return STAGE.Completed;
  if (p.status === 'Done') return STAGE.Done;
  if (p.status === 'Checked In') return STAGE['Checked In'];
  if (p.status === 'Scheduled') return STAGE.Scheduled;
  if (p.decision && p.decision !== 'Accepted') return STAGE.FollowUp;
  return STAGE.AwaitingDecision;
}

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function StageBadge({ p }) {
  const s = stageFor(p);
  return <span className="badge" style={{ background: `${s.color}20`, color: s.color, fontWeight: 600 }}>{s.label}</span>;
}

function DecisionPanel({ c, onSave, busy }) {
  const [decision, setDecision] = useState(c.decision || '');
  const [reason, setReason] = useState('');
  const needsReason = c.decision_locked && decision && decision !== c.decision;
  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 700, marginBottom: 8, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>Patient Decision</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 10 }}>
        {DECISIONS.map((d) => (
          <button key={d} type="button" className="btn" style={{ fontSize: 12, background: decision === d ? 'var(--red)' : undefined, color: decision === d ? '#fff' : undefined }} onClick={() => setDecision(d)}>{d}</button>
        ))}
      </div>
      {needsReason && <input className="fi fi-sm" placeholder="Reason for changing a locked decision" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: '100%', marginBottom: 10 }} />}
      <button className="btn btn-primary" disabled={!decision || busy} onClick={() => onSave(decision, reason)}>Save Decision</button>
    </div>
  );
}

function SchedulePanel({ c, onSave, onCancel, busy }) {
  const [date, setDate] = useState(c.scheduled_date || '');
  const [time, setTime] = useState(c.scheduled_time ? c.scheduled_time.slice(0, 5) : '');
  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 700, marginBottom: 8, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>Procedure Date</div>
      <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
        <input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} />
        <input type="time" className="fi fi-sm" value={time} onChange={(e) => setTime(e.target.value)} />
      </div>
      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" disabled={!date || busy} onClick={() => onSave(date, time)}>{c.status === 'Scheduled' ? 'Update Date' : 'Confirm Schedule'}</button>
        {c.status === 'Scheduled' && <button className="btn" style={{ color: 'var(--red)' }} disabled={busy} onClick={onCancel}>Cancel Procedure</button>}
      </div>
    </div>
  );
}

function CheckinPanel({ c, onCheckIn, onCancel, onReschedule, busy }) {
  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 700, marginBottom: 8, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>Check-In</div>
      <div style={{ fontSize: 13, marginBottom: 10 }}>
        Scheduled for <strong>{fmtDate(c.scheduled_date)}</strong>{c.scheduled_time ? ` at ${c.scheduled_time.slice(0, 5)}` : ''}.<br />
        Advance balance: <strong style={{ color: c.advanceBalance > 0 ? 'var(--green)' : 'var(--red)' }}>Rs. {c.advanceBalance.toLocaleString('en-IN')}</strong>
        {c.advanceBalance <= 0 && <div style={{ color: 'var(--red)', marginTop: 4, fontSize: 12 }}>Collect the advance in Payments before check-in.</div>}
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn btn-primary" disabled={busy} onClick={onCheckIn}>Check In</button>
        <button className="btn" style={{ fontSize: 12 }} disabled={busy} onClick={onReschedule}><i className="ti ti-calendar-time"></i> Change Date</button>
        <button className="btn" style={{ color: 'var(--red)' }} disabled={busy} onClick={onCancel}>Cancel Procedure</button>
      </div>
    </div>
  );
}

function CompletePanel({ c, onSave, busy }) {
  const [procedurePerformed, setProcedurePerformed] = useState(c.procedure_performed || c.name || '');
  const [findings, setFindings] = useState(c.findings || '');
  const [instructions, setInstructions] = useState(c.post_procedure_instructions || '');
  return (
    <div>
      <div style={{ fontSize: 11, fontWeight: 700, marginBottom: 8, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>Post-Procedure Notes</div>
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Procedure Performed</label>
      <input className="fi fi-sm" value={procedurePerformed} onChange={(e) => setProcedurePerformed(e.target.value)} style={{ width: '100%', marginBottom: 8 }} />
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Findings</label>
      <textarea className="fi fi-sm" value={findings} onChange={(e) => setFindings(e.target.value)} style={{ width: '100%', marginBottom: 8, minHeight: 60 }} />
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Post-Procedure Instructions</label>
      <textarea className="fi fi-sm" value={instructions} onChange={(e) => setInstructions(e.target.value)} style={{ width: '100%', marginBottom: 10, minHeight: 60 }} />
      <button className="btn btn-primary" disabled={busy} onClick={() => onSave({ procedurePerformed, findings, instructions })}>Mark Completed</button>
    </div>
  );
}

function CompletedSummary({ c }) {
  if (c.status !== 'Completed') return null;
  return (
    <div style={{ fontSize: 13, lineHeight: 1.7, background: 'var(--g50)', borderRadius: 8, padding: 12 }}>
      <div><strong>Procedure Performed:</strong> {c.procedure_performed || '--'}</div>
      <div><strong>Findings:</strong> {c.findings || '--'}</div>
      <div><strong>Instructions:</strong> {c.post_procedure_instructions || '--'}</div>
      <div style={{ color: 'var(--g400)', fontSize: 11, marginTop: 6 }}>Completed {c.completed_at ? new Date(c.completed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : ''}</div>
    </div>
  );
}

function JourneyCard({ p, expanded, onToggle, onAction, busy, error }) {
  const s = stageFor(p);
  const isTerminal = p.status === 'Completed' || p.status === 'Done' || p.status === 'Cancelled' || p.decision === 'Declined';

  return (
    <div className="card" style={{ marginBottom: 12, borderLeft: `3px solid ${s.color}` }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', cursor: 'pointer' }} onClick={onToggle}>
        <div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>{p.name} {p.eye ? `(${p.eye})` : ''}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>
            Advised {fmtDate(p.created_at?.slice(0, 10))}
            {p.scheduled_date ? ` -- procedure date ${fmtDate(p.scheduled_date)}` : ''}
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <StageBadge p={p} />
          <i className={`ti ${expanded ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>

      {expanded && (
        <div style={{ marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--g100)' }}>
          {error && <div style={{ color: 'var(--red)', fontSize: 12, marginBottom: 10 }}>{error}</div>}
          {p.notes && <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}><strong>Doctor&apos;s note:</strong> {p.notes}</div>}

          {isTerminal ? (
            p.status === 'Completed' ? <CompletedSummary c={p} /> : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>
                {p.status === 'Cancelled' && 'This procedure was cancelled.'}
                {p.decision === 'Declined' && p.status !== 'Cancelled' && `Patient declined${p.decision_reason ? ` -- ${p.decision_reason}` : ''}.`}
                {p.status === 'Done' && 'Performed same-sitting and billed -- no further workflow needed.'}
              </div>
            )
          ) : (
            <>
              {(!p.decision || (p.decision !== 'Accepted' && p.decision !== 'Declined' && p.status === 'Planned')) && (
                <DecisionPanel c={p} busy={busy} onSave={(decision, reason) => onAction('decision', p, decision, reason)} />
              )}
              {p.decision === 'Accepted' && p.status === 'Planned' && (
                <SchedulePanel c={p} busy={busy} onSave={(date, time) => onAction('schedule', p, date, time)} onCancel={() => onAction('cancel', p)} />
              )}
              {p.status === 'Scheduled' && (
                p._rescheduling
                  ? <SchedulePanel c={p} busy={busy} onSave={(date, time) => onAction('schedule', p, date, time)} onCancel={() => onAction('cancel', p)} />
                  : <CheckinPanel c={p} busy={busy} onCheckIn={() => onAction('checkin', p)} onCancel={() => onAction('cancel', p)} onReschedule={() => onAction('toggleReschedule', p)} />
              )}
              {p.status === 'Checked In' && (
                <CompletePanel c={p} busy={busy} onSave={(fields) => onAction('complete', p, fields)} />
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function PatientHeader({ patient }) {
  return (
    <div className="card" style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 16, padding: '14px 18px' }}>
      <div style={{ width: 44, height: 44, borderRadius: '50%', background: 'var(--red-lt, #fee2e2)', color: 'var(--red)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 16, flexShrink: 0 }}>
        {patient.first_name?.[0]}{patient.last_name?.[0]}
      </div>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>{patient.uhid} -- {patient.age ? `${patient.age} yrs` : ''} {patient.gender} -- {patient.mobile}</div>
      </div>
    </div>
  );
}

function TodayShortcuts({ groups, loading, onSelect }) {
  if (loading || groups.length === 0) return null;
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 10 }}>Today&apos;s OPD Procedure Patients</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8 }}>
        {groups.map((g) => (
          <button key={g.patient.id} type="button" className="btn" style={{ fontSize: 12, textAlign: 'left' }} onClick={() => onSelect(g.patient)}>
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

function OpdProceduresInner() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [journey, setJourney] = useState([]);
  const [loading, setLoading] = useState(false);
  const [expandedId, setExpandedId] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [rowError, setRowError] = useState({});
  const [reschedulingId, setReschedulingId] = useState(null);
  const [todayGroups, setTodayGroups] = useState([]);
  const [todayLoading, setTodayLoading] = useState(true);
  const [showCalendar, setShowCalendar] = useState(false);
  const [calendarRows, setCalendarRows] = useState([]);
  const [calendarLoading, setCalendarLoading] = useState(true);
  const skipNextSearch = useRef(false);

  useEffect(() => {
    if (skipNextSearch.current) { skipNextSearch.current = false; return; }
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => setResults(await searchPatients(q)), 300);
    return () => clearTimeout(t);
  }, [query]);

  useEffect(() => {
    (async () => { setTodayGroups(await getTodayOpdProcedurePatients()); setTodayLoading(false); })();
  }, []);

  const loadPatientJourney = useCallback(async (p) => {
    setLoading(true);
    setResults([]);
    setPatient(p);
    setExpandedId(null);
    const data = await getPatientOpdProcedureJourney(p.id);
    const priority = data.find((x) => !['Completed', 'Done', 'Cancelled'].includes(x.status) && x.decision !== 'Declined');
    setExpandedId(priority?.id || data[0]?.id || null);
    setJourney(data);
    setLoading(false);
    skipNextSearch.current = true;
    setQuery(`${p.first_name} ${p.last_name} -- ${p.uhid}`);
  }, []);

  function openCalendar() {
    setShowCalendar(true);
    setCalendarLoading(true);
    getCombinedSchedule().then((rows) => { setCalendarRows(rows); setCalendarLoading(false); });
  }

  async function refreshJourney() {
    if (!patient) return;
    const data = await getPatientOpdProcedureJourney(patient.id);
    setJourney(data);
  }

  async function handleAction(type, p, ...args) {
    setRowError((e) => ({ ...e, [p.id]: '' }));
    if (type === 'toggleReschedule') {
      setReschedulingId((cur) => (cur === p.id ? null : p.id));
      return;
    }
    setBusyId(p.id);
    let result;
    if (type === 'decision') result = await setOpdProcedureDecision(p.id, args[0], args[1]);
    if (type === 'schedule') { result = await scheduleOpdProcedure(p.id, args[0], args[1]); setReschedulingId(null); }
    if (type === 'checkin') result = await checkInOpdProcedure(p.id);
    if (type === 'complete') result = await completeOpdProcedure(p.id, args[0]);
    if (type === 'cancel') result = await cancelOpdProcedure(p.id, 'Cancelled from patient journey view');
    setBusyId(null);
    if (result?.error) { setRowError((e) => ({ ...e, [p.id]: result.error })); return; }
    refreshJourney();
    getTodayOpdProcedurePatients().then(setTodayGroups);
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
                  onClick={() => loadPatientJourney(p)}
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

      {!patient && <TodayShortcuts groups={todayGroups} loading={todayLoading} onSelect={loadPatientJourney} />}

      {loading && <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading patient journey...</div>}

      {!loading && patient && (
        <div>
          <PatientHeader patient={patient} />
          {journey.length === 0 && (
            <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No OPD Procedures on file for this patient yet.</div>
          )}
          {journey.map((p) => (
            <JourneyCard
              key={p.id}
              p={{ ...p, _rescheduling: reschedulingId === p.id }}
              expanded={expandedId === p.id}
              onToggle={() => setExpandedId((cur) => (cur === p.id ? null : p.id))}
              onAction={handleAction}
              busy={busyId === p.id}
              error={rowError[p.id]}
            />
          ))}
        </div>
      )}

      {!loading && !patient && (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
          Search for a patient above to view their OPD Procedure journey, or pick one of today&apos;s shortcuts.
        </div>
      )}
    </div>
  );
}

export default function OpdProceduresPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <OpdProceduresInner />
    </Suspense>
  );
}
