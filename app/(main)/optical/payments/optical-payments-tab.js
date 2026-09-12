'use client';

import { useState, useEffect, Fragment } from 'react';
import {
  getOpticalPaymentsRegister,
  editOpticalPaymentClerical,
  correctOpticalPaymentAmount,
  getOpticalPaymentEditHistory,
} from '../actions';
import { getMyDesignation } from '@/app/(main)/users/actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];
const TYPE_COLORS = {
  sale_payment: 'var(--green)',
  advance: 'var(--blue)',
  advance_adjustment: 'var(--purple)',
  credit_note: 'var(--amber, #b45309)',
  refund: 'var(--red)',
};

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function fmtDateTime(iso) {
  return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export default function OpticalPaymentsTab() {
  const [fromDate, setFromDate] = useState(todayIST());
  const [toDate, setToDate] = useState(todayIST());
  const [query, setQuery] = useState('');
  const [payments, setPayments] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  const [editingId, setEditingId] = useState(null);
  const [editModeAmounts, setEditModeAmounts] = useState({});
  const [editReference, setEditReference] = useState('');
  const [editRemarks, setEditRemarks] = useState('');
  const [editReason, setEditReason] = useState('');
  const [editHistory, setEditHistory] = useState([]);
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');
  const [isAdmin, setIsAdmin] = useState(false);
  const [correctAmount, setCorrectAmount] = useState('');
  const [correctReason, setCorrectReason] = useState('');
  const [correcting, setCorrecting] = useState(false);

  useEffect(() => { runSearch(); getMyDesignation().then((d) => setIsAdmin(d === 'Administrator')); }, []);

  async function runSearch() {
    setLoading(true);
    setError('');
    try {
      const result = await getOpticalPaymentsRegister({ fromDate, toDate, query });
      if (result.error) setError(result.error);
      setPayments(result.payments || []);
    } catch (e) {
      setError('Could not load payments -- check your connection and try again.');
      setPayments([]);
    } finally {
      setLoading(false);
    }
  }

  async function startEdit(p) {
    setEditingId(p.id);
    setSuccessMsg('');
    setError('');
    const modeAmounts = {};
    (p.optical_payment_modes || []).forEach((m) => { modeAmounts[m.mode] = String(m.amount); });
    setEditModeAmounts(modeAmounts);
    setEditReference(p.reference || '');
    setEditRemarks(p.remarks || '');
    setEditReason('');
    setCorrectAmount('');
    setCorrectReason('');
    try {
      setEditHistory(await getOpticalPaymentEditHistory(p.id));
    } catch (e) {
      setEditHistory([]);
    }
  }

  function cancelEdit() {
    setEditingId(null);
    setEditHistory([]);
  }

  function toggleMode(m) {
    setEditModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m]; else next[m] = '';
      return next;
    });
  }
  function updateModeAmount(m, val) {
    setEditModeAmounts((prev) => ({ ...prev, [m]: val }));
  }

  async function saveEdit(p) {
    setError('');
    setSaving(true);
    try {
      const modes = Object.entries(editModeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
      const result = await editOpticalPaymentClerical({
        paymentId: p.id, modes, reference: editReference, remarks: editRemarks, reason: editReason,
        expectedModeCount: (p.optical_payment_modes || []).length,
      });
      if (result.error) { setError(result.error); return; }
      setSuccessMsg(`${p.receipt_number} updated.`);
      setEditingId(null);
      runSearch();
    } catch (e) {
      setError('Something went wrong saving the correction -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  const editModesTotal = Object.values(editModeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  async function handleCorrectAmount(p) {
    setError('');
    setCorrecting(true);
    try {
      const result = await correctOpticalPaymentAmount({ paymentId: p.id, newAmount: correctAmount, reason: correctReason });
      if (result.error) { setError(result.error); return; }
      setSuccessMsg(`${p.receipt_number} corrected to ${fmt(correctAmount)}.`);
      setEditingId(null);
      runSearch();
    } catch (e) {
      setError('Something went wrong correcting the amount -- check your connection and try again.');
    } finally {
      setCorrecting(false);
    }
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list-details" style={{ color: 'var(--blue)' }}></i> Optical Payments</div>
      {error && <div className="msg-err">{error}</div>}
      {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
        <input className="fi" type="date" value={fromDate} onChange={(e) => setFromDate(e.target.value)} style={{ flex: 1 }} />
        <input className="fi" type="date" value={toDate} onChange={(e) => setToDate(e.target.value)} style={{ flex: 1 }} />
        <input className="fi" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Receipt number / reference" style={{ flex: 2 }} />
        <button className="btn btn-primary" onClick={runSearch}><i className="ti ti-search"></i></button>
      </div>

      {loading ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>
      ) : payments.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments found for these filters.</div>
      ) : (
        <table className="tbl">
          <thead><tr><th>Receipt #</th><th>Date/Time</th><th>Bill</th><th>Customer</th><th>Type</th><th>Mode(s)</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
          <tbody>
            {payments.map((p) => (
              <Fragment key={p.id}>
                <tr style={p.cancelledRefundReason !== undefined ? { opacity: 0.6 } : undefined}>
                  <td style={{ fontFamily: 'monospace' }}>{p.receipt_number}</td>
                  <td style={{ fontSize: 12 }}>{fmtDateTime(p.collected_at)}</td>
                  <td>{p.optical_sales?.sale_number || '--'}</td>
                  <td>{p.displayName}</td>
                  <td>
                    <span style={{ color: TYPE_COLORS[p.payment_type], fontWeight: 600, fontSize: 12, textDecoration: p.cancelledRefundReason !== undefined ? 'line-through' : 'none' }}>{p.typeLabel}</span>
                    {p.cancelledRefundReason !== undefined && (
                      <div style={{ fontSize: 10, color: 'var(--red)', fontWeight: 700 }}>CANCELLED -- {p.cancelledRefundReason}</div>
                    )}
                  </td>
                  <td style={{ fontSize: 12 }}>{(p.optical_payment_modes || []).map((m) => m.mode).join('+') || '--'}</td>
                  <td style={{ textAlign: 'right', fontWeight: 600, textDecoration: p.cancelledRefundReason !== undefined ? 'line-through' : 'none' }}>{fmt(p.total_amount)}</td>
                  <td style={{ display: 'flex', gap: 6 }}>
                    <a href={`/optical-payment-receipt-print/${p.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                      <i className="ti ti-printer"></i>
                    </a>
                    {editingId === p.id ? (
                      <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                    ) : (
                      <button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i> Edit</button>
                    )}
                  </td>
                </tr>
                {editingId === p.id && (
                  <tr>
                    <td colSpan={8} style={{ background: 'var(--g50, #f7f8fa)', padding: 14 }}>
                      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
                        Clerical correction only -- the mode split below must still add up to the original amount ({fmt(p.total_amount)}). To change the amount itself, use Refund or Credit Note instead.
                      </div>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
                        {PAYMENT_MODES.map((m) => (
                          <button key={m} className={m in editModeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
                        ))}
                      </div>
                      {Object.keys(editModeAmounts).map((m) => (
                        <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
                          <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
                          <input className="fi fi-sm" style={{ width: 140 }} type="number" value={editModeAmounts[m]} onChange={(e) => updateModeAmount(m, e.target.value)} />
                        </div>
                      ))}
                      <div style={{ fontSize: 11.5, color: editModesTotal === Number(p.total_amount) ? 'var(--g500)' : 'var(--red)', marginBottom: 10 }}>
                        Mode split total: {fmt(editModesTotal)} {editModesTotal !== Number(p.total_amount) ? `(must equal ${fmt(p.total_amount)})` : ''}
                      </div>
                      <div style={{ display: 'flex', gap: 12, marginBottom: 8 }}>
                        <input className="fi fi-sm" value={editReference} onChange={(e) => setEditReference(e.target.value)} placeholder="Reference" style={{ flex: 1 }} />
                        <input className="fi fi-sm" value={editRemarks} onChange={(e) => setEditRemarks(e.target.value)} placeholder="Remarks" style={{ flex: 1 }} />
                      </div>
                      <input className="fi fi-sm" value={editReason} onChange={(e) => setEditReason(e.target.value)} placeholder="Reason for this correction (required)" style={{ marginBottom: 10 }} />
                      <button className="btn btn-sm btn-primary" disabled={saving} onClick={() => saveEdit(p)}>{saving ? 'Saving...' : 'Save Correction'}</button>

                      {isAdmin && p.payment_type !== 'refund' && (
                        <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1px dashed var(--g300)' }}>
                          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber, #b45309)', textTransform: 'uppercase', marginBottom: 6 }}>
                            <i className="ti ti-alert-triangle"></i> Correct Amount (Administrator only)
                          </div>
                          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
                            For a genuinely over-recorded amount (a typo) -- not a real refund. Reduces this payment, its mode split, and the bill's outstanding balance directly. Corrected amount must be less than {fmt(p.total_amount)}.
                          </div>
                          <div style={{ display: 'flex', gap: 8, marginBottom: 8, flexWrap: 'wrap' }}>
                            <input
                              className="fi fi-sm" type="number" style={{ maxWidth: 160 }}
                              placeholder={`New amount (was ${fmt(p.total_amount)})`}
                              value={correctAmount} onChange={(e) => setCorrectAmount(e.target.value)}
                            />
                            <input
                              className="fi fi-sm" style={{ flex: 1, minWidth: 200 }}
                              placeholder="Reason for correcting the amount (required)"
                              value={correctReason} onChange={(e) => setCorrectReason(e.target.value)}
                            />
                          </div>
                          <button className="btn btn-sm" style={{ background: 'var(--amber, #b45309)', color: '#fff', border: 'none' }} disabled={correcting} onClick={() => handleCorrectAmount(p)}>
                            {correcting ? 'Correcting...' : 'Correct Amount'}
                          </button>
                        </div>
                      )}

                      {editHistory.length > 0 && (
                        <div style={{ marginTop: 14, paddingTop: 10, borderTop: '1px solid var(--g200)' }}>
                          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', marginBottom: 6 }}>Edit History</div>
                          {editHistory.map((h) => (
                            <div key={h.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '3px 0' }}>
                              {fmtDateTime(h.edited_at)} -- {h.profiles?.full_name || 'Unknown'}
                              {h.old_amount != null ? <> -- <strong style={{ color: 'var(--amber, #b45309)' }}>Amount corrected {fmt(h.old_amount)} to {fmt(h.new_amount)}</strong></> : ''} -- {h.reason}
                            </div>
                          ))}
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
