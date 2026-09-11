'use client';

import { useState, useEffect } from 'react';
import {
  searchOpticalCustomers,
  getOpticalAdvanceBalance,
  getOpticalPaymentsForCustomer,
  getApprovers,
  refundOpticalAdvance,
  refundOpticalPayment,
  getOpticalRefundRegister,
} from '../actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDateTime(iso) {
  return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}

export default function OpticalRefundTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [balance, setBalance] = useState(0);
  const [payments, setPayments] = useState([]);

  const [refundFor, setRefundFor] = useState(null); // { kind: 'advance' } | { kind: 'payment', payment }
  const [amount, setAmount] = useState('');
  const [refundMode, setRefundMode] = useState('Cash');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [approvers, setApprovers] = useState([]);

  const [register, setRegister] = useState([]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
  }, []);

  async function refreshRegister() {
    try {
      setRegister(await getOpticalRefundRegister());
    } catch (e) {
      // Non-critical background refresh -- leave the existing list showing.
    }
  }

  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => setSearchResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pick(r) {
    setSelected(r);
    setSearchResults([]);
    setSearchQuery('');
    setRefundFor(null);
    setError('');
    try {
      const idArgs = { patientId: r.type === 'patient' ? r.id : null, opticalCustomerId: r.type === 'optical_customer' ? r.id : null };
      const [bal, pays] = await Promise.all([getOpticalAdvanceBalance(idArgs), getOpticalPaymentsForCustomer(idArgs)]);
      setBalance(bal);
      setPayments(pays.filter((p) => p.refundable > 0));
    } catch (e) {
      setError('Could not load this customer\'s refundable balances -- check your connection and try again.');
    }
  }

  function clearCustomer() {
    setSelected(null);
    setBalance(0);
    setPayments([]);
    setRefundFor(null);
  }

  function chooseAdvance() {
    setRefundFor({ kind: 'advance' });
    setAmount(balance > 0 ? String(balance) : '');
    setReason('');
    setApprovedBy('');
  }
  function choosePayment(p) {
    setRefundFor({ kind: 'payment', payment: p });
    setAmount(String(p.refundable));
    setReason('');
    setApprovedBy('');
  }

  async function handleSubmit() {
    setError('');
    setSuccessMsg('');
    setSaving(true);
    try {
      let result;
      if (refundFor.kind === 'advance') {
        result = await refundOpticalAdvance({
          patientId: selected.type === 'patient' ? selected.id : null,
          opticalCustomerId: selected.type === 'optical_customer' ? selected.id : null,
          amount, reason, refundMode, approvedBy,
        });
      } else {
        result = await refundOpticalPayment({ paymentId: refundFor.payment.id, amount, reason, refundMode, approvedBy });
      }
      if (result.error) { setError(result.error); return; }
      setSuccessMsg(`Refund ${result.refund.refund_number} recorded.`);
      setRefundFor(null);
      pick(selected);
      refreshRegister();
    } catch (e) {
      setError('Something went wrong processing the refund -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt-refund" style={{ color: 'var(--red)' }}></i> Refund</div>
        {error && <div className="msg-err">{error}</div>}
        {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

        <label className="flbl">Customer</label>
        {!selected && (
          <div>
            <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient or optical customer..." />
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((r) => (
                  <div key={`${r.type}-${r.id}`} onClick={() => pick(r)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{r.name}</strong> -- {r.type === 'patient' ? r.uhid : 'Optical Customer'} -- {r.mobile || 'no mobile'}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
        {selected && (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 12px', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 14 }}>
            <span><strong>{selected.name}</strong> -- {selected.type === 'patient' ? selected.uhid : 'Optical Customer'} -- {selected.mobile || 'no mobile'}</span>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i> Change</button>
          </div>
        )}

        {selected && !refundFor && (
          <>
            {balance > 0 && (
              <div onClick={chooseAdvance} style={{ padding: '10px 14px', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 8, cursor: 'pointer', display: 'flex', justifyContent: 'space-between' }}>
                <span><i className="ti ti-piggy-bank"></i> Refund from Advance</span>
                <strong>{fmt(balance)} available</strong>
              </div>
            )}
            <div style={{ fontSize: 12, fontWeight: 700, margin: '10px 0 6px', color: 'var(--g500)' }}>Or refund against a specific past payment</div>
            {payments.length === 0 ? (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No refundable payments found for this customer.</div>
            ) : (
              payments.map((p) => (
                <div key={p.id} onClick={() => choosePayment(p)} style={{ padding: '10px 14px', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 8, cursor: 'pointer', display: 'flex', justifyContent: 'space-between', fontSize: 12.5 }}>
                  <span>{p.optical_sales?.sale_number} -- paid {fmt(p.total_amount)} on {fmtDateTime(p.collected_at)}</span>
                  <strong>{fmt(p.refundable)} refundable</strong>
                </div>
              ))
            )}
          </>
        )}

        {refundFor && (
          <>
            <div style={{ padding: '8px 12px', background: 'var(--g50, #f7f8fa)', borderRadius: 8, marginBottom: 12, fontSize: 12.5, display: 'flex', justifyContent: 'space-between' }}>
              <span>{refundFor.kind === 'advance' ? 'Refunding from advance balance' : `Refunding against ${refundFor.payment.optical_sales?.sale_number}`}</span>
              <span onClick={() => setRefundFor(null)} style={{ cursor: 'pointer', color: 'var(--blue)' }}>Change</span>
            </div>

            <label className="flbl">Amount</label>
            <input className="fi" type="number" min="0" max={refundFor.kind === 'advance' ? balance : refundFor.payment.refundable} value={amount} onChange={(e) => setAmount(e.target.value)} />

            <label className="flbl" style={{ marginTop: 10 }}>Refund Mode</label>
            <select className="fi" value={refundMode} onChange={(e) => setRefundMode(e.target.value)}>
              {PAYMENT_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>

            <label className="flbl" style={{ marginTop: 10 }}>Reason</label>
            <input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why is this being refunded?" />

            <label className="flbl" style={{ marginTop: 10 }}>Approved By</label>
            <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
              <option value="">Select approver...</option>
              {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` (${a.designation})` : ''}</option>)}
            </select>

            <button className="btn btn-primary" style={{ marginTop: 14, background: 'var(--red)', borderColor: 'var(--red)' }} disabled={saving} onClick={handleSubmit}>
              <i className="ti ti-receipt-refund"></i> {saving ? 'Processing...' : 'Process Refund'}
            </button>
          </>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> Recent Refunds</div>
        {register.length === 0 ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>No refunds processed yet.</div>
        ) : (
          register.map((r) => (
            <div key={r.id} style={{ padding: '8px 4px', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <strong>{r.refund_number}</strong><span>{fmt(r.amount)}</span>
              </div>
              <div style={{ color: 'var(--g500)' }}>{r.customerName} -- {r.optical_sales?.sale_number || 'Advance'} -- {fmtDateTime(r.refunded_at)}</div>
              <div style={{ color: 'var(--g400)', fontSize: 11 }}>{r.reason}</div>
            </div>
          ))
        )}
      </div>
    </div>
  );
}
