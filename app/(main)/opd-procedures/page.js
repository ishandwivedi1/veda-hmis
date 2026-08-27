'use client';

import { useState, useEffect, useCallback } from 'react';
import { TabButton } from '../ot-intraop/page';
import {
  getOpdProcedureLists,
  getCombinedSchedule,
  setOpdProcedureDecision,
  scheduleOpdProcedure,
  checkInOpdProcedure,
  completeOpdProcedure,
  cancelOpdProcedure,
} from './actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function CaseRow({ c, onOpen, selected }) {
  return (
    <tr onClick={() => onOpen(c.id)} style={{ cursor: 'pointer', background: selected ? 'var(--g100)' : undefined }}>
      <td><strong>{c.patient.first_name} {c.patient.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{c.patient.uhid}</span></td>
      <td style={{ fontSize: 12 }}>{c.name} {c.eye ? `(${c.eye})` : ''}</td>
      <td style={{ fontSize: 12 }}>{fmtDate(c.scheduled_date)}{c.scheduled_time ? ` -- ${c.scheduled_time.slice(0, 5)}` : ''}</td>
      <td style={{ fontSize: 11 }}>
        {c.decision && <span style={{ color: c.decision === 'Accepted' ? 'var(--green)' : 'var(--amber)' }}>{c.decision}</span>}
        {c.status === 'Scheduled' && <div style={{ color: c.advanceBalance > 0 ? 'var(--green)' : 'var(--red)', marginTop: 2 }}>{c.advanceBalance > 0 ? 'Advance paid' : 'Advance pending'}</div>}
      </td>
      <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
    </tr>
  );
}

function ListTable({ rows, onOpen, selectedId, emptyLabel }) {
  return (
    <table className="tbl">
      <thead><tr><th>Patient</th><th>Procedure</th><th>Date</th><th>Status</th><th></th></tr></thead>
      <tbody>
        {rows.map((c) => <CaseRow key={c.id} c={c} onOpen={onOpen} selected={c.id === selectedId} />)}
        {rows.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>{emptyLabel}</td></tr>}
      </tbody>
    </table>
  );
}

function DecisionPanel({ c, onSave, busy }) {
  const [decision, setDecision] = useState(c.decision || '');
  const [reason, setReason] = useState('');
  const needsReason = c.decision_locked && decision && decision !== c.decision;

  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8, color: 'var(--g500)' }}>PATIENT DECISION</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 10 }}>
        {DECISIONS.map((d) => (
          <button key={d} type="button" className="btn" style={{ fontSize: 12, background: decision === d ? 'var(--red)' : undefined, color: decision === d ? '#fff' : undefined }} onClick={() => setDecision(d)}>{d}</button>
        ))}
      </div>
      {needsReason && (
        <input className="fi fi-sm" placeholder="Reason for changing a locked decision" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: '100%', marginBottom: 10 }} />
      )}
      <button className="btn btn-primary" disabled={!decision || busy} onClick={() => onSave(decision, reason)}>Save Decision</button>
    </div>
  );
}

function SchedulePanel({ c, onSave, onCancel, busy }) {
  const [date, setDate] = useState(c.scheduled_date || '');
  const [time, setTime] = useState(c.scheduled_time ? c.scheduled_time.slice(0, 5) : '');
  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8, color: 'var(--g500)' }}>PROCEDURE DATE</div>
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

function CheckinPanel({ c, onCheckIn, onCancel, busy }) {
  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8, color: 'var(--g500)' }}>CHECK-IN</div>
      <div style={{ fontSize: 13, marginBottom: 10 }}>
        Scheduled for <strong>{fmtDate(c.scheduled_date)}</strong>{c.scheduled_time ? ` at ${c.scheduled_time.slice(0, 5)}` : ''}.<br />
        Advance balance: <strong style={{ color: c.advanceBalance > 0 ? 'var(--green)' : 'var(--red)' }}>Rs. {c.advanceBalance.toLocaleString('en-IN')}</strong>
        {c.advanceBalance <= 0 && <div style={{ color: 'var(--red)', marginTop: 4, fontSize: 12 }}>Collect the advance in Payments before check-in.</div>}
      </div>
      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" disabled={busy} onClick={onCheckIn}>Check In</button>
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
      <div style={{ fontSize: 12, fontWeight: 600, marginBottom: 8, color: 'var(--g500)' }}>POST-PROCEDURE NOTES</div>
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
  return (
    <div style={{ fontSize: 13, lineHeight: 1.7 }}>
      <div><strong>Procedure Performed:</strong> {c.procedure_performed || '--'}</div>
      <div><strong>Findings:</strong> {c.findings || '--'}</div>
      <div><strong>Instructions:</strong> {c.post_procedure_instructions || '--'}</div>
      <div style={{ color: 'var(--g400)', fontSize: 11, marginTop: 6 }}>Completed {c.completed_at ? new Date(c.completed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : ''}</div>
    </div>
  );
}

