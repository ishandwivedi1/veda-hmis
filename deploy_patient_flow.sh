#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed, this reads existing tables.

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
  'Front Office': { icon: 'ti-door-enter', color: 'var(--g500)' },
  'Optometry': { icon: 'ti-eye-check', color: 'var(--teal)' },
  'Doctor Queue': { icon: 'ti-clock', color: 'var(--g500)' },
  'With Doctor': { icon: 'ti-stethoscope', color: 'var(--blue)' },
  'Sent Out': { icon: 'ti-route', color: 'var(--amber)' },
  'Counselling': { icon: 'ti-message-circle', color: 'var(--purple)' },
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
  'Front Office', 'Optometry', 'Doctor Queue', 'With Doctor',
  'Sent Out', 'Counselling', 'Billing', 'Pharmacy', 'Checked Out',
];

function computeFlowStage(visit, queueByVisit, surgicalCases, invoices, prescriptions) {
  if (visit.status === 'Closed') {
    return { column: 'Checked Out', detail: '', since: visit.created_at };
  }

  const entries = queueByVisit[visit.id] || [];
  const opto = entries.find((e) => e.department === 'Optometry');
  const doc = entries.find((e) => e.department === 'Doctor');

  if (!doc) {
    if (!opto) return { column: 'Front Office', detail: '', since: visit.created_at };
    if (opto.status === 'Calling') return { column: 'Optometry', detail: 'Called in', since: opto.called_at || opto.issued_at };
    return { column: 'Optometry', detail: 'Waiting', since: opto.issued_at };
  }

  if (doc.status === 'Waiting') return { column: 'Doctor Queue', detail: 'Waiting', since: doc.issued_at };
  if (doc.status === 'Ready for Review') return { column: 'Doctor Queue', detail: 'Ready for review', since: doc.sent_out_at || doc.issued_at };
  if (doc.status === 'In Consultation') return { column: 'With Doctor', detail: '', since: doc.called_at || doc.issued_at };
  if (doc.status?.startsWith('Awaiting')) {
    return { column: 'Sent Out', detail: doc.status.replace('Awaiting ', ''), since: doc.sent_out_at || doc.issued_at };
  }

  if (doc.status === 'Done') {
    const invPending = invoices.some((i) => i.visit_id === visit.id && (i.status === 'Pending' || i.status === 'Partial'));
    if (invPending) return { column: 'Billing', detail: '', since: doc.completed_at || doc.issued_at };

    const rxPending = prescriptions.some((r) => r.visit_id === visit.id && r.status === 'Sent');
    if (rxPending) return { column: 'Pharmacy', detail: '', since: doc.completed_at || doc.issued_at };

    const inCounselling = surgicalCases.some((s) => s.visit_id === visit.id && s.status === 'Pending Workup');
    if (inCounselling) return { column: 'Counselling', detail: '', since: doc.completed_at || doc.issued_at };

    return { column: 'Checked Out', detail: '', since: doc.completed_at || doc.issued_at };
  }

  return { column: 'Doctor Queue', detail: doc.status, since: doc.issued_at };
}

export async function getPatientFlow() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [
    { data: visits },
    { data: queueEntries },
    { data: surgicalCases },
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
    supabase.from('surgical_cases').select('visit_id, status')
      .gte('created_at', startUTC).lte('created_at', endUTC),
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
    const stage = computeFlowStage(v, queueByVisit, surgicalCases || [], invoices || [], prescriptions);
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

cat > "app/components/AppShell.js" << 'FILEEOF_appshell_js'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState, useRef } from 'react';
import { createClient } from '@/lib/supabase-browser';
import { updateHeartbeat } from '@/app/(main)/users/actions';

// 30 minutes of no mouse/keyboard/touch activity -> automatic sign-out.
// Balances security (unattended shared terminals in a hospital) against
// not interrupting a doctor mid-consultation for a shorter window.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const CHECK_INTERVAL_MS = 60 * 1000;

const NAV_ITEMS = [
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Patient Flow' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery & Discharge' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  // Idle auto-logout + "who's online" heartbeat. Checked on an interval,
  // AND immediately whenever the tab becomes visible again -- browsers
  // (Chrome especially) heavily throttle setInterval in backgrounded
  // tabs, sometimes to firing only once every several minutes or less,
  // so the interval alone can miss the 30-minute mark while the tab
  // sits unfocused. visibilitychange isn't subject to that throttling
  // and fires exactly when someone switches back to the tab, so it
  // catches what the interval missed. It doesn't count as "activity"
  // itself -- only real mouse/keyboard/touch input resets the clock.
  const lastActivityRef = useRef(Date.now());
  useEffect(() => {
    const markActive = () => { lastActivityRef.current = Date.now(); };
    const events = ['mousemove', 'keydown', 'mousedown', 'scroll', 'touchstart'];
    events.forEach((e) => window.addEventListener(e, markActive, { passive: true }));

    const checkIdle = async () => {
      const idleMs = Date.now() - lastActivityRef.current;
      if (idleMs >= IDLE_TIMEOUT_MS) {
        await supabase.auth.signOut();
        router.push('/login?reason=idle');
        router.refresh();
      } else {
        updateHeartbeat();
      }
    };

    const onVisible = () => { if (document.visibilityState === 'visible') checkIdle(); };
    document.addEventListener('visibilitychange', onVisible);

    updateHeartbeat(); // immediately on mount, not just on the first interval tick -- extra safety net beyond the login-page write

    const interval = setInterval(checkIdle, CHECK_INTERVAL_MS);

    return () => {
      events.forEach((e) => window.removeEventListener(e, markActive));
      document.removeEventListener('visibilitychange', onVisible);
      clearInterval(interval);
    };
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}




FILEEOF_appshell_js

echo "Files written."

git add -A
git commit -m "Replace Queue Management with a full Patient Flow Board across all 9 stages"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
