'use server';

import { createClient } from '@/lib/supabase-server';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// A plain date string compared against a timestamptz column is
// interpreted at UTC midnight by Postgres, not IST midnight -- that
// mismatch is exactly what made the readiness check disagree with
// close_day() (which correctly uses the ist_date() helper). Building
// explicit +05:30 boundaries makes the two agree.
function istDayBoundsUTC(dateStr) {
  const d = dateStr || todayIST();
  return {
    dateStr: d,
    startUTC: new Date(`${d}T00:00:00+05:30`).toISOString(),
    endUTC: new Date(`${d}T23:59:59.999+05:30`).toISOString(),
  };
}

// ── REVENUE BY DEPARTMENT -- moved here from the Billing Dashboard,
// since it's a same-day revenue breakdown that belongs alongside the
// rest of today's collection summary. ──
export async function getRevenueByDepartmentToday() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: invoices } = await supabase
    .from('invoices')
    .select('purpose, net')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .neq('status', 'Cancelled');

  const byDept = {};
  (invoices || []).forEach((i) => {
    const dept = i.purpose || 'Other';
    byDept[dept] = (byDept[dept] || 0) + Number(i.net);
  });

  return byDept;
}

export async function getTodayCollectionSummary() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), patients(first_name, last_name)')
    .gte('collected_at', startUTC)
    .lte('collected_at', endUTC)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const isRefund = (p) => p.payment_type === 'refund';

  const byMode = {};
  rows.forEach((p) => {
    (p.payment_modes || []).forEach((m) => {
      byMode[m.mode] = (byMode[m.mode] || 0) + (isRefund(p) ? -Number(m.amount) : Number(m.amount));
    });
  });

  const total = rows.reduce((s, p) => s + (isRefund(p) ? -Number(p.total_amount) : Number(p.total_amount)), 0);

  return { transactions: rows, byMode, total, count: rows.length };
}

export async function getReconciliationData() {
  const supabase = await createClient();
  const today = todayIST();

  const summary = await getTodayCollectionSummary();
  const { data: saved } = await supabase.from('day_reconciliation').select('*').eq('closing_date', today);
  const savedByMode = {};
  (saved || []).forEach((r) => { savedByMode[r.mode] = r; });

  const modes = Object.keys(summary.byMode);
  return modes.map((mode) => ({
    mode,
    expected: summary.byMode[mode],
    actual: savedByMode[mode] ? Number(savedByMode[mode].actual) : summary.byMode[mode],
    saved: !!savedByMode[mode],
    reason: savedByMode[mode]?.reason || '',
  }));
}

export async function saveReconciliation(mode, expected, actual, reason, approvedBy) {
  const supabase = await createClient();
  const today = todayIST();
  const { error } = await supabase.rpc('save_reconciliation', {
    p_closing_date: today, p_mode: mode, p_expected: expected, p_actual: actual,
    p_reason: reason || null, p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getCloseDayReadiness() {
  const supabase = await createClient();
  const today = todayIST();

  const [{ count: unreconciledModes }, recon, { data: alreadyClosed }] = await Promise.all([
    (async () => {
      const summary = await getTodayCollectionSummary();
      const { data: saved } = await supabase.from('day_reconciliation').select('mode').eq('closing_date', today);
      const savedModes = new Set((saved || []).map((r) => r.mode));
      const missing = Object.keys(summary.byMode).filter((m) => !savedModes.has(m));
      return { count: missing.length };
    })(),
    getReconciliationData(),
    supabase.from('day_closings').select('id').eq('closing_date', today).maybeSingle(),
  ]);

  return {
    reconciliationComplete: unreconciledModes === 0,
    alreadyClosed: !!alreadyClosed,
    reconciliation: recon,
  };
}

export async function closeDay(notes) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('close_day', { p_date: null, p_notes: notes || null });
  if (error) return { error: error.message };
  return { closing: data };
}

export async function getDayClosingHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('day_closings')
    .select('*, profiles(full_name)')
    .order('closing_date', { ascending: false })
    .limit(30);
  return data || [];
}

export async function getDailyReport(date) {
  const supabase = await createClient();
  const [{ data: closing }, { data: reconciliation }] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
  ]);
  return { closing, reconciliation: reconciliation || [] };
}

export async function reopenDay(date, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('reopen_day', { p_date: date, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getDayOpening() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('*, profiles(full_name)').eq('opening_date', today).maybeSingle();
  return data;
}

export async function openDay(openingBalance, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('open_day', { p_date: null, p_opening_balance: openingBalance || 0, p_remarks: remarks || null });
  if (error) return { error: error.message };
  return { opening: data };
}

export async function isTodayClosed() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.rpc('is_day_closed', { p_date: today });
  return !!data;
}

export async function isTodayOpen() {
  const supabase = await createClient();
  const today = todayIST();
  const { data } = await supabase.from('day_openings').select('id').eq('opening_date', today).maybeSingle();
  return !!data;
}

// Server-side guard for any action that moves physical cash (collect
// payment, refund, advance, or a package invoice that collects an
// advance inline). Called at the top of those actions specifically --
// not a global gate -- so clinical work (doctor, optometry, OT) is
// never blocked by a missed Open Day. Checked here rather than only
// in the UI so it can't be bypassed by calling the server action
// directly. Each new IST calendar date has no day_openings row until
// someone opens it, so this is naturally enforced fresh every day
// without any separate "reset" step.
export async function requireDayOpen() {
  const open = await isTodayOpen();
  if (!open) {
    return { error: "Today's cash day hasn't been opened yet. Go to Cash Management and open the day before collecting or refunding payments." };
  }
  return null;
}

