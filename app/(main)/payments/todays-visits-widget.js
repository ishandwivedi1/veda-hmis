'use client';

import { VISIT_TYPE_COLOR } from '@/lib/visit-types';
import { formatPatientName } from '@/lib/patientName';

export default function TodaysVisitsWidget({ visits, onSelect, title = "Today's Visits" }) {
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> {title}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to select that patient.</div>
      {visits.map((v) => (
        <div
          key={v.id}
          onClick={() => onSelect(v.patients)}
          style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
        >
          <strong>{formatPatientName(v.patients)}</strong>
          <div style={{ color: 'var(--g500)' }}>
            {v.visit_number} --{' '}
            <span style={{ width: 6, height: 6, borderRadius: '50%', background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g400'})`, display: 'inline-block', marginRight: 4 }}></span>
            {v.visit_type}
          </div>
        </div>
      ))}
      {visits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
    </div>
  );
}

