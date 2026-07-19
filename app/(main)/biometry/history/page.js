'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryHistory } from '../actions';

export default function BiometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patients, setPatients] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const router = useRouter();

  const refresh = useCallback(async (filter) => {
    const result = await getBiometryHistory(filter || undefined);
    setRows(result.rows);
    setPatients(result.patients);
  }, []);

  useEffect(() => { refresh(patientFilter); }, [patientFilter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Biometry History</div>
          <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
            <option value="">All patients</option>
            {patients.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
          Historical measurements are never overwritten. Recalculations and re-approvals create new versions, visible in each record's Surgeon Approval tab.
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date</th><th>Patient</th><th>Eye</th><th>AXL</th><th>K1/K2</th><th>ACD</th><th>Formula</th><th>Approved IOL</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.visits?.patients;
              const eyeKey = r.surgical_eye === 'RE' ? 're' : r.surgical_eye === 'LE' ? 'le' : null;
              const m = eyeKey ? (r.measurements?.[eyeKey] || {}) : {};
              return (
                <tr key={r.id} onClick={() => router.push(`/biometry/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.updated_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td>
                    <strong>{patient?.first_name} {patient?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span>
                  </td>
                  <td>{r.surgical_eye || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.axl || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.k1 || '--'}/{m.k2 || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.acd || '--'}</td>
                  <td>{r.selected_formula || r.final_iol_power ? (r.selected_formula || '--') : '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.final_iol_power ? `${r.final_iol_power} D` : '--'}</td>
                  <td><span className={`badge ${r.status === 'Approved' ? 'b-green' : 'b-blue'}`}>{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
