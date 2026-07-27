'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getOptometryHistory } from './actions';

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export default function OptometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (status) => {
    setLoading(true);
    const result = await getOptometryHistory(status || undefined);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setError('');
    setRows(result.rows);
  }, []);

  useEffect(() => { refresh(filter); }, [filter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Assessment History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <select className="fi" style={{ width: 'auto', padding: '9px 12px' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="">All</option>
            <option value="Completed">Completed</option>
            <option value="Draft">Draft</option>
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date/Time</th><th>Patient</th><th>Visit</th><th>VA RE</th><th>VA LE</th><th>IOP RE</th><th>IOP LE</th><th>Status</th><th>By</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const iopReHigh = typeof r.iopRe === 'number' && r.iopRe > 21;
              const iopLeHigh = typeof r.iopLe === 'number' && r.iopLe > 21;
              const by = r.status === 'Completed' ? (r.completed_by_profile?.full_name || '--') : (r.recorded_by_profile?.full_name || '--');
              const dt = new Date(r.completed_at || r.updated_at || r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
              return (
                <tr
                  key={r.id}
                  onClick={() => router.push(`/optometry-history/${r.id}`)}
                  style={{ cursor: 'pointer' }}
                >
                  <td style={{ fontSize: 11 }}>{dt}</td>
                  <td>
                    <strong>{patientName(r)}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.visits?.visit_number || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.re_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.le_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600, color: iopReHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopRe ?? '--'}{iopReHigh ? ' !' : ''}</td>
                  <td style={{ fontWeight: 600, color: iopLeHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopLe ?? '--'}{iopLeHigh ? ' !' : ''}</td>
                  <td>
                    <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-amber'}`}>{r.status}</span>
                    {r.hasDoctorCorrection && (
                      <span className="badge" style={{ marginLeft: 6, background: 'rgba(220,38,38,0.1)', color: 'var(--red)' }} title="Doctor recorded a differing finding for this visit">
                        <i className="ti ti-alert-triangle" style={{ fontSize: 11 }}></i> Correction
                      </span>
                    )}
                  </td>
                  <td style={{ fontSize: 12 }}>{by}</td>
                </tr>
              );
            })}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No assessments found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
