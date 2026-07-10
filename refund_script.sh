mkdir -p 'app/(main)/payments/cancel'

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

cat > 'app/(main)/payments/cancel/refund-tab.js' << 'EOF'
'use client';

import { useState } from 'react';
import { searchReceipts, getRefundableAllocations, getRefundHistory, refundPayment } from '../actions';

export default function RefundTab() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [allocations, setAllocations] = useState([]);
  const [history, setHistory] = useState([]);

  const [refundFor, setRefundFor] = useState(null);
  const [refundAmount, setRefundAmount] = useState('');
  const [refundReason, setRefundReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!query.trim()) return;
    setResults(await searchReceipts(query.trim()));
  }

  async function openReceipt(r) {
    setError(''); setInfo('');
    setSelected(r);
    setAllocations(await getRefundableAllocations(r.id));
    setHistory(await getRefundHistory(r.id));
    setRefundFor(null);
  }

  async function refreshDetail() {
    setAllocations(await getRefundableAllocations(selected.id));
    setHistory(await getRefundHistory(selected.id));
  }

  async function confirmRefund() {
    setError('');
    const amt = parseFloat(refundAmount);
    if (!amt || amt <= 0) { setError('Enter a valid refund amount.'); return; }
    if (!refundReason.trim()) { setError('A refund reason is required.'); return; }

    setLoading(true);
    const result = await refundPayment(selected.id, refundFor.invoice_id, amt, refundReason);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setInfo('Refund processed and logged.');
    setRefundFor(null);
    setRefundAmount('');
    setRefundReason('');
    refreshDetail();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.4fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-receipt-refund" style={{ color: 'var(--red)' }}></i> Refund / Modification
        </div>
        <div className="msg-info">
          <i className="ti ti-alert-triangle"></i> Refunds require a reason and are never deleted -- the original receipt stays exactly as it was, a new refund entry is added alongside it.
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Receipt #, patient, UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
        </div>
        {results.map((r) => (
          <div key={r.id} onClick={() => openReceipt(r)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <strong>{r.patients?.first_name} {r.patients?.last_name}</strong>
              <span>Rs.{r.total_amount}</span>
            </div>
            <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{r.receipt_number}</div>
          </div>
        ))}
        {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Search to find a receipt.</div>}
      </div>

      {selected && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>{selected.receipt_number}</div>
          <div style={{ fontSize: 13, marginBottom: 12 }}>
            <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- Original amount: Rs.{selected.total_amount}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          <label className="flbl" style={{ marginBottom: 8 }}>Applied against (refundable)</label>
          <table className="tbl" style={{ marginBottom: 16 }}>
            <thead><tr><th>Invoice</th><th>Allocated</th><th>Refunded</th><th>Refundable</th><th></th></tr></thead>
            <tbody>
              {allocations.map((a) => (
                <tr key={a.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{a.invoices?.invoice_number}</td>
                  <td>Rs.{Number(a.amount).toFixed(2)}</td>
                  <td>{a.alreadyRefunded > 0 ? `Rs.${a.alreadyRefunded.toFixed(2)}` : '--'}</td>
                  <td style={{ fontWeight: 700, color: a.refundable > 0 ? 'var(--red)' : 'var(--g400)' }}>Rs.{a.refundable.toFixed(2)}</td>
                  <td>
                    {a.refundable > 0 && (
                      <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => { setRefundFor(a); setRefundAmount(''); setRefundReason(''); setError(''); }}>
                        Refund
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {allocations.length === 0 && <tr><td colSpan={5} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>Not applied to any invoice (advance).</td></tr>}
            </tbody>
          </table>

          {refundFor && (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 8 }}>
                Refund against {refundFor.invoices?.invoice_number} -- up to Rs.{refundFor.refundable.toFixed(2)}
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
                <input type="number" className="fi" value={refundAmount} onChange={(e) => setRefundAmount(e.target.value)} placeholder="Amount" />
                <input className="fi" value={refundReason} onChange={(e) => setRefundReason(e.target.value)} placeholder="Reason *" />
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                <button className="btn" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={confirmRefund} disabled={loading}>
                  {loading ? 'Processing...' : 'Confirm Refund'}
                </button>
                <button className="btn" onClick={() => setRefundFor(null)}>Cancel</button>
              </div>
            </div>
          )}

          <label className="flbl" style={{ marginBottom: 8 }}>Refund history for this receipt</label>
          {history.map((h) => (
            <div key={h.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
              {new Date(h.refunded_at).toLocaleDateString('en-IN')} -- {h.invoices?.invoice_number} -- Rs.{h.amount} -- {h.reason}
            </div>
          ))}
          {history.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No refunds on this receipt.</div>}
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/payments/cancel/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';
import RefundTab from './refund-tab';

export default function RefundPage() {
  return (
    <div>
      <PaymentsTabs />
      <RefundTab />
    </div>
  );
}

EOF

cat > 'app/(main)/payments/payments-tabs.js' << 'EOF'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/cancel', label: 'Refund / Modification', icon: 'ti-receipt-refund' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function PaymentsTabs() {
  const pathname = usePathname();
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Link
          key={t.href}
          href={t.href}
          className={pathname === t.href ? 'btn btn-primary' : 'btn'}
          style={{ textDecoration: 'none' }}
        >
          <i className={`ti ${t.icon}`}></i> {t.label}
        </Link>
      ))}
    </div>
  );
}

EOF

echo "Refund/Modification tab built."
