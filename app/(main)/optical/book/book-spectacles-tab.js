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
    await refreshCustomerData(r);
  }

  async function refreshCustomerData(customer) {
    const c = customer || selected;
    if (!c) return;
    setLoadingBills(true);
    const idArgs = { patientId: c.type === 'patient' ? c.id : null, opticalCustomerId: c.type === 'optical_customer' ? c.id : null };
    const [billsResult, balance] = await Promise.all([getOpticalSalesForCustomer(idArgs), getOpticalAdvanceBalance(idArgs)]);
    const list = billsResult.sales || [];
    setBills(list);
    setAdvanceBalance(balance);
    setLoadingBills(false);
    const ongoingCount = list.filter((b) => b.status === 'Pending' || b.status === 'Partial').length;
    setSection(ongoingCount > 0 ? 'ongoing' : 'new');
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

  const [collectNow, setCollectNow] = useState(false);
  const [advanceAmount, setAdvanceAmount] = useState('');
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });

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

  function toggleMode(m) {
    setModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m]; else next[m] = '';
      return next;
    });
  }
  const modesTotal = Object.values(modeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  async function handleSubmit() {
    setError('');
    setSaving(true);

    const advanceAmt = collectNow ? Number(advanceAmount) || 0 : 0;
    if (collectNow && advanceAmt > 0 && Math.abs(modesTotal - advanceAmt) > 0.01) {
      setError(`Payment mode split (${fmt(modesTotal)}) must add up to the advance amount (${fmt(advanceAmt)}).`);
      setSaving(false);
      return;
    }
    if (advanceAmt > net) {
      setError(`Advance (${fmt(advanceAmt)}) can't exceed the order total (${fmt(net)}).`);
      setSaving(false);
      return;
    }

    const saleResult = await createOpticalSale({
      patientId: selected.type === 'patient' ? selected.id : null,
      opticalCustomerId: selected.type === 'optical_customer' ? selected.id : null,
      customerName: walkInName, customerMobile: walkInMobile,
      items: lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
      discount, notes,
    });
    if (saleResult.error) { setError(saleResult.error); setSaving(false); return; }

    if (advanceAmt > 0) {
      const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
      const payResult = await collectOpticalPayment({ saleId: saleResult.sale.id, amount: advanceAmt, modes });
      if (payResult.error) {
        setError(`Order ${saleResult.sale.sale_number} was created, but collecting the advance failed: ${payResult.error}. You can collect it from Ongoing Orders instead.`);
        setSaving(false);
        onBooked();
        return;
      }
    }

    setSaving(false);
    setCreated({ ...saleResult.sale, advanceCollected: advanceAmt });
    setLines([{ tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
    setDiscount('');
    setNotes('');
    setCollectNow(false);
    setAdvanceAmount('');
    setModeAmounts({ Cash: '' });
    onBooked();
  }

  if (created) {
    return (
      <div className="card">
        <div style={{ background: 'var(--green-lt, #e3f5ec)', border: '1px solid var(--green, #157a4f)', borderRadius: 8, padding: '16px 18px' }}>
          <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--green, #157a4f)', marginBottom: 4 }}>
            <i className="ti ti-check"></i> Order {created.sale_number} sent for fitting
          </div>
          <div style={{ fontSize: 13, color: 'var(--g600)' }}>
            Total: {fmt(created.net)}{created.advanceCollected > 0 ? ` -- ${fmt(created.advanceCollected)} collected now, ${fmt(created.net - created.advanceCollected)} due on delivery.` : ' -- nothing collected yet.'}
          </div>
        </div>
        <span onClick={() => setCreated(null)} style={{ fontSize: 12, color: 'var(--g500)', textDecoration: 'underline', cursor: 'pointer', display: 'inline-block', marginTop: 12 }}>
          + Book another order
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

      <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600, margin: '10px 0', cursor: 'pointer' }}>
        <input type="checkbox" checked={collectNow} onChange={(e) => { setCollectNow(e.target.checked); if (!e.target.checked) setAdvanceAmount(''); }} />
        Collect an advance now
      </label>

      {collectNow && (
        <div style={{ padding: 12, background: 'var(--g50, #f7f8fa)', borderRadius: 8, marginBottom: 14 }}>
          <label className="flbl">Advance Amount (up to {fmt(net)} -- full payment)</label>
          <input className="fi" type="number" min="0" max={net} value={advanceAmount} onChange={(e) => setAdvanceAmount(e.target.value)} placeholder="0" />

          <label className="flbl" style={{ marginTop: 10 }}>Payment Mode(s)</label>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
            {PAYMENT_MODES.map((m) => (
              <button key={m} className={m in modeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
            ))}
          </div>
          {Object.keys(modeAmounts).map((m) => (
            <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
              <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
              <input className="fi fi-sm" style={{ width: 140 }} type="number" value={modeAmounts[m]} onChange={(e) => setModeAmounts((prev) => ({ ...prev, [m]: e.target.value }))} />
            </div>
          ))}
          <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>Mode split total: {fmt(modesTotal)}</div>
        </div>
      )}

      <button className="btn btn-primary" disabled={saving} onClick={handleSubmit}>
        <i className="ti ti-truck-delivery"></i> {saving ? 'Sending...' : 'Send for Fitting'}
      </button>
    </div>
  );
}

function OngoingOrdersSection({ bills, loading, advanceBalance, onChanged }) {
  const [expandedId, setExpandedId] = useState(bills.length === 1 ? bills[0].id : null);

  if (loading) return <div className="card"><div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div></div>;
  if (bills.length === 0) return <div className="card"><div style={{ fontSize: 12, color: 'var(--g400)' }}>No ongoing orders -- nothing awaiting payment for this customer.</div></div>;

  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 12 }}>
      {bills.map((b) => (
        <div key={b.id} className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', cursor: 'pointer' }} onClick={() => setExpandedId(expandedId === b.id ? null : b.id)}>
            <span><strong>{b.sale_number}</strong> -- {fmtDate(b.sale_date)} -- Total {fmt(b.net)}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
              <span style={{ color: 'var(--red)', fontWeight: 600 }}>Due {fmt(b.outstanding)}</span>
              <i className={`ti ti-chevron-${expandedId === b.id ? 'up' : 'down'}`}></i>
            </span>
          </div>
          {expandedId === b.id && (
            <BillAndCloseForm saleId={b.id} advanceBalance={advanceBalance} onChanged={onChanged} />
          )}
        </div>
      ))}
    </div>
  );
}

