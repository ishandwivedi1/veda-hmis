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

