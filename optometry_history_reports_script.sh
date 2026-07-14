mkdir -p "app/components" "app/(main)/optometry-history" "app/(main)/optometry-reports"

cat > "app/components/AppShell.js" << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Front Office' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/surgical', label: 'Surgical Coordination', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Scheduling', icon: 'ti-calendar-time', section: 'Surgical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
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
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
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

cat > "app/(main)/optometry-history/page.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOptometryHistory } from './actions';

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export default function OptometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [filter, setFilter] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async (status) => {
    setLoading(true);
    const result = await getOptometryHistory(status || undefined);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setError('');
    setRows(result.rows);
  }, []);

  useEffect(() => { refresh(filter); }, [filter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Assessment History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10 }}>
          <select className="fi" style={{ width: 'auto', padding: '9px 12px' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
            <option value="">All</option>
            <option value="Completed">Completed</option>
            <option value="Draft">Draft</option>
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date/Time</th><th>Patient</th><th>Visit</th><th>VA RE</th><th>VA LE</th><th>IOP RE</th><th>IOP LE</th><th>Status</th><th>By</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const iopReHigh = typeof r.iopRe === 'number' && r.iopRe > 21;
              const iopLeHigh = typeof r.iopLe === 'number' && r.iopLe > 21;
              const by = r.status === 'Completed' ? (r.completed_by_profile?.full_name || '--') : (r.recorded_by_profile?.full_name || '--');
              const dt = new Date(r.completed_at || r.updated_at || r.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });
              return (
                <tr key={r.id}>
                  <td style={{ fontSize: 11 }}>{dt}</td>
                  <td>
                    <strong>{patientName(r)}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                  </td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{r.visits?.visit_number || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.re_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600 }}>{r.le_dist_unaided || '--'}</td>
                  <td style={{ fontWeight: 600, color: iopReHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopRe ?? '--'}{iopReHigh ? ' !' : ''}</td>
                  <td style={{ fontWeight: 600, color: iopLeHigh ? 'var(--red)' : 'var(--g700)' }}>{r.iopLe ?? '--'}{iopLeHigh ? ' !' : ''}</td>
                  <td><span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-amber'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 12 }}>{by}</td>
                </tr>
              );
            })}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No assessments found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/optometry-history/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getOptometryHistory(filterStatus) {
  const supabase = await createClient();

  let query = supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      recorded_by_profile:profiles!optometry_assessments_recorded_by_fkey(full_name),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .order('created_at', { ascending: false });

  if (filterStatus) query = query.eq('status', filterStatus);

  const { data: assessments, error } = await query;
  if (error) return { error: error.message };

  const ids = (assessments || []).map((a) => a.id);
  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r.value);
    });
  }

  const rows = (assessments || []).map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    return {
      ...a,
      iopRe: readings.RE.length ? readings.RE[readings.RE.length - 1] : null,
      iopLe: readings.LE.length ? readings.LE[readings.LE.length - 1] : null,
    };
  });

  return { rows };
}

EOF

cat > "app/(main)/optometry-reports/page.js" << 'EOF'
'use client';

import { useState } from 'react';
import { getOptometryReport } from './actions';

const RPT_DEFS = [
  { id: 'register', icon: 'ti-chart-bar', color: '--teal', title: 'Daily Assessment Register', desc: 'All assessments in period' },
  { id: 'va_distribution', icon: 'ti-eye', color: '--blue', title: 'VA Distribution', desc: 'Visual acuity across patients' },
  { id: 'iop_surveillance', icon: 'ti-activity', color: '--amber', title: 'IOP Surveillance', desc: 'Elevated IOP alerts and trends' },
];

function toISODate(d) {
  return d.toISOString().slice(0, 10);
}

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
];

