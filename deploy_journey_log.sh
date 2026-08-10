#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# The DB migration (visit_journey_events table) has ALREADY been
# applied to both production and training Supabase projects directly
# -- this script only pushes the application code.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/queue"
cat > "app/(main)/queue/page.js" << 'FILEEOF_app__main__queue_page_js'
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
      <div style={{ display: 'flex', gap: 14, overflowX: 'auto', paddingBottom: 8 }}>
        {flow.columns.map((col) => {
          const items = flow.byColumn[col] || [];
          const meta = COLUMN_META[col] || {};
          if (col === 'Checked Out' && items.length === 0) return null;
          return (
            <div key={col} style={{ minWidth: 220, flex: '1 0 220px' }}>
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
FILEEOF_app__main__queue_page_js

mkdir -p "app/(main)/queue"
cat > "app/(main)/queue/actions.js" << 'FILEEOF_app__main__queue_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

function tokenNum(token) {
  return parseInt(token.split('-')[1], 10);
}

// Same IST-boundary approach used in Cash Management / Billing -- a
// plain date string compared against a timestamptz column is
// interpreted at UTC midnight by Postgres, not IST midnight.
function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function istDayBoundsUTC(dateStr) {
  const d = dateStr || todayIST();
  return {
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

export async function getQueues() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  // Excludes every terminal status (not just 'Done') AND scopes to
  // today only -- belt-and-suspenders against anything from a prior
  // day lingering in the live queue view. The real fix for that is
  // Day Closing catching and resolving open entries before the day
  // ends (see getOpenQueueEntriesToday below), but this filter means
  // even a skipped Day Closing can't leak yesterday's patients into
  // today's list.
  const { data: entries, error } = await supabase
    .from('queue_entries')
    .select('*, visits(patients(first_name, last_name, uhid))')
    .not('status', 'in', '(Done,Cancelled,Incomplete)')
    .gte('issued_at', startUTC)
    .lte('issued_at', endUTC)
    .order('issued_at', { ascending: true });

  if (error) return { optometry: [], doctor: [] };

  const optometry = entries.filter((e) => e.department === 'Optometry');
  const doctor = entries.filter((e) => e.department === 'Doctor').sort((a, b) => tokenNum(a.token) - tokenNum(b.token));

  return { optometry, doctor };
}

// Closes a queue entry that can't go through the normal completion path
// (missing diagnosis, missing VA, patient left before being seen, etc.)
// without bypassing those documentation requirements for anyone else.
// Requires a reason -- same audit-trail pattern as cancellations and
// discounts elsewhere in the app.
export async function forceCloseQueueEntry(id, reason) {
  if (!reason || !reason.trim()) return { error: 'A reason is required to force-close a visit.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('queue_entries')
    .update({
      status: 'Incomplete',
      force_close_reason: reason,
      force_closed_by: user?.id || null,
      force_closed_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

// For Day Closing's soft warning -- anything from today (Doctor or
// Optometry) that never reached a terminal status.
export async function getOpenQueueEntriesToday() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data } = await supabase
    .from('queue_entries')
    .select('id, department, token, status, issued_at, visits(patients(first_name, last_name, uhid))')
    .not('status', 'in', '(Done,Cancelled,Incomplete)')
    .gte('issued_at', startUTC)
    .lte('issued_at', endUTC)
    .order('issued_at', { ascending: true });

  return data || [];
}

// Bulk version for Day Closing -- one shared reason applied to every
// still-open entry from today, so the day can close cleanly.
export async function bulkForceCloseQueueEntries(ids, reason) {
  if (!ids || ids.length === 0) return { error: 'No entries to close.' };
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('queue_entries')
    .update({
      status: 'Incomplete',
      force_close_reason: reason,
      force_closed_by: user?.id || null,
      force_closed_at: new Date().toISOString(),
      completed_at: new Date().toISOString(),
    })
    .in('id', ids);

  if (error) return { error: error.message };
  return { success: true, count: ids.length };
}

// ── PATIENT FLOW BOARD ──
// A hospital-wide, live "where is everyone right now" view -- unlike
// getQueues() above (which only drives the Optometry/Doctor call-next
// operator tools), this pulls from every stage a patient passes
// through today and assigns each active visit to a single column so
// staff/doctor can see the whole day's flow and any bottleneck at a
// glance. Reuses status fields each module already maintains rather
// than adding new tracking -- Investigation/Biometry/Dilation status
// for a sent-out patient already lives on the Doctor's own
// queue_entries row (e.g. "Awaiting Investigation & Biometry"), same
// data the old Doctor Queue panel already displayed.
const FLOW_COLUMNS = [
  'Waiting for Optometry', 'With Optometrist', 'Waiting for Doctor', 'With Doctor',
  'Sent Out', 'Billing', 'Pharmacy', 'Checked Out',
];

function computeFlowStage(visit, queueByVisit, invoices, prescriptions, investigations, biometry) {
  if (visit.status === 'Closed') {
    return { column: 'Checked Out', detail: '', since: visit.created_at, unpaid: false };
  }

  const entries = queueByVisit[visit.id] || [];
  const opto = entries.find((e) => e.department === 'Optometry');
  const doc = entries.find((e) => e.department === 'Doctor');

  if (!doc) {
    // No token issued yet is not expected in normal flow (a token is
    // issued the moment a patient is registered) -- treat it as still
    // waiting for Optometry rather than adding a separate column for
    // what should be a near-instant, rarely-visible state.
    if (!opto) return { column: 'Waiting for Optometry', detail: '', since: visit.created_at, unpaid: false };
    if (opto.status === 'Calling') return { column: 'With Optometrist', detail: 'Called in', since: opto.called_at || opto.issued_at, unpaid: false };
    return { column: 'Waiting for Optometry', detail: '', since: opto.issued_at, unpaid: false };
  }

  if (doc.status === 'Waiting') return { column: 'Waiting for Doctor', detail: '', since: doc.issued_at, unpaid: false };
  if (doc.status === 'Ready for Review') return { column: 'Waiting for Doctor', detail: 'Ready for review', since: doc.sent_out_at || doc.issued_at, unpaid: false };
  if (doc.status === 'In Consultation') return { column: 'With Doctor', detail: '', since: doc.called_at || doc.issued_at, unpaid: false };

  if (doc.status?.startsWith('Awaiting')) {
    const myInv = investigations.filter((i) => i.visit_id === visit.id);
    const myBio = biometry.filter((b) => b.visit_id === visit.id);

    // Payment can happen before OR after the actual investigation/
    // biometry -- some patients pay first then go in, others go
    // straight in and settle billing after. The distinguishing
    // signal is whether the item has actually STARTED yet, not
    // whether it's paid: "Ordered"/"Awaiting Biometry" and still
    // unpaid means they're stuck at billing before it can begin;
    // once it's "In Progress" or further, they've physically moved
    // on regardless of payment, so keep them in Sent Out and just
    // flag it unpaid for front office to catch.
    const notYetStarted = (i) => i.status === 'Ordered';
    const notYetStartedBio = (b) => b.status === 'Awaiting Biometry';
    const blockedOnBilling =
      myInv.some((i) => notYetStarted(i) && i.billing_status === 'Pending') ||
      myBio.some((b) => notYetStartedBio(b) && b.billing_status === 'Pending');
    const startedButUnpaid =
      myInv.some((i) => !notYetStarted(i) && i.billing_status === 'Pending') ||
      myBio.some((b) => !notYetStartedBio(b) && b.billing_status === 'Pending');

    if (blockedOnBilling) return { column: 'Billing', detail: doc.status.replace('Awaiting ', ''), since: doc.sent_out_at || doc.issued_at, unpaid: false };
    return { column: 'Sent Out', detail: doc.status.replace('Awaiting ', ''), since: doc.sent_out_at || doc.issued_at, unpaid: startedButUnpaid };
  }

  if (doc.status === 'Done') {
    const invPending = invoices.some((i) => i.visit_id === visit.id && (i.status === 'Pending' || i.status === 'Partial'));
    if (invPending) return { column: 'Billing', detail: '', since: doc.completed_at || doc.issued_at, unpaid: false };

    const rxPending = prescriptions.some((r) => r.visit_id === visit.id && r.status === 'Sent');
    if (rxPending) return { column: 'Pharmacy', detail: '', since: doc.completed_at || doc.issued_at, unpaid: false };

    return { column: 'Checked Out', detail: '', since: doc.completed_at || doc.issued_at, unpaid: false };
  }

  return { column: 'Waiting for Doctor', detail: doc.status, since: doc.issued_at, unpaid: false };
}

export async function getPatientFlow() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [
    { data: visits },
    { data: queueEntries },
    { data: invoices },
    { data: prescriptionsRaw },
    { data: investigationsRaw },
    { data: biometry },
  ] = await Promise.all([
    supabase.from('visits')
      .select('id, visit_type, priority, status, created_at, closed_at, patients(first_name, last_name, uhid), profiles:doctor_id(full_name)')
      .neq('status', 'Cancelled')
      .gte('created_at', startUTC).lte('created_at', endUTC)
      .order('created_at', { ascending: true }),
    supabase.from('queue_entries')
      .select('visit_id, department, status, token, issued_at, called_at, sent_out_at, completed_at')
      .gte('issued_at', startUTC).lte('issued_at', endUTC),
    supabase.from('invoices').select('visit_id, status')
      .neq('status', 'Cancelled')
      .gte('created_at', startUTC).lte('created_at', endUTC),
    supabase.from('prescriptions').select('status, encounters(visit_id)')
      .gte('created_at', startUTC).lte('created_at', endUTC),
    supabase.from('investigation_orders').select('status, billing_status, encounters(visit_id)')
      .neq('status', 'Cancelled')
      .gte('created_at', startUTC).lte('created_at', endUTC),
    supabase.from('biometry_records').select('visit_id, status, billing_status')
      .neq('status', 'Cancelled')
      .gte('created_at', startUTC).lte('created_at', endUTC),
  ]);

  if (!visits) return { columns: FLOW_COLUMNS, byColumn: {} };

  const queueByVisit = {};
  (queueEntries || []).forEach((e) => {
    if (!queueByVisit[e.visit_id]) queueByVisit[e.visit_id] = [];
    queueByVisit[e.visit_id].push(e);
  });

  const prescriptions = (prescriptionsRaw || []).map((r) => ({ status: r.status, visit_id: r.encounters?.visit_id }));
  const investigations = (investigationsRaw || []).map((i) => ({ status: i.status, billing_status: i.billing_status, visit_id: i.encounters?.visit_id }));

  const byColumn = {};
  FLOW_COLUMNS.forEach((c) => { byColumn[c] = []; });

  visits.forEach((v) => {
    const stage = computeFlowStage(v, queueByVisit, invoices || [], prescriptions, investigations, biometry || []);
    const p = v.patients;
    byColumn[stage.column].push({
      visitId: v.id,
      patientName: p ? `${p.first_name} ${p.last_name}` : 'Unknown',
      uhid: p?.uhid,
      doctorName: v.profiles?.full_name,
      priority: v.priority,
      visitType: v.visit_type,
      detail: stage.detail,
      since: stage.since,
      unpaid: stage.unpaid,
      visitSince: v.created_at,
    });
  });

  // Longest-waiting-overall first within each column, so whoever's
  // been in the building longest surfaces at the top -- that's
  // usually who needs someone to go check on them.
  FLOW_COLUMNS.forEach((c) => {
    byColumn[c].sort((a, b) => new Date(a.visitSince) - new Date(b.visitSince));
  });

  return { columns: FLOW_COLUMNS, byColumn };
}

// ── PATIENT TIMELINE ──
// The chronological story for one visit. Registration, token issue,
// and invoice-raised moments come from their existing single-row
// timestamps (fine, since those only ever happen once per visit).
// Everything that can legitimately happen MORE than once in one visit
// -- being called to the doctor, being sent out, coming back -- is
// read from visit_journey_events instead, so a second or third round
// through the same stage shows up as its own entry rather than
// overwriting the first.
//
// One honest limitation: events only exist from the point this
// logging was added onward. A visit already in progress when this
// deployed will show granular detail only for whatever happens next,
// not for steps that already occurred before the deploy.
const STAGE_LABELS = {
  optometry_called: { label: 'Called in to Optometry', icon: 'ti-eye-check', color: 'var(--teal)' },
  optometry_completed: { label: 'Optometry completed', icon: 'ti-circle-check', color: 'var(--teal)' },
  doctor_called: { label: 'Called in to Doctor', icon: 'ti-stethoscope', color: 'var(--blue)' },
  doctor_completed: { label: 'Doctor consultation completed', icon: 'ti-circle-check', color: 'var(--blue)' },
  sent_for_investigation: { label: 'Sent for Investigation', icon: 'ti-route', color: 'var(--amber)' },
  sent_for_biometry: { label: 'Sent for Biometry', icon: 'ti-route', color: 'var(--purple)' },
  sent_for_dilation: { label: 'Sent for Dilation (drops given)', icon: 'ti-droplet', color: 'var(--amber)' },
  investigation_started: { label: 'Investigation started', icon: 'ti-player-play', color: 'var(--amber)' },
  investigation_completed: { label: 'Investigation completed', icon: 'ti-circle-check', color: 'var(--amber)' },
  biometry_completed: { label: 'Biometry completed', icon: 'ti-circle-check', color: 'var(--purple)' },
  ready_for_doctor_review: { label: 'Back and ready for doctor review', icon: 'ti-corner-down-left', color: 'var(--blue)' },
  payment_collected: { label: 'Payment collected', icon: 'ti-cash', color: 'var(--red)' },
  pharmacy_dispensed: { label: 'Medicine dispensed', icon: 'ti-pill', color: 'var(--teal)' },
};

function minutesBetween(a, b) {
  return Math.max(0, Math.round((new Date(b) - new Date(a)) / 60000));
}

// Walks the sorted event list and buckets elapsed time into named
// stages, summing across repeats (e.g. two separate trips to the
// doctor both count toward "With Doctor"). "now" is used as the open
// end for whichever stage the patient is currently sitting in.
function computeStageBreakdown(events, nowIso) {
  const buckets = {};
  const add = (label, mins) => { buckets[label] = (buckets[label] || 0) + mins; };

  // Pending starts: the last time we entered a stage that's waiting
  // to be closed off by its matching end event.
  let pending = {};

  for (const ev of events) {
    switch (ev.type) {
      case 'opto_issued': pending.waitingOptometry = ev.time; break;
      case 'optometry_called':
        if (pending.waitingOptometry) { add('Waiting for Optometry', minutesBetween(pending.waitingOptometry, ev.time)); pending.waitingOptometry = null; }
        pending.withOptometrist = ev.time;
        break;
      case 'optometry_completed':
        if (pending.withOptometrist) { add('With Optometrist', minutesBetween(pending.withOptometrist, ev.time)); pending.withOptometrist = null; }
        pending.waitingDoctor = ev.time;
        break;
      case 'doctor_called':
        if (pending.waitingDoctor) { add('Waiting for Doctor', minutesBetween(pending.waitingDoctor, ev.time)); pending.waitingDoctor = null; }
        pending.withDoctor = ev.time;
        break;
      case 'sent_for_investigation':
        if (pending.withDoctor) { add('With Doctor', minutesBetween(pending.withDoctor, ev.time)); pending.withDoctor = null; }
        pending.waitingInvestigation = ev.time;
        break;
      case 'investigation_started':
        if (pending.waitingInvestigation) { add('Waiting for Investigation', minutesBetween(pending.waitingInvestigation, ev.time)); pending.waitingInvestigation = null; }
        pending.inInvestigation = ev.time;
        break;
      case 'investigation_completed':
        if (pending.inInvestigation) { add('In Investigation', minutesBetween(pending.inInvestigation, ev.time)); pending.inInvestigation = null; }
        else if (pending.waitingInvestigation) { add('Waiting for Investigation', minutesBetween(pending.waitingInvestigation, ev.time)); pending.waitingInvestigation = null; }
        pending.waitingDoctor = ev.time;
        break;
      case 'sent_for_biometry':
        if (pending.withDoctor) { add('With Doctor', minutesBetween(pending.withDoctor, ev.time)); pending.withDoctor = null; }
        pending.inBiometry = ev.time;
        break;
      case 'biometry_completed':
        if (pending.inBiometry) { add('Biometry (wait + procedure)', minutesBetween(pending.inBiometry, ev.time)); pending.inBiometry = null; }
        pending.waitingDoctor = ev.time;
        break;
      case 'sent_for_dilation':
        // Counter starts the instant the doctor marks it -- this IS
        // that moment, no separate "started" signal exists for
        // dilation (it's drops administered on the spot, not a
        // tracked procedure with its own module).
        if (pending.withDoctor) { add('With Doctor', minutesBetween(pending.withDoctor, ev.time)); pending.withDoctor = null; }
        pending.inDilation = ev.time;
        break;
      case 'ready_for_doctor_review':
        if (pending.inDilation) { add('Dilation wait', minutesBetween(pending.inDilation, ev.time)); pending.inDilation = null; }
        if (pending.waitingInvestigation) { add('Waiting for Investigation', minutesBetween(pending.waitingInvestigation, ev.time)); pending.waitingInvestigation = null; }
        if (pending.inBiometry) { add('Biometry (wait + procedure)', minutesBetween(pending.inBiometry, ev.time)); pending.inBiometry = null; }
        pending.waitingDoctor = ev.time;
        break;
      case 'doctor_completed':
        if (pending.withDoctor) { add('With Doctor', minutesBetween(pending.withDoctor, ev.time)); pending.withDoctor = null; }
        pending.waitingBilling = ev.time;
        pending.waitingPharmacy = ev.time;
        break;
      case 'payment_collected':
        if (pending.waitingBilling) { add('Billing', minutesBetween(pending.waitingBilling, ev.time)); pending.waitingBilling = null; }
        break;
      case 'pharmacy_dispensed':
        if (pending.waitingPharmacy) { add('Pharmacy', minutesBetween(pending.waitingPharmacy, ev.time)); pending.waitingPharmacy = null; }
        break;
      default: break;
    }
  }

  // Close out whatever's still open using "now" as the end -- this is
  // what makes a currently-waiting patient's bucket grow live rather
  // than only appearing once the stage finishes.
  const openLabels = {
    waitingOptometry: 'Waiting for Optometry', withOptometrist: 'With Optometrist',
    waitingDoctor: 'Waiting for Doctor', withDoctor: 'With Doctor',
    waitingInvestigation: 'Waiting for Investigation', inInvestigation: 'In Investigation',
    inBiometry: 'Biometry (wait + procedure)', inDilation: 'Dilation wait',
    waitingBilling: 'Billing', waitingPharmacy: 'Pharmacy',
  };
  Object.entries(pending).forEach(([key, startTime]) => {
    if (startTime) add(openLabels[key], minutesBetween(startTime, nowIso));
  });

  return Object.entries(buckets)
    .map(([label, minutes]) => ({ label, minutes }))
    .filter((b) => b.minutes > 0)
    .sort((a, b) => b.minutes - a.minutes);
}

export async function getPatientTimeline(visitId) {
  const supabase = await createClient();

  const [
    { data: visit },
    { data: queueEntries },
    { data: journeyEvents },
    { data: invoices },
    { data: prescriptions },
  ] = await Promise.all([
    supabase.from('visits').select('created_at, closed_at, patients(first_name, last_name, uhid)').eq('id', visitId).single(),
    supabase.from('queue_entries').select('department, status, token, issued_at').eq('visit_id', visitId),
    supabase.from('visit_journey_events').select('event_type, event_time, meta').eq('visit_id', visitId).order('event_time', { ascending: true }),
    supabase.from('invoices').select('net, purpose, status, created_at').eq('visit_id', visitId).neq('status', 'Cancelled'),
    supabase.from('prescriptions').select('drug_name, status, sent_at, encounters!inner(visit_id)').eq('encounters.visit_id', visitId),
  ]);

  if (!visit) return { patientName: '', uhid: '', events: [], breakdown: [] };

  const displayEvents = [];
  const push = (time, label, icon, color) => { if (time) displayEvents.push({ time, label, icon, color }); };

  push(visit.created_at, 'Registered / visit opened', 'ti-door-enter', 'var(--g500)');

  const opto = (queueEntries || []).find((e) => e.department === 'Optometry');
  const doc = (queueEntries || []).find((e) => e.department === 'Doctor');
  if (opto) push(opto.issued_at, `Optometry token issued (${opto.token})`, 'ti-ticket', 'var(--g500)');
  if (doc) push(doc.issued_at, `Doctor token issued (${doc.token})`, 'ti-ticket', 'var(--g500)');

  (journeyEvents || []).forEach((ev) => {
    const meta = STAGE_LABELS[ev.event_type];
    if (meta) push(ev.event_time, meta.label, meta.icon, meta.color);
  });

  (invoices || []).forEach((i) => {
    push(i.created_at, `Invoice raised (${i.purpose}): Rs ${Number(i.net).toLocaleString('en-IN')}`, 'ti-receipt', 'var(--red)');
  });

  (prescriptions || []).forEach((r) => {
    push(r.sent_at, `Sent to Pharmacy: ${r.drug_name}`, 'ti-pill', 'var(--teal)');
  });

  push(visit.closed_at, 'Visit closed', 'ti-door-exit', 'var(--green)');

  displayEvents.sort((a, b) => new Date(a.time) - new Date(b.time));

  // Feed the breakdown calculator the raw typed sequence (token
  // issue + journey events only -- invoices/prescriptions are inputs
  // to Billing/Pharmacy timing, not separate stage markers).
  const breakdownInput = [];
  if (opto) breakdownInput.push({ type: 'opto_issued', time: opto.issued_at });
  (journeyEvents || []).forEach((ev) => breakdownInput.push({ type: ev.event_type, time: ev.event_time }));
  breakdownInput.sort((a, b) => new Date(a.time) - new Date(b.time));
  const breakdown = computeStageBreakdown(breakdownInput, visit.closed_at || new Date().toISOString());

  const p = visit.patients;
  return {
    patientName: p ? `${p.first_name} ${p.last_name}` : 'Unknown',
    uhid: p?.uhid,
    events: displayEvents,
    breakdown,
  };
}

// ── OPTOMETRY ──
export async function optometryCallNext() {
  const supabase = await createClient();
  const { data: waiting } = await supabase
    .from('queue_entries')
    .select('*')
    .eq('department', 'Optometry')
    .eq('status', 'Waiting');

  if (!waiting || waiting.length === 0) return { error: 'No one waiting in Optometry.' };

  const next = waiting.sort((a, b) => tokenNum(a.token) - tokenNum(b.token))[0];
  return optometryCallSpecific(next.id);
}

export async function optometryCallSpecific(id) {
  const supabase = await createClient();

  // Only one patient can be "Calling" at a time -- calling someone new
  // resets whoever was previously being called back to Waiting.
  await supabase
    .from('queue_entries')
    .update({ status: 'Waiting' })
    .eq('department', 'Optometry')
    .eq('status', 'Calling');

  const { data: entry, error } = await supabase
    .from('queue_entries')
    .update({ status: 'Calling', called_at: new Date().toISOString() })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, entry?.visit_id, 'optometry_called');
  return { success: true };
}

export async function optometryComplete(id) {
  const supabase = await createClient();
  const { data: entryBefore } = await supabase.from('queue_entries').select('visit_id').eq('id', id).single();
  const { error } = await supabase.rpc('optometry_complete', { p_queue_entry_id: id });
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, entryBefore?.visit_id, 'optometry_completed');
  return { success: true };
}

// ── DOCTOR ──
export async function doctorCallNext() {
  const supabase = await createClient();
  const { data: available } = await supabase
    .from('queue_entries')
    .select('*')
    .eq('department', 'Doctor')
    .in('status', ['Waiting', 'Ready for Review']);

  if (!available || available.length === 0) return { error: 'No one available to call.' };

  const next = available.sort((a, b) => tokenNum(a.token) - tokenNum(b.token))[0];
  return doctorCallSpecific(next.id);
}

export async function doctorCallSpecific(id) {
  const supabase = await createClient();
  const { data: entry, error } = await supabase
    .from('queue_entries')
    .update({ status: 'In Consultation', called_at: new Date().toISOString() })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, entry?.visit_id, 'doctor_called');
  return { success: true };
}

// Lets the doctor pull a patient straight out of Optometry's waiting
// list and into consultation, for cases where the normal Optometry
// workup isn't needed first (e.g. a quick post-op or referral review).
// Reuses the exact same handoff mechanism Optometry itself uses when it
// finishes normally, just triggered from the other end.
export async function doctorCallDirect(optometryEntryId) {
  const supabase = await createClient();
  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', optometryEntryId).eq('department', 'Optometry').single();
  if (!entry) return { error: 'Queue entry not found in Optometry.' };

  const { error: rpcError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: optometryEntryId });
  if (rpcError) return { error: rpcError.message };
  await logJourneyEvent(supabase, entry.visit_id, 'optometry_completed');

  const { data: doctorEntry } = await supabase
    .from('queue_entries').select('id')
    .eq('visit_id', entry.visit_id).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!doctorEntry) return { error: 'Could not route patient to Doctor queue.' };

  return doctorCallSpecific(doctorEntry.id);
}

export async function doctorComplete(id) {
  const supabase = await createClient();
  const { data: entry, error } = await supabase
    .from('queue_entries')
    .update({ status: 'Done', completed_at: new Date().toISOString() })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, entry?.visit_id, 'doctor_completed');
  return { success: true };
}

