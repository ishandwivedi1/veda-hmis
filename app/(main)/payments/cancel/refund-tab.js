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

