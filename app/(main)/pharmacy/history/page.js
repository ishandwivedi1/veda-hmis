'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getPharmacyHistory } from '../actions';
import PharmacyTabs from '../pharmacy-tabs';

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

export default function PharmacyHistoryPage() {
  const [date, setDate] = useState(todayIST());
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    const data = await getPharmacyHistory(date);
    setGroups(data);
    setLoading(false);
  }, [date]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 12 }}>
        <i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy
      </div>
      <PharmacyTabs />

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 16 }}>
        <label style={{ fontSize: 13, color: 'var(--g500)' }}>Date:</label>
        <input type="date" className="fi fi-sm" value={date} max={todayIST()} onChange={(e) => setDate(e.target.value)} style={{ maxWidth: 170 }} />
      </div>

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
            <div>
              <div style={{ fontSize: 14, fontWeight: 700 }}>{g.patient?.first_name} {g.patient?.last_name}</div>
              <div style={{ fontSize: 11, color: 'var(--g400)' }}>{g.patient?.uhid} &middot; Visit {g.visitNumber}</div>
            </div>
            {g.invoiceId && (
              <Link href={`/payments/collect?invoiceId=${g.invoiceId}`} style={{ fontSize: 12 }}>
                View Invoice <i className="ti ti-external-link"></i>
              </Link>
            )}
          </div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            {g.items.map((rx) => (
              <span key={rx.id} className="badge b-gray" style={{ fontSize: 11 }}>
                {rx.drug_name} x{rx.qty} &middot; {new Date(rx.dispensed_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}
              </span>
            ))}
          </div>
        </div>
      ))}

      {!loading && groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No dispensing recorded for this date.
        </div>
      )}
    </div>
  );
}