// Order matters for a stable, predictable compound string regardless
// of which button the doctor clicked first/second.
const SENDOUT_ORDER = ['Dilation', 'Investigation', 'Biometry'];
const SENDOUT_EVENT = { Dilation: 'sent_for_dilation', Investigation: 'sent_for_investigation', Biometry: 'sent_for_biometry' };

export async function doctorSendOut(id, kind) {
  const supabase = await createClient();
  const newLabel = kind === 'dilate' ? 'Dilation' : kind === 'biometry' ? 'Biometry' : 'Investigation';

  // A patient can genuinely need to go two places at once (e.g. sent
  // for an OCT and for Biometry in the same consultation) -- a single
  // status field can't hold two independent statuses, so rather than
  // the second "Send" silently overwriting the first and making the
  // patient vanish from that queue's tracking, combine them into one
  // compound status ("Awaiting Investigation & Biometry"). Each
  // destination's own queue (Investigation, Biometry) doesn't actually
  // depend on this field at all -- it's only used for the doctor's
  // "who's out and where" tracker and Front Office's availability flag,
  // so a compound label there is enough; nothing needs to parse it back
  // into a single value.
  //
  // The compound status/sent_out_at column can only ever hold ONE
  // timestamp though, so if Investigation and Biometry are sent
  // separately a few minutes apart, the column silently loses the
  // first one. The journey log below is what actually gives each
  // destination its own accurate timer -- e.g. Dilation's clock
  // starts the exact moment THIS call happens, not whenever the last
  // of a compound send-out was recorded.
  const { data: current } = await supabase.from('queue_entries').select('visit_id, status').eq('id', id).single();
  const existingLabels = (current?.status || '').startsWith('Awaiting')
    ? current.status.replace('Awaiting ', '').split(' & ')
    : [];
  const combined = new Set(existingLabels.filter((l) => SENDOUT_ORDER.includes(l)));
  combined.add(newLabel);
  const status = 'Awaiting ' + SENDOUT_ORDER.filter((l) => combined.has(l)).join(' & ');

  const { error } = await supabase
    .from('queue_entries')
    .update({ status, sent_out_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, current?.visit_id, SENDOUT_EVENT[newLabel]);
  return { success: true };
}

export async function doctorMarkReady(id) {
  const supabase = await createClient();
  const { data: entry, error } = await supabase
    .from('queue_entries')
    .update({ status: 'Ready for Review' })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, entry?.visit_id, 'ready_for_doctor_review');
  return { success: true };
}


