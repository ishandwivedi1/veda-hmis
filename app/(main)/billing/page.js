import Link from 'next/link';
import BillingTabs from './billing-tabs';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus, getDischargedUnbilledSurgeries } from './actions';
import RecentInvoicesTable from './recent-invoices-table';
import PendingBillingWidget from './pending-billing-widget';

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
  const [data, todaysVisitsData, dischargedUnbilled] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
    getDischargedUnbilledSurgeries(),
  ]);
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />

      {/* SURGERY BILLING -- discharged patients whose surgery package
          hasn't been billed yet. Advance was already collected pre-op
          (OT Dashboard); this is where the full invoice actually gets
          generated. */}
      {dischargedUnbilled.length > 0 && (
        <div className="card" style={{ marginBottom: 20, border: '1.5px solid var(--red)' }}>
          <div className="card-title" style={{ marginBottom: 4 }}>
            <i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery Billing
            <span className="badge b-red" style={{ marginLeft: 8 }}>{dischargedUnbilled.length}</span>
          </div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            Discharged, package not yet billed. Click a patient to open New Invoice, prefilled and editable.
          </div>
          <table className="tbl">
            <thead><tr><th>Discharged</th><th>Patient</th><th>Surgery</th><th>Package</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {dischargedUnbilled.map((r) => {
                const sc = r.surgical_cases;
                return (
                  <tr key={sc.id}>
                    <td style={{ fontSize: 12 }}>{new Date(r.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                    <td>
                      <strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong>
                      <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span>
                    </td>
                    <td style={{ fontSize: 12 }}>{sc.procedure_name} ({sc.eye})</td>
                    <td style={{ fontSize: 12 }}>{sc.master_packages?.name || '--'}</td>
                    <td style={{ fontWeight: 600 }}>{RUPEE(sc.master_packages?.price)}</td>
                    <td>
                      <Link href={`/billing/new?pkgCaseId=${sc.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> Bill Now
                      </Link>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      {/* TODAY'S VISITS + PENDING BILLING side by side */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
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

        <PendingBillingWidget />
      </div>

      {/* RECENT INVOICES + OUTSTANDING */}
      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        <RecentInvoicesTable invoices={data.todaysInvoices} />

        <div className="card">
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
  );
}
