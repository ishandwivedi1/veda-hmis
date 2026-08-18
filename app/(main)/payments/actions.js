'use server';

import { after } from 'next/server';
import { createClient } from '@/lib/supabase-server';
import { requireDayOpen, getTodayCollectionSummary, getRevenueByDepartmentToday, getDayOpening, isTodayOpen } from '@/app/(main)/cash-management/actions';
import { sendInvoiceBill } from '@/app/(main)/billing/actions';
import { sendAdvanceReceiptWhatsApp, sendPaymentReceiptWhatsApp, formatDateOnlyIST } from '@/lib/whatsapp';
import { generateReceiptPdfBuffer } from '@/lib/pdf-generator';
import { logJourneyEvent } from '@/lib/journey-events';

// Everything the Payments Dashboard needs, fetched in parallel -- one
// round trip per query, not sequential, since this loads on every visit
// to the dashboard.
export async function getPaymentsDashboardData() {
  const [
    summary, revenueByDept, unpaidInvoices, advanceBalances,
    recentReceipts, dayOpening, dayOpen,
  ] = await Promise.all([
    getTodayCollectionSummary(),
    getRevenueByDepartmentToday(),
    getAllUnpaidInvoices(),
    getCurrentBalancesByPatient(),
    searchReceipts(),
    getDayOpening(),
    isTodayOpen(),
  ]);

  const outstandingTotal = unpaidInvoices.reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);
  const advanceTotal = advanceBalances.reduce((s, p) => s + p.balance, 0);

  return {
    summary,
    revenueByDept,
    outstandingTotal,
    outstandingCount: unpaidInvoices.length,
    topOutstanding: [...unpaidInvoices].sort((a, b) => (b.net - b.paid) - (a.net - a.paid)).slice(0, 5),
    advanceTotal,
    advanceCount: advanceBalances.length,
    topAdvances: [...advanceBalances].sort((a, b) => b.balance - a.balance).slice(0, 5),
    recentReceipts: recentReceipts.slice(0, 8),
    dayOpening,
    dayOpen,
  };
}

export async function getTodaysVisits() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function getPatientById(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  if (error) return { error: error.message };
  return { patient: data };
}

export async function getAllUnpaidInvoices() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at, patients(id, first_name, last_name, uhid)')
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── CREDIT NOTES ──
export async function getApprovers() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name, designation').eq('status', 'Active').order('full_name');
  return data || [];
}

