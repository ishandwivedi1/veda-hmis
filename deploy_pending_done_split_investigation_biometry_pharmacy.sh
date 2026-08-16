#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/query-only change -- no DB migration needed.
#
# Same "today's pending + today's done, roll to history tomorrow"
# pattern from OT Intraop/Recovery, applied to Investigation, Biometry,
# and Pharmacy after reviewing all three.
#
# Findings before fixing:
#   - PHARMACY was already correctly date-bounded (today's prescriptions
#     of any status), so nothing actually disappeared -- it just showed
#     pending and done mixed in one table. Split into two sections using
#     data it already had; no backend change needed.
#   - INVESTIGATION had a "Today's Investigations" table that also
#     didn't filter by status (fine), but duplicated today's pending
#     items that were already shown in the Queue below. Replaced it with
#     a clean Pending/Completed split and removed the duplication.
#   - BIOMETRY had the exact same bug OT had before: getBiometryQueue()
#     only returns Awaiting/Measured/Calculated -- an Approved record
#     vanished completely with no "done today" view anywhere except
#     scrolling through all-time History. Added a real
#     getBiometryCompletedToday() and an "Approved Today" section.
#
# All three now split into two dashboard sections (Pending / Completed
# or Done), matching the pattern already used in OT Intraop, OT
# Recovery, and now here too.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/investigation"
cat > "app/(main)/investigation/actions.js" << 'FILEEOF_investigation_actions_js'
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
// the front desk's actual working day rather than UTC midnight.
// Returns everything ordered today regardless of status -- the page
// splits pending vs completed client-side (see investigation/page.js). ──
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

FILEEOF_investigation_actions_js

mkdir -p "app/(main)/investigation"
cat > "app/(main)/investigation/page.js" << 'FILEEOF_investigation_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationQueue, getTodaysInvestigations } from './actions';
import InvestigationTabs from './investigation-tabs';
import { openPrintPopup } from '@/lib/printPopup';

const PRIORITY_BADGE = { Urgent: 'b-red', Routine: 'b-gray' };

// Same type-matching heuristic as the workspace uses -- kept in sync
// so the Queue's type filter and badges agree with what the workspace
// will actually render when opened.
function matchType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) return 'OCT';
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) return 'Visual Field';
  if (n.includes('fundus')) return 'Fundus Photography';
  if (n.includes('pachymetry')) return 'Pachymetry';
  return 'External Report';
}

const TYPE_ICON = { OCT: 'ti-eye', 'Visual Field': 'ti-activity', 'Fundus Photography': 'ti-camera', Pachymetry: 'ti-ruler', 'External Report': 'ti-file-import', Biometry: 'ti-ruler-measure' };

