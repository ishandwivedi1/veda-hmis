'use client';

// Payments Received -- Zoho Books-style register.
//   * Full list when nothing is selected; click a row and it becomes a
//     split view: compact list on the left, the receipt on the right with
//     an action bar (Edit, Print, WhatsApp, Refund, History).
//   * Edit uses the shared PaymentEditPanel (edit_payment/delete_payment).
//   * On a CLOSED day, an Administrator gets "Correct Mode" instead:
//     re-split Cash/UPI/... without reopening the day; the database moves
//     the same amounts in that day's reconciliation (Expected and Actual).

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { openPrintPopup } from '@/lib/printPopup';
import { resendPaymentReceiptWhatsApp } from '../actions';
import { getReceivedPaymentDetail } from '@/lib/rpc-reads/payments__received-actions'; // parallel reads (tools/parallel-reads)
import { getPaymentsScreenData } from '@/lib/rpc-reads/payments__received-actions'; // parallel reads (tools/parallel-reads)
import DayOpenBar from '@/app/components/DayOpenBar';
import { correctClosedDayModes } from '../received-actions';
import PaymentEditPanel from '../payment-edit-panel';
import DeletedPayments from '../deleted-payments';

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Advance applied', credit_note: 'Credit Note', refund: 'Refund' };
const TYPE_BADGE = { invoice_payment: 'b-blue', advance: 'b-purple', advance_adjustment: 'b-amber', credit_note: 'b-teal', refund: 'b-red' };

const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' });
const timeIST = (d) => new Date(d).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
const when = (d) => new Date(d).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

