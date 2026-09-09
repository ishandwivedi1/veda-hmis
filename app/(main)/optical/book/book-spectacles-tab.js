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
  editOpticalSaleItems,
  getOpticalSaleEditHistory,
} from '../actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

export default function BookSpectaclesTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [useWalkIn, setUseWalkIn] = useState(false);
  const [walkInName, setWalkInName] = useState('');
  const [walkInMobile, setWalkInMobile] = useState('');

  const [bills, setBills] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [loadingBills, setLoadingBills] = useState(false);
  const [section, setSection] = useState('new');

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
    const list = await refreshCustomerData(r);
    const ongoingCount = (list || []).filter((b) => b.status === 'Pending' || b.status === 'Partial').length;
    setSection(ongoingCount > 0 ? 'ongoing' : 'new');
  }

  // Refreshes bills/advance balance only -- never changes which
  // section is showing. Called after every action (booking, collecting
  // a balance, applying an advance, etc.) so the numbers stay current
  // without yanking the user away from the section they're actively
  // working in (e.g. straight from Confirm Order into Collect Advance).
  async function refreshCustomerData(customer) {
    const c = customer || selected;
    if (!c) return [];
    setLoadingBills(true);
    const idArgs = { patientId: c.type === 'patient' ? c.id : null, opticalCustomerId: c.type === 'optical_customer' ? c.id : null };
    const [billsResult, balance] = await Promise.all([getOpticalSalesForCustomer(idArgs), getOpticalAdvanceBalance(idArgs)]);
    const list = billsResult.sales || [];
    setBills(list);
    setAdvanceBalance(balance);
    setLoadingBills(false);
    return list;
  }

  function clearCustomer() {
    setSelected(null);
    setUseWalkIn(false);
    setWalkInName('');
    setWalkInMobile('');
    setBills([]);
    setAdvanceBalance(0);
  }

  const ongoingBills = bills.filter((b) => b.status === 'Pending' || b.status === 'Partial');
  const previousBills = bills.filter((b) => b.status === 'Paid' || b.status === 'Cancelled');

  return (
    <div style={{ maxWidth: 900 }}>
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--blue)' }}></i> Book Spectacles</div>

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
              {advanceBalance > 0 && <span style={{ marginLeft: 10, color: 'var(--blue)' }}><i className="ti ti-piggy-bank"></i> Unused advance: <strong>{fmt(advanceBalance)}</strong></span>}
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
          <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
            <button className={section === 'new' ? 'btn btn-primary' : 'btn'} onClick={() => setSection('new')}>
              <i className="ti ti-file-plus"></i> Book New Order
            </button>
            <button className={section === 'ongoing' ? 'btn btn-primary' : 'btn'} onClick={() => setSection('ongoing')}>
              <i className="ti ti-clock"></i> Ongoing Orders {ongoingBills.length > 0 && `(${ongoingBills.length})`}
            </button>
            <button className={section === 'previous' ? 'btn btn-primary' : 'btn'} onClick={() => setSection('previous')}>
              <i className="ti ti-history"></i> Previous Orders {previousBills.length > 0 && `(${previousBills.length})`}
            </button>
          </div>

          {section === 'new' && (
            <NewOrderSection
              selected={selected}
              walkInName={useWalkIn ? walkInName : null}
              walkInMobile={useWalkIn ? walkInMobile : null}
              onBooked={() => refreshCustomerData()}
            />
          )}

          {section === 'ongoing' && (
            <OngoingOrdersSection
              bills={ongoingBills}
              loading={loadingBills}
              advanceBalance={advanceBalance}
              onChanged={() => refreshCustomerData()}
            />
          )}

          {section === 'previous' && (
            <PreviousOrdersSection bills={previousBills} loading={loadingBills} />
          )}
        </>
      )}
    </div>
  );
}

