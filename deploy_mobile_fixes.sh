#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/CSS only -- no DB changes.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app"
cat > "app/layout.js" << 'FILEEOF_app_layout_js'
import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
};

// Without this, phones render the page at a virtual desktop width
// (~980px) and shrink the whole thing to fit -- every phone visitor
// was seeing tiny, pinch-to-zoom-required text and a layout that
// never actually triggered the app's own mobile CSS, since the
// browser never reported a narrow enough width for those rules to
// match in the first place.
export const viewport = {
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.5.0/dist/tabler-icons.min.css" />
        {/* Sora carries the brand voice (sidebar, headings, titles) --
            a geometric grotesque with a bit of warmth, used sparingly.
            Inter handles everything dense (tables, forms, badges)
            since this UI runs at 11-14px constantly. Loaded via link
            tag (not next/font) so it doesn't depend on build-time
            network access -- same pattern as the Tabler icons above. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Sora:wght@600;700;800&display=swap" />
      </head>
      <body>{children}</body>
    </html>
  );
}

FILEEOF_app_layout_js

mkdir -p "app"
cat > "app/globals.css" << 'FILEEOF_app_globals_css'
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
.sb-sec { padding: 18px 18px 8px; font-size: 10.5px; font-weight: 700; color: rgba(232, 200, 140, .82); text-transform: uppercase; letter-spacing: 1.1px; }
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

  /* Consistent margins on every sheet, not just the first. */
  @page {
    size: A4;
    margin: 14mm 12mm;
  }

  /* When a table spills onto a second sheet, its header row (S.No /
     Item / Rate, Structure / RE / LE, etc.) repeats at the top of the
     new page instead of leaving page 2 unlabeled. A single row is
     never split mid-row across the page break -- it either fits
     whole on the current page or moves entirely to the next one. */
  table { page-break-inside: auto; }
  thead { display: table-header-group; }
  tr, td, th { page-break-inside: avoid; }
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

/* ── PHONE WIDTHS -- 68px still eats real estate that actually
   matters on a phone (dense tables everywhere), so below this point
   the sidebar goes fully off-canvas as a slide-out drawer instead,
   opened with the hamburger button in the topbar. ── */
.mobile-menu-btn { display: none; }
.mobile-nav-backdrop { display: none; }

@media (max-width: 640px) {
  .mobile-menu-btn { display: flex; }

  .sidebar {
    position: fixed;
    top: 0; left: 0; bottom: 0;
    width: 240px;
    z-index: 60;
    transform: translateX(-100%);
    transition: transform .22s ease;
    box-shadow: 2px 0 24px rgba(0, 0, 0, .25);
  }
  .sidebar.mobile-open { transform: translateX(0); }

  /* Full labels back -- this is a temporary overlay, not the
     permanent squeeze the 68px icon rail is for tablets, so there's
     no reason to sacrifice readability here too. */
  .sb-name, .sb-sub, .sb-sec, .sb-item span:not(.sb-icon-wrap) { display: block; }
  .sb-item { justify-content: flex-start; padding: 8px 16px 8px 15px; margin: 1px 8px; }
  .sb-logo { justify-content: flex-start; padding: 20px 18px; }

  .mobile-nav-backdrop {
    display: block;
    position: fixed;
    inset: 0;
    background: rgba(0, 0, 0, .4);
    z-index: 55;
  }

  .topbar { padding: 10px 14px; gap: 8px; }
  .top-title { font-size: 15px; }
  .top-sub { display: none; }
  .topbar-userinfo { display: none; }
  .content-area { padding: 12px; }
  .tbl { font-size: 11.5px; }
}


FILEEOF_app_globals_css

mkdir -p "app/components"
cat > "app/components/AppShell.js" << 'FILEEOF_app_components_AppShell_js'
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
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration', adminOnly: true },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
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
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
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
  const sections = [...new Set(visibleNavItems.map((i) => i.section))];

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
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {visibleNavItems.filter((i) => i.section === section).map((item) => (
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



FILEEOF_app_components_AppShell_js

mkdir -p "app/login"
cat > "app/login/page.js" << 'FILEEOF_app_login_page_js'
'use client';

import { useState, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';
import { precheckLogin, getMyDesignation, recordLoginFailure, recordLoginSuccess } from '@/app/(main)/users/actions';

export default function LoginPage() {
  return (
    <Suspense fallback={null}>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const searchParams = useSearchParams();
  const idleLogout = searchParams.get('reason') === 'idle';
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      // One round trip instead of two -- lockout check and email
      // resolution are both just profile lookups on the same
      // username, no reason to make them separate requests.
      const resolved = await precheckLogin(username);
      if (resolved.error) {
        setError(resolved.error);
        return;
      }

      const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
        email: resolved.email,
        password,
      });

      if (signInError) {
        // Awaited -- a fire-and-forget call here would race against
        // showing the error and risk the request never actually
        // completing if the person immediately tries again.
        await recordLoginFailure(username);
        setError(signInError.message);
        return;
      }

      // signInWithPassword already returns the user object -- no need
      // for a separate getUser() call just to fetch the same id again.
      const user = signInData?.user;

      // These three don't depend on each other's results, so they run
      // concurrently instead of one-after-another -- the previous
      // sequential version was the main reason login felt slow.
      // recordLoginSuccess still MUST be awaited here (as part of this
      // group) since the hard navigation below cancels anything still
      // in flight -- an unawaited call was exactly why Login History
      // stayed empty despite real logins happening. Each is wrapped
      // defensively; none of them should be able to block getting in.
      const [, , designationOutcome] = await Promise.allSettled([
        recordLoginSuccess(username),
        // Set immediately, not left to the first client-side heartbeat
        // (up to 60s away) -- the middleware idle check runs on the
        // very next page load, and without this, a stale
        // last_active_at from days ago (or null, for a first-ever
        // login) would immediately look "idle" and bounce someone
        // right after they just signed in.
        user ? supabase.from('profiles').update({ last_active_at: new Date().toISOString() }).eq('id', user.id) : Promise.resolve(),
        // Doctors land on their own dashboard; everyone else (Front
        // Office, Optometry, Billing, Admin, etc.) lands on Front
        // Office Dashboard.
        getMyDesignation(),
      ]);

      let destination = '/front-office-dashboard';
      if (designationOutcome.status === 'fulfilled' && designationOutcome.value === 'Doctor') {
        destination = '/doctor-dashboard';
      }
      // A failed designation lookup falls through to the safe default
      // above -- the session cookie signInWithPassword just set can
      // take a beat to propagate to a server action call, so this
      // must never block login itself.

      // A hard navigation here (not router.push) is deliberate -- right
      // after signInWithPassword, a client-side route change can outrun
      // the new session cookie actually being recognized by middleware,
      // which was bouncing straight back to /login and needing a second
      // click to actually get in. A full navigation guarantees the
      // browser's next request carries the fresh session correctly.
      window.location.href = destination;
    } catch (err) {
      console.error('Login handleSubmit failed:', err);
      setError('Something went wrong signing in. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
        padding: 16,
      }}
    >
      <div className="card" style={{ width: 380, maxWidth: '100%' }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'var(--blue-dk)' }}>
            VEDA HMIS
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>
            Veda Eye Hospital -- Staff Login
          </div>
        </div>

        {idleLogout && !error && (
          <div className="msg-info" style={{ marginBottom: 12 }}>
            <i className="ti ti-clock"></i> You were signed out after 30 minutes of inactivity.
          </div>
        )}
        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 14 }}>
            <label className="flbl">Username</label>
            <input
              type="text"
              className="fi"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
              autoFocus
            />
          </div>
          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Password</label>
            <input
              type="password"
              className="fi"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          <button
            type="submit"
            className="btn btn-primary"
            style={{ width: '100%' }}
            disabled={loading}
          >
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
          <Link
            href="/forgot-password"
            style={{ fontSize: 12, color: 'var(--g500)', display: 'block', textAlign: 'center', marginTop: 12 }}
          >
            Forgot password?
          </Link>
        </form>
      </div>
    </div>
  );
}

FILEEOF_app_login_page_js


echo "Files written."

git add -A
git commit -m "Mobile: add missing viewport meta tag, hamburger drawer sidebar for phone widths, fix login card overflow on narrow screens"
git push

echo "Pushed. Vercel will redeploy automatically."
