'use server';

import { createClient } from '@/lib/supabase-server';
import { formatPatientName } from '@/lib/patientName';
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
    .select('*, visits(patients(first_name, salutation, last_name, uhid))')
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
    .select('id, department, token, status, issued_at, visits(patients(first_name, salutation, last_name, uhid))')
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
      .select('id, visit_type, priority, status, created_at, closed_at, patients(first_name, salutation, last_name, uhid), profiles:doctor_id(full_name)')
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
      patientName: p ? `${formatPatientName(p)}` : 'Unknown',
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
    supabase.from('visits').select('created_at, closed_at, patients(first_name, salutation, last_name, uhid)').eq('id', visitId).single(),
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
    patientName: p ? `${formatPatientName(p)}` : 'Unknown',
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