function NewOrderSection({ selected, walkInName, walkInMobile, onBooked }) {
  const [lines, setLines] = useState([{ tempId: 1, description: '', qty: 1, unit_price: '' }]);
  const [discount, setDiscount] = useState('');
  const [notes, setNotes] = useState('');
  const [recentItems, setRecentItems] = useState([]);
  const nextTempId = useRef(2);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [created, setCreated] = useState(null);

  useEffect(() => { getRecentOpticalItemNames().then(setRecentItems); }, []);

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

  async function handleConfirmOrder() {
    setError('');
    setSaving(true);
    const saleResult = await createOpticalSale({
      patientId: selected.type === 'patient' ? selected.id : null,
      opticalCustomerId: selected.type === 'optical_customer' ? selected.id : null,
      customerName: walkInName, customerMobile: walkInMobile,
      items: lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
      discount, notes,
    });
    setSaving(false);
    if (saleResult.error) { setError(saleResult.error); return; }
    setCreated(saleResult.sale);
    setLines([{ tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
    setDiscount('');
    setNotes('');
    onBooked();
  }

  function bookAnother() {
    setCreated(null);
  }

  if (created) {
    return (
      <div className="card">
        <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: '16px 18px', marginBottom: 16 }}>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 16, fontWeight: 700, color: 'var(--green)', marginBottom: 4 }}>
            <i className="ti ti-check"></i> Order {created.sale_number} confirmed -- sent for fitting
          </div>
          <div style={{ fontSize: 13, color: 'var(--g600)' }}>Total: {fmt(created.net)} -- nothing collected yet.</div>
        </div>

        <CollectAdvanceForNewOrder sale={created} onCollected={bookAnother} />

        <span onClick={bookAnother} style={{ fontSize: 12, color: 'var(--g500)', textDecoration: 'underline', cursor: 'pointer', display: 'inline-block', marginTop: 14 }}>
          Skip advance, book another order
        </span>
      </div>
    );
  }

  return (
    <div className="card">
      {error && <div className="msg-err">{error}</div>}

      <label className="flbl">Items -- frame, lenses, and any other item</label>
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
          <input className="fi" style={{ flex: 3 }} value={l.description} onChange={(e) => updateLine(l.tempId, 'description', e.target.value)} placeholder="e.g. Titan frame TN-2201, or lens power SPH -2.5 CYL -0.5" />
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
        <span style={{ fontSize: 16, fontWeight: 700 }}>Order Total: {fmt(net)}</span>
      </div>

      <button className="btn btn-primary" disabled={saving} onClick={handleConfirmOrder}>
        <i className="ti ti-truck-delivery"></i> {saving ? 'Confirming...' : 'Confirm Order'}
      </button>
    </div>
  );
}

