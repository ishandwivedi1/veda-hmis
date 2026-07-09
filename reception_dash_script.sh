mkdir -p 'app/(main)/reception-dashboard' app/components

cat > 'app/(main)/reception-dashboard/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

function elapsedMin(iso) {
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
};

export default async function ReceptionDashboardPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: todaysRegistrations },
    { data: queueEntries },
    { count: walkInsToday },
    { data: pendingInvoices },
    { data: todaysVisits },
    { count: unregisteredAppts },
    { count: surgicalPendingWorkup },
  ] = await Promise.all([
    supabase.from('patients').select('*').gte('created_at', today).order('created_at', { ascending: false }),
    supabase.from('queue_entries').select('*, visits(patients(first_name, last_name))').neq('status', 'Done').order('issued_at', { ascending: true }),
    supabase.from('visits').select('*', { count: 'exact', head: true }).gte('created_at', today).is('appointment_id', null),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
    supabase.from('visits').select('visit_type').gte('created_at', today),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today).is('patient_id', null),
    supabase.from('surgical_cases').select('*', { count: 'exact', head: true }).eq('status', 'Pending Workup'),
  ]);

  const waitingEntries = (queueEntries || []).filter((e) => e.status === 'Waiting');
  const avgWait = waitingEntries.length
    ? Math.round(waitingEntries.reduce((s, e) => s + elapsedMin(e.issued_at), 0) / waitingEntries.length)
    : 0;

  const outstandingTotal = (pendingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);

  const visitTypeCounts = {};
  (todaysVisits || []).forEach((v) => {
    visitTypeCounts[v.visit_type] = (visitTypeCounts[v.visit_type] || 0) + 1;
  });
  const totalVisitsToday = todaysVisits?.length || 0;

  return (
    <div>
      {/* QUICK ACTIONS */}
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>
            Quick Actions
          </div>
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
              <i className="ti ti-user-plus"></i> New Registration
            </Link>
            <Link href="/appointments/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-calendar-plus"></i> Book Appointment
            </Link>
            <Link href="/visits/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-stethoscope"></i> New Visit
            </Link>
          </div>
        </div>
      </div>

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Registrations</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{todaysRegistrations?.length ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Patients Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingEntries.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Avg wait: {avgWait} min</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Walk-ins Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{walkInsToday ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Billing Pending</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{pendingInvoices?.length ?? 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Rs.{outstandingTotal.toLocaleString('en-IN')} outstanding</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        {/* TODAY'S REGISTRATIONS */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-user-plus" style={{ color: 'var(--blue)' }}></i> Today&apos;s Registrations
          </div>
          <table className="tbl">
            <thead><tr><th>Time</th><th>Patient</th><th>UHID</th><th>Mobile</th></tr></thead>
            <tbody>
              {(todaysRegistrations || []).slice(0, 8).map((p) => (
                <tr key={p.id}>
                  <td>{new Date(p.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}</td>
                  <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
                  <td>{p.mobile}</td>
                </tr>
              ))}
              {(!todaysRegistrations || todaysRegistrations.length === 0) && (
                <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No registrations yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div>
          {/* VISIT TYPE BREAKDOWN */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
            </div>
            {Object.keys(visitTypeCounts).length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
            )}
            {Object.entries(visitTypeCounts).map(([type, count]) => (
              <div key={type} style={{ marginBottom: 8 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                  <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
                </div>
                <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                  <div style={{
                    width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                    height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                  }}></div>
                </div>
              </div>
            ))}
          </div>

          {/* PATIENTS WAITING NOW */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-list-numbers" style={{ color: 'var(--amber)' }}></i> Patients Waiting Now
            </div>
            {(queueEntries || []).slice(0, 5).map((e) => (
              <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                  {e.visits?.patients?.first_name} {e.visits?.patients?.last_name}
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.department} -- {elapsedMin(e.issued_at)} min</div>
                </div>
                <span className={`badge ${e.status === 'Calling' || e.status === 'In Consultation' ? 'b-blue' : 'b-amber'}`}>{e.status}</span>
              </div>
            ))}
            {(!queueEntries || queueEntries.length === 0) && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Queue is empty.</div>
            )}
          </div>

          {/* PENDING ACTIONS */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-circle" style={{ color: 'var(--red)' }}></i> Pending Actions
            </div>
            {(pendingInvoices?.length ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{pendingInvoices.length} invoices -- payment pending</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>Total: Rs.{outstandingTotal.toLocaleString('en-IN')}</div>
                </div>
              </div>
            )}
            {(unregisteredAppts ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-user-plus" style={{ color: 'var(--amber)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{unregisteredAppts} phone bookings not yet registered</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    <Link href="/appointments" style={{ color: 'var(--blue)' }}>Register from Appointments</Link>
                  </div>
                </div>
              </div>
            )}
            {(surgicalPendingWorkup ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0' }}>
                <i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{surgicalPendingWorkup} surgical cases pending workup</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    <Link href="/surgical" style={{ color: 'var(--blue)' }}>Go to Surgical Coordination</Link>
                  </div>
                </div>
              </div>
            )}
            {!(pendingInvoices?.length) && !unregisteredAppts && !surgicalPendingWorkup && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all caught up.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

EOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/reception-dashboard', label: 'Reception Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/surgical', label: 'Surgical Coordination', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Scheduling', icon: 'ti-calendar-time', section: 'Surgical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/reception-dashboard/, title: 'Reception Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Open Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/surgical/, title: 'Surgical Coordination' },
  { match: /^\/ot-schedule/, title: 'OT Scheduling' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${pathname.startsWith(item.href) ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                {item.label}
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}

EOF

echo "Reception Dashboard created."
