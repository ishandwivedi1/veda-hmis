mkdir -p 'app/(main)/payments/receipt' 'app/receipt-print/[paymentId]'

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

cat > 'app/(main)/payments/receipt/receipt-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { searchReceipts } from '../actions';

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const TYPE_BADGE = { invoice_payment: 'b-blue', advance: 'b-purple', advance_adjustment: 'b-amber' };
const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Adjustment' };

export default function ReceiptTab() {
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [receipts, setReceipts] = useState([]);

  const runSearch = useCallback(async () => {
    setReceipts(await searchReceipts(query, modeFilter));
  }, [query, modeFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Receipt Register
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 220 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Receipt #, patient, UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
            <option value="">All modes</option>
            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Receipt #</th><th>Date/Time</th><th>Patient</th><th>Invoice ref</th><th>Mode(s)</th><th>Amount</th><th>Type</th><th></th></tr>
          </thead>
          <tbody>
            {receipts.map((r) => (
              <tr key={r.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{r.receipt_number}</td>
                <td>{new Date(r.collected_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                <td style={{ fontWeight: 600 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                <td style={{ fontSize: 11 }}>{(r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--'}</td>
                <td style={{ fontSize: 11 }}>{(r.payment_modes || []).map((m) => `${m.mode} Rs.${m.amount}`).join(', ')}</td>
                <td style={{ fontWeight: 600 }}>Rs.{r.total_amount}</td>
                <td><span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || r.payment_type}</span></td>
                <td>
                  <a href={`/receipt-print/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                    <i className="ti ti-printer"></i>
                  </a>
                </td>
              </tr>
            ))}
            {receipts.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/receipt/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';
import ReceiptTab from './receipt-tab';

export default function ReceiptPage() {
  return (
    <div>
      <PaymentsTabs />
      <ReceiptTab />
    </div>
  );
}

EOF

cat > 'app/receipt-print/[paymentId]/page.js' << 'EOF'
import { createClient } from '../../../lib/supabase-server';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

export default async function ReceiptPrintPage({ params }) {
  const { paymentId } = await params;
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();

  if (error || !payment) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Receipt not found.</div>;
  }

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return (
    <div style={{ maxWidth: 600, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #15803d', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#166534' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 14, fontWeight: 700, marginTop: 8 }}>PAYMENT RECEIPT</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Received From</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{payment.patients?.first_name} {payment.patients?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{payment.patients?.uhid}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{payment.patients?.mobile}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Receipt #</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{payment.receipt_number}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{new Date(payment.collected_at).toLocaleString('en-IN', { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' })}</div>
          <div style={{ fontSize: 12, marginTop: 4 }}>{TYPE_LABEL[payment.payment_type] || payment.payment_type}</div>
        </div>
      </div>

      <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 8, padding: 16, textAlign: 'center', marginBottom: 20 }}>
        <div style={{ fontSize: 11, color: '#166534', textTransform: 'uppercase' }}>Amount Received</div>
        <div style={{ fontSize: 28, fontWeight: 800, color: '#15803d' }}>Rs.{Number(payment.total_amount).toFixed(2)}</div>
      </div>

      {allocations && allocations.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Applied Against</div>
          {allocations.map((a) => (
            <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0', borderBottom: '1px solid #e5e7eb' }}>
              <span>{a.invoices?.invoice_number}</span>
              <span>Rs.{Number(a.amount).toFixed(2)}</span>
            </div>
          ))}
        </div>
      )}

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Payment Mode(s)</div>
        {(modes || []).map((m) => (
          <div key={m.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0', borderBottom: '1px solid #e5e7eb' }}>
            <span>{m.mode}</span>
            <span>Rs.{Number(m.amount).toFixed(2)}</span>
          </div>
        ))}
      </div>

      {payment.reference && (
        <div style={{ fontSize: 12, color: '#4b5563', marginBottom: 6 }}>Reference: {payment.reference}</div>
      )}
      {payment.remarks && (
        <div style={{ fontSize: 12, color: '#4b5563', marginBottom: 6 }}>Remarks: {payment.remarks}</div>
      )}

      <div style={{ marginTop: 30, fontSize: 12, color: '#4b5563' }}>
        Collected by: {payment.profiles?.full_name || '--'}
      </div>

      <div style={{ marginTop: 40, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated receipt.
      </div>
    </div>
  );
}

EOF

echo "Receipt register and printable receipt built."
