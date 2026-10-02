'use client';

// Optical "+ New Payment" -- same flow as hospital Record Payment:
// customer -> their unpaid bills (tick one, or none = advance) -> amount,
// mode(s), reference, remarks -> Save. Picking a customer is ONE request
// (bills + unused advance together); Save is ONE request that also opens
// the new receipt (server-side redirect).

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchOpticalCustomers } from '@/lib/rpc-reads/optical__actions'; // parallel reads (tools/parallel-reads)
import { getOpticalNewPaymentContext } from '@/lib/rpc-reads/optical__screens-actions'; // parallel reads (tools/parallel-reads)
import { saveOpticalNewPayment } from '../../screens-actions';
import { ModeRows, r2, money, dateIST } from '../../optical-ui';

const STATUS_BADGE = { Partial: 'b-amber', Pending: 'b-red' };
const STATUS_LABEL = { Partial: 'PARTIALLY PAID', Pending: 'UNPAID' };

export default function NewOpticalPayment({ unpaid = [] }) {
  const searchParams = useSearchParams();
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);
  const [customer, setCustomer] = useState(null);
  const [bills, setBills] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [loadingCtx, setLoadingCtx] = useState(false);
  const [saleId, setSaleId] = useState(null);
  const [amount, setAmount] = useState('');
  const [modes, setModes] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    const term = q.trim();
    if (term.length < 2) { setResults([]); return undefined; }
    const t = setTimeout(async () => setResults(await searchOpticalCustomers(term)), 300);
    return () => clearTimeout(t);
  }, [q]);

  // ONE request: this customer's unpaid bills + unused advance.
  async function pickCustomer(c, preferSaleId = null) {
    setCustomer(c); setResults([]); setQ(''); setError('');
    setBills([]); setAdvanceBalance(0); setSaleId(null); setAmount(''); setModes([{ mode: 'Cash', amount: '' }]);
    setLoadingCtx(true);
    try {
      const ctx = await getOpticalNewPaymentContext(c);
      const list = ctx?.bills || [];
      setBills(list);
      setAdvanceBalance(Number(ctx?.advanceBalance) || 0);
      const pre = list.find((b) => b.id === preferSaleId) || list[0] || null;
      if (pre) choose(pre.id, list);
    } catch {
      setError('Could not load this customer -- check your connection and try again.');
    } finally {
      setLoadingCtx(false);
    }
  }

  // ?saleId= (from a bill): start with that bill's customer.
  useEffect(() => {
    const id = searchParams.get('saleId');
    const b = id && unpaid.find((x) => x.id === id);
    if (b) pickCustomer(b.customer, b.id);
  }, []); // eslint-disable-line react-hooks/exhaustive-deps

  function choose(id, list = bills) {
    setSaleId(id);
    const b = list.find((x) => x.id === id);
    const due = b ? String(r2(b.due)) : '';
    setAmount(due);
    setModes([{ mode: 'Cash', amount: due }]);
  }

  const bill = bills.find((b) => b.id === saleId) || null;
  const amt = r2(amount);
  const toBill = bill ? r2(Math.min(amt, Number(bill.due))) : 0;
  const toAdvance = r2(amt - toBill);
  const isAdvanceOnly = !bill;

  async function save() {
    if (saving) return;
    setError('');
    if (!customer) { setError('Select a customer.'); return; }
    if (!(amt > 0)) { setError('Enter the amount received.'); return; }
    const sum = r2(modes.reduce((t, m) => t + (Number(m.amount) || 0), 0));
    if (Math.abs(sum - amt) >= 0.01) { setError(`Payment modes (${money(sum)}) must add up to the amount (${money(amt)}).`); return; }
    setSaving(true);
    try {
      const res = await saveOpticalNewPayment({
        customer, saleId, amount: amt, modes: modes.map((m) => ({ mode: m.mode, amount: r2(m.amount) })), reference, remarks,
      });
      // On success the server opens the new receipt (redirect); the button
      // stays disabled until it does, so a second click can't save twice.
      if (res?.error) { setError(res.error); setSaving(false); }
    } catch (e) {
      if (String(e?.digest || e?.message || '').includes('NEXT_REDIRECT')) throw e;
      setError('Something went wrong -- check your connection and try again.');
      setSaving(false);
    }
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 2fr) minmax(260px, 1fr)', gap: 20, alignItems: 'start' }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-cash" style={{ color: 'var(--green)' }}></i> Record Payment
          <span style={{ fontSize: 11.5, fontWeight: 400, color: 'var(--g500)', marginLeft: 8 }}>for a bill or as advance</span>
        </div>
        {error && <div className="msg-err">{error}</div>}

        {!customer ? (
          <div>
            <label className="flbl">Customer (name, UHID or mobile) *</label>
            <input className="fi" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Type to search patients and optical customers..." autoFocus />
            {results.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {results.map((r) => (
                  <div key={`${r.type}-${r.id}`} onClick={() => pickCustomer(r)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{r.name}</strong> -- {r.type === 'patient' ? r.uhid : 'Optical customer'} -- {r.mobile || 'no mobile'}
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
                  <div style={{ fontWeight: 700 }}>{customer.name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>{customer.type === 'patient' ? customer.uhid : 'Optical customer'}{customer.mobile ? ` · ${customer.mobile}` : ''}</div>
                </div>
                <button type="button" className="btn btn-sm" onClick={() => { setCustomer(null); setBills([]); setSaleId(null); }}>Change</button>
              </div>
              <div style={{ fontSize: 11, marginTop: 5 }}>
                <span style={{ color: 'var(--purple)', fontWeight: 600 }}>Advance balance: </span>
                <span style={{ fontWeight: 700, color: 'var(--purple)' }}>{money(advanceBalance)}</span>
                {advanceBalance > 0 && <span style={{ color: 'var(--g500)', marginLeft: 4 }}>-- apply it from the bill (Optical Bills → Apply credits)</span>}
              </div>
            </div>

            <label className="flbl">Bill being paid <span style={{ fontWeight: 400, color: 'var(--g500)' }}>-- choose none to record an advance</span></label>
            {loadingCtx && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>Loading...</div>}
            {!loadingCtx && bills.length === 0 && <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>No unpaid bills for this customer -- this will be saved as an advance (customer credit).</div>}
            {!loadingCtx && bills.length > 0 && (
              <div style={{ marginBottom: 14 }}>
                {bills.map((b) => (
                  <label key={b.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px', borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer', background: saleId === b.id ? 'var(--green-lt)' : 'transparent', borderRadius: 4 }}>
                    <span>
                      <input type="radio" name="bill" checked={saleId === b.id} onChange={() => choose(b.id)} style={{ marginRight: 8 }} />
                      {b.sale_number} -- {dateIST(b.sale_date)} <span className={`badge ${STATUS_BADGE[b.status] || 'b-gray'}`} style={{ marginLeft: 4 }}>{STATUS_LABEL[b.status] || b.status}</span>
                    </span>
                    <span style={{ fontWeight: 600 }}>{money(b.due)}</span>
                  </label>
                ))}
                <label style={{ display: 'flex', alignItems: 'center', padding: '6px 4px', fontSize: 13, cursor: 'pointer', background: !saleId ? 'var(--purple-lt)' : 'transparent', borderRadius: 4 }}>
                  <input type="radio" name="bill" checked={!saleId} onChange={() => setSaleId(null)} style={{ marginRight: 8 }} /> No bill -- save as advance
                </label>
              </div>
            )}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Amount received (₹) *</label>
                <input type="number" min="0" step="0.01" className="fi" value={amount} onChange={(e) => { setAmount(e.target.value); if (modes.length === 1) setModes([{ ...modes[0], amount: e.target.value }]); }} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">{isAdvanceOnly ? 'Saved as' : 'Balance of chosen bill'}</label>
                <input className="fi" readOnly value={isAdvanceOnly ? 'Advance (customer credit)' : money(bill.due)} style={{ background: 'var(--g50)', fontWeight: 700, color: isAdvanceOnly ? 'var(--purple)' : 'var(--red)' }} />
              </div>
            </div>
            {amt > 0 && (
              <div style={{ fontSize: 12.5, marginBottom: 10, padding: '6px 10px', borderRadius: 8, background: toAdvance > 0.009 ? 'var(--purple-lt)' : 'var(--g50)', color: toAdvance > 0.009 ? 'var(--purple)' : 'var(--g600)' }}>
                {isAdvanceOnly
                  ? <><i className="ti ti-piggy-bank"></i> {money(amt)} will be saved as advance (customer credit).</>
                  : <>{money(toBill)} to {bill.sale_number}{toAdvance > 0.009 && <> · <i className="ti ti-piggy-bank"></i> {money(toAdvance)} extra goes to the customer&apos;s advance credit</>}</>}
              </div>
            )}

            <label className="flbl">Payment mode(s) *</label>
            <ModeRows modes={modes} setModes={setModes} total={amt} />

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginTop: 12 }}>
              <div><label className="flbl">Reference / Transaction ID</label><input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." /></div>
              <div><label className="flbl">Remarks</label><input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." /></div>
            </div>

            <button type="button" className="btn btn-green" style={{ marginTop: 14 }} onClick={save} disabled={saving || loadingCtx}>
              <i className="ti ti-circle-check"></i> {saving ? 'Saving...' : (isAdvanceOnly ? 'Save as Advance' : 'Save Payment')}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i> Unpaid Bills</div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click one to start collecting for that customer.</div>
          <div style={{ maxHeight: 360, overflowY: 'auto' }}>
            {unpaid.map((b) => (
              <div key={b.id} onClick={() => pickCustomer(b.customer, b.id)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{b.customer.name}</strong>
                  <span className={`badge ${STATUS_BADGE[b.status] || 'b-gray'}`}>{STATUS_LABEL[b.status] || b.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{b.sale_number}</span><span>{money(b.due)}</span>
                </div>
              </div>
            ))}
            {unpaid.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding right now.</div>}
          </div>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Payment Summary</div>
          {!customer ? (
            <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 13 }}>Select a customer</div>
          ) : (
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Bill</span><span>{bill ? bill.sale_number : '--'}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Balance of bill</span><span>{money(bill ? bill.due : 0)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Amount received</span><span>{money(amt)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>To bill</span><span>{money(toBill)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--purple)' }}><span>To advance</span><span>{money(toAdvance)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
