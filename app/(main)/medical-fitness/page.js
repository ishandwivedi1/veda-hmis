'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getMedicalFitnessQueue } from './actions';

export default function MedicalFitnessDashboardPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  useEffect(() => {
    getMedicalFitnessQueue().then((r) => { setRows(r); setLoading(false); });
  }, []);

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Patients referred by Counselling for pre-op medical fitness clearance. Open a patient to review their clinical data, order any investigations needed, and clear (or not) for surgery.
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness Referrals</div>
          <span className="badge b-gray">{rows.length}</span>
        </div>

        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

        {!loading && rows.map((r) => (
          <div
            key={r.id}
            onClick={() => router.push(`/medical-fitness/${r.id}`)}
            style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
          >
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {r.visits?.patients?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</span>
              <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Pending Review</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye}) -- referred {new Date(r.referred_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}
              </div>
            </div>
            <button className="btn btn-sm btn-primary"><i className="ti ti-heart-rate-monitor"></i> Review</button>
          </div>
        ))}

        {!loading && rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No referrals pending review.</div>
        )}
      </div>
    </div>
  );
}

