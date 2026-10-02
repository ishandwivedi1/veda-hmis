'use client';

// Optical Payments -- laid out exactly like hospital Payments (Oct 2026):
// "+ New Payment" and "..." (Deleted Receipts) at the top, today's summary
// (Collected today, Cash, UPI, Card / Other, Transactions), the receipts
// list, and a receipt pane with Edit (Delete inside, as on hospital) /
// PDF-Print / Refund / History.
//
// ONE request per load / search, ONE per click: opening a receipt is one
// call (ui_optical_payment_detail); Edit -> Save and Delete send back the
// refreshed receipt + list in the same response (screens-actions.js).

import { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import DayOpenBar from '@/app/components/DayOpenBar';
import EditReasonModal from '@/app/components/EditReasonModal';
import { saveOpticalPaymentEdit, deleteOpticalPayment, refundOpticalReceiptAndRefresh } from '../screens-actions';
import { getOpticalPaymentsScreen, getOpticalReceiptPanel, getOpticalDeletedReceipts } from '@/lib/rpc-reads/optical__screens-actions'; // parallel reads (tools/parallel-reads)
import { OpticalHeader, Menu, ModeRows, PAYMENT_MODES, r2, money, dateIST, when, PAYMENT_TYPE_LABEL, PAYMENT_TYPE_BADGE } from '../optical-ui';

const timeIST = (d) => new Date(d).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
// "Cash 500.00, UPI 100.00" -> "Cash + UPI"
const modeNames = (txt) => [...new Set(String(txt || '').split(',').map((x) => x.trim().split(' ')[0]).filter(Boolean))].join(' + ') || '--';

// Same cells as hospital Payments (from the screen's single load request).
function Summary({ s }) {
  const byMode = s?.byMode || {};
  const other = r2(Object.entries(byMode).filter(([m]) => m !== 'Cash' && m !== 'UPI').reduce((t, [, v]) => t + Number(v), 0));
  const cell = (label, value) => (
    <div style={{ flex: '1 1 140px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
      <div style={{ fontSize: 12, color: 'var(--g500)' }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 700, color: 'var(--g800)', marginTop: 2 }}>{s ? value : '--'}</div>
    </div>
  );
  return (
    <div className="card" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', padding: '12px 4px', marginBottom: 12, gap: '8px 0' }}>
      <div style={{ flex: '1 1 180px', padding: '4px 16px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <span style={{ width: 38, height: 38, borderRadius: '50%', background: 'var(--green-lt, #dcfce7)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><i className="ti ti-arrow-down-left" style={{ color: 'var(--green)', fontSize: 18 }}></i></span>
        <div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Collected today</div>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{s ? money(s.todayCollected) : '--'}</div>
        </div>
      </div>
      {cell('Cash', money(byMode.Cash || 0))}
      {cell('UPI', money(byMode.UPI || 0))}
      {cell('Card / Other', money(other))}
      {cell('Transactions', s ? String(s.todayCount) : '--')}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
function ReceiptEdit({ data, refresh, onDone, onCancel }) {
  const p = data.payment;
  const [amount, setAmount] = useState(String(r2(p.total_amount)));
  const [date, setDate] = useState(data.paymentDate);
  const [modes, setModes] = useState((p.modes || []).map((m) => ({ mode: m.mode, amount: String(r2(m.amount)) })));
  const [reference, setReference] = useState(p.reference || '');
  const [remarks, setRemarks] = useState(p.remarks || '');
  const [error, setError] = useState('');
  const [ask, setAsk] = useState(false);
  const [saving, setSaving] = useState(false);
  const [reasonError, setReasonError] = useState('');
  const amt = r2(amount);

  function handleSave() {
    setError('');
    if (!(amt > 0)) { setError('Amount must be greater than zero. To remove the receipt, use Delete.'); return; }
    if (modes.length === 0 || modes.some((m) => !(Number(m.amount) > 0))) { setError('Every payment mode needs an amount above zero (remove empty rows).'); return; }
    const sum = r2(modes.reduce((s, m) => s + (Number(m.amount) || 0), 0));
    if (Math.abs(sum - amt) >= 0.01) { setError(`Payment modes (${money(sum)}) must add up to the amount (${money(amt)}).`); return; }
    if (date > data.today) { setError('A payment cannot be dated in the future.'); return; }
    setReasonError('');
    setAsk(true);
  }

  async function saveWithReason(reason) {
    setSaving(true);
    try {
      const res = await saveOpticalPaymentEdit({
        paymentId: p.id, amount: amt, date: date !== data.paymentDate ? date : null,
        modes: modes.map((m) => ({ mode: m.mode, amount: r2(m.amount) })), reference, remarks, reason,
        expectedAmount: Number(p.total_amount),
      }, refresh);
      if (res.error) { setReasonError(res.error); return; }
      setAsk(false);
      onDone(`${p.receipt_number || 'Receipt'} updated.`, res.refresh);
    } catch {
      setReasonError('Something went wrong saving -- check your connection and try again. Nothing was saved.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10, marginBottom: 10 }}>
        <div><label className="flbl">Amount received (₹)</label>
          <input type="number" min="0" step="0.01" className="fi" value={amount} onChange={(e) => { setAmount(e.target.value); if (modes.length === 1) setModes([{ ...modes[0], amount: e.target.value }]); }} /></div>
        <div><label className="flbl">Date received</label><input type="date" className="fi" value={date} max={data.today} onChange={(e) => setDate(e.target.value)} /></div>
        <div><label className="flbl">Reference</label><input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} /></div>
        <div><label className="flbl">Remarks</label><input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} /></div>
      </div>
      <label className="flbl">Payment mode(s)</label>
      <ModeRows modes={modes} setModes={setModes} total={amt} />
      {p.payment_type === 'sale_payment' && data.sale && (
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 8 }}>
          Applied to {data.sale.sale_number}. Anything above that bill&apos;s balance stays with the customer as advance credit.
        </div>
      )}
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}><i className="ti ti-device-floppy"></i> Save changes</button>
        <button type="button" className="btn btn-sm" onClick={onCancel} disabled={saving}>Discard</button>
      </div>
      {ask && (
        <EditReasonModal
          title={`Reason for editing ${p.receipt_number || 'this receipt'}`}
          summary={`Amount ${money(amt)}${date !== data.paymentDate ? `, dated ${dateIST(date)}` : ''}. The reason is saved with this change in the receipt history.`}
          saving={saving} error={reasonError} onSave={saveWithReason} onCancel={() => { if (!saving) setAsk(false); }}
        />
      )}
    </div>
  );
}

function ReceiptDelete({ data, refresh, onDone, onCancel }) {
  const p = data.payment;
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  async function save() {
    if (busy) return;
    setError('');
    if (!reason.trim()) { setError('Please give a reason for deleting.'); return; }
    setBusy(true);
    try {
      const res = await deleteOpticalPayment(p.id, reason.trim(), Number(p.total_amount), refresh);
      if (res.error) { setError(res.error); return; }
      onDone(p.payment_type === 'advance_adjustment'
        ? `Advance application removed. ${money(p.total_amount)} is back in the customer's advance.`
        : `${p.receipt_number} deleted. It is kept under "Deleted receipts".`, res.refresh, true);
    } catch {
      setError('Something went wrong -- check your connection and try again. Nothing was changed.');
    } finally {
      setBusy(false);
    }
  }
  return (
    <div style={{ border: '1.5px solid var(--red-lt, #fecaca)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 8, lineHeight: 1.5 }}>
        {p.payment_type === 'advance_adjustment'
          ? <>Removes this application: {money(p.total_amount)} goes back to the customer&apos;s advance and the bill becomes unpaid by that much.</>
          : <>The receipt is removed from all registers and reports; any bill it paid becomes unpaid again. A full copy is kept under <strong>Deleted receipts</strong>.</>}
      </div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <input className="fi" style={{ flex: 1, minWidth: 200 }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason *" />
        <button type="button" className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} disabled={busy} onClick={save}>{busy ? 'Working...' : 'Confirm delete'}</button>
        <button type="button" className="btn btn-sm" disabled={busy} onClick={onCancel}>Back</button>
      </div>
    </div>
  );
}

function ReceiptHistory({ entries }) {
  if (!entries?.length) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded.</div>;
  const modesText = (ms) => (ms || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ');
  return (
    <div>
      {entries.map((e) => (
        <div key={e.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '5px 0', borderBottom: '1px solid var(--g200)' }}>
          <div><strong>Edited</strong> -- {when(e.at)} -- {e.by}</div>
          {e.reason && <div style={{ color: 'var(--g500)' }}>Reason: {e.reason}</div>}
          <div style={{ color: 'var(--g500)' }}>
            {e.old_amount != null && e.new_amount != null && <>Amount {money(e.old_amount)} → <strong>{money(e.new_amount)}</strong>. </>}
            {e.old_date && e.new_date && e.old_date !== e.new_date && <>Date {dateIST(e.old_date)} → <strong>{dateIST(e.new_date)}</strong>. </>}
            {JSON.stringify(e.old_modes) !== JSON.stringify(e.new_modes) && <>Modes {modesText(e.old_modes)} → <strong>{modesText(e.new_modes)}</strong>. </>}
            {(e.old_reference || '') !== (e.new_reference || '') && <>Reference changed. </>}
          </div>
        </div>
      ))}
    </div>
  );
}

// Refund (like hospital Payments -> Refund) -- one request; the refreshed
// receipt + list come back with it. A bill payment is refunded against this
// receipt; an advance receipt is refunded from the customer's unused advance.
function RefundForm({ data, refresh, onDone, onCancel }) {
  const p = data.payment;
  const isAdvance = p.payment_type === 'advance';
  const refunded = r2((data.refunds || []).filter((r) => !r.cancelled_at).reduce((t, r) => t + Number(r.amount), 0));
  const max = isAdvance ? r2(Math.min(Number(data.advanceBalance) || 0, Number(p.total_amount))) : r2(Number(p.total_amount) - refunded);
  const [amount, setAmount] = useState(String(max > 0 ? max : ''));
  const [refundMode, setRefundMode] = useState('Cash');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  async function save() {
    if (busy) return;
    const amt = r2(amount);
    setError('');
    if (!(amt > 0)) { setError('Enter the refund amount.'); return; }
    if (amt > max) { setError(isAdvance ? `Only ${money(max)} of this customer's advance is unused and can be refunded.` : `At most ${money(max)} of this receipt can still be refunded.`); return; }
    if (!reason.trim()) { setError('A reason is required.'); return; }
    if (!approvedBy) { setError('Select who approved it.'); return; }
    setBusy(true);
    try {
      const res = await refundOpticalReceiptAndRefresh(p, { amount: amt, reason: reason.trim(), refundMode, approvedBy }, refresh);
      if (res.error) { setError(res.error); return; }
      onDone(`Refund ${res.refund?.refund_number || ''} of ${money(amt)} recorded.`, res.refresh);
    } catch {
      setError('Something went wrong -- check your connection and try again. Nothing was saved.');
    } finally {
      setBusy(false);
    }
  }

  if (max <= 0) {
    return <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-info-circle"></i> {isAdvance ? "Nothing to refund -- this customer's advance has already been used or refunded." : 'This receipt has already been refunded in full.'}</div>;
  }
  return (
    <div style={{ border: '1.5px solid var(--red-lt, #fecaca)', borderRadius: 10, padding: 12 }}>
      <div style={{ fontWeight: 700, marginBottom: 8 }}><i className="ti ti-rotate-clockwise" style={{ color: 'var(--red)' }}></i> Refund -- up to {money(max)}{isAdvance ? ' (unused advance)' : ''}</div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 10 }}>
        <div><label className="flbl">Refund amount (₹) *</label><input type="number" min="0" step="0.01" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} /></div>
        <div><label className="flbl">Refund mode</label>
          <select className="fi" value={refundMode} onChange={(e) => setRefundMode(e.target.value)}>{PAYMENT_MODES.map((m) => <option key={m}>{m}</option>)}</select></div>
        <div><label className="flbl">Approved by *</label>
          <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
            <option value="">-- Select --</option>
            {(data.approvers || []).map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` (${a.designation})` : ''}</option>)}
          </select></div>
        <div style={{ gridColumn: '1 / -1' }}><label className="flbl">Reason *</label><input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Order cancelled, customer asked for money back" /></div>
      </div>
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} disabled={busy} onClick={save}>{busy ? 'Saving...' : 'Save refund'}</button>
        <button type="button" className="btn btn-sm" disabled={busy} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

function ReceiptPane({ paymentId, preloaded, listArgs, onScreen, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit | refund
  const [showDelete, setShowDelete] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const [flash, setFlash] = useState('');
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const applyDetail = useCallback((d) => {
    if (!d) return;
    if (d.error) { setError(d.error); return; }
    setError(''); setData(d);
  }, []);
  // preloaded: undefined = load it here (one request); null = it is coming
  // with the screen's own load request (deep link); object = use it.
  useEffect(() => { if (preloaded === undefined) getOpticalReceiptPanel(paymentId).then(applyDetail); }, [paymentId, applyDetail]); // eslint-disable-line react-hooks/exhaustive-deps
  useEffect(() => { if (preloaded) applyDetail(preloaded); }, [preloaded, applyDetail]);

  const refresh = { list: listArgs || null };
  function done(msg, r, deleted) {
    setMode('view'); setShowDelete(false); setFlash(msg);
    if (r?.screen) onScreen(r.screen, msg);
    if (deleted) { onCloseRef.current(); return; }
    if (r?.detail) applyDetail(r.detail);
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button type="button" className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!data) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const p = data.payment;
  const isRefund = p.payment_type === 'refund';
  const editable = ['sale_payment', 'advance'].includes(p.payment_type);
  const deletable = ['sale_payment', 'advance', 'advance_adjustment'].includes(p.payment_type);
  let editBlock = null;
  if (!editable) editBlock = p.payment_type === 'advance_adjustment'
    ? 'This is advance credit applied to a bill, not money received -- it can only be removed (below); the credit goes back to the customer.'
    : 'Credit notes and refunds cannot be edited.';
  else if (data.dayClosed) editBlock = 'This receipt is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (data.hasActiveRefund) editBlock = 'This receipt has a refund recorded against it, so it cannot be edited.';
  else if (!data.canEdit) editBlock = 'You do not have permission to edit payments.';
  let deleteBlock = null;
  if (!deletable) deleteBlock = null;
  else if (data.dayClosed) deleteBlock = 'This receipt is from a closed day.';
  else if (data.hasRefundHistory) deleteBlock = 'This receipt has refund history, so it cannot be deleted.';
  else if (!data.canDelete) deleteBlock = 'You do not have permission to delete payments.';
  const showEdit = editable || deletable;
  const applied = data.sale ? r2(Number(p.total_amount) - Number(data.credit || 0)) : 0;

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {p.receipt_number || 'Advance applied'} <span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>
          {data.dayClosed && <span className="badge b-gray" style={{ marginLeft: 6, verticalAlign: 'middle' }}><i className="ti ti-lock"></i> Day closed</span>}
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      {/* Action bar -- same as hospital Payments */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {showEdit && (
          <button type="button" className={mode === 'edit' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => { setFlash(''); setShowDelete(false); setMode(mode === 'edit' ? 'view' : 'edit'); }}><i className="ti ti-edit"></i> Edit</button>
        )}
        {p.receipt_number && <a href={`/optical-payment-receipt-print/${p.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-printer"></i> PDF/Print</a>}
        {['sale_payment', 'advance'].includes(p.payment_type) && (
          <button type="button" className={mode === 'refund' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => { setFlash(''); setMode(mode === 'refund' ? 'view' : 'refund'); }}><i className="ti ti-rotate-clockwise"></i> Refund</button>
        )}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}>
          <i className="ti ti-history"></i> History{data.history?.length ? ` (${data.history.length})` : ''}
        </button>
      </div>
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}><i className="ti ti-circle-check"></i> {flash}</div>}

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (
          <div>
            {editBlock
              ? <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-lock"></i> {editBlock}</div>
              : <ReceiptEdit data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />}
            {deletable && (
              <div style={{ borderTop: '1px solid var(--g200)', marginTop: 16, paddingTop: 12 }}>
                {deleteBlock ? (
                  <div style={{ fontSize: 11, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Delete: {deleteBlock}</div>
                ) : !showDelete ? (
                  <button type="button" className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => setShowDelete(true)}>
                    <i className="ti ti-trash"></i> {p.payment_type === 'advance_adjustment' ? 'Remove this credit application' : 'Delete this payment'}
                  </button>
                ) : (
                  <ReceiptDelete data={data} refresh={refresh} onDone={done} onCancel={() => setShowDelete(false)} />
                )}
              </div>
            )}
          </div>
        )}

        {mode === 'refund' && <RefundForm data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />}

        {mode === 'view' && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 200px', gap: 16, alignItems: 'start' }}>
              <table className="tbl" style={{ fontSize: 13 }}>
                <tbody>
                  <tr><td style={{ color: 'var(--g500)', width: 130 }}>Payment date</td><td style={{ fontWeight: 600 }}>{dateIST(p.collected_at)} <span style={{ color: 'var(--g400)', fontWeight: 400 }}>{timeIST(p.collected_at)}</span></td></tr>
                  <tr><td style={{ color: 'var(--g500)' }}>Customer</td><td style={{ fontWeight: 600 }}>{p.customer}</td></tr>
                  <tr><td style={{ color: 'var(--g500)' }}>Mode</td><td>{(p.modes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(' + ') || '--'}</td></tr>
                  {p.reference && <tr><td style={{ color: 'var(--g500)' }}>Reference</td><td>{p.reference}</td></tr>}
                  {p.remarks && <tr><td style={{ color: 'var(--g500)' }}>Remarks</td><td>{p.remarks}</td></tr>}
                  {p.collectedBy && <tr><td style={{ color: 'var(--g500)' }}>Collected by</td><td>{p.collectedBy}</td></tr>}
                </tbody>
              </table>
              <div style={{ background: isRefund ? 'var(--red)' : 'var(--green)', color: '#fff', borderRadius: 10, padding: '16px 12px', textAlign: 'center' }}>
                <div style={{ fontSize: 12, opacity: 0.9 }}>{isRefund ? 'Amount Refunded' : 'Amount Received'}</div>
                <div style={{ fontSize: 22, fontWeight: 700, marginTop: 4 }}>{money(p.total_amount)}</div>
              </div>
            </div>

            {data.sale && !isRefund && (
              <>
                <div className="card-title" style={{ marginTop: 16, fontSize: 13 }}>Payment for</div>
                <table className="tbl">
                  <thead><tr><th>Bill #</th><th style={{ textAlign: 'right' }}>Amount applied</th></tr></thead>
                  <tbody>
                    <tr>
                      <td><Link href={`/optical?saleId=${data.sale.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{data.sale.sale_number}</Link></td>
                      <td style={{ textAlign: 'right' }}>{money(applied)}</td>
                    </tr>
                  </tbody>
                </table>
              </>
            )}
            {isRefund && data.sale && (
              <div style={{ marginTop: 12, fontSize: 12.5 }}>Refund against bill <Link href={`/optical?saleId=${data.sale.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{data.sale.sale_number}</Link></div>
            )}

            {['advance', 'sale_payment'].includes(p.payment_type) && Number(data.credit) > 0 && (
              <div style={{ marginTop: 12, fontSize: 12.5, background: 'var(--purple-lt)', color: 'var(--purple)', borderRadius: 8, padding: '8px 12px' }}>
                <i className="ti ti-wallet"></i> {money(data.credit)} of this receipt went to the customer&apos;s advance credit.
                Customer&apos;s unused credit now: <strong>{money(data.advanceBalance)}</strong>.
              </div>
            )}

            {data.refunds?.length > 0 && (
              <div style={{ marginTop: 14 }}>
                <div className="card-title" style={{ fontSize: 13 }}>Refunds against this receipt</div>
                {data.refunds.map((r) => (
                  <div key={r.refund_number} style={{ fontSize: 12, color: r.cancelled_at ? 'var(--g400)' : 'var(--red)' }}>
                    {r.refund_number} -- {money(r.amount)} on {dateIST(r.refunded_at)}{r.cancelled_at ? ' (cancelled)' : ''} -- {r.reason}
                  </div>
                ))}
              </div>
            )}
          </>
        )}

        {showHistory && <div style={{ marginTop: 16 }}><div className="card-title" style={{ fontSize: 13 }}>Change history</div><ReceiptHistory entries={data.history} /></div>}
      </div>
    </div>
  );
}

function DeletedReceipts({ onBack }) {
  const [rows, setRows] = useState(null);
  useEffect(() => { getOpticalDeletedReceipts().then((r) => setRows(r.rows || [])); }, []);
  return (
    <div className="card">
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
        <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i> Deleted receipts</div>
        <button type="button" className="btn btn-sm" onClick={onBack}><i className="ti ti-arrow-left"></i> Back to payments</button>
      </div>
      {!rows ? <div style={{ color: 'var(--g400)' }}>Loading...</div> : rows.length === 0 ? <div style={{ color: 'var(--g400)' }}>No deleted receipts.</div> : (
        <table className="tbl">
          <thead><tr><th>Receipt</th><th>Type</th><th>Customer</th><th>Bill</th><th style={{ textAlign: 'right' }}>Amount</th><th>Received</th><th>Deleted</th><th>Reason</th></tr></thead>
          <tbody>
            {rows.map((r) => (
              <tr key={r.id}>
                <td style={{ fontWeight: 600 }}>{r.receipt_number || '--'}</td>
                <td>{PAYMENT_TYPE_LABEL[r.payment_type] || r.payment_type}</td>
                <td>{r.customer || '--'}</td>
                <td>{r.sale_number || '--'}</td>
                <td style={{ textAlign: 'right' }}>{money(r.amount)}</td>
                <td>{r.collected_at ? dateIST(r.collected_at) : '--'}</td>
                <td>{when(r.deleted_at)} -- {r.by}</td>
                <td>{r.reason}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
export default function OpticalPaymentsScreen() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState('');
  const [type, setType] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rows, setRows] = useState([]);
  const [screen, setScreen] = useState({ day: null, summary: null });
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('paymentId') || null);
  // Deep-linked receipt: its pane is fetched together with the list (one request).
  const [deepId, setDeepId] = useState(searchParams.get('paymentId') || null);
  const [deepDetail, setDeepDetail] = useState(null);
  const deepPending = useRef(!!searchParams.get('paymentId'));
  const [view, setView] = useState('list'); // list | deleted
  const [flash, setFlash] = useState('');
  const reqId = useRef(0);
  const needFull = useRef(true);

  function applyScreen(res, full = true) {
    if (full && res) setScreen({ day: res.day || null, summary: res.summary || null });
    setRows(res?.payments || []);
  }

  const runSearch = useCallback(async () => {
    const my = ++reqId.current;
    setLoading(true);
    const full = needFull.current;
    needFull.current = false;
    const linkId = deepPending.current ? deepId : null;
    const res = await getOpticalPaymentsScreen({ query, type, from, to, full, paymentId: linkId });
    if (my !== reqId.current) { if (full) needFull.current = true; return; }
    if (linkId) { deepPending.current = false; setDeepDetail(res?.detail || { error: 'Receipt not found.' }); }
    applyScreen(res, full);
    setLoading(false);
  }, [query, type, from, to]); // eslint-disable-line react-hooks/exhaustive-deps

  const pick = (id) => { setDeepId(null); setSelectedId(id); };

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const split = !!selectedId;
  // Mode filter works on the loaded list (no extra request).
  const list = rows.filter((p) => !modeFilter || modeNames(p.modes).split(' + ').includes(modeFilter));
  const isNeg = (p) => p.payment_type === 'refund';
  const totalShown = r2(list.reduce((t, p) => t + (['sale_payment', 'advance', 'refund'].includes(p.payment_type) && !p.refundCancelled ? (isNeg(p) ? -1 : 1) * Number(p.amount) : 0), 0));

  return (
    <div>
      <OpticalHeader title={view === 'deleted' ? (
        <span style={{ display: 'inline-flex', alignItems: 'center', gap: 10 }}>
          <button type="button" className="btn btn-sm" onClick={() => setView('list')} title="Back to payments"><i className="ti ti-arrow-left"></i></button>
          Deleted Receipts
        </span>
      ) : 'Optical Payments'}>
        <Link href="/optical/payments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-plus"></i> New Payment</Link>
        <Menu label="" icon="ti-dots" items={[
          { href: '/optical', icon: 'ti-file-invoice', label: 'Optical Bills' },
          { icon: 'ti-trash', label: 'Deleted Receipts', onClick: () => { pick(null); setView('deleted'); } },
        ]} />
      </OpticalHeader>
      {flash && <div className="msg-success" style={{ marginBottom: 10 }}><i className="ti ti-circle-check"></i> {flash}</div>}
      <DayOpenBar status={screen.day} note="payments are blocked" source="Optical Shop" />

      {view === 'deleted' ? <DeletedReceipts onBack={() => setView('list')} /> : (
        <>
          <Summary s={screen.summary} />
          <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search receipt #, bill #, customer or reference..." />
              <select className="fi" style={{ flex: 1, minWidth: 120 }} value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
                <option value="">All modes</option>
                {PAYMENT_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
              <select className="fi" style={{ flex: 1, minWidth: 140 }} value={type} onChange={(e) => setType(e.target.value)}>
                <option value="">All types</option>
                <option value="sale_payment">Payments</option>
                <option value="advance">Advances</option>
                <option value="advance_adjustment">Advance applied</option>
                <option value="credit_note">Credit notes</option>
                <option value="refund">Refunds</option>
              </select>
              <input type="date" className="fi" style={{ width: 150 }} value={from} onChange={(e) => setFrom(e.target.value)} title="From" />
              <input type="date" className="fi" style={{ width: 150 }} value={to} onChange={(e) => setTo(e.target.value)} title="To" />
            </div>
            <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
              {!query && !type && !from && !to ? 'Latest 100 receipts. Search or pick dates to see older ones. ' : ''}{list.length} shown{totalShown ? ` · net received ${money(totalShown)}` : ''}
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
            <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
              {split ? (
                <div>
                  {list.map((p) => (
                    <div key={p.id} onClick={() => pick(p.id)}
                      style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === p.id ? 'var(--blue-lt)' : 'transparent', opacity: p.refundCancelled ? 0.5 : 1 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                        <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.customer}</span>
                        <span style={{ fontWeight: 700, color: p.payment_type === 'refund' ? 'var(--red)' : undefined }}>{p.payment_type === 'refund' ? '-' : ''}{money(p.amount)}</span>
                      </div>
                      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{p.receipt_number || 'Advance applied'} · {dateIST(p.collected_at)}{p.sale_number ? ` · ${p.sale_number}` : ''}</div>
                      <div style={{ fontSize: 11, marginTop: 3, display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>
                        <span style={{ color: 'var(--g600)', fontWeight: 600 }}>{modeNames(p.modes)}</span>
                      </div>
                    </div>
                  ))}
                  {!loading && list.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No receipts found.</div>}
                </div>
              ) : (
                <table className="tbl">
                  <thead><tr><th>Date</th><th>Receipt #</th><th>Reference</th><th>Customer</th><th>Bill #</th><th>Mode</th><th>Type</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                  <tbody>
                    {list.map((p) => (
                      <tr key={p.id} onClick={() => pick(p.id)} style={{ cursor: 'pointer', opacity: p.refundCancelled ? 0.55 : 1 }}>
                        <td>{dateIST(p.collected_at)}</td>
                        <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{p.receipt_number || '--'}</td>
                        <td style={{ fontSize: 12, color: 'var(--g600)', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.reference || ''}</td>
                        <td style={{ fontWeight: 600 }}>{p.customer}</td>
                        <td style={{ fontSize: 12 }}>{p.sale_number || '--'}</td>
                        <td>{modeNames(p.modes)}</td>
                        <td>
                          <span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>
                          {p.refundCancelled && <div style={{ fontSize: 10, color: 'var(--red)', fontWeight: 700 }}>CANCELLED</div>}
                        </td>
                        <td style={{ textAlign: 'right', fontWeight: 600, color: isNeg(p) ? 'var(--red)' : 'inherit' }}>{isNeg(p) ? '-' : ''}{money(p.amount)}</td>
                      </tr>
                    ))}
                    {loading && list.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                    {!loading && list.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>}
                  </tbody>
                </table>
              )}
            </div>

            {split && (
              <div style={{ position: 'sticky', top: 12 }}>
                <ReceiptPane
                  key={selectedId}
                  paymentId={selectedId}
                  preloaded={deepId && selectedId === deepId ? deepDetail : undefined}
                  listArgs={{ query, type, from, to }}
                  onScreen={(res, msg) => { reqId.current += 1; applyScreen(res, true); setLoading(false); if (msg) setFlash(msg); }}
                  onClose={() => pick(null)}
                />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