FILEEOF_app__main__queue_actions_js

mkdir -p "app/(main)/investigation"
cat > "app/(main)/investigation/actions.js" << 'FILEEOF_app__main__investigation_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

// ── QUEUE (Ordered + In Progress, grouped by visit) plus today's KPI
// stats for the Queue screen's summary cards. ──
export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data: pending, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return { groups: [], stats: { ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 } };

  // Payment status is about the invoice, not just whether Front Office
  // ticked "billed" -- an invoice can be raised and still unpaid, so
  // this looks at the actual invoice net/paid amounts.
  const invoiceIds = [...new Set((pending || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  const groups = {};
  (pending || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient: io.encounters.visits.patients, items: [] };
    }
    groups[visitId].items.push({ ...io, kind: 'investigation', payment: paymentInfo(io) });
  });

  // Biometry is structurally its own thing (device measurements, IOL
  // formulas, surgeon approval -- not a text-field investigation), so it
  // stays in its own table and dedicated workspace. But per the doctor's
  // actual usage, it belongs in the same "what's outstanding for this
  // patient" queue as any other investigation, not off in a separate
  // module people forget to check. Approved/Cancelled are done, so left
  // out here the same way Available/Cancelled investigations are.
  const { data: bio } = await supabase
    .from('biometry_records')
    .select('*, visits(id, patients(first_name, last_name, uhid))')
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .order('created_at', { ascending: true });

  const bioInvoiceIds = [...new Set((bio || []).map((r) => r.invoice_id).filter(Boolean))];
  let bioInvoiceMap = invoiceMap;
  if (bioInvoiceIds.length > 0) {
    const { data: moreInvoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', bioInvoiceIds);
    (moreInvoices || []).forEach((inv) => { bioInvoiceMap[inv.id] = inv; });
  }
  function bioPaymentInfo(r) {
    if (r.billing_status !== 'Billed' || !r.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = bioInvoiceMap[r.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  (bio || []).forEach((r) => {
    const visitId = r.visit_id;
    const patient = r.visits?.patients;
    if (!visitId || !patient) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient, items: [] };
    }
    groups[visitId].items.push({
      id: r.id, kind: 'biometry', name: 'Biometry', eye: r.surgical_eye || 'OU', priority: 'Routine',
      status: r.status, created_at: r.created_at, payment: bioPaymentInfo(r),
    });
  });

  const ordered = (pending || []).filter((i) => i.status === 'Ordered').length;
  const inProgress = (pending || []).filter((i) => i.status === 'In Progress').length;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: todayOrders } = await supabase
    .from('investigation_orders')
    .select('id, status, verified_at, created_at')
    .gte('created_at', todayStart.toISOString());

  const availableToday = (todayOrders || []).filter((o) => o.status === 'Available' && o.verified_at && new Date(o.verified_at) >= todayStart).length;
  const totalToday = (todayOrders || []).length;

  return { groups: Object.values(groups), stats: { ordered, inProgress, availableToday, totalToday } };
}

