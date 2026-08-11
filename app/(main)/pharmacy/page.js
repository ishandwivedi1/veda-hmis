'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPharmacyDashboard } from './actions';
import PharmacyTabs from './pharmacy-tabs';

const STATUS_BADGE = {
  Purchased: 'b-green',
  Pending: 'b-amber',
  Deferred: 'b-gray',
  'Declined / Bought Elsewhere': 'b-red',
};

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

function VisitStatusBadge({ g }) {
  if (g.allPurchased) return <span className="badge b-green">All Purchased</span>;
  if (g.anyPending) return <span className="badge b-amber">Action Needed</span>;
  return <span className="badge b-gray">Closed Out</span>;
}

export default function PharmacyDashboard() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ totalPatients: 0, pendingItems: 0, purchasedItems: 0, declinedOrDeferred: 0 });
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const data = await getPharmacyDashboard();
    setGroups(data.groups);
    setStats(data.stats);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 20000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Patients today" value={stats.totalPatients} sub="With a prescription written" color="var(--blue)" />
        <KpiCard label="Pending action" value={stats.pendingItems} sub="Not yet billed or dispensed" color="var(--amber)" />
        <KpiCard label="Purchased" value={stats.purchasedItems} sub="Dispensed today" color="var(--green)" />
        <KpiCard label="Declined / deferred" value={stats.declinedOrDeferred} sub="Not collecting from here" color="var(--red)" />
      </div>

      <PharmacyTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Today&apos;s Prescriptions
          <span className="badge b-gray" style={{ marginLeft: 8 }}>{groups.length}</span>
        </div>

        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

        {!loading && groups.length > 0 && (
          <table className="tbl">
            <thead>
              <tr><th>Patient</th><th>Visit</th><th>Medicines</th><th>Status</th><th></th></tr>
            </thead>
            <tbody>
              {groups.map((g) => (
                <tr key={g.visitId}>
                  <td>
                    <strong>{g.patient?.first_name} {g.patient?.last_name}</strong>
                    <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid}</div>
                  </td>
                  <td style={{ fontSize: 12, color: 'var(--g500)' }}>{g.visitNumber}</td>
                  <td>
                    <div style={{ display: 'flex', gap: 4, flexWrap: 'wrap', maxWidth: 320 }}>
                      {g.items.map((rx) => (
                        <span key={rx.id} className={`badge ${STATUS_BADGE[rx.purchaseStatus] || 'b-gray'}`} style={{ fontSize: 10 }}>
                          {rx.drug_name}
                        </span>
                      ))}
                    </div>
                  </td>
                  <td><VisitStatusBadge g={g} /></td>
                  <td style={{ textAlign: 'right' }}>
                    <button className="btn btn-sm" onClick={() => router.push(`/pharmacy/${g.visitId}`)}>
                      Open <i className="ti ti-arrow-right"></i>
                    </button>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {!loading && groups.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            No prescriptions written today yet.
          </div>
        )}
      </div>

      <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 12, padding: 14 }}>
        <i className="ti ti-boxes"></i> Stock tracking is planned for a future update -- current inventory levels aren't shown here yet.
      </div>
    </div>
  );
}
