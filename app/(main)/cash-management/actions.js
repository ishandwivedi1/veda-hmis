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

// Canonical revenue-category mapping from invoice_line_items.dept.
// 'Minor Procedure' is a legacy dept string some older line items were
// tagged with before the code settled on 'OPD Procedure' -- same
// thing, kept as an alias so that old revenue doesn't fall into
// Unclassified. 'Biometry' folds into Investigation, consistent with
// the Billing Dashboard's own Investigation Billing section. Anything
// NOT in this map (a service added with an unexpected/custom dept
// string) falls through to 'Unclassified' rather than being silently
// dropped or mis-bucketed -- see getCategorizedIncome below.
const DEPT_CATEGORY = {
  Consultation: 'OPD Consultation charges',
  'OPD Procedure': 'Procedure charges',
  'Minor Procedure': 'Procedure charges',
  Investigation: 'Investigation charges',
  Biometry: 'Investigation charges',
  Pharmacy: 'Pharmacy',
  Surgery: 'Surgery Income',
};

function emptyCategory() {
  return { byMode: {}, total: 0 };
}

function mergeByMode(...cats) {
  const merged = {};
  cats.forEach((c) => {
    Object.entries(c.byMode || {}).forEach(([mode, amt]) => { merged[mode] = (merged[mode] || 0) + amt; });
  });
  return merged;
}

// Re-slices today's invoice_payment collections (already computed by
// getTodayCollectionSummary) by revenue category, with each category's
// own Cash/UPI/Card/Cheque/Bank Transfer breakdown -- not just "how
// much was collected" but "how much of THIS specific revenue type
// came in on THIS mode".
//
// This requires a proper 3-way proportional split, not a simple
// lookup, because none of the three layers line up 1:1:
//  - one payment/receipt can be split across multiple payment modes
//  - one payment can be allocated across multiple invoices (payment_allocations)
//  - one invoice can (rarely) contain line items from more than one
//    dept (invoices.purpose is a single rolled-up label and doesn't
//    reflect that)
// So for every payment, its mode-split is distributed across its
// invoice allocations by each allocation's share of the payment, and
// each invoice's amount is further distributed across its line items'
// depts by each dept's share of that invoice's net. Nothing is ever
// dropped -- a dept string that isn't in DEPT_CATEGORY (or an invoice
// with no line items on file at all) lands in 'Unclassified' instead,
// and unclassifiedDepts lists exactly which raw dept strings triggered
// it, so it can be flagged rather than silently missed.
async function getCategorizedIncome(supabase, billedTx) {
  if (billedTx.length === 0) return { categories: {}, unclassifiedDepts: [] };

  const paymentIds = billedTx.map((p) => p.id);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('payment_id, invoice_id, amount')
    .in('payment_id', paymentIds);

  const invoiceIds = [...new Set((allocations || []).map((a) => a.invoice_id))];
  let lineItems = [];
  if (invoiceIds.length > 0) {
    const { data } = await supabase.from('invoice_line_items').select('invoice_id, dept, net').in('invoice_id', invoiceIds);
    lineItems = data || [];
  }

  const invoiceDeptMap = {};
  lineItems.forEach((li) => {
    if (!invoiceDeptMap[li.invoice_id]) invoiceDeptMap[li.invoice_id] = { totalNet: 0, byDept: {} };
    const entry = invoiceDeptMap[li.invoice_id];
    entry.totalNet += Number(li.net);
    const dept = li.dept || '(no dept set)';
    entry.byDept[dept] = (entry.byDept[dept] || 0) + Number(li.net);
  });

  const allocByPayment = {};
  (allocations || []).forEach((a) => { (allocByPayment[a.payment_id] ||= []).push(a); });

  const categories = {};
  const unclassifiedDepts = new Set();
  function addTo(category, mode, amt) {
    if (amt === 0) return;
    if (!categories[category]) categories[category] = emptyCategory();
    categories[category].byMode[mode] = (categories[category].byMode[mode] || 0) + amt;
    categories[category].total += amt;
  }

  billedTx.forEach((p) => {
    const total = Number(p.total_amount) || 0;
    if (total <= 0) return;
    const allocs = allocByPayment[p.id] || [];
    const modes = p.payment_modes || [];
    let allocatedShare = 0;
    allocs.forEach((a) => {
      const invShare = Number(a.amount) / total;
      allocatedShare += invShare;
      const invEntry = invoiceDeptMap[a.invoice_id];
      if (!invEntry || invEntry.totalNet <= 0) {
        unclassifiedDepts.add('(no line items on file for this invoice)');
        modes.forEach((m) => addTo('Unclassified', m.mode, Number(m.amount) * invShare));
        return;
      }
      Object.entries(invEntry.byDept).forEach(([dept, deptNet]) => {
        const deptShare = deptNet / invEntry.totalNet;
        const category = DEPT_CATEGORY[dept];
        if (!category) unclassifiedDepts.add(dept);
        modes.forEach((m) => addTo(category || 'Unclassified', m.mode, Number(m.amount) * invShare * deptShare));
      });
    });
    // collect_payment() auto-credits any amount beyond the selected
    // invoices' outstanding total to the patient's advance -- but the
    // receipt itself stays payment_type 'invoice_payment' and its
    // payment_allocations rows only cover the invoiced portion. Without
    // this, that leftover share would just be dropped from every
    // category's total instead of showing up anywhere.
    const leftoverShare = 1 - allocatedShare;
    if (leftoverShare > 0.001) {
      unclassifiedDepts.add('(overpayment auto-credited to patient advance)');
      modes.forEach((m) => addTo('Unclassified', m.mode, Number(m.amount) * leftoverShare));
    }
  });

  return { categories, unclassifiedDepts: [...unclassifiedDepts] };
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
    .select('*, payment_modes(mode, amount), patients(first_name, salutation, last_name)')
    .gte('collected_at', startUTC)
    .lte('collected_at', endUTC)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const isRefund = (p) => p.payment_type === 'refund';
  // advance_adjustment and credit_note both insert a payments row dated
  // today (when the reallocation happens), but no cash actually moves
  // that day -- the money was already received (advance) or was never
  // received at all (credit note, a write-off). Including them here is
  // exactly how an advance collected on a previous date ends up looking
  // like fresh cash in today's total. byMode is unaffected already,
  // since neither type ever gets a payment_modes row.
  const isCashMovement = (p) => ['invoice_payment', 'advance', 'refund'].includes(p.payment_type);

  const byMode = {};
  rows.forEach((p) => {
    (p.payment_modes || []).forEach((m) => {
      byMode[m.mode] = (byMode[m.mode] || 0) + (isRefund(p) ? -Number(m.amount) : Number(m.amount));
    });
  });

  const total = rows
    .filter(isCashMovement)
    .reduce((s, p) => s + (isRefund(p) ? -Number(p.total_amount) : Number(p.total_amount)), 0);

  return { transactions: rows, byMode, total, count: rows.length };
}

