'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { searchReceipts, editPaymentClerical, getPaymentEditHistory } from '../actions';

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const TYPE_BADGE = { invoice_payment: 'b-blue', advance: 'b-purple', advance_adjustment: 'b-amber', credit_note: 'b-teal' };
const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Adjustment', credit_note: 'Credit Note' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'amount_high', label: 'Amount (High-Low)' },
  { value: 'amount_low', label: 'Amount (Low-High)' },
];

function sortReceipts(receipts, sort) {
  const list = [...receipts];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.collected_at) - new Date(b.collected_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'amount_high': return list.sort((a, b) => Number(b.total_amount) - Number(a.total_amount));
    case 'amount_low': return list.sort((a, b) => Number(a.total_amount) - Number(b.total_amount));
    default: return list.sort((a, b) => new Date(b.collected_at) - new Date(a.collected_at)); // newest
  }
}

export default function ReceiptTab() {
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [receipts, setReceipts] = useState([]);

  const [editingId, setEditingId] = useState(null);
  const [editModes, setEditModes] = useState([]);
  const [editReference, setEditReference] = useState('');
  const [editRemarks, setEditRemarks] = useState('');
  const [editReason, setEditReason] = useState('');
  const [editHistory, setEditHistory] = useState([]);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [saving, setSaving] = useState(false);

  const runSearch = useCallback(async () => {
    setReceipts(await searchReceipts(query, modeFilter));
  }, [query, modeFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  const sortedReceipts = sortReceipts(receipts, sortBy);

  async function startEdit(r) {
    setError(''); setSuccess('');
    setEditingId(r.id);
    setEditModes((r.payment_modes || []).map((m) => ({ mode: m.mode, amount: String(m.amount) })));
    setEditReference(r.reference || '');
    setEditRemarks(r.remarks || '');
    setEditReason('');
    setEditHistory(await getPaymentEditHistory(r.id));
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  function updateModeRow(idx, field, value) {
    setEditModes((rows) => rows.map((row, i) => (i === idx ? { ...row, [field]: value } : row)));
  }

  function addModeRow() {
    setEditModes((rows) => [...rows, { mode: 'Cash', amount: '' }]);
  }

  function removeModeRow(idx) {
    setEditModes((rows) => rows.filter((_, i) => i !== idx));
  }

  async function saveEdit(receipt) {
    setError(''); setSuccess('');
    if (!editReason.trim()) { setError('A reason is required to edit this payment.'); return; }
    const modesPayload = editModes.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const modesSum = modesPayload.reduce((s, m) => s + m.amount, 0);
    if (Math.abs(modesSum - Number(receipt.total_amount)) > 0.01) {
      setError(`Mode split (Rs.${modesSum.toFixed(2)}) must still add up to the original amount collected (Rs.${Number(receipt.total_amount).toFixed(2)}). To change the amount itself, use Refund or Credit Note instead.`);
      return;
    }

    setSaving(true);
    const result = await editPaymentClerical(receipt.id, modesPayload, editReference, editRemarks, editReason);
    setSaving(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`${receipt.receipt_number} updated.`);
    setEditingId(null);
    runSearch();
  }

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
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
        <table className="tbl">
          <thead>
            <tr><th>Receipt #</th><th>Date/Time</th><th>Patient</th><th>Invoice ref</th><th>Mode(s)</th><th>Amount</th><th>Type</th><th></th></tr>
          </thead>
          <tbody>
            {sortedReceipts.map((r) => (
              <Fragment key={r.id}>
                <tr>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{r.receipt_number}</td>
                  <td>{new Date(r.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td style={{ fontWeight: 600 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--'}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_modes || []).map((m) => `${m.mode} Rs.${m.amount}`).join(', ')}</td>
                  <td style={{ fontWeight: 600 }}>Rs.{r.total_amount}</td>
                  <td><span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || r.payment_type || 'Payment'}</span></td>
                  <td style={{ display: 'flex', gap: 4 }}>
                    <a href={`/receipt-print/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                      <i className="ti ti-printer"></i>
                    </a>
                    <button className="btn btn-sm" onClick={() => (editingId === r.id ? cancelEdit() : startEdit(r))}>
                      <i className="ti ti-edit"></i> {editingId === r.id ? 'Close' : 'Edit'}
                    </button>
                  </td>
                </tr>
                {editingId === r.id && (
                  <tr key={`${r.id}-edit`}>
                    <td colSpan={8} style={{ background: 'var(--g50)', padding: 16 }}>
                      <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 10 }}>
                        <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Edit clerical details for {r.receipt_number}
                      </div>
                      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                        <i className="ti ti-info-circle"></i> For correcting clerical mistakes only -- payment mode, reference number, remarks. The mode split must still total Rs.{r.total_amount}. To change the amount collected, use Refund or Credit Note instead.
                      </div>

                      <label className="flbl">Payment mode(s)</label>
                      {editModes.map((row, idx) => (
                        <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                          <select className="fi" style={{ flex: 1 }} value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)}>
                            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
                          </select>
                          <input type="number" className="fi" style={{ flex: 1 }} value={row.amount} onChange={(e) => updateModeRow(idx, 'amount', e.target.value)} placeholder="Amount" />
                          {editModes.length > 1 && <button className="btn" style={{ padding: '4px 10px' }} onClick={() => removeModeRow(idx)}>x</button>}
                        </div>
                      ))}
                      <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Add mode</button>

                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                        <div>
                          <label className="flbl">Reference / Transaction ID</label>
                          <input className="fi" value={editReference} onChange={(e) => setEditReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
                        </div>
                        <div>
                          <label className="flbl">Remarks</label>
                          <input className="fi" value={editRemarks} onChange={(e) => setEditRemarks(e.target.value)} />
                        </div>
                      </div>

                      <label className="flbl">Reason for this edit *</label>
                      <input className="fi" style={{ marginBottom: 10 }} value={editReason} onChange={(e) => setEditReason(e.target.value)} placeholder="e.g. Staff mis-entered UPI as Cash" />

                      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                        <button className="btn btn-primary btn-sm" onClick={() => saveEdit(r)} disabled={saving}>{saving ? 'Saving...' : 'Save Correction'}</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </div>

                      {editHistory.length > 0 && (
                        <div>
                          <label className="flbl" style={{ marginBottom: 6 }}>Edit history</label>
                          {editHistory.map((h) => (
                            <div key={h.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g200)' }}>
                              {new Date(h.edited_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {h.profiles?.full_name || 'Staff'} -- {h.reason}
                            </div>
                          ))}
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {sortedReceipts.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

