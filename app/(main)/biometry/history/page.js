'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryHistory } from '../actions';

function bestReading(sets) {
  if (!Array.isArray(sets) || sets.length === 0) return {};
  return sets.find((s) => s.axl && s.k1 && s.k2 && s.acd) || sets[0] || {};
}

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
          One record per patient, reused across every future surgical case -- readings don't meaningfully change for years. IOL brand/power recommendations and the surgeon's final approval are on each record's own page.
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date</th><th>Patient</th><th>RE: AXL / K1/K2 / ACD</th><th>LE: AXL / K1/K2 / ACD</th><th>Device</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.patients;
              const reReading = bestReading(r.measurements?.re);
              const leReading = bestReading(r.measurements?.le);
              return (
                <tr key={r.id} onClick={() => router.push(`/biometry/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.updated_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td>
                    <strong>{patient?.first_name} {patient?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{reReading.axl || '--'} / {reReading.k1 || '--'}/{reReading.k2 || '--'} / {reReading.acd || '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{leReading.axl || '--'} / {leReading.k1 || '--'}/{leReading.k2 || '--'} / {leReading.acd || '--'}</td>
                  <td style={{ fontSize: 11 }}>{r.verify_device || '--'}</td>
                  <td><span className="badge b-green">{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
