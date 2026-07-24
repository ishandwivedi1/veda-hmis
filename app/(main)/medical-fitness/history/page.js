'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getMedicalFitnessHistory } from '../actions';
import MedicalFitnessTabs from '../medical-fitness-tabs';

const STATUS_BADGE = { Cleared: 'b-green', 'Not Fit': 'b-red' };

export default function MedicalFitnessHistoryPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState('');
  const [search, setSearch] = useState('');
  const router = useRouter();

  useEffect(() => {
    getMedicalFitnessHistory().then((r) => { setRows(r); setLoading(false); });
  }, []);

  const counts = {
    Cleared: rows.filter((r) => r.status === 'Cleared').length,
    'Not Fit': rows.filter((r) => r.status === 'Not Fit').length,
  };

  let filtered = statusFilter ? rows.filter((r) => r.status === statusFilter) : rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }

  return (
    <div>
      <MedicalFitnessTabs />

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Medical Fitness History</div>
          <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
          <button className={`btn btn-sm ${!statusFilter ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('')}>All ({rows.length})</button>
          <button className={`btn btn-sm ${statusFilter === 'Cleared' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Cleared')}>Cleared ({counts.Cleared})</button>
          <button className={`btn btn-sm ${statusFilter === 'Not Fit' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Not Fit')}>Not Fit ({counts['Not Fit']})</button>
        </div>

        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

        {!loading && (
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Decided By</th><th>Date</th><th></th></tr></thead>
            <tbody>
              {filtered.map((r) => (
                <tr key={r.id} onClick={() => router.push(`/medical-fitness/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td>
                    <strong>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                  </td>
                  <td style={{ fontSize: 12 }}>{r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 12 }}>{r.clearedByName}</td>
                  <td style={{ fontSize: 11 }}>{r.cleared_at ? new Date(r.cleared_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              ))}
              {filtered.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed referrals yet.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

