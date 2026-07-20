'use client';

import { useState, useEffect, useCallback } from 'react';
import { getSurgicalCases, getSurgeons, scheduleOT, getOTSchedule, completeOT } from '@/app/(main)/counselling/actions';

function ScheduleForm({ sc, surgeons, onScheduled }) {
  const [surgeonId, setSurgeonId] = useState('');
  const [date, setDate] = useState('');
  const [time, setTime] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSchedule() {
    setError('');
    if (!date) { setError('Date is required.'); return; }
    setLoading(true);
    const result = await scheduleOT(sc.id, surgeonId, date, time, notes);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    onScheduled();
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div style={{ fontWeight: 700, fontSize: 14, marginBottom: 4 }}>
        {sc.patients.first_name} {sc.patients.last_name} -- {sc.patients.uhid}
      </div>
      <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>{sc.procedure_name} -- {sc.eye}</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
        <select className="fi" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
          <option value="">-- Surgeon --</option>
          {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
        </select>
        <input type="date" className="fi" value={date} onChange={(e) => setDate(e.target.value)} />
        <input type="time" className="fi" value={time} onChange={(e) => setTime(e.target.value)} />
      </div>
      <input className="fi" placeholder="Notes" value={notes} onChange={(e) => setNotes(e.target.value)} style={{ marginBottom: 8 }} />
      <button className="btn btn-primary btn-sm" onClick={handleSchedule} disabled={loading}>
        {loading ? 'Scheduling...' : 'Schedule Surgery'}
      </button>
    </div>
  );
}

export default function OTSchedulePage() {
  const [readyCases, setReadyCases] = useState([]);
  const [surgeons, setSurgeons] = useState([]);
  const [schedule, setSchedule] = useState([]);

  const refresh = useCallback(async () => {
    const all = await getSurgicalCases();
    setReadyCases(all.filter((c) => c.status === 'Ready for Scheduling'));
    setSurgeons(await getSurgeons());
    setSchedule(await getOTSchedule());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId) {
    await completeOT(otId, caseId);
    refresh();
  }

  return (
    <div>
      {readyCases.length > 0 && (
        <>
          <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Ready to Schedule</div>
          {readyCases.map((sc) => (
            <ScheduleForm key={sc.id} sc={sc} surgeons={surgeons} onScheduled={refresh} />
          ))}
        </>
      )}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> OT Schedule
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Time</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {schedule.map((s) => (
              <tr key={s.id}>
                <td>{new Date(s.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
                <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                <td>{s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}</td>
                <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                <td>{s.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${s.status === 'Completed' ? 'b-green' : 'b-blue'}`}>{s.status}</span></td>
                <td>
                  {s.status === 'Scheduled' && (
                    <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id)}>Complete</button>
                  )}
                </td>
              </tr>
            ))}
            {schedule.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

