import Link from 'next/link';
import PaymentsTabs from './payments-tabs';
import { getPaymentsDashboardData } from './actions';

const MODE_COLOR = {
  Cash: '#5eead4', UPI: '#93c5fd', Card: '#fca5a5', Cheque: '#fcd34d', 'Bank Transfer': '#d8b4fe',
};

function fmt(n) {
  return `Rs.${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtCompact(n) {
  const v = Number(n || 0);
  if (v >= 100000) return `Rs.${(v / 100000).toFixed(2)}L`;
  return fmt(v);
}

export default async function PaymentsDashboardPage() {
  const data = await getPaymentsDashboardData();
  const modeEntries = Object.entries(data.summary.byMode).filter(([, amt]) => amt !== 0);
  const modeTotal = modeEntries.reduce((s, [, amt]) => s + Math.abs(amt), 0);
  const deptEntries = Object.entries(data.revenueByDept).sort((a, b) => b[1] - a[1]);
  const maxDept = deptEntries.length ? deptEntries[0][1] : 1;

  return (
    <div>
      <PaymentsTabs />

      {/* HERO -- the one deliberately bold element on this page. Everything
          else stays quiet by design so this stays the focal point. */}
      <div
        style={{
          background: 'linear-gradient(135deg, var(--blue-dk) 0%, var(--blue) 100%)',
          borderRadius: 'var(--r-lg)',
          padding: '28px 32px',
          marginBottom: 20,
          color: '#fff',
          boxShadow: 'var(--shadow-lg)',
        }}
      >
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', flexWrap: 'wrap', gap: 16 }}>
          <div>
            <div style={{ fontFamily: 'var(--font-body-stack)', fontSize: 11, fontWeight: 700, letterSpacing: '.6px', textTransform: 'uppercase', color: 'rgba(255,255,255,.65)', marginBottom: 6 }}>
              Today&apos;s Collection
            </div>
            <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 42, fontWeight: 800, letterSpacing: '-1px', lineHeight: 1 }}>
              {fmt(data.summary.total)}
            </div>
            <div style={{ fontSize: 12.5, color: 'rgba(255,255,255,.75)', marginTop: 8 }}>
              {data.summary.count} transaction{data.summary.count === 1 ? '' : 's'} recorded
            </div>
          </div>

          <div style={{ textAlign: 'right' }}>
            {data.dayOpen ? (
              <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, background: 'rgba(255,255,255,.14)', padding: '6px 12px', borderRadius: 20, fontSize: 12, fontWeight: 600 }}>
                <span style={{ width: 7, height: 7, borderRadius: '50%', background: '#5eead4', display: 'inline-block' }}></span>
                Day open{data.dayOpening ? ` since ${new Date(data.dayOpening.opened_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}` : ''}
              </div>
            ) : (
              <Link href="/cash-management" style={{ textDecoration: 'none' }}>
                <div style={{ display: 'inline-flex', alignItems: 'center', gap: 6, background: 'rgba(255,255,255,.14)', padding: '6px 12px', borderRadius: 20, fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>
                  <span style={{ width: 7, height: 7, borderRadius: '50%', background: '#fca5a5', display: 'inline-block' }}></span>
                  Day not open -- open now
                </div>
              </Link>
            )}
          </div>
        </div>

        {modeEntries.length > 0 && (
          <div style={{ marginTop: 24 }}>
            <div style={{ display: 'flex', height: 8, borderRadius: 4, overflow: 'hidden', marginBottom: 10, background: 'rgba(255,255,255,.12)' }}>
              {modeEntries.map(([mode, amt]) => (
                <div key={mode} style={{ width: `${(Math.abs(amt) / modeTotal) * 100}%`, background: MODE_COLOR[mode] || '#e2e8f0' }} title={`${mode}: ${fmt(amt)}`}></div>
              ))}
            </div>
            <div style={{ display: 'flex', gap: 18, flexWrap: 'wrap' }}>
              {modeEntries.map(([mode, amt]) => (
                <div key={mode} style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12 }}>
                  <span style={{ width: 8, height: 8, borderRadius: '50%', background: MODE_COLOR[mode] || '#e2e8f0', display: 'inline-block' }}></span>
                  <span style={{ color: 'rgba(255,255,255,.75)' }}>{mode}</span>
                  <span style={{ fontWeight: 700 }}>{fmt(amt)}</span>
                </div>
              ))}
            </div>
          </div>
        )}
      </div>

      {/* SUPPORTING STATS -- quiet by design, hero already carries the page */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ marginBottom: 0 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
            <i className="ti ti-receipt-2"></i> Transactions Today
          </div>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 26, fontWeight: 700, color: 'var(--g900)' }}>{data.summary.count}</div>
        </div>
        <div className="card" style={{ marginBottom: 0 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
            <i className="ti ti-clock-exclamation" style={{ color: 'var(--red)' }}></i> Outstanding Dues
          </div>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 26, fontWeight: 700, color: 'var(--red)' }}>{fmtCompact(data.outstandingTotal)}</div>
          <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 2 }}>across {data.outstandingCount} invoice{data.outstandingCount === 1 ? '' : 's'}</div>
        </div>
        <div className="card" style={{ marginBottom: 0 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
            <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Advance Balances Held
          </div>
          <div style={{ fontFamily: 'var(--font-display-stack)', fontSize: 26, fontWeight: 700, color: 'var(--purple)' }}>{fmtCompact(data.advanceTotal)}</div>
          <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 2 }}>across {data.advanceCount} patient{data.advanceCount === 1 ? '' : 's'}</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 20 }}>
        <div>
          {/* REVENUE BY DEPARTMENT */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 14 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Revenue by Department -- Today</div>
            {deptEntries.length === 0 ? (
              <div style={{ padding: '20px 0', textAlign: 'center', color: 'var(--g400)', fontSize: 13 }}>No invoices generated yet today.</div>
            ) : (
              deptEntries.map(([dept, amt]) => (
                <div key={dept} style={{ marginBottom: 12 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, marginBottom: 4 }}>
                    <span style={{ fontWeight: 600, color: 'var(--g700)' }}>{dept}</span>
                    <span style={{ fontWeight: 700, color: 'var(--g900)' }}>{fmt(amt)}</span>
                  </div>
                  <div style={{ height: 7, borderRadius: 4, background: 'var(--g100)', overflow: 'hidden' }}>
                    <div style={{ height: '100%', width: `${(amt / maxDept) * 100}%`, background: 'linear-gradient(90deg, var(--teal), var(--blue))', borderRadius: 4 }}></div>
                  </div>
                </div>
              ))
            )}
          </div>

          {/* RECENT TRANSACTIONS */}
          <div className="card">
            <div className="card-head">
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Recent Transactions</div>
              <Link href="/payments/receipt" style={{ fontSize: 12, color: 'var(--blue)', textDecoration: 'none', fontWeight: 600 }}>View all &rarr;</Link>
            </div>
            <table className="tbl">
              <thead><tr><th>Receipt</th><th>Patient</th><th>Time</th><th>Mode</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {data.recentReceipts.map((r) => (
                  <tr key={r.id}>
                    <td style={{ fontFamily: 'monospace', fontSize: 11.5 }}>{r.receipt_number}</td>
                    <td>{r.patients?.first_name} {r.patients?.last_name}</td>
                    <td style={{ color: 'var(--g500)', fontSize: 12 }}>{new Date(r.collected_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                    <td style={{ fontSize: 12 }}>{(r.payment_modes || []).map((m) => m.mode).join('+')}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: r.payment_type === 'refund' ? 'var(--red)' : 'var(--g800)' }}>
                      {r.payment_type === 'refund' ? '-' : ''}{fmt(r.total_amount)}
                    </td>
                  </tr>
                ))}
                {data.recentReceipts.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No transactions recorded yet.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </div>

        <div>
          {/* NEEDS ATTENTION -- oldest/largest outstanding dues */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 12 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Largest Outstanding Dues</div>
            {data.topOutstanding.length === 0 ? (
              <div style={{ padding: '10px 0', textAlign: 'center', color: 'var(--g400)', fontSize: 12.5 }}>Nothing outstanding right now.</div>
            ) : (
              data.topOutstanding.map((inv) => (
                <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{inv.invoice_number}</div>
                  </div>
                  <div style={{ fontWeight: 700, color: 'var(--red)', fontSize: 13 }}>{fmt(inv.net - inv.paid)}</div>
                </div>
              ))
            )}
            {data.outstandingCount > data.topOutstanding.length && (
              <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 8, textAlign: 'center' }}>
                +{data.outstandingCount - data.topOutstanding.length} more
              </div>
            )}
          </div>

          {/* NEEDS ATTENTION -- largest advance balances */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 12 }}><i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Largest Advance Balances</div>
            {data.topAdvances.length === 0 ? (
              <div style={{ padding: '10px 0', textAlign: 'center', color: 'var(--g400)', fontSize: 12.5 }}>No advance balances on file.</div>
            ) : (
              data.topAdvances.map((a) => (
                <div key={a.patient.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 600 }}>{a.patient.first_name} {a.patient.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{a.patient.uhid}</div>
                  </div>
                  <div style={{ fontWeight: 700, color: 'var(--purple)', fontSize: 13 }}>{fmt(a.balance)}</div>
                </div>
              ))
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
