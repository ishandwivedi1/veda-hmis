'use client';

// Credit Notes -- Zoho-style list + split view (2 Oct 2026).
// Click a credit note: items, balance, where it was applied, and
// Apply to invoices / PDF-Print / Void.

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { openPrintPopup } from '@/lib/printPopup';
import { searchCreditNotes, getCreditNote } from '@/lib/rpc-reads/credit-notes__actions'; // parallel reads (tools/parallel-reads)
import { applyCreditNote, voidCreditNote } from './actions';

const STATUS_BADGE = { Open: 'b-blue', Closed: 'b-gray', Void: 'b-red' };
const STATUS_LABEL = { Open: 'OPEN', Closed: 'CLOSED', Void: 'VOID' };
const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' });

// ─────────────────────────────────────────────────────────────────────
function ApplyToInvoices({ data, onDone, onCancel }) {
  const cn = data.creditNote;
  const [amounts, setAmounts] = useState({});
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');
  const total = r2(Object.values(amounts).reduce((s, v) => s + (Number(v) || 0), 0));

  function fillOldestFirst() {
    let left = cn.balance;
    const next = {};
    data.openInvoices.forEach((i) => {
      const a = r2(Math.min(left, i.due));
      if (a > 0) { next[i.id] = String(a); left = r2(left - a); }
    });
    setAmounts(next);
  }

  async function save() {
    if (saving) return;
    setError('');
    const rows = data.openInvoices.map((i) => ({ inv: i, amt: r2(amounts[i.id]) })).filter((x) => x.amt > 0);
    if (rows.length === 0) { setError('Enter an amount against at least one invoice.'); return; }
    if (total > cn.balance) { setError(`Only ${money(cn.balance)} is left on this credit note.`); return; }
    const over = rows.find((x) => x.amt > x.inv.due);
    if (over) { setError(`${over.inv.invoice_number} only has ${money(over.inv.due)} due.`); return; }
    setSaving(true);
    for (const x of rows) {
      const res = await applyCreditNote(cn.id, x.inv.id, x.amt);
      if (res?.error) { setSaving(false); setError(`${x.inv.invoice_number}: ${res.error}`); onDone(null); return; }
    }
    setSaving(false);
    onDone(`${money(total)} applied to ${rows.map((x) => x.inv.invoice_number).join(', ')}.`);
  }

  if (data.openInvoices.length === 0) {
    return (
      <div className="msg-info" style={{ fontSize: 12.5 }}>
        This patient has no unpaid invoices right now. The {money(cn.balance)} stays on this credit note and can be applied when the next bill is made.
        <div style={{ marginTop: 8 }}><button type="button" className="btn btn-sm" onClick={onCancel}>Close</button></div>
      </div>
    );
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8, flexWrap: 'wrap', gap: 6 }}>
        <span style={{ fontSize: 13 }}>Credit left: <strong>{money(cn.balance)}</strong></span>
        <button type="button" className="btn btn-sm" onClick={fillOldestFirst}>Fill oldest first</button>
      </div>
      <table className="tbl">
        <thead><tr><th>Invoice #</th><th>Date</th><th style={{ textAlign: 'right' }}>Balance due</th><th style={{ textAlign: 'right', width: 140 }}>Amount to credit</th></tr></thead>
        <tbody>
          {data.openInvoices.map((i) => (
            <tr key={i.id}>
              <td style={{ fontWeight: 600 }}>{i.invoice_number}</td>
              <td>{dateIST(i.created_at)}</td>
              <td style={{ textAlign: 'right' }}>{money(i.due)}</td>
              <td style={{ textAlign: 'right' }}>
                <input className="fi fi-sm" type="number" min="0" step="0.01" style={{ width: 120, textAlign: 'right' }}
                  value={amounts[i.id] || ''} onChange={(e) => setAmounts((a) => ({ ...a, [i.id]: e.target.value }))} />
              </td>
            </tr>
          ))}
        </tbody>
      </table>
      <div style={{ textAlign: 'right', fontSize: 13, marginTop: 6, color: total > cn.balance ? 'var(--red)' : 'var(--g700)' }}>
        Total to apply: <strong>{money(total)}</strong> of {money(cn.balance)}
      </div>
      {error && <div className="msg-err" style={{ marginTop: 8 }}>{error}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
        <button type="button" className="btn btn-primary" disabled={saving} onClick={save}>{saving ? 'Applying...' : 'Apply credits'}</button>
        <button type="button" className="btn" disabled={saving} onClick={onCancel}>Cancel</button>
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
function CreditNoteDetail({ id, onChanged, onClose }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | apply | void
  const [voidReason, setVoidReason] = useState('');
  const [busy, setBusy] = useState(false);
  const [flash, setFlash] = useState('');

  const load = useCallback(async () => {
    setError('');
    const d = await getCreditNote(id);
    if (d?.error) { setError(d.error); return; }
    setData(d);
  }, [id]);
  useEffect(() => { load(); }, [load]);

  async function doVoid() {
    if (busy) return;
    if (!voidReason.trim()) { setError('Enter a reason to void.'); return; }
    setBusy(true); setError('');
    const res = await voidCreditNote(id, voidReason);
    setBusy(false);
    if (res?.error) { setError(res.error); return; }
    setMode('view'); setFlash('Credit note voided.'); load(); onChanged();
  }

  if (!data) return <div className="card" style={{ padding: 24, color: error ? 'var(--red)' : 'var(--g400)' }}>{error || 'Loading...'}</div>;
  const cn = data.creditNote;
  const canApply = cn.status === 'Open' && cn.balance > 0;
  const canVoid = cn.status === 'Open' && cn.applied === 0;

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {cn.credit_note_number} <span className={`badge ${STATUS_BADGE[cn.status] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{STATUS_LABEL[cn.status] || cn.status}</span>
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {canApply && <button type="button" className={mode === 'apply' ? 'btn btn-sm btn-primary' : 'btn btn-sm btn-primary'} onClick={() => setMode(mode === 'apply' ? 'view' : 'apply')}><i className="ti ti-arrow-forward-up"></i> Apply to invoices</button>}
        <button type="button" className="btn btn-sm" onClick={() => openPrintPopup(`/credit-note-print/${cn.id}`)}><i className="ti ti-printer"></i> PDF/Print</button>
        {canVoid && <button type="button" className={mode === 'void' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode(mode === 'void' ? 'view' : 'void')}><i className="ti ti-ban"></i> Void</button>}
      </div>
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}><i className="ti ti-circle-check"></i> {flash}</div>}
      {error && <div className="msg-err" style={{ margin: '8px 16px 0' }}>{error}</div>}

      <div style={{ padding: 16 }}>
        {mode === 'apply' && (
          <ApplyToInvoices data={data} onCancel={() => setMode('view')}
            onDone={(msg) => { if (msg) { setMode('view'); setFlash(msg); } load(); onChanged(); }} />
        )}

        {mode === 'void' && (
          <div style={{ marginBottom: 12 }}>
            <label className="flbl">Reason for voiding *</label>
            <input className="fi" value={voidReason} onChange={(e) => setVoidReason(e.target.value)} placeholder="e.g. Created by mistake" />
            <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
              <button type="button" className="btn btn-danger" disabled={busy} onClick={doVoid}>{busy ? 'Voiding...' : 'Void credit note'}</button>
              <button type="button" className="btn" disabled={busy} onClick={() => setMode('view')}>Cancel</button>
            </div>
          </div>
        )}

        {mode !== 'apply' && (
          <>
            {cn.status === 'Void' && <div className="msg-err" style={{ marginBottom: 12 }}><i className="ti ti-ban"></i> Voided{cn.void_reason ? ` -- ${cn.void_reason}` : ''}{data.voidedByName ? ` (${data.voidedByName})` : ''}.</div>}
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', gap: 12, marginBottom: 12, fontSize: 13 }}>
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 700 }}>PATIENT</div>
                <div style={{ fontWeight: 700, fontSize: 15 }}>{formatPatientName(cn.patients)}</div>
                <div style={{ color: 'var(--g500)' }}>{cn.patients?.uhid}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div><span style={{ color: 'var(--g500)' }}>Date </span><strong>{dateIST(cn.created_at)}</strong></div>
                {cn.invoices?.invoice_number && <div><span style={{ color: 'var(--g500)' }}>Against </span><Link href={`/billing?invoiceId=${cn.invoice_id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{cn.invoices.invoice_number}</Link></div>}
                <div><span style={{ color: 'var(--g500)' }}>Reason </span>{cn.reason}</div>
              </div>
            </div>

            <table className="tbl">
              <thead><tr><th>#</th><th>Item</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Rate</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {cn.credit_note_items.map((it, i) => (
                  <tr key={it.id}>
                    <td>{i + 1}</td>
                    <td>{it.description}{it.dept && <span style={{ fontSize: 11, color: 'var(--g400)', marginLeft: 6 }}>{it.dept}</span>}</td>
                    <td style={{ textAlign: 'right' }}>{Number(it.qty)}</td>
                    <td style={{ textAlign: 'right' }}>{money(it.rate)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600 }}>{money(it.amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 10 }}>
              <div style={{ minWidth: 240, fontSize: 13, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span>{money(cn.amount)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}><span>Credits used</span><span>-{money(cn.applied)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 800, borderTop: '1px solid var(--g200)', color: cn.balance > 0 ? 'var(--blue)' : 'var(--g600)' }}><span>Credits remaining</span><span>{money(cn.balance)}</span></div>
              </div>
            </div>

            <div className="card-title" style={{ marginTop: 14, fontSize: 13 }}>Invoices credited</div>
            <table className="tbl">
              <thead><tr><th>Date</th><th>Invoice #</th><th>Ref</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {cn.credit_note_applications.map((a) => (
                  <tr key={a.id}>
                    <td>{dateIST(a.applied_at)}</td>
                    <td><Link href={`/billing?invoiceId=${a.invoice_id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{a.invoices?.invoice_number}</Link></td>
                    <td style={{ fontSize: 12, color: 'var(--g500)' }}>{a.payments?.receipt_number || ''}</td>
                    <td style={{ textAlign: 'right' }}>{money(a.amount)}</td>
                  </tr>
                ))}
                {cn.credit_note_applications.length === 0 && <tr><td colSpan={4} style={{ textAlign: 'center', color: 'var(--g400)', padding: 12 }}>Not applied to any invoice yet.</td></tr>}
              </tbody>
            </table>

            <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 10 }}>
              {data.createdByName && <>Created by {data.createdByName}. </>}
              {data.approvedByName && <>Approved by {data.approvedByName}. </>}
              {cn.remarks && <>Remarks: {cn.remarks}</>}
            </div>
          </>
        )}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
export default function CreditNotesScreen() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState('');
  const [status, setStatus] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('creditNoteId') || null);
  const reqId = useRef(0);

  const runSearch = useCallback(async () => {
    const my = ++reqId.current;
    setLoading(true);
    const data = await searchCreditNotes(query, status, dateFrom, dateTo);
    if (my !== reqId.current) return;
    setRows(data || []);
    setLoading(false);
  }, [query, status, dateFrom, dateTo]);

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  const split = !!selectedId;
  const openBalance = r2(rows.reduce((s, c) => s + (c.status === 'Open' ? c.balance : 0), 0));

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, gap: 8, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 22, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>Credit Notes</div>
        <Link href="/credit-notes/new" className="btn btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-plus"></i> New Credit Note</Link>
      </div>

      <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search credit note #, patient, UHID..." />
          <select className="fi" style={{ flex: 1, minWidth: 120 }} value={status} onChange={(e) => setStatus(e.target.value)}>
            <option value="">All statuses</option><option value="Open">Open</option><option value="Closed">Closed</option><option value="Void">Void</option>
          </select>
          <input type="date" className="fi" style={{ width: 150 }} value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} title="From" />
          <input type="date" className="fi" style={{ width: 150 }} value={dateTo} onChange={(e) => setDateTo(e.target.value)} title="To" />
        </div>
        <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
          {rows.length} shown{openBalance > 0 ? ` · ${money(openBalance)} of credit still unused` : ''}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
        <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
          {split ? (
            <div>
              {rows.map((c) => (
                <div key={c.id} onClick={() => setSelectedId(c.id)}
                  style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === c.id ? 'var(--blue-lt)' : 'transparent', opacity: c.status === 'Void' ? 0.55 : 1 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                    <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{formatPatientName(c.patients)}</span>
                    <span style={{ fontWeight: 700 }}>{money(c.amount)}</span>
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{c.credit_note_number} · {dateIST(c.created_at)}</div>
                  <div style={{ fontSize: 11, marginTop: 3, display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`}>{STATUS_LABEL[c.status] || c.status}</span>
                    {c.balance > 0 && <span style={{ color: 'var(--blue)', fontWeight: 600 }}>Left {money(c.balance)}</span>}
                  </div>
                </div>
              ))}
              {!loading && rows.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No credit notes.</div>}
            </div>
          ) : (
            <table className="tbl">
              <thead><tr><th>Date</th><th>Credit Note #</th><th>Patient</th><th>Against invoice</th><th>Reason</th><th>Status</th><th style={{ textAlign: 'right' }}>Amount</th><th style={{ textAlign: 'right' }}>Balance</th></tr></thead>
              <tbody>
                {rows.map((c) => (
                  <tr key={c.id} onClick={() => setSelectedId(c.id)} style={{ cursor: 'pointer', opacity: c.status === 'Void' ? 0.55 : 1 }}>
                    <td>{dateIST(c.created_at)}</td>
                    <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{c.credit_note_number}</td>
                    <td style={{ fontWeight: 600 }}>{formatPatientName(c.patients)} <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{c.patients?.uhid}</span></td>
                    <td>{c.invoices?.invoice_number || '--'}</td>
                    <td style={{ fontSize: 12, color: 'var(--g600)' }}>{c.reason}</td>
                    <td><span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`}>{STATUS_LABEL[c.status] || c.status}</span></td>
                    <td style={{ textAlign: 'right' }}>{money(c.amount)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: c.balance > 0 ? 'var(--blue)' : 'inherit' }}>{money(c.balance)}</td>
                  </tr>
                ))}
                {loading && rows.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                {!loading && rows.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No credit notes.</td></tr>}
              </tbody>
            </table>
          )}
        </div>

        {split && (
          <div style={{ position: 'sticky', top: 12 }}>
            <CreditNoteDetail key={selectedId} id={selectedId} onClose={() => setSelectedId(null)} onChanged={runSearch} />
          </div>
        )}
      </div>
    </div>
  );
}