function BillAndCloseForm({ saleId, advanceBalance, onChanged }) {
  const [detail, setDetail] = useState(null);
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });
  const [applyAdvanceAmt, setApplyAdvanceAmt] = useState('');
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  useEffect(() => { load(); }, [saleId]);

  async function load() {
    const result = await getOpticalSaleDetail(saleId);
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
    const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
    const result = await collectOpticalPayment({ saleId, amount: detail.sale.outstanding, modes, reference, remarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Payment recorded -- receipt ${result.payment.receipt_number}. Episode closed.`);
    load();
    onChanged();
  }

  if (!detail) return <div style={{ fontSize: 12, color: 'var(--g400)', marginTop: 10 }}>Loading...</div>;

  return (
    <div style={{ marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--g100)' }}>
      {error && <div className="msg-err">{error}</div>}
      {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

      <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Items</div>
      {detail.items.map((it) => (
        <div key={it.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '3px 0', color: 'var(--g600)' }}>
          <span>{it.description} x{it.qty}</span><span>{fmt(it.amount)}</span>
        </div>
      ))}

      {detail.sale.outstanding <= 0 ? (
        <div style={{ fontSize: 12.5, color: 'var(--green)', marginTop: 10 }}>Fully paid.</div>
      ) : (
        <>
          {advanceBalance > 0 && (
            <div style={{ background: 'var(--blue-lt, #eef4fb)', padding: '8px 12px', borderRadius: 8, margin: '12px 0', fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
              <span><i className="ti ti-piggy-bank"></i> Unused advance available: <strong>{fmt(advanceBalance)}</strong></span>
              <div style={{ display: 'flex', gap: 6 }}>
                <input className="fi" style={{ width: 100 }} type="number" value={applyAdvanceAmt} onChange={(e) => setApplyAdvanceAmt(e.target.value)} placeholder="Amount" />
                <button className="btn btn-sm" disabled={saving || !applyAdvanceAmt} onClick={handleApplyAdvance}>Apply</button>
              </div>
            </div>
          )}

          <label className="flbl" style={{ marginTop: 10 }}>Payment Mode(s) for the Remaining Balance ({fmt(detail.sale.outstanding)})</label>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
            {PAYMENT_MODES.map((m) => (
              <button key={m} className={m in modeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
            ))}
          </div>
          {Object.keys(modeAmounts).map((m) => (
            <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
              <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
              <input className="fi fi-sm" style={{ width: 140 }} type="number" value={modeAmounts[m]} onChange={(e) => setModeAmounts((prev) => ({ ...prev, [m]: e.target.value }))} />
            </div>
          ))}
          <div style={{ fontSize: 11.5, color: modesTotal === Number(detail.sale.outstanding) ? 'var(--g500)' : 'var(--red)', marginBottom: 10 }}>
            Mode split total: {fmt(modesTotal)} {modesTotal !== Number(detail.sale.outstanding) ? `(must equal ${fmt(detail.sale.outstanding)})` : ''}
          </div>
          <div style={{ display: 'flex', gap: 12, marginBottom: 10 }}>
            <input className="fi fi-sm" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" style={{ flex: 1 }} />
            <input className="fi fi-sm" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Remarks (optional)" style={{ flex: 1 }} />
          </div>
          <button className="btn btn-primary" disabled={saving || modesTotal !== Number(detail.sale.outstanding)} onClick={handleCollect}>
            <i className="ti ti-cash"></i> {saving ? 'Recording...' : 'Bill Patient & Close Episode'}
          </button>
        </>
      )}

      <a href={`/optical-receipt-print/${saleId}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none', marginTop: 12, marginLeft: 8, display: 'inline-block' }}>
        <i className="ti ti-printer"></i> Print
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
