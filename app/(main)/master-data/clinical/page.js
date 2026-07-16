'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getDrugs, addDrug,
  getDiagnosesMaster, addDiagnosisMaster,
} from '../actions';

const TABS = [
  { key: 'drugs', label: 'Pharmacy', table: 'master_drugs' },
  { key: 'diagnoses', label: 'Diagnoses', table: 'master_diagnoses' },
];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status);
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
  const [activeTab, setActiveTab] = useState('drugs');
  const [drugs, setDrugs] = useState([]);
  const [diagnoses, setDiagnoses] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    setDrugs(await getDrugs());
    setDiagnoses(await getDiagnosesMaster());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError('');
    if (!form.code || (!form.name && !form.generic)) { setError('Code and name are required.'); return; }

    let result;
    if (activeTab === 'drugs') result = await addDrug(form);
    else if (activeTab === 'diagnoses') result = await addDiagnosisMaster(form);

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
          <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(!showAdd)}>
            <i className="ti ti-plus"></i> Add New
          </button>
        </div>

        {error && <div className="msg-err">{error}</div>}

        {showAdd && (
          <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
            {activeTab === 'drugs' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Brand" onChange={update('brand')} />
                <input className="fi" placeholder="Generic name" onChange={update('generic')} />
                <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                <input className="fi" placeholder="Form (e.g. Eye Drop)" onChange={update('form')} />
                <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
              </div>
            )}
            {activeTab === 'diagnoses' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Name" onChange={update('name')} />
                <input className="fi" placeholder="Category (e.g. Lens, Retina)" onChange={update('category')} />
              </div>
            )}
            <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
          </div>
        )}

        {activeTab === 'drugs' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Brand</th><th>Generic</th><th>Strength</th><th>Rate</th><th>GST%</th><th>Status</th></tr></thead>
            <tbody>
              {drugs.map((d) => (
                <tr key={d.id}>
                  <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                  <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                  <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {activeTab === 'diagnoses' && (
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
        )}
      </div>
    </div>
  );
}

