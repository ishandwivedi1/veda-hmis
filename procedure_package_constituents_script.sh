mkdir -p "app/(main)/master-data/clinical" "app/(main)/master-data/financial" "app/(main)/consultation/[id]"

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

// ── DOCTORS (Clinical Master) ──
// Deliberately NOT a separate table -- doctors are profiles (same
// source User Management and Appointments' doctor dropdown already
// use). This is a management view onto that same data, filtered to
// doctor-type designations, showing both Active and Inactive (unlike
// the dropdown-facing getDoctors() in appointments/actions.js, which
// only wants Active ones). New doctor accounts are still created in
// User Management (needs a real login, service-role auth) -- this tab
// is for reference and status management only.
export async function getDoctorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name, designation, status')
    .or('designation.ilike.%ophthalmologist%,designation.ilike.%doctor%')
    .order('full_name');
  return data || [];
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
  const { data } = await supabase.from('master_packages').select('*, master_procedures(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name: values.name, price: 0, includes: values.includes || null,
    procedure_id: values.procedureId || null, status: 'Active',
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${values.name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_packages').update({
    name: values.name, includes: values.includes, procedure_id: values.procedureId || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== values.name) changes.push(`Name ${oldValues.name} -> ${values.name}`);
  if (oldValues.includes !== values.includes) changes.push('Includes updated');
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}

// ── PACKAGE CONSTITUENTS (breakup for billing / insurance requests) ──
export async function getPackageLineItems(packageId) {
  const supabase = await createClient();
  const { data } = await supabase.from('package_line_items').select('*').eq('package_id', packageId).order('sort_order');
  return data || [];
}
export async function addPackageLineItem(packageId, description, amount) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('package_line_items').select('sort_order').eq('package_id', packageId).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  const { error } = await supabase.from('package_line_items').insert({
    package_id: packageId, description, amount: parseFloat(amount) || 0, sort_order: (existing?.sort_order || 0) + 1,
  });
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', `Constituent added: ${description} -- Rs.${amount}`);
  return { success: true };
}
export async function removePackageLineItem(id, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('package_line_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', 'Constituent removed');
  return { success: true };
}