// ── TODAY'S INVESTIGATIONS -- for the Dashboard widget (patient, test
// name, billing status, view/print). IST-bounded so "today" matches
// the front desk's actual working day rather than UTC midnight. ──
export async function getTodaysInvestigations() {
  const supabase = await createClient();
  const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIST}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIST}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, visits(patients(first_name, last_name, uhid)))')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .order('created_at', { ascending: false });
  if (error) return [];

  const invoiceIds = [...new Set((data || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  return (data || [])
    .filter((io) => io.encounters?.visits?.patients)
    .map((io) => ({
      id: io.id,
      name: io.name,
      eye: io.eye,
      status: io.status,
      patient: io.encounters.visits.patients,
      payment: paymentInfo(io),
    }));
}


// ── WORKSPACE: single order detail, with patient/doctor context ──
export async function getInvestigationDetail(id, viewOnly) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)))')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  // Opening the order to work on it (not just viewing) is the "start" --
  // no separate button needed. Timestamped with whoever opened it.
  if (!viewOnly && data.status === 'Ordered') {
    const { data: userData } = await supabase.auth.getUser();
    const startedAt = new Date().toISOString();
    await supabase.from('investigation_orders').update({
      status: 'In Progress', started_at: startedAt, started_by: userData?.user?.id || null,
    }).eq('id', id);
    data.status = 'In Progress';
    data.started_at = startedAt;
    data.started_by = userData?.user?.id || null;
  }

  let doctorName = '--';
  if (data.encounters?.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.encounters.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  let startedByName = null;
  if (data.started_by) {
    const { data: tech } = await supabase.from('profiles').select('full_name').eq('id', data.started_by).maybeSingle();
    startedByName = tech?.full_name || null;
  }

  return { order: data, doctorName, startedByName };
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({ status: 'In Progress' })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_started', { name: order?.name });
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later, patient stays in the queue.
export async function saveInvestigationDraft(id, resultData, remarks) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('investigation_orders')
    .update({ result_data: resultData, result_notes: remarks })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, resultData, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_data: resultData,
      result_notes: remarks || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Verification is the gate between "technically done" and "visible to
// the doctor" -- status jumps straight to Available once every checklist
// item is confirmed (there's no separate persisted "Verified" state;
// it's a visual timeline step on the way to Available).
// Same "combine, don't overwrite" logic doctorSendOut uses -- a patient
// can be Awaiting more than one thing at once, so resolving Investigation
// should only clear that part, not silently blow away Biometry/Dilation
// if they're still pending.
async function resolveAwaitingPart(supabase, visitId, part) {
  if (!visitId) return;
  const { data: entry } = await supabase
    .from('queue_entries').select('id, status')
    .eq('visit_id', visitId).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!entry || !entry.status?.startsWith('Awaiting')) return;

  const remaining = entry.status.replace('Awaiting ', '').split(' & ').filter((l) => l !== part);
  const newStatus = remaining.length > 0 ? `Awaiting ${remaining.join(' & ')}` : 'Ready for Review';
  await supabase.from('queue_entries').update({ status: newStatus }).eq('id', entry.id);
}

export async function verifyInvestigation(id, checklist) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const allChecked = Object.values(checklist).every(Boolean) && Object.keys(checklist).length > 0;
  if (!allChecked) return { error: 'All verification items must be checked before verifying.' };

  const { data: order } = await supabase.from('investigation_orders').select('name, encounter_id, encounters(visit_id)').eq('id', id).maybeSingle();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Available',
      verification_checklist: checklist,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };

  await resolveAwaitingPart(supabase, order?.encounters?.visit_id, 'Investigation');
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_completed', { name: order?.name });

  return { success: true };
}

