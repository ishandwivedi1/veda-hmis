#!/bin/bash
set -e
echo "Applying: sidebar cleanup -- remove redundant Dashboard/Overview, reorganize Reports and Front Office Dashboard, fix Counselling icon, improve contrast"

cat > "app/components/AppShell.js" << 'PYEOF_4101950011235230209'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/workflow-monitor', label: 'Workflow Monitor', icon: 'ti-activity', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
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
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

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

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

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
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
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
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}



PYEOF_4101950011235230209

cat > "app/globals.css" << 'PYEOF_3045087665104526126'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

/* ── DESIGN TOKENS ──
   Ophthalmic Navy + brass-gold signature, grounded in the subject: a
   slit-lamp instrument palette (deep, precise, calm) with the warm
   brass of an iris used sparingly as the one accent. Semantic badge
   colors (blue/green/red/amber/purple/indigo/cyan/teal) keep their
   existing meaning across the app -- only the values are refined. */
:root {
  --blue: #1e4e8c; --blue-lt: #e7eff8; --blue-dk: #123a66; --blue-mid: #3e71b3;
  --green: #157a4f; --green-lt: #e3f5ec;
  --red: #b3261e; --red-lt: #fbe9e7;
  --amber: #a15c00; --amber-lt: #fbf0dc;
  --purple: #6d28a8; --purple-lt: #f1e7fb;
  --indigo: #3730a3; --indigo-lt: #e7e5fb;
  --cyan: #0b7285; --cyan-lt: #e0f5f8;
  --teal: #0e6b60; --teal-lt: #e1f5f1;
  --g50: #f8f9fa; --g100: #f1f3f5; --g200: #e3e6ea; --g300: #cbd0d6;
  --g400: #97a0aa; --g500: #62707c; --g600: #46525c; --g700: #303a42; --g800: #1c242b; --g900: #10161b;

  /* Signature accent -- the "iris" brass. Used sparingly: logo mark,
     active-nav underline glow, a handful of celebratory highlights.
     Never used for functional/semantic meaning (that's --amber). */
  --accent: #a6791f; --accent-lt: #f6ecd7; --accent-dk: #7d5a12;

  --r: 10px; --r-lg: 16px; --r-sm: 7px;

  --shadow-sm: 0 1px 2px rgba(16, 22, 27, .05), 0 1px 1px rgba(16, 22, 27, .03);
  --shadow-md: 0 4px 14px rgba(16, 22, 27, .07), 0 1px 3px rgba(16, 22, 27, .05);
  --shadow-lg: 0 12px 32px rgba(16, 22, 27, .12), 0 2px 8px rgba(16, 22, 27, .06);

  --font-display-stack: 'Sora', 'Segoe UI', sans-serif;
  --font-body-stack: 'Inter', -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
}

html, body { height: 100%; }
html { -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility; }

body {
  font-family: var(--font-body-stack);
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
  line-height: 1.5;
}

/* Visible keyboard focus everywhere -- quality floor, not optional. */
a:focus-visible, button:focus-visible, input:focus-visible, select:focus-visible, textarea:focus-visible, [tabindex]:focus-visible {
  outline: 2px solid var(--blue-mid);
  outline-offset: 2px;
  border-radius: 4px;
}

/* Quiet, deliberate scrollbars instead of default browser chrome. */
::-webkit-scrollbar { width: 10px; height: 10px; }
::-webkit-scrollbar-track { background: transparent; }
::-webkit-scrollbar-thumb { background: var(--g300); border-radius: 20px; border: 2px solid var(--g50); }
::-webkit-scrollbar-thumb:hover { background: var(--g400); }

/* ── APP SHELL ── */
.app-layout { display: flex; height: 100vh; overflow: hidden; }

/* Dark navy sidebar -- deliberately different register from the rest of
   the (light) app, like an instrument panel: gives the eye a clear,
   permanent anchor for "where am I" that never gets confused with page
   content. Gold accent (--accent) marks the active module. */
