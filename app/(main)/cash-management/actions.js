'use server';

import { createClient } from '@/lib/supabase-server';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// IST calendar-date string for an arbitrary timestamp (not just "now")
// -- e.g. an invoice's created_at, to check whether it was created on
// the report's own date or an earlier one.
function toISTDateStr(timestamp) {
  return new Date(timestamp).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
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
// dropped or mis-bucketed -- see getBilledIncomeByCategory below.
const DEPT_CATEGORY = {
  Consultation: 'OPD Consultation charges',
  'OPD Procedure': 'Procedure charges',
  'Minor Procedure': 'Procedure charges',
  Investigation: 'Investigation charges',
  Biometry: 'Investigation charges',
  Pharmacy: 'Pharmacy',
  Surgery: 'Surgery Income',
};

// Splits a day's real cash-movement transactions into simple gross
// mode totals -- Table 1 (Payment Mode Summary) rows are all this:
// straight from Payments, no netting or attribution. negate flips the
// sign (used for the Hospital/Optical Refunds rows, cash going out).
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

// Table 2 (Billed Income by Category) is pure billing-truth for
// account-book entry: what was invoiced, and exactly how it's been
// settled -- fresh Cash, fresh UPI (net of today's refunds against
// today's own invoices only -- a refund against an EARLIER invoice is
// out of scope here entirely, since that invoice was never part of
// this table's Billed figure to begin with), advance applied, or
// written off via credit note -- plus what's still Outstanding. This
// is deliberately live/cumulative from each invoice/sale's current
// net, paid, and linked activity (not scoped to "happened today" the
// way Table 1's rows are), so it stays internally exact even if a
// refund against today's invoice happens on a later day:
//   billed == netCash + netUPI + advanceSettled + creditNoteSettled
//            + outstanding
// always holds per category, by construction. A dept string not in
// DEPT_CATEGORY (or an invoice with no line items on file) falls into
// 'Unclassified' instead of being silently dropped; unclassifiedDepts
// lists exactly which raw dept strings triggered it, for review.
// Optical has no advance-adjustment or credit-note equivalent, so
// those two stay 0 for its row.
function emptyBilledRow() {
  return { billed: 0, netCash: 0, netUPI: 0, advanceSettled: 0, creditNoteSettled: 0, outstanding: 0 };
}

async function getBilledIncomeByCategory(supabase, date) {
  const { startUTC, endUTC } = istDayBoundsUTC(date);
  const [{ data: invoices }, { data: opticalSales }] = await Promise.all([
    supabase.from('invoices').select('id, net, paid').neq('status', 'Cancelled').gte('created_at', startUTC).lte('created_at', endUTC),
    supabase.from('optical_sales').select('id, net, paid').eq('sale_date', date).neq('status', 'Cancelled'),
  ]);
  const invoiceById = {};
  (invoices || []).forEach((i) => { invoiceById[i.id] = i; });
  const invoiceIds = Object.keys(invoiceById);

  const [{ data: lineItems }, { data: allocations }, { data: refunds }] = await Promise.all([
    invoiceIds.length > 0 ? supabase.from('invoice_line_items').select('invoice_id, dept, net').in('invoice_id', invoiceIds) : Promise.resolve({ data: [] }),
    // Every way an invoice's `paid` ever moved up, by type -- fresh
    // cash/UPI (invoice_payment, with its own mode breakdown), an
    // existing advance applied (advance_adjustment, no mode), or a
    // write-off (credit_note, no mode). Refunds are NOT in
    // payment_allocations (see payment_refunds below instead).
    invoiceIds.length > 0 ? supabase.from('payment_allocations').select('invoice_id, amount, payments(payment_type, total_amount, payment_modes(mode, amount))').in('invoice_id', invoiceIds) : Promise.resolve({ data: [] }),
    // refund_mode is the mode the refund itself went out on (set by
    // refund_payment() onto the refund's own payment_modes row too) --
    // used directly rather than joining back through the refund's own
    // payment, since payment_refunds has two FKs to payments and this
    // is simpler and already reliably populated.
    invoiceIds.length > 0 ? supabase.from('payment_refunds').select('invoice_id, amount, refund_mode').in('invoice_id', invoiceIds) : Promise.resolve({ data: [] }),
  ]);

  const invoiceDeptMap = {};
  (lineItems || []).forEach((li) => {
    if (!invoiceDeptMap[li.invoice_id]) invoiceDeptMap[li.invoice_id] = { totalNet: 0, byDept: {} };
    const entry = invoiceDeptMap[li.invoice_id];
    entry.totalNet += Number(li.net);
    const dept = li.dept || '(no dept set)';
    entry.byDept[dept] = (entry.byDept[dept] || 0) + Number(li.net);
  });

  // Gross fresh-cash payment for this invoice, split by mode -- a
  // payment can itself span Cash+UPI and be allocated across several
  // invoices, so each invoice's share of each mode is the payment's
  // mode amount times this allocation's share of the payment's total.
  const grossPaymentModeByInvoice = {}, advanceSettledByInvoice = {}, creditNoteSettledByInvoice = {};
  (allocations || []).forEach((a) => {
    const type = a.payments?.payment_type;
    const amt = Number(a.amount) || 0;
    if (type === 'invoice_payment') {
      const paymentTotal = Number(a.payments.total_amount) || 0;
      const invShare = paymentTotal > 0 ? amt / paymentTotal : 0;
      if (!grossPaymentModeByInvoice[a.invoice_id]) grossPaymentModeByInvoice[a.invoice_id] = {};
      (a.payments.payment_modes || []).forEach((m) => {
        grossPaymentModeByInvoice[a.invoice_id][m.mode] = (grossPaymentModeByInvoice[a.invoice_id][m.mode] || 0) + Number(m.amount) * invShare;
      });
    } else if (type === 'advance_adjustment') {
      advanceSettledByInvoice[a.invoice_id] = (advanceSettledByInvoice[a.invoice_id] || 0) + amt;
    } else if (type === 'credit_note') {
      creditNoteSettledByInvoice[a.invoice_id] = (creditNoteSettledByInvoice[a.invoice_id] || 0) + amt;
    }
  });
  const refundModeByInvoice = {};
  (refunds || []).forEach((r) => {
    if (!r.invoice_id) return;
    if (!refundModeByInvoice[r.invoice_id]) refundModeByInvoice[r.invoice_id] = {};
    const mode = r.refund_mode || 'Cash';
    refundModeByInvoice[r.invoice_id][mode] = (refundModeByInvoice[r.invoice_id][mode] || 0) + Number(r.amount);
  });

  const categories = {};
  const unclassifiedDepts = new Set();
  function addRow(name, delta) {
    if (!categories[name]) categories[name] = emptyBilledRow();
    const row = categories[name];
    row.billed += delta.billed || 0;
    row.netCash += delta.netCash || 0;
    row.netUPI += delta.netUPI || 0;
    row.advanceSettled += delta.advanceSettled || 0;
    row.creditNoteSettled += delta.creditNoteSettled || 0;
    row.outstanding += delta.outstanding || 0;
  }
  // Net = gross collected on that mode minus refunded on that mode,
  // for THIS invoice only -- a refund is always linked to one specific
  // invoice via payment_refunds.invoice_id, so there's no cross-invoice
  // leakage to worry about; "not previous invoices" is automatic since
  // this whole function only ever looks at today's invoiceIds.
  function netByMode(grossModes, refundModes) {
    const cash = (grossModes?.Cash || 0) - (refundModes?.Cash || 0);
    const upi = (grossModes?.UPI || 0) - (refundModes?.UPI || 0);
    return { netCash: cash, netUPI: upi };
  }

  invoiceIds.forEach((id) => {
    const inv = invoiceById[id];
    const outstanding = Number(inv.net) - Number(inv.paid);
    const grossModes = grossPaymentModeByInvoice[id];
    const refundModes = refundModeByInvoice[id];
    const { netCash, netUPI } = netByMode(grossModes, refundModes);
    const advSettled = advanceSettledByInvoice[id] || 0;
    const cnSettled = creditNoteSettledByInvoice[id] || 0;
    const entry = invoiceDeptMap[id];

    if (!entry || entry.totalNet <= 0) {
      unclassifiedDepts.add('(no line items on file for this invoice)');
      addRow('Unclassified', { billed: Number(inv.net), outstanding, netCash, netUPI, advanceSettled: advSettled, creditNoteSettled: cnSettled });
      return;
    }
    // Every figure for this invoice is prorated by each dept's share
    // of its net -- consistent with treating a multi-dept invoice's
    // payment/refund/write-off activity as spread proportionally
    // across its line items, same technique used throughout this file.
    Object.entries(entry.byDept).forEach(([dept, deptNet]) => {
      const share = deptNet / entry.totalNet;
      const category = DEPT_CATEGORY[dept];
      if (!category) unclassifiedDepts.add(dept);
      addRow(category || 'Unclassified', {
        billed: deptNet, outstanding: outstanding * share, netCash: netCash * share, netUPI: netUPI * share,
        advanceSettled: advSettled * share, creditNoteSettled: cnSettled * share,
      });
    });
  });

  // Optical has no line items to split across and no advance-
  // adjustment/credit-note mechanism -- a flat row, straight from each
  // sale's own net/paid plus its sale-linked payments/refunds.
  const opticalSaleIds = (opticalSales || []).map((s) => s.id);
  let opticalGrossModeBySale = {}, opticalRefundModeBySale = {};
  if (opticalSaleIds.length > 0) {
    const [{ data: opPayments }, { data: opRefunds }] = await Promise.all([
      supabase.from('optical_payments').select('sale_id, total_amount, optical_payment_modes(mode, amount)').eq('payment_type', 'sale_payment').in('sale_id', opticalSaleIds),
      supabase.from('optical_payment_refunds').select('sale_id, amount, refund_mode').in('sale_id', opticalSaleIds),
    ]);
    (opPayments || []).forEach((p) => {
      if (!opticalGrossModeBySale[p.sale_id]) opticalGrossModeBySale[p.sale_id] = {};
      (p.optical_payment_modes || []).forEach((m) => {
        opticalGrossModeBySale[p.sale_id][m.mode] = (opticalGrossModeBySale[p.sale_id][m.mode] || 0) + Number(m.amount);
      });
    });
    (opRefunds || []).forEach((r) => {
      if (!r.sale_id) return;
      if (!opticalRefundModeBySale[r.sale_id]) opticalRefundModeBySale[r.sale_id] = {};
      const mode = r.refund_mode || 'Cash';
      opticalRefundModeBySale[r.sale_id][mode] = (opticalRefundModeBySale[r.sale_id][mode] || 0) + Number(r.amount);
    });
  }
  categories['Optical Shop Sales'] = emptyBilledRow();
  (opticalSales || []).forEach((s) => {
    const { netCash, netUPI } = netByMode(opticalGrossModeBySale[s.id], opticalRefundModeBySale[s.id]);
    addRow('Optical Shop Sales', { billed: Number(s.net), outstanding: Number(s.net) - Number(s.paid), netCash, netUPI });
  });

  return { categories, unclassifiedDepts: [...unclassifiedDepts] };
}


// Splits today's total draw-down of a pooled advance balance (an
// advance-adjustment applied to an invoice, OR an advance refund) into
// "same-day" (a patient/customer deposited an advance today and it was
// drawn down today too) vs "previous-day" (the balance being drawn
// down was built up on an earlier visit) -- grouped by keyFn (patient
// for hospital, patient-or-optical-customer for optical, since walk-in
// optical customers often have no patient record), treating today's
// own new deposit as consumed first, up to whichever is smaller:
// today's new deposit for that person, or today's draw-down for that
// person. This is a conservative approximation (the advance ledger is
// a running balance, not a dated queue of individual rupees, so
// there's no way to know FOR CERTAIN which day's money got drawn
// down) -- but it never overstates "previous day", since any
// ambiguous amount is attributed to today's own deposit first.
function splitByAgeAgainstTodaysDeposit(depositTx, drawDownTx, keyFn = (p) => p.patient_id) {
  function sumByKey(txs) {
    const m = {};
    txs.forEach((p) => { const k = keyFn(p); m[k] = (m[k] || 0) + Number(p.total_amount || 0); });
    return m;
  }
  const depositByKey = sumByKey(depositTx);
  const drawDownByKey = sumByKey(drawDownTx);
  let previousDay = 0, sameDay = 0;
  Object.entries(drawDownByKey).forEach(([key, drawDownAmt]) => {
    const sameDayPortion = Math.min(depositByKey[key] || 0, drawDownAmt);
    sameDay += sameDayPortion;
    previousDay += drawDownAmt - sameDayPortion;
  });
  return { previousDay, sameDay };
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
// Collections by Department -- built from actual payments collected
// today, not invoices raised today. Those are genuinely different
// numbers (an invoice can be raised today but paid later, paid
// earlier against an advance, or only partially paid today), so the
// old invoice-based version could never be guaranteed to sum to the
// day's real Total Collected (getTodayCollectionSummary below).
// Advance is its own line here -- a standalone advance payment (no
// invoice yet) was previously invisible in this breakdown entirely,
// which was exactly why the two totals could disagree. Same
// payment_type filter and refund sign convention as
// getTodayCollectionSummary uses for Total, on purpose: these two
// numbers must always be constructible from the same underlying
// payments, or "sum of the parts" and "the total" will keep drifting
// apart for someone reconciling the day.
//
// Two different tables carry the invoice link depending on
// payment_type -- there's no single "payments.invoice_id" column:
//   - invoice_payment: payment_allocations (payment_id -> [{invoice_id,
//     amount}]) -- ONE payment can settle bills spanning MULTIPLE
//     departments (e.g. a single receipt covering an OPD consultation
//     and a pharmacy bill), so it's split across each allocation's own
//     invoice, not attributed whole to one department.
//   - refund: payment_refunds (refund_payment_id -> invoice_id) -- a
//     refund's own payments row never gets a payment_allocations
//     entry at all; invoice_id there is null for an advance refund
//     (refund_advance), in which case it nets against Advance rather
//     than a department.
export async function getRevenueByDepartmentToday() {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC();

  const [{ data: payments }, { data: opticalPayments }] = await Promise.all([
    supabase
      .from('payments')
      .select('id, payment_type, total_amount')
      .gte('collected_at', startUTC)
      .lte('collected_at', endUTC)
      .in('payment_type', ['invoice_payment', 'advance', 'refund']),
    // Optical sales/advances are real cash collected today too, via a
    // separate table (see app/(main)/optical) since walk-in customers
    // often have no patient record. advance_adjustment is excluded --
    // that's an existing balance being applied, not new cash arriving
    // today. Refunds subtract from the same Optical bucket, same as
    // how a hospital refund subtracts from its own department.
    supabase
      .from('optical_payments')
      .select('total_amount, payment_type')
      .gte('collected_at', startUTC)
      .lte('collected_at', endUTC)
      .in('payment_type', ['sale_payment', 'advance', 'refund']),
  ]);

  const invoicePaymentIds = (payments || []).filter((p) => p.payment_type === 'invoice_payment').map((p) => p.id);
  const refundIds = (payments || []).filter((p) => p.payment_type === 'refund').map((p) => p.id);

  const [{ data: allocations }, { data: refunds }] = await Promise.all([
    invoicePaymentIds.length > 0
      ? supabase.from('payment_allocations').select('payment_id, amount, invoices(purpose)').in('payment_id', invoicePaymentIds)
      : Promise.resolve({ data: [] }),
    refundIds.length > 0
      ? supabase.from('payment_refunds').select('refund_payment_id, invoices(purpose)').in('refund_payment_id', refundIds)
      : Promise.resolve({ data: [] }),
  ]);

  let allocationsByPayment = {};
  (allocations || []).forEach((a) => {
    if (!allocationsByPayment[a.payment_id]) allocationsByPayment[a.payment_id] = [];
    allocationsByPayment[a.payment_id].push(a);
  });

  let refundInfoByPayment = {};
  (refunds || []).forEach((r) => { refundInfoByPayment[r.refund_payment_id] = r; });

  const byDept = {};
  (payments || []).forEach((p) => {
    if (p.payment_type === 'advance') {
      byDept.Advance = (byDept.Advance || 0) + Number(p.total_amount);
      return;
    }
    if (p.payment_type === 'invoice_payment') {
      const allocs = allocationsByPayment[p.id];
      if (allocs && allocs.length > 0) {
        allocs.forEach((a) => {
          const dept = a.invoices?.purpose || 'Other';
          byDept[dept] = (byDept[dept] || 0) + Number(a.amount);
        });
      } else {
        // Shouldn't happen for a genuine invoice_payment, but the
        // money still collected today either way -- never drop it
        // silently just because it has no allocation on record.
        byDept.Other = (byDept.Other || 0) + Number(p.total_amount);
      }
      return;
    }
    // refund
    const dept = refundInfoByPayment[p.id]?.invoices?.purpose || 'Advance';
    byDept[dept] = (byDept[dept] || 0) - Number(p.total_amount);
  });

  (opticalPayments || []).forEach((p) => {
    byDept.Optical = (byDept.Optical || 0) + (p.payment_type === 'refund' ? -Number(p.total_amount) : Number(p.total_amount));
  });

  return byDept;
}

export async function getTodayCollectionSummary(date) {
  const supabase = await createClient();
  const { startUTC, endUTC } = istDayBoundsUTC(date);

  const [{ data: payments }, { data: opticalPayments }] = await Promise.all([
    supabase
      .from('payments')
      .select('*, payment_modes(mode, amount), patients(first_name, salutation, last_name)')
      .gte('collected_at', startUTC)
      .lte('collected_at', endUTC)
      .order('collected_at', { ascending: false }),
    // Optical sales/advances are real cash collected today too, via a
    // separate table (see app/(main)/optical) since walk-in customers
    // often have no patient record. Folded in here -- not just
    // displayed alongside -- so Total Collected/Cash/UPI/Card, the
    // department breakdown, the transactions list, and (via byMode)
    // the Close Day reconciliation's expected-cash figure all reflect
    // it consistently, rather than the drawer count including optical
    // cash while "expected" silently didn't.
    supabase
      .from('optical_payments')
      .select('id, receipt_number, payment_type, total_amount, collected_at, patient_id, optical_customer_id, optical_payment_modes(mode, amount), patients(first_name, salutation, last_name), optical_customers(name)')
      .gte('collected_at', startUTC)
      .lte('collected_at', endUTC)
      .order('collected_at', { ascending: false }),
  ]);

  const opticalRows = (opticalPayments || []).map((p) => ({
    id: `optical-${p.id}`,
    source: 'optical',
    receipt_number: p.receipt_number,
    payment_type: p.payment_type,
    total_amount: p.total_amount,
    collected_at: p.collected_at,
    payment_modes: p.optical_payment_modes,
    patients: p.patients,
    patient_id: p.patient_id,
    optical_customer_id: p.optical_customer_id,
    opticalCustomerName: p.optical_customers?.name,
  }));

  const rows = [...(payments || []), ...opticalRows].sort((a, b) => new Date(b.collected_at) - new Date(a.collected_at));

  const isRefund = (p) => p.payment_type === 'refund';
  // advance_adjustment and credit_note both insert a payments row dated
  // today (when the reallocation happens), but no cash actually moves
  // that day -- the money was already received (advance) or was never
  // received at all (credit note, a write-off). Including them here is
  // exactly how an advance collected on a previous date ends up looking
  // like fresh cash in today's total. byMode is unaffected already,
  // since neither type ever gets a payment_modes row. sale_payment is
  // optical's equivalent of invoice_payment -- real cash, counted.
  const isCashMovement = (p) => ['invoice_payment', 'advance', 'refund', 'sale_payment'].includes(p.payment_type);

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

export async function getDailyReport(date) {
  const supabase = await createClient();
  const [{ data: closing }, { data: reconciliation }, expenses, collectionSummary] = await Promise.all([
    supabase.from('day_closings').select('*, profiles(full_name)').eq('closing_date', date).maybeSingle(),
    supabase.from('day_reconciliation').select('*, profiles(full_name)').eq('closing_date', date),
    getExpensesForDate(date),
    // Same underlying query the Reconciliation tab uses, so the
    // report's numbers can never drift from what Front Office actually
    // reconciled against -- advance_adjustment/credit_note excluded
    // (no real cash moved), refund netted negative. Optical rows are
    // already merged in here (see getTodayCollectionSummary).
    getTodayCollectionSummary(date),
  ]);

  // Hospital-only, real cash collected -- used for Table 1's "Payments
  // against Hospital Billed Items" row. Table 2 (billed value,
  // regardless of collection status) is computed separately below via
  // getBilledIncomeByCategory, straight from invoice_line_items.
  const billedTx = collectionSummary.transactions.filter((p) => p.payment_type === 'invoice_payment');
  // 'sale_payment' only exists on optical_payments rows -- unambiguous.
  const opticalSaleTx = collectionSummary.transactions.filter((p) => p.payment_type === 'sale_payment');
  const advanceTx = collectionSummary.transactions.filter((p) => p.payment_type === 'advance');
  const hospitalAdvanceTx = advanceTx.filter((p) => p.source !== 'optical');
  const opticalAdvanceTx = advanceTx.filter((p) => p.source === 'optical');
  const refundTx = collectionSummary.transactions.filter((p) => p.payment_type === 'refund');
  const creditNoteTx = collectionSummary.transactions.filter((p) => p.payment_type === 'credit_note');
  // Advance applied against an invoice today (e.g. a surgery invoiced
  // today, paid from an advance collected on an earlier day) -- no new
  // cash moves, so this is correctly excluded from Billed Items/
  // Payment Mode Summary above. But the revenue still needs to show up
  // somewhere on invoice day, or Surgery Income would read Rs.0 for a
  // surgery that was fully settled from advance. Categorized the same
  // way as billedTx, kept as a separate "advanceAdjusted" figure per
  // category rather than merged into the cash totals -- Payment Mode
  // Summary stays a pure "what actually moved today" figure, while
  // each Income category shows both its cash total and, separately,
  // how much more was recognized today via an advance applied today.
  const adjustmentTx = collectionSummary.transactions.filter((p) => p.payment_type === 'advance_adjustment');

  // Refunds are split two ways in this report: Payment Mode Summary
  // (Table 1) just needs hospital-vs-optical, gross, as their own
  // rows -- no further tracing needed. Day Totals (Table 3) needs
  // more: whether each refund was against an invoice/sale/advance
  // deposited TODAY or on an earlier day, since only a refund against
  // something from a PREVIOUS day is real cash out that today's
  // Revenue/Outstanding/Advance-Collected figures don't already
  // account for. payment_refunds/optical_payment_refunds carry the
  // invoice/sale link (payment_allocations does NOT -- a refund is
  // never itself allocated to an invoice the way a payment is); the
  // advance side has no such link at all (the advance balance is a
  // pooled running total, not a dated queue), so that's approximated
  // the same conservative same-day-first way as Advance Adjustment.
  const hospitalRefundTx = refundTx.filter((p) => p.source !== 'optical');
  const opticalRefundTx = refundTx.filter((p) => p.source === 'optical');
  const [{ data: refundLinks }, { data: opticalRefundLinks }] = await Promise.all([
    hospitalRefundTx.length > 0
      ? supabase.from('payment_refunds').select('refund_payment_id, invoice_id').in('refund_payment_id', hospitalRefundTx.map((p) => p.id))
      : Promise.resolve({ data: [] }),
    opticalRefundTx.length > 0
      ? supabase.from('optical_payment_refunds').select('refund_payment_id, sale_id').in('refund_payment_id', opticalRefundTx.map((p) => p.id.replace('optical-', '')))
      : Promise.resolve({ data: [] }),
  ]);
  const invoiceIdByRefundPaymentId = {};
  (refundLinks || []).forEach((r) => { if (r.invoice_id) invoiceIdByRefundPaymentId[r.refund_payment_id] = r.invoice_id; });
  const saleIdByRefundPaymentId = {};
  (opticalRefundLinks || []).forEach((r) => { if (r.sale_id) saleIdByRefundPaymentId[r.refund_payment_id] = r.sale_id; });

  const invoiceRefundTx = hospitalRefundTx.filter((p) => invoiceIdByRefundPaymentId[p.id]);
  const advanceRefundTx = hospitalRefundTx.filter((p) => !invoiceIdByRefundPaymentId[p.id]);
  const opticalSaleRefundTx = opticalRefundTx.filter((p) => saleIdByRefundPaymentId[p.id.replace('optical-', '')]);
  const opticalAdvanceRefundTx = opticalRefundTx.filter((p) => !saleIdByRefundPaymentId[p.id.replace('optical-', '')]);

  // For invoice/sale-linked refunds, look up when that invoice/sale
  // was actually created -- a refund against something billed on a
  // PREVIOUS day is real cash out today that Total Revenue/Outstanding
  // (both scoped to today's own invoices/sales) never captures.
  const refundedInvoiceIds = [...new Set(Object.values(invoiceIdByRefundPaymentId))];
  const refundedSaleIds = [...new Set(Object.values(saleIdByRefundPaymentId))];
  const [{ data: refundedInvoices }, { data: refundedSales }] = await Promise.all([
    refundedInvoiceIds.length > 0 ? supabase.from('invoices').select('id, created_at').in('id', refundedInvoiceIds) : Promise.resolve({ data: [] }),
    refundedSaleIds.length > 0 ? supabase.from('optical_sales').select('id, sale_date').in('id', refundedSaleIds) : Promise.resolve({ data: [] }),
  ]);
  const invoiceCreatedDate = {};
  (refundedInvoices || []).forEach((i) => { invoiceCreatedDate[i.id] = toISTDateStr(i.created_at); });
  const saleDate = {};
  (refundedSales || []).forEach((s) => { saleDate[s.id] = s.sale_date; });

  const refundsAgainstPreviousInvoices =
    invoiceRefundTx.filter((p) => invoiceCreatedDate[invoiceIdByRefundPaymentId[p.id]] !== date).reduce((s, p) => s + (Number(p.total_amount) || 0), 0)
    + opticalSaleRefundTx.filter((p) => saleDate[saleIdByRefundPaymentId[p.id.replace('optical-', '')]] !== date).reduce((s, p) => s + (Number(p.total_amount) || 0), 0);

  // Advance refunds have no invoice/sale to check the date of -- same
  // same-day-first approximation used for Advance Adjustment Applied,
  // computed separately per subsystem since hospital and optical each
  // keep their own pooled advance balance. Optical customers often
  // have no patient_id (walk-ins), hence the fallback key.
  const opticalPersonKey = (p) => p.patient_id || p.optical_customer_id;
  const hospitalAdvanceRefundAge = splitByAgeAgainstTodaysDeposit(hospitalAdvanceTx, advanceRefundTx);
  const opticalAdvanceRefundAge = splitByAgeAgainstTodaysDeposit(opticalAdvanceTx, opticalAdvanceRefundTx, opticalPersonKey);
  const refundsAgainstPreviousAdvances = hospitalAdvanceRefundAge.previousDay + opticalAdvanceRefundAge.previousDay;
  // Advance Collected for Day Totals -- today's fresh deposits, net of
  // whatever was refunded same-day (that money never really stuck
  // around as an advance balance at all). A previous-day advance being
  // refunded today does NOT reduce this -- it's accounted for by
  // refundsAgainstPreviousAdvances instead, since today's deposit is
  // untouched by it.
  const advanceCollectedNet =
    (hospitalAdvanceTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0) - hospitalAdvanceRefundAge.sameDay)
    + (opticalAdvanceTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0) - opticalAdvanceRefundAge.sameDay);

  const creditNotesTotal = creditNoteTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0);

  // Table 2 (Billed Income by Category) is pure billing-truth: the
  // full invoiced/sale value for today, by category, plus a full
  // breakdown of how it's been settled (or not) -- this is deliberately
  // NOT payment-mode-based (Table 1 already covers cash by mode).
  const { categories: billedCategories, unclassifiedDepts } = await getBilledIncomeByCategory(supabase, date);
  const emptyRow = () => ({ billed: 0, netCash: 0, netUPI: 0, advanceSettled: 0, creditNoteSettled: 0, outstanding: 0 });
  const catRow = (name) => billedCategories[name] || emptyRow();
  const { previousDay: previousAdvanceAdjustedTotal, sameDay: sameDayAdvanceAdjustedTotal } = splitByAgeAgainstTodaysDeposit(advanceTx, adjustmentTx);

  return {
    closing, reconciliation: reconciliation || [], expenses,
    // ---- TABLE 1: Payment Mode Summary -- six gross rows straight
    // from Payments, no netting or attribution logic. Grand Total
    // (modeSummary) is the only figure derived (sum of all six, with
    // the two refund rows subtracted) -- the actual cash movement.
    hospitalBilledItems: modeBreakdown(billedTx),
    opticalBilledItems: modeBreakdown(opticalSaleTx),
    hospitalAdvances: modeBreakdown(hospitalAdvanceTx),
    opticalAdvances: modeBreakdown(opticalAdvanceTx),
    hospitalRefunds: modeBreakdown(hospitalRefundTx, true),
    opticalRefunds: modeBreakdown(opticalRefundTx, true),
    modeSummary: { byMode: collectionSummary.byMode, total: collectionSummary.total },
    // ---- TABLE 2: Billed Income by Category -- pure billing-truth, no
    // mode/cash dimension at all (that's Table 1's job). Each row is
    // individually self-checking: billed == outstanding +
    // paymentCollected + advanceSettled + creditNoteSettled - refunds.
    // Advances themselves are category-agnostic (deposited before
    // being tied to any bill), so they're a single summary row below
    // rather than a column repeated on every category.
    billedCategories: {
      'OPD Consultation charges': catRow('OPD Consultation charges'),
      'Procedure charges': catRow('Procedure charges'),
      'Investigation charges': catRow('Investigation charges'),
      Pharmacy: catRow('Pharmacy'),
      'Surgery Income': catRow('Surgery Income'),
      'Optical Shop Sales': catRow('Optical Shop Sales'),
      Unclassified: catRow('Unclassified'),
    },
    advancesSummary: {
      // Gross, matching Table 1's Hospital/Optical Advances rows.
      collected: hospitalAdvanceTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0) + opticalAdvanceTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0),
      // Advance refunds only -- invoice/sale-linked refunds are
      // already inside their category's row above, not here.
      refunds: advanceRefundTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0) + opticalAdvanceRefundTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0),
    },
    unclassifiedDepts,
    // ---- TABLE 3: Day Totals -- reconciles Table 1 and Table 2.
    // Total Collected (modeSummary.total above) should equal:
    //   Total Revenue - Outstanding - Advance Adjustment Applied
    //   - Credit Notes - Refunds against Previous Invoices
    //   - Refunds against Previous Advances + Advance Collected
    previousAdvanceAdjustedTotal,
    sameDayAdvanceAdjustedTotal,
    creditNotesTotal,
    advanceCollectedNet,
    refundsAgainstPreviousInvoices,
    refundsAgainstPreviousAdvances,
    // Total refunds today, kept only as a reference figure -- Table 1
    // already shows Hospital/Optical Refunds as their own rows.
    totalRefundsToday: refundTx.reduce((s, p) => s + (Number(p.total_amount) || 0), 0),
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

