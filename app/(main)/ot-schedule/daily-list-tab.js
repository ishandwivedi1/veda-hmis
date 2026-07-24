'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDailyOTList, getOTSessions, rescheduleSurgery } from './actions';

export default function DailyListTab() {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessions, setSessions] = useState([]);
  const [sessionFilter, setSessionFilter] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const [reschedulingId, setReschedulingId] = useState(null);
  const [reschDate, setReschDate] = useState('');
  const [reschSessionId, setReschSessionId] = useState('');
  const [reschReason, setReschReason] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => { getOTSessions().then(setSessions); }, []);

  const refresh = useCallback(() => {
    setLoading(true);
    getDailyOTList(date, sessionFilter || undefined).then((r) => { setRows(r); setLoading(false); });
  }, [date, sessionFilter]);

  useEffect(() => { refresh(); }, [refresh]);

  function startReschedule(r) {
    setError('');
    setReschedulingId(r.id);
    setReschDate(r.scheduled_date);
    setReschSessionId(r.session_id);
    setReschReason('');
  }

  async function confirmReschedule() {
    setError('');
    if (!reschReason.trim()) { setError('A reschedule reason is required.'); return; }
    setSaving(true);
    const result = await rescheduleSurgery(reschedulingId, { date: reschDate, sessionId: reschSessionId, reason: reschReason });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setReschedulingId(null);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-list-details" style={{ color: 'var(--cyan)' }}></i> Daily OT List</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} style={{ width: 150 }} />
          <select className="fi fi-sm" value={sessionFilter} onChange={(e) => setSessionFilter(e.target.value)} style={{ width: 140 }}>
            <option value="">All sessions</option>
            {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <button className="btn btn-sm" onClick={() => window.print()}><i className="ti ti-printer"></i> Print</button>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && rows.map((r, i) => (
        <div key={r.id} style={{ borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 12px' }}>
            <div style={{ width: 24, height: 24, borderRadius: '50%', background: 'var(--cyan)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
              {r.sequence_number || i + 1}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 700 }}>
                {r.surgical_cases?.patients?.first_name} {r.surgical_cases?.patients?.last_name}
                <span className="badge b-cyan" style={{ marginLeft: 6, fontSize: 10 }}>{r.master_ot_sessions?.name}</span>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {r.surgical_cases?.procedure_name} -- {r.surgical_cases?.eye} -- {r.profiles?.full_name || 'No surgeon'}
              </div>
              {r.surgical_cases?.master_packages && (
                <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 1 }}>
                  <i className="ti ti-package"></i> {r.surgical_cases.master_packages.name}
                </div>
              )}
              {r.iolPlans.length > 0 && (
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 1, fontFamily: 'monospace' }}>
                  IOL: {r.iolPlans.map((p) => `${p.surgical_eye} ${p.final_iol_power}D`).join(', ')}
                </div>
              )}
              {r.reschedule_count > 0 && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 1 }}>Rescheduled {r.reschedule_count}x</div>}
            </div>
            <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-blue'}`} style={{ fontSize: 10 }}>{r.status}</span>
            {r.status === 'Scheduled' && (
              <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => startReschedule(r)}>
                <i className="ti ti-calendar-time"></i> Reschedule
              </button>
            )}
          </div>

          {reschedulingId === r.id && (
            <div style={{ margin: '0 12px 10px', padding: 10, background: 'var(--amber-lt)', borderRadius: 8 }}>
              {error && <div className="msg-err" style={{ fontSize: 11, marginBottom: 6 }}>{error}</div>}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <input type="date" className="fi fi-sm" value={reschDate} onChange={(e) => setReschDate(e.target.value)} />
                <select className="fi fi-sm" value={reschSessionId} onChange={(e) => setReschSessionId(e.target.value)}>
                  {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </select>
              </div>
              <select className="fi fi-sm" value={reschReason} onChange={(e) => setReschReason(e.target.value)} style={{ marginBottom: 8, width: '100%' }}>
                <option value="">-- Reason --</option>
                <option>Patient Request</option><option>Surgeon Unavailable</option><option>Medical Issue</option>
                <option>Equipment Failure</option><option>Emergency Case</option><option>Public Holiday</option>
              </select>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={confirmReschedule} disabled={saving}>{saving ? 'Saving...' : 'Confirm'}</button>
                <button className="btn btn-sm" onClick={() => setReschedulingId(null)}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      ))}

      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No surgeries scheduled for this date{sessionFilter ? '/session' : ''}.</div>
      )}
    </div>
  );
}


