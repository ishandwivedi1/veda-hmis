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

// ── PETTY CASH -- day-to-day hospital cash outgoings (stationery,
// transport, refreshments, minor repairs). Entered by any staff on a
// day that's open; no approval step. Folds into Cash reconciliation
// and Close Day so the drawer count ties out. ──
export async function getExpenseCategoriesActive() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function getExpensesForDate(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data } = await supabase
    .from('petty_cash_expenses')
    .select('*, master_expense_categories(name), profiles(full_name)')
    .eq('expense_date', targetDate)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getPettyCashTotal(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data } = await supabase.from('petty_cash_expenses').select('amount').eq('expense_date', targetDate);
  return (data || []).reduce((sum, r) => sum + Number(r.amount), 0);
}

export async function addExpense(categoryId, amount, paidTo, note) {
  const dayGuard = await requireDayOpen();
  if (dayGuard) return dayGuard;

  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const amt = Number(amount);
  if (!categoryId) return { error: 'Select a category.' };
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };

  const { data, error } = await supabase
    .from('petty_cash_expenses')
    .insert({
      expense_date: todayIST(),
      category_id: categoryId,
      amount: amt,
      paid_to: paidTo || null,
      note: note || null,
      entered_by: userData?.user?.id || null,
    })
    .select()
    .single();

  if (error) return { error: error.message };
  return { success: true, expense: data };
}

// Deletion is only allowed on today's un-closed entries -- once the
// day is closed, its petty cash total is locked into that closing
// record, same as reconciliation becomes read-only.
export async function deleteExpense(id, expenseDate) {
  if (expenseDate !== todayIST()) return { error: "Only today's entries can be deleted." };
  const closed = await isTodayClosed();
  if (closed) return { error: 'Today is already closed -- petty cash entries are locked.' };

  const supabase = await createClient();
  const { error } = await supabase.from('petty_cash_expenses').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
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

export async function getTodayCollectionSummary(date) {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC(date);

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

export async function getReconciliationData(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [summary, pettyCashTotal] = await Promise.all([
    getTodayCollectionSummary(targetDate),
    getPettyCashTotal(targetDate),
  ]);
  const { data: saved } = await supabase.from('day_reconciliation').select('*').eq('closing_date', targetDate);
  const savedByMode = {};
  (saved || []).forEach((r) => { savedByMode[r.mode] = r; });

  // Petty cash is a physical cash outflow, so it only touches the Cash
  // mode's expected figure -- Card/UPI/Cheque/Bank Transfer are
  // untouched. Make sure a Cash row shows up even on a day with
  // expenses but zero cash collections, so it isn't silently skipped.
  const modes = new Set(Object.keys(summary.byMode));
  if (pettyCashTotal > 0) modes.add('Cash');

  return [...modes].map((mode) => {
    const rawExpected = summary.byMode[mode] || 0;
    const expected = mode === 'Cash' ? rawExpected - pettyCashTotal : rawExpected;
    return {
      mode,
      expected,
      actual: savedByMode[mode] ? Number(savedByMode[mode].actual) : expected,
      saved: !!savedByMode[mode],
      reason: savedByMode[mode]?.reason || '',
    };
  });
}

export async function saveReconciliation(mode, expected, actual, reason, approvedBy, date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { error } = await supabase.rpc('save_reconciliation', {
    p_closing_date: targetDate, p_mode: mode, p_expected: expected, p_actual: actual,
    p_reason: reason || null, p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getCloseDayReadiness(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [reconciliation, { data: alreadyClosed }] = await Promise.all([
    getReconciliationData(targetDate),
    supabase.from('day_closings').select('id').eq('closing_date', targetDate).maybeSingle(),
  ]);

  return {
    reconciliationComplete: reconciliation.every((r) => r.saved),
    alreadyClosed: !!alreadyClosed,
    reconciliation,
  };
}

export async function closeDay(notes, date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('close_day', { p_date: date || null, p_notes: notes || null });
  if (error) return { error: error.message };
  return { closing: data };
}

// Any day that was opened but never closed, before today. The "Close
// a Past Day" flow works through this list -- and open_day itself now
// refuses to open a new day while any of these exist.
export async function getUnclosedPastDays() {
  const supabase = await createClient();
  const today = todayIST();

  const { data: openings } = await supabase
    .from('day_openings')
    .select('opening_date')
    .lt('opening_date', today)
    .order('opening_date', { ascending: true });
  if (!openings || openings.length === 0) return [];

  const { data: closings } = await supabase
    .from('day_closings')
    .select('closing_date')
    .lt('closing_date', today);
  const closedSet = new Set((closings || []).map((c) => c.closing_date));

  return openings.map((o) => o.opening_date).filter((d) => !closedSet.has(d));
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
  const [{ data: closing }, { data: reconciliation }, expenses] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
    getExpensesForDate(date),
  ]);
  return { closing, reconciliation: reconciliation || [], expenses };
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