// ---------- Reconciliation lock (Step 1 -- gates Cash Counter) ----------

export async function getReconciliationLockStatus(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data } = await supabase.from('reconciliation_locks').select('*, profiles(full_name)').eq('lock_date', targetDate).maybeSingle();
  return data ? { locked: true, lockedBy: data.profiles?.full_name || null, lockedAt: data.locked_at } : { locked: false, lockedBy: null, lockedAt: null };
}

export async function lockReconciliation() {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;
  const supabase = await createClient();
  const today = todayIST();

  // Every mode with today's collection activity must already be
  // reconciled (saved) before Step 1 can be marked complete -- same
  // completeness idea close_day itself enforces for the whole day.
  const [summary, pettyCashTotal, { data: saved }] = await Promise.all([
    getTodayCollectionSummary(today),
    getPettyCashTotal(today),
    supabase.from('day_reconciliation').select('mode').eq('closing_date', today),
  ]);
  const modes = new Set(Object.keys(summary.byMode));
  if (pettyCashTotal > 0) modes.add('Cash');
  const savedModes = new Set((saved || []).map((r) => r.mode));
  const missing = [...modes].filter((m) => !savedModes.has(m));
  if (missing.length > 0) {
    return { error: `Save reconciliation for ${missing.join(', ')} first.` };
  }

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('reconciliation_locks').upsert(
    { lock_date: today, locked_by: userData?.user?.id || null }, { onConflict: 'lock_date' }
  );
  if (error) return { error: error.message };
  return { success: true };
}

