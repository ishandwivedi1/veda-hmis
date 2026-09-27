'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useSearchParams } from 'next/navigation';
import {
  searchInvoices, getInvoiceById, cancelInvoice,
  getTodaysInvoicesForModification, getInvoicesForVisit, getSurgeryBillingOptions, setManualSurgeryDetails,
} from '../actions';
import { openPrintPopup } from '@/lib/printPopup';
import InvoiceEditPanel from '../invoice-edit-panel';
import InvoiceHistory from '../invoice-history';

// Items are changed through the shared Edit Invoice panel (edit_invoice() in
// Postgres): anything can be added, changed or removed, subject to Billing
// Permissions and closed days, and every change is kept in the history.
// The old "original items are locked" rules were retired on 27 Sep 2026.

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [visitInvoices, setVisitInvoices] = useState(null);
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const visitLoadedFor = useRef(null);
  const [historyKey, setHistoryKey] = useState(0);

  // Surgery Billing Details -- same fields as New Invoice, editable here
  // too since a surgery invoice's surgeon/eye can need correction after
  // the fact. Saved independently via its own "Save" button rather than
  // a single commit step, since Modification has no one save-everything
  // action the way New Invoice does.
  const [surgeryName, setSurgeryName] = useState('');
  const [surgeryEyeField, setSurgeryEyeField] = useState('');
  const [surgeryDoctorId, setSurgeryDoctorId] = useState('');
  const [surgeryOptions, setSurgeryOptions] = useState([]);
  const [surgeryDoctorOptions, setSurgeryDoctorOptions] = useState([]);
  const [savingSurgery, setSavingSurgery] = useState(false);

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

  useEffect(() => {
    loadToday();
    getSurgeryBillingOptions().then(({ surgeries, doctors }) => { setSurgeryOptions(surgeries); setSurgeryDoctorOptions(doctors); });
  }, [loadToday]);

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

  const hasSurgeryLine = lineItems.some((li) => li.dept === 'Surgery');

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setVisitInvoices(null);
    try {
      setResults(await searchInvoices(searchQuery.trim()));
    } catch (e) {
      setResults([]);
    }
    setSearched(true);
  }

  async function openInvoice(inv) {
    setError(''); setInfo(''); setConfirmedMessage('');
    try {
      const details = await getInvoiceById(inv.id);
      if (details.error) { setError(details.error); return; }
      setSelected(details.invoice);
      setLineItems(details.lineItems);
      setSurgeryName(details.invoice.manual_surgery_name || '');
      setSurgeryEyeField(details.invoice.manual_surgery_eye || '');
      setSurgeryDoctorId(details.invoice.manual_surgeon_id || '');
      setShowCancelForm(false);
      setCancelReason('');
    } catch (e) {
      setError('Could not load this invoice -- check your connection and try again.');
    }
  }

  async function refresh() {
    try {
      const details = await getInvoiceById(selected.id);
      setSelected(details.invoice);
      setLineItems(details.lineItems);
    } catch (e) {
      setError('Could not refresh this invoice -- check your connection and try again.');
    }
  }

  async function handleSaveSurgeryDetails() {
    setError(''); setInfo('');
    setSavingSurgery(true);
    try {
      const result = await setManualSurgeryDetails(selected.id, surgeryName, surgeryEyeField, surgeryDoctorId);
      if (result.error) { setError(result.error); return; }
      setInfo('Surgery billing details saved.');
      refresh();
    } catch (e) {
      setError('Something went wrong saving surgery details -- check your connection and try again.');
    } finally {
      setSavingSurgery(false);
    }
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
    try {
      const result = await cancelInvoice(selected.id, cancelReason);
      if (result.error) { setError(result.error); return; }
      setInfo('Invoice cancelled and logged for audit.');
      setShowCancelForm(false);
      setCancelReason('');
      refresh();
      loadToday();
    } catch (e) {
      setError('Something went wrong cancelling this invoice -- check your connection and try again.');
    }
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
                  <strong>{formatPatientName(inv.patients)}</strong>
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
                  <strong>{formatPatientName(inv.patients)}</strong>
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

          {/* Patient + visit context -- locked, exactly as filled in on
              New Invoice. No "Change / New" here on purpose: switching
              patient or visit isn't a modification, it's a different
              invoice -- use Find Invoice on the left for that. */}
          <div style={{ background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16, fontSize: 13 }}>
            <div>
              <i className="ti ti-lock" style={{ color: 'var(--g400)', fontSize: 12 }}></i>{' '}
              <strong>{formatPatientName(selected.patients)}</strong> -- {selected.patients?.uhid}
            </div>
            {selected.visits && (
              <div style={{ fontSize: 11.5, color: 'var(--g600)', marginTop: 2 }}>
                Visit: {selected.visits.visit_number || '--'} -- {selected.visits.visit_type} -- {new Date(selected.visits.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
              </div>
            )}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          {selected.status === 'Cancelled' ? (
            <table className="tbl">
              <thead><tr><th>Dept</th><th>Service</th><th>Qty</th><th>Rate</th><th>Disc</th><th>Net</th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id} style={{ color: 'var(--g600)' }}>
                    <td style={{ fontSize: 11 }}>{li.dept}</td>
                    <td>{li.service_name}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.rate}</td>
                    <td>{li.disc > 0 ? `Rs.${li.disc}` : '--'}</td>
                    <td>Rs.{li.net}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          ) : (
            <InvoiceEditPanel
              key={selected.id}
              embedded
              invoiceId={selected.id}
              onSaved={(_, credited) => {
                setInfo(credited > 0
                  ? `Invoice updated. Rs.${credited} already paid is now kept as patient credit.`
                  : 'Invoice updated and logged.');
                setHistoryKey((k) => k + 1);
                refresh();
                loadToday();
              }}
            />
          )}

          {hasSurgeryLine && (
            <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', margin: '16px 0 8px' }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                <i className="ti ti-scalpel"></i> Surgery Billing Details
                <span style={{ fontWeight: 400, color: 'var(--g400)', marginLeft: 6 }}>(editable -- prints on the Surgery Bill)</span>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8 }}>
                <div>
                  <label className="flbl">Surgery</label>
                  <select className="fi fi-sm" value={surgeryName} onChange={(e) => setSurgeryName(e.target.value)}>
                    <option value="">-- Select surgery --</option>
                    {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                  </select>
                </div>
                <div>
                  <label className="flbl">Operated Eye</label>
                  <select className="fi fi-sm" value={surgeryEyeField} onChange={(e) => setSurgeryEyeField(e.target.value)}>
                    <option value="">-- Select --</option>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                </div>
                <div>
                  <label className="flbl">Doctor</label>
                  <select className="fi fi-sm" value={surgeryDoctorId} onChange={(e) => setSurgeryDoctorId(e.target.value)}>
                    <option value="">-- Select doctor --</option>
                    {surgeryDoctorOptions.map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
                  </select>
                </div>
              </div>
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSaveSurgeryDetails} disabled={savingSurgery}>
                <i className="ti ti-device-floppy"></i> {savingSurgery ? 'Saving...' : 'Save Surgery Details'}
              </button>
            </div>
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
          <InvoiceHistory invoiceId={selected.id} refreshKey={historyKey} />
        </div>
      )}
    </div>
  );
}
