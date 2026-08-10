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



