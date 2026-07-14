'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getOptometryDashboardData } from './actions';
import { optometryCallNext, optometryCallSpecific } from '@/app/(main)/queue/actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function TokenBadge({ token }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

export default function OptometryDashboardPage() {
  const [active, setActive] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const { active, completed } = await getOptometryDashboardData();
    setActive(active);
    setCompleted(completed);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  const waitingCount = active.filter((e) => e.status === 'Waiting').length;
  const callingCount = active.filter((e) => e.status === 'Calling').length;
  const editableCount = completed.filter((e) => !e.locked).length;
  const lockedCount = completed.filter((e) => e.locked).length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Progress</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{callingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Editable Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{editableCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Posted, not yet seen by doctor</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--g400)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Locked Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{lockedCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Doctor has opened these</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* ACTIVE QUEUE */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
              <span className="badge b-gray">{active.length}</span>
            </div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>
          {active.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Calling' ? 'b-blue' : 'b-gray'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}>
                    <i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m
                  </span>
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn btn-sm" onClick={() => runAction(optometryCallSpecific, e.id)}>Call</button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  Start Assessment
                </Link>
              )}
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* COMPLETED TODAY -- view / edit already-posted readings */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-clipboard-check" style={{ color: 'var(--purple)' }}></i> Completed Today
              <span className="badge b-gray">{completed.length}</span>
            </div>
          </div>
          {completed.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.locked ? 'b-gray' : 'b-green'}`}>
                    {e.locked ? 'Locked -- doctor viewing' : 'Editable'}
                  </span>
                </div>
              </div>
              <Link href={`/optometry/${e.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                {e.locked ? 'View' : 'Edit'}
              </Link>
            </div>
          ))}
          {completed.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              Nothing completed yet today
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