// Shown right after an order is confirmed -- a separate, explicit step
// (and its own button) for collecting an advance against that specific
// order, rather than bundling it into the order-creation click.
function CollectAdvanceForNewOrder({ sale, onCollected }) {
  const [advanceAmount, setAdvanceAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [collected, setCollected] = useState(null);

  useEffect(() => {
    setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount: advanceAmount }] : rows));
  }, [advanceAmount]);

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      const usedModes = new Set(cleared.map((r) => r.mode));
      const nextMode = PAYMENT_MODES.find((m) => !usedModes.has(m)) || PAYMENT_MODES[0];
      return [...cleared, { mode: nextMode, amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const next = rows.filter((_, i) => i !== idx);
      return next.length === 1 ? [{ ...next[0], amount: advanceAmount }] : next;
    });
  }
  const modesTotal = modeRows.reduce((s, r) => s + (parseFloat(r.amount) || 0), 0);

  async function handleCollectAdvance() {
    setError('');
    const amt = Number(advanceAmount) || 0;
    if (amt <= 0) { setError('Enter an amount to collect.'); return; }
    if (amt > sale.net) { setError(`Advance (${fmt(amt)}) can't exceed the order total (${fmt(sale.net)}).`); return; }
    if (Math.abs(modesTotal - amt) > 0.01) { setError(`Payment mode split (${fmt(modesTotal)}) must add up to the advance amount (${fmt(amt)}).`); return; }

    setSaving(true);
    const modes = modeRows.filter((r) => parseFloat(r.amount) > 0).map((r) => ({ mode: r.mode, amount: r.amount }));
    const result = await collectOpticalPayment({ saleId: sale.id, amount: amt, modes });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setCollected({ amount: amt, receipt: result.payment.receipt_number, paymentId: result.payment.id });
  }

  if (collected) {
    return (
      <div style={{ background: 'var(--green-lt)', padding: '12px 16px', borderRadius: 'var(--r-sm)', fontSize: 13, fontWeight: 600, color: 'var(--green)' }}>
        <i className="ti ti-check"></i> Advance of {fmt(collected.amount)} collected -- receipt {collected.receipt}. {fmt(sale.net - collected.amount)} due on delivery.
        <div style={{ display: 'flex', gap: 14, marginTop: 6, alignItems: 'center' }}>
          <a href={`/optical-payment-receipt-print/${collected.paymentId}`} target="_blank" rel="noopener noreferrer" style={{ fontSize: 12, fontWeight: 400 }}>
            <i className="ti ti-printer"></i> Print Booking Receipt
          </a>
          <span onClick={onCollected} style={{ fontSize: 12, color: 'var(--g500)', textDecoration: 'underline', cursor: 'pointer', fontWeight: 400 }}>Book another order</span>
        </div>
      </div>
    );
  }

  return (
    <div style={{ padding: 16, background: 'var(--blue-lt)', borderRadius: 'var(--r)' }}>
      <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 14, fontWeight: 700, color: 'var(--blue-dk)', marginBottom: 10 }}>
        <i className="ti ti-piggy-bank"></i> Collect Advance for This Order
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

      <label className="flbl">Advance Amount (up to {fmt(sale.net)} -- full payment)</label>
      <input className="fi" style={{ background: '#fff' }} type="number" min="0" max={sale.net} value={advanceAmount} onChange={(e) => setAdvanceAmount(e.target.value)} placeholder="0" />

      <label className="flbl" style={{ marginTop: 10 }}>Payment Mode(s) -- split across multiple if needed</label>
      {modeRows.map((row, idx) => (
        <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
          <select className="fi fi-sm" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1, background: '#fff' }}>
            {PAYMENT_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
          <input
            className="fi fi-sm"
            type="number"
            value={row.amount}
            onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
            placeholder={modeRows.length === 1 ? 'Auto-filled from advance amount' : 'Amount'}
            readOnly={modeRows.length === 1}
            style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g100)' : '#fff' }}
          />
          {modeRows.length > 1 && <button className="btn btn-sm" onClick={() => removeModeRow(idx)}>&times;</button>}
        </div>
      ))}
      <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 10, background: '#fff' }}><i className="ti ti-plus"></i> Add mode</button>

      <button className="btn btn-primary" disabled={saving || !advanceAmount} onClick={handleCollectAdvance}>
        <i className="ti ti-piggy-bank"></i> {saving ? 'Collecting...' : 'Collect Advance'}
      </button>
    </div>
  );
}

function OngoingOrdersSection({ bills, loading, advanceBalance, onChanged }) {
  const [expandedId, setExpandedId] = useState(bills.length === 1 ? bills[0].id : null);

  if (loading) return <div className="card"><div style={{ fontSize: 13, color: 'var(--g400)' }}>Loading...</div></div>;
  if (bills.length === 0) return <div className="card"><div style={{ fontSize: 13, color: 'var(--g400)' }}>No ongoing orders -- nothing awaiting payment for this customer.</div></div>;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 14 }}>
      {bills.map((b) => {
        const isOpen = expandedId === b.id;
        return (
          <div key={b.id} className="card" style={{ padding: 0, overflow: 'hidden' }}>
            <div
              style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', cursor: 'pointer', padding: '16px 20px', background: isOpen ? 'var(--g50)' : '#fff' }}
              onClick={() => setExpandedId(isOpen ? null : b.id)}
            >
              <div>
                <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 15, fontWeight: 700, color: 'var(--g900)' }}>{b.sale_number}</div>
                <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Booked {fmtDate(b.sale_date)} -- Total {fmt(b.net)}</div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
                <span className="badge" style={{ background: 'var(--red-lt)', color: 'var(--red)', fontSize: 13, fontWeight: 700, padding: '6px 12px' }}>Due {fmt(b.outstanding)}</span>
                <i className={`ti ti-chevron-${isOpen ? 'up' : 'down'}`} style={{ color: 'var(--g400)', fontSize: 18 }}></i>
              </div>
            </div>
            {isOpen && (
              <div style={{ padding: '0 20px 20px', borderTop: '1px solid var(--g100)' }}>
                <BillAndCloseForm saleId={b.id} advanceBalance={advanceBalance} onChanged={onChanged} />
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function StatBlock({ label, value, color }) {
  return (
    <div style={{ flex: 1 }}>
      <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 4 }}>{label}</div>
      <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 21, fontWeight: 700, color: color || 'var(--g900)' }}>{value}</div>
    </div>
  );
}

