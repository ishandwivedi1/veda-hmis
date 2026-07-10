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