export default function OptometryReportsPage() {
  const today = toISODate(new Date());
  const [fromDate, setFromDate] = useState(today);
  const [toDate, setToDate] = useState(today);
  const [report, setReport] = useState(null);
  const [activeReportId, setActiveReportId] = useState(null);
  const [loading, setLoading] = useState(null);

  function applyPreset(preset) {
    const [from, to] = preset.range();
    setFromDate(from);
    setToDate(to);
    if (activeReportId) openReport(activeReportId, from, to);
  }

  async function openReport(id, from, to) {
    setActiveReportId(id);
    setLoading(id);
    const data = await getOptometryReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>Period</div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          <span style={{ color: 'var(--g400)' }}>to</span>
          <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          {activeReportId && (
            <button className="btn btn-primary btn-sm" onClick={() => openReport(activeReportId)}>Apply</button>
          )}
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginLeft: 8 }}>
            {PRESETS.map((p) => (
              <button key={p.label} className="btn btn-sm" onClick={() => applyPreset(p)}>{p.label}</button>
            ))}
          </div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 14, marginBottom: 16 }}>
        {RPT_DEFS.map((r) => (
          <div
            key={r.id}
            onClick={() => openReport(r.id)}
            className="card"
            style={{ cursor: 'pointer', borderTop: `3px solid var(${r.color})`, background: activeReportId === r.id ? 'var(--g50)' : '#fff' }}
          >
            <i className={`ti ${r.icon}`} style={{ color: `var(${r.color})`, fontSize: 20 }}></i>
            <div style={{ fontWeight: 700, fontSize: 13, marginTop: 8 }}>{loading === r.id ? 'Loading...' : r.title}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{r.desc}</div>
          </div>
        ))}
      </div>

      {report && (
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-file"></i> {report.title}</div>
            <button className="btn btn-sm" onClick={() => { setReport(null); setActiveReportId(null); }}><i className="ti ti-x"></i> Close</button>
          </div>
          <table className="tbl">
            <thead><tr>{report.headers.map((h) => <th key={h}>{h}</th>)}</tr></thead>
            <tbody>
              {report.rows.map((row, i) => (
                <tr key={i}>{row.cols.map((c, j) => <td key={j}>{c}</td>)}</tr>
              ))}
              {report.rows.length === 0 && (
                <tr><td colSpan={report.headers.length} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No data for this period.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

EOF

cat > "app/(main)/optometry-reports/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

async function fetchAssessmentsWithIop(supabase, from, to, dateColumn) {
  const { data: assessments } = await supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .gte(dateColumn, from)
    .lte(dateColumn, `${to}T23:59:59`);

  const rows = assessments || [];
  const ids = rows.map((a) => a.id);

  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r.value);
    });
  }

  return rows.map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    return {
      ...a,
      iopRe: readings.RE.length ? readings.RE[readings.RE.length - 1] : null,
      iopLe: readings.LE.length ? readings.LE[readings.LE.length - 1] : null,
    };
  });
}

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export async function getOptometryReport(id, from, to) {
  const supabase = await createClient();

  if (id === 'register') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'created_at');
    rows.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    return {
      title: 'Daily Assessment Register',
      headers: ['Date/Time', 'Patient', 'Visit', 'VA RE', 'VA LE', 'IOP RE', 'IOP LE', 'Status', 'By'],
      rows: rows.map((r) => ({
        cols: [
          new Date(r.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }),
          `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
          r.visits?.visit_number || '--',
          r.re_dist_unaided || '--',
          r.le_dist_unaided || '--',
          r.iopRe ?? '--',
          r.iopLe ?? '--',
          r.status,
          r.completed_by_profile?.full_name || '--',
        ],
      })),
      total: null,
    };
  }

  if (id === 'va_distribution') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const tally = {};
    rows.forEach((r) => {
      [r.re_dist_unaided, r.le_dist_unaided].forEach((v) => {
        if (!v) return;
        tally[v] = (tally[v] || 0) + 1;
      });
    });
    const sorted = Object.entries(tally).sort((a, b) => b[1] - a[1]);
    return {
      title: 'VA Distribution (Unaided, both eyes) -- Completed Assessments',
      headers: ['VA Value', 'Count'],
      rows: sorted.map(([val, count]) => ({ cols: [val, count] })),
      total: null,
    };
  }

  if (id === 'iop_surveillance') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const withReadings = rows.filter((r) => r.iopRe !== null || r.iopLe !== null);
    withReadings.sort((a, b) => Math.max(b.iopRe || 0, b.iopLe || 0) - Math.max(a.iopRe || 0, a.iopLe || 0));
    return {
      title: 'IOP Surveillance -- Completed Assessments',
      headers: ['Patient', 'Visit', 'IOP RE', 'IOP LE', 'Flag'],
      rows: withReadings.map((r) => {
        const high = (r.iopRe && r.iopRe > 21) || (r.iopLe && r.iopLe > 21);
        const warn = !high && ((r.iopRe && r.iopRe > 18) || (r.iopLe && r.iopLe > 18));
        return {
          cols: [
            `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
            r.visits?.visit_number || '--',
            r.iopRe ?? '--',
            r.iopLe ?? '--',
            high ? 'ELEVATED' : warn ? 'Borderline' : 'Normal',
          ],
        };
      }),
      total: null,
    };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

EOF

echo "Optometry History + Reports (Phase 2) created/updated."