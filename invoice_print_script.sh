mkdir -p 'app/invoice-print/[invoiceId]' 'app/(main)/billing/details' 'app/(main)/billing/cancel' 'app/(main)/billing/new' 'app/(main)/billing/package'

cat > 'app/invoice-print/[invoiceId]/page.js' << 'EOF'
import { createClient } from '../../../lib/supabase-server';
import PrintButton from './print-button';

export default async function InvoicePrintPage({ params }) {
  const { invoiceId } = await params;
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid, mobile, address, city, state, pin_code)')
    .eq('id', invoiceId)
    .single();

  if (error || !invoice) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Invoice not found.</div>;
  }

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoiceId)
    .order('id');

  const balanceDue = Number(invoice.net) - Number(invoice.paid);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc), 0);

  return (
    <div style={{ maxWidth: 750, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #1d4ed8', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#1e3a8a' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Bill To</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{invoice.patients?.first_name} {invoice.patients?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients?.uhid}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients?.mobile}</div>
          {invoice.patients?.address && <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients.address}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Invoice</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{invoice.invoice_number}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{new Date(invoice.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' })}</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 4, color: invoice.status === 'Cancelled' ? '#b91c1c' : '#15803d' }}>{invoice.status}</div>
        </div>
      </div>

      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 20, fontSize: 13 }}>
        <thead>
          <tr style={{ borderBottom: '2px solid #1f2937' }}>
            <th style={{ textAlign: 'left', padding: '8px 4px' }}>Service</th>
            <th style={{ textAlign: 'center', padding: '8px 4px' }}>Qty</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Rate</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Disc</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>GST</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Net</th>
          </tr>
        </thead>
        <tbody>
          {(lineItems || []).map((li) => (
            <tr key={li.id} style={{ borderBottom: '1px solid #e5e7eb' }}>
              <td style={{ padding: '8px 4px' }}>{li.service_name}</td>
              <td style={{ textAlign: 'center', padding: '8px 4px' }}>{li.qty}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{Number(li.rate).toFixed(2)}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{li.disc > 0 ? Number(li.disc).toFixed(2) : '--'}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{Number(li.gst_amount).toFixed(2)}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px', fontWeight: 600 }}>{Number(li.net).toFixed(2)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <div style={{ marginLeft: 'auto', width: 260, fontSize: 13 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>Gross</span><span>Rs.{Number(invoice.gross).toFixed(2)}</span></div>
        {totalDisc > 0 && <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>Discount</span><span>-Rs.{totalDisc.toFixed(2)}</span></div>}
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>GST</span><span>Rs.{Number(invoice.gst).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderTop: '1px solid #1f2937', fontWeight: 700, fontSize: 14 }}><span>Net Total</span><span>Rs.{Number(invoice.net).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', color: '#15803d' }}><span>Paid</span><span>Rs.{Number(invoice.paid).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', fontWeight: 700, color: balanceDue > 0 ? '#b91c1c' : '#15803d' }}><span>Balance Due</span><span>Rs.{balanceDue.toFixed(2)}</span></div>
      </div>

      {invoice.status === 'Cancelled' && (
        <div style={{ marginTop: 20, padding: 12, background: '#fee2e2', color: '#b91c1c', borderRadius: 6, fontSize: 12 }}>
          Cancelled -- Reason: {invoice.cancellation_reason}
        </div>
      )}

      <div style={{ marginTop: 40, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated invoice.
      </div>
    </div>
  );
}

EOF

cat > 'app/invoice-print/[invoiceId]/print-button.js' << 'EOF'
'use client';

export default function PrintButton() {
  return (
    <button
      onClick={() => window.print()}
      style={{
        padding: '9px 16px',
        borderRadius: 8,
        fontSize: 13,
        fontWeight: 600,
        cursor: 'pointer',
        border: 'none',
        background: '#1d4ed8',
        color: '#fff',
      }}
    >
      Print / Save as PDF
    </button>
  );
}

EOF

cat > 'app/globals.css' << 'EOF'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --blue: #1d4ed8; --blue-lt: #dbeafe; --blue-dk: #1e3a8a; --blue-mid: #3b82f6;
  --green: #15803d; --green-lt: #dcfce7;
  --red: #b91c1c; --red-lt: #fee2e2;
  --amber: #b45309; --amber-lt: #fef3c7;
  --purple: #7c3aed; --purple-lt: #ede9fe;
  --teal: #0f766e; --teal-lt: #ccfbf1;
  --g50: #f9fafb; --g100: #f3f4f6; --g200: #e5e7eb; --g300: #d1d5db;
  --g400: #9ca3af; --g500: #6b7280; --g600: #4b5563; --g700: #374151; --g800: #1f2937; --g900: #111827;
  --r: 8px; --r-lg: 12px;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
}

/* ── APP SHELL ── */
.app-layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: #fff; border-right: 1px solid var(--g200); display: flex; flex-direction: column; flex-shrink: 0; }
.sb-logo { display: flex; align-items: center; gap: 10px; padding: 18px 16px; border-bottom: 1px solid var(--g100); }
.sb-logo-icon { width: 34px; height: 34px; border-radius: 8px; background: var(--blue); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 17px; flex-shrink: 0; }
.sb-name { font-weight: 700; font-size: 13px; }
.sb-sub { font-size: 10px; color: var(--g400); }
.sb-sec { padding: 14px 16px 6px; font-size: 10px; font-weight: 700; color: var(--g400); text-transform: uppercase; letter-spacing: .4px; }
.sb-item { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-size: 13px; color: var(--g600); cursor: pointer; border-left: 3px solid transparent; text-decoration: none; }
.sb-item:hover { background: var(--g50); }
.sb-item.active { background: var(--blue-lt); color: var(--blue-dk); border-left-color: var(--blue); font-weight: 600; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; }
.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.topbar { background: #fff; border-bottom: 1px solid var(--g200); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; }
.top-title { font-size: 16px; font-weight: 700; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 1px; }
.content-area { flex: 1; overflow-y: auto; padding: 24px; }

/* ── CARDS ── */
.card { background: #fff; border: 1px solid var(--g200); border-radius: var(--r-lg); padding: 20px; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-size: 14px; font-weight: 700; display: flex; align-items: center; gap: 7px; }

/* ── BUTTONS ── */
.btn { padding: 9px 16px; border-radius: var(--r); font-size: 13px; font-weight: 600; cursor: pointer; border: 1px solid var(--g200); background: #fff; color: var(--g700); font-family: inherit; transition: all .12s; display: inline-flex; align-items: center; gap: 6px; }
.btn:hover { background: var(--g50); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; }
.btn-primary:hover { background: var(--blue-dk); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; }
.btn-sm { padding: 5px 10px; font-size: 11.5px; }

/* ── BADGES ── */
.badge { padding: 2px 10px; border-radius: 12px; font-size: 11px; font-weight: 700; display: inline-flex; align-items: center; gap: 4px; }
.b-blue { background: var(--blue-lt); color: var(--blue); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi { width: 100%; padding: 9px 12px; border: 1.5px solid var(--g200); border-radius: var(--r); font-size: 13px; font-family: inherit; background: #fff; }
.fi:focus { outline: none; border-color: var(--blue); }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }
.msg-err { background: var(--red-lt); color: var(--red); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-success { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 8px 10px; color: var(--g500); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .3px; border-bottom: 1.5px solid var(--g200); }
.tbl td { padding: 9px 10px; border-bottom: 1px solid var(--g100); }

/* ── PRINT ── */
@media print {
  .no-print { display: none !important; }
  body { background: #fff; }
}

EOF

cat > 'app/(main)/billing/details/invoice-details-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, recordPayment } from '../actions';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceDetailsTab() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [invoices, setInvoices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [paymentAmount, setPaymentAmount] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const runSearch = useCallback(async () => {
    setInvoices(await searchInvoices(query, deptFilter));
  }, [query, deptFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  async function openInvoice(inv) {
    setError('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  async function handleRecordPayment() {
    setError('');
    const amt = parseFloat(paymentAmount);
    if (!amt || amt <= 0) { setError('Enter a valid payment amount.'); return; }
    setLoading(true);
    const result = await recordPayment(selected.id, amt);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setPaymentAmount('');
    openInvoice(selected);
    runSearch();
  }

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
        </div>

        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Date</th><th>Patient</th><th>Visit</th><th>Gross</th><th>Disc</th><th>Net</th><th>Paid</th><th>Status</th></tr></thead>
          <tbody>
            {invoices.map((inv) => (
              <tr key={inv.id} onClick={() => openInvoice(inv)} style={{ cursor: 'pointer', background: selected?.id === inv.id ? 'var(--blue-lt)' : 'transparent' }}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{inv.invoice_number || '--'}</td>
                <td>{new Date(inv.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}</td>
                <td style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td>Rs.{inv.gross}</td>
                <td>{inv.gross - inv.net > 0 ? `Rs.${(inv.gross - inv.net).toFixed(2)}` : '--'}</td>
                <td>Rs.{inv.net}</td>
                <td>Rs.{inv.paid}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
              </tr>
            ))}
            {invoices.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices found.</td></tr>
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
                <a href={`/invoice-print/${selected.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                  <i className="ti ti-printer"></i> Print / PDF
                </a>
                <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
              </div>
            </div>
            {error && <div className="msg-err">{error}</div>}
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
              <div className="card-title" style={{ marginBottom: 10 }}>Collect Payment</div>
              <div style={{ display: 'flex', gap: 8 }}>
                <input type="number" className="fi" placeholder={`Up to Rs.${balanceDue}`} value={paymentAmount} onChange={(e) => setPaymentAmount(e.target.value)} />
                <button className="btn btn-primary" onClick={handleRecordPayment} disabled={loading}>{loading ? 'Recording...' : 'Record'}</button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/billing/cancel/invoice-modification-tab.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchInvoices, getInvoiceById, getServiceCatalog, addLineItem, removeLineItem, cancelInvoice } from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);

  const [dept, setDept] = useState('');
  const [serviceCode, setServiceCode] = useState('');
  const [qty, setQty] = useState(1);

  const [removeReasonFor, setRemoveReasonFor] = useState(null);
  const [removeReason, setRemoveReason] = useState('');

  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');

  useEffect(() => { getServiceCatalog().then(setCatalog); }, []);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setResults(await searchInvoices(searchQuery.trim()));
  }

  async function openInvoice(inv) {
    setError(''); setInfo('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
    setShowCancelForm(false);
    setCancelReason('');
  }

  async function refresh() {
    const details = await getInvoiceById(selected.id);
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  async function handleAddLine() {
    setError('');
    if (!serviceCode) { setError('Select department and service.'); return; }
    const result = await addLineItem(selected.id, serviceCode, parseInt(qty, 10) || 1, 'none', 0, null);
    if (result.error) { setError(result.error); return; }
    setDept(''); setServiceCode(''); setQty(1);
    refresh();
  }

  async function confirmRemoveLine() {
    setError('');
    if (!removeReason.trim()) { setError('A reason is required to remove a line item from an existing invoice.'); return; }
    const result = await removeLineItem(removeReasonFor, removeReason);
    if (result.error) { setError(result.error); return; }
    setRemoveReasonFor(null);
    setRemoveReason('');
    setInfo('Line item removed and logged.');
    refresh();
  }

  async function handleCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A cancellation reason is required.'); return; }
    const result = await cancelInvoice(selected.id, cancelReason);
    if (result.error) { setError(result.error); return; }
    setInfo('Invoice cancelled and logged for audit.');
    setShowCancelForm(false);
    setCancelReason('');
    refresh();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.3fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Find Invoice
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
        </div>
        {results.map((inv) => (
          <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
              <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
            </div>
            <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
          </div>
        ))}
        {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Search to find an invoice.</div>}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.invoice_number}</div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <a href={`/invoice-print/${selected.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
            </div>
          </div>
          <div style={{ fontSize: 13, marginBottom: 12 }}>
            <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          <table className="tbl">
            <thead><tr><th>Service</th><th>Qty</th><th>Net</th><th></th></tr></thead>
            <tbody>
              {lineItems.map((li) => (
                <tr key={li.id}>
                  <td>{li.service_name}</td>
                  <td>{li.qty}</td>
                  <td>Rs.{li.net}</td>
                  <td>
                    {selected.status !== 'Cancelled' && (
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => { setRemoveReasonFor(li.id); setRemoveReason(''); setError(''); }}>
                        Remove
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {removeReasonFor && (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12, marginTop: 10 }}>
              <label className="flbl">Reason for removing this line item *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={removeReason} onChange={(e) => setRemoveReason(e.target.value)} placeholder="e.g. Billed in error" />
                <button className="btn btn-primary btn-sm" onClick={confirmRemoveLine}>Confirm</button>
                <button className="btn btn-sm" onClick={() => setRemoveReasonFor(null)}>Cancel</button>
              </div>
            </div>
          )}

          {selected.status !== 'Cancelled' && (
            <>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '16px 0 8px' }}>Add Line Item</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 80px', gap: 8, marginBottom: 8 }}>
                <select className="fi" value={dept} onChange={(e) => { setDept(e.target.value); setServiceCode(''); }}>
                  <option value="">-- Dept --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
                <select className="fi" value={serviceCode} onChange={(e) => setServiceCode(e.target.value)} disabled={!dept}>
                  <option value="">-- Service --</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
              </div>
              <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
                <i className="ti ti-plus"></i> Add
              </button>
            </>
          )}

          <div style={{ borderTop: '1px solid var(--g200)', paddingTop: 12, marginTop: 4 }}>
            <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Net Total: Rs.{selected.net} -- Paid: Rs.{selected.paid}</div>

            {selected.status === 'Cancelled' ? (
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>
                <i className="ti ti-x-circle" style={{ color: 'var(--red)' }}></i> Cancelled -- reason: {selected.cancellation_reason}
              </div>
            ) : selected.paid > 0 ? (
              <div className="msg-info" style={{ margin: 0 }}>
                <i className="ti ti-info-circle"></i> This invoice has payments recorded and cannot be cancelled. Contact an administrator if needed.
              </div>
            ) : !showCancelForm ? (
              <button className="btn" style={{ color: 'var(--red)' }} onClick={() => setShowCancelForm(true)}>
                <i className="ti ti-x-circle"></i> Cancel Invoice
              </button>
            ) : (
              <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12 }}>
                <label className="flbl">Cancellation reason *</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
                  <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleCancel}>Confirm Cancel</button>
                  <button className="btn btn-sm" onClick={() => setShowCancelForm(false)}>Back</button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/billing/new/new-invoice-tab.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  createStandaloneInvoice,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  removeLineItem,
  getTodaysVisitsForBilling,
  getInvoiceForVisit,
} from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoice, setInvoice] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);

  const [dept, setDept] = useState('');
  const [selectedServiceCode, setSelectedServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [error, setError] = useState('');
  const [finalized, setFinalized] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);
  const router = useRouter();
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
    getTodaysVisitsForBilling().then(setTodaysVisits);
  }, []);

  // If we arrived here via a "Bill" link elsewhere in the app (e.g. from
  // Visits or Front Office Dashboard), open that visit's real invoice
  // automatically -- so the redirect still feels seamless, not like
  // starting over.
  useEffect(() => {
    if (!urlVisitId) return;
    (async () => {
      const details = await getInvoiceForVisit(urlVisitId);
      if (details.error) { setError(details.error); return; }
      setSelectedPatient(details.visit.patients);
      setInvoice(details.invoice);
      setLineItems(details.lineItems);
    })();
  }, [urlVisitId]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvoice(searchQuery.trim());
    setSearchResults(results);
  }

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const result = await createStandaloneInvoice(p.id);
    if (result.error) { setError(result.error); return; }
    const details = await getInvoiceById(result.invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function pickVisit(v) {
    setError('');
    setSelectedPatient(v.patients);
    const details = await getInvoiceForVisit(v.id);
    if (details.error) { setError(details.error); return; }
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function refreshInvoice() {
    const details = await getInvoiceById(invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  function handleDeptChange(e) {
    setDept(e.target.value);
    setSelectedServiceCode('');
    setRate('');
    setGstPct('');
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setSelectedServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  async function handleAddLine() {
    setError('');
    if (!selectedServiceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(invoice.id, selectedServiceCode, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }

    setDept(''); setSelectedServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
    refreshInvoice();
  }

  async function handleRemoveLine(id) {
    await removeLineItem(id);
    refreshInvoice();
  }

  function startOver() {
    setSelectedPatient(null);
    setInvoice(null);
    setLineItems([]);
    setFinalized(false);
  }

  function handleFinalize() {
    setError('');
    if (lineItems.length === 0) { setError('Add at least one line item before finalizing.'); return; }
    setFinalized(true);
  }

  function handleSaveDraft() {
    // Every line item is already saved to the database the moment it's
    // added -- there's no separate "draft" storage to write to. This
    // just confirms that and lets staff step away and resume later from
    // Invoice Details.
    router.push('/billing/details');
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Invoice
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
          <div>
            <label className="flbl">Find patient (name, UHID, or mobile)</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : finalized ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Invoice finalized for {selectedPatient.first_name} {selectedPatient.last_name} -- Net Rs.{invoice.net}.{' '}
            <a href={`/billing/details?q=${selectedPatient.uhid}`} style={{ color: 'var(--blue)' }}>Go collect payment in Invoice Details &rarr;</a>
            <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
              <a href={`/invoice-print/${invoice.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <button className="btn btn-sm" onClick={startOver}>Start a new invoice</button>
            </div>
          </div>
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span><strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong> -- {selectedPatient.uhid}</span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Department *</label>
                <select className="fi" value={dept} onChange={handleDeptChange}>
                  <option value="">-- Select --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Service *</label>
                <select className="fi" value={selectedServiceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">{dept ? '-- Select --' : '-- Select dept first --'}</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
                </select>
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Qty</label>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
              </div>
              <div>
                <label className="flbl">Unit rate (Rs.)</label>
                <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
              </div>
              <div>
                <label className="flbl">GST %</label>
                <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
              <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                <option value="none">No discount</option>
                <option value="pct">Percentage (%)</option>
                <option value="fixed">Fixed (Rs.)</option>
              </select>
              <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
              <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
            </div>

            <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
              <i className="ti ti-plus"></i> Add line item
            </button>

            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Rate</th><th>Disc</th><th>GST</th><th>Net</th><th></th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id}>
                    <td>{li.service_name}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.rate}</td>
                    <td>{li.disc > 0 ? `Rs.${li.disc}` : '--'}</td>
                    <td>Rs.{li.gst_amount}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{li.net}</td>
                    <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(li.id)}>Remove</button></td>
                  </tr>
                ))}
                {lineItems.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet.</td></tr>
                )}
              </tbody>
            </table>

            <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
              <button className="btn btn-green" onClick={handleFinalize}>
                <i className="ti ti-circle-check"></i> Finalize invoice
              </button>
              <button className="btn" onClick={handleSaveDraft}>
                <i className="ti ti-device-floppy"></i> Save draft
              </button>
            </div>
          </div>
        )}
      </div>

      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to auto-fill and continue their invoice.</div>
          {todaysVisits.map((v) => (
            <div
              key={v.id}
              onClick={() => pickVisit(v)}
              style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
            >
              <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
              <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
            </div>
          ))}
          {todaysVisits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
        </div>

        {invoice && (
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> {invoice.invoice_number || 'Invoice Summary'}
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Gross</span><span>Rs.{invoice.gross}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>GST</span><span>Rs.{invoice.gst}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Net Total</span><span>Rs.{invoice.net}</span></div>
              <div style={{ marginTop: 8 }}><span className={`badge ${invoice.status === 'Paid' ? 'b-green' : 'b-amber'}`}>{invoice.status}</span></div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/billing/package/package-billing-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostSurgicalPendingPackages,
  getActivePackages,
  searchPatientsForPackage,
  generatePackageInvoice,
} from '../actions';

export default function PackageBillingTab() {
  const [pending, setPending] = useState([]);
  const [packages, setPackages] = useState([]);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [selectedPackage, setSelectedPackage] = useState(null);
  const [surgicalCaseId, setSurgicalCaseId] = useState(null);

  const [paymentMode, setPaymentMode] = useState('full');
  const [advanceAmount, setAdvanceAmount] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);

  const refresh = useCallback(async () => {
    setPending(await getPostSurgicalPendingPackages());
    setPackages(await getActivePackages());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPackage(searchQuery.trim()));
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSurgicalCaseId(null);
    setSearchResults([]);
    setSearchQuery('');
  }

  function pickPostSurgical(sc) {
    setSelectedPatient(sc.patients);
    setSurgicalCaseId(sc.id);
    if (sc.master_packages) setSelectedPackage(sc.master_packages);
  }

  function reset() {
    setSelectedPatient(null);
    setSelectedPackage(null);
    setSurgicalCaseId(null);
    setPaymentMode('full');
    setAdvanceAmount('');
    setResult(null);
    setError('');
  }

  async function handleGenerate() {
    setError('');
    if (!selectedPatient || !selectedPackage) { setError('Select a patient and a package.'); return; }
    setLoading(true);
    const res = await generatePackageInvoice(
      selectedPatient.id,
      selectedPackage.id,
      paymentMode,
      paymentMode === 'advance' ? parseFloat(advanceAmount) : 0,
      surgicalCaseId
    );
    setLoading(false);
    if (res.error) { setError(res.error); return; }
    setResult(res.invoice);
    refresh();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-scissors" style={{ color: 'var(--blue)' }}></i> Post-surgical Patients -- Package Pending
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
          Surgery is complete but the package invoice hasn&apos;t been generated yet.
        </div>
        {pending.map((sc) => (
          <div
            key={sc.id}
            onClick={() => pickPostSurgical(sc)}
            style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13, display: 'flex', justifyContent: 'space-between' }}
          >
            <span><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong> -- {sc.patients?.uhid} -- {sc.procedure_name}</span>
            <span style={{ color: 'var(--g500)' }}>{sc.master_packages?.name || 'No package selected'}</span>
          </div>
        ))}
        {pending.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending.</div>}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-package" style={{ color: 'var(--blue)' }}></i> Package Billing
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Surgery package invoices are generated after counselling. Full payment or advance is collected before surgery scheduling.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {result ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Package invoice generated -- Net Rs.{result.net}, Paid Rs.{result.paid}, Status: {result.status}.
            <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
              <a href={`/invoice-print/${result.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <button className="btn btn-sm" onClick={reset}>Bill another package</button>
            </div>
          </div>
        ) : (
          <>
            {!selectedPatient ? (
              <div>
                <label className="flbl">Patient / Visit</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type patient name or UHID..." />
                  <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
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
              </div>
            ) : (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
                  <div>
                    <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>{selectedPatient.uhid}</div>
                  </div>
                  <button className="btn btn-sm" onClick={reset}>Change</button>
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
                  {packages.map((pkg) => (
                    <div
                      key={pkg.id}
                      onClick={() => setSelectedPackage(pkg)}
                      style={{
                        border: selectedPackage?.id === pkg.id ? '2px solid var(--blue)' : '1px solid var(--g200)',
                        borderRadius: 8, padding: 12, cursor: 'pointer',
                        background: selectedPackage?.id === pkg.id ? 'var(--blue-lt)' : '#fff',
                      }}
                    >
                      <div style={{ fontWeight: 700, fontSize: 13 }}>{pkg.name}</div>
                      <div style={{ fontSize: 12, color: 'var(--g500)' }}>Rs.{pkg.price}</div>
                      {pkg.includes && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>{pkg.includes}</div>}
                    </div>
                  ))}
                </div>

                {selectedPackage && (
                  <div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 14 }}>
                      <div>
                        <label className="flbl">Payment mode</label>
                        <select className="fi" value={paymentMode} onChange={(e) => setPaymentMode(e.target.value)}>
                          <option value="full">Full payment</option>
                          <option value="advance">Advance payment</option>
                        </select>
                      </div>
                      {paymentMode === 'advance' && (
                        <div>
                          <label className="flbl">Advance amount (Rs.)</label>
                          <input type="number" className="fi" value={advanceAmount} onChange={(e) => setAdvanceAmount(e.target.value)} placeholder={`Up to Rs.${selectedPackage.price}`} />
                        </div>
                      )}
                    </div>
                    <button className="btn btn-green" onClick={handleGenerate} disabled={loading}>
                      <i className="ti ti-receipt"></i> {loading ? 'Generating...' : 'Generate package invoice'}
                    </button>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

EOF

echo "Print/PDF invoice view built, linked from all 4 billing screens."