export async function unlockReconciliation() {
  const supabase = await createClient();
  const today = todayIST();
  const { error } = await supabase.from('reconciliation_locks').delete().eq('lock_date', today);
  if (error) return { error: error.message };
  return { success: true };
}

// ---------- Cash Counter (Step 2) ----------
// Opening cash is never duplicated -- read live from
// day_openings.opening_cash_balance. Cash Handed Over is never typed
// in either -- it's computed from Opening Cash + Step 1's reconciled
// Cash-mode actual (which is already net of today's Cash Expenses --
// see getReconciliationData, don't subtract expenses again here),
// minus the Closing Cash count (the float retained by the cashier for
// the next day) -- so the only thing anyone enters here is that
// closing/retained count itself.

export async function getCashCounterForDate(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const [{ data: opening }, { data: counter }, lockStatus, { data: cashRecon }] = await Promise.all([
    supabase.from('day_openings').select('opening_cash_balance, opened_at, profiles(full_name)').eq('opening_date', targetDate).maybeSingle(),
    supabase.from('cash_counter').select('*, closer:profiles!cash_counter_closing_recorded_by_fkey(full_name), handedOverByProfile:profiles!cash_counter_handed_over_by_fkey(full_name)')
      .eq('counter_date', targetDate).maybeSingle(),
    getReconciliationLockStatus(targetDate),
    supabase.from('day_reconciliation').select('actual').eq('closing_date', targetDate).eq('mode', 'Cash').maybeSingle(),
  ]);
  const openingCash = opening?.opening_cash_balance != null ? Number(opening.opening_cash_balance) : 0;
  // Step 1's saved Cash-mode "actual" is already net of today's Cash
  // Expenses -- getReconciliationData computes that mode's `expected`
  // as rawExpected - pettyCashTotal, and staff reconcile `actual`
  // against that already-net figure. So expenses must NOT be
  // subtracted again here, or they get deducted twice.
  const reconciledCashActual = cashRecon?.actual != null ? Number(cashRecon.actual) : 0;
  const closingCashValue = counter?.closing_cash != null ? Number(counter.closing_cash) : null;

  return {
    date: targetDate,
    openingCash: opening?.opening_cash_balance ?? null,
    openedBy: opening?.profiles?.full_name || null,
    reconciliationLocked: lockStatus.locked,
    reconciledCashActual,
    // Only computable once the closing/retained count is in -- null until then.
    computedHandover: closingCashValue != null ? (openingCash + reconciledCashActual - closingCashValue) : null,
    closingCash: counter?.closing_cash ?? null,
    closingRecordedBy: counter?.closer?.full_name || null,
    closingRecordedAt: counter?.closing_recorded_at || null,
    amountHandedOver: counter?.amount_handed_over ?? null,
    handedOverBy: counter?.handedOverByProfile?.full_name || null,
    handedOverAt: counter?.handed_over_at || null,
  };
}

