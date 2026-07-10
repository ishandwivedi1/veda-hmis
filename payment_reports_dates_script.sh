mkdir -p 'app/(main)/payments/reports'

cat > 'app/(main)/payments/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

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
    .select('patient_id, amount, patients(first_name, last_name, uhid)');
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
    .select('*, patients(first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
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
    .select('*, patients(first_name, last_name, uhid), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
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

export async function refundPayment(paymentId, invoiceId, amount, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_payment', {
    p_payment_id: paymentId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
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
      .select('*, patients(first_name, last_name, uhid)')
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
      .select('invoice_number, net, paid, created_at, patients(first_name, last_name, uhid)')
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

cat > 'app/(main)/payments/reports/payment-reports-tab.js' << 'EOF'
'use client';

import { useState } from 'react';
import { getPaymentReport } from '../actions';

const RPT_DEFS = [
  { id: 'daily', icon: 'ti-calendar', color: '--green', title: 'Collection', desc: 'All payments in period' },
  { id: 'mode', icon: 'ti-credit-card', color: '--blue', title: 'Payment Mode Summary', desc: 'Cash vs UPI vs Card' },
  { id: 'cash', icon: 'ti-cash', color: '--amber', title: 'Cash Collection', desc: 'Cash receipts' },
  { id: 'upi', icon: 'ti-device-mobile', color: '--teal', title: 'UPI Collection', desc: 'UPI transactions' },
  { id: 'advance', icon: 'ti-wallet', color: '--purple', title: 'Advance Report', desc: 'Advances and adjustments' },
  { id: 'out', icon: 'ti-clock', color: '--red', title: 'Outstanding Balances', desc: 'Pending invoice dues' },
  { id: 'register', icon: 'ti-receipt', color: '--green', title: 'Receipt Register', desc: 'All receipts' },
  { id: 'cancel', icon: 'ti-x-circle', color: '--red', title: 'Refund Report', desc: 'Refunds processed' },
];

function toISODate(d) {
  return d.toISOString().slice(0, 10);
}

// India's fiscal year runs April to March.
function fiscalYearRange(offsetYears = 0) {
  const now = new Date();
  let fyStartYear = now.getMonth() >= 3 ? now.getFullYear() : now.getFullYear() - 1; // April = month index 3
  fyStartYear += offsetYears;
  const from = new Date(fyStartYear, 3, 1);
  const to = new Date(fyStartYear + 1, 2, 31);
  return [toISODate(from), toISODate(to)];
}

function fiscalQuarterRange() {
  const now = new Date();
  const month = now.getMonth(); // 0-11
  // FY quarters: Q1 Apr-Jun, Q2 Jul-Sep, Q3 Oct-Dec, Q4 Jan-Mar
  let qStartMonth, year = now.getFullYear();
  if (month >= 3 && month <= 5) qStartMonth = 3;
  else if (month >= 6 && month <= 8) qStartMonth = 6;
  else if (month >= 9 && month <= 11) qStartMonth = 9;
  else { qStartMonth = 0; }
  const from = new Date(year, qStartMonth, 1);
  const to = new Date(year, qStartMonth + 3, 0);
  return [toISODate(from), toISODate(to)];
}

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Quarter', range: fiscalQuarterRange },
  { label: 'This FY', range: () => fiscalYearRange(0) },
  { label: 'Last FY', range: () => fiscalYearRange(-1) },
];

export default function PaymentReportsTab() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from);
    setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getPaymentReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && (
            <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => (
              <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>
            ))}
          </div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-file"></i> {report.title}</div>
            <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>
              )}
            </tbody>
          </table>
          {report.total !== null && (
            <div style={{ textAlign: 'right', fontWeight: 700, marginTop: 10, fontSize: 14 }}>
              Total: Rs.{report.total.toFixed(2)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

EOF

echo "Date range and period presets (incl. FY quarters) added to Payments Reports."
