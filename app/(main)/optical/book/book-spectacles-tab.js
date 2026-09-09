'use client';

import { useState, useEffect, useRef } from 'react';
import {
  searchOpticalCustomers,
  createOpticalSale,
  getRecentOpticalItemNames,
  getOpticalSalesForCustomer,
  getOpticalSaleDetail,
  getOpticalAdvanceBalance,
  collectOpticalPayment,
  applyOpticalAdvanceAdjustment,
  collectOpticalAdvance,
} from '../actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];
const STATUS_COLORS = { Pending: 'var(--g500)', Partial: 'var(--purple)', Paid: 'var(--green)', Cancelled: 'var(--red)' };

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function BookSpectaclesTab() {
  // ---- Customer selection ----
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [useWalkIn, setUseWalkIn] = useState(false);
  const [walkInName, setWalkInName] = useState('');
  const [walkInMobile, setWalkInMobile] = useState('');

  const [bills, setBills] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [loadingCustomerData, setLoadingCustomerData] = useState(false);

  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => setSearchResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pick(r) {
    setSelected(r);
    setSearchResults([]);
    setSearchQuery('');
    setUseWalkIn(false);
    await refreshCustomerData(r);
  }

  async function refreshCustomerData(customer) {
    const c = customer || selected;
    if (!c) return;
    setLoadingCustomerData(true);
    const idArgs = { patientId: c.type === 'patient' ? c.id : null, opticalCustomerId: c.type === 'optical_customer' ? c.id : null };
    const [billsResult, balance] = await Promise.all([getOpticalSalesForCustomer(idArgs), getOpticalAdvanceBalance(idArgs)]);
    setBills(billsResult.sales || []);
    setAdvanceBalance(balance);
    setLoadingCustomerData(false);
  }

  function clearCustomer() {
    setSelected(null);
    setUseWalkIn(false);
    setWalkInName('');
    setWalkInMobile('');
    setBills([]);
    setAdvanceBalance(0);
  }

  const customerIdArgs = selected ? { patientId: selected.type === 'patient' ? selected.id : null, opticalCustomerId: selected.type === 'optical_customer' ? selected.id : null } : null;
  const outstandingBills = bills.filter((b) => b.status === 'Pending' || b.status === 'Partial');

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 20, maxWidth: 900 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--blue)' }}></i> Book Spectacles</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>
          Book a new order, collect an advance, or collect a balance payment -- all for one customer, in one place.
        </div>

        <label className="flbl">Customer</label>
        {!selected && !useWalkIn && (
          <div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient or existing optical customer (name/UHID/mobile)..." />
              <button className="btn" onClick={() => setUseWalkIn(true)}><i className="ti ti-user-plus"></i> New Walk-in</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((r) => (
                  <div key={`${r.type}-${r.id}`} onClick={() => pick(r)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{r.name}</strong> -- {r.type === 'patient' ? r.uhid : 'Optical Customer'} -- {r.mobile || 'no mobile'}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
        {selected && (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 14px', border: '1px solid var(--g200)', borderRadius: 8, background: 'var(--g50, #f7f8fa)' }}>
            <span>
              <strong style={{ fontSize: 15 }}>{selected.name}</strong> -- {selected.type === 'patient' ? selected.uhid : 'Optical Customer'} -- {selected.mobile || 'no mobile'}
              {advanceBalance > 0 && <span style={{ marginLeft: 10, color: 'var(--blue)' }}><i className="ti ti-piggy-bank"></i> Advance available: <strong>{fmt(advanceBalance)}</strong></span>}
            </span>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i> Change Customer</button>
          </div>
        )}
        {useWalkIn && !selected && (
          <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end' }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Walk-in name</label>
              <input className="fi" value={walkInName} onChange={(e) => setWalkInName(e.target.value)} placeholder="Customer name" />
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Mobile (optional)</label>
              <input className="fi" value={walkInMobile} onChange={(e) => setWalkInMobile(e.target.value)} placeholder="10-digit mobile" />
            </div>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i></button>
          </div>
        )}
      </div>

      {selected && (
        <>
          {outstandingBills.length > 0 && (
            <BalanceCollectionCard
              key="balance"
              bills={outstandingBills}
              advanceBalance={advanceBalance}
              onDone={() => refreshCustomerData()}
            />
          )}

          <BookingCard
            key="booking"
            selected={selected}
            walkInName={useWalkIn ? walkInName : null}
            walkInMobile={useWalkIn ? walkInMobile : null}
            onBooked={() => refreshCustomerData()}
          />

          <AdvanceCard
            key="advance"
            customerIdArgs={customerIdArgs}
            balance={advanceBalance}
            onDone={() => refreshCustomerData()}
          />

          {bills.length > 0 && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-history"></i> This Customer's Bills</div>
              {loadingCustomerData ? (
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>
              ) : (
                bills.map((b) => (
                  <div key={b.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
                    <span><strong>{b.sale_number}</strong> -- {fmt(b.net)}</span>
                    <span style={{ color: STATUS_COLORS[b.status] }}>{b.status}{b.outstanding > 0 && b.status !== 'Cancelled' ? ` (due ${fmt(b.outstanding)})` : ''}</span>
                  </div>
                ))
              )}
            </div>
          )}
        </>
      )}
    </div>
  );
}

// ---------- Book a new order ----------
function BookingCard({ selected, walkInName, walkInMobile, onBooked }) {
  const [open, setOpen] = useState(false);
  const [lines, setLines] = useState([{ tempId: 1, description: '', qty: 1, unit_price: '' }]);
  const [discount, setDiscount] = useState('');
  const [notes, setNotes] = useState('');
  const [recentItems, setRecentItems] = useState([]);
  const nextTempId = useRef(2);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [created, setCreated] = useState(null);

  useEffect(() => { if (open) getRecentOpticalItemNames().then(setRecentItems); }, [open]);

  function updateLine(tempId, field, value) {
    setLines((prev) => prev.map((l) => (l.tempId === tempId ? { ...l, [field]: value } : l)));
  }
  function addLine() {
    setLines((prev) => [...prev, { tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
  }
  function removeLine(tempId) {
    setLines((prev) => (prev.length > 1 ? prev.filter((l) => l.tempId !== tempId) : prev));
  }

  const gross = lines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.unit_price) || 0), 0);
  const net = Math.max(0, gross - (Number(discount) || 0));

  async function handleSubmit() {
    setError('');
    setSaving(true);
    const result = await createOpticalSale({
      patientId: selected.type === 'patient' ? selected.id : null,
      opticalCustomerId: selected.type === 'optical_customer' ? selected.id : null,
      customerName: walkInName, customerMobile: walkInMobile,
      items: lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
      discount, notes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setCreated(result.sale);
    setLines([{ tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
    setDiscount('');
    setNotes('');
    onBooked();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 8, cursor: 'pointer', display: 'flex', justifyContent: 'space-between' }} onClick={() => setOpen((o) => !o)}>
        <span><i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> Book New Spectacles</span>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`}></i>
      </div>

      {created && (
        <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '10px 12px', borderRadius: 8, fontSize: 13, marginBottom: 12 }}>
          <i className="ti ti-check"></i> Bill {created.sale_number} booked -- {fmt(created.net)} total, nothing collected yet. Collect an advance below if the customer is paying something now.
        </div>
      )}

      {open && (
        <>
          {error && <div className="msg-err">{error}</div>}
          <label className="flbl">Items (frame, lenses, power etc.)</label>
          {recentItems.length > 0 && (
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 6 }}>
              Recent: {recentItems.slice(0, 8).map((name, i) => (
                <span key={name}>
                  <span
                    onClick={() => {
                      const emptyLine = lines.find((l) => !l.description);
                      if (emptyLine) updateLine(emptyLine.tempId, 'description', name);
                      else setLines((prev) => [...prev, { tempId: nextTempId.current++, description: name, qty: 1, unit_price: '' }]);
                    }}
                    style={{ cursor: 'pointer', textDecoration: 'underline', color: 'var(--blue)' }}
                  >
                    {name}
                  </span>
                  {i < Math.min(recentItems.length, 8) - 1 ? ', ' : ''}
                </span>
              ))}
            </div>
          )}
          {lines.map((l) => (
            <div key={l.tempId} style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
              <input className="fi" style={{ flex: 3 }} value={l.description} onChange={(e) => updateLine(l.tempId, 'description', e.target.value)} placeholder="e.g. Titan frame TN-2201, or 'SPH -2.5 CYL -0.5' for lens power" />
              <input className="fi" type="number" min="1" style={{ flex: 1 }} value={l.qty} onChange={(e) => updateLine(l.tempId, 'qty', e.target.value)} placeholder="Qty" />
              <input className="fi" type="number" min="0" style={{ flex: 1 }} value={l.unit_price} onChange={(e) => updateLine(l.tempId, 'unit_price', e.target.value)} placeholder="Price" />
              <div style={{ flex: 1, alignSelf: 'center', fontSize: 13, textAlign: 'right' }}>{fmt((Number(l.qty) || 0) * (Number(l.unit_price) || 0))}</div>
              <button className="btn btn-sm" onClick={() => removeLine(l.tempId)}><i className="ti ti-trash"></i></button>
            </div>
          ))}
          <button className="btn btn-sm" onClick={addLine}><i className="ti ti-plus"></i> Add Item</button>

          <div style={{ display: 'flex', gap: 16, marginTop: 16 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Discount (\u20b9)</label>
              <input className="fi" type="number" min="0" value={discount} onChange={(e) => setDiscount(e.target.value)} placeholder="0" />
            </div>
            <div style={{ flex: 2 }}>
              <label className="flbl">Notes (prescription reference, order details)</label>
              <input className="fi" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional" />
            </div>
          </div>

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0', marginTop: 16, borderTop: '1.5px solid var(--g200)' }}>
            <span style={{ fontSize: 14 }}>Gross: {fmt(gross)} {Number(discount) > 0 && <>-- Discount: {fmt(discount)}</>}</span>
            <span style={{ fontSize: 16, fontWeight: 700 }}>Bill Total: {fmt(net)}</span>
          </div>
          <button className="btn btn-primary" disabled={saving} onClick={handleSubmit}>
            <i className="ti ti-file-plus"></i> {saving ? 'Booking...' : 'Book This Order'}
          </button>
        </>
      )}
    </div>
  );
}

// ---------- Collect advance ----------
function AdvanceCard({ customerIdArgs, balance, onDone }) {
  const [open, setOpen] = useState(false);
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  function toggleMode(m) {
    setModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m]; else next[m] = '';
      return next;
    });
  }
  const modesTotal = Object.values(modeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  async function handleCollect() {
    setError('');
    setSaving(true);
    const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
    const result = await collectOpticalAdvance({ ...customerIdArgs, amount: modesTotal, modes, reference, remarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Advance recorded -- receipt ${result.payment.receipt_number}`);
    setModeAmounts({ Cash: '' });
    setReference('');
    setRemarks('');
    onDone();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 8, cursor: 'pointer', display: 'flex', justifyContent: 'space-between' }} onClick={() => setOpen((o) => !o)}>
        <span><i className="ti ti-piggy-bank" style={{ color: 'var(--blue)' }}></i> Collect Advance {balance > 0 && <span style={{ fontWeight: 400, fontSize: 12, color: 'var(--g500)' }}>-- current balance {fmt(balance)}</span>}</span>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`}></i>
      </div>
      {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}
      {open && (
        <>
          {error && <div className="msg-err">{error}</div>}
          <label className="flbl">Payment Mode(s)</label>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
            {PAYMENT_MODES.map((m) => (
              <button key={m} className={m in modeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
            ))}
          </div>
          {Object.keys(modeAmounts).map((m) => (
            <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
              <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
              <input className="fi" type="number" value={modeAmounts[m]} onChange={(e) => setModeAmounts((prev) => ({ ...prev, [m]: e.target.value }))} />
            </div>
          ))}
          <label className="flbl" style={{ marginTop: 6 }}>Amount</label>
          <input className="fi" value={modesTotal} disabled style={{ background: 'var(--g50, #f7f8fa)', fontWeight: 700 }} />
          <div style={{ display: 'flex', gap: 12, margin: '10px 0' }}>
            <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" />
            <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Remarks (optional)" />
          </div>
          <button className="btn btn-primary" disabled={saving || modesTotal <= 0} onClick={handleCollect}>
            <i className="ti ti-piggy-bank"></i> {saving ? 'Recording...' : 'Collect Advance'}
          </button>
        </>
      )}
    </div>
  );
}

// ---------- Collect balance payment against outstanding bill(s) ----------
function BalanceCollectionCard({ bills, advanceBalance, onDone }) {
  const [activeBillId, setActiveBillId] = useState(bills.length === 1 ? bills[0].id : null);
  const [detail, setDetail] = useState(null);
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });
  const [applyAdvanceAmt, setApplyAdvanceAmt] = useState('');
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  useEffect(() => { if (activeBillId) loadBill(activeBillId); }, [activeBillId]);

  async function loadBill(id) {
    const result = await getOpticalSaleDetail(id);
    if (result.error) { setError(result.error); return; }
    setDetail(result);
    setModeAmounts({ Cash: result.sale.outstanding > 0 ? String(result.sale.outstanding) : '' });
  }

  const modesTotal = Object.values(modeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  function toggleMode(m) {
    setModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m]; else next[m] = '';
      return next;
    });
  }

  async function handleApplyAdvance() {
    setError('');
    setSaving(true);
    const result = await applyOpticalAdvanceAdjustment({
      patientId: detail.sale.patient_id, opticalCustomerId: detail.sale.optical_customer_id, saleId: detail.sale.id, amount: applyAdvanceAmt,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setApplyAdvanceAmt('');
    loadBill(detail.sale.id);
    onDone();
  }

  async function handleCollect() {
    setError('');
    setSaving(true);
    const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
    const result = await collectOpticalPayment({ saleId: detail.sale.id, amount: modesTotal, modes, reference, remarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Payment recorded -- receipt ${result.payment.receipt_number}`);
    setReference('');
    setRemarks('');
    loadBill(detail.sale.id);
    onDone();
  }

  return (
    <div className="card" style={{ border: '1.5px solid var(--blue)' }}>
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-cash" style={{ color: 'var(--blue)' }}></i> Collect Balance Payment</div>
      {error && <div className="msg-err">{error}</div>}
      {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

      {bills.length > 1 && !activeBillId && (
        <>
          <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>This customer has more than one order awaiting payment -- pick one:</div>
          {bills.map((b) => (
            <div key={b.id} onClick={() => setActiveBillId(b.id)} style={{ padding: '8px 12px', cursor: 'pointer', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 6, fontSize: 12.5, display: 'flex', justifyContent: 'space-between' }}>
              <span><strong>{b.sale_number}</strong></span>
              <span>{b.status} -- Due {fmt(b.outstanding)}</span>
            </div>
          ))}
        </>
      )}

      {activeBillId && detail && (
        <>
          {bills.length > 1 && (
            <span onClick={() => { setActiveBillId(null); setDetail(null); }} style={{ fontSize: 11.5, color: 'var(--blue)', cursor: 'pointer' }}>&larr; Choose a different order</span>
          )}
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', marginTop: 8, borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>{detail.sale.sale_number} -- Total</span><span>{fmt(detail.sale.net)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', marginBottom: 10, fontSize: 14, fontWeight: 700 }}>
            <span>Outstanding</span><span style={{ color: 'var(--red)' }}>{fmt(detail.sale.outstanding)}</span>
          </div>

          {advanceBalance > 0 && (
            <div style={{ background: 'var(--blue-lt, #eef4fb)', padding: '8px 12px', borderRadius: 8, marginBottom: 12, fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <span><i className="ti ti-piggy-bank"></i> Advance available: <strong>{fmt(advanceBalance)}</strong></span>
              <div style={{ display: 'flex', gap: 6 }}>
                <input className="fi" style={{ width: 100 }} type="number" value={applyAdvanceAmt} onChange={(e) => setApplyAdvanceAmt(e.target.value)} placeholder="Amount" />
                <button className="btn btn-sm" disabled={saving || !applyAdvanceAmt} onClick={handleApplyAdvance}>Apply</button>
              </div>
            </div>
          )}

          <label className="flbl">Payment Mode(s) for the Remaining Balance</label>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
            {PAYMENT_MODES.map((m) => (
              <button key={m} className={m in modeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
            ))}
          </div>
          {Object.keys(modeAmounts).map((m) => (
            <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
              <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
              <input className="fi" type="number" value={modeAmounts[m]} onChange={(e) => setModeAmounts((prev) => ({ ...prev, [m]: e.target.value }))} />
            </div>
          ))}
          <div style={{ fontSize: 11.5, color: modesTotal === Number(detail.sale.outstanding) ? 'var(--g500)' : 'var(--red)', marginBottom: 10 }}>
            Mode split total: {fmt(modesTotal)} {modesTotal !== Number(detail.sale.outstanding) ? `(must equal outstanding ${fmt(detail.sale.outstanding)})` : ''}
          </div>
          <div style={{ display: 'flex', gap: 12, margin: '10px 0' }}>
            <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" />
            <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Remarks (optional)" />
          </div>
          {detail.sale.outstanding > 0 && (
            <button className="btn btn-primary" disabled={saving || modesTotal !== Number(detail.sale.outstanding)} onClick={handleCollect}>
              <i className="ti ti-cash"></i> {saving ? 'Recording...' : 'Collect Balance'}
            </button>
          )}
        </>
      )}
    </div>
  );
}
