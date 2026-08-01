'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, getServiceCatalog, addLineItem, removeLineItem, cancelInvoice, getTodaysInvoicesForModification, getInvoicesForVisit } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [originalLineItemIds, setOriginalLineItemIds] = useState(new Set());
  const [catalog, setCatalog] = useState([]);
  const [visitInvoices, setVisitInvoices] = useState(null);
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const visitLoadedFor = useRef(null);

  const [dept, setDept] = useState('');
  const [serviceCode, setServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [removeReasonFor, setRemoveReasonFor] = useState(null);
  const [removeReason, setRemoveReason] = useState('');

  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [todaysInvoices, setTodaysInvoices] = useState([]);
  const [searched, setSearched] = useState(false);
  const [confirmedMessage, setConfirmedMessage] = useState('');

  const loadToday = useCallback(async () => {
    setTodaysInvoices(await getTodaysInvoicesForModification());
  }, []);

  useEffect(() => { getServiceCatalog().then(setCatalog); loadToday(); }, [loadToday]);

  // Arrived via "Modify" from Front Office Dashboard or New Invoice --
  // jump straight to this visit's invoice(s) instead of a generic
  // search. If there's exactly one, open it directly; if more than
  // one, show them as a pre-filtered pick list.
  useEffect(() => {
    if (!urlVisitId) return;
    if (visitLoadedFor.current === urlVisitId) return;
    visitLoadedFor.current = urlVisitId;
    (async () => {
      const result = await getInvoicesForVisit(urlVisitId);
      const invoices = result.invoices || [];
      if (invoices.length === 1) {
        openInvoice(invoices[0]);
      } else {
        setVisitInvoices(invoices);
      }
    })();
  }, [urlVisitId]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setVisitInvoices(null);
    setResults(await searchInvoices(searchQuery.trim()));
    setSearched(true);
  }

  async function openInvoice(inv) {
    setError(''); setInfo(''); setConfirmedMessage('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
    // Snapshot which line items already existed when this modification
    // session started -- these are locked (part of the original bill).
    // Anything added from here on stays removable until the invoice is
    // reopened fresh, at which point it becomes part of the locked set.
    setOriginalLineItemIds(new Set((details.lineItems || []).map((li) => li.id)));
    setShowCancelForm(false);
    setCancelReason('');
  }

  async function refresh() {
    const details = await getInvoiceById(selected.id);
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  async function handleAddLine() {
    setError('');
    if (!serviceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(selected.id, serviceCode, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }
    setDept(''); setServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
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

  function handleConfirmModification() {
    setConfirmedMessage(`Modification confirmed for ${selected.invoice_number} -- Net Total: Rs.${selected.net}.`);
    setSelected(null);
    setLineItems([]);
    loadToday();
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
    loadToday();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.3fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Find Invoice
        </div>
        {confirmedMessage && (
          <div className="msg-success"><i className="ti ti-circle-check"></i> {confirmedMessage}</div>
        )}
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={searchQuery} onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }} placeholder="Patient name or UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
        </div>

        {visitInvoices ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6 }}>
              Invoices for this visit
            </div>
            {visitInvoices.map((inv) => (
              <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.purpose}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {visitInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices found for this visit.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setVisitInvoices(null)}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : searched ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>
              Search Results
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
            {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No matches found.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => { setSearched(false); setSearchQuery(''); }}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
              <i className="ti ti-calendar-event"></i> Today&apos;s Invoices
              <span className="badge b-blue">{todaysInvoices.length}</span>
            </div>
            {todaysInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => openInvoice(inv)}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12, background: 'var(--blue-lt)', borderRadius: 4, marginBottom: 4 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g600)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {todaysInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices generated today yet.</div>}
          </>
        )}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.invoice_number}</div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <button onClick={() => openPrintPopup(`/invoice-print/${selected.id}`)} className="btn btn-sm">
                <i className="ti ti-printer"></i> Print / PDF
              </button>
              <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
            </div>
          </div>
          <div style={{ fontSize: 13, marginBottom: 12 }}>
            <i className="ti ti-lock" style={{ color: 'var(--g400)', fontSize: 12 }}></i>{' '}
            <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          <table className="tbl">
            <thead><tr><th>Service</th><th>Qty</th><th>Net</th><th></th></tr></thead>
            <tbody>
              {lineItems.map((li) => {
                const isLocked = originalLineItemIds.has(li.id);
                return (
                  <tr key={li.id} style={isLocked ? { color: 'var(--g600)' } : undefined}>
                    <td>{li.service_name}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.net}</td>
                    <td>
                      {isLocked ? (
                        <span style={{ fontSize: 11, color: 'var(--g400)' }} title="Part of the original bill -- cannot be removed">
                          <i className="ti ti-lock"></i> Locked
                        </span>
                      ) : selected.status !== 'Cancelled' ? (
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => { setRemoveReasonFor(li.id); setRemoveReason(''); setError(''); }}>
                          Remove
                        </button>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>
            <i className="ti ti-info-circle"></i> Original line items are locked once an invoice is opened for modification -- add new items below instead of editing what was already billed.
          </div>

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
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <select className="fi" value={dept} onChange={(e) => { setDept(e.target.value); setServiceCode(''); setRate(''); setGstPct(''); }}>
                  <option value="">-- Dept --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
                <select className="fi" value={serviceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">-- Service --</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
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

            {selected.status !== 'Cancelled' && !showCancelForm && (
              <button className="btn btn-green" style={{ marginTop: 12 }} onClick={handleConfirmModification}>
                <i className="ti ti-circle-check"></i> Confirm Modification &amp; Close
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}


