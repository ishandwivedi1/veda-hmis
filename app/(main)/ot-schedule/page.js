'use client';

import { useState, useEffect, useCallback, Fragment, Suspense } from 'react';
import {
  getScheduledOT, getOTHistory, getOTAvailability, rescheduleOTSlot, completeOT, undoCompleteOT,
  searchPatientsForDirectSurgery, getPackagesForDirectSurgery, getSurgeonsForDirectSurgery, registerSurgeryDirect,
} from './actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import OTCalendar from './ot-calendar';

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

// ── REGISTER SURGERY DIRECTLY ──────────────────────────────────────────
// Fast-track for a patient whose surgical decision was made outside
// today's Doctor -> Counselling pipeline: a returning patient whose
// surgery was arranged before HMIS existed, an external referral, an
// emergency. Creates the surgical case AND books the OT slot in one go,
// with biometry & medical fitness recorded as skipped-with-a-reason
// rather than the app pretending they went through the normal workup.
function RegisterSurgeryDirectForm({ onDone }) {
  const [patientQuery, setPatientQuery] = useState('');
  const [patientResults, setPatientResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searching, setSearching] = useState(false);

  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState('');
  const [eye, setEye] = useState('');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState('');
  const [priority, setPriority] = useState('Routine');
  const [workupNote, setWorkupNote] = useState('');

  const [packages, setPackages] = useState([]);
  const [packageId, setPackageId] = useState('');

  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getSurgeries().then(setSurgeries);
    getSurgeonsForDirectSurgery().then(setSurgeons);
    getPackagesForDirectSurgery().then(setPackages);
  }, []);

  useEffect(() => {
    if (!patientQuery.trim()) { setPatientResults([]); return; }
    setSearching(true);
    const t = setTimeout(() => {
      searchPatientsForDirectSurgery(patientQuery.trim()).then((rows) => { setPatientResults(rows); setSearching(false); });
    }, 300);
    return () => clearTimeout(t);
  }, [patientQuery]);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!selectedPatient) { setError('Select a patient.'); return; }
    if (!procedureName) { setError('Select the procedure.'); return; }
    if (!workupNote.trim()) { setError('Explain where biometry & fitness clearance came from -- required so this case has an honest audit trail.'); return; }
    if (!packageId) { setError('Select a billing package.'); return; }
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }

    setSaving(true);
    const result = await registerSurgeryDirect({
      patientId: selectedPatient.id, procedureName, eye: eye || null, surgeonId: surgeonId || null,
      priority, workupNote, packageId, date, sessionId, notes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Register Surgery Directly
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>
        For a patient whose surgery was decided outside today's Doctor / Counselling flow -- a returning patient from before HMIS existed, an external referral, or an emergency. Biometry & medical fitness are recorded as not-required-in-system with your reason, not faked.
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Patient</label>
        {selectedPatient ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
            <span className="badge b-blue">{selectedPatient.uhid}</span>
            <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
            <span style={{ color: 'var(--g400)', fontSize: 11 }}>{selectedPatient.mobile}</span>
            <button type="button" className="btn btn-sm" onClick={() => { setSelectedPatient(null); setPatientQuery(''); }}>Change</button>
          </div>
        ) : (
          <>
            <input className="fi fi-sm" placeholder="Search by name, UHID, or mobile..." value={patientQuery} onChange={(e) => setPatientQuery(e.target.value)} />
            {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>Searching...</div>}
            {patientResults.length > 0 && (
              <div style={{ marginTop: 6, border: '1px solid var(--g100)', borderRadius: 8, maxHeight: 180, overflowY: 'auto' }}>
                {patientResults.map((p) => (
                  <div
                    key={p.id}
                    onClick={() => { setSelectedPatient(p); setPatientResults([]); }}
                    style={{ padding: '8px 10px', fontSize: 12.5, cursor: 'pointer', borderBottom: '1px solid var(--g100)' }}
                  >
                    <span className="badge b-blue" style={{ marginRight: 6 }}>{p.uhid}</span>
                    {p.first_name} {p.last_name} <span style={{ color: 'var(--g400)' }}>-- {p.mobile}</span>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Procedure</label>
          <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
            <option value="">Select...</option>
            {surgeries.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Eye</label>
          <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
            <option value="">--</option>
            <option value="RE">RE</option>
            <option value="LE">LE</option>
          </select>
        </div>
      </div>

      {procedureName && (
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: -6, marginBottom: 12 }}>
          For a bilateral case, register each eye separately (they're normally booked into different OT sessions/dates anyway) -- submit this form once per eye.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">--</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Priority</label>
          <select className="fi fi-sm" value={priority} onChange={(e) => setPriority(e.target.value)}>
            <option value="Routine">Routine</option>
            <option value="Urgent">Urgent</option>
            <option value="Emergency">Emergency</option>
          </select>
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Where did biometry & medical fitness clearance come from?</label>
        <input className="fi fi-sm" placeholder='e.g. "Done before HMIS -- surgery decided 1 month ago", "External hospital referral, reports attached", "Emergency"' value={workupNote} onChange={(e) => setWorkupNote(e.target.value)} />
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Billing Package</label>
        <select className="fi fi-sm" value={packageId} onChange={(e) => setPackageId(e.target.value)}>
          <option value="">Select...</option>
          {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- ₹{p.price}</option>)}
        </select>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">OT Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{date ? 'No active OT sessions configured.' : 'Pick a date first.'}</div>
          ) : (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id} type="button" disabled={full} onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    {s.name} ({s.remaining} left)
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label className="flbl">Notes (optional)</label>
        <input className="fi fi-sm" placeholder="Anything else worth recording..." value={notes} onChange={(e) => setNotes(e.target.value)} />
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Registering...' : <><i className="ti ti-check"></i> Register & Book OT Slot</>}
        </button>
        <button className="btn" onClick={() => onDone(false)}>Cancel</button>
      </div>
    </div>
  );
}

export default function OTSchedulePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <OTScheduleInner />
    </Suspense>
  );
}

function OTScheduleInner() {
  const [activeTab, setActiveTab] = useState('scheduled');
  const [showDirectForm, setShowDirectForm] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 10, marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 480 }}>
          <button
            type="button"
            onClick={() => setActiveTab('scheduled')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'scheduled' ? '#fff' : 'transparent', color: activeTab === 'scheduled' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'scheduled' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar-event"></i> Scheduled OT
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('calendar')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'calendar' ? '#fff' : 'transparent', color: activeTab === 'calendar' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'calendar' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar"></i> Calendar
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('history')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'history' ? '#fff' : 'transparent', color: activeTab === 'history' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'history' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-history"></i> OT History
          </button>
        </div>

        <button type="button" className="btn" style={{ borderColor: 'var(--amber)', color: 'var(--amber)' }} onClick={() => setShowDirectForm(!showDirectForm)}>
          <i className="ti ti-calendar-plus"></i> {showDirectForm ? 'Close' : 'Register Surgery Directly'}
        </button>
      </div>

      {showDirectForm && (
        <RegisterSurgeryDirectForm
          onDone={(saved) => {
            setShowDirectForm(false);
            if (saved) { setActiveTab('scheduled'); setRefreshKey((k) => k + 1); }
          }}
        />
      )}

      {activeTab === 'scheduled' && <ScheduledOTTab key={refreshKey} />}
      {activeTab === 'calendar' && <OTCalendar />}
      {activeTab === 'history' && <OTHistoryTab />}
    </div>
  );
}
