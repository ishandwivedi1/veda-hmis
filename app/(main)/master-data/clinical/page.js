'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getDiagnosesMaster, addDiagnosisMaster,
  getDoctorsMaster,
  getProcedures, addProcedure,
  getIopMethods, addIopMethod,
  getClinicalObservations, addClinicalObservation,
} from '../actions';

const TABS = [
  { key: 'doctors', label: 'Doctor' },
  { key: 'procedures', label: 'Procedure' },
  { key: 'diagnoses', label: 'Diagnoses' },
  { key: 'iopMethods', label: 'IOP Methods' },
  { key: 'observations', label: 'Clinical Observations' },
];

function StatusToggle({ record, table, onUpdate, codeField = 'code' }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status, record[codeField]);
    setLoading(false);
    onUpdate();
  }
  return (
    <button
      className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`}
      style={{ border: 'none', cursor: 'pointer' }}
      onClick={handleToggle}
      disabled={loading}
    >
      {record.status}
    </button>
  );
}

export default function ClinicalMastersPage() {
  const [activeTab, setActiveTab] = useState('doctors');
  const [diagnoses, setDiagnoses] = useState([]);
  const [doctors, setDoctors] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [iopMethods, setIopMethods] = useState([]);
  const [observations, setObservations] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    setDiagnoses(await getDiagnosesMaster());
    setDoctors(await getDoctorsMaster());
    setProcedures(await getProcedures());
    setIopMethods(await getIopMethods());
    setObservations(await getClinicalObservations());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError('');
    if (!form.code || !form.name) { setError('Code and name are required.'); return; }
    let result;
    if (activeTab === 'procedures') result = await addProcedure(form);
    else if (activeTab === 'iopMethods') result = await addIopMethod(form);
    else if (activeTab === 'observations') result = await addClinicalObservation(form);
    else result = await addDiagnosisMaster(form);
    if (result?.error) { setError(result.error); return; }
    setForm({});
    setShowAdd(false);
    refresh();
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
            onClick={() => { setActiveTab(t.key); setShowAdd(false); setError(''); }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="card">
        <div className="card-head">
          <div className="card-title">{TABS.find((t) => t.key === activeTab).label}</div>
          {(activeTab === 'diagnoses' || activeTab === 'procedures' || activeTab === 'iopMethods' || activeTab === 'observations') && (
            <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(!showAdd)}>
              <i className="ti ti-plus"></i> Add New
            </button>
          )}
        </div>

        {error && <div className="msg-err">{error}</div>}

        {activeTab === 'doctors' && (
          <>
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Reference list only -- the same record used everywhere a doctor is selected (Appointments, Visits, Surgery). To onboard a new doctor with real login access, use User Management; status set here (Active/Inactive) is the same status shown there.
            </div>
            <table className="tbl">
              <thead><tr><th>Name</th><th>Designation</th><th>Status</th></tr></thead>
              <tbody>
                {doctors.map((d) => (
                  <tr key={d.id}>
                    <td style={{ fontWeight: 600 }}>{d.full_name}</td><td>{d.designation}</td>
                    <td><StatusToggle record={d} table="profiles" onUpdate={refresh} codeField="full_name" /></td>
                  </tr>
                ))}
                {doctors.length === 0 && (
                  <tr><td colSpan={3} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No doctor profiles found. Create one in User Management.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'procedures' && (
          <>
            <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> The clinical surgery type a doctor advises (e.g. &quot;Cataract Surgery&quot;) -- no price here. Billing packages for this procedure are set up separately in Financial Masters, and multiple packages can offer the same procedure at different price points.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery)" onChange={update('name')} />
                  <input className="fi" placeholder="Category (e.g. Cataract, Glaucoma, Retina)" onChange={update('category')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Status</th></tr></thead>
              <tbody>
                {procedures.map((p) => (
                  <tr key={p.id}>
                    <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td><td>{p.category}</td>
                    <td><StatusToggle record={p} table="master_procedures" onUpdate={refresh} /></td>
                  </tr>
                ))}
                {procedures.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No procedures added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'iopMethods' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the Method dropdown in Optometry Assessment's IOP section.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name (e.g. Goldmann Applanation)" onChange={update('name')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Status</th></tr></thead>
              <tbody>
                {iopMethods.map((m) => (
                  <tr key={m.id}>
                    <td style={{ fontFamily: 'monospace' }}>{m.code}</td><td>{m.name}</td>
                    <td><StatusToggle record={m} table="master_iop_methods" onUpdate={refresh} /></td>
                  </tr>
                ))}
                {iopMethods.length === 0 && (
                  <tr><td colSpan={3} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No IOP methods added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'observations' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the quick-pick chips in Optometry Assessment's Clinical Observations section.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name (e.g. Poor fixation)" onChange={update('name')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Status</th></tr></thead>
              <tbody>
                {observations.map((o) => (
                  <tr key={o.id}>
                    <td style={{ fontFamily: 'monospace' }}>{o.code}</td><td>{o.name}</td>
                    <td><StatusToggle record={o} table="master_clinical_observations" onUpdate={refresh} /></td>
                  </tr>
                ))}
                {observations.length === 0 && (
                  <tr><td colSpan={3} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No observations added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'diagnoses' && (
          <>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input className="fi" placeholder="Category (e.g. Lens, Retina)" onChange={update('category')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Status</th></tr></thead>
              <tbody>
                {diagnoses.map((d) => (
                  <tr key={d.id}>
                    <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.name}</td><td>{d.category}</td>
                    <td><StatusToggle record={d} table="master_diagnoses" onUpdate={refresh} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </>
        )}
      </div>
    </div>
  );
}

