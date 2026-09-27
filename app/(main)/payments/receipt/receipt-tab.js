'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { searchReceipts, resendPaymentReceiptWhatsApp } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';
import PaymentEditPanel from '../payment-edit-panel';
import DeletedPayments from '../deleted-payments';

// Editing and deleting go through the shared PaymentEditPanel
// (edit_payment / delete_payment in Postgres): amount, date, modes,
// reference and which invoices a payment pays -- subject to Billing
// Permissions and closed days, every change kept in the history.
// The older clerical-only edit and Administrator "Correct Amount" were
// retired on 27 Sep 2026.

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
    case 'patient_az': return list.sort((a, b) => `${formatPatientName(a.patients)}`.localeCompare(`${formatPatientName(b.patients)}`));
    case 'amount_high': return list.sort((a, b) => Number(b.total_amount) - Number(a.total_amount));
    case 'amount_low': return list.sort((a, b) => Number(a.total_amount) - Number(b.total_amount));
    default: return list.sort((a, b) => new Date(b.collected_at) - new Date(a.collected_at)); // newest
  }
}

export default function ReceiptTab() {
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [receipts, setReceipts] = useState([]);

  const [editingId, setEditingId] = useState(null);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [waStatus, setWaStatus] = useState({}); // { [receiptId]: 'sending'|'sent'|'warning'|'error' }
  const [waMsg, setWaMsg] = useState({});
  const [view, setView] = useState('register'); // 'register' | 'deleted'

  async function handleSendWhatsApp(receiptId) {
    setWaStatus((s) => ({ ...s, [receiptId]: 'sending' }));
    setWaMsg((s) => ({ ...s, [receiptId]: '' }));
    const result = await resendPaymentReceiptWhatsApp(receiptId);
    if (result.error) {
      setWaStatus((s) => ({ ...s, [receiptId]: 'error' }));
      setWaMsg((s) => ({ ...s, [receiptId]: result.error }));
      return;
    }
    if (result.warning) {
      setWaStatus((s) => ({ ...s, [receiptId]: 'warning' }));
      setWaMsg((s) => ({ ...s, [receiptId]: result.warning }));
      return;
    }
    setWaStatus((s) => ({ ...s, [receiptId]: 'sent' }));
  }

  const runSearch = useCallback(async () => {
    setReceipts(await searchReceipts(query, modeFilter, dateFrom, dateTo));
  }, [query, modeFilter, dateFrom, dateTo]);

  // Wait for a pause in typing: Next.js runs server calls one at a time,
  // so searching on every keystroke queued up one request per letter.
  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const sortedReceipts = sortReceipts(receipts, sortBy);

  function startEdit(r) {
    setError(''); setSuccess('');
    setEditingId(r.id);
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, gap: 8, flexWrap: 'wrap' }}>
          <div className="card-title" style={{ marginBottom: 0 }}>
            <i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> {view === 'deleted' ? 'Deleted Receipts' : 'Receipt Register'}
          </div>
          <div style={{ display: 'flex', gap: 6 }}>
            <button className={view === 'register' ? 'btn btn-primary btn-sm' : 'btn btn-sm'} onClick={() => setView('register')}>Receipts</button>
            <button className={view === 'deleted' ? 'btn btn-primary btn-sm' : 'btn btn-sm'} onClick={() => { setView('deleted'); setEditingId(null); }}>
              <i className="ti ti-trash"></i> Deleted receipts
            </button>
          </div>
        </div>
        {view === 'register' && <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
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
          <input type="date" className="fi" style={{ width: 150 }} value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} title="From date" />
          <input type="date" className="fi" style={{ width: 150 }} value={dateTo} onChange={(e) => setDateTo(e.target.value)} title="To date" />
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>}
        {view === 'register' && !query && !dateFrom && !dateTo && (
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>
            Showing the 50 most recent receipts. Search by receipt #/patient/UHID or set a date range to reach older ones.
          </div>
        )}
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      {view === 'deleted' && <DeletedPayments />}

      {view === 'register' && <div style={{ display: 'grid', gridTemplateColumns: editingId ? 'minmax(0, 1fr) minmax(0, 1.1fr)' : '1fr', gap: 16, alignItems: 'start' }}>
      <div className="card" style={{ padding: 0, overflow: 'auto' }}>
        <table className="tbl">
          <thead>
            <tr><th>Receipt #</th><th>Date/Time</th><th>Patient</th><th>Invoice ref</th><th>Mode(s)</th><th>Amount</th><th>Type</th><th></th></tr>
          </thead>
          <tbody>
            {sortedReceipts.map((r) => (
              <Fragment key={r.id}>
                <tr style={{ ...(r.cancelledRefundReason !== undefined ? { opacity: 0.6 } : {}), ...(editingId === r.id ? { background: 'var(--blue-lt)' } : {}) }}>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{r.receipt_number}</td>
                  <td>{new Date(r.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td style={{ fontWeight: 600 }}>{formatPatientName(r.patients)}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--'}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_modes || []).map((m) => `${m.mode} Rs.${m.amount}`).join(', ')}</td>
                  <td style={{ fontWeight: 600, textDecoration: r.cancelledRefundReason !== undefined ? 'line-through' : 'none' }}>Rs.{r.total_amount}</td>
                  <td>
                    <span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`} style={{ textDecoration: r.cancelledRefundReason !== undefined ? 'line-through' : 'none' }}>{TYPE_LABEL[r.payment_type] || r.payment_type || 'Payment'}</span>
                    {r.cancelledRefundReason !== undefined && (
                      <div style={{ fontSize: 10, color: 'var(--red)', fontWeight: 700, marginTop: 2 }}>CANCELLED -- {r.cancelledRefundReason}</div>
                    )}
                  </td>
                  <td style={{ display: 'flex', gap: 4, alignItems: 'center', flexWrap: 'wrap' }}>
                    <button className="btn btn-sm" onClick={() => openPrintPopup(`/receipt-print/${r.id}`)}>
                      <i className="ti ti-printer"></i>
                    </button>
                    <button className="btn btn-sm" onClick={() => (editingId === r.id ? cancelEdit() : startEdit(r))}>
                      <i className="ti ti-edit"></i> {editingId === r.id ? 'Close' : 'Edit'}
                    </button>
                    <button className="btn btn-sm" onClick={() => handleSendWhatsApp(r.id)} disabled={waStatus[r.id] === 'sending'} title="Send WhatsApp confirmation">
                      <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i>
                    </button>
                    {waStatus[r.id] === 'sent' && <span style={{ fontSize: 10, color: 'var(--green)' }}><i className="ti ti-circle-check"></i></span>}
                    {waStatus[r.id] === 'warning' && <span style={{ fontSize: 10, color: 'var(--amber)' }} title={waMsg[r.id]}><i className="ti ti-alert-triangle"></i></span>}
                    {waStatus[r.id] === 'error' && <span style={{ fontSize: 10, color: 'var(--red)' }} title={waMsg[r.id]}><i className="ti ti-alert-circle"></i></span>}
                  </td>
                </tr>
              </Fragment>
            ))}
            {sortedReceipts.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
      {editingId && (
        <div className="card" style={{ position: 'sticky', top: 12 }}>
          <PaymentEditPanel
            key={editingId}
            paymentId={editingId}
            onClose={cancelEdit}
            onChanged={(msg) => {
              setSuccess(msg);
              setEditingId(null);
              runSearch();
            }}
          />
        </div>
      )}
      </div>}
    </div>
  );
}