export async function markUnableToPerform(id, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  const { error } = await supabase
    .from('investigation_orders')
    .update({ status: 'Cancelled', unable_reason: reason })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every investigation lands here the moment it's ordered from
// Consultation, regardless of lab status -- Front Office bills as soon
// as the doctor orders it, it doesn't wait on the lab. Grouped by visit
// the same way the lab's own Queue screen is, so it reads the same way.
export async function getPendingInvestigationBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    const visit = io.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

async function setInvestigationBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationDenied(id, note) {
  return setInvestigationBillingStatus(id, 'Denied', note);
}

export async function markInvestigationDeferred(id, note) {
  return setInvestigationBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetInvestigationBilling(id) {
  return setInvestigationBillingStatus(id, 'Pending', null);
}

// ── HISTORY ──
// Every investigation ever ordered, regardless of status -- filtering
// happens client-side (patient/type dropdowns) since a single-hospital
// dataset is small enough that a broad fetch is simpler and fast enough,
// same approach the rest of this module already takes.
export async function getInvestigationHistory(fromDate, toDate) {
  const supabase = await createClient();
  let query = supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(id, first_name, last_name, uhid)))')
    .order('created_at', { ascending: false })
    .limit(500);

  // Applied before the row cap so a date range reaches further back
  // than the default "most recent 500" would otherwise allow.
  if (fromDate) query = query.gte('created_at', `${fromDate}T00:00:00`);
  if (toDate) query = query.lte('created_at', `${toDate}T23:59:59`);

  const { data, error } = await query;
  if (error) return { error: error.message };

  const doctorIds = (data || []).map((o) => o.encounters?.doctor_id).filter(Boolean);
  const staffIds = (data || []).flatMap((o) => [o.completed_by, o.verified_by]).filter(Boolean);
  const allIds = [...new Set([...doctorIds, ...staffIds])];

  let profileMap = {};
  if (allIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', allIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }

  const rows = (data || []).map((o) => ({
    ...o,
    doctorName: profileMap[o.encounters?.doctor_id] || '--',
    performedByName: profileMap[o.verified_by] || profileMap[o.completed_by] || '--',
  }));

  return { rows };
}

// ── LONGITUDINAL COMPARISON ──
export async function searchPatientsForInvestigation(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getInvestigationComparisonData(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters!inner(id, visit_id, visits!inner(id, patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .in('status', ['Completed', 'Available'])
    .order('created_at', { ascending: true });
  if (error) return { error: error.message };
  return { rows: data || [] };
}

// ── REPORTS ──
export async function getInvestigationReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const fromIso = `${fromDate}T00:00:00`;
  const toIso = `${toDate}T23:59:59`;

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, doctor_id, visits(id, patients(first_name, last_name, uhid)))')
    .gte('created_at', fromIso)
    .lte('created_at', toIso)
    .order('created_at', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  const doctorIds = [...new Set((data || []).map((o) => o.encounters?.doctor_id).filter(Boolean))];
  let profileMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const doctorName = (o) => profileMap[o.encounters?.doctor_id] || '--';
  const patientName = (o) => {
    const p = o.encounters?.visits?.patients;
    return p ? `${p.first_name} ${p.last_name} (${p.uhid})` : '--';
  };

  if (reportId === 'register') {
    return {
      title: 'Daily Investigation Register',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: (data || []).map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'type_summary') {
    const counts = {};
    (data || []).forEach((o) => {
      const n = (o.name || '').toLowerCase();
      const type = n.includes('oct') ? 'OCT' : (n.includes('visual field') || n.includes(' vf')) ? 'Visual Field' : n.includes('fundus') ? 'Fundus Photography' : 'External Report';
      counts[type] = (counts[type] || 0) + 1;
    });
    return {
      title: 'Investigation Type Summary',
      headers: ['Type', 'Count'],
      rows: Object.entries(counts).map(([type, count]) => ({ cols: [type, count] })),
    };
  }

  if (reportId === 'pending') {
    const pending = (data || []).filter((o) => o.status === 'Ordered' || o.status === 'In Progress');
    return {
      title: 'Pending Investigations',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: pending.map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'quality') {
    const cancelled = (data || []).filter((o) => o.status === 'Cancelled');
    const total = (data || []).length;
    const rows = cancelled.map((o) => ({
      cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.unable_reason || '--'],
    }));
    rows.push({ cols: [`Total ordered in period: ${total}`, `Unable to perform: ${cancelled.length}`, '', ''] });
    return {
      title: 'Quality Report -- Unable to Perform',
      headers: ['Date', 'Patient', 'Investigation', 'Reason'],
      rows,
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

FILEEOF_app__main__investigation_actions_js

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/actions.js" << 'FILEEOF_app__main__biometry_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const MEAS_FIELDS = ['axl', 'k1', 'k2', 'acd', 'lt', 'wtw'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──
// Reads biometry_records directly (not queue_entries.status), same
// architecture as the Investigation Queue. This is deliberate: if it
// depended on queue_entries.status, sending a patient for both an
// investigation and Biometry in the same consultation would risk one
// overwriting the other and the patient silently vanishing from this
// screen. Reading the record itself means it always shows up here
// regardless of whatever else the patient's front-desk status says.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.visits)
    .map((r) => ({
      recordId: r.id,
      visitId: r.visit_id,
      encounterId: r.encounter_id,
      doctorId: r.visits?.doctor_id,
      patient: r.visits?.patients,
      status: r.status,
      procedureName: r.procedure_name,
      surgicalEye: r.surgical_eye,
    }));

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: approvedToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Approved')
    .gte('approved_at', todayStart.toISOString());

  const stats = {
    awaiting: rows.filter((r) => r.status === 'Awaiting Biometry').length,
    measured: rows.filter((r) => r.status === 'Measured').length,
    calculated: rows.filter((r) => r.status === 'Calculated').length,
    approvedToday: (approvedToday || []).length,
  };

  return { rows, stats };
}

// Finds an in-flight record for this visit, or creates a fresh one --
// same lazy-create pattern as the encounter/optometry assessment.
export async function getOrCreateBiometryRecord(visitId, encounterId) {
  const supabase = await createClient();

  // Reuse ANY existing non-cancelled record for this visit -- including
  // Approved ones. Previously this only matched in-flight statuses, so
  // reopening an already-approved patient (e.g. from the Queue, since
  // queue_entries.status doesn't change on approval) silently created a
  // second, blank record for the same visit.
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();

  // Procedure + eye come from the surgical case (set when the doctor
  // marked the patient for surgery) rather than being re-typed by hand
  // in Biometry -- one source of truth, no risk of the two drifting
  // apart. Falls back to blank only if biometry is genuinely being done
  // before any surgical case exists yet for this visit.
  const { data: surgicalCase } = await supabase
    .from('surgical_cases')
    .select('procedure_name, eye')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({
      visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null,
      procedure_name: surgicalCase?.procedure_name || null,
      surgical_eye: surgicalCase?.eye === 'OD' ? 'RE' : surgicalCase?.eye === 'OS' ? 'LE' : surgicalCase?.eye === 'OU' ? 'Both' : null,
    })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)), master_iol_catalog(brand, model, manufacturer)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  let surgeonName = '--';
  if (data.surgeon_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.surgeon_id).maybeSingle();
    surgeonName = doc?.full_name || '--';
  }

  return { record: data, surgeonName };
}

// Sets/updates the procedure + surgical eye for this record -- captured
// here rather than assumed from elsewhere, since Biometry may be the
// first place this gets confirmed with the technician.
export async function setBiometrySurgicalDetails(id, procedureName, surgicalEye) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ procedure_name: procedureName, surgical_eye: surgicalEye, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// BR-BIO-002: only verified measurements may be used for calculation.
// AUTO-BIO-001: verification is what triggers calculation eligibility --
// there's no separate persisted "Measured" state in practice, mirroring
// the source workflow (jumps straight to Calculated).
export async function verifyBiometryMeasurements(id, measurements, surgicalEye, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!surgicalEye) return { error: 'Set the surgical eye before verifying.' };

  const eyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  if (!eyeKey) return { error: 'Surgical eye must be RE or LE to verify (OU not supported for a single IOL calculation).' };

  // Each eye can now hold multiple tagged readings (e.g. Manual A-Scan
  // AND an optical biometer, when both were used) -- verification just
  // needs at least ONE complete reading for the surgical eye, not every
  // reading filled in.
  const eyeSets = Array.isArray(measurements[eyeKey]) ? measurements[eyeKey] : [];
  const completeSet = eyeSets.find((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim()));
  if (!completeSet) {
    return { error: `At least one complete reading (AXL, K1, K2, ACD) is required for the surgical eye (${surgicalEye}) before verification.` };
  }

  // Summarize which device(s) actually produced complete readings for
  // the surgical eye, for a readable record -- e.g. "Manual A-Scan,
  // ZEISS IOLMaster 700" if both were used.
  const devicesUsed = [...new Set(
    eyeSets.filter((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim())).map((set) => set.device)
  )];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Calculated',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id')
    .single();

  if (error) return { error: error.message };
  await logJourneyEvent(supabase, data?.visit_id, 'biometry_completed');
  return { success: true };
}

// ── IOL CALCULATION ──
// Formula results are NOT computed by this system -- real IOL power
// formulas (Barrett Universal II, SRK/T, Haigis, etc.) are complex and
// in some cases proprietary. These numbers come from the biometry
// device's own built-in formula software (the same printout captured
// in Device Reports); staff transcribes each formula's result here so
// the surgeon has a structured side-by-side comparison to choose from.
export async function saveFormulaResults(id, targetRefraction, formulaResults, selectedFormula) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      target_refraction: targetRefraction,
      formula_results: formulaResults,
      selected_formula: selectedFormula,
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGEON APPROVAL ──
// BR-BIO-003: only surgeon sign-off finalizes a plan (soft UX check
// only -- see note in the Approval tab; not DB-enforced by role).
// BR-BIO-005: approval supersedes but never deletes a prior version --
// every approve call adds a new biometry_iol_versions row and marks
// any previous Approved version for this record as Superseded.
// ── Used by the Doctor Dashboard's Biometry Approvals widget --
// records ready for surgeon sign-off, mapped to today's visits only. ──
export async function getBiometryApprovalsToday() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from('biometry_records')
    .select('id, surgical_eye, status, visits(id, visit_type, created_at, patients(first_name, last_name, uhid))')
    .eq('status', 'Calculated')
    .gte('visits.created_at', today);
  if (error) return [];
  // The visits filter above can't be applied as a proper join filter via
  // PostgREST here, so double-check in JS that the visit really is today's.
  return (data || []).filter((r) => r.visits && r.visits.created_at?.slice(0, 10) === today);
}

