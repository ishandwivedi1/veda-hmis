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

