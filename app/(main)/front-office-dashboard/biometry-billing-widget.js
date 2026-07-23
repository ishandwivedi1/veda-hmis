'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingBiometryBilling, markBiometryDenied, markBiometryDeferred, resetBiometryBilling } from '@/app/(main)/biometry/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

export default function BiometryBillingWidget() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState(null);
  const router = useRouter();

  async function load() {
    const data = await getPendingBiometryBilling();
    setGroups(data);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  async function handleDeny(id) {
    setBusyId(id);
    await markBiometryDenied(id, 'Patient declined at Front Office');
    await load();
    setBusyId(null);
  }

  async function handleDefer(id) {
    setBusyId(id);
    await markBiometryDeferred(id, 'Patient asked to come back later');
    await load();
    setBusyId(null);
  }

  async function handleReset(id) {
    setBusyId(id);
    await resetBiometryBilling(id);
    await load();
    setBusyId(null);
  }

  function billNow(group) {
    const ids = group.items.map((i) => i.id).join(',');
    router.push(`/billing/new?visitId=${group.visitId}&bioIds=${ids}`);
  }

  const totalItems = groups.reduce((s, g) => s + g.items.length, 0);

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Sent for biometry, not yet billed. Click a patient to open a pre-filled invoice.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && groups.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all biometry is billed.</div>
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

          {g.items.map((r) => (
            <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', fontSize: 12, flexWrap: 'wrap', gap: 4 }}>
              <div>
                Biometry
                <span className={`badge ${BILLING_BADGE[r.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{r.billing_status}</span>
              </div>
              <div style={{ display: 'flex', gap: 4 }}>
                {r.billing_status === 'Pending' && (
                  <>
                    <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === r.id} onClick={() => handleDefer(r.id)}>
                      <i className="ti ti-clock"></i>
                    </button>
                    <button className="btn" style={{ padding: '2px 6px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === r.id} onClick={() => handleDeny(r.id)}>
                      <i className="ti ti-x"></i>
                    </button>
                  </>
                )}
                {r.billing_status === 'Deferred' && (
                  <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} disabled={busyId === r.id} onClick={() => handleReset(r.id)}>
                    Reset
                  </button>
                )}
              </div>
            </div>
          ))}
        </div>
      ))}
    </div>
  );
}

