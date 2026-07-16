mkdir -p "app/(main)/payments/refund"

cat > "app/(main)/payments/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

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
export async function editPaymentClerical(paymentId, modes, reference, remarks, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('edit_payment_clerical', {
    p_payment_id: paymentId,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_reason: reason,
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
    .select('*, patients(id, first_name, last_name, uhid), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
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
  const rangeLabel = from === to ? new Date(from).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
    : `${new Date(from).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })} -- ${new Date(to).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}`;

  if (reportId === 'daily') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false });
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, new Date(p.collected_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }), `Rs.${p.total_amount}`],
    }));
    return { title: `Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date/Time', 'Amount'], rows, total: (data || []).reduce((s, p) => s + Number(p.total_amount), 0) };
  }

  if (reportId === 'mode' || reportId === 'cash' || reportId === 'upi') {
    const modeFilter = reportId === 'cash' ? 'Cash' : reportId === 'upi' ? 'UPI' : null;
    let q = supabase
      .from('payment_modes')
      .select('mode, amount, payments!inner(receipt_number, collected_at, patients(first_name, last_name))')
      .gte('payments.collected_at', from)
      .lte('payments.collected_at', toEnd);
    if (modeFilter) q = q.eq('mode', modeFilter);
    const { data } = await q;

    if (reportId === 'mode') {
      const byMode = {};
      (data || []).forEach((m) => { byMode[m.mode] = (byMode[m.mode] || 0) + Number(m.amount); });
      const rows = Object.entries(byMode).map(([mode, amount]) => ({ cols: [mode, `Rs.${amount.toFixed(2)}`] }));
      return { title: `Payment Mode Summary -- ${rangeLabel}`, headers: ['Mode', 'Total'], rows, total: Object.values(byMode).reduce((s, v) => s + v, 0) };
    }

    const rows = (data || []).map((m) => ({
      cols: [m.payments?.receipt_number, `${m.payments?.patients?.first_name} ${m.payments?.patients?.last_name}`, new Date(m.payments?.collected_at).toLocaleDateString('en-IN'), `Rs.${m.amount}`],
    }));
    return { title: `${modeFilter} Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date', 'Amount'], rows, total: (data || []).reduce((s, m) => s + Number(m.amount), 0) };
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
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, p.payment_type, new Date(p.collected_at).toLocaleDateString('en-IN'), `Rs.${p.total_amount}`],
    }));
    return { title: `Receipt Register -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Type', 'Date', 'Amount'], rows, total: null };
  }

  if (reportId === 'cancel') {
    const { data } = await supabase
      .from('payment_refunds')
      .select('*, payments(receipt_number, patients(first_name, last_name)), invoices(invoice_number)')
      .gte('refunded_at', from)
      .lte('refunded_at', toEnd)
      .order('refunded_at', { ascending: false });
    const rows = (data || []).map((r) => ({
      cols: [r.payments?.receipt_number, `${r.payments?.patients?.first_name} ${r.payments?.patients?.last_name}`, r.invoices?.invoice_number, `Rs.${r.amount}`, r.reason],
    }));
    return { title: `Refund Report -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Invoice', 'Amount', 'Reason'], rows, total: (data || []).reduce((s, r) => s + Number(r.amount), 0) };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
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
  return { payment: data };
}


EOF

cat > "app/(main)/payments/refund/refund-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientPayments, getAdvanceBalance, getApprovers, refundPayment, refundAdvance, getRefundRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Excess payment', 'Cancelled service', 'Duplicate payment', 'Service not rendered', 'Patient request -- approved', 'Other approved reason'];
const MODES = ['Cash', 'UPI (to patient)', 'Bank Transfer', 'Cheque'];