export async function recordClosingCash(amount, date) {
  const targetDate = date || todayIST();
  const supabase = await createClient();
  // Same check requireDayOpen() does for "today", but generalized to
  // any date so this can also run for a past unclosed day -- which by
  // definition already has a day_openings row (that's what makes it
  // eligible for the Close a Past Day flow), so this is really just a
  // safety check, not a real-world blocker for that path.
  const { data: openingRow } = await supabase.from('day_openings').select('id').eq('opening_date', targetDate).maybeSingle();
  if (!openingRow) return { error: `${targetDate} hasn't been opened -- can't record its Cash Counter.` };
  const lockStatus = await getReconciliationLockStatus(targetDate);
  if (!lockStatus.locked) return { error: 'Complete and close Reconciliation (Step 1) first.' };
  const amt = Number(amount);
  if (isNaN(amt) || amt < 0) return { error: 'Enter a valid amount.' };

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('cash_counter').upsert({
    counter_date: targetDate, closing_cash: amt, closing_recorded_by: userData?.user?.id || null, closing_recorded_at: new Date().toISOString(),
  }, { onConflict: 'counter_date' });
  if (error) return { error: error.message };
  return { success: true };
}

// Confirms Cash Counter for the day -- no manual amount needed, it's
// the same computedHandover the UI already shows.
export async function confirmCashCounter(date) {
  const targetDate = date || todayIST();
  const supabase = await createClient();
  const { data: openingRow } = await supabase.from('day_openings').select('id').eq('opening_date', targetDate).maybeSingle();
  if (!openingRow) return { error: `${targetDate} hasn't been opened -- can't confirm its Cash Counter.` };

  const lockStatus = await getReconciliationLockStatus(targetDate);
  if (!lockStatus.locked) return { error: 'Complete and close Reconciliation (Step 1) first.' };

  const [{ data: existing }, counterState] = await Promise.all([
    supabase.from('cash_counter').select('closing_cash').eq('counter_date', targetDate).maybeSingle(),
    getCashCounterForDate(targetDate),
  ]);
  if (!existing || existing.closing_cash === null) {
    return { error: 'Record the closing cash count first.' };
  }
  const computedHandover = counterState.computedHandover;

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('cash_counter').update({
    amount_handed_over: computedHandover, handed_over_by: userData?.user?.id || null, handed_over_at: new Date().toISOString(),
  }).eq('counter_date', targetDate);
  if (error) return { error: error.message };
  return { success: true };
}

