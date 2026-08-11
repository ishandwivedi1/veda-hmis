'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, resendInvoiceBillWhatsApp } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'net_high', label: 'Net (High-Low)' },
  { value: 'net_low', label: 'Net (Low-High)' },
];

function sortInvoices(invoices, sort) {
  const list = [...invoices];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'net_high': return list.sort((a, b) => Number(b.net) - Number(a.net));
    case 'net_low': return list.sort((a, b) => Number(a.net) - Number(b.net));
    default: return list.sort((a, b) => new Date(b.created_at) - new Date(a.created_at)); // newest
  }
}

export default function InvoiceDetailsTab() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [invoices, setInvoices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [error, setError] = useState('');
  const [waStatus, setWaStatus] = useState(''); // '', 'sending', 'sent', 'warning', 'error'
  const [waMsg, setWaMsg] = useState('');

  async function handleSendWhatsAppBill() {
    if (!selected) return;
    setWaStatus('sending');
    setWaMsg('');
    const result = await resendInvoiceBillWhatsApp(selected.id);
    if (result.error) { setWaStatus('error'); setWaMsg(result.error); return; }
    if (result.warning) { setWaStatus('warning'); setWaMsg(result.warning); return; }
    setWaStatus('sent');
  }

  const runSearch = useCallback(async () => {
    setInvoices(await searchInvoices(query, deptFilter));
  }, [query, deptFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  const sortedInvoices = sortInvoices(invoices, sortBy);

  async function openInvoice(inv) {
    setError('');
    setWaStatus('');
    setWaMsg('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  // Deep-linked from elsewhere (e.g. Pharmacy History's "View
  // Invoice") -- open that exact invoice directly instead of
  // requiring a text search first.
  const urlInvoiceId = searchParams.get('invoiceId');
  useEffect(() => {
    if (urlInvoiceId) openInvoice({ id: urlInvoiceId });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [urlInvoiceId]);

  const balanceDue = selected ? Number(selected.net) - Number(selected.paid) : 0;

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Search Invoices
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 200 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Patient name or UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={deptFilter} onChange={(e) => setDeptFilter(e.target.value)}>
            <option value="">All departments</option>
            <option>Consultation</option>
            <option>Investigation</option>
            <option>Surgery</option>
            <option>Pharmacy</option>
          </select>
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>

        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Date</th><th>Patient</th><th>Visit</th><th>Gross</th><th>Disc</th><th>Net</th><th>Paid</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {sortedInvoices.map((inv) => (
              <tr key={inv.id} onClick={() => openInvoice(inv)} style={{ cursor: 'pointer', background: selected?.id === inv.id ? 'var(--blue-lt)' : 'transparent' }}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{inv.invoice_number || '--'}</td>
                <td>{new Date(inv.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}</td>
                <td style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td>Rs.{inv.gross}</td>
                <td>{inv.gross - inv.net > 0 ? `Rs.${(inv.gross - inv.net).toFixed(2)}` : '--'}</td>
                <td>Rs.{inv.net}</td>
                <td>Rs.{inv.paid}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                <td>
                  <button
                    onClick={(e) => { e.stopPropagation(); openPrintPopup(`/invoice-print/${inv.id}`); }}
                    className="btn"
                    style={{ padding: '3px 8px', fontSize: 11 }}
                    title="Print / PDF"
                  >
                    <i className="ti ti-printer"></i>
                  </button>
                </td>
              </tr>
            ))}
            {sortedInvoices.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices found.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {selected && (
        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> {selected.invoice_number || 'Invoice Detail'}</div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <button onClick={() => openPrintPopup(`/invoice-print/${selected.id}`)} className="btn btn-sm">
                  <i className="ti ti-printer"></i> Print / PDF
                </button>
                <button onClick={handleSendWhatsAppBill} className="btn btn-sm" disabled={waStatus === 'sending'}>
                  <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i>
                  {waStatus === 'sending' ? 'Sending...' : 'Send WhatsApp Bill'}
                </button>
                <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
              </div>
            </div>
            {error && <div className="msg-err">{error}</div>}
            {waStatus === 'sent' && (
              <div className="msg-success" style={{ marginBottom: 10 }}>
                <i className="ti ti-circle-check"></i> WhatsApp bill sent.
              </div>
            )}
            {waStatus === 'warning' && (
              <div className="msg-info" style={{ marginBottom: 10, color: 'var(--amber)' }}>
                <i className="ti ti-alert-triangle"></i> {waMsg}
              </div>
            )}
            {waStatus === 'error' && (
              <div className="msg-err" style={{ marginBottom: 10 }}>
                <i className="ti ti-alert-circle"></i> {waMsg}
              </div>
            )}
            <div style={{ fontSize: 13, marginBottom: 12 }}>
              <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
            </div>
            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Net</th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id}><td>{li.service_name}</td><td>{li.qty}</td><td>Rs.{li.net}</td></tr>
                ))}
              </tbody>
            </table>
            <div style={{ fontSize: 13, lineHeight: 1.9, marginTop: 12, borderTop: '1px solid var(--g200)', paddingTop: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Net Total</span><span style={{ fontWeight: 700 }}>Rs.{selected.net}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>Rs.{selected.paid}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, color: balanceDue > 0 ? 'var(--red)' : 'var(--green)' }}><span>Balance Due</span><span>Rs.{balanceDue}</span></div>
            </div>
          </div>

          {balanceDue > 0 && selected.status !== 'Cancelled' && (
            <div className="card">
              <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
                Balance of Rs.{balanceDue} still due on this invoice.
              </div>
              <a
                href={`/payments/collect?patientId=${selected.patient_id}&invoiceId=${selected.id}`}
                className="btn btn-primary"
                style={{ textDecoration: 'none' }}
              >
                <i className="ti ti-cash"></i> Collect Payment
              </a>
            </div>
          )}
        </div>
      )}
    </div>
  );
}