export async function approveIolPlan(id, plan) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  const isDoctor = approverProfile?.designation === 'Doctor';
  if (!isDoctor) return { error: 'Only a doctor can approve a biometry / IOL plan.' };

  if (!plan.finalPower || !plan.finalCategory) return { error: 'Final IOL power and category are required.' };

  const { data: priorVersions } = await supabase
    .from('biometry_iol_versions')
    .select('id, version_no')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });

  const nextVersionNo = (priorVersions?.[0]?.version_no || 0) + 1;

  if (priorVersions && priorVersions.length > 0) {
    await supabase.from('biometry_iol_versions').update({ status: 'Superseded' }).eq('biometry_record_id', id).eq('status', 'Approved');
  }

  const { error: versionError } = await supabase.from('biometry_iol_versions').insert({
    biometry_record_id: id,
    version_no: nextVersionNo,
    power: plan.finalPower,
    formula: plan.finalFormula,
    status: 'Approved',
    created_by: userData?.user?.id || null,
  });
  if (versionError) return { error: versionError.message };

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Approved',
      final_iol_power: plan.finalPower,
      final_iol_category: plan.finalCategory,
      final_iol_catalog_id: plan.iolCatalogId || null,
      target_refraction: plan.finalTarget,
      surgeon_notes: plan.surgeonNotes,
      approved_by: userData?.user?.id || null,
      approved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true, versionNo: nextVersionNo };
}

export async function getIolVersionHistory(id) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_iol_versions')
    .select('*, profiles(full_name)')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });
  if (error) return [];
  return data || [];
}

// ── HISTORY (Section 17.15) -- cross-patient, all statuses past
// Awaiting Biometry. BR-BIO-005: nothing here is ever overwritten;
// re-approvals just add rows to biometry_iol_versions. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, visits(visit_number, patients(id, first_name, last_name, uhid))')
    .in('status', ['Calculated', 'Approved'])
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.visits?.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.visits?.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every biometry lands here the moment Counselling sends the patient
// for it (the stub row is created right then), regardless of how far
// the actual measurement/calculation/approval workflow has gotten --
// same "bill upfront, don't wait for completion" principle used for
// investigations and prescriptions.
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(id, first_name, last_name, uhid))')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.visit_id && r.visits)
    .map((r) => ({ visitId: r.visit_id, visitNumber: r.visits.visit_number, patient: r.visits.patients, items: [r] }));
}

async function setBiometryBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markBiometryDenied(id, note) {
  return setBiometryBillingStatus(id, 'Denied', note);
}

export async function markBiometryDeferred(id, note) {
  return setBiometryBillingStatus(id, 'Deferred', note);
}

export async function resetBiometryBilling(id) {
  return setBiometryBillingStatus(id, 'Pending', null);
}

FILEEOF_app__main__biometry_actions_js

mkdir -p "app/(main)/payments"
cat > "app/(main)/payments/actions.js" << 'FILEEOF_app__main__payments_actions_js'
'use server';

import { after } from 'next/server';
import { createClient } from '@/lib/supabase-server';
import { requireDayOpen, getTodayCollectionSummary, getRevenueByDepartmentToday, getDayOpening, isTodayOpen } from '@/app/(main)/cash-management/actions';
import { sendInvoiceBill } from '@/app/(main)/billing/actions';
import { sendAdvanceReceiptWhatsApp, sendPaymentReceiptWhatsApp, formatDateOnlyIST } from '@/lib/whatsapp';
import { generateReceiptPdfBuffer } from '@/lib/pdf-generator';
import { logJourneyEvent } from '@/lib/journey-events';

// Everything the Payments Dashboard needs, fetched in parallel -- one
// round trip per query, not sequential, since this loads on every visit
// to the dashboard.
export async function getPaymentsDashboardData() {
  const [
    summary, revenueByDept, unpaidInvoices, advanceBalances,
    recentReceipts, dayOpening, dayOpen,
  ] = await Promise.all([
    getTodayCollectionSummary(),
    getRevenueByDepartmentToday(),
    getAllUnpaidInvoices(),
    getCurrentBalancesByPatient(),
    searchReceipts(),
    getDayOpening(),
    isTodayOpen(),
  ]);

  const outstandingTotal = unpaidInvoices.reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);
  const advanceTotal = advanceBalances.reduce((s, p) => s + p.balance, 0);

  return {
    summary,
    revenueByDept,
    outstandingTotal,
    outstandingCount: unpaidInvoices.length,
    topOutstanding: [...unpaidInvoices].sort((a, b) => (b.net - b.paid) - (a.net - a.paid)).slice(0, 5),
    advanceTotal,
    advanceCount: advanceBalances.length,
    topAdvances: [...advanceBalances].sort((a, b) => b.balance - a.balance).slice(0, 5),
    recentReceipts: recentReceipts.slice(0, 8),
    dayOpening,
    dayOpen,
  };
}

export async function getTodaysVisits() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getPatientById(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  if (error) return { error: error.message };
  return { patient: data };
}

export async function getAllUnpaidInvoices() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at, patients(id, first_name, last_name, uhid)')
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── CREDIT NOTES ──
export async function getApprovers() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name, designation').eq('status', 'Active').order('full_name');
  return data || [];
}

export async function createCreditNote(patientId, invoiceId, amount, reason, approvedBy, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_credit_note', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_approved_by: approvedBy,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function getCreditNoteRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('credit_notes')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!credit_notes_approved_by_fkey(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── UNIFIED PATIENT LEDGER (Invoice / Payment / Advance / Advance
// Adjustment / Credit Note / Refund, interleaved with a running
// balance). patient_ledger itself is deliberately NOT a source here --
// it's an internal advance-balance tracker (get_advance_balance sums
// it), and every event it records already has a richer counterpart in
// payments/invoices/credit_notes, so including both would double-count.
export async function getPatientUnifiedLedger(patientId) {
  const supabase = await createClient();

  const [{ data: invoices }, { data: payments }, { data: refunds }, { data: creditNotes }] = await Promise.all([
    supabase.from('invoices').select('id, invoice_number, net, status, created_at, visits(visit_number)').eq('patient_id', patientId),
    supabase.from('payments').select('*, payment_modes(mode, amount)').eq('patient_id', patientId),
    supabase.from('payment_refunds').select('*, refund_payment:payments!payment_refunds_refund_payment_id_fkey(receipt_number), invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
    supabase.from('credit_notes').select('*, invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
  ]);

  const PAYMENT_TYPE_LABEL = { advance: 'Advance', advance_adjustment: 'Advance Adjustment', credit_note: 'Credit Note' };

  const entries = [];

  (invoices || []).forEach((inv) => {
    entries.push({
      date: inv.created_at, type: 'Invoice', ref: inv.invoice_number, visit: inv.visits?.visit_number || '--',
      desc: `Invoice ${inv.invoice_number}`, debit: Number(inv.net), credit: 0, by: 'System',
    });
  });

  // Every refund (invoice-based or from advance) now has exactly one
  // payment_refunds row -- its companion payments row (created purely
  // for Receipt visibility) is always skipped here to avoid double
  // counting.
  (payments || []).forEach((p) => {
    if (p.payment_type === 'credit_note' || p.payment_type === 'refund') return;
    const type = PAYMENT_TYPE_LABEL[p.payment_type] || 'Payment';
    const modeDesc = (p.payment_modes || []).map((m) => m.mode).join('+') || 'Advance';
    entries.push({
      date: p.collected_at, type, ref: p.receipt_number, visit: '--',
      desc: `${type} via ${modeDesc}${p.remarks ? ' -- ' + p.remarks : ''}`, debit: 0, credit: Number(p.total_amount), by: 'Staff',
    });
  });

  (refunds || []).forEach((r) => {
    const desc = r.invoice_id
      ? `Refund against ${r.invoices?.invoice_number || '--'} -- ${r.reason}`
      : `Refund from advance -- ${r.reason}`;
    entries.push({
      date: r.refunded_at, type: 'Refund', ref: r.refund_payment?.receipt_number || '--', visit: r.invoices?.visits?.visit_number || '--',
      desc, debit: Number(r.amount), credit: 0, by: 'Staff',
    });
  });

  (creditNotes || []).forEach((cn) => {
    entries.push({
      date: cn.created_at, type: 'Credit Note', ref: cn.credit_note_number, visit: cn.invoices?.visits?.visit_number || '--',
      desc: `${cn.reason} -- against ${cn.invoices?.invoice_number || '--'}`, debit: 0, credit: Number(cn.amount), by: 'Staff',
    });
  });

  entries.sort((a, b) => new Date(a.date) - new Date(b.date));

  let balance = 0;
  entries.forEach((e) => {
    balance += e.debit - e.credit;
    e.balance = balance;
  });

  return entries.reverse(); // newest first for display
}

// ── EDIT PAYMENT (clerical corrections only -- mode/reference/remarks,
// never amount) ──
export async function editPaymentClerical(paymentId, modes, reference, remarks, reason) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('edit_payment_clerical', {
    p_payment_id: paymentId,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_reason: reason,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getPaymentEditHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase.from('payment_edits').select('*, profiles(full_name)').eq('payment_id', paymentId).order('edited_at', { ascending: false });
  return data || [];
}

// ── REFUND (patient-first flow) ──
export async function getPatientPayments(patientId) {
  const supabase = await createClient();
  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), payment_allocations(id, invoice_id, amount, invoices(invoice_number))')
    .eq('patient_id', patientId)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const paymentIds = rows.map((p) => p.id);

  let refundedByPaymentInvoice = {};
  if (paymentIds.length > 0) {
    const { data: refunds } = await supabase.from('payment_refunds').select('payment_id, invoice_id, amount').in('payment_id', paymentIds);
    (refunds || []).forEach((r) => {
      const key = `${r.payment_id}:${r.invoice_id}`;
      refundedByPaymentInvoice[key] = (refundedByPaymentInvoice[key] || 0) + Number(r.amount);
    });
  }

  return rows.map((p) => ({
    ...p,
    payment_allocations: (p.payment_allocations || []).map((a) => {
      const alreadyRefunded = refundedByPaymentInvoice[`${p.id}:${a.invoice_id}`] || 0;
      return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
    }),
  }));
}

export async function refundAdvance(patientId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_advance', {
    p_patient_id: patientId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getRefundRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!payment_refunds_approved_by_fkey(full_name)')
    .order('refunded_at', { ascending: false })
    .limit(50);
  return data || [];
}

export async function searchPatientsForPayment(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getOutstandingInvoices(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at')
    .eq('patient_id', patientId)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true }); // oldest first, matches allocation order
  return data || [];
}

// ── ADVANCE ──
export async function getAdvanceBalance(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_advance_balance', { p_patient_id: patientId });
  if (error) return 0;
  return data || 0;
}

export async function collectAdvance(patientId, advanceType, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_advance', {
    p_patient_id: patientId,
    p_advance_type: advanceType,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };

  // Auto-send WhatsApp confirmation for advance payments only (regular
  // invoice payments are not auto-sent -- only via the manual Receipt
  // button). Deferred with after() so this never adds latency to the
  // collection response, same fix as applied to collectPayment.
  try {
    const { data: { user } } = await supabase.auth.getUser();
    const { data: patient } = await supabase
      .from('patients')
      .select('id, first_name, last_name, mobile')
      .eq('id', patientId)
      .single();
    const triggeredBy = user?.id || null;

    if (patient?.mobile) {
      after(async () => {
        try {
          const pdfResult = await generateReceiptPdfBuffer(data.id);
          if (pdfResult.error) {
            console.error('Advance receipt PDF generation failed:', pdfResult.error);
            return;
          }
          await sendAdvanceReceiptWhatsApp({
            name: `${patient.first_name} ${patient.last_name}`.trim(),
            amount: data.total_amount,
            receiptNumber: data.receipt_number,
            date: formatDateOnlyIST(data.collected_at),
            mobile: patient.mobile,
            pdfBuffer: pdfResult.buffer,
            filename: `${data.receipt_number || 'Receipt'}.pdf`,
            patientDbId: patient.id,
            meta: { module: 'advance_payment', triggeredBy },
          });
        } catch (waErr) {
          console.error('WhatsApp advance payment send failed:', waErr.message);
        }
      });
    }
  } catch (waErr) {
    console.error('WhatsApp advance payment setup failed (advance already collected):', waErr.message);
  }

  return { payment: data };
}

export async function getCurrentBalancesByPatient() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('patient_id, amount, patients(id, first_name, last_name, uhid)');
  if (!data) return [];

  const byPatient = {};
  data.forEach((entry) => {
    if (!byPatient[entry.patient_id]) {
      byPatient[entry.patient_id] = { patient: entry.patients, balance: 0 };
    }
    byPatient[entry.patient_id].balance += Number(entry.amount);
  });
  return Object.values(byPatient).filter((p) => p.balance > 0);
}

