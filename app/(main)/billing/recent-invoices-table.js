'use client';

import { useState } from 'react';
import Link from 'next/link';

const STATUS_BADGE = { Paid: 'b-green', Pending: 'b-amber', Partial: 'b-blue', Cancelled: 'b-gray' };

export default function RecentInvoicesTable({ invoices }) {
  const [filter, setFilter] = useState('');
  const filtered = filter ? invoices.filter((i) => i.status === filter) : invoices;

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title"><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> Recent Invoices</div>
        <select className="fi" style={{ width: 'auto', padding: '4px 8px', fontSize: 12 }} value={filter} onChange={(e) => setFilter(e.target.value)}>
          <option value="">All</option>
          <option value="Paid">Paid</option>
          <option value="Pending">Pending</option>
          <option value="Partial">Partial</option>
        </select>
      </div>
      <div style={{ maxHeight: 420, overflowY: 'auto' }}>
        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Patient</th><th>Visit</th><th>Dept</th><th>Amount</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {filtered.map((inv) => (
              <tr key={inv.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--blue)' }}>{inv.invoice_number || '--'}</td>
                <td>
                  <div style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.patients?.uhid}</div>
                </td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td style={{ fontSize: 12 }}>{inv.purpose || '--'}</td>
                <td style={{ fontWeight: 600 }}>Rs.{Number(inv.net).toLocaleString('en-IN')}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <Link href={`/billing/details?q=${inv.patients?.uhid || ''}`} className="btn btn-sm" style={{ textDecoration: 'none' }} title="View">
                      <i className="ti ti-eye"></i>
                    </Link>
                    <Link href={`/invoice-print/${inv.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }} title="Print">
                      <i className="ti ti-printer"></i>
                    </Link>
                  </div>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices {filter ? `with status "${filter}"` : 'yet today'}.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
