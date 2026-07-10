'use client';

import { useState, useEffect } from 'react';
import {
  searchPatientsForInvoice,
  createStandaloneInvoice,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  removeLineItem,
} from '../actions';

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoice, setInvoice] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);

  const [selectedService, setSelectedService] = useState('');
  const [qty, setQty] = useState(1);
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
  }, []);

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

  async function refreshInvoice() {
    const details = await getInvoiceById(invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function handleAddLine() {
    setError('');
    if (!selectedService) { setError('Select a service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(invoice.id, selectedService, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }

    setSelectedService(''); setQty(1); setDiscType('none'); setDiscValue(''); setDiscReason('');
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
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span><strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong> -- {selectedPatient.uhid}</span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi" value={selectedService} onChange={(e) => setSelectedService(e.target.value)}>
                <option value="">-- Select service --</option>
                {catalog.map((s) => (
                  <option key={s.code} value={s.code}>{s.dept} -- {s.name} -- Rs.{s.rate} ({s.gst_pct}% GST)</option>
                ))}
              </select>
              <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} placeholder="Qty" />
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
          </div>
        )}
      </div>

      <div>
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

