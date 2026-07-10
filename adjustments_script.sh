mkdir -p 'app/(main)/payments/adjustments'

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

cat > 'app/(main)/payments/adjustments/adjustments-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getCurrentBalancesByPatient, getAdvanceBalance, getOutstandingInvoices, getPatientLedgerAudit, applyAdjustment } from '../actions';

export default function AdjustmentsTab() {
  const [patientsWithBalance, setPatientsWithBalance] = useState([]);
  const [selected, setSelected] = useState(null);
  const [balance, setBalance] = useState(0);
  const [invoices, setInvoices] = useState([]);
  const [audit, setAudit] = useState([]);

  const [amount, setAmount] = useState('');
  const [invoiceId, setInvoiceId] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setPatientsWithBalance(await getCurrentBalancesByPatient());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function pickPatient(entry) {
    setError(''); setSuccess('');
    setSelected(entry.patient);
    setBalance(await getAdvanceBalance(entry.patient.id));
    setInvoices(await getOutstandingInvoices(entry.patient.id));
    setAudit(await getPatientLedgerAudit(entry.patient.id));
    setAmount('');
    setInvoiceId('');
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
    setBalance(await getAdvanceBalance(selected.id));
    setInvoices(await getOutstandingInvoices(selected.id));
    setAudit(await getPatientLedgerAudit(selected.id));
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

            <label className="flbl" style={{ marginBottom: 8 }}>Outstanding invoices</label>
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

cat > 'app/(main)/payments/adjustments/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';
import AdjustmentsTab from './adjustments-tab';

export default function AdjustmentsPage() {
  return (
    <div>
      <PaymentsTabs />
      <AdjustmentsTab />
    </div>
  );
}

EOF

echo "Adjustments tab built."
