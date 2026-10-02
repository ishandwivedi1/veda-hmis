'use client';

// Optical Bills -- Zoho-style (like hospital Invoices): summary strip,
// searchable list, and a bill pane on the right
// with Edit / Record Payment / Apply Advance / Credit Note / Print / Cancel /
// History.
//
// ONE request per screen load / search, ONE per click: opening a bill is one
// call (ui_optical_bill_panel); every save sends back the refreshed bill and
// list in the same response (screens-actions.js) -- no reloads afterwards.

import { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import DayOpenBar from '@/app/components/DayOpenBar';
import EditReasonModal from '@/app/components/EditReasonModal';
import { saveOpticalBillEdit, recordOpticalBillPayment, applyOpticalAdvanceToBill, cancelOpticalBill } from '../screens-actions';
import { getOpticalBillsScreen, getOpticalBillPanel } from '@/lib/rpc-reads/optical__screens-actions'; // parallel reads (tools/parallel-reads)
import {
  OpticalHeader, ModeRows, r2, money, dateIST, when,
  BILL_STATUS_BADGE, BILL_STATUS_LABEL, PAYMENT_TYPE_LABEL, PAYMENT_TYPE_BADGE,
} from '../optical-ui';

// ─────────────────────────────────────────────────────────────────────
function Summary({ s }) {
  const cell = (label, value, sub, color) => (
    <div style={{ flex: '1 1 150px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
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
      {cell('Billed this month', s ? money(s.monthBilled) : '')}
      {cell('Advance held', s ? money(s.advanceHeld) : '', 'customer credit on file')}
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

function ApplyAdvance({ data, refresh, onDone, onCancel }) {
  const max = r2(Math.min(data.advanceBalance, data.sale.due));
  const [amount, setAmount] = useState(String(max));
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function save() {
    if (busy) return;
    const amt = r2(amount);
    setError('');
    if (!(amt > 0)) { setError('Enter an amount.'); return; }
    if (amt > max) { setError(`At most ${money(max)} can be applied (advance ${money(data.advanceBalance)}, due ${money(data.sale.due)}).`); return; }
    setBusy(true);
    try {
      const res = await applyOpticalAdvanceToBill(data.sale, amt, refresh);
      if (res.error) { setError(res.error); return; }
      onDone(`${money(amt)} of advance applied.`, res.refresh);
    } catch {
      setError('Something went wrong -- check your connection and try again.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ border: '1.5px solid var(--amber)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontWeight: 700, marginBottom: 8 }}><i className="ti ti-wallet" style={{ color: 'var(--amber)' }}></i> Apply advance -- {money(data.advanceBalance)} on file, {money(data.sale.due)} due</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
        <input type="number" min="0" step="0.01" className="fi" style={{ width: 160 }} value={amount} onChange={(e) => setAmount(e.target.value)} />
        <button type="button" className="btn btn-primary" disabled={busy} onClick={save}>{busy ? 'Applying...' : 'Apply'}</button>
        <button type="button" className="btn" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

function CancelBill({ data, refresh, onDone, onCancel }) {
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
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
    <div style={{ border: '1.5px solid var(--red-lt, #fecaca)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 8 }}>The bill stays on record as <strong>Cancelled</strong> and drops out of sales and dues.</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <input className="fi" style={{ flex: 1, minWidth: 200 }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason *" />
        <button type="button" className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} disabled={busy} onClick={save}>{busy ? 'Working...' : 'Confirm cancel'}</button>
        <button type="button" className="btn btn-sm" disabled={busy} onClick={onCancel}>Back</button>
      </div>
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
function BillPane({ saleId, listArgs, onScreen, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit | pay | advance | cancel
  const [showHistory, setShowHistory] = useState(false);
  const [flash, setFlash] = useState('');

  const applyPanel = useCallback((d) => {
    if (!d) return;
    if (d.error) { setError(d.error); return; }
    setError(''); setData(d);
  }, []);
  useEffect(() => { getOpticalBillPanel(saleId).then(applyPanel); }, [saleId, applyPanel]);

  const refresh = { list: listArgs || null };
  function done(msg, r) {
    setMode('view'); setFlash(msg);
    if (r?.panel) applyPanel(r.panel);
    if (r?.screen) onScreen(r.screen);
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button type="button" className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!data) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const s = data.sale;
  const cancelled = s.status === 'Cancelled';
  const due = r2(s.due);
  let editBlock = null;
  if (cancelled) editBlock = 'This bill is cancelled.';
  else if (data.dayClosed) editBlock = 'This bill is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (!data.canEdit) editBlock = 'You do not have permission to edit bills.';

  const action = (key, icon, label, show = true, disabledTitle = null) => show && (
    <button type="button" className={mode === key ? 'btn btn-sm btn-primary' : 'btn btn-sm'} title={disabledTitle || ''}
      onClick={() => { setFlash(''); setMode(mode === key ? 'view' : key); }}>
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {s.sale_number} <span className={`badge ${BILL_STATUS_BADGE[s.status] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{BILL_STATUS_LABEL[s.status] || s.status}</span>
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {action('edit', 'ti-edit', 'Edit', !cancelled)}
        {action('pay', 'ti-cash', 'Record Payment', !cancelled && due > 0)}
        {action('advance', 'ti-wallet', `Apply Advance (${money(data.advanceBalance)})`, !cancelled && due > 0 && data.advanceBalance > 0)}
        <a href={`/optical-receipt-print/${s.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-printer"></i> PDF/Print</a>
        {action('cancel', 'ti-x-circle', 'Cancel bill', !cancelled && r2(s.paid) === 0)}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}>
          <i className="ti ti-history"></i> History{data.history?.length ? ` (${data.history.length})` : ''}
        </button>
      </div>
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}>{flash}</div>}

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (editBlock
          ? <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-lock"></i> {editBlock}</div>
          : <BillEdit data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />)}
        {mode === 'pay' && <RecordPayment data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />}
        {mode === 'advance' && <ApplyAdvance data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />}
        {mode === 'cancel' && <CancelBill data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />}

        {mode !== 'edit' && (
          <div style={{ marginTop: mode === 'view' ? 0 : 14 }}>
            {cancelled && <div className="msg-err" style={{ marginBottom: 12 }}><i className="ti ti-ban"></i> Cancelled{s.cancellation_reason ? ` -- ${s.cancellation_reason}` : ''}.</div>}
            <div style={{ display: 'flex', justifyContent: 'space-between', gap: 12, flexWrap: 'wrap', marginBottom: 12, fontSize: 13 }}>
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>Bill to</div>
                <div style={{ fontWeight: 700 }}>{s.customer}</div>
                <div style={{ fontSize: 12, color: 'var(--g500)' }}>{[s.uhid, s.mobile].filter(Boolean).join(' · ')}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>Bill date</div>
                <div style={{ fontWeight: 600 }}>{dateIST(s.sale_date)}</div>
              </div>
            </div>

            <table className="tbl">
              <thead><tr><th>Item</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Price</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {data.items.map((i) => (
                  <tr key={i.id}><td>{i.description}</td><td style={{ textAlign: 'right' }}>{i.qty}</td><td style={{ textAlign: 'right' }}>{money(i.unit_price)}</td><td style={{ textAlign: 'right' }}>{money(i.amount)}</td></tr>
                ))}
              </tbody>
            </table>
            <div style={{ marginLeft: 'auto', maxWidth: 300, fontSize: 13, lineHeight: 1.9, marginTop: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Items total</span><span>{money(s.gross)}</span></div>
              {Number(s.discount) > 0 && <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Discount</span><span>-{money(s.discount)}</span></div>}
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span>{money(s.net)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>{money(s.paid)}</span></div>
              {due > 0 && <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)', fontWeight: 700 }}><span>Balance due</span><span>{money(due)}</span></div>}
            </div>
            {s.notes && <div style={{ fontSize: 12, color: 'var(--g600)', marginTop: 8 }}><i className="ti ti-note"></i> {s.notes}</div>}

            <div style={{ marginTop: 14 }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Payments</div>
              {data.payments.length === 0 ? <div style={{ fontSize: 12, color: 'var(--g400)' }}>No payments yet.</div> : (
                <table className="tbl">
                  <thead><tr><th>Date</th><th>Receipt</th><th>Type</th><th>Mode</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                  <tbody>
                    {data.payments.map((p) => (
                      <tr key={p.id} style={{ color: p.payment_type === 'refund' ? 'var(--red)' : undefined, opacity: p.refundCancelled ? 0.5 : 1 }}>
                        <td>{dateIST(p.collected_at)}</td>
                        <td>{p.receipt_number ? <Link href={`/optical/payments?paymentId=${p.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{p.receipt_number}</Link> : '--'}</td>
                        <td><span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>{p.refundCancelled && <span style={{ fontSize: 10, marginLeft: 4 }}>(cancelled)</span>}</td>
                        <td style={{ fontSize: 12 }}>{p.modes || '--'}</td>
                        <td style={{ textAlign: 'right' }}>{p.payment_type === 'refund' ? '-' : ''}{money(p.amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </div>
          </div>
        )}

        {showHistory && <div style={{ marginTop: 14 }}><div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Change history</div><BillHistory entries={data.history} /></div>}
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
    const res = await getOpticalBillsScreen({ query, status, from, to, full });
    if (my !== reqId.current) { if (full) needFull.current = true; return; }
    applyScreen(res, full);
    setLoading(false);
  }, [query, status, from, to]);

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const split = !!selectedId;
  const totalDue = r2(rows.reduce((s, r) => s + Number(r.due || 0), 0));

  return (
    <div>
      <OpticalHeader title="Optical Bills" />
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
            <option value="Cancelled">Cancelled</option>
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
                <div key={b.id} onClick={() => setSelectedId(b.id)}
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
              <thead><tr><th>Date</th><th>Bill #</th><th>Customer</th><th>Status</th><th style={{ textAlign: 'right' }}>Amount</th><th style={{ textAlign: 'right' }}>Balance due</th></tr></thead>
              <tbody>
                {rows.map((b) => (
                  <tr key={b.id} onClick={() => setSelectedId(b.id)} style={{ cursor: 'pointer', opacity: b.status === 'Cancelled' ? 0.55 : 1 }}>
                    <td>{dateIST(b.sale_date)}</td>
                    <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{b.sale_number}</td>
                    <td style={{ fontWeight: 600 }}>{b.customer} <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{b.uhid || b.mobile || ''}</span></td>
                    <td><span className={`badge ${BILL_STATUS_BADGE[b.status] || 'b-gray'}`}>{BILL_STATUS_LABEL[b.status] || b.status}</span></td>
                    <td style={{ textAlign: 'right' }}>{money(b.net)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: Number(b.due) > 0 ? 'var(--red)' : 'inherit' }}>{money(b.due)}</td>
                  </tr>
                ))}
                {loading && rows.length === 0 && <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                {!loading && rows.length === 0 && <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No bills found.</td></tr>}
              </tbody>
            </table>
          )}
        </div>

        {split && (
          <div style={{ position: 'sticky', top: 12 }}>
            <BillPane
              key={selectedId}
              saleId={selectedId}
              listArgs={{ query, status, from, to }}
              onScreen={(res) => { reqId.current += 1; applyScreen(res, true); setLoading(false); }}
              onClose={() => setSelectedId(null)}
            />
          </div>
        )}
      </div>
    </div>
  );
}