export async function getReconciliationData(date, precomputedSummary) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [summary, pettyCashTotal] = await Promise.all([
    precomputedSummary || getTodayCollectionSummary(targetDate),
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

export async function getCloseDayReadiness(date, precomputedSummary) {
  const supabase = await createClient();
  const targetDate = date || todayIST();

  const [reconciliation, { data: alreadyClosed }] = await Promise.all([
    getReconciliationData(targetDate, precomputedSummary),
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

// Splits a day's real cash-movement transactions into the two
// categories Front Office actually cares about at closing time --
// money collected against an invoice (Billed Items) vs money held as
// Advance for later -- each with its own mode-wise breakdown. negate
// flips the sign (used for Refunds, which are cash going out).
function modeBreakdown(txs, negate = false) {
  const byMode = {};
  txs.forEach((p) => {
    (p.payment_modes || []).forEach((m) => {
      byMode[m.mode] = (byMode[m.mode] || 0) + (negate ? -Number(m.amount) : Number(m.amount));
    });
  });
  const total = txs.reduce((s, p) => s + (negate ? -Number(p.total_amount) : Number(p.total_amount)), 0);
  return { byMode, total, count: txs.length };
}

export async function getDailyReport(date) {
  const supabase = await createClient();
  const [{ data: closing }, { data: reconciliation }, expenses, collectionSummary] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
    getExpensesForDate(date),
    // Same underlying query the Reconciliation tab uses, so the
    // report's numbers can never drift from what Front Office actually
    // reconciled against -- advance_adjustment/credit_note excluded
    // (no real cash moved), refund netted negative.
    getTodayCollectionSummary(date),
  ]);

  const billedTx = collectionSummary.transactions.filter((p) => p.payment_type === 'invoice_payment');
  const advanceTx = collectionSummary.transactions.filter((p) => p.payment_type === 'advance');
  const refundTx = collectionSummary.transactions.filter((p) => p.payment_type === 'refund');

  const { categories, unclassifiedDepts } = await getCategorizedIncome(supabase, billedTx);
  const cat = (name) => categories[name] || emptyCategory();

  // OPD Income is the roll-up of the three OPD-workflow categories --
  // shown as its own headline total/mode-split, with each component
  // broken out underneath. Investigation Income is then restated as
  // its own standalone line too (same figure as the component above)
  // since Front Office may want to see it without wading through the
  // OPD breakdown -- it is NOT additional money on top of OPD Income,
  // just the same investigation revenue shown a second way.
  const opdConsultation = cat('OPD Consultation charges');
  const opdProcedure = cat('Procedure charges');
  const opdInvestigation = cat('Investigation charges');
  const opdIncome = {
    consultation: opdConsultation, procedure: opdProcedure, investigation: opdInvestigation,
    byMode: mergeByMode(opdConsultation, opdProcedure, opdInvestigation),
    total: opdConsultation.total + opdProcedure.total + opdInvestigation.total,
  };
  const unclassified = cat('Unclassified');

  return {
    closing, reconciliation: reconciliation || [], expenses,
    billedItems: modeBreakdown(billedTx),
    advances: modeBreakdown(advanceTx),
    refunds: modeBreakdown(refundTx, true),
    // Combined Cash/UPI/Card/Cheque/Bank Transfer totals across Billed
    // + Advance - Refund -- the single "here's what actually moved,
    // by mode, today" figure the report should lead with.
    modeSummary: { byMode: collectionSummary.byMode, total: collectionSummary.total },
    opdIncome,
    investigationIncome: opdInvestigation,
    pharmacyIncome: cat('Pharmacy'),
    surgeryIncome: cat('Surgery Income'),
    unclassifiedIncome: unclassified,
    unclassifiedDepts,
  };
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
