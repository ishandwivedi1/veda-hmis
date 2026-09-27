'use client';

// Edit an issued invoice. Used by Invoice Details (as a pop-open panel) and
// by the Invoice Modification tab (embedded). The preview here is only a
// preview -- edit_invoice() in Postgres recalculates everything and is the
// only thing that saves.

import { useState, useEffect, useCallback } from 'react';
import { saveInvoiceEdit, saveInvoiceDate, saveInvoiceVoid } from './invoice-edit-actions';
import { getInvoiceEditContext } from '@/lib/rpc-reads/billing__invoice-edit-actions'; // parallel reads (tools/parallel-reads)

const money = (n) => `Rs.${(Math.round((Number(n) || 0) * 100) / 100).toLocaleString('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;
const fmtDay = (d) => (d ? new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--');

// Cancel / Void the whole invoice (void_invoice() in Postgres).
function VoidSection({ ctx, invoiceId, onVoided }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');

  if (ctx.invoice.status === 'Cancelled') return null;
  const paid = Number(ctx.appliedTotal) > 0;

  async function handleVoid() {
    setError('');
    if (!reason.trim()) { setError('Please give a reason.'); return; }
    setBusy(true);
    try {
      const res = await saveInvoiceVoid(invoiceId, reason.trim(), Number(ctx.invoice.net));
      if (res.error) { setError(res.error); return; }
      onVoided(res.invoice, Number(ctx.appliedTotal) || 0);
    } catch (e) {
      setError('Something went wrong -- check your connection and try again. Nothing was changed.');
    } finally {
      setBusy(false);
    }
  }

  return (
    <div style={{ borderTop: '1px dashed var(--g300, #cbd5e1)', marginTop: 16, paddingTop: 10 }}>
      {!ctx.canVoid ? (
        <div style={{ fontSize: 11, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Cancel / Void: {ctx.voidBlock}</div>
      ) : !open ? (
        <button className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => setOpen(true)}>
          <i className="ti ti-x-circle"></i> {paid ? 'Void this invoice' : 'Cancel this invoice'}
        </button>
      ) : (
        <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 10 }}>
          <div style={{ fontSize: 12, color: 'var(--g600)', marginBottom: 6, lineHeight: 1.5 }}>
            The invoice stays on record as <strong>Cancelled</strong> and drops out of revenue and dues.
            {paid && <> The <strong>{money(ctx.appliedTotal)}</strong> already paid on it becomes <strong>patient credit</strong> (usable on another bill or refundable) -- no cash changes hands.</>}
            {' '}Linked prescriptions, tests, procedures and biometry go back to Pending; a surgery package&apos;s case is marked not billed.
          </div>
          {error && <div className="msg-err">{error}</div>}
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
            <input className="fi" style={{ flex: 1, minWidth: 200 }} value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Reason *" />
            <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleVoid} disabled={busy}>
              {busy ? 'Working...' : paid ? 'Confirm void' : 'Confirm cancel'}
            </button>
            <button className="btn btn-sm" onClick={() => setOpen(false)} disabled={busy}>Back</button>
          </div>
        </div>
      )}
    </div>
  );
}

function lineTotals(rate, gstPct, qty, discType, discValue) {
  const gross = (Number(rate) || 0) * (parseInt(qty, 10) || 0);
  const v = Number(discValue) || 0;
  let disc = 0;
  if (discType === 'pct') disc = Math.round(gross * Math.min(v, 100)) / 100;
  else if (discType === 'fixed') disc = Math.min(v, gross);
  const gst = Math.round((gross - disc) * (Number(gstPct) || 0)) / 100;
  return { gross, disc, net: gross - disc + gst };
}

export default function InvoiceEditPanel({ invoiceId, onSaved, onClose, onVoided, embedded = false }) {
  const [ctx, setCtx] = useState(null);
  const [rows, setRows] = useState([]);
  const [added, setAdded] = useState([]);
  const [newDept, setNewDept] = useState('');
  const [newCode, setNewCode] = useState('');
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [newDate, setNewDate] = useState('');
  const [dateReason, setDateReason] = useState('');
  const [savingDate, setSavingDate] = useState(false);

  const load = useCallback(() => {
    getInvoiceEditContext(invoiceId).then((c) => {
      if (c.error) { setError(c.error); return; }
      setCtx(c);
      setRows(c.lines.map((l) => ({
        line: l, qty: l.qty, discType: 'fixed', discValue: Number(l.disc) || 0, discReason: '', removed: false,
      })));
      setAdded([]);
      setReason('');
      setNewDate(c.invoiceDate);
      setDateReason('');
    });
  }, [invoiceId]);

  useEffect(() => { load(); }, [load]);

  if (error && !ctx) return <div className="card"><div className="msg-err">{error}</div></div>;
  if (!ctx) return <div className="card" style={{ color: 'var(--g400)', textAlign: 'center' }}>Loading...</div>;

  if (!ctx.canEdit) {
    return (
      <div className={embedded ? '' : 'card'}>
        <div className="msg-info" style={{ margin: 0 }}>
          <i className="ti ti-lock"></i> {ctx.blockReason}
        </div>
        <VoidSection ctx={ctx} invoiceId={invoiceId} onVoided={(inv, credited) => onVoided?.(inv, credited)} />
        {onClose && <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={onClose}>Close</button>}
      </div>
    );
  }

  const inv = ctx.invoice;
  const paid = Number(inv.paid) || 0;

  const rowCalc = rows.map((r) => {
    const t = lineTotals(r.line.rate, r.line.gst_pct, r.qty, r.discType, r.discValue);
    const changed = !r.removed && (parseInt(r.qty, 10) !== r.line.qty || Math.round(t.disc * 100) !== Math.round(Number(r.line.disc) * 100));
    return { ...r, ...t, changed, lock: ctx.lockReasons[r.line.id] };
  });
  const addedCalc = added.map((a) => {
    const svc = ctx.services.find((s) => s.code === a.code);
    return { ...a, svc, ...lineTotals(svc?.rate, svc?.gst_pct, a.qty, a.discType, a.discValue) };
  });

  const newNet = rowCalc.filter((r) => !r.removed).reduce((s, r) => s + r.net, 0) + addedCalc.reduce((s, a) => s + a.net, 0);
  const anyChange = rowCalc.some((r) => r.changed || r.removed) || added.length > 0;
  const toCredit = Math.max(0, Math.round((paid - newNet) * 100) / 100);
  const due = Math.max(0, Math.round((newNet - paid) * 100) / 100);
  const keptLines = rowCalc.filter((r) => !r.removed).length + added.length;

  const depts = [...new Set(ctx.services.map((s) => s.dept))];

  function setRow(i, patch) { setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r))); }
  function setAdd(i, patch) { setAdded((as) => as.map((a, j) => (j === i ? { ...a, ...patch } : a))); }

  async function handleSave() {
    setError('');
    if (!reason.trim()) { setError('Please give a reason for this edit.'); return; }
    if (keptLines === 0) { setError('An invoice must keep at least one item.'); return; }
    for (const r of rowCalc) {
      if (r.changed && r.disc > Number(r.line.disc) && !r.discReason.trim()) {
        setError(`"${r.line.service_name}": give a reason for the discount.`); return;
      }
    }
    for (const a of addedCalc) {
      if (a.discType !== 'none' && Number(a.discValue) > 0 && !a.discReason.trim()) {
        setError(`"${a.svc?.name}": give a reason for the discount.`); return;
      }
    }

    const changes = {
      remove: rowCalc.filter((r) => r.removed).map((r) => r.line.id),
      update: rowCalc.filter((r) => r.changed).map((r) => ({
        id: r.line.id, qty: parseInt(r.qty, 10), disc_type: r.discType, disc_value: Number(r.discValue) || 0, disc_reason: r.discReason.trim(),
      })),
      add: addedCalc.map((a) => ({
        service_code: a.code, qty: parseInt(a.qty, 10) || 1, disc_type: a.discType, disc_value: Number(a.discValue) || 0, disc_reason: a.discReason.trim(),
      })),
    };

    setSaving(true);
    try {
      const res = await saveInvoiceEdit(invoiceId, changes, reason.trim(), Number(inv.net));
      if (res.error) { setError(res.error); return; }
      if (embedded) load();
      onSaved?.(res.invoice, toCredit);
    } catch (e) {
      setError('Something went wrong saving this edit -- check your connection and try again. Nothing was saved.');
    } finally {
      setSaving(false);
    }
  }

  async function handleSaveDate() {
    setError('');
    if (!newDate || newDate === ctx.invoiceDate) { setError('Choose a different date.'); return; }
    if (ctx.visitDate && newDate < ctx.visitDate) {
      setError(`This invoice belongs to visit ${ctx.visitNumber || ''} dated ${fmtDay(ctx.visitDate)}. It cannot be dated before the visit.`);
      return;
    }
    if (newDate > ctx.today) { setError('An invoice cannot be dated in the future.'); return; }
    if (!dateReason.trim()) { setError('Please give a reason for changing the invoice date.'); return; }
    const ok = window.confirm(
      `Move ${ctx.invoice.invoice_number} from ${fmtDay(ctx.invoiceDate)} to ${fmtDay(newDate)}?\n\n`
      + `Its amount moves out of ${fmtDay(ctx.invoiceDate)}'s revenue and into ${fmtDay(newDate)}'s. `
      + 'Payments keep their own dates. The change is recorded in the invoice history.',
    );
    if (!ok) return;
    setSavingDate(true);
    try {
      const res = await saveInvoiceDate(invoiceId, newDate, dateReason.trim());
      if (res.error) { setError(res.error); return; }
      load();
      onSaved?.(res.invoice, 0);
    } catch (e) {
      setError('Something went wrong changing the date -- check your connection and try again. Nothing was saved.');
    } finally {
      setSavingDate(false);
    }
  }

  return (
    <div className={embedded ? '' : 'card'} style={embedded ? undefined : { border: '1.5px solid var(--blue)' }}>
      {!embedded && (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title" style={{ marginBottom: 0 }}>
            <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Edit {inv.invoice_number}
          </div>
          {onClose && <button className="btn btn-sm" onClick={onClose} disabled={saving}>Close</button>}
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ overflowX: 'auto' }}>
        <table className="tbl">
          <thead><tr><th>Service</th><th style={{ width: 70 }}>Qty</th><th>Rate</th><th style={{ width: 170 }}>Discount</th><th>Net</th><th></th></tr></thead>
          <tbody>
            {rowCalc.map((r, i) => (
              <tr key={r.line.id} style={{ opacity: r.removed ? 0.45 : 1, background: r.changed ? 'var(--amber-lt)' : undefined }}>
                <td>
                  <div style={{ textDecoration: r.removed ? 'line-through' : 'none', fontWeight: 600 }}>{r.line.service_name}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--g400)' }}>{r.line.dept}</div>
                  {r.lock && <div style={{ fontSize: 10.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> {r.lock}</div>}
                  {r.removed && ctx.removeHints[r.line.id] && (
                    <div style={{ fontSize: 10.5, color: 'var(--amber)' }}><i className="ti ti-info-circle"></i> {ctx.removeHints[r.line.id]}</div>
                  )}
                </td>
                <td>
                  {r.lock || r.removed ? r.qty : (
                    <input type="number" min={1} className="fi fi-sm" value={r.qty} onChange={(e) => setRow(i, { qty: e.target.value })} style={{ width: 60 }} />
                  )}
                </td>
                <td>{money(r.line.rate)}</td>
                <td>
                  {r.lock || r.removed ? (Number(r.line.disc) > 0 ? money(r.line.disc) : '--') : (
                    <div>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <select className="fi fi-sm" value={r.discType} onChange={(e) => setRow(i, { discType: e.target.value, discValue: e.target.value === 'none' ? 0 : r.discValue })} style={{ width: 70 }}>
                          <option value="fixed">Rs.</option>
                          <option value="pct">%</option>
                          <option value="none">None</option>
                        </select>
                        <input type="number" min={0} className="fi fi-sm" value={r.discValue} disabled={r.discType === 'none'} onChange={(e) => setRow(i, { discValue: e.target.value })} style={{ width: 80 }} />
                      </div>
                      {r.changed && r.disc > Number(r.line.disc) && (
                        <input className="fi fi-sm" placeholder="Discount reason *" value={r.discReason} onChange={(e) => setRow(i, { discReason: e.target.value })} style={{ marginTop: 4 }} />
                      )}
                    </div>
                  )}
                </td>
                <td>
                  {r.changed && <div style={{ fontSize: 10.5, color: 'var(--g400)', textDecoration: 'line-through' }}>{money(r.line.net)}</div>}
                  {money(r.removed ? 0 : r.net)}
                </td>
                <td>
                  {!r.lock && (
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => setRow(i, { removed: !r.removed, qty: r.line.qty, discType: 'fixed', discValue: Number(r.line.disc) || 0 })}>
                      {r.removed ? 'Undo' : 'Remove'}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {addedCalc.map((a, i) => (
              <tr key={`add-${i}`} style={{ background: 'var(--green-lt)' }}>
                <td>
                  <div style={{ fontWeight: 600 }}>{a.svc?.name}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--green)' }}>New -- {a.svc?.dept}</div>
                </td>
                <td><input type="number" min={1} className="fi fi-sm" value={a.qty} onChange={(e) => setAdd(i, { qty: e.target.value })} style={{ width: 60 }} /></td>
                <td>{money(a.svc?.rate)}</td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <select className="fi fi-sm" value={a.discType} onChange={(e) => setAdd(i, { discType: e.target.value, discValue: e.target.value === 'none' ? 0 : a.discValue })} style={{ width: 70 }}>
                      <option value="none">None</option>
                      <option value="fixed">Rs.</option>
                      <option value="pct">%</option>
                    </select>
                    <input type="number" min={0} className="fi fi-sm" value={a.discValue} disabled={a.discType === 'none'} onChange={(e) => setAdd(i, { discValue: e.target.value })} style={{ width: 80 }} />
                  </div>
                  {a.discType !== 'none' && Number(a.discValue) > 0 && (
                    <input className="fi fi-sm" placeholder="Discount reason *" value={a.discReason} onChange={(e) => setAdd(i, { discReason: e.target.value })} style={{ marginTop: 4 }} />
                  )}
                </td>
                <td>{money(a.net)}</td>
                <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => setAdded((as) => as.filter((_, j) => j !== i))}>Remove</button></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap' }}>
        <select className="fi fi-sm" style={{ width: 160 }} value={newDept} onChange={(e) => { setNewDept(e.target.value); setNewCode(''); }}>
          <option value="">-- Dept --</option>
          {depts.map((d) => <option key={d} value={d}>{d}</option>)}
        </select>
        <select className="fi fi-sm" style={{ flex: 1, minWidth: 180 }} value={newCode} disabled={!newDept} onChange={(e) => setNewCode(e.target.value)}>
          <option value="">-- Add an item --</option>
          {ctx.services.filter((s) => s.dept === newDept).map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
        </select>
        <button className="btn btn-sm" disabled={!newCode} onClick={() => { setAdded((as) => [...as, { code: newCode, qty: 1, discType: 'none', discValue: 0, discReason: '' }]); setNewCode(''); }}>
          <i className="ti ti-plus"></i> Add
        </button>
      </div>

      <div style={{ borderTop: '1px solid var(--g200)', marginTop: 14, paddingTop: 10, fontSize: 13, lineHeight: 1.9 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between' }}>
          <span>Invoice total</span>
          <span>
            {anyChange && <span style={{ color: 'var(--g400)', textDecoration: 'line-through', marginRight: 8 }}>{money(inv.net)}</span>}
            <strong>{money(newNet)}</strong>
          </span>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Already paid</span><span>{money(paid)}</span></div>
        {anyChange && toCredit > 0 && (
          <div className="msg-info" style={{ margin: '6px 0 0' }}>
            <i className="ti ti-wallet"></i> {money(toCredit)} already paid will be kept as <strong>&nbsp;patient credit&nbsp;</strong> (usable on future bills or refundable). No cash changes hands.
          </div>
        )}
        {anyChange && due > 0 && (
          <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)', fontWeight: 700 }}><span>Balance due after edit</span><span>{money(due)}</span></div>
        )}
      </div>

      <label className="flbl" style={{ marginTop: 12 }}>Reason for this edit *</label>
      <input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="e.g. Senior citizen discount missed / test not done" />

      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving || !anyChange}>
          <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save changes'}
        </button>
        <button className="btn" onClick={embedded ? load : onClose} disabled={saving || (embedded && !anyChange)}>Discard</button>
      </div>

      {ctx.isAdmin && (
        <div style={{ border: '1px dashed var(--g300, #cbd5e1)', borderRadius: 8, padding: '10px 12px', marginTop: 16 }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>
            <i className="ti ti-calendar-event"></i> Invoice date <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(Administrator only -- both days must be open)</span>
          </div>
          {ctx.visitDate && (
            <div style={{ fontSize: 11.5, color: 'var(--amber)', marginBottom: 6 }}>
              <i className="ti ti-info-circle"></i> This invoice belongs to visit {ctx.visitNumber} on {fmtDay(ctx.visitDate)}, so it can only be dated from {fmtDay(ctx.visitDate)} to today.
            </div>
          )}
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
            <input type="date" className="fi fi-sm" style={{ width: 150 }} value={newDate} min={ctx.visitDate || undefined} max={ctx.today} onChange={(e) => setNewDate(e.target.value)} />
            <input className="fi fi-sm" style={{ flex: 1, minWidth: 180 }} value={dateReason} onChange={(e) => setDateReason(e.target.value)} placeholder="Reason for changing the date *" />
            <button className="btn btn-sm" onClick={handleSaveDate} disabled={savingDate || newDate === ctx.invoiceDate}>
              {savingDate ? 'Saving...' : 'Change date'}
            </button>
          </div>
        </div>
      )}

      <VoidSection ctx={ctx} invoiceId={invoiceId} onVoided={(inv, credited) => onVoided?.(inv, credited)} />
    </div>
  );
}
