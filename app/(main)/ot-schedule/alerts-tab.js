'use client';

import { useState, useEffect } from 'react';
import { getOTAlerts } from './actions';

export default function AlertsTab() {
  const [alerts, setAlerts] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => { getOTAlerts().then((a) => { setAlerts(a); setLoading(false); }); }, []);

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title"><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> OT Readiness Alerts</div>
        <span className="badge b-red">{alerts.length}</span>
      </div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Readiness changes after scheduling (e.g. medical fitness no longer cleared) surface here automatically.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && alerts.map((a, i) => (
        <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 12px', borderRadius: 8, marginBottom: 6, background: a.urgency === 'high' ? 'var(--red-lt)' : 'var(--amber-lt)', border: `1px solid ${a.urgency === 'high' ? 'var(--red)' : 'var(--amber)'}30` }}>
          <i className="ti ti-alert-triangle" style={{ color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)', fontSize: 18, flexShrink: 0 }}></i>
          <div style={{ flex: 1 }}>
            <div style={{ fontWeight: 700, fontSize: 13 }}>{a.patient}</div>
            <div style={{ fontSize: 11, color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)' }}>{a.issue}</div>
          </div>
          <span className="badge" style={{ background: a.urgency === 'high' ? 'var(--red-lt)' : 'var(--amber-lt)', color: a.urgency === 'high' ? 'var(--red)' : 'var(--amber)', fontSize: 10 }}>{a.urgency.toUpperCase()}</span>
        </div>
      ))}

      {!loading && alerts.length === 0 && (
        <div style={{ textAlign: 'center', padding: 30, color: 'var(--green)' }}>
          <i className="ti ti-circle-check" style={{ fontSize: 24, display: 'block', marginBottom: 6 }}></i>
          No readiness alerts.
        </div>
      )}
    </div>
  );
}

