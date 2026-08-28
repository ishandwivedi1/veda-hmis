'use client';

import { formatPatientName } from '@/lib/patientName';
import Link from 'next/link';
import { openPrintPopup } from '@/lib/printPopup';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;
const STATUS_BADGE = { Pending: 'b-amber', Partial: 'b-blue' };

// Drill-down for the Outstanding KPI card -- lists the specific
// invoices behind that number so a person can go straight to
// collecting payment on one, instead of the count/total being a
// dead-end figure. Same row shape as Recent Invoices, plus a Paid/
// Balance breakdown and a direct Collect Payment link per invoice.
export default function OutstandingInvoicesTable({ invoices, todayOnly }) {
  return (
    <div style={{ marginBottom: 16 }}>
      <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
        <i className="ti ti-file-invoice"></i> Outstanding Invoices
        <span className="badge b-red" style={{ marginLeft: 8 }}>{invoices.length}</span>
        <span style={{ marginLeft: 8, fontWeight: 500, textTransform: 'none', color: 'var(--g400)' }}>
          {todayOnly ? '-- created today' : '-- all time'}
        </span>
      </div>
      <div style={{ maxHeight: 420, overflowY: 'auto' }}>
        <table className="tbl">
          <thead>
            <tr>
              <th>Invoice #</th><th>Patient</th><th>Visit</th><th>Date</th>
              <th>Net</th><th>Paid</th><th>Balance</th><th>Status</th><th></th>
            </tr>
          </thead>
          <tbody>
            {invoices.map((inv) => {
              const balance = Math.max(0, Number(inv.net) - Number(inv.paid));
              return (
                <tr key={inv.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--blue)' }}>{inv.invoice_number || '--'}</td>
                  <td>
                    <div style={{ fontWeight: 600 }}>{formatPatientName(inv.patients)}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.patients?.uhid}</div>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                  <td style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {new Date(inv.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' })}
                  </td>
                  <td>{RUPEE(inv.net)}</td>
                  <td>{RUPEE(inv.paid)}</td>
                  <td style={{ fontWeight: 700, color: 'var(--red)' }}>{RUPEE(balance)}</td>
                  <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      {inv.patient_id && (
                        <Link
                          href={`/payments/collect?patientId=${inv.patient_id}&invoiceId=${inv.id}`}
                          className="btn btn-primary btn-sm"
                          style={{ textDecoration: 'none' }}
                          title="Collect Payment"
                        >
                          <i className="ti ti-cash"></i> Collect
                        </Link>
                      )}
                      <Link href={`/billing/details?q=${inv.patients?.uhid || ''}`} className="btn btn-sm" style={{ textDecoration: 'none' }} title="View">
                        <i className="ti ti-eye"></i>
                      </Link>
                      <button onClick={() => openPrintPopup(`/invoice-print/${inv.id}`)} className="btn btn-sm" title="Print">
                        <i className="ti ti-printer"></i>
                      </button>
                    </div>
                  </td>
                </tr>
              );
            })}
            {invoices.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No outstanding invoices {todayOnly ? 'created today' : ''}.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
