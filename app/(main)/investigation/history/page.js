'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    setLoading(true);
    const result = await getInvestigationHistory();
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = rows.filter((r) => {
    if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
    if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
    return true;
  });

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Date/Time</th><th>Patient</th><th>Investigation</th><th>Eye</th><th>Key values</th><th>Status</th><th>Doctor</th><th>Performed by</th></tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const p = r.encounters?.visits?.patients;
              const type = matchInvestigationType(r.name);
              return (
                <tr key={r.id} onClick={() => router.push(`/investigation/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <strong>{p?.first_name} {p?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{p?.uhid}</span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td><span className="badge b-blue" style={{ fontSize: 10 }}>{r.eye}</span></td>
                  <td style={{ fontSize: 11, color: 'var(--g600)' }}>{summarizeResultData(type, r.result_data)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 11 }}>{r.doctorName}</td>
                  <td style={{ fontSize: 11, color: 'var(--g400)' }}>{r.performedByName}</td>
                </tr>
              );
            })}
            {!loading && filtered.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No records found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

