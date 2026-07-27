'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingProcedureBilling } from '@/app/(main)/billing/actions';

export default function ProceduresBillingWidget() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  async function load() {
    const data = await getPendingProcedureBilling();
    setGroups(data);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  function billNow(group) {
    const ids = group.items.map((i) => i.id).join(',');
    router.push(`/billing/new?visitId=${group.visitId}&procIds=${ids}`);
  }

  const totalItems = groups.reduce((s, g) => s + g.items.length, 0);

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Prescribed Minor Procedures</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Recommended in consultation, not yet billed. Click a patient to open a pre-filled invoice.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && groups.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all prescribed minor procedures are billed.</div>
      )}

      {!loading && groups.map((g) => (
        <div key={g.visitId} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 6, flexWrap: 'wrap', gap: 6 }}>
            <div>
              <div style={{ fontWeight: 600, fontSize: 13 }}>{g.patient?.first_name} {g.patient?.last_name}</div>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{g.patient?.uhid} -- {g.visitNumber}</div>
            </div>
            <button className="btn btn-primary btn-sm" style={{ fontSize: 11, padding: '4px 8px' }} onClick={() => billNow(g)}>
              <i className="ti ti-receipt"></i> Bill Now
            </button>
          </div>

          {g.items.map((p) => (
            <div key={p.id} style={{ padding: '4px 0', fontSize: 12 }}>
              {p.name} <span style={{ color: 'var(--g400)' }}>({p.eye})</span>
              {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.notes}</div>}
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}
