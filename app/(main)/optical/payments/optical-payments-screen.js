'use client';

// Optical Payments -- Zoho-style (like hospital Payments): today's summary,
// searchable list of every receipt (payments, advances, advance applied,
// credit notes, refunds), and a receipt pane with Edit / Delete / Refund /
// Print / History. "..." -> Deleted receipts.
//
// ONE request per load / search, ONE per click: opening a receipt is one
// call (ui_optical_payment_detail); Edit -> Save and Delete send back the
// refreshed receipt + list in the same response (screens-actions.js).

import { useState, useEffect, useCallback, useRef } from 'react';
import Link from 'next/link';
import { useSearchParams } from 'next/navigation';
import DayOpenBar from '@/app/components/DayOpenBar';
import EditReasonModal from '@/app/components/EditReasonModal';
import { saveOpticalPaymentEdit, deleteOpticalPayment } from '../screens-actions';
import { getOpticalPaymentsScreen, getOpticalReceiptPanel, getOpticalDeletedReceipts } from '@/lib/rpc-reads/optical__screens-actions'; // parallel reads (tools/parallel-reads)
import { OpticalHeader, ModeRows, r2, money, dateIST, when, PAYMENT_TYPE_LABEL, PAYMENT_TYPE_BADGE } from '../optical-ui';

