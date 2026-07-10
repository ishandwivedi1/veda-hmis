'use client';

import { useState } from 'react';
import { getPaymentReport } from '../actions';

const RPT_DEFS = [
  { id: 'daily', icon: 'ti-calendar', color: '--green', title: 'Daily Collection', desc: 'All payments for today' },
  { id: 'mode', icon: 'ti-credit-card', color: '--blue', title: 'Payment Mode Summary', desc: 'Cash vs UPI vs Card' },
  { id: 'cash', icon: 'ti-cash', color: '--amber', title: 'Cash Collection', desc: 'Cash receipts' },
  { id: 'upi', icon: 'ti-device-mobile', color: '--teal', title: 'UPI Collection', desc: 'UPI transactions' },
  { id: 'advance', icon: 'ti-wallet', color: '--purple', title: 'Advance Report', desc: 'Advances and adjustments' },
  { id: 'out', icon: 'ti-clock', color: '--red', title: 'Outstanding Balances', desc: 'Pending invoice dues' },
  { id: 'register', icon: 'ti-receipt', color: '--green', title: 'Receipt Register', desc: 'All receipts' },
  { id: 'cancel', icon: 'ti-x-circle', color: '--red', title: 'Refund Report', desc: 'Refunds processed' },
];

export default function PaymentReportsTab() {
  const [report, setReport] = useState(null);
  const [loading, setLoading] = useState(null);

  async function openReport(id) {
    setLoading(id);
    const data = await getPaymentReport(id);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})` }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-file"></i> {report.title}</div>
            <button className="btn btn-sm" onClick={() => setReport(null)}><i className="ti ti-x"></i> Close</button>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data.</td></tr>
              )}
            </tbody>
          </table>
          {report.total !== null && (
            <div style={{ textAlign: 'right', fontWeight: 700, marginTop: 10, fontSize: 14 }}>
              Total: Rs.{report.total.toFixed(2)}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

