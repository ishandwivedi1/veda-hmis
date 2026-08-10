#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed.

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
FILEEOF_app__main__queue_page_js

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
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_data: resultData,
      result_notes: remarks || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  // This is the moment that actually matters for the patient's timeline
  // -- results are entered and they're walking back to the doctor with
  // the report. Verification (below) is a separate QA checklist step
  // that can happen much later, sometimes by someone else entirely, so
  // it shouldn't be what closes out "In Investigation" time.
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_completed', { name: order?.name });
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


echo "Files written."

git add -A
git commit -m "Fix Investigation timeline event timing (log at completion, not later verification), board wraps vertically instead of scrolling off-screen"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