export async function createCreditNote(patientId, invoiceId, amount, reason, approvedBy, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_credit_note', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_approved_by: approvedBy,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function getCreditNoteRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('credit_notes')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!credit_notes_approved_by_fkey(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── UNIFIED PATIENT LEDGER (Invoice / Payment / Advance / Advance
// Adjustment / Credit Note / Refund, interleaved with a running
// balance). patient_ledger itself is deliberately NOT a source here --
// it's an internal advance-balance tracker (get_advance_balance sums
// it), and every event it records already has a richer counterpart in
// payments/invoices/credit_notes, so including both would double-count.
export async function getPatientUnifiedLedger(patientId) {
  const supabase = await createClient();

  const [{ data: invoices }, { data: payments }, { data: refunds }, { data: creditNotes }] = await Promise.all([
    supabase.from('invoices').select('id, invoice_number, net, status, created_at, visits(visit_number)').eq('patient_id', patientId),
    supabase.from('payments').select('*, payment_modes(mode, amount)').eq('patient_id', patientId),
    supabase.from('payment_refunds').select('*, refund_payment:payments!payment_refunds_refund_payment_id_fkey(receipt_number), invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
    supabase.from('credit_notes').select('*, invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
  ]);

  const PAYMENT_TYPE_LABEL = { advance: 'Advance', advance_adjustment: 'Advance Adjustment', credit_note: 'Credit Note' };

  const entries = [];

  (invoices || []).forEach((inv) => {
    entries.push({
      date: inv.created_at, type: 'Invoice', ref: inv.invoice_number, visit: inv.visits?.visit_number || '--',
      desc: `Invoice ${inv.invoice_number}`, debit: Number(inv.net), credit: 0, by: 'System',
    });
  });

  // Every refund (invoice-based or from advance) now has exactly one
  // payment_refunds row -- its companion payments row (created purely
  // for Receipt visibility) is always skipped here to avoid double
  // counting.
  (payments || []).forEach((p) => {
    if (p.payment_type === 'credit_note' || p.payment_type === 'refund') return;
    const type = PAYMENT_TYPE_LABEL[p.payment_type] || 'Payment';
    const modeDesc = (p.payment_modes || []).map((m) => m.mode).join('+') || 'Advance';
    entries.push({
      date: p.collected_at, type, ref: p.receipt_number, visit: '--',
      desc: `${type} via ${modeDesc}${p.remarks ? ' -- ' + p.remarks : ''}`, debit: 0, credit: Number(p.total_amount), by: 'Staff',
    });
  });

  (refunds || []).forEach((r) => {
    const desc = r.invoice_id
      ? `Refund against ${r.invoices?.invoice_number || '--'} -- ${r.reason}`
      : `Refund from advance -- ${r.reason}`;
    entries.push({
      date: r.refunded_at, type: 'Refund', ref: r.refund_payment?.receipt_number || '--', visit: r.invoices?.visits?.visit_number || '--',
      desc, debit: Number(r.amount), credit: 0, by: 'Staff',
    });
  });

  (creditNotes || []).forEach((cn) => {
    entries.push({
      date: cn.created_at, type: 'Credit Note', ref: cn.credit_note_number, visit: cn.invoices?.visits?.visit_number || '--',
      desc: `${cn.reason} -- against ${cn.invoices?.invoice_number || '--'}`, debit: 0, credit: Number(cn.amount), by: 'Staff',
    });
  });

  entries.sort((a, b) => new Date(a.date) - new Date(b.date));

  let balance = 0;
  entries.forEach((e) => {
    balance += e.debit - e.credit;
    e.balance = balance;
  });

  return entries.reverse(); // newest first for display
}

// ── EDIT PAYMENT (clerical corrections only -- mode/reference/remarks,
// never amount) ──
// expectedModeCount is an optimistic-concurrency guard -- the number of
// payment_modes rows the client saw when the edit form was opened
// (fetched fresh via getReceiptById, not from a stale search-results
// list). If the server finds a different count right now, something
// changed underneath this edit (another tab, a retried/double submit,
// a stale page) and the RPC refuses rather than silently stacking modes
// on top of whatever's actually there.
export async function editPaymentClerical(paymentId, modes, reference, remarks, reason, expectedModeCount) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('edit_payment_clerical', {
    p_payment_id: paymentId,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_reason: reason,
    p_expected_mode_count: typeof expectedModeCount === 'number' ? expectedModeCount : null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getPaymentEditHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase.from('payment_edits').select('*, profiles(full_name)').eq('payment_id', paymentId).order('edited_at', { ascending: false });
  return data || [];
}

// ── REFUND (patient-first flow) ──
export async function getPatientPayments(patientId) {
  const supabase = await createClient();
  const { data: payments } = await supabase
    .from('payments')
    .select('*, payment_modes(mode, amount), payment_allocations(id, invoice_id, amount, invoices(invoice_number))')
    .eq('patient_id', patientId)
    .order('collected_at', { ascending: false });

  const rows = payments || [];
  const paymentIds = rows.map((p) => p.id);

  let refundedByPaymentInvoice = {};
  if (paymentIds.length > 0) {
    const { data: refunds } = await supabase.from('payment_refunds').select('payment_id, invoice_id, amount').in('payment_id', paymentIds);
    (refunds || []).forEach((r) => {
      const key = `${r.payment_id}:${r.invoice_id}`;
      refundedByPaymentInvoice[key] = (refundedByPaymentInvoice[key] || 0) + Number(r.amount);
    });
  }

  return rows.map((p) => ({
    ...p,
    payment_allocations: (p.payment_allocations || []).map((a) => {
      const alreadyRefunded = refundedByPaymentInvoice[`${p.id}:${a.invoice_id}`] || 0;
      return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
    }),
  }));
}

export async function refundAdvance(patientId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_advance', {
    p_patient_id: patientId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getRefundRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!payment_refunds_approved_by_fkey(full_name)')
    .order('refunded_at', { ascending: false })
    .limit(50);
  return data || [];
}

export async function searchPatientsForPayment(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getOutstandingInvoices(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at')
    .eq('patient_id', patientId)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true }); // oldest first, matches allocation order
  return data || [];
}

// ── ADVANCE ──
export async function getAdvanceBalance(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_advance_balance', { p_patient_id: patientId });
  if (error) return 0;
  return data || 0;
}

export async function collectAdvance(patientId, advanceType, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_advance', {
    p_patient_id: patientId,
    p_advance_type: advanceType,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };

  // Auto-send WhatsApp confirmation for advance payments only (regular
  // invoice payments are not auto-sent -- only via the manual Receipt
  // button). Deferred with after() so this never adds latency to the
  // collection response, same fix as applied to collectPayment.
  try {
    const { data: { user } } = await supabase.auth.getUser();
    const { data: patient } = await supabase
      .from('patients')
      .select('id, first_name, last_name, mobile')
      .eq('id', patientId)
      .single();
    const triggeredBy = user?.id || null;

    if (patient?.mobile) {
      after(async () => {
        try {
          const pdfResult = await generateReceiptPdfBuffer(data.id);
          if (pdfResult.error) {
            console.error('Advance receipt PDF generation failed:', pdfResult.error);
            return;
          }
          await sendAdvanceReceiptWhatsApp({
            name: `${patient.first_name} ${patient.last_name}`.trim(),
            amount: data.total_amount,
            receiptNumber: data.receipt_number,
            date: formatDateOnlyIST(data.collected_at),
            mobile: patient.mobile,
            pdfBuffer: pdfResult.buffer,
            filename: `${data.receipt_number || 'Receipt'}.pdf`,
            patientDbId: patient.id,
            meta: { module: 'advance_payment', triggeredBy },
          });
        } catch (waErr) {
          console.error('WhatsApp advance payment send failed:', waErr.message);
        }
      });
    }
  } catch (waErr) {
    console.error('WhatsApp advance payment setup failed (advance already collected):', waErr.message);
  }

  return { payment: data };
}

export async function getCurrentBalancesByPatient() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('patient_id, amount, patients(id, first_name, last_name, uhid)');
  if (!data) return [];

  const byPatient = {};
  data.forEach((entry) => {
    if (!byPatient[entry.patient_id]) {
      byPatient[entry.patient_id] = { patient: entry.patients, balance: 0 };
    }
    byPatient[entry.patient_id].balance += Number(entry.amount);
  });
  return Object.values(byPatient).filter((p) => p.balance > 0);
}

export async function getLedgerHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*, patients(id, first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
    .order('recorded_at', { ascending: false })
    .limit(30);
  return data || [];
}
// ── ADJUSTMENTS ──
export async function getPatientLedgerAudit(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*')
    .eq('patient_id', patientId)
    .order('recorded_at', { ascending: false });
  return data || [];
}

export async function applyAdjustment(patientId, invoiceId, amount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_advance_adjustment', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── RECEIPTS ──
export async function searchReceipts(query, modeFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('payments')
    .select('*, patients(id, first_name, last_name, uhid, mobile), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
    .order('collected_at', { ascending: false })
    .limit(50);

  if (query) {
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    q = q.or(`receipt_number.ilike.%${query}%${ids.length ? ',patient_id.in.(' + ids.join(',') + ')' : ''}`);
  }

  const { data: receipts } = await q;
  if (!receipts) return [];

  if (!modeFilter) return receipts;
  return receipts.filter((r) => (r.payment_modes || []).some((m) => m.mode === modeFilter));
}

export async function getReceiptById(paymentId) {
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();
  if (error) return { error: error.message };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return { payment, modes: modes || [], allocations: allocations || [] };
}

// Manual "Send WhatsApp" button in Receipt -- works for any payment.
// Routes to the correct template based on payment_type: regular invoice
// payments use "payment_receipt" (manual-send only, never automatic);
// advance payments use "advance_receipt" (also sent automatically, but
// this button lets it be resent on demand too). Both attach the receipt
// PDF.
export async function resendPaymentReceiptWhatsApp(paymentId) {
  if (!paymentId) return { error: 'Missing payment id.' };
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('id, receipt_number, total_amount, collected_at, patient_id, payment_type, patients(id, first_name, last_name, mobile)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: error?.message || 'Receipt not found.' };
  if (!payment.patients?.mobile) return { error: 'Patient has no mobile number on file.' };

  const pdfResult = await generateReceiptPdfBuffer(paymentId);
  if (pdfResult.error) return { error: pdfResult.error };

  const { data: { user } } = await supabase.auth.getUser();
  const name = `${payment.patients.first_name} ${payment.patients.last_name}`.trim();
  const filename = `${payment.receipt_number || 'Receipt'}.pdf`;
  const meta = { module: payment.payment_type === 'advance' ? 'advance_payment' : 'payment_receipt', triggeredBy: user?.id || null };

  let whatsapp;
  if (payment.payment_type === 'advance') {
    whatsapp = await sendAdvanceReceiptWhatsApp({
      name,
      amount: payment.total_amount,
      receiptNumber: payment.receipt_number,
      date: formatDateOnlyIST(payment.collected_at),
      mobile: payment.patients.mobile,
      pdfBuffer: pdfResult.buffer,
      filename,
      patientDbId: payment.patient_id,
      meta,
    });
  } else {
    const { data: allocations } = await supabase
      .from('payment_allocations')
      .select('invoices(invoice_number)')
      .eq('payment_id', paymentId);
    const invoiceNumber = (allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--';

    whatsapp = await sendPaymentReceiptWhatsApp({
      name,
      amount: payment.total_amount,
      invoiceNumber,
      receiptNumber: payment.receipt_number,
      date: formatDateOnlyIST(payment.collected_at),
      mobile: payment.patients.mobile,
      pdfBuffer: pdfResult.buffer,
      filename,
      patientDbId: payment.patient_id,
      meta,
    });
  }

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

// ── REFUND / MODIFICATION ──
export async function getRefundableAllocations(paymentId) {
  const supabase = await createClient();
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const { data: refunds } = await supabase
    .from('payment_refunds')
    .select('*')
    .eq('payment_id', paymentId);

  return (allocations || []).map((a) => {
    const alreadyRefunded = (refunds || [])
      .filter((r) => r.invoice_id === a.invoice_id)
      .reduce((s, r) => s + Number(r.amount), 0);
    return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
  });
}

export async function getRefundHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId)
    .order('refunded_at', { ascending: false });
  return data || [];
}

export async function refundPayment(paymentId, invoiceId, amount, reason, refundMode, approvedBy) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_payment', {
    p_payment_id: paymentId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_refund_mode: refundMode || null,
    p_approved_by: approvedBy || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── REPORTS ──
export async function getPaymentReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const from = fromDate || today;
  const to = toDate || today;
  // Include the entire "to" day, not just its midnight instant.
  const toEnd = `${to}T23:59:59`;
  const rangeLabel = from === to ? new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })
    : `${new Date(from).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- ${new Date(to).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}`;

  if (reportId === 'daily') {
    const [{ data }, { data: refundsData }] = await Promise.all([
      supabase
        .from('payments')
        .select('receipt_number, total_amount, collected_at, patients(first_name, last_name)')
        .in('payment_type', ['invoice_payment', 'advance'])
        .gte('collected_at', from)
        .lte('collected_at', toEnd)
        .order('collected_at', { ascending: false }),
      supabase
        .from('payment_refunds')
        .select('amount')
        .gte('refunded_at', from)
        .lte('refunded_at', toEnd),
    ]);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, new Date(p.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }), `Rs.${p.total_amount}`],
    }));
    const grossTotal = (data || []).reduce((s, p) => s + Number(p.total_amount), 0);
    const refundTotal = (refundsData || []).reduce((s, r) => s + Number(r.amount), 0);
    return {
      title: `Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date/Time', 'Amount'], rows,
      total: grossTotal - refundTotal,
      summary: [
        { label: 'Gross Collected', value: grossTotal },
        { label: 'Refunds This Period', value: -refundTotal },
        { label: 'Net Collection', value: grossTotal - refundTotal, emphasize: true },
      ],
    };
  }

  if (reportId === 'mode' || reportId === 'cash' || reportId === 'upi') {
    const modeFilter = reportId === 'cash' ? 'Cash' : reportId === 'upi' ? 'UPI' : null;
    let q = supabase
      .from('payment_modes')
      .select('mode, amount, payments!inner(receipt_number, collected_at, patients(first_name, last_name), payment_type)')
      .gte('payments.collected_at', from)
      .lte('payments.collected_at', toEnd);
    if (modeFilter) q = q.eq('mode', modeFilter);
    const { data } = await q;

    // Refunds are included, not hidden -- but count against their mode
    // as negative, so both the per-mode summary and the mode-specific
    // reports show what was actually retained, not gross collected.
    const signedAmount = (m) => (m.payments?.payment_type === 'refund' ? -Number(m.amount) : Number(m.amount));

    if (reportId === 'mode') {
      const byMode = {};
      (data || []).forEach((m) => { byMode[m.mode] = (byMode[m.mode] || 0) + signedAmount(m); });
      const rows = Object.entries(byMode).map(([mode, amount]) => ({ cols: [mode, `Rs.${amount.toFixed(2)}`] }));
      return { title: `Payment Mode Summary (net of refunds) -- ${rangeLabel}`, headers: ['Mode', 'Net Total'], rows, total: Object.values(byMode).reduce((s, v) => s + v, 0) };
    }

    const rows = (data || []).map((m) => {
      const isRefund = m.payments?.payment_type === 'refund';
      return {
        cols: [
          m.payments?.receipt_number, `${m.payments?.patients?.first_name} ${m.payments?.patients?.last_name}`,
          new Date(m.payments?.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }),
          isRefund ? 'Refund' : 'Collection',
          `${isRefund ? '-' : ''}Rs.${m.amount}`,
        ],
      };
    });
    return { title: `${modeFilter} Collection (net of refunds) -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date', 'Type', 'Amount'], rows, total: (data || []).reduce((s, m) => s + signedAmount(m), 0) };
  }

  if (reportId === 'advance') {
    const { data } = await supabase
      .from('patient_ledger')
      .select('*, patients(id, first_name, last_name, uhid)')
      .gte('recorded_at', from)
      .lte('recorded_at', toEnd)
      .order('recorded_at', { ascending: false });
    const rows = (data || []).map((l) => ({
      cols: [`${l.patients?.first_name} ${l.patients?.last_name}`, l.patients?.uhid, l.entry_type, `Rs.${Math.abs(l.amount).toFixed(2)}`],
    }));
    return { title: `Advance Report -- ${rangeLabel}`, headers: ['Patient', 'UHID', 'Entry', 'Amount'], rows, total: null };
  }

  if (reportId === 'out') {
    // Outstanding balances are inherently "as of now", not date-ranged --
    // the range here filters by when the invoice was created, so you can
    // still see "what's still outstanding from invoices raised in period X".
    const { data } = await supabase
      .from('invoices')
      .select('invoice_number, net, paid, created_at, patients(id, first_name, last_name, uhid)')
      .in('status', ['Pending', 'Partial'])
      .gte('created_at', from)
      .lte('created_at', toEnd)
      .order('created_at', { ascending: true });
    const rows = (data || []).map((i) => ({
      cols: [i.invoice_number, `${i.patients?.first_name} ${i.patients?.last_name}`, i.patients?.uhid, `Rs.${(i.net - i.paid).toFixed(2)}`],
    }));
    return { title: `Outstanding Balances -- invoices raised ${rangeLabel}`, headers: ['Invoice #', 'Patient', 'UHID', 'Outstanding'], rows, total: (data || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0) };
  }

  if (reportId === 'register') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, payment_type, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false })
      .limit(200);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, p.payment_type, new Date(p.collected_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }), `Rs.${p.total_amount}`],
    }));
    return { title: `Receipt Register -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Type', 'Date', 'Amount'], rows, total: null };
  }

  if (reportId === 'cancel') {
    const { data } = await supabase
      .from('payment_refunds')
      .select('*, patients(first_name, last_name), invoices(invoice_number)')
      .gte('refunded_at', from)
      .lte('refunded_at', toEnd)
      .order('refunded_at', { ascending: false });
    const rows = (data || []).map((r) => ({
      cols: [`${r.patients?.first_name} ${r.patients?.last_name}`, r.invoices?.invoice_number || 'Advance', `Rs.${r.amount}`, r.reason],
    }));
    return { title: `Refund Report -- ${rangeLabel}`, headers: ['Patient', 'Invoice', 'Amount', 'Reason'], rows, total: (data || []).reduce((s, r) => s + Number(r.amount), 0) };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
  const blocked = await requireDayOpen();
  if (blocked) return blocked;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_payment', {
    p_patient_id: patientId,
    p_invoice_ids: invoiceIds,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };

  // Log a journey event for whichever visit(s) this payment was
  // against -- one payment can span invoices from the same visit
  // (e.g. consultation + investigation billed separately), so dedupe
  // to one event per visit rather than one per invoice.
  try {
    const { data: paidVisits } = await supabase.from('invoices').select('visit_id').in('id', invoiceIds || []);
    const distinctVisitIds = [...new Set((paidVisits || []).map((i) => i.visit_id).filter(Boolean))];
    for (const vId of distinctVisitIds) {
      await logJourneyEvent(supabase, vId, 'payment_collected', { amount });
    }
  } catch (logErr) {
    console.error('payment_collected journey log failed:', logErr.message);
  }

  // Fire the WhatsApp bill for any invoice that just became fully paid --
  // but NOT inline. PDF generation (headless Chrome) + Meta's media
  // upload + template send together take several seconds, and awaiting
  // that here was adding 4-5s to every payment confirmation. after()
  // returns the response to the front desk immediately, then keeps this
  // function alive just long enough to finish the send in the background.
  try {
    const { data: { user } } = await supabase.auth.getUser();
    const { data: affectedInvoices } = await supabase
      .from('invoices')
      .select('id, status')
      .in('id', invoiceIds || []);
    const paidInvoiceIds = (affectedInvoices || []).filter((inv) => inv.status === 'Paid').map((inv) => inv.id);
    const triggeredBy = user?.id || null;

    if (paidInvoiceIds.length > 0) {
      after(async () => {
        for (const invoiceId of paidInvoiceIds) {
          try {
            await sendInvoiceBill(invoiceId, { force: false, triggeredBy });
          } catch (waErr) {
            console.error('WhatsApp bill auto-send failed:', waErr.message);
          }
        }
      });
    }
  } catch (waErr) {
    console.error('WhatsApp bill auto-send setup failed (payment already collected):', waErr.message);
  }

  return { payment: data };
}


