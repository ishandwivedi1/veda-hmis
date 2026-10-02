'use client';

// Edit / delete one payment (Billing Phase 3), Zoho-style (migration 051):
// every field editable for any date; Save asks for the reason in a popup.
// Opened from the Receipt Register. The figures here are a preview -- edit_payment() /
// delete_payment() in Postgres recheck everything and are the only thing
// that saves.

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { savePaymentEdit, removePayment } from './payment-edit-actions';
import EditReasonModal from '@/app/components/EditReasonModal';
import { getPaymentEditContext } from '@/lib/rpc-reads/payments__payment-edit-actions'; // parallel reads (tools/parallel-reads)

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `Rs.${r2(n).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
const when = (d) => new Date(d).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

const HISTORY_LABEL = {
  payment_edited: 'Edited',
  older_edit: 'Edited (older record)',
  payment_modes_corrected_closed_day: 'Mode corrected (closed day)',
};

function PaymentHistory({ entries }) {
  if (!entries.length) return null;
  return (
    <div style={{ marginTop: 14 }}>
      <label className="flbl" style={{ marginBottom: 6 }}>Change history</label>
      {entries.map((e) => (
        <div key={e.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '5px 0', borderBottom: '1px solid var(--g200)' }}>
          <div><strong>{HISTORY_LABEL[e.action] || e.action}</strong> -- {when(e.at)} -- {e.by}</div>
          {e.reason && <div style={{ color: 'var(--g500)' }}>Reason: {e.reason}</div>}
          {e.action === 'payment_edited' && (
            <div style={{ color: 'var(--g500)' }}>
              {Number(e.before?.total_amount) !== Number(e.after?.total_amount) && <>Amount {money(e.before?.total_amount)} → <strong>{money(e.after?.total_amount)}</strong>. </>}
              {e.before?.date !== e.after?.date && <>Date {e.before?.date} → <strong>{e.after?.date}</strong>. </>}
              Modes: {(e.after?.modes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ')}.{' '}
              Applied: {(e.after?.allocations || []).map((a) => `${a.invoice_number} ${money(a.amount)}`).join(', ') || 'none'}.
              {Number(e.after?.credit_change) !== 0 && <> Patient credit {Number(e.after.credit_change) > 0 ? '+' : ''}{money(e.after.credit_change)}.</>}
            </div>
          )}
          {e.action === 'older_edit' && e.older?.oldAmount != null && (
            <div style={{ color: 'var(--g500)' }}>Amount {money(e.older.oldAmount)} → {money(e.older.newAmount)}</div>
          )}
        </div>
      ))}
    </div>
  );
}

export default function PaymentEditPanel({ paymentId, onChanged, onClose }) {
  const [ctx, setCtx] = useState(null);
  const [history, setHistory] = useState([]);
  const [amount, setAmount] = useState('');
  const [date, setDate] = useState('');
  const [modes, setModes] = useState([]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [applied, setApplied] = useState({}); // invoice_id -> amount string
  const [askReason, setAskReason] = useState(false);
  const [reasonError, setReasonError] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [showDelete, setShowDelete] = useState(false);
  const [deleteReason, setDeleteReason] = useState('');
  const [deleting, setDeleting] = useState(false);

  const load = useCallback(async () => {
    setError('');
    // One request: context and history come back together.
    const c = await getPaymentEditContext(paymentId);
    if (c.error) { setError(c.error); return; }
    setCtx(c);
    setHistory(c.history || []);
    const p = c.payment;
    setAmount(String(r2(p.total_amount)));
    setDate(c.paymentDate);
    setModes((p.payment_modes || []).map((m) => ({ mode: m.mode, amount: String(r2(m.amount)) })));
    setReference(p.reference || '');
    setRemarks(p.remarks || '');
    setApplied(Object.fromEntries(c.invoices.map((i) => [i.id, i.current ? String(r2(i.current)) : ''])));
    setAskReason(false);
    setShowDelete(false);
    setDeleteReason('');
  }, [paymentId]);

  useEffect(() => { load(); }, [load]);

  if (error && !ctx) return <div className="msg-err">{error}</div>;
  if (!ctx) return <div style={{ fontSize: 12, color: 'var(--g400)', padding: 12 }}>Loading payment...</div>;

  const p = ctx.payment;
  const isInvoicePayment = p.payment_type === 'invoice_payment';
  const amt = r2(amount);
  const modesSum = r2(modes.reduce((s, m) => s + (Number(m.amount) || 0), 0));
  const appliedSum = r2(Object.values(applied).reduce((s, v) => s + (Number(v) || 0), 0));
  const leftover = r2(amt - (isInvoicePayment ? appliedSum : 0));
  const creditChange = r2(leftover - ctx.paymentCredit);
  const overApplied = ctx.invoices.filter((i) => r2(applied[i.id]) > i.room);

  function setMode(i, patch) { setModes((ms) => ms.map((m, j) => (j === i ? { ...m, ...patch } : m))); }

  // Save -> checks, then the reason popup; the popup's Save sends the edit.
  function handleSave() {
    setError('');
    if (!(amt > 0)) { setError('Amount must be greater than zero. To remove the payment, use Delete.'); return; }
    if (Math.abs(modesSum - amt) >= 0.01) { setError(`Payment modes (${money(modesSum)}) must add up to the amount (${money(amt)}).`); return; }
    if (modes.some((m) => !(Number(m.amount) > 0))) { setError('Every payment mode needs an amount above zero (remove empty rows).'); return; }
    if (isInvoicePayment && appliedSum > amt + 0.001) { setError(`${money(appliedSum)} is applied to invoices but the payment is only ${money(amt)}.`); return; }
    if (overApplied.length) { setError(`${overApplied[0].invoice_number} only has ${money(overApplied[0].room)} left to pay.`); return; }
    if (creditChange < 0 && ctx.patientCredit + creditChange < -0.001) {
      setError(`This takes back ${money(-creditChange)} of patient credit, but only ${money(ctx.patientCredit)} is unused.`); return;
    }
    setReasonError('');
    setAskReason(true);
  }

  async function saveWithReason(reason) {
    setSaving(true);
    try {
      const res = await savePaymentEdit({
        paymentId,
        amount: amt,
        date: date !== ctx.paymentDate ? date : null,
        modes: modes.map((m) => ({ mode: m.mode, amount: r2(m.amount) })),
        reference,
        remarks,
        allocations: isInvoicePayment
          ? Object.entries(applied).filter(([, v]) => Number(v) > 0).map(([invoiceId, v]) => ({ invoice_id: invoiceId, amount: r2(v) }))
          : [],
        reason,
        expectedAmount: Number(p.total_amount),
      });
      if (res.error) { setReasonError(res.error); return; }
      setAskReason(false);
      onChanged?.(`${p.receipt_number} updated.${creditChange > 0 ? ` ${money(creditChange)} added to patient credit.` : creditChange < 0 ? ` Patient credit reduced by ${money(-creditChange)}.` : ''}`);
    } catch (e) {
      setReasonError('Something went wrong saving -- check your connection and try again. Nothing was saved.');
    } finally {
      setSaving(false);
    }
  }

  async function handleDelete() {
    setError('');
    if (!deleteReason.trim()) { setError('Please give a reason for deleting.'); return; }
    setDeleting(true);
    try {
      const res = await removePayment(paymentId, deleteReason.trim(), Number(p.total_amount));
      if (res.error) { setError(res.error); return; }
      onChanged?.(p.payment_type === 'advance_adjustment'
        ? `Credit application removed. ${money(p.total_amount)} is back in the patient's credit.`
        : `${p.receipt_number} deleted. It is kept under "Deleted receipts".`, { deleted: true });
    } catch (e) {
      setError('Something went wrong deleting -- check your connection and try again. Nothing was changed.');
    } finally {
      setDeleting(false);
    }
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
        <div style={{ fontSize: 12.5, fontWeight: 700 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i>{' '}
          {p.receipt_number || 'Credit application'} -- {formatPatientName(p.patients)} ({p.patients?.uhid})
        </div>
        {onClose && <button className="btn btn-sm" onClick={onClose}>Close</button>}
      </div>

      {error && <div className="msg-err">{error}</div>}

      {!ctx.canEdit && (
        <div className="msg-info" style={{ marginBottom: 10 }}><i className="ti ti-lock"></i> {ctx.editBlock}</div>
      )}

      {ctx.canEdit && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))', gap: 10, marginBottom: 10 }}>
            <div>
              <label className="flbl">Amount received (Rs.)</label>
              <input type="number" min={0} className="fi" value={amount} onChange={(e) => {
                const v = e.target.value;
                setAmount(v);
                if (modes.length === 1) setModes([{ ...modes[0], amount: v }]);
              }} />
            </div>
            <div>
              <label className="flbl">Date received</label>
              <input type="date" className="fi" value={date} max={ctx.today} disabled={!ctx.canChangeDate} onChange={(e) => setDate(e.target.value)}
                title={ctx.canChangeDate ? '' : 'You do not have permission to edit payments'} />
            </div>
            <div>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
            </div>
            <div>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} />
            </div>
          </div>

          <label className="flbl">Payment mode(s)</label>
          {modes.map((m, i) => (
            <div key={i} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
              <select className="fi" style={{ flex: 1 }} value={m.mode} onChange={(e) => setMode(i, { mode: e.target.value })}>
                {[...new Set([...MODE_OPTIONS, m.mode])].map((o) => <option key={o} value={o}>{o}</option>)}
              </select>
              <input type="number" min={0} className="fi" style={{ flex: 1 }} value={m.amount} onChange={(e) => setMode(i, { amount: e.target.value })} />
              {modes.length > 1 && <button className="btn" style={{ padding: '4px 10px' }} onClick={() => setModes((ms) => ms.filter((_, j) => j !== i))}>x</button>}
            </div>
          ))}
          <button className="btn btn-sm" style={{ marginBottom: 6 }} onClick={() => setModes((ms) => [...ms, { mode: 'UPI', amount: '' }])}>
            <i className="ti ti-plus"></i> Split into another mode
          </button>
          <div style={{ fontSize: 12, fontWeight: 600, color: Math.abs(modesSum - amt) < 0.01 ? 'var(--green)' : 'var(--red)', marginBottom: 12 }}>
            Modes total {money(modesSum)} / {money(amt)}
          </div>

          {isInvoicePayment ? (
            <>
              <label className="flbl">Applied to invoices</label>
              {ctx.invoices.length === 0 ? (
                <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 8 }}>No unpaid invoices for this patient.</div>
              ) : (
                <table className="tbl" style={{ marginBottom: 6 }}>
                  <thead><tr><th>Invoice</th><th>Date</th><th>Total</th><th>Can take</th><th style={{ width: 130 }}>Apply (Rs.)</th></tr></thead>
                  <tbody>
                    {ctx.invoices.map((i) => (
                      <tr key={i.id} style={{ background: r2(applied[i.id]) > i.room ? 'var(--red-lt)' : undefined }}>
                        <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{i.invoice_number}</td>
                        <td style={{ fontSize: 11 }}>{i.date}</td>
                        <td>{money(i.net)}</td>
                        <td>{money(i.room)}</td>
                        <td>
                          <div style={{ display: 'flex', gap: 4 }}>
                            <input type="number" min={0} className="fi fi-sm" style={{ width: 80 }} value={applied[i.id] ?? ''} onChange={(e) => setApplied((a) => ({ ...a, [i.id]: e.target.value }))} />
                            <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} title="Fill"
                              onClick={() => {
                                const others = r2(Object.entries(applied).filter(([k]) => k !== i.id).reduce((s, [, v]) => s + (Number(v) || 0), 0));
                                setApplied((a) => ({ ...a, [i.id]: String(Math.max(0, Math.min(i.room, r2(amt - others)))) }));
                              }}>Max</button>
                          </div>
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              )}
            </>
          ) : (
            <div className="msg-info" style={{ marginBottom: 8 }}>
              <i className="ti ti-info-circle"></i> This is an advance: it stays as patient credit. Use <strong>&nbsp;Apply Advance&nbsp;</strong> to put it against a bill.
            </div>
          )}

          <div style={{ fontSize: 12.5, lineHeight: 1.8, borderTop: '1px solid var(--g200)', paddingTop: 8 }}>
            {isInvoicePayment && <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Applied to invoices</span><strong>{money(appliedSum)}</strong></div>}
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Left as patient credit</span><strong>{money(leftover)}</strong></div>
            {creditChange !== 0 && (
              <div style={{ color: creditChange > 0 ? 'var(--blue)' : 'var(--amber)', fontSize: 12 }}>
                <i className="ti ti-wallet"></i> Patient credit will {creditChange > 0 ? 'increase' : 'decrease'} by {money(Math.abs(creditChange))} (unused credit now {money(ctx.patientCredit)}).
              </div>
            )}
          </div>

          <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
            <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>
              <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save changes'}
            </button>
            <button className="btn btn-sm" onClick={load} disabled={saving}>Discard</button>
          </div>
        </>
      )}

      {!ctx.canEdit && p.payment_type === 'advance_adjustment' && (
        <div style={{ fontSize: 12, color: 'var(--g600)', marginBottom: 8 }}>
          {money(p.total_amount)} of credit applied to {(p.payment_allocations || []).map((a) => a.invoices?.invoice_number).join(', ') || '--'}.
        </div>
      )}

      <div style={{ borderTop: '1px dashed var(--g300, #cbd5e1)', marginTop: 14, paddingTop: 10 }}>
        {ctx.canDelete ? (
          !showDelete ? (
            <button className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => setShowDelete(true)}>
              <i className="ti ti-trash"></i> {p.payment_type === 'advance_adjustment' ? 'Remove this credit application' : 'Delete this payment'}
            </button>
          ) : (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 10 }}>
              <div style={{ fontSize: 12, color: 'var(--g600)', marginBottom: 6 }}>
                {p.payment_type === 'advance_adjustment'
                  ? `The ${money(p.total_amount)} goes back into the patient's credit and the invoice becomes unpaid by that amount.`
                  : `The receipt is removed from all registers and reports; any invoices it paid become unpaid again. A full copy is kept under "Deleted receipts".`}
              </div>
              <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
                <input className="fi" style={{ flex: 1, minWidth: 200 }} value={deleteReason} onChange={(e) => setDeleteReason(e.target.value)} placeholder="Reason *" />
                <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleDelete} disabled={deleting}>
                  {deleting ? 'Working...' : 'Confirm'}
                </button>
                <button className="btn btn-sm" onClick={() => setShowDelete(false)} disabled={deleting}>Back</button>
              </div>
            </div>
          )
        ) : (
          <div style={{ fontSize: 11, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Delete: {ctx.deleteBlock}</div>
        )}
      </div>

      <PaymentHistory entries={history} />
      {askReason && (
        <EditReasonModal
          title={`Reason for editing ${p.receipt_number || 'this payment'}`}
          summary={`Amount ${money(amt)}${date !== ctx.paymentDate ? `, dated ${date}` : ''}. The reason is saved with this change in the payment history.`}
          saving={saving}
          error={reasonError}
          onSave={saveWithReason}
          onCancel={() => { if (!saving) setAskReason(false); }}
        />
      )}
    </div>
  );
}
