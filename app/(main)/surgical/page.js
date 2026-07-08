'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getSurgicalCases, getPackagesForSelection, selectPackage,
  updateChecklistItem, markReadyForScheduling,
} from './actions';

function CaseCard({ sc, packages, onUpdate }) {
  const [error, setError] = useState('');

  async function handlePackage(e) {
    await selectPackage(sc.id, e.target.value);
    onUpdate();
  }

  async function handleChecklist(field, checked) {
    await updateChecklistItem(sc.id, field, checked);
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-head">
        <div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>
            {sc.patients.first_name} {sc.patients.last_name} -- {sc.patients.uhid}
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>{sc.procedure_name} -- {sc.eye}</div>
        </div>
        <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`}>{sc.status}</span>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Package</label>
        <select className="fi" value={sc.package_id || ''} onChange={handlePackage}>
          <option value="">-- Select package --</option>
          {packages.map((p) => (
            <option key={p.id} value={p.id}>{p.name} -- Rs.{p.price}</option>
          ))}
        </select>
      </div>

      <div style={{ display: 'flex', gap: 20, marginBottom: 12 }}>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.consent_taken} onChange={(e) => handleChecklist('consent_taken', e.target.checked)} />
          Consent taken
        </label>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.biometry_done} onChange={(e) => handleChecklist('biometry_done', e.target.checked)} />
          Biometry done
        </label>
        <label style={{ fontSize: 13, display: 'flex', alignItems: 'center', gap: 6 }}>
          <input type="checkbox" checked={sc.fitness_cleared} onChange={(e) => handleChecklist('fitness_cleared', e.target.checked)} />
          Fitness cleared
        </label>
      </div>

      {sc.status === 'Pending Workup' && (
        <button className="btn btn-primary btn-sm" onClick={handleReady}>Mark Ready for Scheduling</button>
      )}
      {sc.status === 'Ready for Scheduling' && (
        <div className="msg-success" style={{ margin: 0 }}>
          <i className="ti ti-circle-check"></i> Ready -- go to OT Scheduling to book a date.
        </div>
      )}
    </div>
  );
}

export default function SurgicalPage() {
  const [cases, setCases] = useState([]);
  const [packages, setPackages] = useState([]);

  const refresh = useCallback(async () => {
    setCases(await getSurgicalCases());
    setPackages(await getPackagesForSelection());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      {cases.map((sc) => (
        <CaseCard key={sc.id} sc={sc} packages={packages} onUpdate={refresh} />
      ))}
      {cases.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          No surgical cases pending workup. Mark a patient for surgery from their Consultation.
        </div>
      )}
    </div>
  );
}