// Investigation and Biometry use different status vocabularies
// (Ordered/In Progress/... vs Awaiting Biometry/Measured/Calculated),
// so the Queue badge needs to know which one it's looking at.
const STATUS_BADGE = {
  investigation: { 'In Progress': 'b-blue' },
  biometry: { 'Awaiting Biometry': 'b-amber', Measured: 'b-blue', Calculated: 'b-purple' },
};
function statusBadgeClass(item) {
  return STATUS_BADGE[item.kind]?.[item.status] || 'b-amber';
}

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function InvestigationPage() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 });
  const [typeFilter, setTypeFilter] = useState('');
  const [todaysInvestigations, setTodaysInvestigations] = useState([]);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvestigationQueue();
    setGroups(result.groups);
    setStats(result.stats);
    setTodaysInvestigations(await getTodaysInvestigations());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const filteredGroups = typeFilter
    ? groups.map((g) => ({ ...g, items: g.items.filter((i) => (i.kind === 'biometry' ? 'Biometry' : matchType(i.name)) === typeFilter) })).filter((g) => g.items.length > 0)
    : groups;

  const todaysPending = todaysInvestigations.filter((r) => ['Ordered', 'In Progress'].includes(r.status));
  const todaysCompleted = todaysInvestigations.filter((r) => ['Completed', 'Available', 'Verified'].includes(r.status));

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Ordered" value={stats.ordered} sub="Awaiting performance" color="var(--teal)" />
        <KpiCard label="In progress" value={stats.inProgress} sub="Currently being done" color="var(--amber)" />
        <KpiCard label="Verified today" value={stats.availableToday} sub="Available for review" color="var(--green)" />
        <KpiCard label="Total today" value={stats.totalToday} sub="All investigations" color="var(--blue)" />
      </div>

      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Today&apos;s Pending
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{todaysPending.length}</span>
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Patient Name</th><th>Investigation</th><th>Status</th><th>Billing Status</th><th></th></tr>
          </thead>
          <tbody>
            {todaysPending.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{r.patient?.first_name} {r.patient?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.patient?.uhid}</span>
                </td>
                <td style={{ fontWeight: 600 }}>{r.name} <span style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 400 }}>({r.eye})</span></td>
                <td><span className="badge b-amber">{r.status}</span></td>
                <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                <td>
                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(`/investigation/${r.id}`)} title="View">
                    <i className="ti ti-eye"></i>
                  </button>
                </td>
              </tr>
            ))}
            {todaysPending.length === 0 && (
              <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Nothing pending from today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Today&apos;s Completed
          <span className="badge b-green" style={{ marginLeft: 8 }}>{todaysCompleted.length}</span>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still viewable/printable from here today.</div>
        <table className="tbl">
          <thead>
            <tr><th>Patient Name</th><th>Investigation</th><th>Billing Status</th><th></th></tr>
          </thead>
          <tbody>
            {todaysCompleted.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{r.patient?.first_name} {r.patient?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.patient?.uhid}</span>
                </td>
                <td style={{ fontWeight: 600 }}>{r.name} <span style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 400 }}>({r.eye})</span></td>
                <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                <td style={{ display: 'flex', gap: 4 }}>
                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(`/investigation/${r.id}`)} title="View">
                    <i className="ti ti-eye"></i>
                  </button>
                  <button
                    onClick={() => openPrintPopup(`/investigation-print/${r.id}`)}
                    className="btn"
                    style={{ padding: '3px 8px', fontSize: 11 }}
                    title="Print / PDF"
                  >
                    <i className="ti ti-printer"></i>
                  </button>
                </td>
              </tr>
            ))}
            {todaysCompleted.length === 0 && (
              <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Nothing completed yet today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--teal)' }}></i> Investigation Queue <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(all pending, any date)</span></div>
          <select className="fi" style={{ width: 'auto', padding: '5px 8px', fontSize: 11 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
            <option value="">All types</option>
            <option value="OCT">OCT</option>
            <option value="Visual Field">Visual Field</option>
            <option value="Fundus Photography">Fundus Photography</option>
            <option value="Pachymetry">Pachymetry</option>
            <option value="External Report">External Report</option>
            <option value="Biometry">Biometry</option>
          </select>
        </div>
      </div>

      {filteredGroups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-user" style={{ color: 'var(--purple)' }}></i>
            {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
          </div>
          {g.items.map((item) => {
            const type = item.kind === 'biometry' ? 'Biometry' : matchType(item.name);
            const href = item.kind === 'biometry' ? `/biometry/${item.id}` : `/investigation/${item.id}`;
            return (
              <div
                key={item.id}
                onClick={() => router.push(href)}
                style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
              >
                <i className={`ti ${TYPE_ICON[type] || 'ti-flask'}`} style={{ color: item.kind === 'biometry' ? 'var(--indigo)' : 'var(--teal)', fontSize: 16 }}></i>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{item.name}</span>
                  <span style={{ fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>{item.eye}</span>
                </div>
                <span className={`badge ${PRIORITY_BADGE[item.priority] || 'b-gray'}`}>{item.priority}</span>
                <span className={`badge ${statusBadgeClass(item)}`}>{item.status}</span>
                <span className={`badge ${item.payment?.badge || 'b-gray'}`}>{item.payment?.label || 'Unbilled'}</span>
                <button className="btn btn-sm btn-primary"><i className={`ti ${item.kind === 'biometry' ? 'ti-ruler-measure' : 'ti-flask'}`}></i> Open</button>
              </div>
            );
          })}
        </div>
      ))}

      {filteredGroups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

FILEEOF_investigation_page_js

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/actions.js" << 'FILEEOF_biometry_actions_js'
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

// ── COMPLETED TODAY -- Approved records from today, so a biometry
// doesn't just disappear from the Queue the instant it's approved.
// Moves to History (getBiometryHistory) once the day rolls over --
// mirrors the same Dashboard/History split used in OT Intraop, OT
// Recovery, and the Investigation Queue. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .eq('status', 'Approved')
    .gte('approved_at', startUTC)
    .lte('approved_at', endUTC)
    .order('approved_at', { ascending: false });
  if (error) return [];

  return (data || [])
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
      approvedAt: r.approved_at,
    }));
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
    .select('id, procedure_name, eye')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  // OU (bilateral) can't be represented on a single record --
  // verifyBiometryMeasurements only supports one eye per record. This
  // fallback path only ever creates ONE record (unlike Counselling's
  // sendForBiometry, which fans an OU case out into two), so for OU we
  // deliberately leave surgical_eye blank here rather than writing an
  // unsupported value -- the technician sets it explicitly instead.
  const surgicalEye = surgicalCase?.eye === 'OD' ? 'RE' : surgicalCase?.eye === 'OS' ? 'LE' : null;

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({
      visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null,
      surgical_case_id: surgicalCase?.id || null,
      procedure_name: surgicalCase?.procedure_name || null,
      surgical_eye: surgicalEye,
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

FILEEOF_biometry_actions_js

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/page.js" << 'FILEEOF_biometry_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryQueue, getOrCreateBiometryRecord, getBiometryCompletedToday } from './actions';

const STATUS_BADGE = {
  'Awaiting Biometry': 'b-gray',
  Measured: 'b-amber',
  Calculated: 'b-blue',
  Approved: 'b-green',
};

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function BiometryQueuePage() {
  const [rows, setRows] = useState([]);
  const [completedToday, setCompletedToday] = useState([]);
  const [stats, setStats] = useState({ awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 });
  const [openingId, setOpeningId] = useState(null);
  const [error, setError] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getBiometryQueue();
    setRows(result.rows);
    setStats(result.stats);
    setCompletedToday(await getBiometryCompletedToday());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleOpen(row) {
    setError('');
    if (row.recordId) {
      router.push(`/biometry/${row.recordId}`);
      return;
    }
    setOpeningId(row.recordId);
    const result = await getOrCreateBiometryRecord(row.visitId, row.encounterId);
    setOpeningId(null);
    if (result.error) { setError(result.error); return; }
    router.push(`/biometry/${result.id}`);
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Awaiting biometry" value={stats.awaiting} sub="Not yet measured" color="var(--indigo)" />
        <KpiCard label="Measured" value={stats.measured} sub="Awaiting calculation" color="var(--amber)" />
        <KpiCard label="Calculated" value={stats.calculated} sub="Awaiting surgeon" color="var(--blue)" />
        <KpiCard label="Approved today" value={stats.approvedToday} sub="IOL plan finalized" color="var(--green)" />
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Measurement before calculation. Calculation before selection. Only the surgeon may approve the final IOL plan.
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Biometry Queue <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(pending, any date)</span></div>
          <button className="btn btn-sm" onClick={() => router.push('/biometry/history')}>
            <i className="ti ti-history"></i> History
          </button>
        </div>
        {rows.map((row) => (
          <div key={row.recordId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{row.patient?.first_name} {row.patient?.last_name}</span>
              <span className={`badge ${STATUS_BADGE[row.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{row.status}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {row.patient?.uhid}{row.procedureName ? ` -- ${row.procedureName}` : ''}{row.surgicalEye ? ` ${row.surgicalEye}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => handleOpen(row)} disabled={openingId === row.recordId}>
              <i className={`ti ${row.status === 'Approved' ? 'ti-eye' : 'ti-ruler-measure'}`}></i> {openingId === row.recordId ? 'Opening...' : row.status === 'Approved' ? 'View' : 'Measure'}
            </button>
          </div>
        ))}
        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            Nothing pending -- all caught up.
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Approved Today</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still viewable from here today.</div>
        {completedToday.map((row) => (
          <div key={row.recordId} onClick={() => router.push(`/biometry/${row.recordId}`)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{row.patient?.first_name} {row.patient?.last_name}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Approved</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {row.patient?.uhid}{row.procedureName ? ` -- ${row.procedureName}` : ''}{row.surgicalEye ? ` ${row.surgicalEye}` : ''}
              </div>
            </div>
            <button className="btn btn-sm"><i className="ti ti-eye"></i> View</button>
          </div>
        ))}
        {completedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>
    </div>
  );
}

FILEEOF_biometry_page_js

mkdir -p "app/(main)/pharmacy"
cat > "app/(main)/pharmacy/page.js" << 'FILEEOF_pharmacy_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPharmacyDashboard } from './actions';
import PharmacyTabs from './pharmacy-tabs';

const STATUS_BADGE = {
  Purchased: 'b-green',
  Pending: 'b-amber',
  Deferred: 'b-gray',
  'Declined / Bought Elsewhere': 'b-red',
};

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

function VisitStatusBadge({ g }) {
  if (g.allPurchased) return <span className="badge b-green">All Purchased</span>;
  if (g.anyPending) return <span className="badge b-amber">Action Needed</span>;
  return <span className="badge b-gray">Closed Out</span>;
}

export default function PharmacyDashboard() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ totalPatients: 0, pendingItems: 0, purchasedItems: 0, declinedOrDeferred: 0 });
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const data = await getPharmacyDashboard();
    setGroups(data.groups);
    setStats(data.stats);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 20000);
    return () => clearInterval(interval);
  }, [refresh]);

  const pendingGroups = groups.filter((g) => g.anyPending);
  // "Done" = nothing left to action for this patient today -- either
  // every item was purchased, or the remaining ones were explicitly
  // declined/deferred (not just silently forgotten).
  const doneGroups = groups.filter((g) => !g.anyPending);

  function GroupTable({ rows, emptyText }) {
    if (rows.length === 0) {
      return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 24 }}>{emptyText}</div>;
    }
    return (
      <table className="tbl">
        <thead>
          <tr><th>Patient</th><th>Visit</th><th>Medicines</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {rows.map((g) => (
            <tr key={g.visitId}>
              <td>
                <strong>{g.patient?.first_name} {g.patient?.last_name}</strong>
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid}</div>
              </td>
              <td style={{ fontSize: 12, color: 'var(--g500)' }}>{g.visitNumber}</td>
              <td>
                <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', maxWidth: 320 }}>
                  {g.items.map((rx) => (
                    <span key={rx.id} className={`badge ${STATUS_BADGE[rx.purchaseStatus] || 'b-gray'}`} style={{ fontSize: 10 }}>
                      {rx.drug_name}
                    </span>
                  ))}
                </div>
              </td>
              <td><VisitStatusBadge g={g} /></td>
              <td style={{ textAlign: 'right' }}>
                <button className="btn btn-sm" onClick={() => router.push(`/pharmacy/${g.visitId}`)}>
                  Open <i className="ti ti-arrow-right"></i>
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    );
  }

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Patients today" value={stats.totalPatients} sub="With a prescription written" color="var(--blue)" />
        <KpiCard label="Pending action" value={stats.pendingItems} sub="Not yet billed or dispensed" color="var(--amber)" />
        <KpiCard label="Purchased" value={stats.purchasedItems} sub="Dispensed today" color="var(--green)" />
        <KpiCard label="Declined / deferred" value={stats.declinedOrDeferred} sub="Not collecting from here" color="var(--red)" />
      </div>

      <PharmacyTabs />

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Today&apos;s Pending
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pendingGroups.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && <GroupTable rows={pendingGroups} emptyText="Nothing pending -- all caught up." />}
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Today&apos;s Done
          <span className="badge b-green" style={{ marginLeft: 8 }}>{doneGroups.length}</span>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Purchased, declined, or deferred -- nothing left to action. Moves out of today's view tomorrow.</div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && <GroupTable rows={doneGroups} emptyText="Nothing closed out yet today." />}
      </div>

      <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 12, padding: 14 }}>
        <i className="ti ti-boxes"></i> Stock tracking is planned for a future update -- current inventory levels aren't shown here yet.
      </div>
    </div>
  );
}
FILEEOF_pharmacy_page_js

echo "Files written. Run: npm run build"