export async function unlockCashCounter(date) {
  const targetDate = date || todayIST();
  const supabase = await createClient();
  const { error } = await supabase.from('cash_counter').delete().eq('counter_date', targetDate);
  if (error) return { error: error.message };
  return { success: true };
}

// Defaults to the last 2 days -- a specific older date can still be
// looked up directly via getCashCounterForDate(date).
export async function getCashCounterHistory(limit = 2) {
  const supabase = await createClient();
  const { data: openings } = await supabase.from('day_openings').select('opening_date, opening_cash_balance').order('opening_date', { ascending: false }).limit(limit);
  const { data: counters } = await supabase.from('cash_counter')
    .select('*, handedOverByProfile:profiles!cash_counter_handed_over_by_fkey(full_name)')
    .order('counter_date', { ascending: false }).limit(limit);
  const counterByDate = {};
  (counters || []).forEach((c) => { counterByDate[c.counter_date] = c; });

  return (openings || []).map((o) => {
    const c = counterByDate[o.opening_date];
    return {
      date: o.opening_date,
      openingCash: o.opening_cash_balance,
      closingCash: c?.closing_cash ?? null,
      amountHandedOver: c?.amount_handed_over ?? null,
      handedOverBy: c?.handedOverByProfile?.full_name || null,
    };
  });
}
