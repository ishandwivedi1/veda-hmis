'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { getScheduledOT, getOTHistory, getOTAvailability, rescheduleOTSlot, completeOT, undoCompleteOT } from './actions';

const STATUS_BADGE = { Scheduled: 'b-blue', 'In Progress': 'b-amber', Completed: 'b-green', Cancelled: 'b-red' };

function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function RescheduleForm({ booking, onDone }) {
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [reason, setReason] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!date) { setError('Pick a new date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setSaving(true);
    const result = await rescheduleOTSlot(booking.id, date, sessionId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div style={{ padding: '10px 0', borderTop: '1px dashed var(--g200)' }}>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
        <div>
          <label className="flbl">New Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">Reason (optional)</label>
          <input className="fi fi-sm" placeholder="e.g. Patient requested, surgeon unavailable..." value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
      </div>

      {date && (
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      borderColor: selected ? 'transparent' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}
                    </div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      <div style={{ display: 'flex', gap: 6 }}>
        <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Saving...' : 'Confirm Reschedule'}</button>
        <button className="btn btn-sm" onClick={() => onDone(false)} disabled={saving}>Cancel</button>
      </div>
    </div>
  );
}

function ScheduledOTTab() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);
  const [reschedulingId, setReschedulingId] = useState(null);

  const refresh = useCallback(async () => {
    setSchedule(await getScheduledOT());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId, patientName) {
    if (!window.confirm(`Mark ${patientName}'s surgery as Complete? This should only be done AFTER the surgery has actually happened -- it will move out of Scheduled and cannot be easily undone once intraoperative details are recorded.`)) return;
    await completeOT(otId, caseId);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Scheduled OT
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{schedule.length}</span>
      </div>

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {schedule.map((s) => (
              <Fragment key={s.id}>
                <tr>
                  <td>{fmtDate(s.scheduled_date)}</td>
                  <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                  <td>{s.room || '--'}</td>
                  <td>
                    {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                  </td>
                  <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                  <td>{s.profiles?.full_name || '--'}</td>
                  <td>
                    <span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span>
                    {s.reschedule_count > 0 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>(rescheduled {s.reschedule_count}x)</span>}
                  </td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-sm" onClick={() => setReschedulingId(reschedulingId === s.id ? null : s.id)}>
                        <i className="ti ti-calendar-time"></i> Reschedule
                      </button>
                      <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id, `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`)}>Complete</button>
                    </div>
                  </td>
                </tr>
                {reschedulingId === s.id && (
                  <tr>
                    <td colSpan={8} style={{ padding: 0, border: 'none' }}>
                      <RescheduleForm booking={s} onDone={(saved) => { setReschedulingId(null); if (saved) refresh(); }} />
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {schedule.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

function OTHistoryTab() {
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [undoingId, setUndoingId] = useState(null);
  const [undoError, setUndoError] = useState('');

  const refresh = useCallback(() => {
    getOTHistory().then((data) => { setHistory(data); setLoading(false); });
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleUndo(s) {
    const name = `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`;
    if (!window.confirm(`Undo the Complete on ${name}'s surgery and move it back to Scheduled?`)) return;
    setUndoError('');
    setUndoingId(s.id);
    const result = await undoCompleteOT(s.id, s.surgical_case_id);
    setUndoingId(null);
    if (result.error) { setUndoError(result.error); return; }
    refresh();
  }

  const filtered = search.trim()
    ? history.filter((s) => {
        const q = search.trim().toLowerCase();
        const p = s.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : history;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> OT History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Patients no longer in the active schedule -- currently in surgery, completed, or cancelled.
      </div>
      {undoError && <div className="msg-err" style={{ marginBottom: 10 }}>{undoError}</div>}

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {filtered.map((s) => (
              <tr key={s.id}>
                <td>{fmtDate(s.scheduled_date)}</td>
                <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                <td>
                  {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                </td>
                <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                <td>{s.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span></td>
                <td>
                  {s.status === 'Completed' && (
                    <button className="btn btn-sm" onClick={() => handleUndo(s)} disabled={undoingId === s.id} title="Undo an accidental Complete click">
                      {undoingId === s.id ? 'Undoing...' : <><i className="ti ti-arrow-back-up"></i> Undo</>}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>Nothing here yet.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function OTSchedulePage() {
  const [activeTab, setActiveTab] = useState('scheduled');

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <button
          type="button"
          onClick={() => setActiveTab('scheduled')}
          style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'scheduled' ? '#fff' : 'transparent', color: activeTab === 'scheduled' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'scheduled' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
        >
          <i className="ti ti-calendar-event"></i> Scheduled OT
        </button>
        <button
          type="button"
          onClick={() => setActiveTab('history')}
          style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'history' ? '#fff' : 'transparent', color: activeTab === 'history' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'history' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
        >
          <i className="ti ti-history"></i> OT History
        </button>
      </div>

      {activeTab === 'scheduled' && <ScheduledOTTab />}
      {activeTab === 'history' && <OTHistoryTab />}
    </div>
  );
}
