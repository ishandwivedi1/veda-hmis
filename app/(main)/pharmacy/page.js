'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getPharmacyDashboard } from './actions';
import PharmacyTabs from './pharmacy-tabs';

const STATUS_BADGE = {
  Purchased: 'b-green',
  Pending: 'b-amber',
  Deferred: 'b-gray',
  'Declined / Bought Elsewhere': 'b-red',
};

export default function PharmacyDashboard() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const data = await getPharmacyDashboard();
    setGroups(data);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 20000);
    return () => clearInterval(interval);
  }, [refresh]);

  const pendingCount = groups.reduce((sum, g) => sum + g.items.filter((i) => i.purchaseStatus === 'Pending').length, 0);

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
        <i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy
      </div>
      <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 12 }}>
        {pendingCount} item(s) still pending today &middot; auto-refreshes every 20s
      </div>
      <PharmacyTabs />

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && groups.map((g) => (
        <Link key={g.visitId} href={`/pharmacy/${g.visitId}`} style={{ textDecoration: 'none', color: 'inherit' }}>
          <div className="card" style={{ marginBottom: 12, cursor: 'pointer' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <div>
                <div style={{ fontSize: 15, fontWeight: 700 }}>
                  {g.patient?.first_name} {g.patient?.last_name}
                </div>
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>{g.patient?.uhid} &middot; Visit {g.visitNumber}</div>
              </div>
              {g.allPurchased && <span className="badge b-green" style={{ fontSize: 11 }}>All Purchased</span>}
              {!g.allPurchased && g.anyPending && <span className="badge b-amber" style={{ fontSize: 11 }}>Action Needed</span>}
            </div>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {g.items.map((rx) => (
                <span key={rx.id} className={`badge ${STATUS_BADGE[rx.purchaseStatus] || 'b-gray'}`} style={{ fontSize: 10 }}>
                  {rx.drug_name}: {rx.purchaseStatus}
                </span>
              ))}
            </div>
          </div>
        </Link>
      ))}

      {!loading && groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No prescriptions written today yet.
        </div>
      )}

      <div className="card" style={{ marginTop: 20, textAlign: 'center', color: 'var(--g400)', fontSize: 12, padding: 14 }}>
        <i className="ti ti-boxes"></i> Stock tracking is planned for a future update -- current inventory levels aren't shown here yet.
      </div>
    </div>
  );
}
