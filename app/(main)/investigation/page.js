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
                <span className={`badge ${item.payment?.badge || 'b-gray'}`}>{item.payment?.label || 'Unbilled'}</span>
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

