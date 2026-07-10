'use client';

import { useState } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [receipt, setReceipt] = useState(null);

  const totalSelectedOutstanding = invoices
    .filter((inv) => selectedInvoiceIds.includes(inv.id))
    .reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const invs = await getOutstandingInvoices(p.id);
    setInvoices(invs);
    setSelectedInvoiceIds(invs.map((i) => i.id)); // pre-select all, matching "select invoice(s) to pay"
  }

  function toggleInvoice(id) {
    setSelectedInvoiceIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }

  function useFullOutstanding() {
    setAmount(totalSelectedOutstanding.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: totalSelectedOutstanding.toFixed(2) }]);
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }

  function addModeRow() {
    setModeRows((rows) => [...rows, { mode: 'Cash', amount: '' }]);
  }

  function removeModeRow(idx) {
    setModeRows((rows) => rows.filter((_, i) => i !== idx));
  }

  function reset() {
    setSelectedPatient(null);
    setInvoices([]);
    setSelectedInvoiceIds([]);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setReceipt(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice to pay.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount collecting.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount collecting (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectPayment(selectedPatient.id, selectedInvoiceIds, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setReceipt(result.payment);
  }

  if (receipt) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Payment collected -- Receipt <strong>{receipt.receipt_number}</strong> -- Rs.{receipt.total_amount}
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {selectedPatient.first_name} {selectedPatient.last_name} -- {selectedPatient.uhid}</div>
          <div><strong>Amount:</strong> Rs.{receipt.total_amount}</div>
          {receipt.reference && <div><strong>Reference:</strong> {receipt.reference}</div>}
        </div>
        <button className="btn btn-primary" style={{ marginTop: 16 }} onClick={reset}>Collect another payment</button>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-cash" style={{ color: 'var(--green)' }}></i> Collect Payment
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
          <div>
            <label className="flbl">Patient (name, UHID, or mobile) *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
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
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--green-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div>
                <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
              </div>
              <button className="btn btn-sm" onClick={reset}>Change</button>
            </div>

            <label className="flbl">Select invoice(s) to pay *</label>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>No outstanding invoices for this patient.</div>}
            <div style={{ marginBottom: 14 }}>
              {invoices.map((inv) => (
                <label key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px', borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer' }}>
                  <span>
                    <input type="checkbox" checked={selectedInvoiceIds.includes(inv.id)} onChange={() => toggleInvoice(inv.id)} style={{ marginRight: 8 }} />
                    {inv.invoice_number} -- <span className={`badge ${inv.status === 'Partial' ? 'b-amber' : 'b-red'}`}>{inv.status}</span>
                  </span>
                  <span style={{ fontWeight: 600 }}>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </label>
              ))}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Amount collecting (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Total selected outstanding</label>
                <input className="fi" value={`Rs.${totalSelectedOutstanding.toFixed(2)}`} readOnly style={{ background: 'var(--g50)', fontWeight: 700, color: 'var(--red)' }} />
              </div>
            </div>
            <button className="btn btn-sm" onClick={useFullOutstanding} style={{ marginBottom: 14 }}>Use full outstanding amount</button>

            <label className="flbl">Payment mode(s) * -- split across multiple if needed</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input type="number" className="fi" value={row.amount} onChange={(e) => updateModeRow(idx, 'amount', e.target.value)} placeholder="Amount" style={{ flex: 1 }} />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect payment'}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Payment Summary
          </div>
          {!selectedPatient ? (
            <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 13 }}>Select patient and invoice</div>
          ) : (
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices selected</span><span>{selectedInvoiceIds.length}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total outstanding</span><span>Rs.{totalSelectedOutstanding.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Amount collecting</span><span>Rs.{(parseFloat(amount) || 0).toFixed(2)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

