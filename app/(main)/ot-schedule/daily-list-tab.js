'use client';

import { useState, useEffect } from 'react';
import { getDailyOTList, getOTSessions } from './actions';

export default function DailyListTab() {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessions, setSessions] = useState([]);
  const [sessionFilter, setSessionFilter] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => { getOTSessions().then(setSessions); }, []);
  useEffect(() => {
    setLoading(true);
    getDailyOTList(date, sessionFilter || undefined).then((r) => { setRows(r); setLoading(false); });
  }, [date, sessionFilter]);

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
        <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 12px', borderBottom: '1px solid var(--g100)' }}>
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
            {r.iolPlans.length > 0 && (
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 1, fontFamily: 'monospace' }}>
                IOL: {r.iolPlans.map((p) => `${p.surgical_eye} ${p.final_iol_power}D`).join(', ')}
              </div>
            )}
          </div>
          <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-blue'}`} style={{ fontSize: 10 }}>{r.status}</span>
        </div>
      ))}

      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No surgeries scheduled for this date{sessionFilter ? '/session' : ''}.</div>
      )}
    </div>
  );
}