function CalendarTab({ rows, loading }) {
  const grouped = {};
  rows.forEach((r) => { (grouped[r.date] = grouped[r.date] || []).push(r); });
  const dates = Object.keys(grouped).sort();

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>;
  if (dates.length === 0) return <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing scheduled.</div>;

  return (
    <div>
      {dates.map((date) => (
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

export default function OpdProceduresPage() {
  const [activeTab, setActiveTab] = useState('decision');
  const [lists, setLists] = useState({ awaitingDecision: [], scheduled: [], checkedIn: [], completedToday: [], followUp: [] });
  const [calendar, setCalendar] = useState([]);
  const [loading, setLoading] = useState(true);
  const [calLoading, setCalLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [rescheduling, setRescheduling] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setLists(await getOpdProcedureLists());
    setLoading(false);
  }, []);

  const refreshCalendar = useCallback(async () => {
    setCalLoading(true);
    setCalendar(await getCombinedSchedule());
    setCalLoading(false);
  }, []);

  useEffect(() => { refresh(); refreshCalendar(); }, [refresh, refreshCalendar]);
  useEffect(() => { setRescheduling(false); setError(''); }, [selectedId]);

  const allCases = [...lists.awaitingDecision, ...lists.scheduled, ...lists.checkedIn, ...lists.completedToday, ...lists.followUp];
  const selected = allCases.find((c) => c.id === selectedId);

  async function run(fn, ...args) {
    setBusy(true);
    setError('');
    const result = await fn(...args);
    setBusy(false);
    if (result?.error) { setError(result.error); return; }
    setSelectedId(null);
    refresh();
    refreshCalendar();
  }

  const tabs = [
    { key: 'decision', label: 'Awaiting Decision', icon: 'ti-help-circle', rows: lists.awaitingDecision },
    { key: 'followup', label: 'Follow Up', icon: 'ti-clock', rows: lists.followUp },
    { key: 'scheduled', label: 'Scheduled', icon: 'ti-calendar-event', rows: lists.scheduled },
    { key: 'checkedin', label: 'Checked In', icon: 'ti-clipboard-check', rows: lists.checkedIn },
    { key: 'completed', label: 'Completed Today', icon: 'ti-circle-check', rows: lists.completedToday },
  ];

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, flexWrap: 'wrap' }}>
        {tabs.map((t) => (
          <TabButton key={t.key} active={activeTab === t.key} onClick={() => { setActiveTab(t.key); setSelectedId(null); }} icon={t.icon} label={`${t.label} (${t.rows.length})`} />
        ))}
        <TabButton active={activeTab === 'calendar'} onClick={() => { setActiveTab('calendar'); setSelectedId(null); }} icon="ti-calendar" label="Calendar" />
      </div>

      {activeTab === 'calendar' ? (
        <CalendarTab rows={calendar} loading={calLoading} />
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: selected ? '1.3fr 1fr' : '1fr', gap: 16 }}>
          <div className="card">
            {loading ? (
              <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>
            ) : (
              <ListTable rows={tabs.find((t) => t.key === activeTab).rows} onOpen={setSelectedId} selectedId={selectedId} emptyLabel="Nothing here right now." />
            )}
          </div>

          {selected && (
            <div className="card">
              <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 10 }}>
                <div>
                  <strong>{selected.patient.first_name} {selected.patient.last_name}</strong>
                  <div style={{ fontSize: 11, color: 'var(--g400)' }}>{selected.patient.uhid} -- {selected.name} {selected.eye ? `(${selected.eye})` : ''}</div>
                </div>
                <button className="btn" style={{ fontSize: 11 }} onClick={() => setSelectedId(null)}><i className="ti ti-x"></i></button>
              </div>

              {error && <div style={{ color: 'var(--red)', fontSize: 12, marginBottom: 10 }}>{error}</div>}

              {!selected.decision && selected.status === 'Planned' && (
                <DecisionPanel c={selected} busy={busy} onSave={(decision, reason) => run(setOpdProcedureDecision, selected.id, decision, reason)} />
              )}
              {selected.decision && selected.decision !== 'Accepted' && selected.decision !== 'Declined' && selected.status === 'Planned' && (
                <DecisionPanel c={selected} busy={busy} onSave={(decision, reason) => run(setOpdProcedureDecision, selected.id, decision, reason)} />
              )}
              {selected.decision === 'Accepted' && selected.status === 'Planned' && (
                <SchedulePanel
                  c={selected}
                  busy={busy}
                  onSave={(date, time) => run(scheduleOpdProcedure, selected.id, date, time)}
                  onCancel={() => run(cancelOpdProcedure, selected.id, 'Cancelled from OPD Procedures workspace')}
                />
              )}
              {selected.status === 'Scheduled' && !rescheduling && (
                <div>
                  <CheckinPanel
                    c={selected}
                    busy={busy}
                    onCheckIn={() => run(checkInOpdProcedure, selected.id)}
                    onCancel={() => run(cancelOpdProcedure, selected.id, 'Cancelled from OPD Procedures workspace')}
                  />
                  <button className="btn" style={{ fontSize: 11, marginTop: 10 }} onClick={() => setRescheduling(true)}><i className="ti ti-calendar-time"></i> Change Date</button>
                </div>
              )}
              {selected.status === 'Scheduled' && rescheduling && (
                <SchedulePanel
                  c={selected}
                  busy={busy}
                  onSave={(date, time) => { setRescheduling(false); run(scheduleOpdProcedure, selected.id, date, time); }}
                  onCancel={() => run(cancelOpdProcedure, selected.id, 'Cancelled from OPD Procedures workspace')}
                />
              )}
              {selected.status === 'Checked In' && (
                <CompletePanel c={selected} busy={busy} onSave={(fields) => run(completeOpdProcedure, selected.id, fields)} />
              )}
              {selected.status === 'Completed' && <CompletedSummary c={selected} />}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
