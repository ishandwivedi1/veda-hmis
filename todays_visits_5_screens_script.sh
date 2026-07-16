mkdir -p "app/(main)/payments/advance" "app/(main)/payments/adjustments" "app/(main)/payments/ledger" "app/(main)/payments/credit-note" "app/(main)/payments/refund"

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
    supabase.from('payment_refunds').select('*, payments!inner(patient_id, receipt_number), invoices(invoice_number, visits(visit_number))').eq('payments.patient_id', patientId),
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

  (payments || []).forEach((p) => {
    if (p.payment_type === 'credit_note') return; // shown from credit_notes instead, richer detail there
    const type = PAYMENT_TYPE_LABEL[p.payment_type] || 'Payment';
    const modeDesc = (p.payment_modes || []).map((m) => m.mode).join('+') || 'Advance';
    entries.push({
      date: p.collected_at, type, ref: p.receipt_number, visit: '--',
      desc: `${type} via ${modeDesc}${p.remarks ? ' -- ' + p.remarks : ''}`, debit: 0, credit: Number(p.total_amount), by: 'Staff',
    });
  });

  (refunds || []).forEach((r) => {
    entries.push({
      date: r.refunded_at, type: 'Refund', ref: r.payments?.receipt_number || '--', visit: r.invoices?.visits?.visit_number || '--',
      desc: `Refund against ${r.invoices?.invoice_number || '--'} -- ${r.reason}`, debit: Number(r.amount), credit: 0, by: 'Staff',
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

export async function getRefundRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, payments(receipt_number, patients(first_name, last_name, uhid)), invoices(invoice_number), profiles!payment_refunds_approved_by_fkey(full_name)')
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

cat > "app/(main)/payments/todays-visits-widget.js" << 'EOF'
'use client';

export default function TodaysVisitsWidget({ visits, onSelect, title = "Today's Visits" }) {
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> {title}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to select that patient.</div>
      {visits.map((v) => (
        <div
          key={v.id}
          onClick={() => onSelect(v.patients)}
          style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
        >
          <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
          <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
        </div>
      ))}
      {visits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
    </div>
  );
}

EOF

cat > "app/(main)/payments/advance/advance-tab.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { searchPatientsForPayment, getAdvanceBalance, collectAdvance, getCurrentBalancesByPatient, getLedgerHistory, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const ADVANCE_TYPES = ['Surgery Advance', 'General Advance', 'Package Advance', 'Other'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function AdvanceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [currentBalance, setCurrentBalance] = useState(0);

  const [advanceType, setAdvanceType] = useState('Surgery Advance');
  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);

  // Same simplification as Collect Payment: in the common single-mode
  // case, the mode amount always matches the amount field -- no need to
  // type the same number twice.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(null);

  const [balances, setBalances] = useState([]);
  const [history, setHistory] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const refreshSidebar = useCallback(async () => {
    setBalances(await getCurrentBalancesByPatient());
    setHistory(await getLedgerHistory());
  }, []);

  useEffect(() => { refreshSidebar(); }, [refreshSidebar]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setCurrentBalance(await getAdvanceBalance(p.id));
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setSuccess(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectAdvance(selectedPatient.id, advanceType, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(result.payment);
    refreshSidebar();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance Collection
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Advance collected without invoice. Balance held in Patient Ledger and adjusted against future invoices.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {success ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Advance collected -- Receipt <strong>{success.receipt_number}</strong> -- Rs.{success.total_amount}
            <div style={{ marginTop: 10 }}>
              <button className="btn btn-sm" onClick={reset}>Collect another advance</button>
            </div>
          </div>
        ) : !selectedPatient ? (
          <div>
            <label className="flbl">Patient *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
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
          </div>
        ) : (
          <div>
            <div style={{ background: 'var(--purple-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 12, marginTop: 6 }}>Current advance: <strong style={{ color: 'var(--purple)' }}>Rs.{currentBalance}</strong></div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Advance type</label>
                <select className="fi" value={advanceType} onChange={(e) => setAdvanceType(e.target.value)}>
                  {ADVANCE_TYPES.map((t) => <option key={t}>{t}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
            </div>

            <label className="flbl">Payment mode(s) *</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="e.g. Surgery scheduled 30 Jun..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect advance'}
            </button>
          </div>
        )}
      </div>

      <div>
        <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />

        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Current Balance by Patient
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Balance</th></tr></thead>
            <tbody>
              {balances.map((b, i) => (
                <tr key={i}><td>{b.patient?.first_name} {b.patient?.last_name}</td><td style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{b.balance.toFixed(2)}</td></tr>
              ))}
              {balances.length === 0 && <tr><td colSpan={2} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No advances held.</td></tr>}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Transaction History
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Immutable record -- entries are never edited, only added to.
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Type</th><th>Amount</th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td>{h.patients?.first_name} {h.patients?.last_name}</td>
                  <td><span className={`badge ${h.entry_type === 'Advance Collected' ? 'b-green' : 'b-amber'}`}>{h.entry_type}</span></td>
                  <td style={{ fontWeight: 600 }}>Rs.{Math.abs(h.amount).toFixed(2)}</td>
                </tr>
              ))}
              {history.length === 0 && <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}


EOF

cat > "app/(main)/payments/adjustments/adjustments-tab.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getCurrentBalancesByPatient, getAdvanceBalance, getOutstandingInvoices, getPatientLedgerAudit, applyAdjustment, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

export default function AdjustmentsTab() {
  const [patientsWithBalance, setPatientsWithBalance] = useState([]);
  const [selected, setSelected] = useState(null);
  const [balance, setBalance] = useState(0);
  const [invoices, setInvoices] = useState([]);
  const [audit, setAudit] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const [amount, setAmount] = useState('');
  const [invoiceId, setInvoiceId] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setPatientsWithBalance(await getCurrentBalancesByPatient());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function loadPatientData(patient) {
    setBalance(await getAdvanceBalance(patient.id));
    setInvoices(await getOutstandingInvoices(patient.id));
    setAudit(await getPatientLedgerAudit(patient.id));
  }

  async function selectPatient(patient) {
    setError(''); setSuccess('');
    setSelected(patient);
    await loadPatientData(patient);
    setAmount('');
    setInvoiceId('');
  }

  async function pickPatient(entry) {
    await selectPatient(entry.patient);
  }

  async function handleRefresh() {
    if (!selected) return;
    setError(''); setSuccess('');
    await loadPatientData(selected);
    refresh();
  }

  async function handleApply() {
    setError(''); setSuccess('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid adjustment amount.'); return; }
    if (!invoiceId) { setError('Select an invoice to adjust against.'); return; }

    setLoading(true);
    const result = await applyAdjustment(selected.id, invoiceId, amt);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Rs.${amt} adjusted against invoice successfully.`);
    setAmount('');
    setInvoiceId('');
    await loadPatientData(selected);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-arrows-exchange" style={{ color: 'var(--blue)' }}></i> Advance Adjustment
      </div>
      <div className="msg-info">
        <i className="ti ti-info-circle"></i> Adjusting an advance never edits or deletes the original collection entry -- it creates a new, linked adjustment entry instead, so the full history stays intact and auditable.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 20 }}>
        <div>
          <TodaysVisitsWidget visits={todaysVisits} onSelect={selectPatient} />

          <label className="flbl" style={{ marginBottom: 8 }}>Patients with advance balance</label>
          {patientsWithBalance.map((entry, i) => (
            <div
              key={i}
              onClick={() => pickPatient(entry)}
              style={{
                padding: '10px 12px', cursor: 'pointer', borderRadius: 8, marginBottom: 6, fontSize: 13,
                background: selected?.id === entry.patient.id ? 'var(--purple-lt)' : 'var(--g50)',
                border: selected?.id === entry.patient.id ? '1.5px solid var(--purple)' : '1px solid var(--g200)',
              }}
            >
              <div style={{ fontWeight: 600 }}>{entry.patient.first_name} {entry.patient.last_name}</div>
              <div style={{ color: 'var(--purple)', fontWeight: 700 }}>Rs.{entry.balance.toFixed(2)}</div>
            </div>
          ))}
          {patientsWithBalance.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No patients currently hold an advance balance.</div>}
        </div>

        {selected && (
          <div>
            <div style={{ background: 'var(--purple-lt)', border: '1px solid var(--purple)', borderRadius: 8, padding: 12, marginBottom: 12 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>{selected.first_name} {selected.last_name}</div>
              <div style={{ fontSize: 13, marginTop: 4 }}>Advance available: <strong style={{ color: 'var(--purple)', fontSize: 16 }}>Rs.{balance}</strong></div>
            </div>

            {error && <div className="msg-err">{error}</div>}
            {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <label className="flbl" style={{ marginBottom: 0 }}>Outstanding invoices</label>
              <button className="btn btn-sm" onClick={handleRefresh}><i className="ti ti-refresh"></i> Refresh</button>
            </div>
            <table className="tbl" style={{ marginBottom: 12 }}>
              <thead><tr><th>Invoice</th><th>Outstanding</th></tr></thead>
              <tbody>
                {invoices.map((inv) => (
                  <tr key={inv.id}><td style={{ fontFamily: 'monospace' }}>{inv.invoice_number}</td><td>Rs.{(inv.net - inv.paid).toFixed(2)}</td></tr>
                ))}
                {invoices.length === 0 && <tr><td colSpan={2} style={{ padding: 10, textAlign: 'center', color: 'var(--g400)' }}>No outstanding invoices.</td></tr>}
              </tbody>
            </table>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Adjust amount (Rs.)</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Against invoice</label>
                <select className="fi" value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
                  <option value="">-- Select --</option>
                  {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)}</option>)}
                </select>
              </div>
            </div>

            <button className="btn btn-primary" onClick={handleApply} disabled={loading || invoices.length === 0}>
              <i className="ti ti-arrows-exchange"></i> {loading ? 'Applying...' : 'Apply adjustment'}
            </button>

            <div style={{ marginTop: 16 }}>
              <label className="flbl" style={{ marginBottom: 8 }}>Audit trail -- this patient</label>
              {audit.map((a) => (
                <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                  {new Date(a.recorded_at).toLocaleDateString('en-IN')} -- {a.entry_type} -- Rs.{Math.abs(a.amount).toFixed(2)}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}


EOF

cat > "app/(main)/payments/ledger/ledger-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientUnifiedLedger, getAdvanceBalance, getOutstandingInvoices, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const TYPE_COLOR = {
  Invoice: 'var(--red)', Payment: 'var(--green)', Advance: 'var(--purple)',
  'Advance Adjustment': 'var(--blue)', Refund: 'var(--amber)', 'Credit Note': 'var(--teal)',
};

function fmt(n) {
  return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function LedgerTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [entries, setEntries] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [outstandingInvoices, setOutstandingInvoices] = useState([]);
  const [typeFilter, setTypeFilter] = useState('');
  const [visitFilter, setVisitFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setLoading(true);
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate('');
    const [ledgerEntries, balance, outstanding] = await Promise.all([
      getPatientUnifiedLedger(p.id), getAdvanceBalance(p.id), getOutstandingInvoices(p.id),
    ]);
    setEntries(ledgerEntries);
    setAdvanceBalance(balance);
    setOutstandingInvoices(outstanding);
    setLoading(false);
  }

  function changePatient() {
    setPatient(null);
    setEntries([]);
  }

  const visits = [...new Set(entries.map((e) => e.visit).filter((v) => v && v !== '--'))];
  const filtered = entries.filter((e) => {
    if (typeFilter && e.type !== typeFilter) return false;
    if (visitFilter && e.visit !== visitFilter) return false;
    if (fromDate && new Date(e.date) < new Date(fromDate)) return false;
    if (toDate && new Date(e.date) > new Date(`${toDate}T23:59:59`)) return false;
    return true;
  });

  const totalInvoiced = entries.filter((e) => e.type === 'Invoice').reduce((s, e) => s + e.debit, 0);
  const totalCollected = entries.filter((e) => e.type !== 'Invoice').reduce((s, e) => s + e.credit - e.debit, 0);
  const currentBalance = entries.length > 0 ? entries[0].balance : 0;

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Patient Ledger
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Spans all visits for this patient. Outstanding balance is calculated dynamically from every entry below -- Balance {'>'} 0 means the patient owes the hospital; Balance {'<'} 0 means the hospital owes the patient (unused advance).
        </div>

        {!patient ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            <div>
              <label className="flbl">Search patient (name, UHID, or mobile)</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
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
            </div>
            <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
          </div>
        ) : (
          <div>
            <div style={{ background: 'linear-gradient(135deg,#4c1d95,#7c3aed)', borderRadius: 12, padding: '14px 18px', color: '#fff', marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 16, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
                  <div style={{ fontSize: 12, opacity: .8, marginTop: 2 }}>{patient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={changePatient} style={{ background: 'rgba(255,255,255,.15)', color: '#fff', border: '1px solid rgba(255,255,255,.3)' }}>
                  <i className="ti ti-arrow-left"></i> Change patient
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginTop: 14 }}>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Invoiced</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3 }}>Rs.{fmt(totalInvoiced)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Collected</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#86efac' }}>Rs.{fmt(totalCollected)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Advance Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#c4b5fd' }}>Rs.{fmt(advanceBalance)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Current Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: currentBalance > 0 ? '#fca5a5' : '#86efac' }}>Rs.{fmt(currentBalance)}</div>
                </div>
              </div>
            </div>

            {loading ? (
              <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading ledger...</div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
                  <select className="fi" style={{ width: 'auto' }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                    <option value="">All types</option>
                    {Object.keys(TYPE_COLOR).map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                  <select className="fi" style={{ width: 'auto' }} value={visitFilter} onChange={(e) => setVisitFilter(e.target.value)}>
                    <option value="">All visits</option>
                    {visits.map((v) => <option key={v} value={v}>{v}</option>)}
                  </select>
                  <input type="date" className="fi" style={{ width: 'auto' }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
                  <input type="date" className="fi" style={{ width: 'auto' }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
                  {(typeFilter || visitFilter || fromDate || toDate) && (
                    <button className="btn btn-sm" onClick={() => { setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate(''); }}>
                      <i className="ti ti-x"></i> Clear
                    </button>
                  )}
                </div>

                <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
                  <table className="tbl">
                    <thead>
                      <tr><th>Date/Time</th><th>Type</th><th>Reference</th><th>Visit</th><th>Description</th><th style={{ textAlign: 'right' }}>Debit</th><th style={{ textAlign: 'right' }}>Credit</th><th style={{ textAlign: 'right' }}>Balance</th></tr>
                    </thead>
                    <tbody>
                      {filtered.map((e, i) => (
                        <tr key={i} style={{ borderLeft: `3px solid ${TYPE_COLOR[e.type]}` }}>
                          <td style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{new Date(e.date).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                          <td>
                            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600 }}>
                              <span style={{ width: 7, height: 7, borderRadius: '50%', background: TYPE_COLOR[e.type], flexShrink: 0 }}></span>
                              {e.type}
                            </span>
                          </td>
                          <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.ref}</td>
                          <td style={{ fontSize: 11 }}>{e.visit}</td>
                          <td style={{ fontSize: 12 }}>{e.desc}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.debit > 0 ? <span style={{ color: 'var(--red)', fontWeight: 600 }}>{fmt(e.debit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.credit > 0 ? <span style={{ color: 'var(--green)', fontWeight: 600 }}>{fmt(e.credit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 700, color: e.balance > 0 ? 'var(--red)' : e.balance < 0 ? 'var(--purple)' : 'var(--green)' }}>{fmt(e.balance)}</td>
                        </tr>
                      ))}
                      {filtered.length === 0 && (
                        <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No entries match these filters.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <div className="card" style={{ padding: '10px 14px' }}>
                  <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: 'var(--g600)' }}>
                    {Object.entries(TYPE_COLOR).map(([type, color]) => (
                      <span key={type}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: color, marginRight: 4 }}></span>{type}</span>
                    ))}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/payments/credit-note/credit-note-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, getApprovers, createCreditNote, getCreditNoteRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Billing correction', 'Service cancellation', 'Approved financial adjustment', 'Goodwill gesture', 'Insurance adjustment', 'Other'];

export default function CreditNoteTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [invoiceId, setInvoiceId] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
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
    setRegister(await getCreditNoteRegister());
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
    setInvoices(await getOutstandingInvoices(p.id));
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
  }

  function changePatient() {
    setPatient(null);
    setInvoices([]);
  }

  const selectedInvoice = invoices.find((i) => i.id === invoiceId);
  const outstandingOnSelected = selectedInvoice ? Number(selectedInvoice.net) - Number(selectedInvoice.paid) : 0;

  async function handleSubmit() {
    setError(''); setSuccess('');
    if (!invoiceId) { setError('Select an invoice to credit.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid credit amount.'); return; }
    if (amt > outstandingOnSelected) { setError(`Credit amount cannot exceed this invoice's outstanding balance (Rs.${outstandingOnSelected.toFixed(2)}).`); return; }
    if (!reason) { setError('Select a reason.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    const result = await createCreditNote(patient.id, invoiceId, amt, reason, approvedBy, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Credit note ${result.creditNote.credit_note_number} created for Rs.${amt.toFixed(2)}.`);
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
    setInvoices(await getOutstandingInvoices(patient.id));
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-file-minus" style={{ color: 'var(--teal)' }}></i> Credit Note
        </div>
        <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Reduces what a patient owes on an invoice without reversing any payment -- for billing corrections, service cancellations, goodwill, or insurance adjustments. Different from a refund, which returns money already collected.
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
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--teal-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 14 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={changePatient}>Change</button>
            </div>

            <label className="flbl">Invoice to credit *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
              <option value="">-- Select invoice --</option>
              {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)} outstanding</option>)}
            </select>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 12 }}>No outstanding invoices for this patient.</div>}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Reason *</label>
                <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                  <option value="">-- Select reason --</option>
                  {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Credit amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={selectedInvoice ? `Up to Rs.${outstandingOnSelected.toFixed(2)}` : '0.00'} />
              </div>
            </div>

            <label className="flbl">Approved by *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
              <option value="">-- Select approver --</option>
              {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` -- ${a.designation}` : ''}</option>)}
            </select>

            <label className="flbl">Remarks</label>
            <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Supporting details for this credit note..." />

            <button className="btn" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleSubmit} disabled={loading || invoices.length === 0}>
              <i className="ti ti-file-minus"></i> {loading ? 'Creating...' : 'Create Credit Note'}
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Credit Note Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>CN #</th><th>Patient</th><th>Invoice</th><th>Amount</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((cn) => (
                <tr key={cn.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.credit_note_number}</td>
                  <td style={{ fontSize: 12 }}>{cn.patients?.first_name} {cn.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.invoices?.invoice_number || '--'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(cn.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{cn.reason}</td>
                  <td style={{ fontSize: 11 }}>{cn.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No credit notes issued yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/payments/refund/refund-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getPatientPayments, getAdvanceBalance, getApprovers, refundPayment, getRefundRegister, getTodaysVisits } from '../actions';
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
    setRefundFor({ payment, allocation });
    setAmount(''); setReason(''); setMode(''); setApprovedBy(''); setRemarks('');
  }

  const totalPaid = payments.reduce((s, p) => s + Number(p.total_amount), 0);
  const totalRefundable = payments.reduce((s, p) => s + (p.payment_allocations || []).reduce((s2, a) => s2 + Math.max(0, a.refundable), 0), 0);

  async function confirmRefund() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid refund amount.'); return; }
    if (amt > refundFor.allocation.refundable) { setError(`Refund amount cannot exceed what remains refundable (Rs.${refundFor.allocation.refundable.toFixed(2)}).`); return; }
    if (!reason) { setError('Select a refund reason.'); return; }
    if (!mode) { setError('Select a refund mode.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    const result = await refundPayment(refundFor.payment.id, refundFor.allocation.invoice_id, amt, reason, mode, approvedBy);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Refund of Rs.${amt.toFixed(2)} processed against ${refundFor.allocation.invoices?.invoice_number}.`);
    setRefundFor(null);
    const pmts = await getPatientPayments(patient.id);
    setPayments(pmts);
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
                    Refund against {refundFor.allocation.invoices?.invoice_number} -- up to Rs.{refundFor.allocation.refundable.toFixed(2)}
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
                  <td style={{ fontSize: 12 }}>{r.payments?.patients?.first_name} {r.payments?.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.invoices?.invoice_number || '--'}</td>
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

echo "Today's Visits widget added to Advance, Adjustments, Ledger, Credit Note, and Refund. All confirmed write-free until their explicit action button."