'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getPostSurgicalPendingPackages, getPendingPackageBilling } from '../actions';

export default function PackageBillingTab() {
  const [postSurgical, setPostSurgical] = useState([]);
  const [pending, setPending] = useState([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async () => {
    setPostSurgical(await getPostSurgicalPendingPackages());
    setPending(await getPendingPackageBilling());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function billNow(sc) {
    router.push(`/billing/new?pkgCaseId=${sc.id}`);
  }

  return (
    <div>
      <div className="msg-info">
        <i className="ti ti-info-circle"></i> Package invoices go through the same New Invoice -&gt; Finalize -&gt; Collect Payment flow as everything else -- nothing here marks an invoice paid directly.
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-package" style={{ color: 'var(--blue)' }}></i> Package Locked, Not Yet Billed
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
          Package selected and locked in Counselling.
        </div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}
        {!loading && pending.map((sc) => (
          <div key={sc.id} onClick={() => billNow(sc)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong> -- {sc.patients?.uhid} -- {sc.procedure_name}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ color: 'var(--g500)' }}>{sc.master_packages?.name} -- Rs.{Number(sc.master_packages?.price || 0).toLocaleString('en-IN')}</span>
              <button className="btn btn-sm btn-primary"><i className="ti ti-receipt"></i> Bill</button>
            </span>
          </div>
        ))}
        {!loading && pending.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending.</div>}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-scissors" style={{ color: 'var(--blue)' }}></i> Post-surgical, Package Still Unbilled
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
          Surgery is complete but the package invoice was never generated -- a fallback catch for anything missed earlier.
        </div>
        {!loading && postSurgical.map((sc) => (
          <div key={sc.id} onClick={() => billNow(sc)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong> -- {sc.patients?.uhid} -- {sc.procedure_name}</span>
            <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
              <span style={{ color: 'var(--g500)' }}>{sc.master_packages?.name || 'No package selected'}</span>
              {sc.master_packages && <button className="btn btn-sm btn-primary"><i className="ti ti-receipt"></i> Bill</button>}
            </span>
          </div>
        ))}
        {!loading && postSurgical.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending.</div>}
      </div>
    </div>
  );
}

