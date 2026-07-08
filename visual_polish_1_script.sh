mkdir -p app/components app/dashboard

cat > 'app/globals.css' << 'EOF'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --blue: #1d4ed8; --blue-lt: #dbeafe; --blue-dk: #1e3a8a; --blue-mid: #3b82f6;
  --green: #15803d; --green-lt: #dcfce7;
  --red: #b91c1c; --red-lt: #fee2e2;
  --amber: #b45309; --amber-lt: #fef3c7;
  --purple: #7c3aed; --purple-lt: #ede9fe;
  --teal: #0f766e; --teal-lt: #ccfbf1;
  --g50: #f9fafb; --g100: #f3f4f6; --g200: #e5e7eb; --g300: #d1d5db;
  --g400: #9ca3af; --g500: #6b7280; --g600: #4b5563; --g700: #374151; --g800: #1f2937; --g900: #111827;
  --r: 8px; --r-lg: 12px;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
}

/* ── APP SHELL ── */
.app-layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: #fff; border-right: 1px solid var(--g200); display: flex; flex-direction: column; flex-shrink: 0; }
.sb-logo { display: flex; align-items: center; gap: 10px; padding: 18px 16px; border-bottom: 1px solid var(--g100); }
.sb-logo-icon { width: 34px; height: 34px; border-radius: 8px; background: var(--blue); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 17px; flex-shrink: 0; }
.sb-name { font-weight: 700; font-size: 13px; }
.sb-sub { font-size: 10px; color: var(--g400); }
.sb-sec { padding: 14px 16px 6px; font-size: 10px; font-weight: 700; color: var(--g400); text-transform: uppercase; letter-spacing: .4px; }
.sb-item { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-size: 13px; color: var(--g600); cursor: pointer; border-left: 3px solid transparent; text-decoration: none; }
.sb-item:hover { background: var(--g50); }
.sb-item.active { background: var(--blue-lt); color: var(--blue-dk); border-left-color: var(--blue); font-weight: 600; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; }
.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.topbar { background: #fff; border-bottom: 1px solid var(--g200); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; }
.top-title { font-size: 16px; font-weight: 700; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 1px; }
.content-area { flex: 1; overflow-y: auto; padding: 24px; }

/* ── CARDS ── */
.card { background: #fff; border: 1px solid var(--g200); border-radius: var(--r-lg); padding: 20px; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-size: 14px; font-weight: 700; display: flex; align-items: center; gap: 7px; }

/* ── BUTTONS ── */
.btn { padding: 9px 16px; border-radius: var(--r); font-size: 13px; font-weight: 600; cursor: pointer; border: 1px solid var(--g200); background: #fff; color: var(--g700); font-family: inherit; transition: all .12s; display: inline-flex; align-items: center; gap: 6px; }
.btn:hover { background: var(--g50); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; }
.btn-primary:hover { background: var(--blue-dk); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; }
.btn-sm { padding: 5px 10px; font-size: 11.5px; }

/* ── BADGES ── */
.badge { padding: 2px 10px; border-radius: 12px; font-size: 11px; font-weight: 700; display: inline-flex; align-items: center; gap: 4px; }
.b-blue { background: var(--blue-lt); color: var(--blue); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi { width: 100%; padding: 9px 12px; border: 1.5px solid var(--g200); border-radius: var(--r); font-size: 13px; font-family: inherit; background: #fff; }
.fi:focus { outline: none; border-color: var(--blue); }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }
.msg-err { background: var(--red-lt); color: var(--red); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-success { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 8px 10px; color: var(--g500); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .3px; border-bottom: 1.5px solid var(--g200); }
.tbl td { padding: 9px 10px; border-bottom: 1px solid var(--g100); }

EOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '../../lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
];

export default function AppShell({ children, title, subtitle }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

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
            <div className="top-title">{title}</div>
            {subtitle && <div className="top-sub">{subtitle}</div>}
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

cat > 'app/layout.js' << 'EOF'
import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.5.0/dist/tabler-icons.min.css" />
      </head>
      <body>{children}</body>
    </html>
  );
}

EOF

cat > 'app/dashboard/page.js' << 'EOF'
import { createClient } from '../../lib/supabase-server';
import AppShell from '../components/AppShell';

export default async function DashboardPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();

  const today = new Date().toISOString().slice(0, 10);

  const [{ count: patientCount }, { count: apptCount }, { count: visitCount }, { count: rxCount }] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
  ]);

  return (
    <AppShell title="Dashboard" subtitle={`Welcome back, ${profile?.full_name || user.email}`}>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Patients</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{patientCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{apptCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Open Visits</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{visitCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Pending Prescriptions</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{rxCount ?? 0}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-user-circle" style={{ color: 'var(--blue)' }}></i> Your Profile
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Name:</strong> {profile?.full_name || '(not set yet)'}</div>
          <div><strong>Designation:</strong> {profile?.designation || '(not set yet)'}</div>
          <div><strong>Department:</strong> {profile?.department || '(not set yet)'}</div>
          <div><strong>Status:</strong> <span className="badge b-green">{profile?.status}</span></div>
          <div><strong>Email:</strong> {user.email}</div>
        </div>
      </div>
    </AppShell>
  );
}

EOF

echo "Visual polish pass 1 (shell + dashboard) applied."
