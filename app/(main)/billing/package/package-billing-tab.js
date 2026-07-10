'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostSurgicalPendingPackages,
  getActivePackages,
  searchPatientsForPackage,
  generatePackageInvoice,
} from '../actions';

export default function PackageBillingTab() {
  const [pending, setPending] = useState([]);
  const [packages, setPackages] = useState([]);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [selectedPackage, setSelectedPackage] = useState(null);
  const [surgicalCaseId, setSurgicalCaseId] = useState(null);

  const [paymentMode, setPaymentMode] = useState('full');
  const [advanceAmount, setAdvanceAmount] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);

  const refresh = useCallback(async () => {
    setPending(await getPostSurgicalPendingPackages());
    setPackages(await getActivePackages());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPackage(searchQuery.trim()));
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSurgicalCaseId(null);
    setSearchResults([]);
    setSearchQuery('');
  }

  function pickPostSurgical(sc) {
    setSelectedPatient(sc.patients);
    setSurgicalCaseId(sc.id);
    if (sc.master_packages) setSelectedPackage(sc.master_packages);
  }

  function reset() {
    setSelectedPatient(null);
    setSelectedPackage(null);
    setSurgicalCaseId(null);
    setPaymentMode('full');
    setAdvanceAmount('');
    setResult(null);
    setError('');
  }

  async function handleGenerate() {
    setError('');
    if (!selectedPatient || !selectedPackage) { setError('Select a patient and a package.'); return; }
    setLoading(true);
    const res = await generatePackageInvoice(
      selectedPatient.id,
      selectedPackage.id,
      paymentMode,
      paymentMode === 'advance' ? parseFloat(advanceAmount) : 0,
      surgicalCaseId
    );
    setLoading(false);
    if (res.error) { setError(res.error); return; }
    setResult(res.invoice);
    refresh();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-scissors" style={{ color: 'var(--blue)' }}></i> Post-surgical Patients -- Package Pending
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
          Surgery is complete but the package invoice hasn&apos;t been generated yet.
        </div>
        {pending.map((sc) => (
          <div
            key={sc.id}
            onClick={() => pickPostSurgical(sc)}
            style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13, display: 'flex', justifyContent: 'space-between' }}
          >
            <span><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong> -- {sc.patients?.uhid} -- {sc.procedure_name}</span>
            <span style={{ color: 'var(--g500)' }}>{sc.master_packages?.name || 'No package selected'}</span>
          </div>
        ))}
        {pending.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending.</div>}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-package" style={{ color: 'var(--blue)' }}></i> Package Billing
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Surgery package invoices are generated after counselling. Full payment or advance is collected before surgery scheduling.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {result ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Package invoice generated -- Net Rs.{result.net}, Paid Rs.{result.paid}, Status: {result.status}.
            <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
              <a href={`/invoice-print/${result.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <button className="btn btn-sm" onClick={reset}>Bill another package</button>
            </div>
          </div>
        ) : (
          <>
            {!selectedPatient ? (
              <div>
                <label className="flbl">Patient / Visit</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type patient name or UHID..." />
                  <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                    {searchResults.map((p) => (
                      <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
                  <div>
                    <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>{selectedPatient.uhid}</div>
                  </div>
                  <button className="btn btn-sm" onClick={reset}>Change</button>
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
                  {packages.map((pkg) => (
                    <div
                      key={pkg.id}
                      onClick={() => setSelectedPackage(pkg)}
                      style={{
                        border: selectedPackage?.id === pkg.id ? '2px solid var(--blue)' : '1px solid var(--g200)',
                        borderRadius: 8, padding: 12, cursor: 'pointer',
                        background: selectedPackage?.id === pkg.id ? 'var(--blue-lt)' : '#fff',
                      }}
                    >
                      <div style={{ fontWeight: 700, fontSize: 13 }}>{pkg.name}</div>
                      <div style={{ fontSize: 12, color: 'var(--g500)' }}>Rs.{pkg.price}</div>
                      {pkg.includes && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>{pkg.includes}</div>}
                    </div>
                  ))}
                </div>

                {selectedPackage && (
                  <div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 14 }}>
                      <div>
                        <label className="flbl">Payment mode</label>
                        <select className="fi" value={paymentMode} onChange={(e) => setPaymentMode(e.target.value)}>
                          <option value="full">Full payment</option>
                          <option value="advance">Advance payment</option>
                        </select>
                      </div>
                      {paymentMode === 'advance' && (
                        <div>
                          <label className="flbl">Advance amount (Rs.)</label>
                          <input type="number" className="fi" value={advanceAmount} onChange={(e) => setAdvanceAmount(e.target.value)} placeholder={`Up to Rs.${selectedPackage.price}`} />
                        </div>
                      )}
                    </div>
                    <button className="btn btn-green" onClick={handleGenerate} disabled={loading}>
                      <i className="ti ti-receipt"></i> {loading ? 'Generating...' : 'Generate package invoice'}
                    </button>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