export async function getLedgerHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*, patients(id, first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
    .order('recorded_at', { ascending: false })
    .limit(30);
  return data || [];
}
// ── ADJUSTMENTS ──
export async function getPatientLedgerAudit(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*')
    .eq('patient_id', patientId)
    .order('recorded_at', { ascending: false });
  return data || [];
}

export async function applyAdjustment(patientId, invoiceId, amount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_advance_adjustment', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── RECEIPTS ──
export async function searchReceipts(query, modeFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('payments')
    .select('*, patients(id, first_name, last_name, uhid, mobile), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
    .order('collected_at', { ascending: false })
    .limit(50);

  if (query) {
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    q = q.or(`receipt_number.ilike.%${query}%${ids.length ? ',patient_id.in.(' + ids.join(',') + ')' : ''}`);
  }

  const { data: receipts } = await q;
  if (!receipts) return [];

  if (!modeFilter) return receipts;
  return receipts.filter((r) => (r.payment_modes || []).some((m) => m.mode === modeFilter));
}

export async function getReceiptById(paymentId) {
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();
  if (error) return { error: error.message };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return { payment, modes: modes || [], allocations: allocations || [] };
}

// Manual "Send WhatsApp" button in Receipt -- works for any payment.
// Routes to the correct template based on payment_type: regular invoice
// payments use "payment_receipt" (manual-send only, never automatic);
// advance payments use "advance_receipt" (also sent automatically, but
// this button lets it be resent on demand too). Both attach the receipt
// PDF.
export async function resendPaymentReceiptWhatsApp(paymentId) {
  if (!paymentId) return { error: 'Missing payment id.' };
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('id, receipt_number, total_amount, collected_at, patient_id, payment_type, patients(id, first_name, last_name, mobile)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: error?.message || 'Receipt not found.' };
  if (!payment.patients?.mobile) return { error: 'Patient has no mobile number on file.' };

  const pdfResult = await generateReceiptPdfBuffer(paymentId);
  if (pdfResult.error) return { error: pdfResult.error };

  const { data: { user } } = await supabase.auth.getUser();
  const name = `${payment.patients.first_name} ${payment.patients.last_name}`.trim();
  const filename = `${payment.receipt_number || 'Receipt'}.pdf`;
  const meta = { module: payment.payment_type === 'advance' ? 'advance_payment' : 'payment_receipt', triggeredBy: user?.id || null };

  let whatsapp;
  if (payment.payment_type === 'advance') {
    whatsapp = await sendAdvanceReceiptWhatsApp({
      name,
      amount: payment.total_amount,
      receiptNumber: payment.receipt_number,
      date: formatDateOnlyIST(payment.collected_at),
      mobile: payment.patients.mobile,
      pdfBuffer: pdfResult.buffer,
      filename,
      patientDbId: payment.patient_id,
      meta,
    });
  } else {
    const { data: allocations } = await supabase
      .from('payment_allocations')
      .select('invoices(invoice_number)')
      .eq('payment_id', paymentId);
    const invoiceNumber = (allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--';

    whatsapp = await sendPaymentReceiptWhatsApp({
      name,
      amount: payment.total_amount,
      invoiceNumber,
      receiptNumber: payment.receipt_number,
      date: formatDateOnlyIST(payment.collected_at),
      mobile: payment.patients.mobile,
      pdfBuffer: pdfResult.buffer,
      filename,
      patientDbId: payment.patient_id,
      meta,
    });
  }

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

// ── REFUND / MODIFICATION ──
export async function getRefundableAllocations(paymentId) {
  const supabase = await createClient();
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const { data: refunds } = await supabase
    .from('payment_refunds')
    .select('*')
    .eq('payment_id', paymentId);

  return (allocations || []).map((a) => {
    const alreadyRefunded = (refunds || [])
      .filter((r) => r.invoice_id === a.invoice_id)
      .reduce((s, r) => s + Number(r.amount), 0);
    return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
  });
}

export async function getRefundHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId)
    .order('refunded_at', { ascending: false });
  return data || [];
}

export async function refundPayment(paymentId, invoiceId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_payment', {
    p_payment_id: paymentId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── REPORTS ──
export async function getPaymentReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const from = fromDate || today;
  const to = toDate || today;
  // Include the entire "to" day, not just its midnight instant.
  const toEnd = `${to}T23:59:59`;
  const rangeLabel = from === to ? new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })
    : `${new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- ${new Date(to).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}`;

  if (reportId === 'daily') {
    const [{ data }, { data: refundsData }] = await Promise.all([
      supabase
        .from('payments')
        .select('receipt_number, total_amount, collected_at, patients(first_name, last_name)')
        .in('payment_type', ['invoice_payment', 'advance'])
        .gte('collected_at', from)
        .lte('collected_at', toEnd)
        .order('collected_at', { ascending: false }),
      supabase
        .from('payment_refunds')
        .select('amount')
        .gte('refunded_at', from)
        .lte('refunded_at', toEnd),
    ]);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, new Date(p.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }), `Rs.${p.total_amount}`],
    }));
    const grossTotal = (data || []).reduce((s, p) => s + Number(p.total_amount), 0);
    const refundTotal = (refundsData || []).reduce((s, r) => s + Number(r.amount), 0);
    return {
      title: `Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date/Time', 'Amount'], rows,
      total: grossTotal - refundTotal,
      summary: [
        { label: 'Gross Collected', value: grossTotal },
        { label: 'Refunds This Period', value: -refundTotal },
        { label: 'Net Collection', value: grossTotal - refundTotal, emphasize: true },
      ],
    };
  }

  if (reportId === 'mode' || reportId === 'cash' || reportId === 'upi') {
    const modeFilter = reportId === 'cash' ? 'Cash' : reportId === 'upi' ? 'UPI' : null;
    let q = supabase
      .from('payment_modes')
      .select('mode, amount, payments!inner(receipt_number, collected_at, patients(first_name, last_name), payment_type)')
      .gte('payments.collected_at', from)
      .lte('payments.collected_at', toEnd);
    if (modeFilter) q = q.eq('mode', modeFilter);
    const { data } = await q;

    // Refunds are included, not hidden -- but count against their mode
    // as negative, so both the per-mode summary and the mode-specific
    // reports show what was actually retained, not gross collected.
    const signedAmount = (m) => (m.payments?.payment_type === 'refund' ? -Number(m.amount) : Number(m.amount));

    if (reportId === 'mode') {
      const byMode = {};
      (data || []).forEach((m) => { byMode[m.mode] = (byMode[m.mode] || 0) + signedAmount(m); });
      const rows = Object.entries(byMode).map(([mode, amount]) => ({ cols: [mode, `Rs.${amount.toFixed(2)}`] }));
      return { title: `Payment Mode Summary (net of refunds) -- ${rangeLabel}`, headers: ['Mode', 'Net Total'], rows, total: Object.values(byMode).reduce((s, v) => s + v, 0) };
    }

    const rows = (data || []).map((m) => {
      const isRefund = m.payments?.payment_type === 'refund';
      return {
        cols: [
          m.payments?.receipt_number, `${m.payments?.patients?.first_name} ${m.payments?.patients?.last_name}`,
          new Date(m.payments?.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }),
          isRefund ? 'Refund' : 'Collection',
          `${isRefund ? '-' : ''}Rs.${m.amount}`,
        ],
      };
    });
    return { title: `${modeFilter} Collection (net of refunds) -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date', 'Type', 'Amount'], rows, total: (data || []).reduce((s, m) => s + signedAmount(m), 0) };
  }

  if (reportId === 'advance') {
    const { data } = await supabase
      .from('patient_ledger')
      .select('*, patients(id, first_name, last_name, uhid)')
      .gte('recorded_at', from)
      .lte('recorded_at', toEnd)
      .order('recorded_at', { ascending: false });
    const rows = (data || []).map((l) => ({
      cols: [`${l.patients?.first_name} ${l.patients?.last_name}`, l.patients?.uhid, l.entry_type, `Rs.${Math.abs(l.amount).toFixed(2)}`],
    }));
    return { title: `Advance Report -- ${rangeLabel}`, headers: ['Patient', 'UHID', 'Entry', 'Amount'], rows, total: null };
  }

  if (reportId === 'out') {
    // Outstanding balances are inherently "as of now", not date-ranged --
    // the range here filters by when the invoice was created, so you can
    // still see "what's still outstanding from invoices raised in period X".
    const { data } = await supabase
      .from('invoices')
      .select('invoice_number, net, paid, created_at, patients(id, first_name, last_name, uhid)')
      .in('status', ['Pending', 'Partial'])
      .gte('created_at', from)
      .lte('created_at', toEnd)
      .order('created_at', { ascending: true });
    const rows = (data || []).map((i) => ({
      cols: [i.invoice_number, `${i.patients?.first_name} ${i.patients?.last_name}`, i.patients?.uhid, `Rs.${(i.net - i.paid).toFixed(2)}`],
    }));
    return { title: `Outstanding Balances -- invoices raised ${rangeLabel}`, headers: ['Invoice #', 'Patient', 'UHID', 'Outstanding'], rows, total: (data || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0) };
  }

  if (reportId === 'register') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, payment_type, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false })
      .limit(200);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, p.payment_type, new Date(p.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }), `Rs.${p.total_amount}`],
    }));
    return { title: `Receipt Register -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Type', 'Date', 'Amount'], rows, total: null };
  }

  if (reportId === 'cancel') {
    const { data } = await supabase
      .from('payment_refunds')
      .select('*, patients(first_name, last_name), invoices(invoice_number)')
      .gte('refunded_at', from)
      .lte('refunded_at', toEnd)
      .order('refunded_at', { ascending: false });
    const rows = (data || []).map((r) => ({
      cols: [`${r.patients?.first_name} ${r.patients?.last_name}`, r.invoices?.invoice_number || 'Advance', `Rs.${r.amount}`, r.reason],
    }));
    return { title: `Refund Report -- ${rangeLabel}`, headers: ['Patient', 'Invoice', 'Amount', 'Reason'], rows, total: (data || []).reduce((s, r) => s + Number(r.amount), 0) };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_payment', {
    p_patient_id: patientId,
    p_invoice_ids: invoiceIds,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };

  // Log a journey event for whichever visit(s) this payment was
  // against -- one payment can span invoices from the same visit
  // (e.g. consultation + investigation billed separately), so dedupe
  // to one event per visit rather than one per invoice.
  try {
    const { data: paidVisits } = await supabase.from('invoices').select('visit_id').in('id', invoiceIds || []);
    const distinctVisitIds = [...new Set((paidVisits || []).map((i) => i.visit_id).filter(Boolean))];
    for (const vId of distinctVisitIds) {
      await logJourneyEvent(supabase, vId, 'payment_collected', { amount });
    }
  } catch (logErr) {
    console.error('payment_collected journey log failed:', logErr.message);
  }

  // Fire the WhatsApp bill for any invoice that just became fully paid --
  // but NOT inline. PDF generation (headless Chrome) + Meta's media
  // upload + template send together take several seconds, and awaiting
  // that here was adding 4-5s to every payment confirmation. after()
  // returns the response to the front desk immediately, then keeps this
  // function alive just long enough to finish the send in the background.
  try {
    const { data: { user } } = await supabase.auth.getUser();
    const { data: affectedInvoices } = await supabase
      .from('invoices')
      .select('id, status')
      .in('id', invoiceIds || []);
    const paidInvoiceIds = (affectedInvoices || []).filter((inv) => inv.status === 'Paid').map((inv) => inv.id);
    const triggeredBy = user?.id || null;

    if (paidInvoiceIds.length > 0) {
      after(async () => {
        for (const invoiceId of paidInvoiceIds) {
          try {
            await sendInvoiceBill(invoiceId, { force: false, triggeredBy });
          } catch (waErr) {
            console.error('WhatsApp bill auto-send failed:', waErr.message);
          }
        }
      });
    }
  } catch (waErr) {
    console.error('WhatsApp bill auto-send setup failed (payment already collected):', waErr.message);
  }

  return { payment: data };
}


FILEEOF_app__main__payments_actions_js

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/actions.js" << 'FILEEOF_app__main__pharmacy_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

export async function getPendingPrescriptions() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .eq('status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  // Group flat prescription rows by visit, since a pharmacist hands over
  // everything for one patient's visit together, not drug by drug.
  const groups = {};
  data.forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: rx.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

export async function dispensePrescription(id) {
  const supabase = await createClient();
  const { data: rx } = await supabase.from('prescriptions').select('drug_name, encounters(visit_id)').eq('id', id).maybeSingle();
  const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, rx?.encounters?.visit_id, 'pharmacy_dispensed', { drug_name: rx?.drug_name });
  return { success: true };
}

export async function dispenseAllForVisit(prescriptionIds) {
  const supabase = await createClient();
  const { data: rxList } = await supabase.from('prescriptions').select('id, drug_name, encounters(visit_id)').in('id', prescriptionIds);
  for (const id of prescriptionIds) {
    const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
    if (error) return { error: error.message };
  }
  const visitId = rxList?.[0]?.encounters?.visit_id;
  await logJourneyEvent(supabase, visitId, 'pharmacy_dispensed', { count: prescriptionIds.length });
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every prescription lands here the moment it's written in
// Consultation, regardless of dispensing status -- Front Office can
// bill it at the counter before the patient even reaches Pharmacy.
export async function getPendingPrescriptionsForFrontOffice() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    const visit = rx.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

async function setPrescriptionBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('prescriptions')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markPrescriptionDenied(id, note) {
  return setPrescriptionBillingStatus(id, 'Denied', note);
}

export async function markPrescriptionDeferred(id, note) {
  return setPrescriptionBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetPrescriptionBilling(id) {
  return setPrescriptionBillingStatus(id, 'Pending', null);
}


FILEEOF_app__main__pharmacy_actions_js

mkdir -p "lib"
cat > "lib/journey-events.js" << 'FILEEOF_lib_journey_events_js'
// Shared logger for visit_journey_events -- an append-only record of
// the moments in a patient's day that a single-row "current status"
// column can't hold onto (repeat trips to the doctor, per-destination
// send-out times, etc). Called from server actions across queue,
// investigation, biometry, payments, and pharmacy, each passing their
// own already-open supabase client so this doesn't open a second
// connection per call.
//
// Never throws -- a failed log write should not block the actual
// clinical/billing action it's attached to. Best-effort only.
export async function logJourneyEvent(supabase, visitId, eventType, meta = {}) {
  if (!visitId) return;
  try {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('visit_journey_events').insert({
      visit_id: visitId,
      event_type: eventType,
      meta,
      created_by: userData?.user?.id || null,
    });
  } catch (err) {
    console.error('logJourneyEvent failed:', eventType, visitId, err?.message);
  }
}
FILEEOF_lib_journey_events_js


echo "Files written."

git add -A
git commit -m "Add patient journey event log: repeat-visit history, per-destination timers, per-stage time breakdown"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
