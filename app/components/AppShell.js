'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState, useRef } from 'react';
import { createClient } from '@/lib/supabase-browser';
import { updateHeartbeat } from '@/app/(main)/users/actions';

// 30 minutes of no mouse/keyboard/touch activity -> automatic sign-out.
// Balances security (unattended shared terminals in a hospital) against
// not interrupting a doctor mid-consultation for a shorter window.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const CHECK_INTERVAL_MS = 60 * 1000;

const NAV_ITEMS = [
  // ── FRONT OFFICE ──
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', group: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', group: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', group: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', group: 'Front Office' },

  // ── FINANCE ──
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', group: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', group: 'Finance' },
  { href: '/cash-management', label: 'Daily Cash Management', icon: 'ti-cash-register', group: 'Finance' },
  { href: '/payments/reports', label: 'Payment Reports', icon: 'ti-report-money', group: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', group: 'Finance' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', group: 'Finance' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', group: 'Finance' },

  // ── OPD ──
  { href: '/optometry-dashboard', label: 'Optometry', icon: 'ti-eye-check', group: 'OPD' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', group: 'OPD' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', group: 'OPD' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', group: 'OPD' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', group: 'OPD' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', group: 'OPD' },
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', group: 'OPD' },

  // ── IPD ──
  { href: '/doctor-dashboard-surgery', label: 'Surgeon Dashboard', icon: 'ti-building-hospital', group: 'IPD' },
  { href: '/surgical-journey', label: 'Surgical Workflow', icon: 'ti-route', group: 'IPD' },
  { href: '/iol-approval', label: 'IOL Approval', icon: 'ti-aperture', group: 'IPD' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', group: 'IPD' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', group: 'IPD' },
  { href: '/patient-checkin', label: 'Patient Check-In', icon: 'ti-clipboard-check', group: 'IPD' },
  { href: '/ot-intraop', label: 'Intraoperative Management', icon: 'ti-building-hospital', group: 'IPD' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', group: 'IPD' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', group: 'IPD' },

  // ── OPERATIONS ──
  { href: '/inventory', label: 'Inventory', icon: 'ti-boxes', group: 'Operations' },

  // ── ADMINISTRATION ──
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', group: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', group: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', group: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', group: 'Administration', adminOnly: true },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', group: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Patient Flow' },
  { match: /^\/doctor-dashboard-surgery/, title: 'Surgery Dashboard' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Daily Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/inventory/, title: 'Inventory' },
  { match: /^\/surgical-journey/, title: 'Surgical Journey' },
  { match: /^\/iol-approval/, title: 'IOL Approval' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/patient-checkin/, title: 'Patient Check-In' },
  { match: /^\/ot-intraop/, title: 'Intraoperative Management' },
  { match: /^\/ot-recovery/, title: 'Recovery & Discharge' },
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
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  // Every navigation should close the drawer -- without this, tapping
  // a link would leave it sitting open over the new page underneath.
  useEffect(() => { setMobileNavOpen(false); }, [pathname]);

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  // Idle auto-logout + "who's online" heartbeat. Checked on an interval,
  // AND immediately whenever the tab becomes visible again -- browsers
  // (Chrome especially) heavily throttle setInterval in backgrounded
  // tabs, sometimes to firing only once every several minutes or less,
  // so the interval alone can miss the 30-minute mark while the tab
  // sits unfocused. visibilitychange isn't subject to that throttling
  // and fires exactly when someone switches back to the tab, so it
  // catches what the interval missed. It doesn't count as "activity"
  // itself -- only real mouse/keyboard/touch input resets the clock.
  const lastActivityRef = useRef(Date.now());
  useEffect(() => {
    const markActive = () => { lastActivityRef.current = Date.now(); };
    const events = ['mousemove', 'keydown', 'mousedown', 'scroll', 'touchstart'];
    events.forEach((e) => window.addEventListener(e, markActive, { passive: true }));

    const checkIdle = async () => {
      const idleMs = Date.now() - lastActivityRef.current;
      if (idleMs >= IDLE_TIMEOUT_MS) {
        await supabase.auth.signOut();
        router.push('/login?reason=idle');
        router.refresh();
      } else {
        updateHeartbeat();
      }
    };

    const onVisible = () => { if (document.visibilityState === 'visible') checkIdle(); };
    document.addEventListener('visibilitychange', onVisible);

    updateHeartbeat(); // immediately on mount, not just on the first interval tick -- extra safety net beyond the login-page write

    const interval = setInterval(checkIdle, CHECK_INTERVAL_MS);

    return () => {
      events.forEach((e) => window.removeEventListener(e, markActive));
      document.removeEventListener('visibilitychange', onVisible);
      clearInterval(interval);
    };
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const visibleNavItems = NAV_ITEMS.filter((i) => !i.adminOnly || profile?.designation === 'Administrator');
  const groups = [...new Set(visibleNavItems.map((i) => i.group))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = visibleNavItems
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      {mobileNavOpen && <div className="mobile-nav-backdrop" onClick={() => setMobileNavOpen(false)}></div>}

      <div className={`sidebar ${mobileNavOpen ? 'mobile-open' : ''}`}>
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {groups.map((group) => (
          <div key={group} className="sb-group-block">
            <div className="sb-group">{group}</div>
            {visibleNavItems.filter((i) => i.group === group).map((item) => (
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
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <button
              className="mobile-menu-btn btn"
              style={{ padding: '7px 10px', flexShrink: 0 }}
              onClick={() => setMobileNavOpen(true)}
              aria-label="Open menu"
            >
              <i className="ti ti-menu-2"></i>
            </button>
            <div>
              <div className="top-title">{pageTitle}</div>
              <div className="top-sub">Veda Eye Hospital</div>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div className="topbar-userinfo" style={{ textAlign: 'right' }}>
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