export default function RefundTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [payments, setPayments] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [refundFor, setRefundFor] = useState(null);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [mode, setMode] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    getTodaysVisits().then(setTodaysVisits);
  }, []);

  async function refreshRegister() {
    setRegister(await getRefundRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(p.id), getAdvanceBalance(p.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
  }

  function changePatient() {
    setPatient(null);
    setPayments([]);
    setRefundFor(null);
  }

  function startRefund(payment, allocation) {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'invoice', payment, allocation });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  function startRefundAdvance() {
    setError(''); setSuccess('');
    setRefundFor({ kind: 'advance' });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  const totalPaid = payments.reduce((s, p) => s + Number(p.total_amount), 0);
  const totalRefundable = payments.reduce((s, p) => s + (p.payment_allocations || []).reduce((s2, a) => s2 + Math.max(0, a.refundable), 0), 0);

  async function confirmRefund() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid refund amount.'); return; }
    if (!reason) { setError('Select a refund reason.'); return; }
    if (!mode) { setError('Select a refund mode.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    let result;
    if (refundFor.kind === 'advance') {
      if (amt > advanceBalance) { setLoading(false); setError(`Refund amount cannot exceed the available advance balance (Rs.${advanceBalance}).`); return; }
      result = await refundAdvance(patient.id, amt, reason, mode, approvedBy);
    } else {
      if (amt > refundFor.allocation.refundable) { setLoading(false); setError(`Refund amount cannot exceed what remains refundable (Rs.${refundFor.allocation.refundable.toFixed(2)}).`); return; }
      result = await refundPayment(refundFor.payment.id, refundFor.allocation.invoice_id, amt, reason, mode, approvedBy);
    }
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(refundFor.kind === 'advance'
      ? `Refund of Rs.${amt.toFixed(2)} processed from advance balance.`
      : `Refund of Rs.${amt.toFixed(2)} processed against ${refundFor.allocation.invoices?.invoice_number}.`);
    setRefundFor(null);
    const [pmts, balance] = await Promise.all([getPatientPayments(patient.id), getAdvanceBalance(patient.id)]);
    setPayments(pmts);
    setAdvanceBalance(balance);
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-rotate-clockwise" style={{ color: 'var(--amber)' }}></i> Refund
          </div>
          <div className="msg-info" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-info-circle"></i> Reverses money already collected -- the original receipt is never edited or deleted, a new linked refund entry is added alongside it. Requires an approver.
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {!patient ? (
            <div>
              <label className="flbl">Patient</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
              <div style={{ marginTop: 16 }}>
                <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
              </div>
            </div>
          ) : (
            <div>
              <div style={{ background: 'var(--amber-lt)', border: '1px solid var(--amber)', borderRadius: 8, padding: '10px 14px', marginBottom: 14 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <div style={{ fontWeight: 700, fontSize: 14 }}>{patient.first_name} {patient.last_name}</div>
                  <button className="btn btn-sm" onClick={changePatient}>Change</button>
                </div>
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 2 }}>{patient.uhid}</div>
                <div style={{ display: 'flex', gap: 16, marginTop: 8, fontSize: 12 }}>
                  <span>Total paid: <strong style={{ color: 'var(--green)' }}>Rs.{totalPaid.toFixed(2)}</strong></span>
                  <span>Refundable: <strong style={{ color: 'var(--amber)' }}>Rs.{totalRefundable.toFixed(2)}</strong></span>
                  <span>Advance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong></span>
                </div>
              </div>

              {advanceBalance > 0 && (
                <div className="card" style={{ padding: '10px 12px', marginBottom: 8, background: 'var(--purple-lt)', border: '1px solid var(--purple)' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ fontSize: 12 }}>
                      <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance balance: <strong style={{ color: 'var(--purple)' }}>Rs.{advanceBalance}</strong>
                      <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>Not tied to any invoice -- refund it directly from the pooled balance.</div>
                    </div>
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={startRefundAdvance}>
                      Refund from Advance
                    </button>
                  </div>
                </div>
              )}

              <label className="flbl" style={{ marginBottom: 8 }}>Receipts -- select what to refund</label>
              {payments.map((p) => (
                <div key={p.id} className="card" style={{ padding: '10px 12px', marginBottom: 8 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 6 }}>
                    <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{p.receipt_number}</span>
                    <span style={{ color: 'var(--g500)' }}>{new Date(p.collected_at).toLocaleDateString('en-IN')} -- Rs.{p.total_amount}</span>
                  </div>
                  {(p.payment_allocations || []).length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)' }}>Not applied to any invoice (advance).</div>}
                  {(p.payment_allocations || []).map((a) => (
                    <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', fontSize: 12, borderTop: '1px solid var(--g100)' }}>
                      <span style={{ fontFamily: 'monospace' }}>{a.invoices?.invoice_number}</span>
                      <span>Rs.{Number(a.amount).toFixed(2)} allocated{a.alreadyRefunded > 0 ? ` -- Rs.${a.alreadyRefunded.toFixed(2)} refunded` : ''}</span>
                      {a.refundable > 0 ? (
                        <button className="btn btn-sm" onClick={() => startRefund(p, a)}>Refund up to Rs.{a.refundable.toFixed(2)}</button>
                      ) : <span style={{ color: 'var(--g400)', fontSize: 11 }}>Fully refunded</span>}
                    </div>
                  ))}
                </div>
              ))}
              {payments.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments found for this patient.</div>}

              {refundFor && (
                <div style={{ border: '1.5px solid var(--amber)', borderRadius: 8, padding: 14, marginTop: 12 }}>
                  <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}>
                    {refundFor.kind === 'advance'
                      ? `Refund from advance balance -- up to Rs.${advanceBalance}`
                      : `Refund against ${refundFor.allocation.invoices?.invoice_number} -- up to Rs.${refundFor.allocation.refundable.toFixed(2)}`}
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund reason *</label>
                      <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                        <option value="">-- Select --</option>
                        {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Refund amount (Rs.) *</label>
                      <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
                    </div>
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                    <div>
                      <label className="flbl">Refund mode *</label>
                      <select className="fi" value={mode} onChange={(e) => setMode(e.target.value)}>
                        <option value="">-- Select --</option>
                        {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                      </select>
                    </div>
                    <div>
                      <label className="flbl">Approved by *</label>
                      <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
                        <option value="">-- Select --</option>
                        {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}</option>)}
                      </select>
                    </div>
                  </div>
                  <label className="flbl">Remarks</label>
                  <input className="fi" style={{ marginBottom: 12 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
                  <div style={{ display: 'flex', gap: 8 }}>
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={confirmRefund} disabled={loading}>
                      {loading ? 'Processing...' : 'Process Refund'}
                    </button>
                    <button className="btn" onClick={() => setRefundFor(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--amber)' }}></i> Refund Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Invoice</th><th>Amount</th><th>Mode</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((r) => (
                <tr key={r.id}>
                  <td style={{ fontSize: 12 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.invoices?.invoice_number || 'Advance'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(r.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{r.refund_mode || '--'}</td>
                  <td style={{ fontSize: 11 }}>{r.reason}</td>
                  <td style={{ fontSize: 11 }}>{r.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No refunds processed yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Refund from Advance balance added; Ledger and Refund Register fixed to handle both refund types correctly."