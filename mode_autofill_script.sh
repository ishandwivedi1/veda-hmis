mkdir -p 'app/(main)/payments/collect' 'app/(main)/payments/advance'

cat > 'app/(main)/payments/collect/collect-payment-tab.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment, getAdvanceBalance } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [receipt, setReceipt] = useState(null);

  // In the common case (single payment mode), the mode's amount should
  // always match the amount collecting -- no need to type the same
  // number twice. Only once a second mode is added (a real split) does
  // each row need its own independently-entered amount.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);

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
    setAdvanceBalance(await getAdvanceBalance(p.id));
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
    setModeRows((rows) => {
      // Moving from single-mode (auto-filled) to a real split -- clear
      // amounts so staff explicitly enters how much goes to each mode,
      // rather than leaving a stale auto-filled value on the first row.
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }

  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      // Back to a single mode -- re-sync it to the amount collecting.
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
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
            <div style={{ background: 'var(--green-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 11, marginTop: 5 }}>
                <span style={{ color: 'var(--purple)', fontWeight: 600 }}>Advance balance: </span>
                <span style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{advanceBalance}</span>
              </div>
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
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
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

EOF

cat > 'app/(main)/payments/advance/advance-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { searchPatientsForPayment, getAdvanceBalance, collectAdvance, getCurrentBalancesByPatient, getLedgerHistory } from '../actions';

const ADVANCE_TYPES = ['Surgery Advance', 'General Advance', 'Package Advance', 'Other'];
const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function AdvanceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [currentBalance, setCurrentBalance] = useState(0);

  const [advanceType, setAdvanceType] = useState('Surgery Advance');
  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);

  // Same simplification as Collect Payment: in the common single-mode
  // case, the mode amount always matches the amount field -- no need to
  // type the same number twice.
  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount }] : rows));
  }, [amount]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [success, setSuccess] = useState(null);

  const [balances, setBalances] = useState([]);
  const [history, setHistory] = useState([]);

  const refreshSidebar = useCallback(async () => {
    setBalances(await getCurrentBalancesByPatient());
    setHistory(await getLedgerHistory());
  }, []);

  useEffect(() => { refreshSidebar(); }, [refreshSidebar]);

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
    setCurrentBalance(await getAdvanceBalance(p.id));
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      return [...cleared, { mode: 'Card', amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const remaining = rows.filter((_, i) => i !== idx);
      return remaining.length === 1 ? [{ ...remaining[0], amount }] : remaining;
    });
  }

  function reset() {
    setSelectedPatient(null);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setSuccess(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectAdvance(selectedPatient.id, advanceType, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(result.payment);
    refreshSidebar();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance Collection
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Advance collected without invoice. Balance held in Patient Ledger and adjusted against future invoices.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {success ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Advance collected -- Receipt <strong>{success.receipt_number}</strong> -- Rs.{success.total_amount}
            <div style={{ marginTop: 10 }}>
              <button className="btn btn-sm" onClick={reset}>Collect another advance</button>
            </div>
          </div>
        ) : !selectedPatient ? (
          <div>
            <label className="flbl">Patient *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
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
            <div style={{ background: 'var(--purple-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <div>
                  <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 12, marginTop: 6 }}>Current advance: <strong style={{ color: 'var(--purple)' }}>Rs.{currentBalance}</strong></div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Advance type</label>
                <select className="fi" value={advanceType} onChange={(e) => setAdvanceType(e.target.value)}>
                  {ADVANCE_TYPES.map((t) => <option key={t}>{t}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
            </div>

            <label className="flbl">Payment mode(s) *</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input
                  type="number"
                  className="fi"
                  value={row.amount}
                  onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                  placeholder={modeRows.length === 1 ? 'Auto-filled from amount above' : 'Amount'}
                  readOnly={modeRows.length === 1}
                  style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g50)' : '#fff' }}
                />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="e.g. Surgery scheduled 30 Jun..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect advance'}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Current Balance by Patient
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Balance</th></tr></thead>
            <tbody>
              {balances.map((b, i) => (
                <tr key={i}><td>{b.patient?.first_name} {b.patient?.last_name}</td><td style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{b.balance.toFixed(2)}</td></tr>
              ))}
              {balances.length === 0 && <tr><td colSpan={2} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No advances held.</td></tr>}
            </tbody>
          </table>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Transaction History
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Immutable record -- entries are never edited, only added to.
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Type</th><th>Amount</th></tr></thead>
            <tbody>
              {history.map((h) => (
                <tr key={h.id}>
                  <td>{h.patients?.first_name} {h.patients?.last_name}</td>
                  <td><span className={`badge ${h.entry_type === 'Advance Collected' ? 'b-green' : 'b-amber'}`}>{h.entry_type}</span></td>
                  <td style={{ fontWeight: 600 }}>Rs.{Math.abs(h.amount).toFixed(2)}</td>
                </tr>
              ))}
              {history.length === 0 && <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No transactions yet.</td></tr>}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Single-mode amount auto-fill added to Collect Payment and Advance."
