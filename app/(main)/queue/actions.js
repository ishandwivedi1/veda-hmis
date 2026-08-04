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


