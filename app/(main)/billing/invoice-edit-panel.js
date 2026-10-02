'use client';

// Edit an issued invoice, Zoho-style (migration 051): date, description,
// price, quantity and discount are all editable inline, items can be added
// or removed; Save asks for one reason in a popup and records it with the
// change. A paid invoice can't drop below what's been paid. Used by Invoice
// Details (as a pop-open panel) and by the Invoice Modification tab
// (embedded). The preview here is only a preview -- edit_invoice() in
// Postgres recalculates everything and is the only thing that saves.

import { useState, useEffect, useCallback } from 'react';
import { saveInvoiceEdit, saveInvoiceVoid } from './invoice-edit-actions';
// One-request saves (change + refreshed screen in the same response) -- used
// when the caller passes `refresh` (the Invoices screen does).
import { saveInvoiceEditAndRefresh, voidInvoiceAndRefresh } from './invoice-change-actions';
import EditReasonModal from '@/app/components/EditReasonModal';
import { getInvoiceEditContext } from '@/lib/rpc-reads/billing__invoice-edit-actions'; // parallel reads (tools/parallel-reads)

const money = (n) => `Rs.${(Math.round((Number(n) || 0) * 100) / 100).toLocaleString('en-IN', { minimumFractionDigits: 0, maximumFractionDigits: 2 })}`;
const fmtDay = (d) => (d ? new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--');

// Cancel / Void the whole invoice (void_invoice() in Postgres).
function VoidSection({ ctx, invoiceId, onVoided, refresh }) {
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
      const res = refresh
        ? await voidInvoiceAndRefresh(invoiceId, reason.trim(), Number(ctx.invoice.net), refresh)
        : await saveInvoiceVoid(invoiceId, reason.trim(), Number(ctx.invoice.net));
      if (res.error) { setError(res.error); return; }
      onVoided(res.invoice, Number(ctx.appliedTotal) || 0, res.refresh);
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

export default function InvoiceEditPanel({ invoiceId, onSaved, onClose, onVoided, embedded = false, refresh = null, onContext }) {
  const [ctx, setCtx] = useState(null);
  const [rows, setRows] = useState([]);
  const [added, setAdded] = useState([]);
  const [newDept, setNewDept] = useState('');
  const [newCode, setNewCode] = useState('');
  const [newDate, setNewDate] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const [askReason, setAskReason] = useState(false);
  const [reasonError, setReasonError] = useState('');

  const load = useCallback(() => {
    getInvoiceEditContext(invoiceId).then((c) => {
      if (c.error) { setError(c.error); return; }
      setCtx(c);
      onContext?.(c);
      setRows(c.lines.map((l) => ({
        line: l, name: l.service_name, rate: Number(l.rate), qty: l.qty,
        discType: 'fixed', discValue: Number(l.disc) || 0, removed: false,
      })));
      setAdded([]);
      setNewDate(c.invoiceDate);
      setError('');
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
        <VoidSection ctx={ctx} invoiceId={invoiceId} onVoided={(inv, credited, r) => onVoided?.(inv, credited, r)} refresh={refresh} />
        {onClose && <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={onClose}>Close</button>}
      </div>
    );
  }

  const inv = ctx.invoice;
  const paid = Number(inv.paid) || 0;

  const rowCalc = rows.map((r) => {
    const t = lineTotals(r.rate, r.line.gst_pct, r.qty, r.discType, r.discValue);
    const changed = !r.removed && (
      (r.name || '').trim() !== r.line.service_name
      || Math.round((Number(r.rate) || 0) * 100) !== Math.round(Number(r.line.rate) * 100)
      || parseInt(r.qty, 10) !== r.line.qty
      || Math.round(t.disc * 100) !== Math.round(Number(r.line.disc) * 100));
    return { ...r, ...t, changed, lock: ctx.lockReasons[r.line.id] };
  });
  const addedCalc = added.map((a) => {
    const svc = ctx.services.find((s) => s.code === a.code);
    return { ...a, svc, ...lineTotals(a.rate, svc?.gst_pct, a.qty, a.discType, a.discValue) };
  });

  const dateChanged = newDate && newDate !== ctx.invoiceDate;
  const newNet = rowCalc.filter((r) => !r.removed).reduce((s, r) => s + r.net, 0) + addedCalc.reduce((s, a) => s + a.net, 0);
  const anyChange = rowCalc.some((r) => r.changed || r.removed) || added.length > 0 || dateChanged;
  const belowPaid = Math.round(newNet * 100) < Math.round(paid * 100);
  const due = Math.max(0, Math.round((newNet - paid) * 100) / 100);
  const keptLines = rowCalc.filter((r) => !r.removed).length + added.length;

  const depts = [...new Set(ctx.services.map((s) => s.dept))];

  function setRow(i, patch) { setRows((rs) => rs.map((r, j) => (j === i ? { ...r, ...patch } : r))); }
  function setAdd(i, patch) { setAdded((as) => as.map((a, j) => (j === i ? { ...a, ...patch } : a))); }

  // Save -> checks, then the reason popup; the popup's Save sends the edit.
  function handleSave() {
    setError('');
    if (keptLines === 0) { setError('An invoice must keep at least one item. To cancel the whole bill, use Cancel/Void below.'); return; }
    for (const r of rowCalc) {
      if (r.removed) continue;
      if (!(r.name || '').trim()) { setError('Every item needs a description.'); return; }
      if (!(Number(r.rate) >= 0)) { setError(`"${r.name}": enter a valid price.`); return; }
      if (!(parseInt(r.qty, 10) >= 1)) { setError(`"${r.name}": quantity must be at least 1.`); return; }
    }
    for (const a of addedCalc) {
      if (!(Number(a.rate) >= 0)) { setError(`"${a.name || a.svc?.name}": enter a valid price.`); return; }
    }
    if (dateChanged) {
      if (newDate > ctx.today) { setError('An invoice cannot be dated in the future.'); return; }
      if (ctx.visitDate && newDate < ctx.visitDate) {
        setError(`This invoice belongs to visit ${ctx.visitNumber || ''} dated ${fmtDay(ctx.visitDate)}. It cannot be dated before the visit.`);
        return;
      }
    }
    if (belowPaid) {
      setError(`The new total (${money(newNet)}) is less than the ${money(paid)} already paid on this invoice. Adjust or remove the payment first, then edit the invoice.`);
      return;
    }
    setReasonError('');
    setAskReason(true);
  }

  async function saveWithReason(reason) {
    const changes = {
      ...(dateChanged ? { date: newDate } : {}),
      remove: rowCalc.filter((r) => r.removed).map((r) => r.line.id),
      update: rowCalc.filter((r) => r.changed).map((r) => ({
        id: r.line.id, service_name: r.name.trim(), rate: Number(r.rate) || 0, qty: parseInt(r.qty, 10),
        disc_type: r.discType, disc_value: Number(r.discValue) || 0,
      })),
      add: addedCalc.map((a) => ({
        service_code: a.code, service_name: (a.name || '').trim() || undefined, rate: Number(a.rate) || 0,
        qty: parseInt(a.qty, 10) || 1, disc_type: a.discType, disc_value: Number(a.discValue) || 0,
      })),
    };

    setSaving(true);
    try {
      const res = refresh
        ? await saveInvoiceEditAndRefresh(invoiceId, changes, reason, Number(inv.net), refresh)
        : await saveInvoiceEdit(invoiceId, changes, reason, Number(inv.net));
      if (res.error) { setReasonError(res.error); return; }
      setAskReason(false);
      if (embedded) load();
      onSaved?.(res.invoice, 0, res.refresh);
    } catch (e) {
      setReasonError('Something went wrong saving this edit -- check your connection and try again. Nothing was saved.');
    } finally {
      setSaving(false);
    }
  }

  const changedStyle = (on) => (on ? { borderColor: 'var(--amber)', background: 'var(--amber-lt)' } : undefined);

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

      <div style={{ display: 'flex', gap: 10, alignItems: 'center', flexWrap: 'wrap', marginBottom: 10 }}>
        <label className="flbl" style={{ margin: 0 }}>Invoice date</label>
        <input type="date" className="fi fi-sm" style={{ width: 160, ...changedStyle(dateChanged) }} value={newDate}
          min={ctx.visitDate || undefined} max={ctx.today} onChange={(e) => setNewDate(e.target.value)} />
        {ctx.visitDate && <span style={{ fontSize: 11, color: 'var(--g500)' }}>Visit {ctx.visitNumber} on {fmtDay(ctx.visitDate)} -- can&apos;t be dated before it.</span>}
      </div>

      <div style={{ overflowX: 'auto' }}>
        <table className="tbl">
          <thead><tr><th>Item</th><th style={{ width: 110 }}>Price (Rs.)</th><th style={{ width: 70 }}>Qty</th><th style={{ width: 160 }}>Discount</th><th>Net</th><th></th></tr></thead>
          <tbody>
            {rowCalc.map((r, i) => (
              <tr key={r.line.id} style={{ opacity: r.removed ? 0.45 : 1, background: r.changed ? 'var(--amber-lt)' : undefined }}>
                <td style={{ minWidth: 180 }}>
                  {r.removed ? (
                    <div style={{ textDecoration: 'line-through', fontWeight: 600 }}>{r.line.service_name}</div>
                  ) : (
                    <input className="fi fi-sm" value={r.name} onChange={(e) => setRow(i, { name: e.target.value })} style={{ fontWeight: 600 }} />
                  )}
                  <div style={{ fontSize: 10.5, color: 'var(--g400)' }}>{r.line.dept}</div>
                  {r.lock && <div style={{ fontSize: 10.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> {r.lock}</div>}
                  {r.removed && ctx.removeHints[r.line.id] && (
                    <div style={{ fontSize: 10.5, color: 'var(--amber)' }}><i className="ti ti-info-circle"></i> {ctx.removeHints[r.line.id]}</div>
                  )}
                </td>
                <td>
                  {r.removed ? money(r.line.rate) : (
                    <input type="number" min={0} step="0.01" className="fi fi-sm" value={r.rate} onChange={(e) => setRow(i, { rate: e.target.value })} style={{ width: 95 }} />
                  )}
                </td>
                <td>
                  {r.lock || r.removed ? r.qty : (
                    <input type="number" min={1} className="fi fi-sm" value={r.qty} onChange={(e) => setRow(i, { qty: e.target.value })} style={{ width: 60 }} />
                  )}
                </td>
                <td>
                  {r.removed ? (Number(r.line.disc) > 0 ? money(r.line.disc) : '--') : (
                    <div style={{ display: 'flex', gap: 4 }}>
                      <select className="fi fi-sm" value={r.discType} onChange={(e) => setRow(i, { discType: e.target.value, discValue: e.target.value === 'none' ? 0 : r.discValue })} style={{ width: 66 }}>
                        <option value="fixed">Rs.</option>
                        <option value="pct">%</option>
                        <option value="none">None</option>
                      </select>
                      <input type="number" min={0} className="fi fi-sm" value={r.discValue} disabled={r.discType === 'none'} onChange={(e) => setRow(i, { discValue: e.target.value })} style={{ width: 76 }} />
                    </div>
                  )}
                </td>
                <td>
                  {r.changed && <div style={{ fontSize: 10.5, color: 'var(--g400)', textDecoration: 'line-through' }}>{money(r.line.net)}</div>}
                  {money(r.removed ? 0 : r.net)}
                </td>
                <td>
                  {!r.lock && (
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }}
                      onClick={() => setRow(i, { removed: !r.removed, name: r.line.service_name, rate: Number(r.line.rate), qty: r.line.qty, discType: 'fixed', discValue: Number(r.line.disc) || 0 })}>
                      {r.removed ? 'Undo' : 'Remove'}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {addedCalc.map((a, i) => (
              <tr key={`add-${i}`} style={{ background: 'var(--green-lt)' }}>
                <td style={{ minWidth: 180 }}>
                  <input className="fi fi-sm" value={a.name} onChange={(e) => setAdd(i, { name: e.target.value })} style={{ fontWeight: 600 }} />
                  <div style={{ fontSize: 10.5, color: 'var(--green)' }}>New -- {a.svc?.dept}</div>
                </td>
                <td><input type="number" min={0} step="0.01" className="fi fi-sm" value={a.rate} onChange={(e) => setAdd(i, { rate: e.target.value })} style={{ width: 95 }} /></td>
                <td><input type="number" min={1} className="fi fi-sm" value={a.qty} onChange={(e) => setAdd(i, { qty: e.target.value })} style={{ width: 60 }} /></td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <select className="fi fi-sm" value={a.discType} onChange={(e) => setAdd(i, { discType: e.target.value, discValue: e.target.value === 'none' ? 0 : a.discValue })} style={{ width: 66 }}>
                      <option value="none">None</option>
                      <option value="fixed">Rs.</option>
                      <option value="pct">%</option>
                    </select>
                    <input type="number" min={0} className="fi fi-sm" value={a.discValue} disabled={a.discType === 'none'} onChange={(e) => setAdd(i, { discValue: e.target.value })} style={{ width: 76 }} />
                  </div>
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
        <button className="btn btn-sm" disabled={!newCode} onClick={() => {
          const svc = ctx.services.find((s) => s.code === newCode);
          setAdded((as) => [...as, { code: newCode, name: svc?.name || '', rate: Number(svc?.rate) || 0, qty: 1, discType: 'none', discValue: 0 }]);
          setNewCode('');
        }}>
          <i className="ti ti-plus"></i> Add
        </button>
      </div>

      <div style={{ borderTop: '1px solid var(--g200)', marginTop: 14, paddingTop: 10, fontSize: 13, lineHeight: 1.9 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between' }}>
          <span>Invoice total</span>
          <span>
            {anyChange && Math.round(newNet * 100) !== Math.round(Number(inv.net) * 100) && <span style={{ color: 'var(--g400)', textDecoration: 'line-through', marginRight: 8 }}>{money(inv.net)}</span>}
            <strong>{money(newNet)}</strong>
          </span>
        </div>
        <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Already paid</span><span>{money(paid)}</span></div>
        {anyChange && belowPaid && (
          <div className="msg-err" style={{ margin: '6px 0 0' }}>
            <i className="ti ti-alert-triangle"></i> The total can&apos;t be less than the {money(paid)} already paid. Adjust or remove the payment first, then edit the invoice.
          </div>
        )}
        {anyChange && !belowPaid && due > 0 && (
          <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)', fontWeight: 700 }}><span>Balance due after edit</span><span>{money(due)}</span></div>
        )}
      </div>

      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving || !anyChange || belowPaid}>
          <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save changes'}
        </button>
        <button className="btn" onClick={embedded ? load : onClose} disabled={saving || (embedded && !anyChange)}>Discard</button>
      </div>

      <VoidSection ctx={ctx} invoiceId={invoiceId} onVoided={(inv, credited, r) => onVoided?.(inv, credited, r)} refresh={refresh} />

      {askReason && (
        <EditReasonModal
          title={`Reason for editing ${inv.invoice_number}`}
          summary={`New total ${money(newNet)}${dateChanged ? `, dated ${fmtDay(newDate)}` : ''}. The reason is saved with this change in the invoice history.`}
          saving={saving}
          error={reasonError}
          onSave={saveWithReason}
          onCancel={() => { if (!saving) setAskReason(false); }}
        />
      )}
    </div>
  );
}
