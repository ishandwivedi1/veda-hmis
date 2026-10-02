'use client';

import { useState, useEffect, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import { formatPatientName } from '@/lib/patientName';
// One request per click: the list arrives with the page (server render);
// Finalize / Cancel send back the refreshed list in the same response.
import { finalizeOpticalOrderAndRefresh, cancelOpticalOrderAndRefresh } from '../book-finalize-actions';
import { openPrintPopup } from '@/lib/printPopup';
import { collectOpticalPayment } from '../actions';
import { ModeRows, r2 } from '../optical-ui';

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

export default function FinalizeOrderTab({ initialOrders = [] }) {
  const searchParams = useSearchParams();
  const initialOrderId = searchParams.get('orderId');
  const autoOpenedRef = useRef(false);

  const [orders, setOrders] = useState(initialOrders);
  const [selected, setSelected] = useState(null);
  const [lines, setLines] = useState([]);
  const [discount, setDiscount] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [result, setResult] = useState(null);
  const [cancelReason, setCancelReason] = useState('');
  const [showCancelForm, setShowCancelForm] = useState(false);
  const nextTempId = useRef(1);

  // Deep link from the Optical Dashboard's "Finalize Existing Order" box (?orderId=...)
  // opens that order's edit/finalize panel directly instead of landing on the
  // bare list and making the person find and click it again. Runs once per
  // orderId -- autoOpenedRef stops it from re-forcing the selection back open
  // if the person deliberately closes it (e.g. after finalizing) while still
  // on this page.
  useEffect(() => {
    if (!initialOrderId || autoOpenedRef.current) return;
    const match = orders.find((o) => o.id === initialOrderId);
    if (match) {
      autoOpenedRef.current = true;
      openOrder(match);
    }
  }, [initialOrderId, orders]);

  function openOrder(order) {
    setSelected(order);
    setResult(null);
    setError('');
    setShowCancelForm(false);
    setLines((order.items || []).map((it) => ({
      tempId: nextTempId.current++, description: it.description, qty: it.qty, unit_price: it.unit_price,
    })));
    setDiscount(order.discount > 0 ? String(order.discount) : '');
    setNotes(order.notes || '');
  }

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

  async function handleFinalize() {
    setError('');
    setSaving(true);
    try {
      const cleanItems = lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price }));
      const res = await finalizeOpticalOrderAndRefresh(selected.id, { items: cleanItems, discount, notes });
      if (res.error) { setError(res.error); return; }
      setResult(res.sale);
      setSelected(null);
      setOrders(res.orders || []);
    } catch (e) {
      setError('Something went wrong finalizing this order -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  async function handleCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A reason is required to cancel this order.'); return; }
    setSaving(true);
    try {
      const res = await cancelOpticalOrderAndRefresh(selected.id, cancelReason);
      if (res.error) { setError(res.error); return; }
      setSelected(null);
      setCancelReason('');
      setShowCancelForm(false);
      setOrders(res.orders || []);
    } catch (e) {
      setError('Something went wrong cancelling this order -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  if (result) {
    return (
      <div className="card">
        <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: '16px 18px' }}>
          <div style={{ fontSize: 11, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.4px', color: 'var(--green)', marginBottom: 4 }}>
            <i className="ti ti-check"></i> Order Finalized -- Bill Created
          </div>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 22, fontWeight: 700, color: 'var(--g900)' }}>{result.sale_number}</div>
          <div style={{ fontSize: 13, color: 'var(--g600)', marginTop: 2 }}>
            Total: {fmt(result.net)} -- Paid/applied: {fmt(Number(result.paid) + (result.collectedNow || 0))} -- Balance due: {fmt(Math.max(0, Number(result.net) - Number(result.paid) - (result.collectedNow || 0)))}
          </div>
          <div style={{ display: 'flex', gap: 14, marginTop: 10 }}>
            <a href={`/optical-receipt-print/${result.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-primary" style={{ textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Bill
            </a>
          </div>
        </div>
        {/* Collect the balance right here -- no trip to Optical Bills. ONE request. */}
        {r2(Number(result.net) - Number(result.paid)) > 0 && (
          <CollectBalance sale={result} onPaid={(paidNow) => setResult((r) => ({ ...r, collectedNow: paidNow }))} />
        )}

        <span onClick={() => setResult(null)} style={{ fontSize: 12, color: 'var(--g500)', textDecoration: 'underline', cursor: 'pointer', display: 'inline-block', marginTop: 14 }}>
          Finalize another order
        </span>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.4fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--blue)' }}></i> Orders Awaiting Delivery
        </div>
        {orders.map((o) => (
          <div
            key={o.id}
            onClick={() => openOrder(o)}
            style={{
              padding: '10px 12px', cursor: 'pointer', borderRadius: 8, marginBottom: 6, fontSize: 13,
              background: selected?.id === o.id ? 'var(--blue-lt)' : 'var(--g50)',
              border: selected?.id === o.id ? '1.5px solid var(--blue)' : '1px solid var(--g200)',
            }}
          >
            <div style={{ display: 'flex', justifyContent: 'space-between' }}>
              <strong>{o.patients ? formatPatientName(o.patients) : (o.optical_customers?.name || o.customer_name || 'Walk-in')}</strong>
              <span style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--g500)' }}>{o.order_number}</span>
            </div>
            <div style={{ color: 'var(--g500)', fontSize: 12, marginTop: 2 }}>
              Estimated {fmt(o.net)} -- booked {fmtDate(o.created_at)}
            </div>
          </div>
        ))}
        {orders.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No orders currently awaiting delivery.</div>}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.order_number}</div>
            <span style={{ fontSize: 12, color: 'var(--g500)' }}>
              {selected.patients ? formatPatientName(selected.patients) : (selected.optical_customers?.name || selected.customer_name || 'Walk-in')}
            </span>
          </div>

          {error && <div className="msg-err">{error}</div>}

          <div className="msg-info" style={{ marginBottom: 12 }}>
            <i className="ti ti-info-circle"></i> Confirm the final items and pricing below -- this is what actually gets billed, and may differ from the original estimate. Any advance already on file for this customer is applied automatically.
          </div>

          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead><tr><th>Description</th><th>Qty</th><th>Unit Price</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {lines.map((l) => (
                <tr key={l.tempId}>
                  <td><input className="fi fi-sm" value={l.description} onChange={(e) => updateLine(l.tempId, 'description', e.target.value)} /></td>
                  <td style={{ width: 70 }}><input type="number" className="fi fi-sm" min={1} value={l.qty} onChange={(e) => updateLine(l.tempId, 'qty', e.target.value)} /></td>
                  <td style={{ width: 100 }}><input type="number" className="fi fi-sm" min={0} value={l.unit_price} onChange={(e) => updateLine(l.tempId, 'unit_price', e.target.value)} /></td>
                  <td style={{ fontSize: 12 }}>{fmt((Number(l.qty) || 0) * (Number(l.unit_price) || 0))}</td>
                  <td>{lines.length > 1 && <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => removeLine(l.tempId)}>Remove</button>}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={addLine}><i className="ti ti-plus"></i> Add item</button>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div>
              <label className="flbl">Discount (Rs.)</label>
              <input type="number" className="fi" min={0} value={discount} onChange={(e) => setDiscount(e.target.value)} placeholder="0" />
            </div>
            <div>
              <label className="flbl">Notes</label>
              <input className="fi" value={notes} onChange={(e) => setNotes(e.target.value)} />
            </div>
          </div>

          <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 12 }}>
            Gross: {fmt(gross)} {Number(discount) > 0 && <>-- Discount: {fmt(discount)}</>} -- Net: {fmt(net)}
          </div>

          <div style={{ display: 'flex', gap: 10 }}>
            <button className="btn btn-primary" disabled={saving} onClick={handleFinalize}>
              <i className="ti ti-circle-check"></i> {saving ? 'Finalizing...' : 'Finalize Order & Create Bill'}
            </button>
            {!showCancelForm ? (
              <button className="btn" style={{ color: 'var(--red)' }} onClick={() => setShowCancelForm(true)}>
                <i className="ti ti-x"></i> Cancel Order
              </button>
            ) : null}
          </div>

          {showCancelForm && (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12, marginTop: 12 }}>
              <label className="flbl">Reason for cancelling this order *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="e.g. Customer changed their mind" />
                <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} disabled={saving} onClick={handleCancel}>Confirm Cancel</button>
                <button className="btn btn-sm" onClick={() => setShowCancelForm(false)}>Back</button>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
                <i className="ti ti-info-circle"></i> Cancelling only marks this order cancelled -- any advance already collected stays on the customer's advance balance and can be applied to their next bill.
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// Collect Remaining Balance, shown right after the bill is created.
// ONE request (collect_optical_payment); same rules as everywhere else
// (day must be open, modes must add up). Anything above the balance is
// kept as the customer's advance credit.
function CollectBalance({ sale, onPaid }) {
  const due = r2(Number(sale.net) - Number(sale.paid));
  const [amount, setAmount] = useState(String(due));
  const [modes, setModes] = useState([{ mode: 'Cash', amount: String(due) }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [done, setDone] = useState(null);
  const amt = r2(amount);

  async function save() {
    if (busy) return;
    setError('');
    if (!(amt > 0)) { setError('Enter the amount received.'); return; }
    const sum = r2(modes.reduce((t, m) => t + (Number(m.amount) || 0), 0));
    if (Math.abs(sum - amt) >= 0.01) { setError(`Payment modes (${fmt(sum)}) must add up to the amount (${fmt(amt)}).`); return; }
    setBusy(true);
    try {
      const res = await collectOpticalPayment({ saleId: sale.id, amount: amt, modes: modes.map((m) => ({ mode: m.mode, amount: r2(m.amount) })), reference, remarks });
      if (res?.error) { setError(res.error); return; }
      setDone({ amount: amt, receipt: res.payment?.receipt_number, paymentId: res.payment?.id, extra: r2(amt - due) });
      onPaid(Math.min(amt, due));
    } catch {
      setError('Something went wrong -- check your connection and try again.');
    } finally {
      setBusy(false);
    }
  }

  if (done) {
    return (
      <div style={{ marginTop: 14, background: 'var(--green-lt)', padding: '12px 16px', borderRadius: 'var(--r-sm)', fontSize: 13, fontWeight: 600, color: 'var(--green)' }}>
        <i className="ti ti-check"></i> {fmt(done.amount)} received{done.receipt ? ` -- receipt ${done.receipt}` : ''}.{done.extra > 0 ? ` ${fmt(done.extra)} over the balance is kept as advance credit.` : ' Bill fully paid.'}
        <div style={{ display: 'flex', gap: 10, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {/* The full bill: items, totals, and every payment -- including the
              advance receipt(s) used, with the amount used from each. */}
          <a href={`/optical-receipt-print/${sale.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-printer"></i> Print Bill</a>
          {done.paymentId && (
            <a href={`/optical-payment-receipt-print/${done.paymentId}`} target="_blank" rel="noopener noreferrer" style={{ fontSize: 12, fontWeight: 400 }}><i className="ti ti-receipt"></i> Print this payment receipt only</a>
          )}
        </div>
      </div>
    );
  }

  return (
    <div style={{ marginTop: 14, padding: 16, background: 'var(--blue-lt)', borderRadius: 'var(--r)' }}>
      <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 14, fontWeight: 700, color: 'var(--blue-dk)', marginBottom: 10 }}>
        <i className="ti ti-cash"></i> Collect Remaining Balance -- {fmt(due)}
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10, marginBottom: 10 }}>
        <div><label className="flbl">Amount received (₹)</label>
          <input type="number" min="0" step="0.01" className="fi" style={{ background: '#fff' }} value={amount} onChange={(e) => { setAmount(e.target.value); if (modes.length === 1) setModes([{ ...modes[0], amount: e.target.value }]); }} /></div>
        <div><label className="flbl">Reference</label><input className="fi" style={{ background: '#fff' }} value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4..." /></div>
        <div><label className="flbl">Remarks</label><input className="fi" style={{ background: '#fff' }} value={remarks} onChange={(e) => setRemarks(e.target.value)} /></div>
      </div>
      <label className="flbl">Payment mode(s)</label>
      <ModeRows modes={modes} setModes={setModes} total={amt} />
      <button type="button" className="btn btn-primary" style={{ marginTop: 12 }} disabled={busy} onClick={save}>
        <i className="ti ti-cash"></i> {busy ? 'Saving...' : 'Collect Payment'}
      </button>
    </div>
  );
}
