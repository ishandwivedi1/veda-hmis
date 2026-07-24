'use client';

import { useState, useEffect } from 'react';
import { getOTCaseList } from './actions';
import Workspace from './workspace';

const STATUS_BADGE = { Scheduled: 'b-amber', 'In Progress': 'b-blue' };

export default function OTIntraopPage() {
  const [cases, setCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [activeId, setActiveId] = useState(null);

  async function refresh() {
    setLoading(true);
    setCases(await getOTCaseList());
    setLoading(false);
  }

  useEffect(() => { refresh(); }, []);

  if (activeId) {
    return <Workspace otScheduleId={activeId} onBack={() => { setActiveId(null); refresh(); }} />;
  }

  return (
    <div style={{ maxWidth: 640, margin: '30px auto', textAlign: 'center' }}>
      <i className="ti ti-building-hospital" style={{ fontSize: 38, color: 'var(--red)', display: 'block', marginBottom: 8 }}></i>
      <div style={{ fontSize: 17, fontWeight: 700 }}>Intraoperative Management</div>
      <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4, marginBottom: 20 }}>Select an OT Case to begin documentation</div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && cases.map((c) => {
        const sc = c.surgical_cases;
        const patient = sc.patients;
        return (
          <div
            key={c.id}
            onClick={() => setActiveId(c.id)}
            className="card"
            style={{ textAlign: 'left', cursor: 'pointer', marginBottom: 10, transition: 'border-color .15s' }}
          >
            <div style={{ fontSize: 14, fontWeight: 700 }}>
              {patient?.first_name} {patient?.last_name}
              <span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8 }}>{c.status}</span>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 3 }}>
              {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
            </div>
          </div>
        );
      })}

      {!loading && cases.length === 0 && (
        <div style={{ color: 'var(--g400)', fontSize: 13 }}>No OT cases scheduled for today.</div>
      )}
    </div>
  );
}

