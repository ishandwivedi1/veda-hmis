'use client';

import { useState, useEffect } from 'react';
import { getQualityIndicators } from './actions';

export default function QualityIndicators() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => { getQualityIndicators().then((r) => { setRows(r); setLoading(false); }); }, []);

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--teal)' }}></i> Quality Indicators</div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> For quality improvement and benchmarking -- computed from actual closed episodes this month, not routine clinical documentation.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 12 }}>
          {rows.map((r) => (
            <div key={r.name} style={{ border: '1px solid var(--g200)', borderRadius: 12, padding: '14px 16px' }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>{r.name}</div>
              <div style={{ fontSize: 22, fontWeight: 700, color: 'var(--teal)' }}>{r.value}</div>
              <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{r.sub}</div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