const modesText = (r) => (r.payment_modes || []).map((m) => m.mode).filter((v, i, a) => a.indexOf(v) === i).join(' + ') || '--';
const invoicesText = (r) => (r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ');
const isNegative = (r) => r.payment_type === 'refund';

const HISTORY_LABEL = {
  payment_edited: 'Edited',
  older_edit: 'Edited',
  payment_modes_corrected_closed_day: 'Mode corrected (closed day)',
  payment_deleted: 'Deleted',
  credit_application_removed: 'Credit application removed',
};

// ─────────────────────────────────────────────────────────────────────
// Closed-day mode correction (Administrator only)
// ─────────────────────────────────────────────────────────────────────
function ClosedDayModeFix({ detail, onDone, onCancel }) {
  const p = detail.payment;
  const total = r2(p.total_amount);
  const [rows, setRows] = useState((p.payment_modes || []).map((m) => ({ mode: m.mode, amount: String(r2(m.amount)) })));
  const [reference, setReference] = useState(p.reference || '');
  const [remarks, setRemarks] = useState(p.remarks || '');
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const sum = r2(rows.reduce((s, r) => s + (Number(r.amount) || 0), 0));
  const oldBy = {};
  (p.payment_modes || []).forEach((m) => { oldBy[m.mode] = r2((oldBy[m.mode] || 0) + Number(m.amount)); });
  const newBy = {};
  rows.forEach((r) => { if (r.mode) newBy[r.mode] = r2((newBy[r.mode] || 0) + (Number(r.amount) || 0)); });
  const moves = [...new Set([...Object.keys(oldBy), ...Object.keys(newBy)])]
    .map((mode) => ({ mode, delta: r2((newBy[mode] || 0) - (oldBy[mode] || 0)) }))
    .filter((m) => m.delta !== 0);
  const cashMove = moves.find((m) => m.mode === 'Cash')?.delta || 0;

  function setRow(i, field, val) { setRows((rs) => rs.map((r, j) => (j === i ? { ...r, [field]: val } : r))); }

  async function save() {
    if (saving) return;
    setError('');
    if (sum !== total) { setError(`Modes must add up to ${money(total)} (now ${money(sum)}).`); return; }
    if (!reason.trim()) { setError('Enter a reason.'); return; }
    setSaving(true);
    const res = await correctClosedDayModes({
      paymentId: p.id,
      modes: rows.filter((r) => Number(r.amount) > 0).map((r) => ({ mode: r.mode, amount: r2(r.amount) })),
      reference, remarks, reason, expectedAmount: total,
    });
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    const moved = Object.entries(res.result?.moved || {}).map(([m, d]) => `${m} ${d > 0 ? '+' : ''}${money(d)}`).join(', ');
    onDone(`${p.receipt_number} corrected on closed day ${dateIST(p.collected_at)}${moved ? ` -- reconciliation moved: ${moved}` : ''}.`);
  }

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--amber-lt, #fff7e6)', color: 'var(--amber, #b45309)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-lock"></i> <strong>{dateIST(p.collected_at)} is closed.</strong> You can change how this {money(total)} was split between modes (e.g. Cash → UPI) without reopening the day.
        The same amounts move in that day&apos;s reconciliation (Expected and Actual together), so its totals stay the same. To change the amount, date or invoices, reopen the day in Cash Management.
      </div>

      {rows.map((r, i) => (
        <div key={i} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
          <select className="fi" style={{ flex: 1 }} value={r.mode} onChange={(e) => setRow(i, 'mode', e.target.value)}>
            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
          <input className="fi" style={{ width: 140 }} type="number" min="0" step="0.01" value={r.amount} onChange={(e) => setRow(i, 'amount', e.target.value)} />
          <button type="button" className="btn btn-sm" disabled={rows.length === 1} onClick={() => setRows((rs) => rs.filter((_, j) => j !== i))} title="Remove"><i className="ti ti-x"></i></button>
        </div>
      ))}
      <button type="button" className="btn btn-sm" onClick={() => setRows((rs) => [...rs, { mode: 'UPI', amount: '' }])}><i className="ti ti-plus"></i> Split into another mode</button>
      <div style={{ fontSize: 12, margin: '8px 0', color: sum === total ? 'var(--green)' : 'var(--red)', fontWeight: 600 }}>
        Total {money(sum)} of {money(total)}
      </div>

      {moves.length > 0 && sum === total && (
        <div style={{ fontSize: 12, background: 'var(--g50)', borderRadius: 8, padding: '8px 10px', marginBottom: 8 }}>
          <strong>Reconciliation for {dateIST(p.collected_at)} will change:</strong>{' '}
          {moves.map((m) => `${m.mode} ${m.delta > 0 ? '+' : ''}${money(m.delta)}`).join(', ')}
        </div>
      )}
      {cashMove !== 0 && sum === total && (
        <div className="msg-err" style={{ fontSize: 12 }}>
          <i className="ti ti-alert-triangle"></i> Cash changes by {money(cashMove)}. The <strong>Cash Handed Over</strong> recorded for that day
          ({detail.cashHandedOver != null ? money(detail.cashHandedOver) : 'not recorded'}) is <strong>not</strong> changed -- check it matches what was really handed over.
        </div>
      )}

      <label className="flbl">Reference</label>
      <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} />
      <label className="flbl">Remarks</label>
      <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} />
      <label className="flbl">Reason for correction *</label>
      <input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Patient paid by UPI, entered as Cash by mistake" />

      {error && <div className="msg-err" style={{ marginTop: 8 }}>{error}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button type="button" className="btn btn-primary" disabled={saving} onClick={save}>{saving ? 'Saving...' : 'Save correction'}</button>
        <button type="button" className="btn" disabled={saving} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Right-hand detail pane
// ─────────────────────────────────────────────────────────────────────
function PaymentDetail({ paymentId, onChanged, onClose }) {
  const [detail, setDetail] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit | fix
  const [showHistory, setShowHistory] = useState(false);
  const [wa, setWa] = useState({ status: '', msg: '' });

  const hadDetail = useRef(false);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const load = useCallback(async () => {
    setError('');
    const d = await getReceivedPaymentDetail(paymentId);
    if (d?.error) {
      // Receipt was just deleted from the Edit panel -- close the pane.
      if (hadDetail.current) { onCloseRef.current(); return; }
      setError(d.error); return;
    }
    hadDetail.current = true;
    setDetail(d);
  }, [paymentId]);
  useEffect(() => { load(); }, [load]);

  async function sendWhatsApp() {
    if (wa.status === 'sending') return;
    setWa({ status: 'sending', msg: '' });
    const res = await resendPaymentReceiptWhatsApp(paymentId);
    if (res.error) setWa({ status: 'error', msg: res.error });
    else if (res.warning) setWa({ status: 'warning', msg: res.warning });
    else setWa({ status: 'sent', msg: 'Sent on WhatsApp.' });
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!detail) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const p = detail.payment;
  const isRefund = p.payment_type === 'refund';
  const typeLabel = TYPE_LABEL[p.payment_type] || 'Payment';
  const showEdit = detail.canEdit || detail.canDelete;
  const editNote = !detail.canEdit && !detail.canCorrectClosedDay ? detail.editBlock : null;

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      {/* Header */}
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {p.receipt_number || 'Receipt'} <span className={`badge ${TYPE_BADGE[p.payment_type] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{typeLabel}</span>
          {detail.dayClosed && <span className="badge b-gray" style={{ marginLeft: 6, verticalAlign: 'middle' }}><i className="ti ti-lock"></i> Day closed</span>}
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      {/* Action bar */}
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {showEdit && (
          <button type="button" className={mode === 'edit' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode(mode === 'edit' ? 'view' : 'edit')}>
            <i className="ti ti-edit"></i> Edit
          </button>
        )}
        {detail.canCorrectClosedDay && (
          <button type="button" className={mode === 'fix' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode(mode === 'fix' ? 'view' : 'fix')}>
            <i className="ti ti-arrows-exchange"></i> Correct Mode (closed day)
          </button>
        )}
        <button type="button" className="btn btn-sm" onClick={() => openPrintPopup(`/receipt-print/${p.id}`)}><i className="ti ti-printer"></i> PDF/Print</button>
        {!isRefund && (
          <button type="button" className="btn btn-sm" disabled={wa.status === 'sending'} onClick={sendWhatsApp}>
            <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i> {wa.status === 'sending' ? 'Sending...' : 'WhatsApp'}
          </button>
        )}
        {['invoice_payment', 'advance'].includes(p.payment_type) && (
          <Link href={`/payments/refund?patientId=${p.patient_id}&paymentId=${p.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-rotate-clockwise"></i> Refund</Link>
        )}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}>
          <i className="ti ti-history"></i> History{detail.history?.length ? ` (${detail.history.length})` : ''}
        </button>
      </div>
      {wa.msg && <div className={wa.status === 'error' ? 'msg-err' : 'msg-success'} style={{ margin: '8px 16px 0' }}>{wa.msg}</div>}

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (
          <PaymentEditPanel
            key={`edit-${p.id}`}
            paymentId={p.id}
            onClose={() => setMode('view')}
            onChanged={(msg) => { setMode('view'); onChanged(msg); load(); }}
          />
        )}

        {mode === 'fix' && (
          <ClosedDayModeFix
            detail={detail}
            onCancel={() => setMode('view')}
            onDone={(msg) => { setMode('view'); onChanged(msg); load(); }}
          />
        )}

        {mode === 'view' && (
          <>
            {editNote && (
              <div style={{ fontSize: 12, color: 'var(--g500)', background: 'var(--g50)', borderRadius: 8, padding: '6px 10px', marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> {editNote}
              </div>
            )}

            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) 200px', gap: 16, alignItems: 'start' }}>
              <table className="tbl" style={{ fontSize: 13 }}>
                <tbody>
                  <tr><td style={{ color: 'var(--g500)', width: 130 }}>Payment date</td><td style={{ fontWeight: 600 }}>{dateIST(p.collected_at)} <span style={{ color: 'var(--g400)', fontWeight: 400 }}>{timeIST(p.collected_at)}</span></td></tr>
                  <tr><td style={{ color: 'var(--g500)' }}>Patient</td><td style={{ fontWeight: 600 }}>{formatPatientName(p.patients)} <span style={{ color: 'var(--g400)', fontWeight: 400 }}>{p.patients?.uhid}</span></td></tr>
                  <tr><td style={{ color: 'var(--g500)' }}>Mode</td><td>{(p.payment_modes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(' + ') || '--'}</td></tr>
                  {p.reference && <tr><td style={{ color: 'var(--g500)' }}>Reference</td><td>{p.reference}</td></tr>}
                  {p.remarks && <tr><td style={{ color: 'var(--g500)' }}>Remarks</td><td>{p.remarks}</td></tr>}
                  {detail.collectedBy && <tr><td style={{ color: 'var(--g500)' }}>Collected by</td><td>{detail.collectedBy}</td></tr>}
                </tbody>
              </table>
              <div style={{ background: isRefund ? 'var(--red)' : 'var(--green)', color: '#fff', borderRadius: 10, padding: '16px 12px', textAlign: 'center' }}>
                <div style={{ fontSize: 12, opacity: 0.9 }}>{isRefund ? 'Amount Refunded' : 'Amount Received'}</div>
                <div style={{ fontSize: 22, fontWeight: 700, marginTop: 4 }}>{money(p.total_amount)}</div>
              </div>
            </div>

            {(p.payment_allocations || []).length > 0 && (
              <>
                <div className="card-title" style={{ marginTop: 16, fontSize: 13 }}>Payment for</div>
                <table className="tbl">
                  <thead><tr><th>Invoice #</th><th style={{ textAlign: 'right' }}>Amount applied</th></tr></thead>
                  <tbody>
                    {p.payment_allocations.map((a) => (
                      <tr key={a.invoice_id}>
                        <td><Link href={`/billing?invoiceId=${a.invoice_id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{a.invoices?.invoice_number || 'Invoice'}</Link></td>
                        <td style={{ textAlign: 'right' }}>{money(a.amount)}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </>
            )}

            {['advance', 'invoice_payment'].includes(p.payment_type) && Number(detail.paymentCredit) > 0 && (
              <div style={{ marginTop: 12, fontSize: 12.5, background: 'var(--purple-lt)', color: 'var(--purple)', borderRadius: 8, padding: '8px 12px' }}>
                <i className="ti ti-wallet"></i> {money(detail.paymentCredit)} of this receipt went to the patient&apos;s advance credit.
                Patient&apos;s unused credit now: <strong>{money(detail.patientCredit)}</strong>.
              </div>
            )}
          </>
        )}

        {showHistory && (
          <div style={{ marginTop: 16 }}>
            <div className="card-title" style={{ fontSize: 13 }}>Change history</div>
            {(detail.history || []).length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded.</div>}
            {(detail.history || []).map((e) => (
              <div key={e.id} style={{ fontSize: 12, color: 'var(--g600)', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                <div><strong>{HISTORY_LABEL[e.action] || e.action}</strong> -- {when(e.at)} -- {e.by}</div>
                {e.reason && <div style={{ color: 'var(--g500)' }}>Reason: {e.reason}</div>}
                {e.after?.modes && <div style={{ color: 'var(--g500)' }}>Modes after: {e.after.modes.map((m) => `${m.mode} ${money(m.amount)}`).join(', ')}</div>}
                {e.older && <div style={{ color: 'var(--g500)' }}>{(e.older.oldModes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ')} → {(e.older.newModes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ')}</div>}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// "..." menu. As in Zoho: "+ New Payment" is the only way to start money
// in (the form lists the patient's unpaid bills; with none, it's saved as
// an advance). Refund lives on a payment, Credit Note on an invoice.
// Each item opens the existing form full-width with a "<- Payments" link
// back (same routes as before, so links from other screens keep working).
// ─────────────────────────────────────────────────────────────────────

function Menu({ label, icon, primary, items, align = 'right' }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const close = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button type="button" className={primary ? 'btn btn-primary' : 'btn'} onClick={() => setOpen((v) => !v)}>
        {icon && <i className={`ti ${icon}`}></i>} {label} {primary && <i className="ti ti-chevron-down" style={{ fontSize: 12 }}></i>}
      </button>
      {open && (
        <div style={{ position: 'absolute', [align]: 0, top: 'calc(100% + 4px)', background: '#fff', border: '1px solid var(--g200)', borderRadius: 10, boxShadow: 'var(--shadow-lg, 0 8px 24px rgba(0,0,0,.12))', minWidth: 230, zIndex: 50, padding: 4 }}>
          {items.map((it) => (it.href ? (
            <Link key={it.label} href={it.href} onClick={() => setOpen(false)} style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '8px 10px', borderRadius: 8, textDecoration: 'none', color: 'var(--g800)' }}
              onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--g50)'; }} onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; }}>
              <i className={`ti ${it.icon}`} style={{ color: 'var(--blue)', fontSize: 16 }}></i>
              <span><span style={{ fontWeight: 600, fontSize: 13 }}>{it.label}</span>{it.hint && <span style={{ display: 'block', fontSize: 11, color: 'var(--g500)' }}>{it.hint}</span>}</span>
            </Link>
          ) : (
            <button key={it.label} type="button" onClick={() => { setOpen(false); it.onClick(); }} style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '8px 10px', borderRadius: 8, width: '100%', border: 'none', background: 'transparent', cursor: 'pointer', color: 'var(--g800)', textAlign: 'left' }}>
              <i className={`ti ${it.icon}`} style={{ color: 'var(--blue)', fontSize: 16 }}></i>
              <span style={{ fontWeight: 600, fontSize: 13 }}>{it.label}</span>
            </button>
          )))}
        </div>
      )}
    </div>
  );
}

// Data comes from the screen's single load request (no request of its own).
function TodaySummary({ s }) {
  const byMode = s?.byMode || {};
  const other = r2(Object.entries(byMode).filter(([m]) => m !== 'Cash' && m !== 'UPI').reduce((a, [, v]) => a + Number(v), 0));
  const cell = (label, value, color) => (
    <div style={{ flex: '1 1 140px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
      <div style={{ fontSize: 12, color: 'var(--g500)' }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 700, color: color || 'var(--g800)', marginTop: 2 }}>{s ? value : '--'}</div>
    </div>
  );
  return (
    <div className="card" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', padding: '12px 4px', marginBottom: 12, gap: '8px 0' }}>
      <div style={{ flex: '1 1 180px', padding: '4px 16px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <span style={{ width: 38, height: 38, borderRadius: '50%', background: 'var(--green-lt, #dcfce7)', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><i className="ti ti-arrow-down-left" style={{ color: 'var(--green)', fontSize: 18 }}></i></span>
        <div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Collected today</div>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{s ? money(s.total) : '--'}</div>
        </div>
      </div>
      {cell('Cash', money(byMode.Cash || 0))}
      {cell('UPI', money(byMode.UPI || 0))}
      {cell('Card / Other', money(other))}
      {cell('Transactions', s ? String(s.count) : '--')}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────
export default function PaymentsReceived() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState([]);
  const [summary, setSummary] = useState(null);
  const [day, setDay] = useState(null);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('paymentId') || null);
  const [view, setView] = useState('register'); // register | deleted
  const [flash, setFlash] = useState('');
  const reqId = useRef(0);

  const runSearch = useCallback(async () => {
    const my = ++reqId.current;
    setLoading(true);
    // ONE request: list + today's summary + day status, in parallel server-side.
    const res = await getPaymentsScreenData({ query, mode: modeFilter, dateFrom, dateTo });
    const data = res?.receipts;
    if (my === reqId.current) { setSummary(res?.summary || null); setDay(res?.day || null); }
    if (my !== reqId.current) return; // a newer search already started
    setRows(data || []);
    setLoading(false);
  }, [query, modeFilter, dateFrom, dateTo]);

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const list = rows.filter((r) => !typeFilter || r.payment_type === typeFilter);
  const split = !!selectedId && view === 'register';

  const totalShown = r2(list.reduce((s, r) => s + (isNegative(r) ? -1 : 1) * (['invoice_payment', 'advance', 'refund'].includes(r.payment_type) ? Number(r.total_amount) : 0), 0));

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, gap: 8, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 22, fontWeight: 700, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
          {view === 'deleted' ? (
            <>
              <button type="button" className="btn btn-sm" onClick={() => setView('register')} title="Back to payments"><i className="ti ti-arrow-left"></i></button>
              Deleted Receipts
            </>
          ) : 'Payments'}
        </div>
        <div style={{ display: 'flex', gap: 6 }}>
          <Link href="/payments/collect" className="btn btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-plus"></i> New Payment</Link>
          <Menu
            label=""
            icon="ti-dots"
            items={[
              { href: '/payments/reports', icon: 'ti-file-report', label: 'Reports' },
              { href: '/payments/ledger', icon: 'ti-book', label: 'Patient Ledger' },
              { icon: 'ti-trash', label: 'Deleted Receipts', onClick: () => { setView('deleted'); setSelectedId(null); } },
            ]}
          />
        </div>
      </div>

      {flash && <div className="msg-success" style={{ marginBottom: 10 }}><i className="ti ti-circle-check"></i> {flash}</div>}

      <DayOpenBar status={day} note="payments are blocked" source="Payments" />
      {view === 'register' && <TodaySummary s={summary} />}

      {view === 'deleted' && <DeletedPayments />}

      {view === 'register' && (
        <>
          <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search receipt #, patient, UHID..." />
              <select className="fi" style={{ flex: 1, minWidth: 120 }} value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
                <option value="">All modes</option>
                {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
              <select className="fi" style={{ flex: 1, minWidth: 130 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                <option value="">All types</option>
                {Object.entries(TYPE_LABEL).map(([k, v]) => <option key={k} value={k}>{v}</option>)}
              </select>
              <input type="date" className="fi" style={{ width: 150 }} value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} title="From" />
              <input type="date" className="fi" style={{ width: 150 }} value={dateTo} onChange={(e) => setDateTo(e.target.value)} title="To" />
            </div>
            <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
              {!query && !dateFrom && !dateTo ? 'Latest 50 receipts. Search or pick dates to see older ones. ' : ''}
              {list.length} shown{totalShown ? ` · net received ${money(totalShown)}` : ''}
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
            <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
              {split ? (
                // Compact list (split view)
                <div>
                  {list.map((r) => (
                    <div
                      key={r.id}
                      onClick={() => setSelectedId(r.id)}
                      style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === r.id ? 'var(--blue-lt)' : 'transparent', opacity: r.cancelledRefundReason !== undefined ? 0.55 : 1 }}
                    >
                      <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                        <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{formatPatientName(r.patients)}</span>
                        <span style={{ fontWeight: 700, color: isNegative(r) ? 'var(--red)' : 'inherit' }}>{isNegative(r) ? '-' : ''}{money(r.total_amount)}</span>
                      </div>
                      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{r.receipt_number} · {dateIST(r.collected_at)}</div>
                      <div style={{ fontSize: 11, marginTop: 3, display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || 'Payment'}</span>
                        <span style={{ color: 'var(--g600)', fontWeight: 600 }}>{modesText(r)}</span>
                      </div>
                    </div>
                  ))}
                  {!loading && list.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No receipts found.</div>}
                </div>
              ) : (
                // Full table
                <table className="tbl">
                  <thead>
                    <tr><th>Date</th><th>Receipt #</th><th>Reference</th><th>Patient</th><th>Invoice #</th><th>Mode</th><th>Type</th><th style={{ textAlign: 'right' }}>Amount</th></tr>
                  </thead>
                  <tbody>
                    {list.map((r) => (
                      <tr key={r.id} onClick={() => setSelectedId(r.id)} style={{ cursor: 'pointer', opacity: r.cancelledRefundReason !== undefined ? 0.55 : 1 }}>
                        <td>{dateIST(r.collected_at)}</td>
                        <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{r.receipt_number}</td>
                        <td style={{ fontSize: 12, color: 'var(--g600)', maxWidth: 180, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{r.reference || ''}</td>
                        <td style={{ fontWeight: 600 }}>{formatPatientName(r.patients)} <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{r.patients?.uhid}</span></td>
                        <td style={{ fontSize: 12 }}>{invoicesText(r) || '--'}</td>
                        <td>{modesText(r)}</td>
                        <td>
                          <span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || 'Payment'}</span>
                          {r.cancelledRefundReason !== undefined && <div style={{ fontSize: 10, color: 'var(--red)', fontWeight: 700 }}>CANCELLED</div>}
                        </td>
                        <td style={{ textAlign: 'right', fontWeight: 600, color: isNegative(r) ? 'var(--red)' : 'inherit' }}>{isNegative(r) ? '-' : ''}{money(r.total_amount)}</td>
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
                <PaymentDetail
                  key={selectedId}
                  paymentId={selectedId}
                  onClose={() => setSelectedId(null)}
                  onChanged={(msg) => { setFlash(msg); runSearch(); }}
                />
              </div>
            )}
          </div>
        </>
      )}
    </div>
  );
}
