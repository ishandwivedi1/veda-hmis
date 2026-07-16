'use client';

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
          <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
          <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
        </div>
      ))}
      {visits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
    </div>
  );
}

