'use client';

// Optical Bills -- laid out exactly like hospital Invoices (Oct 2026):
// summary strip (outstanding, billed today, still due from today),
// searchable list, and a bill pane with Edit (Cancel bill inside, as Void
// is on hospital invoices) / Record Payment / PDF-Print / Credit Note /
// History, a "Credits available -> Apply credits" strip for the customer's
// advance, and a "Payments received (n)" strip.
//
// ONE request per screen load / search, ONE per click: opening a bill is one
// call (ui_optical_bill_panel); every save sends back the refreshed bill and
// list in the same response (screens-actions.js) -- no reloads afterwards.

import { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import DayOpenBar from '@/app/components/DayOpenBar';
import EditReasonModal from '@/app/components/EditReasonModal';
import { saveOpticalBillEdit, recordOpticalBillPayment, applyOpticalAdvanceToBill, cancelOpticalBill, createOpticalCreditNoteAndRefresh } from '../screens-actions';
import { getOpticalBillsScreen, getOpticalBillPanel } from '@/lib/rpc-reads/optical__screens-actions'; // parallel reads (tools/parallel-reads)
import {
  OpticalHeader, Menu, ModeRows, r2, money, dateIST, when,
  BILL_STATUS_BADGE, BILL_STATUS_LABEL,
} from '../optical-ui';

// ─────────────────────────────────────────────────────────────────────
function Summary({ s }) {
  const cell = (label, value, sub, color) => (
    <div style={{ flex: '1 1 160px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
      <div style={{ fontSize: 12, color: 'var(--g500)' }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 700, color: color || 'var(--g800)', marginTop: 2 }}>{s ? value : '--'}</div>
      {sub && s && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{sub}</div>}
    </div>
  );
  return (
    <div className="card" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', padding: '12px 4px', marginBottom: 12, gap: '8px 0' }}>
      <div style={{ flex: '1 1 200px', padding: '4px 16px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <span style={{ width: 38, height: 38, borderRadius: '50%', background: '#fde68a', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><i className="ti ti-arrow-down-left" style={{ color: '#b45309', fontSize: 18 }}></i></span>
        <div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Total outstanding</div>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{s ? money(s.outstanding) : '--'}</div>
          {s && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{s.outstandingCount} unpaid / part-paid bill{s.outstandingCount === 1 ? '' : 's'}</div>}
        </div>
      </div>
      {cell('Billed today', s ? money(s.todayBilled) : '', s ? `${s.todayCount} bill${s.todayCount === 1 ? '' : 's'}` : '')}
      {cell('Still due from today', s ? money(s.todayDue || 0) : '', null, s && s.todayDue > 0 ? 'var(--red)' : undefined)}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Edit -- every field inline; Save -> reason popup -> one request.
// ─────────────────────────────────────────────────────────────────────
function BillEdit({ data, refresh, onDone, onCancel }) {
  const sale = data.sale;
  const [date, setDate] = useState(sale.sale_date);
  const [items, setItems] = useState(data.items.map((i) => ({ description: i.description, qty: String(i.qty), unit_price: String(r2(i.unit_price)) })));
  const [discount, setDiscount] = useState(String(r2(sale.discount)));
  const [notes, setNotes] = useState(sale.notes || '');
  const [error, setError] = useState('');
  const [ask, setAsk] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reasonError, setReasonError] = useState('');

  const gross = r2(items.reduce((s, i) => s + (parseInt(i.qty, 10) || 0) * (Number(i.unit_price) || 0), 0));
  const disc = r2(discount);
  const net = r2(gross - disc);
  const paid = r2(sale.paid);
  const belowPaid = net < paid;

  const origItems = JSON.stringify(data.items.map((i) => [i.description, Number(i.qty), r2(i.unit_price)]));
  const nowItems = JSON.stringify(items.map((i) => [i.description.trim(), parseInt(i.qty, 10) || 0, r2(i.unit_price)]));
  const itemsChanged = origItems !== nowItems;
  const anyChange = itemsChanged || disc !== r2(sale.discount) || (notes || '') !== (sale.notes || '') || date !== sale.sale_date;

  const setItem = (i, patch) => setItems((xs) => xs.map((x, j) => (j === i ? { ...x, ...patch } : x)));

  function handleSave() {
    setError('');
    if (items.length === 0) { setError('A bill must keep at least one item. To cancel the whole bill, use Cancel.'); return; }
    for (const i of items) {
      if (!i.description.trim()) { setError('Every item needs a description.'); return; }
      if (!(parseInt(i.qty, 10) >= 1)) { setError(`"${i.description}": quantity must be at least 1.`); return; }
      if (!(Number(i.unit_price) >= 0) || i.unit_price === '') { setError(`"${i.description}": enter a valid price.`); return; }
    }
    if (disc < 0 || disc > gross) { setError(`Discount must be between ₹0 and the items total (${money(gross)}).`); return; }
    if (date > data.today) { setError('A bill cannot be dated in the future.'); return; }
    if (belowPaid) { setError(`The new total (${money(net)}) is less than the ${money(paid)} already paid on this bill. Adjust or remove the payment first, then edit the bill.`); return; }
    setReasonError('');
    setAsk(true);
  }

  async function saveWithReason(reason) {
    const changes = {
      ...(date !== sale.sale_date ? { date } : {}),
      ...(itemsChanged ? { items: items.map((i) => ({ description: i.description.trim(), qty: parseInt(i.qty, 10), unit_price: r2(i.unit_price) })) } : {}),
      discount: disc,
      notes,
    };
    setSaving(true);
    try {
      const res = await saveOpticalBillEdit(sale.id, changes, reason, Number(sale.net), refresh);
      if (res.error) { setReasonError(res.error); return; }
      setAsk(false);
      onDone('Bill updated.', res.refresh);
    } catch {
      setReasonError('Something went wrong saving -- check your connection and try again. Nothing was saved.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', marginBottom: 10 }}>
        <label className="flbl" style={{ margin: 0 }}>Bill date</label>
        <input type="date" className="fi fi-sm" style={{ width: 160 }} value={date} max={data.today} onChange={(e) => setDate(e.target.value)} />
      </div>
      <table className="tbl">
        <thead><tr><th>Item</th><th style={{ width: 70 }}>Qty</th><th style={{ width: 120 }}>Price (₹)</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
        <tbody>
          {items.map((i, idx) => (
            <tr key={idx}>
              <td><input className="fi fi-sm" value={i.description} onChange={(e) => setItem(idx, { description: e.target.value })} /></td>
              <td><input type="number" min="1" className="fi fi-sm" value={i.qty} onChange={(e) => setItem(idx, { qty: e.target.value })} style={{ width: 60 }} /></td>
              <td><input type="number" min="0" step="0.01" className="fi fi-sm" value={i.unit_price} onChange={(e) => setItem(idx, { unit_price: e.target.value })} style={{ width: 105 }} /></td>
              <td style={{ textAlign: 'right' }}>{money((parseInt(i.qty, 10) || 0) * (Number(i.unit_price) || 0))}</td>
              <td><button type="button" className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => setItems((xs) => xs.filter((_, j) => j !== idx))}>Remove</button></td>
            </tr>
          ))}
        </tbody>
      </table>
      <button type="button" className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => setItems((xs) => [...xs, { description: '', qty: '1', unit_price: '' }])}><i className="ti ti-plus"></i> Add item</button>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 10, marginTop: 12 }}>
        <div><label className="flbl">Discount (₹)</label><input type="number" min="0" step="0.01" className="fi" value={discount} onChange={(e) => setDiscount(e.target.value)} /></div>
        <div style={{ gridColumn: 'span 2' }}><label className="flbl">Notes</label><input className="fi" value={notes} onChange={(e) => setNotes(e.target.value)} /></div>
      </div>

      <div style={{ borderTop: '1px solid var(--g200)', marginTop: 12, paddingTop: 8, fontSize: 13, lineHeight: 1.9 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Items total</span><span>{money(gross)}</span></div>
        {disc > 0 && <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Discount</span><span>-{money(disc)}</span></div>}
        <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Bill total</span><span>{net !== r2(sale.net) && <span style={{ color: 'var(--g400)', textDecoration: 'line-through', marginRight: 8 }}>{money(sale.net)}</span>}<strong>{money(net)}</strong></span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Already paid</span><span>{money(paid)}</span></div>
        {belowPaid ? (
          <div className="msg-err" style={{ margin: '6px 0 0' }}><i className="ti ti-alert-triangle"></i> The total can&apos;t be less than the {money(paid)} already paid. Adjust or remove the payment first, then edit the bill.</div>
        ) : net - paid > 0 && (
          <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)', fontWeight: 700 }}><span>Balance due after edit</span><span>{money(net - paid)}</span></div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving || !anyChange || belowPaid}><i className="ti ti-device-floppy"></i> Save changes</button>
        <button type="button" className="btn" onClick={onCancel} disabled={saving}>Discard</button>
      </div>

      <CancelSection data={data} refresh={refresh} onDone={onDone} />

      {ask && (
        <EditReasonModal
          title={`Reason for editing ${sale.sale_number}`}
          summary={`New total ${money(net)}${date !== sale.sale_date ? `, dated ${dateIST(date)}` : ''}. The reason is saved with this change in the bill history.`}
          saving={saving} error={reasonError} onSave={saveWithReason} onCancel={() => { if (!saving) setAsk(false); }}
        />
      )}
    </div>
  );
}

function RecordPayment({ data, refresh, onDone, onCancel }) {
  const due = r2(data.sale.due);
  const [amount, setAmount] = useState(String(due));
  const [modes, setModes] = useState([{ mode: 'Cash', amount: String(due) }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const amt = r2(amount);

  async function save() {
    if (busy) return;
    setError('');
    if (!(amt > 0)) { setError('Enter the amount received.'); return; }
    const sum = r2(modes.reduce((s, m) => s + (Number(m.amount) || 0), 0));
    if (Math.abs(sum - amt) >= 0.01) { setError(`Payment modes (${money(sum)}) must add up to the amount (${money(amt)}).`); return; }
    setBusy(true);
    try {
      const res = await recordOpticalBillPayment(data.sale.id, { amount: amt, modes: modes.map((m) => ({ mode: m.mode, amount: r2(m.amount) })), reference, remarks }, refresh);
      if (res.error) { setError(res.error); return; }
      onDone(`${money(amt)} received${res.receiptNumber ? ` -- receipt ${res.receiptNumber}` : ''}.${amt > due ? ` ${money(amt - due)} over the balance is kept as advance credit.` : ''}`, res.refresh);
    } catch {
      setError('Something went wrong -- check your connection and try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ border: '1.5px solid var(--blue)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontWeight: 700, marginBottom: 8 }}><i className="ti ti-cash" style={{ color: 'var(--blue)' }}></i> Record payment -- balance due {money(due)}</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10, marginBottom: 10 }}>
        <div><label className="flbl">Amount received (₹)</label>
          <input type="number" min="0" step="0.01" className="fi" value={amount} onChange={(e) => { setAmount(e.target.value); if (modes.length === 1) setModes([{ ...modes[0], amount: e.target.value }]); }} /></div>
        <div><label className="flbl">Reference</label><input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4..." /></div>
        <div><label className="flbl">Remarks</label><input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} /></div>
      </div>
      <label className="flbl">Payment mode(s)</label>
      <ModeRows modes={modes} setModes={setModes} total={amt} />
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-primary" disabled={busy} onClick={save}><i className="ti ti-device-floppy"></i> {busy ? 'Saving...' : 'Save payment'}</button>
        <button type="button" className="btn" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// Credit Note (Zoho-style, from the bill) -- reduces what the customer
// owes on this bill. One request; refreshed bill + list come back with it.
function CreditNoteForm({ data, refresh, onDone, onCancel }) {
  const due = r2(data.sale.due);
  const [amount, setAmount] = useState(String(due));
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function save() {
    if (busy) return;
    const amt = r2(amount);
    setError('');
    if (!(amt > 0)) { setError('Enter the credit amount.'); return; }
    if (amt > due) { setError(`A credit note can be at most the balance due (${money(due)}).`); return; }
    if (!reason.trim()) { setError('A reason is required.'); return; }
    if (!approvedBy) { setError('Select who approved it.'); return; }
    setBusy(true);
    try {
      const res = await createOpticalCreditNoteAndRefresh(data.sale.id, { amount: amt, reason: reason.trim(), approvedBy, remarks }, refresh);
      if (res.error) { setError(res.error); return; }
      onDone(`Credit note of ${money(amt)} issued on ${data.sale.sale_number}.`, res.refresh);
    } catch {
      setError('Something went wrong -- check your connection and try again. Nothing was saved.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ border: '1.5px solid var(--teal, #0d9488)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontWeight: 700, marginBottom: 8 }}><i className="ti ti-file-minus" style={{ color: 'var(--teal, #0d9488)' }}></i> Credit note -- balance due {money(due)}</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 10 }}>
        <div><label className="flbl">Credit amount (₹) *</label><input type="number" min="0" step="0.01" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
        <div><label className="flbl">Approved by *</label>
          <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
            <option value="">-- Select --</option>
            {(data.approvers || []).map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` (${a.designation})` : ''}</option>)}
          </select></div>
        <div style={{ gridColumn: '1 / -1' }}><label className="flbl">Reason *</label><input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Frame price adjusted after delivery" /></div>
        <div style={{ gridColumn: '1 / -1' }}><label className="flbl">Remarks</label><input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} /></div>
      </div>
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-primary" disabled={busy} onClick={save}><i className="ti ti-device-floppy"></i> {busy ? 'Saving...' : 'Save credit note'}</button>
        <button type="button" className="btn" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// Inside Edit, at the bottom (like hospital's Cancel / Void section).
// An optical bill can be cancelled only while nothing is paid on it.
function CancelSection({ data, refresh, onDone }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const paid = r2(data.sale.paid);
  async function save() {
    if (busy) return;
    setError('');
    if (!reason.trim()) { setError('Please give a reason.'); return; }
    setBusy(true);
    try {
      const res = await cancelOpticalBill(data.sale.id, reason.trim(), refresh);
      if (res.error) { setError(res.error); return; }
      onDone(`${data.sale.sale_number} cancelled.`, res.refresh);
    } catch {
      setError('Something went wrong -- check your connection and try again. Nothing was changed.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <div style={{ borderTop: '1px solid var(--g200)', marginTop: 16, paddingTop: 12 }}>
      {paid > 0 ? (
        <div style={{ fontSize: 11, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Cancel bill: {money(paid)} has been paid / applied on this bill. Delete or refund those receipts first (Optical Payments).</div>
      ) : !open ? (
        <button type="button" className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => setOpen(true)}><i className="ti ti-x-circle"></i> Cancel this bill</button>
      ) : (
        <div style={{ border: '1.5px solid var(--red-lt, #fecaca)', borderRadius: 10, padding: 12 }}>
          <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 8 }}>The bill stays on record as <strong>Void</strong> and drops out of sales and dues.</div>
          {error && <div className="msg-err">{error}</div>}
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <input className="fi" style={{ flex: 1, minWidth: 200 }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason *" />
            <button type="button" className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} disabled={busy} onClick={save}>{busy ? 'Working...' : 'Confirm cancel'}</button>
            <button type="button" className="btn btn-sm" disabled={busy} onClick={() => setOpen(false)}>Back</button>
          </div>
        </div>
      )}
    </div>
  );
}

function BillHistory({ entries }) {
  if (!entries?.length) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded.</div>;
  const itemsText = (xs) => (xs || []).map((i) => `${i.description} ${i.qty}×${money(i.unit_price)}`).join(', ');
  return (
    <div>
      {entries.map((e) => (
        <div key={e.id} style={{ borderLeft: '3px solid var(--blue-lt)', padding: '6px 0 8px 10px', marginBottom: 8, fontSize: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, flexWrap: 'wrap' }}>
            <strong>Edited</strong><span style={{ color: 'var(--g500)' }}>{when(e.at)} -- {e.by}</span>
          </div>
          {e.reason && <div style={{ color: 'var(--g600)', marginTop: 2 }}>Reason: {e.reason}</div>}
          {e.old_date && e.new_date && e.old_date !== e.new_date && <div style={{ color: 'var(--g600)' }}><i className="ti ti-calendar-event"></i> Date {dateIST(e.old_date)} → <strong>{dateIST(e.new_date)}</strong></div>}
          {JSON.stringify(e.old_items) !== JSON.stringify(e.new_items) && (
            <div style={{ color: 'var(--g500)', marginTop: 2 }}>Items: {itemsText(e.old_items)} → <strong>{itemsText(e.new_items)}</strong></div>
          )}
          {Number(e.old_discount) !== Number(e.new_discount) && <div style={{ color: 'var(--g500)' }}>Discount {money(e.old_discount)} → <strong>{money(e.new_discount)}</strong></div>}
          {Number(e.old_net) !== Number(e.new_net) && <div style={{ color: 'var(--g600)' }}>Total {money(e.old_net)} → <strong>{money(e.new_net)}</strong></div>}
          {(e.old_notes || '') !== (e.new_notes || '') && <div style={{ color: 'var(--g500)' }}>Notes changed</div>}
        </div>
      ))}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Right-hand bill pane
// ─────────────────────────────────────────────────────────────────────
function BillPane({ saleId, preloaded, listArgs, onScreen, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit | pay | cn
  const [showHistory, setShowHistory] = useState(false);
  const [showPayments, setShowPayments] = useState(false);
  const [flash, setFlash] = useState('');
  // Credits available -> Apply credits (customer's unused advance)
  const [applyOpen, setApplyOpen] = useState(false);
  const [applyAmt, setApplyAmt] = useState('');
  const [applying, setApplying] = useState(false);
  const [applyErr, setApplyErr] = useState('');

  const applyPanel = useCallback((d) => {
    if (!d) return;
    if (d.error) { setError(d.error); return; }
    setError(''); setData(d);
  }, []);
  // preloaded: undefined = load it here (one request); null = it is coming
  // with the screen's own load request (deep link); object = use it.
  useEffect(() => { if (preloaded === undefined) getOpticalBillPanel(saleId).then(applyPanel); }, [saleId, applyPanel]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (preloaded) applyPanel(preloaded); }, [preloaded, applyPanel]);

  const refresh = { list: listArgs || null };
  function done(msg, r) {
    setMode('view'); setFlash(msg); setApplyOpen(false);
    if (r?.panel) applyPanel(r.panel);
    if (r?.screen) onScreen(r.screen);
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button type="button" className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!data) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const s = data.sale;
  const cancelled = s.status === 'Cancelled';
  const due = r2(s.due);
  const credit = r2(data.advanceBalance);
  let editBlock = null;
  if (cancelled) editBlock = 'This bill is void.';
  else if (data.dayClosed) editBlock = 'This bill is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (!data.canEdit) editBlock = 'You do not have permission to edit bills.';
  const receipts = data.payments.filter((p) => p.payment_type !== 'refund');
  const refunds = data.payments.filter((p) => p.payment_type === 'refund');

  const action = (key, icon, label, show = true, primary = false) => show && (
    <button type="button" className={mode === key || primary ? 'btn btn-sm btn-primary' : 'btn btn-sm'}
      onClick={() => { setFlash(''); setMode(mode === key ? 'view' : key); }}>
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );

  function openApply() {
    setApplyAmt(String(r2(Math.min(credit, due)))); setApplyErr(''); setApplyOpen(true);
  }
  async function applyCredits() {
    if (applying) return;
    const amt = r2(applyAmt);
    setApplyErr('');
    if (!(amt > 0)) { setApplyErr('Enter an amount to credit.'); return; }
    if (amt > credit) { setApplyErr(`Advance credit only has ${money(credit)}.`); return; }
    if (amt > due) { setApplyErr(`Only ${money(due)} is due on this bill.`); return; }
    setApplying(true);
    try {
      const res = await applyOpticalAdvanceToBill(s, amt, refresh);
      if (res.error) { setApplyErr(res.error); return; }
      done(`${money(amt)} of credit applied to ${s.sale_number}.`, res.refresh);
    } catch {
      setApplyErr('Something went wrong -- check your connection and try again.');
    } finally {
      setApplying(false);
    }
  }

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {s.sale_number} <span className={`badge ${BILL_STATUS_BADGE[s.status] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{BILL_STATUS_LABEL[s.status] || s.status}</span>
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      {/* Action bar -- same as hospital Invoices */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {action('edit', 'ti-edit', 'Edit', !cancelled)}
        {!cancelled && due > 0 && (
          <button type="button" className="btn btn-sm btn-primary" onClick={() => { setFlash(''); setMode(mode === 'pay' ? 'view' : 'pay'); }}><i className="ti ti-cash"></i> Record Payment</button>
        )}
        <a href={`/optical-receipt-print/${s.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-printer"></i> PDF/Print</a>
        {action('cn', 'ti-file-minus', 'Credit Note', !cancelled && due > 0)}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}>
          <i className="ti ti-history"></i> History
        </button>
      </div>
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}><i className="ti ti-circle-check"></i> {flash}</div>}

      {/* Credits available (Zoho-style): the customer's unused advance */}
      {!cancelled && due > 0 && credit > 0 && (
        <div style={{ margin: '12px 16px 0', padding: '10px 12px', borderRadius: 8, background: 'var(--purple-lt)', border: '1px solid #d8b4fe' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13, color: 'var(--purple)' }}>
              <i className="ti ti-wallet"></i> <strong>Credits available: {money(credit)}</strong> <span style={{ color: 'var(--g600)' }}>(Advance credit)</span>
            </span>
            {!applyOpen && (
              <button type="button" className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={openApply}>Apply credits</button>
            )}
          </div>
          {applyOpen && (
            <div style={{ marginTop: 8, background: '#fff', borderRadius: 8, padding: 8 }}>
              <table className="tbl" style={{ margin: 0 }}>
                <thead><tr><th>Credit</th><th style={{ textAlign: 'right' }}>Available</th><th style={{ textAlign: 'right', width: 130 }}>Amount to credit</th></tr></thead>
                <tbody>
                  <tr>
                    <td style={{ fontWeight: 600 }}>Advance credit</td>
                    <td style={{ textAlign: 'right' }}>{money(credit)}</td>
                    <td style={{ textAlign: 'right' }}>
                      <input className="fi fi-sm" type="number" min="0" step="0.01" style={{ width: 115, textAlign: 'right' }} value={applyAmt} onChange={(e) => setApplyAmt(e.target.value)} />
                    </td>
                  </tr>
                </tbody>
              </table>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 12.5 }}>Balance due {money(due)} · applying <strong>{money(r2(applyAmt))}</strong></span>
                <span style={{ flex: 1 }}></span>
                <button type="button" className="btn btn-sm btn-primary" disabled={applying} onClick={applyCredits}>{applying ? 'Applying...' : 'Apply credits'}</button>
                <button type="button" className="btn btn-sm" disabled={applying} onClick={() => setApplyOpen(false)}>Cancel</button>
              </div>
              {applyErr && <div style={{ fontSize: 12, color: 'var(--red)', marginTop: 6 }}>{applyErr}</div>}
            </div>
          )}
        </div>
      )}

      {/* Payments received strip (Zoho-style) */}
      <div style={{ margin: '12px 16px 0', border: '1px solid var(--g200)', borderRadius: 8 }}>
        <button type="button" onClick={() => setShowPayments((v) => !v)} style={{ width: '100%', display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', background: 'transparent', border: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: 'var(--g700)' }}>
          <span>Payments received <span className="badge b-blue" style={{ marginLeft: 4 }}>{receipts.length}</span>{refunds.length > 0 && <span className="badge b-red" style={{ marginLeft: 4 }}>{refunds.length} refund{refunds.length === 1 ? '' : 's'}</span>}</span>
          <i className={`ti ti-chevron-${showPayments ? 'up' : 'down'}`}></i>
        </button>
        {showPayments && (
          <table className="tbl" style={{ margin: 0 }}>
            <thead><tr><th>Date</th><th>Receipt #</th><th>Mode</th><th style={{ textAlign: 'right' }}>Applied</th></tr></thead>
            <tbody>
              {receipts.map((p) => (
                <tr key={p.id}>
                  <td>{dateIST(p.collected_at)}</td>
                  <td>
                    <Link prefetch={false} href={`/optical/payments?paymentId=${p.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{p.receipt_number || 'Advance applied'}</Link>
                    {p.payment_type === 'advance_adjustment' && <span className="badge b-amber" style={{ marginLeft: 6 }}>Advance</span>}
                    {p.payment_type === 'credit_note' && <span className="badge b-teal" style={{ marginLeft: 6 }}>Credit note</span>}
                  </td>
                  <td>{p.modes || '--'}</td>
                  <td style={{ textAlign: 'right' }}>{money(p.amount)}</td>
                </tr>
              ))}
              {refunds.map((r) => (
                <tr key={r.id} style={{ color: 'var(--red)', opacity: r.refundCancelled ? 0.5 : 1 }}>
                  <td>{dateIST(r.collected_at)}</td><td>Refund{r.refundCancelled ? ' (cancelled)' : ''}</td><td>{r.modes || '--'}</td><td style={{ textAlign: 'right' }}>-{money(r.amount)}</td>
                </tr>
              ))}
              {data.payments.length === 0 && <tr><td colSpan={4} style={{ color: 'var(--g400)', textAlign: 'center', padding: 12 }}>No payments yet.</td></tr>}
            </tbody>
          </table>
        )}
      </div>

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (editBlock
          ? <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-lock"></i> {editBlock}</div>
          : <BillEdit data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />)}
        {mode === 'pay' && <div style={{ marginBottom: 14 }}><RecordPayment data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} /></div>}
        {mode === 'cn' && <div style={{ marginBottom: 14 }}><CreditNoteForm data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} /></div>}

        {mode !== 'edit' && (
          <>
            {cancelled && <div className="msg-err" style={{ marginBottom: 12 }}><i className="ti ti-ban"></i> Void{s.cancellation_reason ? ` -- ${s.cancellation_reason}` : ''}.</div>}
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', gap: 12, marginBottom: 12, fontSize: 13 }}>
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 700 }}>BILL TO</div>
                <div style={{ fontWeight: 700, fontSize: 15 }}>{s.customer}</div>
                <div style={{ color: 'var(--g500)' }}>{[s.uhid, s.mobile].filter(Boolean).join(' · ')}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div><span style={{ color: 'var(--g500)' }}>Bill date </span><strong>{dateIST(s.sale_date)}</strong></div>
                {s.notes && <div><span style={{ color: 'var(--g500)' }}>Notes </span>{s.notes}</div>}
              </div>
            </div>

            <table className="tbl">
              <thead><tr><th>#</th><th>Description</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Rate</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {data.items.map((i, idx) => (
                  <tr key={i.id}>
                    <td>{idx + 1}</td>
                    <td>{i.description}</td>
                    <td style={{ textAlign: 'right' }}>{i.qty}</td>
                    <td style={{ textAlign: 'right' }}>{money(i.unit_price)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600 }}>{money(i.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 10 }}>
              <div style={{ minWidth: 240, fontSize: 13, lineHeight: 1.9 }}>
                {Number(s.discount) > 0 && <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Sub total</span><span>{money(s.gross)}</span></div>}
                {Number(s.discount) > 0 && <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}><span>Discount</span><span>-{money(s.discount)}</span></div>}
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span>{money(s.net)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>-{money(s.paid)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 800, borderTop: '1px solid var(--g200)', color: due > 0 ? 'var(--red)' : 'var(--green)' }}><span>Balance due</span><span>{money(due)}</span></div>
              </div>
            </div>
          </>
        )}

        {showHistory && <div style={{ marginTop: 12 }}><div className="card-title" style={{ fontSize: 13 }}>Change history</div><BillHistory entries={data.history} /></div>}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
export default function OpticalBillsScreen() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rows, setRows] = useState([]);
  const [screen, setScreen] = useState({ day: null, summary: null, bookings: [] });
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('saleId') || null);
  // Deep-linked bill: its pane is fetched together with the list (one request).
  const [deepId, setDeepId] = useState(searchParams.get('saleId') || null);
  const [deepPanel, setDeepPanel] = useState(null);
  const deepPending = useRef(!!searchParams.get('saleId'));
  const reqId = useRef(0);
  const needFull = useRef(true);

  function applyScreen(res, full = true) {
    if (full && res) setScreen({ day: res.day || null, summary: res.summary || null, bookings: res.bookings || [] });
    setRows(res?.bills || []);
  }

  // ONE request: list (+ summary, day bar, bookings on first load / after changes).
  const runSearch = useCallback(async () => {
    const my = ++reqId.current;
    setLoading(true);
    const full = needFull.current;
    needFull.current = false;
    const linkId = deepPending.current ? deepId : null;
    const res = await getOpticalBillsScreen({ query, status, from, to, full, saleId: linkId });
    if (my !== reqId.current) { if (full) needFull.current = true; return; }
    if (linkId) { deepPending.current = false; setDeepPanel(res?.panel || { error: 'Bill not found.' }); }
    applyScreen(res, full);
    setLoading(false);
  }, [query, status, from, to]); // eslint-disable-line react-hooks/exhaustive-deps

  const pick = (id) => { setDeepId(null); setSelectedId(id); };

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const split = !!selectedId;
  const totalDue = r2(rows.reduce((s, r) => s + Number(r.due || 0), 0));

  return (
    <div>
      <OpticalHeader title="Optical Bills">
        <Menu label="" icon="ti-dots" items={[
          { href: '/optical/payments', icon: 'ti-receipt-2', label: 'Optical Payments' },
          { href: '/optical/dashboard', icon: 'ti-eyeglass', label: 'Book / Finalize orders' },
        ]} />
      </OpticalHeader>
      <DayOpenBar status={screen.day} note="creating bills or collecting payments is blocked" source="Optical Shop" />
      <Summary s={screen.summary} />

      <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search bill #, customer, mobile or UHID..." />
          <select className="fi" style={{ flex: 1, minWidth: 130 }} value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All statuses</option>
            <option value="Pending">Unpaid</option>
            <option value="Partial">Partially paid</option>
            <option value="Paid">Paid</option>
            <option value="Cancelled">Void</option>
          </select>
          <input type="date" className="fi" style={{ width: 150 }} value={from} onChange={(e) => setFrom(e.target.value)} title="From" />
          <input type="date" className="fi" style={{ width: 150 }} value={to} onChange={(e) => setTo(e.target.value)} title="To" />
        </div>
        <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
          {!query && !status && !from && !to ? 'Latest 100 bills. Search or filter to see older ones. ' : ''}
          {rows.length} shown{totalDue > 0 ? ` · balance due ${money(totalDue)}` : ''}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
        <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
          {split ? (
            <div>
              {rows.map((b) => (
                <div key={b.id} onClick={() => pick(b.id)}
                  style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === b.id ? 'var(--blue-lt)' : 'transparent', opacity: b.status === 'Cancelled' ? 0.55 : 1 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                    <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{b.customer}</span>
                    <span style={{ fontWeight: 700 }}>{money(b.net)}</span>
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{b.sale_number} · {dateIST(b.sale_date)}</div>
                  <div style={{ fontSize: 11, marginTop: 3, display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${BILL_STATUS_BADGE[b.status] || 'b-gray'}`}>{BILL_STATUS_LABEL[b.status] || b.status}</span>
                    {Number(b.due) > 0 && <span style={{ color: 'var(--red)', fontWeight: 600 }}>Due {money(b.due)}</span>}
                  </div>
                </div>
              ))}
              {!loading && rows.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No bills found.</div>}
            </div>
          ) : (
            <table className="tbl">
              <thead><tr><th>Date</th><th>Bill #</th><th>Customer</th><th>Status</th><th style={{ textAlign: 'right' }}>Amount</th><th style={{ textAlign: 'right' }}>Balance due</th><th></th></tr></thead>
              <tbody>
                {rows.map((b) => (
                  <tr key={b.id} onClick={() => pick(b.id)} style={{ cursor: 'pointer', opacity: b.status === 'Cancelled' ? 0.55 : 1 }}>
                    <td>{dateIST(b.sale_date)}</td>
                    <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{b.sale_number}</td>
                    <td style={{ fontWeight: 600 }}>{b.customer} <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{b.uhid || b.mobile || ''}</span></td>
                    <td><span className={`badge ${BILL_STATUS_BADGE[b.status] || 'b-gray'}`}>{BILL_STATUS_LABEL[b.status] || b.status}</span></td>
                    <td style={{ textAlign: 'right' }}>{money(b.net)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: Number(b.due) > 0 ? 'var(--red)' : 'inherit' }}>{money(b.due)}</td>
                    <td onClick={(e) => e.stopPropagation()}>
                      <a href={`/optical-receipt-print/${b.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" title="Print / PDF"><i className="ti ti-printer"></i></a>
                    </td>
                  </tr>
                ))}
                {loading && rows.length === 0 && <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                {!loading && rows.length === 0 && <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No bills found.</td></tr>}
              </tbody>
            </table>
          )}
        </div>

        {split && (
          <div style={{ position: 'sticky', top: 12 }}>
            <BillPane
              key={selectedId}
              saleId={selectedId}
              preloaded={deepId && selectedId === deepId ? deepPanel : undefined}
              listArgs={{ query, status, from, to }}
              onScreen={(res) => { reqId.current += 1; applyScreen(res, true); setLoading(false); }}
              onClose={() => pick(null)}
            />
          </div>
        )}
      </div>
    </div>
  );
}
