'use client';

// Permanent change history for one invoice, newest first.
// Reads billing_audit_log (before/after snapshots) + the older
// invoice_modifications log (cancellations).

import { useState, useEffect } from 'react';
import { getInvoiceHistory } from '@/lib/rpc-reads/billing__invoice-edit-actions'; // parallel reads (tools/parallel-reads)

const money = (n) => `Rs.${(Math.round((Number(n) || 0) * 100) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
const when = (d) => new Date(d).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

const LEGACY_LABEL = { cancelled: 'Cancelled', line_item_removed: 'Item removed', invoice_date_changed: 'Date changed', invoice_voided: 'Cancelled / Voided' };

const SIDE_EFFECT_TEXT = {
  prescription_back_to_pending: (s) => `${s.service}: prescription sent back to Pending in Pharmacy`,
  prescriptions_back_to_pending: (s) => `${s.count} prescription(s) sent back to Pending in Pharmacy`,
  investigations_back_to_pending: (s) => `${s.count} investigation order(s) back to Pending billing`,
  procedures_back_to_pending: (s) => `${s.count} OPD procedure(s) back to Pending billing`,
  biometry_back_to_pending: (s) => `${s.count} biometry record(s) back to Pending billing`,
  surgical_case_unbilled: (s) => `${s.service ? `${s.service}: ` : ''}surgical case marked as not billed`,
  surgical_case_not_found: (s) => `${s.service}: no matching surgical case found to un-bill -- check Surgical Journey`,
  surgical_case_ambiguous: (s) => `${s.service}: ${s.count} billed surgical cases could match, none was changed -- un-bill the right one in Surgical Journey`,
};
const fmtDate = (d) => (d ? new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--');

function describeLine(l) {
  return `${l.service_name} x${l.qty}${Number(l.disc) > 0 ? ` (disc ${money(l.disc)})` : ''} = ${money(l.net)}`;
}

function diffLines(before, after) {
  const b = Object.fromEntries((before?.lines || []).map((l) => [l.id, l]));
  const a = Object.fromEntries((after?.lines || []).map((l) => [l.id, l]));
  const out = [];
  for (const id of Object.keys(b)) {
    if (!a[id]) out.push({ kind: 'removed', text: describeLine(b[id]) });
    else if (b[id].qty !== a[id].qty || Number(b[id].disc) !== Number(a[id].disc) || Number(b[id].net) !== Number(a[id].net)) {
      out.push({ kind: 'changed', text: `${describeLine(b[id])}  →  x${a[id].qty}${Number(a[id].disc) > 0 ? ` (disc ${money(a[id].disc)})` : ''} = ${money(a[id].net)}` });
    }
  }
  for (const id of Object.keys(a)) if (!b[id]) out.push({ kind: 'added', text: describeLine(a[id]) });
  return out;
}

const KIND_STYLE = {
  removed: { icon: 'ti-minus', color: 'var(--red)', label: 'Removed' },
  added: { icon: 'ti-plus', color: 'var(--green)', label: 'Added' },
  changed: { icon: 'ti-arrows-exchange', color: 'var(--amber)', label: 'Changed' },
};

export default function InvoiceHistory({ invoiceId, refreshKey }) {
  const [entries, setEntries] = useState(null);

  useEffect(() => {
    let live = true;
    getInvoiceHistory(invoiceId).then((e) => { if (live) setEntries(e); }).catch(() => { if (live) setEntries([]); });
    return () => { live = false; };
  }, [invoiceId, refreshKey]);

  if (!entries || entries.length === 0) return null;

  return (
    <div className="card" style={{ marginTop: 16 }}>
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-history" style={{ color: 'var(--blue)' }}></i> Change history
        <span className="badge b-gray" style={{ marginLeft: 6 }}>{entries.length}</span>
      </div>
      {entries.map((e) => (
        <div key={e.id} style={{ borderLeft: '3px solid var(--blue-lt)', padding: '6px 0 8px 10px', marginBottom: 8, fontSize: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8, flexWrap: 'wrap' }}>
            <strong>{e.action === 'invoice_edited' ? 'Edited' : (LEGACY_LABEL[e.action] || e.action)}</strong>
            <span style={{ color: 'var(--g500)' }}>{when(e.at)} -- {e.by}</span>
          </div>
          {e.reason && <div style={{ color: 'var(--g600)', marginTop: 2 }}>Reason: {e.reason}</div>}
          {e.details && <div style={{ color: 'var(--g500)', marginTop: 2 }}>{e.details}</div>}
          {e.action === 'invoice_date_changed' && (
            <div style={{ marginTop: 4, color: 'var(--g600)' }}>
              <i className="ti ti-calendar-event"></i> {fmtDate(e.before?.date)} → <strong>{fmtDate(e.after?.date)}</strong>
            </div>
          )}
          {e.action === 'invoice_voided' && (
            <div style={{ marginTop: 4, color: 'var(--g600)' }}>
              Total was {money(e.before?.net)}
              {Number(e.after?.credited_to_patient) > 0
                ? <span style={{ color: 'var(--blue)' }}> -- {money(e.after.credited_to_patient)} paid on it moved to patient credit ({(e.after.credit_moves || []).map((m) => `${m.receipt} ${money(m.amount)}`).join(', ')})</span>
                : ' -- nothing had been paid'}
              {(e.after?.side_effects || []).map((s, i) => (
                <div key={i} style={{ color: ['surgical_case_not_found', 'surgical_case_ambiguous'].includes(s.effect) ? 'var(--amber)' : 'var(--g500)', marginTop: 2 }}>
                  <i className="ti ti-link"></i> {(SIDE_EFFECT_TEXT[s.effect] || ((x) => x.effect))(s)}
                </div>
              ))}
            </div>
          )}
          {e.action === 'invoice_edited' && (
            <>
              <div style={{ marginTop: 4 }}>
                {diffLines(e.before, e.after).map((d, i) => (
                  <div key={i} style={{ color: KIND_STYLE[d.kind].color }}>
                    <i className={`ti ${KIND_STYLE[d.kind].icon}`}></i> {KIND_STYLE[d.kind].label}: {d.text}
                  </div>
                ))}
              </div>
              <div style={{ marginTop: 4, color: 'var(--g600)' }}>
                Total {money(e.before?.net)} → <strong>{money(e.after?.net)}</strong>
                {Number(e.after?.credited_to_patient) > 0 && (
                  <span style={{ color: 'var(--blue)' }}> -- {money(e.after.credited_to_patient)} moved to patient credit</span>
                )}
              </div>
              {(e.after?.discount_reasons || []).length > 0 && (
                <div style={{ color: 'var(--g500)', marginTop: 2 }}>
                  Discount reason: {e.after.discount_reasons.map((r) => r.reason).join('; ')}
                </div>
              )}
              {(e.after?.side_effects || []).map((s, i) => (
                <div key={i} style={{ color: ['surgical_case_not_found', 'surgical_case_ambiguous'].includes(s.effect) ? 'var(--amber)' : 'var(--g500)', marginTop: 2 }}>
                  <i className="ti ti-link"></i> {(SIDE_EFFECT_TEXT[s.effect] || ((x) => `${x.service}: ${x.effect}`))(s)}
                </div>
              ))}
            </>
          )}
        </div>
      ))}
    </div>
  );
}
