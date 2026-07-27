'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getPendingPackageBilling } from '@/app/(main)/billing/actions';

export default function PackageBillingWidget() {
  const [cases, setCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  async function load() {
    setCases(await getPendingPackageBilling());
    setLoading(false);
  }

  useEffect(() => { load(); }, []);

  function billNow(sc) {
    router.push(`/billing/new?pkgCaseId=${sc.id}`);
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
        <span><i className="ti ti-package" style={{ color: 'var(--green)' }}></i> Package Billing</span>
        {cases.length > 0 && <span className="badge b-red">{cases.length}</span>}
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
        Package locked in Counselling, not yet billed. Click a patient to open a pre-filled invoice.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>}

      {!loading && cases.length === 0 && (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all packages are billed.</div>
      )}

      {!loading && cases.map((sc) => (
        <div key={sc.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)', flexWrap: 'wrap', gap: 6 }}>
          <div>
            <div style={{ fontWeight: 600, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{sc.patients?.uhid} -- {sc.procedure_name} ({sc.eye})</div>
            <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 2 }}>{sc.master_packages?.name} -- Rs.{Number(sc.master_packages?.price || 0).toLocaleString('en-IN')}</div>
          </div>
          <button className="btn btn-primary btn-sm" style={{ fontSize: 11, padding: '4px 8px' }} onClick={() => billNow(sc)}>
            <i className="ti ti-receipt"></i> Bill Now
          </button>
        </div>
      ))}
    </div>
  );
}