function Summary({ s }) {
  const modes = s?.byMode ? Object.entries(s.byMode) : [];
  return (
    <div className="card" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', padding: '12px 4px', marginBottom: 12, gap: '8px 0' }}>
      <div style={{ flex: '1 1 200px', padding: '4px 16px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <span style={{ width: 38, height: 38, borderRadius: '50%', background: '#bbf7d0', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><i className="ti ti-arrow-down-right" style={{ color: '#15803d', fontSize: 18 }}></i></span>
        <div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Collected today (net of refunds)</div>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{s ? money(s.todayCollected) : '--'}</div>
          {s && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{s.todayCount} receipt{s.todayCount === 1 ? '' : 's'}</div>}
        </div>
      </div>
      {modes.map(([m, v]) => (
        <div key={m} style={{ flex: '1 1 120px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>{m}</div>
          <div style={{ fontSize: 16, fontWeight: 700, marginTop: 2 }}>{money(v)}</div>
        </div>
      ))}
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

function ReceiptPane({ paymentId, listArgs, onScreen, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit | delete
  const [showHistory, setShowHistory] = useState(false);
  const [flash, setFlash] = useState('');
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;

  const applyDetail = useCallback((d) => {
    if (!d) return;
    if (d.error) { setError(d.error); return; }
    setError(''); setData(d);
  }, []);
  useEffect(() => { getOpticalReceiptPanel(paymentId).then(applyDetail); }, [paymentId, applyDetail]);

  const refresh = { list: listArgs || null };
  function done(msg, r, deleted) {
    setMode('view'); setFlash(msg);
    if (r?.screen) onScreen(r.screen, msg);
    if (deleted) { onCloseRef.current(); return; }
    if (r?.detail) applyDetail(r.detail);
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button type="button" className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!data) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const p = data.payment;
  const editable = ['sale_payment', 'advance'].includes(p.payment_type);
  const deletable = ['sale_payment', 'advance', 'advance_adjustment'].includes(p.payment_type);
  let editBlock = null;
  if (!editable) editBlock = p.payment_type === 'advance_adjustment'
    ? 'This is advance credit applied to a bill, not money received. It can only be removed (Delete) -- the credit goes back to the customer.'
    : 'Credit notes and refunds are managed from their own screens, not edited here.';
  else if (data.dayClosed) editBlock = 'This receipt is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (data.hasActiveRefund) editBlock = 'This receipt has a refund recorded against it. Cancel that refund first (Refund screen).';
  else if (!data.canEdit) editBlock = 'You do not have permission to edit payments.';
  let deleteBlock = null;
  if (!deletable) deleteBlock = 'Credit notes and refunds are managed from their own screens.';
  else if (data.dayClosed) deleteBlock = 'This receipt is from a closed day.';
  else if (data.hasRefundHistory) deleteBlock = 'This receipt has refund history -- use Edit, or the Refund screen.';
  else if (!data.canDelete) deleteBlock = 'You do not have permission to delete payments.';

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {p.receipt_number || 'Advance applied'} <span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>
          {data.dayClosed && <span className="badge b-gray" style={{ marginLeft: 6, verticalAlign: 'middle' }}><i className="ti ti-lock"></i> Day closed</span>}
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        <button type="button" className={mode === 'edit' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => { setFlash(''); setMode(mode === 'edit' ? 'view' : 'edit'); }}><i className="ti ti-edit"></i> Edit</button>
        <button type="button" className={mode === 'delete' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => { setFlash(''); setMode(mode === 'delete' ? 'view' : 'delete'); }}><i className="ti ti-trash"></i> Delete</button>
        {p.receipt_number && <a href={`/optical-payment-receipt-print/${p.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-printer"></i> PDF/Print</a>}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}>
          <i className="ti ti-history"></i> History{data.history?.length ? ` (${data.history.length})` : ''}
        </button>
      </div>
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}>{flash}</div>}

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (editBlock
          ? <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-lock"></i> {editBlock}</div>
          : <ReceiptEdit data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />)}
        {mode === 'delete' && (deleteBlock
          ? <div className="msg-info" style={{ margin: 0 }}><i className="ti ti-lock"></i> {deleteBlock}</div>
          : <ReceiptDelete data={data} refresh={refresh} onDone={done} onCancel={() => setMode('view')} />)}

        {mode === 'view' && (
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(170px, 1fr))', gap: 12, fontSize: 13 }}>
            <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Customer</div><div style={{ fontWeight: 700 }}>{p.customer}</div></div>
            <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Date</div><div style={{ fontWeight: 600 }}>{when(p.collected_at)}</div></div>
            <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Amount</div><div style={{ fontWeight: 800, fontSize: 18 }}>{p.payment_type === 'refund' ? '-' : ''}{money(p.total_amount)}</div></div>
            <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Mode</div><div>{(p.modes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ') || '--'}</div></div>
            {data.sale && <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Bill</div><Link href={`/optical?saleId=${data.sale.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{data.sale.sale_number}</Link></div>}
            {Number(data.credit) > 0 && <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Kept as advance credit</div><div>{money(data.credit)}</div></div>}
            {p.reference && <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Reference</div><div>{p.reference}</div></div>}
            {p.remarks && <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Remarks</div><div>{p.remarks}</div></div>}
            {p.collectedBy && <div><div style={{ fontSize: 11, color: 'var(--g500)' }}>Recorded by</div><div>{p.collectedBy}</div></div>}
          </div>
        )}

        {mode === 'view' && data.refunds?.length > 0 && (
          <div style={{ marginTop: 14 }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Refunds against this receipt</div>
            {data.refunds.map((r) => (
              <div key={r.refund_number} style={{ fontSize: 12, color: r.cancelled_at ? 'var(--g400)' : 'var(--red)' }}>
                {r.refund_number} -- {money(r.amount)} on {dateIST(r.refunded_at)}{r.cancelled_at ? ' (cancelled)' : ''} -- {r.reason}
              </div>
            ))}
          </div>
        )}

        {showHistory && <div style={{ marginTop: 14 }}><div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Change history</div><ReceiptHistory entries={data.history} /></div>}
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
  const [from, setFrom] = useState('');
  const [to, setTo] = useState('');
  const [rows, setRows] = useState([]);
  const [screen, setScreen] = useState({ day: null, summary: null });
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('paymentId') || null);
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
    const res = await getOpticalPaymentsScreen({ query, type, from, to, full });
    if (my !== reqId.current) { if (full) needFull.current = true; return; }
    applyScreen(res, full);
    setLoading(false);
  }, [query, type, from, to]);

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const split = !!selectedId;

  return (
    <div>
      <OpticalHeader title="Optical Payments" />
      <DayOpenBar status={screen.day} note="collecting payments is blocked" source="Optical Shop" />
      {flash && <div className="msg-success" style={{ marginBottom: 12 }}>{flash}</div>}

      {view === 'deleted' ? <DeletedReceipts onBack={() => setView('list')} /> : (
        <>
          <Summary s={screen.summary} />
          <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search receipt #, bill #, customer or reference..." />
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
              <button type="button" className="btn btn-sm" onClick={() => { setSelectedId(null); setView('deleted'); }}><i className="ti ti-trash"></i> Deleted receipts</button>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
              {!query && !type && !from && !to ? 'Latest 100 receipts. Search or filter to see older ones. ' : ''}{rows.length} shown
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
            <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
              {split ? (
                <div>
                  {rows.map((p) => (
                    <div key={p.id} onClick={() => setSelectedId(p.id)}
                      style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === p.id ? 'var(--blue-lt)' : 'transparent', opacity: p.refundCancelled ? 0.5 : 1 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                        <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{p.customer}</span>
                        <span style={{ fontWeight: 700, color: p.payment_type === 'refund' ? 'var(--red)' : undefined }}>{p.payment_type === 'refund' ? '-' : ''}{money(p.amount)}</span>
                      </div>
                      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{p.receipt_number || 'Advance applied'} · {dateIST(p.collected_at)}{p.sale_number ? ` · ${p.sale_number}` : ''}</div>
                      <div style={{ fontSize: 11, marginTop: 3 }}><span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span></div>
                    </div>
                  ))}
                  {!loading && rows.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No receipts found.</div>}
                </div>
              ) : (
                <table className="tbl">
                  <thead><tr><th>Date</th><th>Receipt #</th><th>Customer</th><th>Bill #</th><th>Type</th><th>Mode</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
                  <tbody>
                    {rows.map((p) => (
                      <tr key={p.id} onClick={() => setSelectedId(p.id)} style={{ cursor: 'pointer', opacity: p.refundCancelled ? 0.5 : 1 }}>
                        <td>{dateIST(p.collected_at)}</td>
                        <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{p.receipt_number || '--'}</td>
                        <td style={{ fontWeight: 600 }}>{p.customer}</td>
                        <td>{p.sale_number || '--'}</td>
                        <td><span className={`badge ${PAYMENT_TYPE_BADGE[p.payment_type] || 'b-gray'}`}>{PAYMENT_TYPE_LABEL[p.payment_type] || p.payment_type}</span>{p.refundCancelled && <span style={{ fontSize: 10, marginLeft: 4 }}>(cancelled)</span>}</td>
                        <td style={{ fontSize: 12 }}>{p.modes || '--'}</td>
                        <td style={{ textAlign: 'right', fontWeight: 600, color: p.payment_type === 'refund' ? 'var(--red)' : undefined }}>{p.payment_type === 'refund' ? '-' : ''}{money(p.amount)}</td>
                      </tr>
                    ))}
                    {loading && rows.length === 0 && <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                    {!loading && rows.length === 0 && <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>}
                  </tbody>
                </table>
              )}
            </div>

            {split && (
              <div style={{ position: 'sticky', top: 12 }}>
                <ReceiptPane
                  key={selectedId}
                  paymentId={selectedId}
                  listArgs={{ query, type, from, to }}
                  onScreen={(res, msg) => { reqId.current += 1; applyScreen(res, true); setLoading(false); if (msg) setFlash(msg); }}
                  onClose={() => setSelectedId(null)}
                />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
