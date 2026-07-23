'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingInvestigationBilling, markInvestigationDenied, markInvestigationDeferred, resetInvestigationBilling } from '@/app/(main)/investigation/actions';

const BILLING_BADGE = { Pending: 'b-amber', Deferred: 'b-indigo' };

export default function InvestigationsBillingWidget() {
  const [groups, setGroups] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busyId, setBusyId] = useState(null);
  const router = useRouter();

  async function load() {
    const data = await getPendingInvestigationBilling();
    setGroups(data);
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  async function handleDeny(id) {
    setBusyId(id);
    await markInvestigationDenied(id, 'Patient declined at Front Office');
    await load();
    setBusyId(null);
  }

  async function handleDefer(id) {
    setBusyId(id);
    await markInvestigationDeferred(id, 'Patient asked to come back later');
    await load();
    setBusyId(null);
  }

  async function handleReset(id) {
    setBusyId(id);
    await resetInvestigationBilling(id);
    await load();
    setBusyId(null);
  }

  function billNow(group) {
    const ids = group.items.map((i) => i.id).join(',');
    router.push(`/billing/new?visitId=${group.visitId}&invOrderIds=${ids}`);
  }

  const totalItems = groups.reduce((s, g) => s + g.items.length, 0);

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <span><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Prescribed Investigations -- Pending Billing</span>
        {totalItems > 0 && <span className="badge b-red">{totalItems}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Investigations ordered by doctors, not yet billed. Click a patient to open a pre-filled invoice.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && groups.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all prescribed investigations are billed.</div>
      )}

      {!loading && groups.map((g) => (
        <div key={g.visitId} style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', marginBottom: 6 }}>
            <div>
              <div style={{ fontWeight: 600, fontSize: 13 }}>{g.patient?.first_name} {g.patient?.last_name}</div>
              <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{g.patient?.uhid} -- {g.visitNumber}</div>
            </div>
            <button className="btn btn-primary btn-sm" onClick={() => billNow(g)}>
              <i className="ti ti-receipt"></i> Bill Now
            </button>
          </div>

          {g.items.map((io) => (
            <div key={io.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '4px 0', fontSize: 12 }}>
              <div>
                {io.name} <span style={{ color: 'var(--g400)' }}>({io.eye})</span>
                <span className={`badge ${BILLING_BADGE[io.billing_status] || 'b-amber'}`} style={{ marginLeft: 6, fontSize: 9 }}>{io.billing_status}</span>
              </div>
              <div style={{ display: 'flex', gap: 4 }}>
                {io.billing_status === 'Pending' && (
                  <>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} disabled={busyId === io.id} onClick={() => handleDefer(io.id)}>
                      <i className="ti ti-clock"></i> Later
                    </button>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 10, color: 'var(--red)' }} disabled={busyId === io.id} onClick={() => handleDeny(io.id)}>
                      <i className="ti ti-x"></i> Denied
                    </button>
                  </>
                )}
                {io.billing_status === 'Deferred' && (
                  <button className="btn" style={{ padding: '2px 8px', fontSize: 10 }} disabled={busyId === io.id} onClick={() => handleReset(io.id)}>
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

