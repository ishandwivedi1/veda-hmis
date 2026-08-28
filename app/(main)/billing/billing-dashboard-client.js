'use client';

import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import { useState } from 'react';
import PendingBillingWidget from './pending-billing-widget';
import RecentInvoicesTable from './recent-invoices-table';
import OutstandingInvoicesTable from './outstanding-invoices-table';

const RUPEE = (n) => `Rs.${Number(n || 0).toLocaleString('en-IN')}`;

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
  'OPD Procedure Only': '--teal',
};

function StatCard({ label, value, sub, color, onClick, active }) {
  return (
    <div
      className="card"
      onClick={onClick}
      style={{
        borderTop: `3px solid var(${color})`,
        cursor: onClick ? 'pointer' : undefined,
        boxShadow: active ? `0 0 0 2px var(${color})` : undefined,
        background: active ? `var(${color}-lt)` : undefined,
      }}
      title={onClick ? 'Click to see the entries behind this number' : undefined}
    >
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>{label}</div>
      <div style={{ fontSize: 24, fontWeight: 800, marginTop: 6 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
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

export default function BillingDashboardClient({ fullyPaidUnbilled, todaysVisits, billingByVisit, todaysInvoices, outstandingInvoices, outstandingTotal, outstandingInvoicesToday, outstandingTotalToday }) {
  const router = useRouter();
  // Single-select tab across the six KPI cards -- clicking one shows
  // only its entries in the panel below, the rest stay out of view
  // rather than each having its own independent open/close state.
  // Defaults to "today" since Today's Invoices is what used to be the
  // permanently-visible section before this became tabbed.
  const [activeTab, setActiveTab] = useState('today');
  // Live "still needs action" counts for the three billing-category
  // KPI cards, fed by the single PendingBillingWidget instance below
  // regardless of which tab is currently active (see that widget's
  // onCounts comment for why it stays mounted at all times).
  const [categoryCounts, setCategoryCounts] = useState({ investigation: 0, procedure: 0, pharmacy: 0 });
  // Defaults to today -- pending bills should read as "what's due right
  // now", not a mixed list where a 2-week-old deferred item sits next
  // to something from this morning. Historical is one click away.
  const [todayOnly, setTodayOnly] = useState(true);

  const todaysInvoicesValue = todaysInvoices.reduce((s, i) => s + Number(i.net || 0), 0);

  // Outstanding respects the same Today/Historical toggle as the
  // billing-category tabs: Today = only invoices created today that
  // are still Pending/Partial; Historical = the full all-time
  // outstanding book.
  const shownOutstandingInvoices = todayOnly ? outstandingInvoicesToday : outstandingInvoices;
  const shownOutstandingTotal = todayOnly ? outstandingTotalToday : outstandingTotal;

  return (
    <div>
      <ScopeToggle todayOnly={todayOnly} onChange={setTodayOnly} />

      {/* KPI STRIP -- each card is a tab; clicking one shows only its
          entries in the panel below. */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 16, marginBottom: 20 }}>
        <StatCard
          label="Today's Invoices" value={todaysInvoices.length} sub={RUPEE(todaysInvoicesValue)} color="--blue"
          active={activeTab === 'today'} onClick={() => setActiveTab('today')}
        />
        <StatCard
          label="Outstanding"
          value={shownOutstandingInvoices.length}
          sub={`${RUPEE(shownOutstandingTotal)} -- ${todayOnly ? 'today' : 'all time'}`}
          color="--red"
          active={activeTab === 'outstanding'} onClick={() => setActiveTab('outstanding')}
        />
        <StatCard
          label="Surgery Billing Due" value={fullyPaidUnbilled.length} sub="Fully paid, not yet invoiced" color="--purple"
          active={activeTab === 'surgery'} onClick={() => setActiveTab('surgery')}
        />
        <StatCard
          label="Investigations" value={categoryCounts.investigation} sub={todayOnly ? 'Not yet billed -- today' : 'Not yet billed -- all time'} color="--teal"
          active={activeTab === 'investigations'} onClick={() => setActiveTab('investigations')}
        />
        <StatCard
          label="OPD Procedures" value={categoryCounts.procedure} sub={todayOnly ? 'Not yet billed -- today' : 'Not yet billed -- all time'} color="--amber"
          active={activeTab === 'opdProcedures'} onClick={() => setActiveTab('opdProcedures')}
        />
        <StatCard
          label="Pharmacy" value={categoryCounts.pharmacy} sub={todayOnly ? 'Not yet billed -- today' : 'Not yet billed -- all time'} color="--indigo"
          active={activeTab === 'pharmacy'} onClick={() => setActiveTab('pharmacy')}
        />
      </div>

      {/* ENTRIES PANEL -- swaps content by activeTab. RecentInvoicesTable
          already renders its own .card wrapper, so the other tabs get
          their own wrapper here rather than sharing one outer card
          (which would double the card chrome around Today's Invoices).
          PendingBillingWidget and the Surgery Billing list stay mounted
          at all times (just hidden via CSS when not active) so the
          three billing-category KPI cards above keep live counts even
          while another tab is showing -- the widget fetches its own
          data client-side and unmounting it would lose those counts
          until it reloaded. Surgery Billing's list is plain page-load
          props, so it's cheap to leave mounted too. Investigations/OPD
          Procedures/Pharmacy all render from that one widget instance,
          each only showing its own category via visibleCategories. */}
      <div style={{ marginBottom: 20 }}>
        <div style={{ display: activeTab === 'today' ? 'block' : 'none' }}>
          <RecentInvoicesTable invoices={todaysInvoices} />
        </div>

        <div className="card" style={{ display: activeTab === 'outstanding' ? 'block' : 'none' }}>
          <OutstandingInvoicesTable invoices={shownOutstandingInvoices} todayOnly={todayOnly} />
        </div>

        <div className="card" style={{ display: activeTab === 'surgery' ? 'block' : 'none' }}>
          <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>
            <i className="ti ti-scalpel"></i> Surgery Billing
            <span className="badge b-red" style={{ marginLeft: 8 }}>{fullyPaidUnbilled.length}</span>
          </div>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Surgery</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {fullyPaidUnbilled.map((sc) => (
                <tr key={sc.id} onClick={() => router.push(`/billing/new?pkgCaseId=${sc.id}`)} style={{ cursor: 'pointer' }}>
                  <td>
                    <strong>{formatPatientName(sc.patients)}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span>
                  </td>
                  <td style={{ fontSize: 12 }}>
                    {sc.procedure_name} ({sc.eye})
                    {sc.additionalProcedures?.length > 0 && (
                      <div style={{ color: 'var(--g400)' }}>
                        + {sc.additionalProcedures.map((p) => `${p.procedure_name} (${p.eye})`).join(', ')}
                      </div>
                    )}
                  </td>
                  <td style={{ fontWeight: 600 }}>{RUPEE(sc.netTotal)}</td>
                  <td>
                    <button type="button" className="btn btn-primary btn-sm" onClick={(e) => e.stopPropagation()} style={{ pointerEvents: 'none' }}>
                      <i className="ti ti-receipt"></i> Bill Now
                    </button>
                  </td>
                </tr>
              ))}
              {fullyPaidUnbilled.length === 0 && (
                <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No surgeries fully paid and awaiting billing.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        {/* Always mounted (see comment above); only its visible
            category (and hence its visibility) changes with the tab. */}
        <div
          className="card"
          style={{ display: ['investigations', 'opdProcedures', 'pharmacy'].includes(activeTab) ? 'block' : 'none' }}
        >
          <PendingBillingWidget
            bare todayOnly={todayOnly} onCounts={setCategoryCounts}
            visibleCategories={
              activeTab === 'investigations' ? ['Investigation', 'Biometry']
                : activeTab === 'opdProcedures' ? ['Procedure']
                : activeTab === 'pharmacy' ? ['Pharmacy']
                : []
            }
          />
        </div>
      </div>

      {/* TODAY'S VISITS -- all visits for the day; not part of the tab
          system above, always visible. */}
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
                    <div style={{ fontWeight: 600 }}>{formatPatientName(v.patients)}</div>
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

    </div>
  );
}