.sidebar {
  width: 236px;
  background: #0f1b2e;
  border-right: 1px solid rgba(255, 255, 255, .06);
  display: flex;
  flex-direction: column;
  flex-shrink: 0;
  overflow-y: auto;
  min-height: 0;
}
.sb-logo {
  display: flex;
  align-items: center;
  gap: 11px;
  padding: 20px 18px;
  border-bottom: 1px solid rgba(255, 255, 255, .08);
  margin-bottom: 4px;
}
.sb-logo-icon {
  width: 36px; height: 36px;
  border-radius: 50%;
  flex-shrink: 0;
  position: relative;
  background:
    radial-gradient(circle at 50% 50%, var(--accent) 0 5px, transparent 5.5px),
    conic-gradient(from 0deg, var(--blue-dk), var(--blue) 35%, var(--blue-mid) 60%, var(--blue-dk) 100%);
  box-shadow: inset 0 0 0 2px rgba(255, 255, 255, .22), 0 0 0 1px rgba(255, 255, 255, .06);
}
.sb-name { font-family: var(--font-display-stack); font-weight: 700; font-size: 14px; letter-spacing: .1px; color: #fff; }
.sb-sub { font-size: 10.5px; color: rgba(255, 255, 255, .45); margin-top: 1px; }
.sb-sec { padding: 16px 18px 7px; font-size: 10px; font-weight: 700; color: rgba(255, 255, 255, .35); text-transform: uppercase; letter-spacing: .6px; }
.sb-item {
  display: flex;
  align-items: center;
  gap: 10px;
  padding: 8px 16px 8px 15px;
  margin: 1px 8px;
  font-size: 13.5px;
  font-weight: 500;
  color: rgba(255, 255, 255, .88);
  cursor: pointer;
  border-left: 3px solid transparent;
  border-radius: 0 var(--r-sm) var(--r-sm) 0;
  text-decoration: none;
  transition: background .12s ease, color .12s ease;
}
.sb-item:hover { background: rgba(255, 255, 255, .06); color: #fff; }
.sb-item.active { background: rgba(166, 121, 31, .18); color: #fff; border-left-color: var(--accent); font-weight: 700; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; font-size: 14px; }

.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; height: 100vh; overflow: hidden; }
.topbar {
  background: #fff;
  border-bottom: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  padding: 14px 26px;
  display: flex;
  justify-content: space-between;
  align-items: center;
  position: relative;
  z-index: 5;
  flex-shrink: 0;
}
.top-title { font-family: var(--font-display-stack); font-size: 16.5px; font-weight: 700; color: var(--g900); letter-spacing: -.1px; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 2px; }
.content-area { flex: 1; overflow-y: auto; padding: 26px; min-height: 0; }

/* ── CARDS ── */
.card {
  background: #fff;
  border: 1px solid var(--g200);
  box-shadow: var(--shadow-sm);
  border-radius: var(--r-lg);
  padding: 20px;
  margin-bottom: 16px;
}
.card:last-child { margin-bottom: 0; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-family: var(--font-display-stack); font-size: 14px; font-weight: 700; color: var(--g900); display: flex; align-items: center; gap: 8px; letter-spacing: -.1px; }

/* ── BUTTONS ── */
.btn {
  padding: 9px 16px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid var(--g200);
  background: #fff;
  color: var(--g700);
  font-family: var(--font-body-stack);
  transition: background .12s ease, border-color .12s ease, box-shadow .12s ease, transform .08s ease;
  display: inline-flex;
  align-items: center;
  gap: 6px;
}
.btn:hover { background: var(--g50); border-color: var(--g300); }
.btn:active { transform: translateY(1px); }
.btn:disabled { opacity: .5; cursor: not-allowed; transform: none; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-primary:hover { background: var(--blue-dk); box-shadow: var(--shadow-md); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-green:hover { filter: brightness(.92); }
.btn-danger { background: var(--red); color: #fff; border-color: transparent; box-shadow: var(--shadow-sm); }
.btn-danger:hover { filter: brightness(.92); }
.btn-sm { padding: 5px 10px; font-size: 11.5px; border-radius: var(--r-sm); }

/* ── BADGES ── */
.badge {
  padding: 2.5px 10px;
  border-radius: 999px;
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .1px;
  display: inline-flex;
  align-items: center;
  gap: 4px;
}
.b-blue { background: var(--blue-lt); color: var(--blue-dk); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-indigo { background: var(--indigo-lt); color: var(--indigo); }
.b-cyan { background: var(--cyan-lt); color: var(--cyan); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi {
  width: 100%;
  padding: 9px 12px;
  border: 1.5px solid var(--g200);
  border-radius: var(--r);
  font-size: 13px;
  font-family: var(--font-body-stack);
  background: #fff;
  color: var(--g800);
  transition: border-color .12s ease, box-shadow .12s ease;
}
.fi:focus { outline: none; border-color: var(--blue-mid); box-shadow: 0 0 0 3px var(--blue-lt); }
.fi:disabled { background: var(--g50); color: var(--g400); cursor: not-allowed; }
.fi-sm { padding: 6px 10px; font-size: 12px; }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }

/* Errors and warnings are easy to miss as a quiet inline line, especially
   on long forms -- they now float as an unmissable toast instead,
   regardless of where on the page they're rendered. Success/info stay
   in-flow since they're not the complaint and floating every positive
   confirmation would just add noise. This is pure CSS -- the exact same
   {error && <div className="msg-err">...} pattern used everywhere in the
   app automatically gets this treatment with zero code changes. */
@keyframes msgSlideIn {
  from { opacity: 0; transform: translateX(36px) scale(.97); }
  to { opacity: 1; transform: translateX(0) scale(1); }
}
@keyframes msgShake {
  0%, 100% { transform: translateX(0); }
  20% { transform: translateX(-5px); }
  40% { transform: translateX(5px); }
  60% { transform: translateX(-3px); }
  80% { transform: translateX(3px); }
}

.msg-err, .msg-warn {
  position: fixed;
  right: 26px;
  z-index: 1000;
  min-width: 300px;
  max-width: 440px;
  background: #fff;
  padding: 13px 18px;
  border-radius: var(--r);
  font-size: 13px;
  font-weight: 600;
  display: flex;
  align-items: center;
  gap: 10px;
  box-shadow: var(--shadow-lg);
  margin-bottom: 0;
}
.msg-err {
  top: 78px;
  color: var(--red);
  border: 1.5px solid var(--red);
  border-left: 5px solid var(--red);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1), msgShake .4s ease .3s;
}
.msg-err::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--red); color: #fff; font-weight: 800; font-size: 13px;
}
.msg-warn {
  top: 146px;
  color: var(--amber);
  border: 1.5px solid var(--amber);
  border-left: 5px solid var(--amber);
  animation: msgSlideIn .3s cubic-bezier(.2, .8, .3, 1);
}
.msg-warn::before {
  content: '!';
  display: flex; align-items: center; justify-content: center; flex-shrink: 0;
  width: 21px; height: 21px; border-radius: 50%;
  background: var(--amber); color: #fff; font-weight: 800; font-size: 13px;
}

.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }
.msg-success, .msg-ok { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; display: flex; align-items: center; gap: 8px; }

@media (max-width: 860px) {
  .msg-err, .msg-warn { left: 16px; right: 16px; max-width: none; }
}

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 9px 10px; color: var(--g500); font-weight: 700; font-size: 10.5px; text-transform: uppercase; letter-spacing: .4px; background: var(--g50); border-bottom: 1.5px solid var(--g200); }
.tbl th:first-child { border-top-left-radius: var(--r-sm); }
.tbl th:last-child { border-top-right-radius: var(--r-sm); }
.tbl td { padding: 10px; border-bottom: 1px solid var(--g100); color: var(--g700); }
.tbl tbody tr { transition: background .1s ease; }
.tbl tbody tr:hover { background: var(--g50); }

/* ── PRINT ── */
@media print {
  .no-print { display: none !important; }
  body { background: #fff; }
  .card { box-shadow: none; }
}

/* ── SMALL SCREENS -- light touch, not a full mobile rework ── */
@media (max-width: 860px) {
  .sidebar { width: 68px; }
  .sb-name, .sb-sub, .sb-sec, .sb-item span:not(.sb-icon-wrap) { display: none; }
  .sb-item { justify-content: center; padding: 10px 0; margin: 1px 6px; }
  .sb-logo { justify-content: center; padding: 16px 0; }
  .content-area { padding: 16px; }
  .topbar { padding: 12px 16px; }
}
PYEOF_3045087665104526126

echo "Files written. Run: npm run build"
