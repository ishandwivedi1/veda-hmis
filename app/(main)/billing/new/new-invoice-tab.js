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
            <div style={{ marginTop: 10 }}>
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
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Invoice Summary
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

