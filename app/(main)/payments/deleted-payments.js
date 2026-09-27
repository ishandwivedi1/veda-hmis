'use client';

// Receipts that were deleted, and credit applications that were removed --
// kept permanently in billing_audit_log (Zoho's "deleted transactions").

import { useState, useEffect } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { getDeletedPayments } from '@/lib/rpc-reads/payments__payment-edit-actions'; // parallel reads (tools/parallel-reads)

const money = (n) => `Rs.${(Math.round((Number(n) || 0) * 100) / 100).toLocaleString('en-IN', { maximumFractionDigits: 2 })}`;
const when = (d) => new Date(d).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

export default function DeletedPayments() {
  const [rows, setRows] = useState(null);
  useEffect(() => { getDeletedPayments().then(setRows).catch(() => setRows([])); }, []);

  if (!rows) return <div className="card" style={{ color: 'var(--g400)', textAlign: 'center' }}>Loading...</div>;

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <table className="tbl">
        <thead>
          <tr><th>Receipt</th><th>Originally</th><th>Patient</th><th>Amount / modes</th><th>Had paid</th><th>Removed</th><th>Reason</th></tr>
        </thead>
        <tbody>
          {rows.map((r) => {
            const b = r.before_data || {};
            return (
              <tr key={r.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>
                  {r.action === 'credit_application_removed' ? <span className="badge b-amber">Credit application</span> : r.entity_ref}
                </td>
                <td style={{ fontSize: 11 }}>{b.date || '--'}</td>
                <td style={{ fontWeight: 600, fontSize: 12 }}>{r.patient ? `${formatPatientName(r.patient)} (${r.patient.uhid})` : '--'}</td>
                <td style={{ fontSize: 11 }}>
                  <strong>{money(b.total_amount)}</strong>
                  <div style={{ color: 'var(--g500)' }}>{(b.modes || []).map((m) => `${m.mode} ${money(m.amount)}`).join(', ')}</div>
                </td>
                <td style={{ fontSize: 11 }}>{(b.allocations || []).map((a) => `${a.invoice_number} ${money(a.amount)}`).join(', ') || (Number(b.credit) > 0 ? `Credit ${money(b.credit)}` : '--')}</td>
                <td style={{ fontSize: 11 }}>{when(r.changed_at)}<div style={{ color: 'var(--g500)' }}>{r.by}</div></td>
                <td style={{ fontSize: 11.5 }}>{r.reason}</td>
              </tr>
            );
          })}
          {rows.length === 0 && (
            <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts have been deleted.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}
