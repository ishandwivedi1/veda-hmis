#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/queue"
cat > "app/(main)/queue/page.js" << 'FILEEOF_page_js'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  getPatientFlow,
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

function waitBadgeClass(mins) {
  if (mins >= 30) return 'b-red';
  if (mins >= 15) return 'b-amber';
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

function FlowCard({ item }) {
  const mins = elapsedMin(item.since);
  return (
    <div style={{
      background: '#fff', border: '1px solid var(--g100)', borderRadius: 8,
      padding: '9px 10px', marginBottom: 8,
    }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{item.patientName}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)' }}>{item.uhid}</div>
        </div>
        {item.priority && item.priority !== 'Routine' && (
          <span className={`badge ${item.priority === 'Emergency' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{item.priority}</span>
        )}
      </div>
      <div style={{ display: 'flex', gap: 6, alignItems: 'center', marginTop: 6, flexWrap: 'wrap' }}>
        {item.detail && <span className="badge b-gray" style={{ fontSize: 10 }}>{item.detail}</span>}
        {item.doctorName && <span className="badge b-gray" style={{ fontSize: 10 }}><i className="ti ti-stethoscope"></i> {item.doctorName}</span>}
        <span className={`badge ${waitBadgeClass(mins)}`} style={{ fontSize: 10 }}>
          <i className="ti ti-clock"></i> {mins}m
        </span>
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
                {items.map((item) => <FlowCard key={item.visitId} item={item} />)}
                {items.length === 0 && (
                  <div style={{ textAlign: 'center', color: 'var(--g300)', fontSize: 11, padding: 12 }}>--</div>
                )}
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}

FILEEOF_page_js

cat > "app/(main)/queue/actions.js" << 'FILEEOF_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';

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

function computeFlowStage(visit, queueByVisit, invoices, prescriptions) {
  if (visit.status === 'Closed') {
    return { column: 'Checked Out', detail: '', since: visit.created_at };
  }

  const entries = queueByVisit[visit.id] || [];
  const opto = entries.find((e) => e.department === 'Optometry');
  const doc = entries.find((e) => e.department === 'Doctor');

  if (!doc) {
    // No token issued yet is not expected in normal flow (a token is
    // issued the moment a patient is registered) -- treat it as still
    // waiting for Optometry rather than adding a separate column for
    // what should be a near-instant, rarely-visible state.
    if (!opto) return { column: 'Waiting for Optometry', detail: '', since: visit.created_at };
    if (opto.status === 'Calling') return { column: 'With Optometrist', detail: 'Called in', since: opto.called_at || opto.issued_at };
    return { column: 'Waiting for Optometry', detail: '', since: opto.issued_at };
  }

  if (doc.status === 'Waiting') return { column: 'Waiting for Doctor', detail: '', since: doc.issued_at };
  if (doc.status === 'Ready for Review') return { column: 'Waiting for Doctor', detail: 'Ready for review', since: doc.sent_out_at || doc.issued_at };
  if (doc.status === 'In Consultation') return { column: 'With Doctor', detail: '', since: doc.called_at || doc.issued_at };
  if (doc.status?.startsWith('Awaiting')) {
    return { column: 'Sent Out', detail: doc.status.replace('Awaiting ', ''), since: doc.sent_out_at || doc.issued_at };
  }

  if (doc.status === 'Done') {
    const invPending = invoices.some((i) => i.visit_id === visit.id && (i.status === 'Pending' || i.status === 'Partial'));
    if (invPending) return { column: 'Billing', detail: '', since: doc.completed_at || doc.issued_at };

    const rxPending = prescriptions.some((r) => r.visit_id === visit.id && r.status === 'Sent');
    if (rxPending) return { column: 'Pharmacy', detail: '', since: doc.completed_at || doc.issued_at };

    return { column: 'Checked Out', detail: '', since: doc.completed_at || doc.issued_at };
  }

  return { column: 'Waiting for Doctor', detail: doc.status, since: doc.issued_at };
}

export async function getPatientFlow() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [
    { data: visits },
    { data: queueEntries },
    { data: invoices },
    { data: prescriptionsRaw },
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
  ]);

  if (!visits) return { columns: FLOW_COLUMNS, byColumn: {} };

  const queueByVisit = {};
  (queueEntries || []).forEach((e) => {
    if (!queueByVisit[e.visit_id]) queueByVisit[e.visit_id] = [];
    queueByVisit[e.visit_id].push(e);
  });

  const prescriptions = (prescriptionsRaw || []).map((r) => ({ status: r.status, visit_id: r.encounters?.visit_id }));

  const byColumn = {};
  FLOW_COLUMNS.forEach((c) => { byColumn[c] = []; });

  visits.forEach((v) => {
    const stage = computeFlowStage(v, queueByVisit, invoices || [], prescriptions);
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
    });
  });

  return { columns: FLOW_COLUMNS, byColumn };
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

  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Calling', called_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

export async function optometryComplete(id) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('optometry_complete', { p_queue_entry_id: id });
  if (error) return { error: error.message };
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
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'In Consultation', called_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
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

  const { data: doctorEntry } = await supabase
    .from('queue_entries').select('id')
    .eq('visit_id', entry.visit_id).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!doctorEntry) return { error: 'Could not route patient to Doctor queue.' };

  return doctorCallSpecific(doctorEntry.id);
}

export async function doctorComplete(id) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Done', completed_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

// Order matters for a stable, predictable compound string regardless
// of which button the doctor clicked first/second.
const SENDOUT_ORDER = ['Dilation', 'Investigation', 'Biometry'];

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
  const { data: current } = await supabase.from('queue_entries').select('status').eq('id', id).single();
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
  return { success: true };
}

export async function doctorMarkReady(id) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Ready for Review' })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}



FILEEOF_actions_js

echo "Files written."

git add -A
git commit -m "Patient Flow: drop Front Office and Counselling columns, split Optometry into Waiting/With Optometrist, rename Doctor Queue"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
