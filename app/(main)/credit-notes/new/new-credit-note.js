'use client';

// New Credit Note (Zoho-style). Patient -> the invoice it corrects -> pick
// that invoice's lines (qty adjustable) and/or add custom lines -> reason,
// approver -> optionally apply the credit to that invoice straight away.
// Saved by cn_create (migration 045).

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { createCreditNote } from '../actions';
import { getCreditNoteFormData, searchPatientsForCreditNote } from '@/lib/rpc-reads/credit-notes__actions'; // parallel reads (tools/parallel-reads)

const REASONS = ['Billing correction', 'Service cancellation', 'Service not rendered', 'Approved financial adjustment', 'Goodwill gesture', 'Insurance adjustment', 'Other'];
const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' });

export default function NewCreditNote() {
  const searchParams = useSearchParams();
  const router = useRouter();
  const [patientId, setPatientId] = useState(searchParams.get('patientId') || '');
  const [invoiceId, setInvoiceId] = useState(searchParams.get('invoiceId') || '');
  const [form, setForm] = useState(null); // { patient, invoices, approvers, lines, creditedSoFar }
  const [q, setQ] = useState('');
  const [results, setResults] = useState([]);

  const [picked, setPicked] = useState({}); // lineId -> { on, qty }
  const [custom, setCustom] = useState([]); // [{ description, qty, rate }]
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');
  const [applyNow, setApplyNow] = useState(true);
  const [applyAmt, setApplyAmt] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    const d = await getCreditNoteFormData(patientId || null, invoiceId || null);
    setForm(d);
    setPicked({});
  }, [patientId, invoiceId]);
  useEffect(() => { load(); }, [load]);

  useEffect(() => {
    if (patientId) return;
    const t = setTimeout(async () => setResults(await searchPatientsForCreditNote(q)), 250);
    return () => clearTimeout(t);
  }, [q, patientId]);

  const invoice = form?.invoices.find((i) => i.id === invoiceId) || null;
  const invoiceDue = invoice ? r2(Number(invoice.net) - Number(invoice.paid)) : 0;
  const maxCredit = invoice ? r2(Number(invoice.net) - (form?.creditedSoFar || 0)) : 0;

  // Per-unit value actually billed (after discount), rounded DOWN to the
  // paisa so crediting every unit can never total more than the line.
  const unitRate = (li) => Math.floor((Number(li.net) / (Number(li.qty) || 1)) * 100 + 1e-6) / 100;
  const items = [
    ...(form?.lines || []).filter((li) => picked[li.id]?.on).map((li) => ({
      invoice_line_item_id: li.id, description: li.service_name, dept: li.dept || '',
      qty: Number(picked[li.id].qty) || 0, rate: unitRate(li),
    })),
    ...custom.filter((c) => c.description.trim()).map((c) => ({ description: c.description.trim(), dept: '', qty: Number(c.qty) || 0, rate: Number(c.rate) || 0 })),
  ];
  const total = r2(items.reduce((s, it) => s + r2(it.qty * it.rate), 0));
  const suggestedApply = r2(Math.min(total, invoiceDue));

  useEffect(() => { setApplyAmt(suggestedApply > 0 ? String(suggestedApply) : ''); }, [suggestedApply]);

  function toggleLine(li) {
    setPicked((p) => ({ ...p, [li.id]: p[li.id]?.on ? { ...p[li.id], on: false } : { on: true, qty: p[li.id]?.qty ?? Number(li.qty) } }));
  }

  async function save() {
    if (saving) return;
    setError('');
    if (!patientId) { setError('Choose a patient.'); return; }
    if (!invoiceId) { setError('Choose the invoice this credit note is for.'); return; }
    if (items.length === 0 || total <= 0) { setError('Pick at least one item or add a line.'); return; }
    const badQty = items.find((it) => it.invoice_line_item_id && it.qty > Number(form.lines.find((l) => l.id === it.invoice_line_item_id)?.qty || 0));
    if (badQty) { setError(`Quantity for "${badQty.description}" is more than was billed.`); return; }
    if (total > maxCredit) { setError(`This invoice can take at most ${money(maxCredit)} more in credit notes.`); return; }
    if (!reason) { setError('Choose a reason.'); return; }
    if (!approvedBy) { setError('Choose who approved it.'); return; }
    const apply = applyNow && invoiceDue > 0 ? r2(applyAmt) : 0;
    if (apply > suggestedApply) { setError(`At most ${money(suggestedApply)} can be applied to this invoice now.`); return; }
    setSaving(true);
    const res = await createCreditNote({ patientId, invoiceId, items, reason, approvedBy, remarks, applyAmount: apply });
    setSaving(false);
    if (res?.error) { setError(res.error); return; }
    router.push(`/credit-notes?creditNoteId=${res.creditNote.id}`);
  }

  if (!form) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  return (
    <div className="card" style={{ maxWidth: 980 }}>
      {/* Patient */}
      {!patientId ? (
        <div style={{ marginBottom: 14 }}>
          <label className="flbl">Patient *</label>
          <input className="fi" value={q} onChange={(e) => setQ(e.target.value)} placeholder="Name, UHID or mobile..." autoFocus />
          {results.length > 0 && (
            <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
              {results.map((p) => (
                <div key={p.id} onClick={() => { setPatientId(p.id); setInvoiceId(''); setResults([]); }} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                  <strong>{formatPatientName(p)}</strong> -- {p.uhid}
                </div>
              ))}
            </div>
          )}
        </div>
      ) : (
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', borderRadius: 8, padding: '8px 12px', marginBottom: 14 }}>
          <div><strong>{formatPatientName(form.patient)}</strong> <span style={{ color: 'var(--g500)' }}>{form.patient?.uhid}</span></div>
          <button type="button" className="btn btn-sm" onClick={() => { setPatientId(''); setInvoiceId(''); setQ(''); }}>Change</button>
        </div>
      )}

      {patientId && (
        <>
          <label className="flbl">Invoice this credit note is for *</label>
          <select className="fi" style={{ maxWidth: 480, marginBottom: 14 }} value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
            <option value="">-- Choose invoice --</option>
            {form.invoices.map((i) => (
              <option key={i.id} value={i.id}>{i.invoice_number} · {dateIST(i.created_at)} · {money(i.net)} · {i.status}</option>
            ))}
          </select>
          {form.invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>This patient has no invoices.</div>}
        </>
      )}

      {invoice && (
        <>
          <div className="card-title" style={{ fontSize: 13, marginBottom: 6 }}>Items being credited</div>
          <table className="tbl">
            <thead><tr><th style={{ width: 30 }}></th><th>Item (from {invoice.invoice_number})</th><th style={{ textAlign: 'right' }}>Billed qty</th><th style={{ textAlign: 'right', width: 100 }}>Credit qty</th><th style={{ textAlign: 'right' }}>Rate</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
            <tbody>
              {form.lines.map((li) => {
                const p = picked[li.id];
                return (
                  <tr key={li.id} style={{ background: p?.on ? 'var(--blue-lt)' : 'transparent' }}>
                    <td><input type="checkbox" checked={!!p?.on} onChange={() => toggleLine(li)} /></td>
                    <td>{li.service_name}{li.dept && <span style={{ fontSize: 11, color: 'var(--g400)', marginLeft: 6 }}>{li.dept}</span>}</td>
                    <td style={{ textAlign: 'right' }}>{Number(li.qty)}</td>
                    <td style={{ textAlign: 'right' }}>
                      <input className="fi fi-sm" type="number" min="0" step="1" style={{ width: 80, textAlign: 'right' }} disabled={!p?.on}
                        value={p?.on ? p.qty : ''} onChange={(e) => setPicked((x) => ({ ...x, [li.id]: { on: true, qty: e.target.value } }))} />
                    </td>
                    <td style={{ textAlign: 'right' }}>{money(unitRate(li))}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600 }}>{p?.on ? money(r2((Number(p.qty) || 0) * unitRate(li))) : ''}</td>
                  </tr>
                );
              })}
              {custom.map((c, i) => (
                <tr key={`c${i}`}>
                  <td><button type="button" className="btn btn-sm" title="Remove" onClick={() => setCustom((cs) => cs.filter((_, j) => j !== i))}><i className="ti ti-x"></i></button></td>
                  <td><input className="fi fi-sm" value={c.description} placeholder="Description" onChange={(e) => setCustom((cs) => cs.map((x, j) => (j === i ? { ...x, description: e.target.value } : x)))} /></td>
                  <td></td>
                  <td style={{ textAlign: 'right' }}><input className="fi fi-sm" type="number" min="0" style={{ width: 80, textAlign: 'right' }} value={c.qty} onChange={(e) => setCustom((cs) => cs.map((x, j) => (j === i ? { ...x, qty: e.target.value } : x)))} /></td>
                  <td style={{ textAlign: 'right' }}><input className="fi fi-sm" type="number" min="0" step="0.01" style={{ width: 100, textAlign: 'right' }} value={c.rate} onChange={(e) => setCustom((cs) => cs.map((x, j) => (j === i ? { ...x, rate: e.target.value } : x)))} /></td>
                  <td style={{ textAlign: 'right', fontWeight: 600 }}>{money(r2((Number(c.qty) || 0) * (Number(c.rate) || 0)))}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <button type="button" className="btn btn-sm" style={{ marginTop: 6 }} onClick={() => setCustom((cs) => [...cs, { description: '', qty: '1', rate: '' }])}><i className="ti ti-plus"></i> Add a line</button>

          <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 8 }}>
            <div style={{ minWidth: 260, fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 800 }}><span>Credit note total</span><span>{money(total)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)', fontSize: 12 }}><span>Most this invoice can take</span><span>{money(maxCredit)}</span></div>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(220px, 1fr))', gap: 10, marginTop: 12 }}>
            <div>
              <label className="flbl">Reason *</label>
              <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                <option value="">-- Choose --</option>
                {REASONS.map((r) => <option key={r}>{r}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Approved by *</label>
              <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
                <option value="">-- Choose --</option>
                {form.approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` (${a.designation})` : ''}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional" />
            </div>
          </div>

          <div style={{ marginTop: 14, padding: '10px 12px', borderRadius: 8, background: 'var(--g50)' }}>
            {invoiceDue > 0 ? (
              <label style={{ display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', fontSize: 13, cursor: 'pointer' }}>
                <input type="checkbox" checked={applyNow} onChange={(e) => setApplyNow(e.target.checked)} />
                Apply to {invoice.invoice_number} now (balance due {money(invoiceDue)}):
                <input className="fi fi-sm" type="number" min="0" step="0.01" style={{ width: 120 }} disabled={!applyNow} value={applyAmt} onChange={(e) => setApplyAmt(e.target.value)} />
                <span style={{ fontSize: 11.5, color: 'var(--g500)' }}>Anything not applied stays on the credit note for later bills.</span>
              </label>
            ) : (
              <div style={{ fontSize: 12.5, color: 'var(--g600)' }}>
                <i className="ti ti-info-circle"></i> {invoice.invoice_number} is fully paid. The {money(total)} stays on this credit note as credit and can be applied to the patient&apos;s next bill (or refunded from the payment).
              </div>
            )}
          </div>
        </>
      )}

      {error && <div className="msg-err" style={{ marginTop: 12 }}>{error}</div>}
      <div style={{ display: 'flex', gap: 8, marginTop: 14 }}>
        <button type="button" className="btn btn-primary" disabled={saving || !invoice} onClick={save}>{saving ? 'Saving...' : 'Save credit note'}</button>
        <Link href="/credit-notes" className="btn" style={{ textDecoration: 'none' }}>Cancel</Link>
      </div>
    </div>
  );
}
