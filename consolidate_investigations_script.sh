mkdir -p "app/(main)/master-data/clinical" "app/(main)/master-data/financial"

cat > "app/(main)/master-data/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

export async function getMasterAuditLog(masterTable) {
  const supabase = await createClient();
  let q = supabase.from('master_data_audit_log').select('*, profiles(full_name)').order('changed_at', { ascending: false }).limit(30);
  if (masterTable) q = q.eq('master_table', masterTable);
  const { data } = await q;
  return data || [];
}

// Generic toggle works the same way across all 5 master tables --
// every one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

// ── SERVICES ──
export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_services').insert({
    code: values.code, name: values.name, dept: values.dept,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_services', values.code, 'Create', `${values.name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_services').update({
    name: values.name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== values.name) changes.push(`Name ${oldValues.name} -> ${values.name}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  if (oldValues.dept !== values.dept) changes.push(`Dept ${oldValues.dept} -> ${values.dept}`);
  await logMasterAudit(supabase, 'master_services', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}

// ── PACKAGES ──
export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_packages').insert({
    code: values.code, name: values.name, price: parseFloat(values.price) || 0,
    includes: values.includes, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_packages', values.code, 'Create', `${values.name} created -- Rs.${values.price}`);
  return { success: true };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_packages').update({
    name: values.name, price: parseFloat(values.price) || 0, includes: values.includes,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== values.name) changes.push(`Name ${oldValues.name} -> ${values.name}`);
  if (String(oldValues.price) !== String(values.price)) changes.push(`Price Rs.${oldValues.price} -> Rs.${values.price}`);
  if (oldValues.includes !== values.includes) changes.push(`Includes updated`);
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*').order('generic');
  return data || [];
}
export async function addDrug(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_drugs').insert({
    code: values.code, brand: values.brand, generic: values.generic, strength: values.strength,
    form: values.form, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── DIAGNOSES ──
export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_diagnoses').insert({
    code: values.code, name: values.name, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.


EOF

cat > "app/(main)/master-data/clinical/page.js" << 'EOF'
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

EOF

cat > "app/(main)/master-data/financial/page.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService,
  getPackages, addPackage, updatePackage,
  getMasterAuditLog,
} from '../actions';

const TABS = [
  { key: 'services', label: 'Services', table: 'master_services' },
  { key: 'packages', label: 'Packages', table: 'master_packages' },
];

const DEPTS = ['Consultation', 'Investigation', 'Pharmacy', 'Surgery'];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status, record.code);
    setLoading(false);
    onUpdate();
  }
  return (
    <button className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ border: 'none', cursor: 'pointer' }} onClick={handleToggle} disabled={loading}>
      {record.status}
    </button>
  );
}

export default function FinancialMastersPage() {
  const [activeTab, setActiveTab] = useState('services');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setAuditLog(await getMasterAuditLog(activeTab === 'services' ? 'master_services' : 'master_packages'));
  }, [activeTab]);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError(''); setSuccess('');
    if (!form.code || !form.name) { setError('Code and name are required.'); return; }

    const result = activeTab === 'services' ? await addService(form) : await addPackage(form);
    if (result?.error) { setError(result.error); return; }
    setSuccess(`${form.name} added.`);
    setForm({});
    setShowAdd(false);
    refresh();
  }

  function startEdit(record) {
    setError(''); setSuccess('');
    setEditingId(record.id);
    if (activeTab === 'services') {
      setEditForm({ name: record.name, dept: record.dept, rate: record.rate, gstPct: record.gst_pct });
    } else {
      setEditForm({ name: record.name, price: record.price, includes: record.includes });
    }
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    const result = activeTab === 'services'
      ? await updateService(record.id, record, editForm)
      : await updatePackage(record.id, record, editForm);
    if (result?.error) { setError(result.error); return; }
    setSuccess(`${editForm.name} updated.`);
    setEditingId(null);
    refresh();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div>
        <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
          {TABS.map((t) => (
            <button
              key={t.key}
              className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
              onClick={() => { setActiveTab(t.key); setShowAdd(false); setEditingId(null); setError(''); setSuccess(''); }}
            >
              {t.label}
            </button>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> {TABS.find((t) => t.key === activeTab).label}</div>
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}
          {activeTab === 'services' && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Investigation rates live here too -- filter or set Dept to &quot;Investigation&quot;. This is the single source of truth for every priced item; nothing else in the app maintains a separate copy.
            </div>
          )}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {activeTab === 'services' ? (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <select className="fi" onChange={update('dept')} defaultValue="">
                    <option value="" disabled>Dept</option>
                    {DEPTS.map((d) => <option key={d}>{d}</option>)}
                  </select>
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              ) : (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Price" onChange={update('price')} />
                  <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 3' }} onChange={update('includes')} />
                </div>
              )}
              <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
            </div>
          )}

          {activeTab === 'services' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Dept</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {services.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.dept} onChange={updateEdit('dept')}>
                          {DEPTS.map((d) => <option key={d}>{d}</option>)}
                        </select>
                      </td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 80 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 60 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${s.status === 'Active' ? 'b-green' : 'b-gray'}`}>{s.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(s)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={s.id}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td><td>{s.dept}</td>
                      <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td><button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button></td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}

          {activeTab === 'packages' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Price</th><th>Includes</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 90 }} value={editForm.price} onChange={updateEdit('price')} /></td>
                      <td><input className="fi fi-sm" value={editForm.includes} onChange={updateEdit('includes')} /></td>
                      <td><span className={`badge ${p.status === 'Active' ? 'b-green' : 'b-gray'}`}>{p.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(p)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td><td>Rs.{p.price}</td><td>{p.includes}</td>
                      <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                      <td><button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i></button></td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Change History -- {TABS.find((t) => t.key === activeTab).label}
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded yet.</div>}
          {auditLog.map((a) => (
            <div key={a.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span className={`badge ${a.action === 'Create' ? 'b-green' : a.action === 'Edit' ? 'b-blue' : a.action === 'Reactivate' ? 'b-teal' : 'b-red'}`} style={{ fontSize: 10 }}>{a.action}</span>
                <span style={{ fontSize: 10, color: 'var(--g400)' }}>{new Date(a.changed_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
              </div>
              <div style={{ marginTop: 3, fontFamily: 'monospace', fontSize: 11, color: 'var(--g600)' }}>{a.record_code}</div>
              <div style={{ marginTop: 2 }}>{a.detail}</div>
              <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{a.profiles?.full_name || 'Staff'}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

EOF

echo "Investigations consolidated into Financial Masters only - removed duplicate empty master_investigations tab."