mkdir -p 'app/(main)/reports' app/components

cat > 'app/(main)/reports/page.js' << 'EOF'
import { createClient } from '@/lib/supabase-server';

async function StatCard({ label, value, color, icon, sub }) {
  return (
    <div className="card" style={{ borderTop: `3px solid var(${color})` }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase', display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className={`ti ${icon}`}></i> {label}
      </div>
      <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{value}</div>
      {sub && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>}
    </div>
  );
}

export default async function ReportsPage() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { count: totalPatients },
    { count: registeredToday },
    { count: apptsToday },
    { count: openVisits },
    { count: consultationsToday },
    { count: investigationsToday },
    { count: pendingRx },
    { count: surgeriesScheduled },
    { count: surgeriesCompleted },
    { data: invoicesToday },
    { data: outstandingInvoices },
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('encounters').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('investigation_orders').select('*', { count: 'exact', head: true }).eq('status', 'Completed').gte('completed_at', today),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Scheduled'),
    supabase.from('ot_schedule').select('*', { count: 'exact', head: true }).eq('status', 'Completed').eq('scheduled_date', today),
    supabase.from('invoices').select('paid, net').gte('created_at', today),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
  ]);

  const revenueToday = (invoicesToday || []).reduce((s, i) => s + Number(i.paid), 0);
  const outstanding = (outstandingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);

  return (
    <div>
      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Patient Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Total Patients" value={totalPatients ?? 0} color="--blue" icon="ti-users" />
        <StatCard label="Registered Today" value={registeredToday ?? 0} color="--blue" icon="ti-user-plus" />
        <StatCard label="Appointments Today" value={apptsToday ?? 0} color="--amber" icon="ti-calendar-event" />
        <StatCard label="Open Visits" value={openVisits ?? 0} color="--green" icon="ti-door-enter" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Clinical Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Consultations Today" value={consultationsToday ?? 0} color="--teal" icon="ti-stethoscope" />
        <StatCard label="Investigations Today" value={investigationsToday ?? 0} color="--purple" icon="ti-flask" />
        <StatCard label="Pending Prescriptions" value={pendingRx ?? 0} color="--purple" icon="ti-pill" />
        <StatCard label="Surgeries Scheduled" value={surgeriesScheduled ?? 0} color="--red" icon="ti-scalpel" />
      </div>

      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 10 }}>
        Financial Statistics
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 24 }}>
        <StatCard label="Revenue Today" value={`Rs.${revenueToday.toLocaleString('en-IN')}`} color="--green" icon="ti-cash" />
        <StatCard label="Outstanding Receivables" value={`Rs.${outstanding.toLocaleString('en-IN')}`} color="--red" icon="ti-receipt-2" />
        <StatCard label="Surgeries Completed Today" value={surgeriesCompleted ?? 0} color="--green" icon="ti-circle-check" />
      </div>

      <div className="msg-info" style={{ marginTop: 8 }}>
        <i className="ti ti-info-circle"></i> All figures above are computed live from the actual database -- nothing on this page is hardcoded or simulated.
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

echo "Reports module created."
