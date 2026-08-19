'use client';

import Link from 'next/link';
import { useState } from 'react';
import PendingBillingWidget from './pending-billing-widget';
import RecentInvoicesTable from './recent-invoices-table';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

function StatCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderTop: `3px solid var(${color})` }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontSize: 24, fontWeight: 800, marginTop: 6 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

// Shared collapsible-section header -- same toggle affordance as the
// sidebar's group headings (chevron flips right/down), so a person
// already used to collapsing sidebar groups recognizes it here too.
function SectionHeader({ icon, iconColor, title, badgeCount, badgeCls, open, onToggle }) {
  return (
    <button
      type="button"
      onClick={onToggle}
      style={{ width: '100%', background: 'none', border: 'none', cursor: 'pointer', display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: 0, marginBottom: open ? 4 : 0, fontFamily: 'inherit' }}
    >
      <span className="card-title" style={{ marginBottom: 0 }}>
        <i className={`ti ${icon}`} style={{ color: iconColor }}></i> {title}
        {badgeCount > 0 && <span className={`badge ${badgeCls}`} style={{ marginLeft: 8 }}>{badgeCount}</span>}
      </span>
      <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
    </button>
  );
}

// Same IST-day comparison used in pending-billing-widget.js -- kept as
// a separate small copy rather than a shared import since it's a
// two-line pure function and this file already has its own RUPEE/
// VISIT_TYPE_COLOR helpers duplicated in the same spirit.
function istDateOnly(dateInput) {
  return new Date(dateInput).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function isToday(dateInput) {
  if (!dateInput) return false;
  return istDateOnly(dateInput) === istDateOnly(new Date());
}

function ScopeToggle({ todayOnly, onChange }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
      <span style={{ fontSize: 12, fontWeight: 600, color: 'var(--g500)' }}>Pending Bills:</span>
      <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
        <button
          type="button"
          onClick={() => onChange(true)}
          style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: todayOnly ? '#fff' : 'transparent', color: todayOnly ? 'var(--indigo)' : 'var(--g500)', cursor: 'pointer', boxShadow: todayOnly ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
        >
          Today
        </button>
        <button
          type="button"
          onClick={() => onChange(false)}
          style={{ padding: '6px 14px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: !todayOnly ? '#fff' : 'transparent', color: !todayOnly ? 'var(--indigo)' : 'var(--g500)', cursor: 'pointer', boxShadow: !todayOnly ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
        >
          Historical
        </button>
      </div>
    </div>
  );
}

export default function BillingDashboardClient({ dischargedUnbilled, todaysVisits, billingByVisit, todaysInvoices, outstandingInvoices, outstandingTotal }) {
  // Needs Action starts collapsed -- it's the "here's what's still
  // outstanding" detail view, not the first thing a person should have
  // to scroll past to see today's invoices.
  const [needsActionOpen, setNeedsActionOpen] = useState(false);
  const [showAllVisits, setShowAllVisits] = useState(false);
  const [pendingBillingTotal, setPendingBillingTotal] = useState(0);
  // Defaults to today -- pending bills should read as "what's due right
  // now", not a mixed list where a 2-week-old deferred item sits next
  // to something from this morning. Historical is one click away.
  const [todayOnly, setTodayOnly] = useState(true);

  const todaysInvoicesValue = todaysInvoices.reduce((s, i) => s + Number(i.net || 0), 0);

  const visitsWithBillingDue = todaysVisits.filter((v) => (billingByVisit[v.id]?.badge) === 'b-red');
  const visitsFullyBilled = todaysVisits.length - visitsWithBillingDue.length;
  const visitsToShow = showAllVisits ? todaysVisits : visitsWithBillingDue;

  const dischargedUnbilledShown = todayOnly
    ? dischargedUnbilled.filter((r) => isToday(r.discharge_date))
    : dischargedUnbilled;

  const needsActionCount = dischargedUnbilledShown.length + pendingBillingTotal;

  return (
    <div>
      <ScopeToggle todayOnly={todayOnly} onChange={setTodayOnly} />

      {/* KPI STRIP */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <StatCard label="Today's Invoices" value={todaysInvoices.length} sub={RUPEE(todaysInvoicesValue)} color="--blue" />
        <StatCard label="Outstanding" value={outstandingInvoices.length} sub={RUPEE(outstandingTotal)} color="--red" />
        <StatCard label="Pending Billing" value={pendingBillingTotal} sub={todayOnly ? 'Not yet invoiced -- today' : 'Not yet invoiced -- all time'} color="--amber" />
        <StatCard label="Surgery Billing Due" value={dischargedUnbilledShown.length} sub={todayOnly ? 'Discharged today, unbilled' : 'Discharged, unbilled -- all time'} color="--purple" />
      </div>

      {/* RECENT INVOICES -- full width, first thing after the KPI strip */}
      <div style={{ marginBottom: 20 }}>
        <RecentInvoicesTable invoices={todaysInvoices} />
      </div>

      {/* TODAY'S VISITS -- pending-billing visits shown by default;
          fully-billed visits collapse into a single expandable line
          instead of padding out the table with rows needing no action. */}
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
        </div>
        <table className="tbl">
          <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
          <tbody>
            {visitsToShow.map((v) => {
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
            {visitsToShow.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>
                {todaysVisits.length === 0 ? 'No visits yet today.' : 'No visits with billing pending -- everything is settled.'}
              </td></tr>
            )}
          </tbody>
        </table>
        {!showAllVisits && visitsFullyBilled > 0 && (
          <button type="button" className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setShowAllVisits(true)}>
            <i className="ti ti-chevron-down"></i> Show {visitsFullyBilled} fully billed visit{visitsFullyBilled === 1 ? '' : 's'}
          </button>
        )}
        {showAllVisits && (
          <button type="button" className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setShowAllVisits(false)}>
            <i className="ti ti-chevron-up"></i> Show pending billing only
          </button>
        )}
      </div>

      {/* NEEDS ACTION -- Surgery Billing + all four pending-billing
          categories (Investigation, Biometry, Consultation, Pharmacy),
          each laid out like Surgery Billing's own table. Collapsed by
          default; it's the detail view, not the first thing to greet
          someone opening the dashboard. */}
      <div className="card" style={{ border: needsActionCount > 0 ? '1.5px solid var(--red)' : undefined }}>
        <SectionHeader
          icon="ti-alert-circle" iconColor="var(--red)" title="Needs Action"
          badgeCount={needsActionCount} badgeCls="b-red"
          open={needsActionOpen} onToggle={() => setNeedsActionOpen((v) => !v)}
        />
        <div style={{ marginTop: needsActionOpen ? 10 : 0, display: needsActionOpen ? 'block' : 'none' }}>
            {dischargedUnbilledShown.length > 0 && (
              <div style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
                  <i className="ti ti-scalpel"></i> Surgery Billing
                  <span className="badge b-red" style={{ marginLeft: 8 }}>{dischargedUnbilledShown.length}</span>
                </div>
                <table className="tbl">
                  <thead><tr><th>Discharged</th><th>Patient</th><th>Surgery</th><th>Package</th><th>Amount</th><th></th></tr></thead>
                  <tbody>
                    {dischargedUnbilledShown.map((r) => {
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
            {todayOnly && dischargedUnbilledShown.length === 0 && dischargedUnbilled.length > 0 && (
              <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 16 }}>
                No surgery billing due from today -- {dischargedUnbilled.length} older case{dischargedUnbilled.length === 1 ? '' : 's'} in Historical.
              </div>
            )}

            <PendingBillingWidget bare todayOnly={todayOnly} onTotalChange={setPendingBillingTotal} />
          </div>
      </div>
    </div>
  );
}
