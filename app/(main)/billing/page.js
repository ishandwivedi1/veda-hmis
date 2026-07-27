import Link from 'next/link';
import BillingTabs from './billing-tabs';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus } from './actions';
import RecentInvoicesTable from './recent-invoices-table';
import InvestigationsBillingWidget from './investigations-billing-widget';
import ProceduresBillingWidget from './procedures-billing-widget';
import PharmacyBillingWidget from './pharmacy-billing-widget';
import BiometryBillingWidget from './biometry-billing-widget';
import PackageBillingWidget from './package-billing-widget';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

export default async function BillingDashboardPage() {
  const [data, todaysVisitsData] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
  ]);
  const deptEntries = Object.entries(data.byDept).sort((a, b) => b[1] - a[1]);
  const maxDept = deptEntries.length ? Math.max(...deptEntries.map(([, v]) => v)) : 0;
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />

      {/* STAT CARDS -- WS-086 */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Revenue</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{RUPEE(data.revenue)}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{data.todaysInvoices.length} invoices</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Collected Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{RUPEE(data.collected)}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>
            {data.revenue ? `${((data.collected / data.revenue) * 100).toFixed(1)}% collection rate` : 'No invoices yet'}
          </div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Outstanding</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{RUPEE(data.outstandingTotal)}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{data.outstandingInvoices.length} invoices pending</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Cancelled Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{data.cancelledToday}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>BR-BIL-007: Retained for audit</div>
        </div>
      </div>

      {/* TODAY'S VISITS -- moved here from Front Office Dashboard, since
          New Invoice / Modify are billing actions */}
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
        </div>
        <table className="tbl">
          <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
          <tbody>
            {todaysVisits.map((v) => {
              const billing = billingByVisit[v.id] || { count: 0, label: '--', badge: 'b-gray' };
              return (
                <tr key={v.id}>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                  <td>{new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                  </td>
                  <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                  <td>{v.profiles?.full_name || '--'}</td>
                  <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                  <td>
                    {billing.badge === 'b-red' && v.patients?.id ? (
                      <Link href={`/payments/collect?patientId=${v.patients.id}`} className="badge b-red" style={{ textDecoration: 'none', cursor: 'pointer' }}>
                        {billing.label}
                      </Link>
                    ) : (
                      <span className={`badge ${billing.badge}`}>{billing.label}</span>
                    )}
                    {billing.count > 1 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>({billing.count} invoices)</span>}
                  </td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> New Invoice
                      </Link>
                      {billing.count > 0 && (
                        <Link href={`/billing/cancel?visitId=${v.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                          <i className="ti ti-edit"></i> Modify
                        </Link>
                      )}
                    </div>
                  </td>
                </tr>
              );
            })}
            {todaysVisits.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        <div>
          {/* REVENUE BY DEPARTMENT */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-bar" style={{ color: 'var(--amber)' }}></i> Revenue by Department -- Today
            </div>
            {deptEntries.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices yet today.</div>}
            {deptEntries.map(([dept, amount]) => (
              <div key={dept} style={{ marginBottom: 10 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                  <span>{dept}</span><span style={{ fontWeight: 600 }}>{RUPEE(amount)}</span>
                </div>
                <div style={{ height: 8, background: 'var(--g100)', borderRadius: 4 }}>
                  <div style={{ width: `${maxDept ? (amount / maxDept) * 100 : 0}%`, height: '100%', background: 'var(--amber)', borderRadius: 4 }}></div>
                </div>
              </div>
            ))}
          </div>

          {/* RECENT INVOICES */}
          <RecentInvoicesTable invoices={data.todaysInvoices} />
        </div>

        <div>
          {/* PENDING BILLING QUEUES -- moved here from Front Office Dashboard */}
          <InvestigationsBillingWidget />
          <ProceduresBillingWidget />
          <PharmacyBillingWidget />
          <BiometryBillingWidget />
          <PackageBillingWidget />

          {/* OUTSTANDING INVOICES */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Outstanding Invoices</div>
              <span className="badge b-amber">{data.outstandingInvoices.length} pending</span>
            </div>
            <div style={{ maxHeight: 320, overflowY: 'auto' }}>
              {data.outstandingInvoices.map((inv) => (
                <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <div>
                    <div style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>{inv.patients?.uhid} -- {inv.purpose || '--'}</div>
                  </div>
                  <div style={{ textAlign: 'right' }}>
                    <div style={{ fontWeight: 700, color: 'var(--red)' }}>{RUPEE(Number(inv.net) - Number(inv.paid))}</div>
                    <Link href={`/payments/collect?patientId=${inv.patient_id}&invoiceId=${inv.id}`} style={{ fontSize: 11, color: 'var(--blue)', textDecoration: 'none' }}>
                      Collect &rarr;
                    </Link>
                  </div>
                </div>
              ))}
              {data.outstandingInvoices.length === 0 && (
                <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>Nothing outstanding.</div>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}
