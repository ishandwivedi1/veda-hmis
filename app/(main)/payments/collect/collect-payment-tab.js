'use client';

import { useState, useEffect, useRef } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useSearchParams, useRouter } from 'next/navigation';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment, getAdvanceBalance, getPatientById, getAllUnpaidInvoices, applyAdjustment } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const STATUS_BADGE = { Partial: 'b-amber', Pending: 'b-red' };

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [highlightInvoiceId, setHighlightInvoiceId] = useState(null);
  const [unpaidInvoices, setUnpaidInvoices] = useState([]);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [applyingAdvance, setApplyingAdvance] = useState(false);
  const [receipt, setReceipt] = useState(null);
  const [overpaidAmount, setOverpaidAmount] = useState(0);
  // Set when Apply Advance alone fully covers every selected invoice --
  // applyAdjustment() is a ledger transfer, not a payment collection,
  // so it never produces a `receipt`. Without this, the form was just
  // left sitting at "0.00 to collect" with no sign anything happened,
  // even though the invoice was already Paid server-side.
  const [advancePaidInvoices, setAdvancePaidInvoices] = useState(null);
  const searchParams = useSearchParams();
  const router = useRouter();
  const urlPatientId = searchParams.get('patientId');
  const urlInvoiceId = searchParams.get('invoiceId');
  const isPopup = searchParams.get('popup') === '1';
  const returnTo = searchParams.get('returnTo');
  const autofillDoneFor = useRef(null);

  useEffect(() => {
    getAllUnpaidInvoices().then(setUnpaidInvoices);
  }, []);

  // Arrived from "Finalize invoice" -- auto-load the patient and their
  // outstanding invoices (including the one just billed) instead of
  // requiring a manual search.
  useEffect(() => {
    if (!urlPatientId) return;
    if (autofillDoneFor.current === urlPatientId) return;
    autofillDoneFor.current = urlPatientId;
    (async () => {
      const result = await getPatientById(urlPatientId);
      if (result.error) { setError(result.error); return; }
      if (urlInvoiceId) setHighlightInvoiceId(urlInvoiceId);
      await pickPatient(result.patient);
    })();
  }, [urlPatientId, urlInvoiceId]);

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

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

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

  // The day-of-surgery flow: patient already paid an advance at booking;
  // today the full remaining balance is collected upfront. This applies
  // the advance against the selected invoice(s) first (a real ledger
  // adjustment, not just arithmetic on screen -- the advance balance
  // actually goes down), then auto-fills the correct remaining amount
  // to collect, so nobody has to subtract by hand or remember to visit
  // the separate Adjustments tab.
  async function handleApplyAdvanceAndCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice.'); return; }
    if (advanceBalance <= 0) { setError('No advance balance available for this patient.'); return; }

    setApplyingAdvance(true);
    let remaining = advanceBalance;
    for (const invId of selectedInvoiceIds) {
      if (remaining <= 0) break;
      const inv = invoices.find((i) => i.id === invId);
      if (!inv) continue;
      const outstanding = Number(inv.net) - Number(inv.paid);
      if (outstanding <= 0.01) continue;
      const toApply = Math.min(remaining, outstanding);
      const result = await applyAdjustment(selectedPatient.id, invId, toApply);
      if (result.error) { setApplyingAdvance(false); setError(result.error); return; }
      remaining -= toApply;
    }

    const [refreshedInvoices, refreshedAdvance] = await Promise.all([
      getOutstandingInvoices(selectedPatient.id),
      getAdvanceBalance(selectedPatient.id),
    ]);
    setInvoices(refreshedInvoices);
    setAdvanceBalance(refreshedAdvance);
    const stillOutstandingIds = refreshedInvoices.filter((i) => selectedInvoiceIds.includes(i.id)).map((i) => i.id);

    // Advance alone covered every selected invoice -- there's nothing
    // left to collect, so this IS the end of the flow. Show a clear
    // confirmation instead of leaving the form at "0.00 to collect"
    // with the Finalize Payment button still sitting there.
    if (stillOutstandingIds.length === 0) {
      setAdvancePaidInvoices(invoices.filter((i) => selectedInvoiceIds.includes(i.id)).map((i) => i.invoice_number));
      setSelectedInvoiceIds([]);
      setApplyingAdvance(false);
      return;
    }

    setSelectedInvoiceIds(stillOutstandingIds);
    const newTotal = refreshedInvoices
      .filter((i) => stillOutstandingIds.includes(i.id))
      .reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
    setAmount(newTotal.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: newTotal.toFixed(2) }]);
    setApplyingAdvance(false);
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
    setOverpaidAmount(0);
    setAdvancePaidInvoices(null);
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
    // Anything collected beyond the selected invoices' outstanding
    // total was automatically credited to advance -- surface that so
    // it's not a silent surprise.
    const overpaid = amt - totalSelectedOutstanding;
    setOverpaidAmount(overpaid > 0.01 ? overpaid : 0);
    setReceipt(result.payment);
  }

  // Collecting from a specific invoice means this was reached via a
  // link from elsewhere (Billing Dashboard, or another module's own
  // billing flow like Pharmacy) -- once paid, the natural next step is
  // back there rather than sitting on this form. A short delay keeps
  // the receipt confirmation visible instead of yanking it away.
  //
  // Opened as a popup (from Pharmacy's own bill-and-pay flow): just
  // close the tab so the person lands back on the page they were
  // already on, instead of navigating that popup somewhere new.
  useEffect(() => {
    if ((!receipt && !advancePaidInvoices) || !urlInvoiceId) return;
    const timer = setTimeout(() => {
      if (isPopup) { window.close(); return; }
      router.push(returnTo || '/billing');
    }, 2500);
    return () => clearTimeout(timer);
  }, [receipt, advancePaidInvoices, urlInvoiceId, router, isPopup, returnTo]);

  if (advancePaidInvoices) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-piggy-bank"></i> Covered entirely by advance -- {advancePaidInvoices.join(', ')} {advancePaidInvoices.length > 1 ? 'are' : 'is'} now Paid. Nothing more to collect.
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {formatPatientName(selectedPatient)} -- {selectedPatient.uhid}</div>
          <div><strong>Remaining advance balance:</strong> Rs.{advanceBalance}</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          {urlInvoiceId ? (
            <>
              <button className="btn btn-primary" onClick={() => router.push('/billing')}>
                <i className="ti ti-arrow-left"></i> Back to Billing Dashboard
              </button>
              <span style={{ fontSize: 11, color: 'var(--g400)', alignSelf: 'center' }}>Returning automatically...</span>
            </>
          ) : (
            <button className="btn btn-primary" onClick={reset}>Collect another payment</button>
          )}
        </div>
      </div>
    );
  }

  if (receipt) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Payment collected -- Receipt <strong>{receipt.receipt_number}</strong> -- Rs.{receipt.total_amount}
        </div>
        {overpaidAmount > 0 && (
          <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-piggy-bank"></i> Rs.{overpaidAmount.toFixed(2)} was more than the selected invoices' balance -- credited to this patient's advance for future use.
          </div>
        )}
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {formatPatientName(selectedPatient)} -- {selectedPatient.uhid}</div>
          <div><strong>Amount:</strong> Rs.{receipt.total_amount}</div>
          {receipt.reference && <div><strong>Reference:</strong> {receipt.reference}</div>}
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
          {urlInvoiceId ? (
            <>
              <button className="btn btn-primary" onClick={() => router.push('/billing')}>
                <i className="ti ti-arrow-left"></i> Back to Billing Dashboard
              </button>
              <span style={{ fontSize: 11, color: 'var(--g400)', alignSelf: 'center' }}>Returning automatically...</span>
            </>
          ) : (
            <button className="btn btn-primary" onClick={reset}>Collect another payment</button>
          )}
        </div>
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
                    <strong>{formatPatientName(p)}</strong> -- {p.uhid}
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
                  <div style={{ fontWeight: 700 }}>{formatPatientName(selectedPatient)}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={reset}>Change</button>
              </div>
              <div style={{ fontSize: 11, marginTop: 5 }}>
                <span style={{ color: 'var(--purple)', fontWeight: 600 }}>Advance balance: </span>
                <span style={{ fontWeight: 700, color: 'var(--purple)' }}>Rs.{advanceBalance}</span>
                {advanceBalance > 0 && <span style={{ color: 'var(--g500)', marginLeft: 4 }}>-- use the purple button below to apply it</span>}
              </div>
            </div>

            <label className="flbl">Select invoice(s) to pay *</label>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>No outstanding invoices for this patient.</div>}
            <div style={{ marginBottom: 14 }}>
              {invoices.map((inv) => (
                <label
                  key={inv.id}
                  style={{
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px',
                    borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer',
                    background: inv.id === highlightInvoiceId ? 'var(--green-lt)' : 'transparent', borderRadius: 4,
                  }}
                >
                  <span>
                    <input type="checkbox" checked={selectedInvoiceIds.includes(inv.id)} onChange={() => toggleInvoice(inv.id)} style={{ marginRight: 8 }} />
                    {inv.invoice_number} -- <span className={`badge ${inv.status === 'Partial' ? 'b-amber' : 'b-red'}`}>{inv.status}</span>
                    {inv.id === highlightInvoiceId && <span className="badge b-green" style={{ marginLeft: 6 }}>Just billed</span>}
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
            <div style={{ display: 'flex', gap: 8, marginBottom: 14, flexWrap: 'wrap' }}>
              <button className="btn btn-sm" onClick={useFullOutstanding}>Use full outstanding amount</button>
              {advanceBalance > 0 && (
                <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleApplyAdvanceAndCollect} disabled={applyingAdvance}>
                  <i className="ti ti-piggy-bank"></i> {applyingAdvance ? 'Applying advance...' : 'Apply Advance & Auto-fill Remaining'}
                </button>
              )}
            </div>

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
              <i className="ti ti-circle-check"></i> {loading ? 'Finalizing...' : 'Finalize Payment'}
            </button>
          </div>
        )}
      </div>

      <div>
        {!urlPatientId && (
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Unpaid Invoices
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click one to start collecting for that patient.</div>
            {unpaidInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => { setHighlightInvoiceId(inv.id); pickPatient(inv.patients); }}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{formatPatientName(inv.patients)}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{inv.invoice_number}</span>
                  <span>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </div>
              </div>
            ))}
            {unpaidInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding right now.</div>}
          </div>
        )}

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



