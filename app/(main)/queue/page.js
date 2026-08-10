'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  getPatientFlow,
  getPatientTimeline,
  optometryCallNext,
  optometryCallSpecific,
  doctorCallNext,
  doctorCallSpecific,
  doctorMarkReady,
} from './actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function formatDuration(mins) {
  if (mins < 60) return `${mins}m`;
  const h = Math.floor(mins / 60);
  const m = mins % 60;
  return `${h}h ${m}m`;
}

function waitBadgeClass(mins) {
  if (mins >= 30) return 'b-red';
  if (mins >= 15) return 'b-amber';
  return 'b-green';
}

// Total-in-hospital gets more generous thresholds than per-stage
// wait -- a patient can legitimately be in the building 45+ minutes
// across a normal visit without anything being wrong, so flagging
// that the same way as "15 minutes stuck in one queue" would just
// make everything look red by lunchtime.
function totalBadgeClass(mins) {
  if (mins >= 90) return 'b-red';
  if (mins >= 45) return 'b-amber';
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

const COLUMN_META = {
  'Waiting for Optometry': { icon: 'ti-eye-check', color: 'var(--g500)' },
  'With Optometrist': { icon: 'ti-eye-check', color: 'var(--teal)' },
  'Waiting for Doctor': { icon: 'ti-clock', color: 'var(--g500)' },
  'With Doctor': { icon: 'ti-stethoscope', color: 'var(--blue)' },
  'Sent Out': { icon: 'ti-route', color: 'var(--amber)' },
  'Billing': { icon: 'ti-receipt', color: 'var(--red)' },
  'Pharmacy': { icon: 'ti-pill', color: 'var(--teal)' },
  'Checked Out': { icon: 'ti-circle-check', color: 'var(--green)' },
};

function FlowCard({ item, onOpenTimeline }) {
  const stageMins = elapsedMin(item.since);
  const totalMins = elapsedMin(item.visitSince);
  return (
    <div
      onClick={() => onOpenTimeline(item)}
      style={{
        background: '#fff', border: '1px solid var(--g100)', borderRadius: 8,
        padding: '9px 10px', marginBottom: 8, cursor: 'pointer',
      }}
    >
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{item.patientName}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)' }}>{item.uhid}</div>
        </div>
        {item.priority && item.priority !== 'Routine' && (
          <span className={`badge ${item.priority === 'Emergency' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{item.priority}</span>
        )}
      </div>

      {/* Total time in hospital -- the headline figure, shown the
          same prominent way regardless of which column the patient
          is in, so it's the one number that's always easy to scan
          for across the whole board. */}
      <div style={{ marginTop: 7, display: 'flex', alignItems: 'center', gap: 5 }}>
        <span className={`badge ${totalBadgeClass(totalMins)}`} style={{ fontSize: 11, fontWeight: 700, padding: '3px 8px' }}>
          <i className="ti ti-hourglass"></i> {formatDuration(totalMins)} in hospital
        </span>
      </div>

      <div style={{ display: 'flex', gap: 6, alignItems: 'center', marginTop: 6, flexWrap: 'wrap' }}>
        {item.detail && <span className="badge b-gray" style={{ fontSize: 10 }}>{item.detail}</span>}
        {item.unpaid && <span className="badge b-red" style={{ fontSize: 10 }}><i className="ti ti-currency-rupee"></i> Unpaid</span>}
        {item.doctorName && <span className="badge b-gray" style={{ fontSize: 10 }}><i className="ti ti-stethoscope"></i> {item.doctorName}</span>}
      </div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 4 }}>
        In this stage: <span style={{ fontWeight: 600, color: waitBadgeClass(stageMins) === 'b-red' ? 'var(--red)' : 'var(--g500)' }}>{formatDuration(stageMins)}</span>
      </div>
    </div>
  );
}

function TimelineModal({ visitId, onClose }) {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    getPatientTimeline(visitId).then((res) => {
      if (!cancelled) { setData(res); setLoading(false); }
    });
    return () => { cancelled = true; };
  }, [visitId]);

  return (
    <div
      onClick={onClose}
      style={{
        position: 'fixed', inset: 0, background: 'rgba(0,0,0,0.4)', zIndex: 1000,
        display: 'flex', justifyContent: 'flex-end',
      }}
    >
      <div
        onClick={(e) => e.stopPropagation()}
        style={{
          background: '#fff', width: 380, maxWidth: '90vw', height: '100%',
          padding: 20, overflowY: 'auto', boxShadow: '-4px 0 20px rgba(0,0,0,0.15)',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 16 }}>
          <div>
            <div style={{ fontWeight: 800, fontSize: 16 }}>{data?.patientName || 'Loading...'}</div>
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{data?.uhid}</div>
          </div>
          <button className="btn btn-sm" onClick={onClose}><i className="ti ti-x"></i></button>
        </div>

        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading timeline...</div>}

        {!loading && data && (
          <>
            {data.breakdown && data.breakdown.length > 0 && (
              <div style={{ marginBottom: 20, paddingBottom: 16, borderBottom: '1px solid var(--g100)' }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>
                  Time Breakdown
                </div>
                {(() => {
                  const maxMins = Math.max(...data.breakdown.map((b) => b.minutes));
                  return data.breakdown.map((b) => (
                    <div key={b.label} style={{ marginBottom: 8 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                        <span>{b.label}</span>
                        <span style={{ fontWeight: 700 }}>{formatDuration(b.minutes)}</span>
                      </div>
                      <div style={{ background: 'var(--g100)', borderRadius: 4, height: 6, overflow: 'hidden' }}>
                        <div style={{ background: 'var(--blue)', height: '100%', width: `${Math.max(4, (b.minutes / maxMins) * 100)}%` }}></div>
                      </div>
                    </div>
                  ));
                })()}
              </div>
            )}

            <div style={{ position: 'relative', paddingLeft: 22 }}>
              <div style={{ position: 'absolute', left: 7, top: 6, bottom: 6, width: 2, background: 'var(--g100)' }}></div>
              {data.events.map((ev, i) => (
                <div key={i} style={{ position: 'relative', marginBottom: 18 }}>
                  <div style={{
                    position: 'absolute', left: -22, top: 2, width: 14, height: 14, borderRadius: '50%',
                    background: '#fff', border: `2.5px solid ${ev.color}`,
                  }}></div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginBottom: 2 }}>
                    {new Date(ev.time).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}
                  </div>
                  <div style={{ fontSize: 13, fontWeight: 600, display: 'flex', alignItems: 'center', gap: 6 }}>
                    <i className={`ti ${ev.icon}`} style={{ color: ev.color }}></i> {ev.label}
                  </div>
                </div>
              ))}
              {data.events.length === 0 && (
                <div style={{ color: 'var(--g400)', fontSize: 13 }}>No recorded events yet.</div>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function QueuePage() {
  const [flow, setFlow] = useState({ columns: [], byColumn: {} });
  const [optometry, setOptometry] = useState([]);
  const [doctor, setDoctor] = useState([]);
  const [error, setError] = useState('');
  const [showControls, setShowControls] = useState(false);
  const [timelineVisitId, setTimelineVisitId] = useState(null);

  const refresh = useCallback(async () => {
    const [flowData, queues] = await Promise.all([getPatientFlow(), getQueues()]);
    setFlow(flowData);
    setOptometry(queues.optometry);
    setDoctor(queues.doctor);
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

  const doctorInConsultation = doctor.find((d) => d.status === 'In Consultation');
  const totalActive = Object.values(flow.byColumn).reduce((sum, list, i) =>
    flow.columns[i] === 'Checked Out' ? sum : sum + list.length, 0);

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          <strong>{totalActive}</strong> patients active today &middot; auto-refreshes every 15s
        </div>
        <button className="btn btn-sm" onClick={() => setShowControls((s) => !s)}>
          <i className="ti ti-adjustments"></i> {showControls ? 'Hide' : 'Show'} Call Queue Controls
        </button>
      </div>

      {showControls && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 24 }}>
          {/* OPTOMETRY */}
          <div className="card">
            <div className="card-head">
              <div className="card-title">
                <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
                <span className="badge b-gray">{optometry.length}</span>
              </div>
            </div>
            <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
              <i className="ti ti-bell-ringing"></i> Call Next
            </button>
            {optometry.map((e) => (
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
                    Enter Findings
                  </Link>
                )}
              </div>
            ))}
            {optometry.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
                <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
                Queue is empty
              </div>
            )}
          </div>

          {/* DOCTOR */}
          <div className="card">
            <div className="card-head">
              <div className="card-title">
                <i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue
                <span className="badge b-gray">{doctor.length}</span>
              </div>
            </div>
            <button
              className="btn btn-primary"
              style={{ width: '100%', marginBottom: 12 }}
              onClick={() => runAction(doctorCallNext)}
              disabled={!!doctorInConsultation}
            >
              <i className="ti ti-bell-ringing"></i> Call Next
            </button>

            {doctorInConsultation && (
              <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                  <TokenBadge token={doctorInConsultation.token} />
                  <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(doctorInConsultation)}</span>
                </div>
                <Link
                  href={`/consultation/${doctorInConsultation.id}`}
                  className="btn btn-primary btn-sm"
                  style={{ textDecoration: 'none' }}
                >
                  <i className="ti ti-clipboard-text"></i> Open Consultation
                </Link>
              </div>
            )}

            {doctor
              .filter((e) => e.id !== doctorInConsultation?.id)
              .map((e) => {
                const notAvailable = e.status?.startsWith('Awaiting');
                const since = notAvailable ? e.sent_out_at : e.issued_at;
                return (
                  <div
                    key={e.id}
                    style={{
                      display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                      padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                      opacity: notAvailable ? 0.55 : 1,
                    }}
                  >
                    <div>
                      <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                        <TokenBadge token={e.token} />
                        <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                      </div>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${notAvailable ? 'b-amber' : 'b-gray'}`}>{e.status}</span>
                        <span className={`badge ${waitBadgeClass(elapsedMin(since))}`}>
                          <i className="ti ti-clock"></i> {elapsedMin(since)}m
                        </span>
                      </div>
                    </div>
                    {(e.status === 'Waiting' || e.status === 'Ready for Review') && (
                      <button className="btn btn-sm" onClick={() => runAction(doctorCallSpecific, e.id)} disabled={!!doctorInConsultation}>
                        Call
                      </button>
                    )}
                    {notAvailable && (
                      <button className="btn btn-sm" onClick={() => runAction(doctorMarkReady, e.id)}>Mark Ready</button>
                    )}
                  </div>
                );
              })}
            {doctor.length === 0 && (
              <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
                <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
                Queue is empty
              </div>
            )}
          </div>
        </div>
      )}

      {/* PATIENT FLOW BOARD */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 14 }}>
        {flow.columns.map((col) => {
          const items = flow.byColumn[col] || [];
          const meta = COLUMN_META[col] || {};
          if (col === 'Checked Out' && items.length === 0) return null;
          return (
            <div key={col}>
              <div className="card" style={{ padding: 10, minHeight: 120 }}>
                <div style={{
                  display: 'flex', alignItems: 'center', justifyContent: 'space-between',
                  marginBottom: 10, paddingBottom: 8, borderBottom: '1px solid var(--g100)',
                }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, fontWeight: 700, fontSize: 12.5 }}>
                    <i className={`ti ${meta.icon || 'ti-circle'}`} style={{ color: meta.color || 'var(--g500)' }}></i>
                    {col}
                  </div>
                  <span className="badge b-gray">{items.length}</span>
                </div>
                {items.map((item) => <FlowCard key={item.visitId} item={item} onOpenTimeline={(it) => setTimelineVisitId(it.visitId)} />)}
                {items.length === 0 && (
                  <div style={{ textAlign: 'center', color: 'var(--g300)', fontSize: 11, padding: 12 }}>--</div>
                )}
              </div>
            </div>
          );
        })}
      </div>

      {timelineVisitId && (
        <TimelineModal visitId={timelineVisitId} onClose={() => setTimelineVisitId(null)} />
      )}
    </div>
  );
}