function BillAndCloseForm({ saleId, advanceBalance, onChanged }) {
  const [detail, setDetail] = useState(null);
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [applyAdvanceAmt, setApplyAdvanceAmt] = useState('');
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  const [editing, setEditing] = useState(false);
  const [editLines, setEditLines] = useState([]);
  const [editDiscount, setEditDiscount] = useState('');
  const [editNotes, setEditNotes] = useState('');
  const [editReason, setEditReason] = useState('');
  const editNextTempId = useRef(1);

  useEffect(() => { load(); }, [saleId]);

  async function load() {
    const result = await getOpticalSaleDetail(saleId);
    if (result.error) { setError(result.error); return; }
    setDetail(result);
    setModeRows([{ mode: 'Cash', amount: result.sale.outstanding > 0 ? String(result.sale.outstanding) : '' }]);
  }

  function startEditing() {
    editNextTempId.current = 1;
    setEditLines(detail.items.map((it) => ({ tempId: editNextTempId.current++, description: it.description, qty: it.qty, unit_price: it.unit_price })));
    setEditDiscount(detail.sale.discount > 0 ? String(detail.sale.discount) : '');
    setEditNotes(detail.sale.notes || '');
    setEditReason('');
    setError('');
    setEditing(true);
  }
  function updateEditLine(tempId, field, value) {
    setEditLines((prev) => prev.map((l) => (l.tempId === tempId ? { ...l, [field]: value } : l)));
  }
  function addEditLine() {
    setEditLines((prev) => [...prev, { tempId: editNextTempId.current++, description: '', qty: 1, unit_price: '' }]);
  }
  function removeEditLine(tempId) {
    setEditLines((prev) => (prev.length > 1 ? prev.filter((l) => l.tempId !== tempId) : prev));
  }
  const editGross = editLines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.unit_price) || 0), 0);
  const editNet = Math.max(0, editGross - (Number(editDiscount) || 0));

  async function saveEdit() {
    setError('');
    setSaving(true);
    const result = await editOpticalSaleItems({
      saleId, items: editLines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
      discount: editDiscount, notes: editNotes, reason: editReason,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg('Order updated.');
    setEditing(false);
    load();
    onChanged();
  }

  // Single mode (the common case) always matches the outstanding
  // balance -- no need to type the number twice. Only once a second
  // mode is added (a real split) does each row need its own amount.
  useEffect(() => {
    if (detail) setModeRows((rows) => (rows.length === 1 ? [{ ...rows[0], amount: String(detail.sale.outstanding) }] : rows));
  }, [detail?.sale.outstanding]);

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }
  function addModeRow() {
    setModeRows((rows) => {
      const cleared = rows.length === 1 ? [{ ...rows[0], amount: '' }] : rows;
      const usedModes = new Set(cleared.map((r) => r.mode));
      const nextMode = PAYMENT_MODES.find((m) => !usedModes.has(m)) || PAYMENT_MODES[0];
      return [...cleared, { mode: nextMode, amount: '' }];
    });
  }
  function removeModeRow(idx) {
    setModeRows((rows) => {
      const next = rows.filter((_, i) => i !== idx);
      return next.length === 1 && detail ? [{ ...next[0], amount: String(detail.sale.outstanding) }] : next;
    });
  }
  const modesTotal = modeRows.reduce((s, r) => s + (parseFloat(r.amount) || 0), 0);

  async function handleApplyAdvance() {
    setError('');
    setSaving(true);
    const result = await applyOpticalAdvanceAdjustment({
      patientId: detail.sale.patient_id, opticalCustomerId: detail.sale.optical_customer_id, saleId, amount: applyAdvanceAmt,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setApplyAdvanceAmt('');
    load();
    onChanged();
  }

  async function handleCollect() {
    setError('');
    setSaving(true);
    const modes = modeRows.filter((r) => parseFloat(r.amount) > 0).map((r) => ({ mode: r.mode, amount: r.amount }));
    const result = await collectOpticalPayment({ saleId, amount: detail.sale.outstanding, modes, reference, remarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Payment recorded -- receipt ${result.payment.receipt_number}. Episode closed.`);
    load();
    onChanged();
  }

  if (!detail) return <div style={{ fontSize: 13, color: 'var(--g400)', padding: '16px 0' }}>Loading...</div>;

  const paymentTypeLabel = (p) => {
    if (p.payment_type === 'advance_adjustment') return 'Advance Applied';
    if (p.payment_type === 'credit_note') return 'Credit Note';
    if (p.payment_type === 'refund') return 'Refund';
    return (p.optical_payment_modes || []).map((m) => m.mode).join(' + ') || 'Payment';
  };

  return (
    <div style={{ paddingTop: 18 }}>
      {error && <div className="msg-err" style={{ marginBottom: 14 }}>{error}</div>}
      {successMsg && <div style={{ background: 'var(--green-lt)', color: 'var(--green)', padding: '10px 14px', borderRadius: 'var(--r-sm)', fontSize: 13, fontWeight: 600, marginBottom: 14 }}>
        <i className="ti ti-check"></i> {successMsg}
      </div>}

      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 14 }}>
        <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 16, fontWeight: 700, color: 'var(--g900)' }}>Order Summary</div>
        {!editing && detail.sale.status !== 'Cancelled' && (
          <button className="btn btn-sm" onClick={startEditing}><i className="ti ti-edit"></i> Edit Order</button>
        )}
      </div>

      {editing ? (
        <div style={{ padding: 20, background: 'var(--amber-lt)', borderRadius: 'var(--r)' }}>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 14, fontWeight: 700, color: 'var(--amber)', marginBottom: 4 }}>
            <i className="ti ti-edit"></i> Editing {detail.sale.sale_number}
          </div>
          <div style={{ fontSize: 12, color: 'var(--g600)', marginBottom: 14 }}>
            The new total can't drop below what's already been paid or applied ({fmt(detail.sale.paid)}).
          </div>

          {editLines.map((l) => (
            <div key={l.tempId} style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" style={{ flex: 3, background: '#fff' }} value={l.description} onChange={(e) => updateEditLine(l.tempId, 'description', e.target.value)} placeholder="Item description" />
              <input className="fi fi-sm" style={{ flex: 1, background: '#fff' }} type="number" min="1" value={l.qty} onChange={(e) => updateEditLine(l.tempId, 'qty', e.target.value)} placeholder="Qty" />
              <input className="fi fi-sm" style={{ flex: 1, background: '#fff' }} type="number" min="0" value={l.unit_price} onChange={(e) => updateEditLine(l.tempId, 'unit_price', e.target.value)} placeholder="Price" />
              <div style={{ flex: 1, alignSelf: 'center', fontSize: 13, textAlign: 'right' }}>{fmt((Number(l.qty) || 0) * (Number(l.unit_price) || 0))}</div>
              <button className="btn btn-sm" onClick={() => removeEditLine(l.tempId)}><i className="ti ti-trash"></i></button>
            </div>
          ))}
          <button className="btn btn-sm" onClick={addEditLine} style={{ marginBottom: 12, background: '#fff' }}><i className="ti ti-plus"></i> Add Item</button>

          <div style={{ display: 'flex', gap: 16, marginBottom: 12 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Discount (\u20b9)</label>
              <input className="fi fi-sm" style={{ background: '#fff' }} type="number" min="0" value={editDiscount} onChange={(e) => setEditDiscount(e.target.value)} placeholder="0" />
            </div>
            <div style={{ flex: 2 }}>
              <label className="flbl">Notes</label>
              <input className="fi fi-sm" style={{ background: '#fff' }} value={editNotes} onChange={(e) => setEditNotes(e.target.value)} placeholder="Optional" />
            </div>
          </div>

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 0', borderTop: '1px solid rgba(0,0,0,.08)', marginBottom: 12, fontSize: 15, fontWeight: 700 }}>
            <span>New Order Total</span><span>{fmt(editNet)}</span>
          </div>

          <label className="flbl">Reason for this change (required)</label>
          <input className="fi fi-sm" style={{ background: '#fff' }} value={editReason} onChange={(e) => setEditReason(e.target.value)} placeholder="e.g. corrected frame price, added lens coating" />

          <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
            <button className="btn btn-sm" onClick={() => setEditing(false)}>Cancel</button>
            <button className="btn btn-sm btn-primary" disabled={saving} onClick={saveEdit}>{saving ? 'Saving...' : 'Save Changes'}</button>
          </div>
        </div>
      ) : (
        <>
      {/* Financial summary -- order total, what's already been paid or
          applied, and what's still due, at a glance. */}
      {detail.sale.discount > 0 && (
        <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>
          Gross: {fmt(detail.sale.gross)} -- Discount: {fmt(detail.sale.discount)}
        </div>
      )}
      <div style={{ display: 'flex', gap: 24, padding: '16px 20px', background: 'var(--g50)', borderRadius: 'var(--r)', marginBottom: 18 }}>
        <StatBlock label="Order Total" value={fmt(detail.sale.net)} />
        <StatBlock label="Paid / Applied So Far" value={fmt(detail.sale.paid)} color="var(--green)" />
        <StatBlock label="Balance Due" value={fmt(detail.sale.outstanding)} color={detail.sale.outstanding > 0 ? 'var(--red)' : 'var(--green)'} />
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 24 }}>
        <div>
          <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 8 }}>Items Ordered</div>
          <div style={{ border: '1px solid var(--g200)', borderRadius: 'var(--r-sm)', overflow: 'hidden' }}>
            {detail.items.map((it, i) => (
              <div key={it.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '9px 12px', background: i % 2 ? 'var(--g50)' : '#fff' }}>
                <span style={{ color: 'var(--g700)' }}>{it.description} {it.qty > 1 && <span style={{ color: 'var(--g400)' }}>x{it.qty}</span>}</span>
                <span style={{ fontWeight: 600 }}>{fmt(it.amount)}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--g500)', marginBottom: 8 }}>
            Previous Payments &amp; Advance
          </div>
          {detail.payments.length === 0 ? (
            <div style={{ border: '1px solid var(--g200)', borderRadius: 'var(--r-sm)', padding: '12px', fontSize: 12.5, color: 'var(--g400)' }}>
              Nothing collected against this order yet.
            </div>
          ) : (
            <div style={{ border: '1px solid var(--g200)', borderRadius: 'var(--r-sm)', overflow: 'hidden' }}>
              {detail.payments.map((p, i) => (
                <div key={p.id} style={{ padding: '9px 12px', background: i % 2 ? 'var(--g50)' : '#fff' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13 }}>
                    <span style={{ fontWeight: 600, color: 'var(--g700)' }}>{paymentTypeLabel(p)}</span>
                    <span style={{ fontWeight: 700, color: 'var(--green)' }}>{fmt(p.total_amount)}</span>
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 1 }}>{p.receipt_number} -- {fmtDate(p.collected_at)}</div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {detail.sale.outstanding <= 0 ? (
        <div style={{ marginTop: 18, background: 'var(--green-lt)', color: 'var(--green)', padding: '12px 16px', borderRadius: 'var(--r)', fontSize: 13.5, fontWeight: 600 }}>
          <i className="ti ti-circle-check"></i> Fully paid -- this episode is closed.
        </div>
      ) : (
        <div style={{ marginTop: 20, padding: 20, background: 'var(--blue-lt)', borderRadius: 'var(--r)' }}>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 14, fontWeight: 700, color: 'var(--blue-dk)', marginBottom: 14 }}>
            <i className="ti ti-cash"></i> Collect Remaining Balance -- {fmt(detail.sale.outstanding)}
          </div>

          {advanceBalance > 0 && (
            <div style={{ background: '#fff', padding: '10px 14px', borderRadius: 'var(--r-sm)', marginBottom: 14, fontSize: 13, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <span><i className="ti ti-piggy-bank" style={{ color: 'var(--blue)' }}></i> Unused advance on file: <strong>{fmt(advanceBalance)}</strong></span>
              <div style={{ display: 'flex', gap: 6 }}>
                <input className="fi fi-sm" style={{ width: 100 }} type="number" value={applyAdvanceAmt} onChange={(e) => setApplyAdvanceAmt(e.target.value)} placeholder="Amount" />
                <button className="btn btn-sm" disabled={saving || !applyAdvanceAmt} onClick={handleApplyAdvance}>Apply</button>
              </div>
            </div>
          )}

          <label className="flbl">Payment Mode(s) -- split across multiple if needed</label>
          {modeRows.map((row, idx) => (
            <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
              <select className="fi fi-sm" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1, background: '#fff' }}>
                {PAYMENT_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
              <input
                className="fi fi-sm"
                type="number"
                value={row.amount}
                onChange={(e) => updateModeRow(idx, 'amount', e.target.value)}
                placeholder={modeRows.length === 1 ? 'Auto-filled from balance due' : 'Amount'}
                readOnly={modeRows.length === 1}
                style={{ flex: 1, background: modeRows.length === 1 ? 'var(--g100)' : '#fff' }}
              />
              {modeRows.length > 1 && <button className="btn btn-sm" onClick={() => removeModeRow(idx)}>&times;</button>}
            </div>
          ))}
          <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 8, background: '#fff' }}><i className="ti ti-plus"></i> Add mode</button>
          <div style={{ fontSize: 12, fontWeight: 600, color: modesTotal === Number(detail.sale.outstanding) ? 'var(--green)' : 'var(--red)', marginBottom: 12 }}>
            Split total: {fmt(modesTotal)} {modesTotal !== Number(detail.sale.outstanding) ? `-- must equal ${fmt(detail.sale.outstanding)}` : ''}
          </div>
          <div style={{ display: 'flex', gap: 12, marginBottom: 14 }}>
            <input className="fi fi-sm" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" style={{ flex: 1, background: '#fff' }} />
            <input className="fi fi-sm" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Remarks (optional)" style={{ flex: 1, background: '#fff' }} />
          </div>
          <button className="btn btn-primary" disabled={saving || modesTotal !== Number(detail.sale.outstanding)} onClick={handleCollect}>
            <i className="ti ti-cash"></i> {saving ? 'Recording...' : 'Bill Patient & Close Episode'}
          </button>
        </div>
      )}
        </>
      )}

      <a href={`/optical-receipt-print/${saleId}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none', marginTop: 16, display: 'inline-block' }}>
        <i className="ti ti-printer"></i> Print Bill
      </a>
    </div>
  );
}


function PreviousOrdersSection({ bills, loading }) {
  if (loading) return <div className="card"><div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div></div>;
  if (bills.length === 0) return <div className="card"><div style={{ fontSize: 12, color: 'var(--g400)' }}>No previous orders for this customer yet.</div></div>;

  return (
    <div className="card">
      {bills.map((b) => (
        <div key={b.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 0', borderBottom: '1px solid var(--g100)', fontSize: 13, opacity: b.status === 'Cancelled' ? 0.6 : 1 }}>
          <span><strong>{b.sale_number}</strong> -- {fmtDate(b.sale_date)}</span>
          <span style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <span style={{ color: b.status === 'Cancelled' ? 'var(--red)' : 'var(--green)' }}>{b.status === 'Cancelled' ? 'Cancelled' : fmt(b.net)}</span>
            <a href={`/optical-receipt-print/${b.id}`} target="_blank" rel="noopener noreferrer" style={{ fontSize: 12, color: 'var(--blue)' }}>Print</a>
          </span>
        </div>
      ))}
    </div>
  );
}
