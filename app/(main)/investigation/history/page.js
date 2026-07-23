'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

const SORT_OPTIONS = [
  { value: 'date_desc', label: 'Newest first' },
  { value: 'date_asc', label: 'Oldest first' },
  { value: 'patient_asc', label: 'Patient (A-Z)' },
  { value: 'status', label: 'Status' },
];

function patientLabel(r) {
  const p = r.encounters?.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : '';
}

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [sortBy, setSortBy] = useState('date_desc');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (from, to) => {
    setLoading(true);
    const result = await getInvestigationHistory(from || undefined, to || undefined);
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(fromDate, toDate); }, [fromDate, toDate, refresh]);

  function clearDates() {
    setFromDate('');
    setToDate('');
  }

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = useMemo(() => {
    const result = rows.filter((r) => {
      if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
      if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
      return true;
    });

    const sorted = [...result];
    if (sortBy === 'date_desc') sorted.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    else if (sortBy === 'date_asc') sorted.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    else if (sortBy === 'patient_asc') sorted.sort((a, b) => patientLabel(a).localeCompare(patientLabel(b)));
    else if (sortBy === 'status') sorted.sort((a, b) => a.status.localeCompare(b.status));
    return sorted;
  }, [rows, patientFilter, typeFilter, sortBy]);

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <label className="flbl">From</label>
            <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">To</label>
            <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          </div>
          {(fromDate || toDate) && (
            <button className="btn btn-sm" style={{ alignSelf: 'flex-end' }} onClick={clearDates}>
              <i className="ti ti-x"></i> Clear dates
            </button>
          )}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignSelf: 'flex-end' }}>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
              {SORT_OPTIONS.map((s) => <option key={s.value} value={s.value}>Sort: {s.label}</option>)}
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

