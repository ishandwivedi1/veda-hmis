'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getWorkflowMonitorData } from './actions';

const STATE_MATRIX = [
  { from: 'Waiting (Optometry)', event: 'Call Next / Call', to: 'Calling (Optometry)' },
  { from: 'Calling (Optometry)', event: 'Complete Assessment', to: 'Done -- Doctor token issued' },
  { from: 'Waiting (Doctor)', event: 'Call Next / Call', to: 'In Consultation' },
  { from: 'In Consultation', event: 'Send for Dilation', to: 'Awaiting Dilation' },
  { from: 'In Consultation', event: 'Send for Investigation', to: 'Awaiting Investigation' },
  { from: 'Awaiting Dilation / Investigation', event: 'Mark Ready', to: 'Ready for Review' },
  { from: 'Ready for Review', event: 'Call', to: 'In Consultation' },
  { from: 'In Consultation', event: 'Complete Visit', to: 'Done -- Encounter Completed' },
  { from: 'Requested (Biometry / Fitness / Counselling)', event: 'Toggle again, or Mark Done', to: 'Cancelled or Completed' },
];

function stateBadgeClass(state) {
  if (state === '--') return 'b-gray';
  if (state.includes('Awaiting')) return 'b-purple';
  if (state === 'Ready for Review') return 'b-green';
  if (state === 'In Consultation') return 'b-blue';
  return 'b-gray';
}

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

export default function WorkflowMonitorPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const data = await getWorkflowMonitorData();
    setRows(data);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-head">
          <div className="card-title"><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Workflow Status Monitor</div>
          <span style={{ fontSize: 11, color: 'var(--g400)' }}>Live view -- all in-progress consultations</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
          <i className="ti ti-info-circle"></i> Workflow-driven architecture -- all state transitions are logged. No manual patient routing.
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> State Transition Matrix</div>
        <table className="tbl">
          <thead><tr><th>From State</th><th>Event</th><th>Next State</th></tr></thead>
          <tbody>
            {STATE_MATRIX.map((s, i) => (
              <tr key={i}>
                <td><span className={`badge ${stateBadgeClass(s.from)}`} style={{ fontSize: 11 }}>{s.from}</span></td>
                <td style={{ fontSize: 12, color: 'var(--g600)' }}>{s.event}</td>
                <td><span className={`badge ${stateBadgeClass(s.to)}`} style={{ fontSize: 11 }}>{s.to}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <div className="card-head">
          <div className="card-title"><i className="ti ti-list" style={{ color: 'var(--blue)' }}></i> All Active Encounters</div>
          <span className="badge b-blue">{rows.length} encounters</span>
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Patient</th><th>UHID</th><th>Visit</th><th>Doctor</th><th>Queue State</th><th>Time in Consultation</th><th>Transitions</th><th></th></tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.id}>
                <td style={{ fontWeight: 600 }}>{e.visits?.patients?.first_name} {e.visits?.patients?.last_name}</td>
                <td style={{ fontSize: 11, fontFamily: 'monospace' }}>{e.visits?.patients?.uhid}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.visits?.visit_number || '--'}</td>
                <td style={{ fontSize: 12 }}>{e.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${stateBadgeClass(e.queueStatus)}`} style={{ fontSize: 10 }}>{e.queueStatus}</span></td>
                <td style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.started_at)}m</td>
                <td style={{ textAlign: 'center' }}><span className="badge b-gray">{e.transitions}</span></td>
                <td>
                  {e.queueEntryId && (
                    <Link href={`/consultation/${e.queueEntryId}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>Open</Link>
                  )}
                </td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No encounters in progress right now.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

