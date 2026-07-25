#!/bin/bash
set -e

echo 'Applying: prominent Investigation tab bar (Queue/History/Comparison/Reports)...'

mkdir -p 'app/(main)/investigation/history' 'app/(main)/investigation/comparison' 'app/(main)/investigation/reports'

cat > 'app/(main)/investigation/page.js' << 'INV_PAGE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationQueue } from './actions';
import InvestigationTabs from './investigation-tabs';

const PRIORITY_BADGE = { Urgent: 'b-red', Routine: 'b-gray' };

// Same type-matching heuristic as the workspace uses -- kept in sync
// so the Queue's type filter and badges agree with what the workspace
// will actually render when opened.
function matchType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) return 'OCT';
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) return 'Visual Field';
  if (n.includes('fundus')) return 'Fundus Photography';
  if (n.includes('pachymetry')) return 'Pachymetry';
  return 'External Report';
}

const TYPE_ICON = { OCT: 'ti-eye', 'Visual Field': 'ti-activity', 'Fundus Photography': 'ti-camera', Pachymetry: 'ti-ruler', 'External Report': 'ti-file-import' };

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function InvestigationPage() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 });
  const [typeFilter, setTypeFilter] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvestigationQueue();
    setGroups(result.groups);
    setStats(result.stats);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const filteredGroups = typeFilter
    ? groups.map((g) => ({ ...g, items: g.items.filter((i) => matchType(i.name) === typeFilter) })).filter((g) => g.items.length > 0)
    : groups;

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Ordered" value={stats.ordered} sub="Awaiting performance" color="var(--teal)" />
        <KpiCard label="In progress" value={stats.inProgress} sub="Currently being done" color="var(--amber)" />
        <KpiCard label="Verified today" value={stats.availableToday} sub="Available for review" color="var(--green)" />
        <KpiCard label="Total today" value={stats.totalToday} sub="All investigations" color="var(--blue)" />
      </div>

      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--teal)' }}></i> Investigation Queue</div>
          <select className="fi" style={{ width: 'auto', padding: '5px 8px', fontSize: 11 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
            <option value="">All types</option>
            <option value="OCT">OCT</option>
            <option value="Visual Field">Visual Field</option>
            <option value="Fundus Photography">Fundus Photography</option>
            <option value="Pachymetry">Pachymetry</option>
            <option value="External Report">External Report</option>
          </select>
        </div>
      </div>

      {filteredGroups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-user" style={{ color: 'var(--purple)' }}></i>
            {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
          </div>
          {g.items.map((item) => {
            const type = matchType(item.name);
            return (
              <div
                key={item.id}
                onClick={() => router.push(`/investigation/${item.id}`)}
                style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
              >
                <i className={`ti ${TYPE_ICON[type] || 'ti-flask'}`} style={{ color: 'var(--teal)', fontSize: 16 }}></i>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{item.name}</span>
                  <span style={{ fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>{item.eye}</span>
                </div>
                <span className={`badge ${PRIORITY_BADGE[item.priority] || 'b-gray'}`}>{item.priority}</span>
                <span className={`badge ${item.status === 'In Progress' ? 'b-blue' : 'b-amber'}`}>{item.status}</span>
                <button className="btn btn-sm btn-primary"><i className="ti ti-flask"></i> Open</button>
              </div>
            );
          })}
        </div>
      ))}

      {filteredGroups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

INV_PAGE_EOF

cat > 'app/(main)/investigation/investigation-tabs.js' << 'INV_TABS_EOF'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/investigation', label: 'Queue', icon: 'ti-list-numbers' },
  { href: '/investigation/history', label: 'History', icon: 'ti-history' },
  { href: '/investigation/comparison', label: 'Comparison', icon: 'ti-chart-bar-off' },
  { href: '/investigation/reports', label: 'Reports', icon: 'ti-chart-bar' },
];

export default function InvestigationTabs() {
  const pathname = usePathname();
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Link
          key={t.href}
          href={t.href}
          className={pathname === t.href ? 'btn btn-primary' : 'btn'}
          style={{ textDecoration: 'none' }}
        >
          <i className={`ti ${t.icon}`}></i> {t.label}
        </Link>
      ))}
    </div>
  );
}

INV_TABS_EOF

