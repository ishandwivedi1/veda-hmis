'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getMedicalFitnessQueue } from './actions';
import MedicalFitnessTabs from './medical-fitness-tabs';

function daysWaiting(referral) {
  const ms = new Date() - new Date(referral.referred_at);
  return Math.floor(ms / (1000 * 60 * 60 * 24));
}

export default function MedicalFitnessQueuePage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');
  const router = useRouter();

  useEffect(() => {
    getMedicalFitnessQueue().then((r) => { setRows(r); setLoading(false); });
  }, []);

  let filtered = rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  filtered = [...filtered].sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.referred_at) - new Date(b.referred_at);
    if (sortBy === 'newest') return new Date(b.referred_at) - new Date(a.referred_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.surgical_cases?.priority] ?? 9) - (order[b.surgical_cases?.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div>
      <MedicalFitnessTabs />

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Pending Review <span className="badge b-amber">{rows.length}</span></div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
            <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
              <option value="oldest">Oldest first</option>
              <option value="newest">Newest first</option>
              <option value="priority">Priority</option>
            </select>
          </div>
        </div>

        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

        {!loading && filtered.map((r) => {
          const dw = daysWaiting(r);
          return (
            <div
              key={r.id}
              onClick={() => router.push(`/medical-fitness/${r.id}`)}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {r.visits?.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</span>
                <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Pending Review</span>
                {r.surgical_cases?.priority && r.surgical_cases.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{r.surgical_cases.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})
                </div>
              </div>
              <div style={{ textAlign: 'right', fontSize: 10, color: dw > 3 ? 'var(--red)' : dw > 1 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                {dw === 0 ? 'Today' : `${dw}d waiting`}
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}

        {!loading && filtered.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {rows.length === 0 ? 'No referrals pending review. Counsellors refer patients from Counselling once package is confirmed and accepted.' : 'No referrals match this search.'}
          </div>
        )}
      </div>
    </div>
  );
}

