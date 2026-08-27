'use client';

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import { getBiometryQueue, getBiometryCompletedToday } from './actions';

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function BiometryQueuePage() {
  const [rows, setRows] = useState([]);
  const [completedToday, setCompletedToday] = useState([]);
  const [stats, setStats] = useState({ awaiting: 0, measuredToday: 0 });
  const [error, setError] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getBiometryQueue();
    setRows(result.rows);
    setStats(result.stats);
    setCompletedToday(await getBiometryCompletedToday());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Awaiting biometry" value={stats.awaiting} sub="Not yet measured" color="var(--indigo)" />
        <KpiCard label="Measured today" value={stats.measuredToday} sub="Sessions completed today" color="var(--green)" />
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Biometry is always done for both eyes and is reusable across every future surgical case for this patient -- readings don't meaningfully change for years. Surgeon IOL approval for a specific case happens in its own module.
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Biometry Queue</div>
          <button className="btn btn-sm" onClick={() => router.push('/biometry/history')}>
            <i className="ti ti-history"></i> History
          </button>
        </div>
        {rows.map((row) => (
          <div key={row.recordId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(row.patient)}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{row.status}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {row.patient?.uhid}{row.doctorInstructions ? ` -- ${row.doctorInstructions}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => router.push(`/biometry/${row.recordId}`)}>
              <i className="ti ti-ruler-measure"></i> Measure
            </button>
          </div>
        ))}
        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            Nothing pending -- all caught up.
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Measured Today</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still viewable from here today.</div>
        {completedToday.map((row) => (
          <div key={row.recordId} onClick={() => router.push(`/biometry/${row.recordId}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(row.patient)}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Measured</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>{row.patient?.uhid}</div>
            </div>
            <button className="btn btn-sm"><i className="ti ti-eye"></i> View</button>
          </div>
        ))}
        {completedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing measured yet today.</div>
        )}
      </div>
    </div>
  );
}