cat > 'app/(main)/investigation/history/page.js' << 'INV_HISTORY_EOF'
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    setLoading(true);
    const result = await getInvestigationHistory();
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = rows.filter((r) => {
    if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
    if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
    return true;
  });

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Date/Time</th><th>Patient</th><th>Investigation</th><th>Eye</th><th>Key values</th><th>Status</th><th>Doctor</th><th>Performed by</th></tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const p = r.encounters?.visits?.patients;
              const type = matchInvestigationType(r.name);
              return (
                <tr key={r.id} onClick={() => router.push(`/investigation/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <strong>{p?.first_name} {p?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{p?.uhid}</span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td><span className="badge b-blue" style={{ fontSize: 10 }}>{r.eye}</span></td>
                  <td style={{ fontSize: 11, color: 'var(--g600)' }}>{summarizeResultData(type, r.result_data)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 11 }}>{r.doctorName}</td>
                  <td style={{ fontSize: 11, color: 'var(--g400)' }}>{r.performedByName}</td>
                </tr>
              );
            })}
            {!loading && filtered.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No records found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

INV_HISTORY_EOF

cat > 'app/(main)/investigation/comparison/page.js' << 'INV_COMPARISON_EOF'
'use client';

import { useState } from 'react';
import { searchPatientsForInvestigation, getInvestigationComparisonData } from '../actions';
import { matchInvestigationType, parseNumeric } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const COMPARE_TYPES = ['OCT', 'Visual Field'];

export default function InvestigationComparisonPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [type, setType] = useState('OCT');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvestigation(searchQuery.trim());
    setSearchResults(results);
  }

  async function pickPatient(p) {
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    await loadData(p.id, type);
  }

  async function loadData(patientId, t) {
    setLoading(true);
    const result = await getInvestigationComparisonData(patientId);
    setLoading(false);
    if (result.error) { setRows([]); return; }
    const filtered = (result.rows || []).filter((r) => matchInvestigationType(r.name) === t);
    setRows(filtered);
  }

  async function handleTypeChange(t) {
    setType(t);
    if (patient) await loadData(patient.id, t);
  }

  const first = rows[0];
  const last = rows[rows.length - 1];
  const trend = type === 'OCT' && rows.length > 1 && first && last
    ? {
        cmt: (() => { const a = parseNumeric(first.result_data?.['cmt-re']); const b = parseNumeric(last.result_data?.['cmt-re']); return a !== null && b !== null ? b - a : null; })(),
        rnfl: (() => { const a = parseNumeric(first.result_data?.rnfl); const b = parseNumeric(last.result_data?.rnfl); return a !== null && b !== null ? b - a : null; })(),
      }
    : null;

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-chart-bar-off" style={{ color: 'var(--teal)' }}></i> Longitudinal Comparison</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {!patient ? (
            <div style={{ position: 'relative', flex: 1, minWidth: 240 }}>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient by name or UHID..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, position: 'absolute', background: '#fff', width: '100%', zIndex: 5 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--blue-lt)', padding: '6px 12px', borderRadius: 8 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={() => { setPatient(null); setRows([]); }}>Change</button>
            </div>
          )}
          <select className="fi" style={{ width: 'auto', padding: '7px 10px' }} value={type} onChange={(e) => handleTypeChange(e.target.value)}>
            {COMPARE_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && patient && rows.length === 0 && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No {type} history for this patient.</div>
      )}

      {!loading && rows.length > 0 && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: `repeat(${rows.length}, 1fr)`, gap: 12, marginBottom: 12 }}>
            {rows.map((r) => (
              <div key={r.id} className="card" style={{ marginBottom: 0 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', marginBottom: 8 }}>
                  {new Date(r.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                </div>
                {type === 'OCT' ? (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>CMT</span><strong>{r.result_data?.['cmt-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>RNFL</span><strong>{r.result_data?.rnfl || '--'}</strong></div>
                  </>
                ) : (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD RE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD LE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-le'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>VFI</span><strong>{r.result_data?.vfi || '--'}</strong></div>
                  </>
                )}
              </div>
            ))}
          </div>

          {trend && (trend.cmt !== null || trend.rnfl !== null) && (
            <div className="card">
              <div className="card-title"><i className="ti ti-trending-up" style={{ color: 'var(--teal)' }}></i> Trend Analysis</div>
              {trend.cmt !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <span>CMT change</span>
                  <span style={{ fontWeight: 700, color: trend.cmt > 10 ? 'var(--red)' : trend.cmt < -10 ? 'var(--green)' : 'var(--g600)' }}>{trend.cmt >= 0 ? '+' : ''}{trend.cmt} um over {rows.length - 1} visit(s)</span>
                </div>
              )}
              {trend.rnfl !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', fontSize: 12 }}>
                  <span>RNFL change</span>
                  <span style={{ fontWeight: 700, color: trend.rnfl < -5 ? 'var(--red)' : 'var(--green)' }}>{trend.rnfl >= 0 ? '+' : ''}{trend.rnfl} um</span>
                </div>
              )}
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>For clinical decision support. Interpretation by Ophthalmologist only.</div>
            </div>
          )}
        </>
      )}

      {!patient && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Search for a patient to compare their investigation results over time.</div>
      )}
    </div>
  );
}

INV_COMPARISON_EOF

cat > 'app/(main)/investigation/reports/page.js' << 'INV_REPORTS_EOF'
'use client';

import { useState } from 'react';
import { getInvestigationReport } from '../actions';
import InvestigationTabs from '../investigation-tabs';

const RPT_DEFS = [
  { id: 'register', icon: 'ti-calendar', color: '--teal', title: 'Daily Investigation Register', desc: 'All investigations in period' },
  { id: 'type_summary', icon: 'ti-flask', color: '--blue', title: 'Investigation Type Summary', desc: 'Counts by investigation type' },
  { id: 'pending', icon: 'ti-clock', color: '--amber', title: 'Pending Investigations', desc: 'Not yet completed' },
  { id: 'quality', icon: 'ti-shield', color: '--green', title: 'Quality Report', desc: 'Unable to perform, with reasons' },
];

function toISODate(d) { return d.toISOString().slice(0, 10); }

const PRESETS = [
  { label: 'Today', range: () => { const t = toISODate(new Date()); return [t, t]; } },
  { label: 'This Week', range: () => { const now = new Date(); const from = new Date(now); from.setDate(now.getDate() - 6); return [toISODate(from), toISODate(now)]; } },
  { label: 'This Month', range: () => { const now = new Date(); const from = new Date(now.getFullYear(), now.getMonth(), 1); return [toISODate(from), toISODate(now)]; } },
];

export default function InvestigationReportsPage() {
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
    const data = await getInvestigationReport(id, from || fromDate, to || toDate);
    setLoading(null);
    setReport(data);
  }

  return (
    <div>
      <InvestigationTabs />

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

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 14, marginBottom: 16 }}>
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

INV_REPORTS_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/investigation/page.js" "app/(main)/investigation/investigation-tabs.js" "app/(main)/investigation/history" "app/(main)/investigation/comparison" "app/(main)/investigation/reports"'
echo '  git commit -m "Add prominent 4-tab bar to Investigation module"'
echo '  git push'