// ── PROCEDURES (Clinical Master -- the surgery TYPE a doctor advises,
// e.g. "Cataract Surgery". No price -- pure clinical classification.
// Multiple billing Packages can point at one procedure.) ──
export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_procedures').insert({
    code: values.code, name: values.name, category: values.category, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_procedures', values.code, 'Create', `${values.name} created`);
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
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_drugs', values.code, 'Create', `${values.generic} (${values.brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_drugs').update({
    brand: values.brand, generic: values.generic, strength: values.strength, form: values.form,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.generic !== values.generic) changes.push(`Generic ${oldValues.generic} -> ${values.generic}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  await logMasterAudit(supabase, 'master_drugs', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
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
  getDiagnosesMaster, addDiagnosisMaster,
  getDoctorsMaster,
  getProcedures, addProcedure,
} from '../actions';

const TABS = [
  { key: 'doctors', label: 'Doctor' },
  { key: 'procedures', label: 'Procedure' },
  { key: 'diagnoses', label: 'Diagnoses' },
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
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    setDiagnoses(await getDiagnosesMaster());
    setDoctors(await getDoctorsMaster());
    setProcedures(await getProcedures());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError('');
    if (!form.code || !form.name) { setError('Code and name are required.'); return; }
    const result = activeTab === 'procedures' ? await addProcedure(form) : await addDiagnosisMaster(form);
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
          {(activeTab === 'diagnoses' || activeTab === 'procedures') && (
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

EOF

cat > "app/(main)/master-data/financial/page.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService,
  getPackages, addPackage, updatePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug,
  getProcedures,
  getMasterAuditLog,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', type: 'package' }];

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
  const [activeTab, setActiveTab] = useState('Consultation');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [drugs, setDrugs] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const [constituentsFor, setConstituentsFor] = useState(null);
  const [constituents, setConstituents] = useState([]);
  const [newLineDesc, setNewLineDesc] = useState('');
  const [newLineAmount, setNewLineAmount] = useState('');

  const tabDef = TABS.find((t) => t.key === activeTab);
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setProcedures(await getProcedures());
    setAuditLog(await getMasterAuditLog(auditTable));
  }, [auditTable]);

  useEffect(() => { refresh(); }, [refresh]);

  const deptServices = services.filter((s) => s.dept === activeTab);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }
  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError(''); setSuccess('');
    if (tabDef.type === 'drug') {
      if (!form.code || !form.generic) { setError('Code and generic name are required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (!form.code || !form.name) {
      setError('Code and name are required.'); return;
    }

    let result;
    if (tabDef.type === 'package') result = await addPackage(form);
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else result = await addService({ ...form, dept: activeTab });

    if (result?.error) { setError(result.error); return; }
    setSuccess(`${form.name || form.generic} added${tabDef.type === 'package' ? ' -- add its constituents to set the price' : ''}.`);
    setForm({});
    setShowAdd(false);
    refresh();
    if (tabDef.type === 'package' && result.package) openConstituents(result.package);
  }

  function startEdit(record) {
    setError(''); setSuccess('');
    setEditingId(record.id);
    if (tabDef.type === 'package') setEditForm({ name: record.name, includes: record.includes, procedureId: record.procedure_id || '' });
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand, generic: record.generic, strength: record.strength, form: record.form, rate: record.rate, gstPct: record.gst_pct });
    else setEditForm({ name: record.name, rate: record.rate, gstPct: record.gst_pct });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') result = await updatePackage(record.id, record, editForm);
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else result = await updateService(record.id, record, { ...editForm, dept: record.dept });
    if (result?.error) { setError(result.error); return; }
    setSuccess('Updated.');
    setEditingId(null);
    refresh();
  }

  async function openConstituents(pkg) {
    setConstituentsFor(pkg);
    setConstituents(await getPackageLineItems(pkg.id));
    setNewLineDesc(''); setNewLineAmount('');
  }

  function closeConstituents() {
    setConstituentsFor(null);
    setConstituents([]);
  }

  async function handleAddLine() {
    if (!newLineDesc.trim() || !newLineAmount) { setError('Description and amount are required.'); return; }
    setError('');
    const result = await addPackageLineItem(constituentsFor.id, newLineDesc, newLineAmount);
    if (result?.error) { setError(result.error); return; }
    setNewLineDesc(''); setNewLineAmount('');
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  async function handleRemoveLine(id) {
    await removePackageLineItem(id, constituentsFor.id);
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  const constituentsTotal = constituents.reduce((s, c) => s + Number(c.amount), 0);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div>
        <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
          {TABS.map((t) => (
            <button
              key={t.key}
              className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
              onClick={() => { setActiveTab(t.key); setShowAdd(false); setEditingId(null); setError(''); setSuccess(''); }}
            >
              {t.key}
            </button>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> {activeTab}</div>
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {tabDef.type === 'service' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'drug' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Code" onChange={update('code')} />
                  <input className="fi" placeholder="Brand" onChange={update('brand')} />
                  <input className="fi" placeholder="Generic name" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <input className="fi" placeholder="Form (e.g. Eye Drop)" onChange={update('form')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'package' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery -- Standard IOL)" onChange={update('name')} />
                  <select className="fi" onChange={update('procedureId')} defaultValue="">
                    <option value="">-- Link to procedure (optional) --</option>
                    {procedures.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select>
                  <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 2' }} onChange={update('includes')} />
                  <div style={{ gridColumn: 'span 2', fontSize: 11, color: 'var(--g500)' }}>
                    Code auto-generates (PKG001, PKG002...). Price is set by adding constituents after saving.
                  </div>
                </div>
              )}
              <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
            </div>
          )}

          {tabDef.type === 'service' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {deptServices.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
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
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td>
                      <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td><button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button></td>
                    </tr>
                  )
                ))}
                {deptServices.length === 0 && (
                  <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No {activeTab.toLowerCase()} services yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Brand</th><th>Generic</th><th>Strength</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 70 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 55 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${d.status === 'Active' ? 'b-green' : 'b-gray'}`}>{d.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(d)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={d.id}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                      <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                      <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                      <td><button className="btn btn-sm" onClick={() => startEdit(d)}><i className="ti ti-edit"></i></button></td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Procedure</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.procedureId} onChange={updateEdit('procedureId')}>
                          <option value="">--</option>
                          {procedures.map((pr) => <option key={pr.id} value={pr.id}>{pr.name}</option>)}
                        </select>
                      </td>
                      <td>Rs.{p.price}</td>
                      <td><span className={`badge ${p.status === 'Active' ? 'b-green' : 'b-gray'}`}>{p.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(p)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td>
                      <td style={{ fontSize: 12, color: 'var(--g500)' }}>{p.master_procedures?.name || '--'}</td>
                      <td style={{ fontWeight: 600 }}>Rs.{p.price}</td>
                      <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => openConstituents(p)}><i className="ti ti-list-details"></i> Breakup</button>
                        <button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {constituentsFor && (
            <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, marginTop: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                <div style={{ fontSize: 13, fontWeight: 700 }}>
                  <i className="ti ti-list-details" style={{ color: 'var(--teal)' }}></i> Breakup -- {constituentsFor.name} ({constituentsFor.code})
                </div>
                <button className="btn btn-sm" onClick={closeConstituents}><i className="ti ti-x"></i> Close</button>
              </div>
              <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> The package price is always the sum of these constituents -- this is what gets shown when a patient or insurer asks for an itemized breakup.
              </div>
              <table className="tbl" style={{ marginBottom: 12 }}>
                <thead><tr><th>Description</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
                <tbody>
                  {constituents.map((c) => (
                    <tr key={c.id}>
                      <td>{c.description}</td>
                      <td style={{ textAlign: 'right' }}>Rs.{Number(c.amount).toFixed(2)}</td>
                      <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(c.id)}>Remove</button></td>
                    </tr>
                  ))}
                  {constituents.length === 0 && (
                    <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No constituents yet -- price is Rs.0 until you add some.</td></tr>
                  )}
                </tbody>
                <tfoot>
                  <tr style={{ fontWeight: 700 }}>
                    <td>Total</td><td style={{ textAlign: 'right' }}>Rs.{constituentsTotal.toFixed(2)}</td><td></td>
                  </tr>
                </tfoot>
              </table>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" placeholder="e.g. Surgeon Fee, OT Charges, IOL, Consumables..." value={newLineDesc} onChange={(e) => setNewLineDesc(e.target.value)} style={{ flex: 2 }} />
                <input type="number" className="fi" placeholder="Amount" value={newLineAmount} onChange={(e) => setNewLineAmount(e.target.value)} style={{ flex: 1 }} />
                <button className="btn btn-primary btn-sm" onClick={handleAddLine}><i className="ti ti-plus"></i> Add</button>
              </div>
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Change History -- {activeTab}
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

cat > "app/(main)/consultation/[id]/consultation-form.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  toggleWorkflowRequest,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  addReferral,
  removeReferral,
  addCounsellingItem,
  removeCounsellingItem,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
} from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/surgical/actions';
import { getProcedures as getProcedureMasters } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import HistoryTab from './history-tab';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [procedureMasters, setProcedureMasters] = useState([]);
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('history');
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [counselTopic, setCounselTopic] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    getProcedureMasters().then((all) => setProcedureMasters(all.filter((p) => p.status === 'Active')));
  }, []);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
  }, [data]);

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName.trim()) { setError('Procedure name is required.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    refresh();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleAddCounsel() {
    setError('');
    if (!counselTopic.trim()) { setError('Counselling topic is required.'); return; }
    const result = await addCounsellingItem(data.encounter.id, counselTopic);
    if (result.error) { setError(result.error); return; }
    setCounselTopic('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a procedure.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleToggleWorkflow(kind) {
    setError('');
    const result = await toggleWorkflowRequest(data.entry.visits.id, data.encounter.id, kind);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Completed' && i.status !== 'Verified');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  return (
    <div style={{ maxWidth: 1180, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Consultation -- {data.entry.token}</div>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.age} {patient.gender}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {/* WORKFLOW CONTROLS -- Biometry / Medical Fitness / Counselling.
          Independent toggles: a patient can need more than one at once.
          Dilation/Investigation stay in the Actions bar below since
          those physically move the queue entry, not just flag a task. */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 16 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.5px', marginRight: 4 }}>Request:</span>
        {Object.keys(WF_ITEMS).map((kind) => {
          const isActive = activeWorkflows.some((w) => w.kind === kind);
          return (
            <button
              key={kind}
              type="button"
              className="btn btn-sm"
              style={{
                background: isActive ? WF_ITEMS[kind].color : 'rgba(255,255,255,.08)',
                color: isActive ? '#0f172a' : '#e2e8f0',
                borderColor: isActive ? WF_ITEMS[kind].color : 'rgba(255,255,255,.2)',
                fontWeight: isActive ? 700 : 600,
              }}
              onClick={() => handleToggleWorkflow(kind)}
            >
              <i className={`ti ${WF_ITEMS[kind].icon}`}></i> {kind}{isActive ? ' -- Requested' : ''}
            </button>
          );
        })}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
        {/* MAIN COLUMN */}
        <div>
          {/* TABS */}
          <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-message" label="History" />
            <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
            <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
            <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />
          </div>

          {activeTab === 'history' && (
            <HistoryTab
              encounter={data.encounter}
              findings={data.findings}
              iopReadings={data.iopReadings}
              doctorRepeatFindings={data.doctorRepeatFindings}
              onSaved={refresh}
            />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              {/* DIAGNOSIS HISTORY (longitudinal, read-only, Section 13.15) */}
              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              {/* DIAGNOSIS */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Diagnosis</div>
                {data.diagnoses.map((d) => (
                  <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option>
                    <option value="OS">OS</option>
                    <option value="OU">OU</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              {/* PRESCRIPTION */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Prescription</div>
                {data.prescriptions.map((r) => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap' }}>
                  <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>
              </div>

              {/* INVESTIGATIONS */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Investigations</div>
                {data.investigations.map((i) => (
                  <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
                    <option>Routine</option><option>Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              {/* SURGERY */}
              <div className="card" style={{ marginBottom: 16 }}>
                {!showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Mark for Surgery</div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select procedure --</option>
                        {procedureMasters.map((p) => <option key={p.id} value={p.name}>{p.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                        <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                      </select>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              {/* MANAGEMENT PLAN EXPANSION (Ch.14) */}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div>
                  {/* OPTICAL ADVICE */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                    {data.opticalAdvice.map((o) => (
                      <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{o.advice}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                    </div>
                  </div>

                  {/* PROCEDURES */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Procedures</div>
                    {data.procedures.map((p) => (
                      <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['YAG Capsulotomy', 'Intravitreal Injection', 'FB Removal', 'Syringing'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setProcName(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Procedure name..." value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }} />
                      <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 70 }}>
                        <option>OD</option><option>OS</option><option>OU</option>
                      </select>
                      <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                    </div>
                  </div>
                </div>

                <div>
                  {/* REFERRAL */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                    {data.referrals.map((r) => (
                      <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                      <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                        <option value="">-- Destination --</option>
                        <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                      </select>
                      <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                    </div>
                  </div>

                  {/* COUNSELLING TOPICS */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-messages" style={{ color: 'var(--teal)' }}></i> Counselling Topics</div>
                    {data.counsellingItems.map((c) => (
                      <div key={c.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{c.topic}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeCounsellingItem(c.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Cataract counselling', 'Premium IOL discussion', 'Financial counselling', 'Consent education'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setCounselTopic(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Counselling topic..." value={counselTopic} onChange={(e) => setCounselTopic(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleAddCounsel}>Add</button>
                    </div>
                  </div>

                  {/* FOLLOW-UP */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                      <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                        <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                      </select>
                      <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                        <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                      </select>
                      <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                        <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                      </select>
                    </div>
                    <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                    {fuSaved && (
                      <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                        Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                      </div>
                    )}
                  </div>

                  {/* PATIENT INSTRUCTIONS */}
                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                    <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                    {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
                  </div>
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
              Send for Investigation
            </button>
          </div>
        </div>

        {/* RIGHT PANEL */}
        <div>
          {/* ENCOUNTER STATUS */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Encounter Status</div>
            <div style={{ fontSize: 12, color: 'var(--g600)', lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Status</span><span className="badge b-blue">{data.encounter.status}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(data.encounter.started_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>In progress</span><span style={{ fontWeight: 700 }}>{elapsedMin(data.encounter.started_at)}m</span></div>
            </div>
          </div>

          {/* OUTSTANDING TASKS */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list-checks" style={{ color: 'var(--amber)' }}></i> Outstanding Tasks</div>
            {openInvestigations.length === 0 && activeWorkflows.length === 0 && pendingRx.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding.</div>
            )}
            {openInvestigations.map((i) => (
              <div key={i.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i><span style={{ flex: 1 }}>{i.name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{i.status}</span>
              </div>
            ))}
            {activeWorkflows.map((w) => (
              <div key={w.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className={`ti ${WF_ITEMS[w.kind]?.icon || 'ti-clipboard'}`} style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{w.kind}</span><span className="badge b-amber" style={{ fontSize: 9 }}>Requested</span>
              </div>
            ))}
            {pendingRx.map((r) => (
              <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i><span style={{ flex: 1 }}>{r.drug_name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{r.status}</span>
              </div>
            ))}
          </div>

          {/* AUDIT LOG */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
            <div style={{ maxHeight: 260, overflowY: 'auto' }}>
              {data.auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
              {data.auditLog.map((a) => (
                <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
                  <div>{a.message}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Surgery moved to Clinical (Procedure master); Packages get auto-numbered codes + constituent breakup; Mark for Surgery now selects from Procedure master."