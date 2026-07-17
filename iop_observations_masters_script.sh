mkdir -p "app/(main)/master-data/clinical" "app/(main)/optometry/[id]"

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

// ── IOP METHODS (Clinical Master -- used in Optometry Assessment) ──
export async function getIopMethods() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iop_methods').select('*').order('name');
  return data || [];
}
export async function addIopMethod(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_iop_methods').insert({ code: values.code, name: values.name, status: 'Active' });
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_iop_methods', values.code, 'Create', `${values.name} created`);
  return { success: true };
}

// ── CLINICAL OBSERVATIONS (Clinical Master -- quick-pick chips in
// Optometry Assessment's Clinical Observations section) ──
export async function getClinicalObservations() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_clinical_observations').select('*').order('name');
  return data || [];
}
export async function addClinicalObservation(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_clinical_observations').insert({ code: values.code, name: values.name, status: 'Active' });
  if (error) {
    if (error.code === '23505') return { error: `Duplicate code: ${values.code} already exists.` };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_clinical_observations', values.code, 'Create', `${values.name} created`);
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

EOF

cat > "app/(main)/optometry/[id]/optometry-workspace.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getAssessmentWorkspaceData,
  saveDraft,
  completeAssessment,
  updateCompletedAssessment,
  addIopReading,
} from '@/app/(main)/optometry/actions';
import { getIopMethods, getClinicalObservations } from '@/app/(main)/master-data/actions';

const VA_SNELLEN = ['6/6', '6/9', '6/12', '6/18', '6/24', '6/36', '6/60', '3/60', '2/60', '1/60'];
const VA_SPECIAL = ['CF', 'HM', 'PL', 'NPL'];
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen',
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1: '', add_k2: '', add_axial_length: '', add_pachymetry: '', add_white_to_white: '', add_schirmer: '',
    add_color_vision: '', add_ocular_motility: '', add_syringing: '',
    observation_chips: [], observations_text: '',
    section_va_done: false, section_refraction_done: false, section_iop_done: false, section_additional_done: false, section_obs_done: false,
  };
  VA_FIELDS.forEach((f2) => { f[f2.key] = ''; });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['sph', 'cyl', 'axis'].forEach((p) => { f[`ref_${type}_${eye}_${p}`] = ''; });
      if (type === 'final') f[`ref_${type}_${eye}_add`] = '';
    });
  });
  return f;
}

function AsmtSection({ id, num, color, title, badge, badgeCls, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
          <span className={`badge ${badgeCls}`}>{badge}</span>
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

function VaOptPills({ values, selected, onSelect, disabled }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 6 }}>
      {values.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px solid ${selected === v ? 'var(--teal)' : 'var(--g200)'}`,
            background: selected === v ? 'var(--teal)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
      {VA_SPECIAL.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px dashed ${selected === v ? 'var(--amber)' : 'var(--g200)'}`,
            borderStyle: selected === v ? 'solid' : 'dashed',
            background: selected === v ? 'var(--amber)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
    </div>
  );
}

export default function OptometryWorkspace({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ va: true, refraction: false, iop: false, additional: false, obs: false });
  const [refTab, setRefTab] = useState('obj');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');

  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [iopMethods, setIopMethods] = useState([]);
  const [obsChips, setObsChips] = useState([]);
  const router = useRouter();

  function load() {
    getAssessmentWorkspaceData(queueEntryId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setEntry(result.entry);
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setLocked(result.locked);

      const f = emptyForm();
      Object.keys(f).forEach((key) => {
        if (result.assessment[key] !== null && result.assessment[key] !== undefined) f[key] = result.assessment[key];
      });
      setForm(f);
    });
  }

  useEffect(() => { load(); }, [queueEntryId]);

  useEffect(() => {
    getIopMethods().then((all) => setIopMethods(all.filter((m) => m.status === 'Active')));
    getClinicalObservations().then((all) => setObsChips(all.filter((o) => o.status === 'Active')));
  }, []);

  const isEdit = assessment?.status === 'Completed';

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function setVa(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_va_done: true }));
  }

  function setRef(type, eye, part, value) {
    setForm((prev) => ({ ...prev, [`ref_${type}_${eye}_${part}`]: value, section_refraction_done: true }));
  }

  function toggleObsChip(chip) {
    setForm((prev) => {
      const has = prev.observation_chips.includes(chip);
      return {
        ...prev,
        observation_chips: has ? prev.observation_chips.filter((c) => c !== chip) : [...prev.observation_chips, chip],
        section_obs_done: true,
      };
    });
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value) return;
    const result = await addIopReading(assessment.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setForm((prev) => ({ ...prev, section_iop_done: true }));
    load();
  }

  async function handleSaveDraft() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await saveDraft(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in Optometry Queue.');
    load();
  }

  async function handleComplete() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await completeAssessment(assessment.id, queueEntryId, form);
    setSaving(false);
    if (result.error) {
      setError(result.error);
      if (!openSections.va) toggleSection('va');
      return;
    }
    setOkMsg('Assessment completed -- routed to Doctor Queue.');
    setTimeout(() => router.push('/optometry-dashboard'), 1200);
  }

  async function handleUpdate() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateCompletedAssessment(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Changes saved.');
    load();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!entry || !assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = entry.visits?.patients;
  const doneCount = ['section_va_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done', 'section_obs_done'].filter((k) => form[k]).length;
  const vaScaleValues = vaValuesForScale(form.va_scale);

  const reIopSorted = iopReadings.filter((r) => r.eye === 'RE');
  const leIopSorted = iopReadings.filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  return (
    <div>
      {/* PATIENT STRIP */}
      <div style={{ background: 'linear-gradient(135deg,#0f766e,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>Token {entry.token}</span>
          </div>
        </div>
      </div>

      {/* WORKFLOW PANEL */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#5eead4', boxShadow: '0 0 6px #5eead4', flexShrink: 0 }}></div>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#5eead4' }}>
          {locked ? 'Locked -- Doctor Reviewing' : isEdit ? 'Assessment Completed -- Editable' : 'Optometry -- In Progress'}
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 10, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.4px' }}>Assessment progress</div>
            <div style={{ fontSize: 13, fontWeight: 700, color: '#e2e8f0' }}>{doneCount} / 5 sections</div>
            <div style={{ height: 6, borderRadius: 3, background: 'var(--g200)', width: 160, marginTop: 4, overflow: 'hidden' }}>
              <div style={{ height: '100%', borderRadius: 3, background: 'var(--teal)', width: `${(doneCount / 5) * 100}%`, transition: 'width .3s' }}></div>
            </div>
          </div>
          {!locked && (
            <div style={{ display: 'flex', gap: 6 }}>
              {!isEdit && (
                <>
                  <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.1)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSaveDraft} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> Save Draft
                  </button>
                  <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleComplete} disabled={saving}>
                    <i className="ti ti-circle-check"></i> Complete Assessment
                  </button>
                </>
              )}
              {isEdit && (
                <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleUpdate} disabled={saving}>
                  <i className="ti ti-device-floppy"></i> Save Changes
                </button>
              )}
            </div>
          )}
        </div>
      </div>

      {locked && (
        <div className="msg-err" style={{ marginBottom: 12 }}>
          <i className="ti ti-lock"></i> The doctor has already started this consultation. Shown here for reference only -- no further edits.
        </div>
      )}
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={1} color="var(--teal)" title="Visual Acuity" badge={form.section_va_done ? 'Done' : 'Not started'} badgeCls={form.section_va_done ? 'b-green' : 'b-gray'}
          open={openSections.va} onToggle={() => toggleSection('va')}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => !locked && setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaOptPills values={vaScaleValues} selected={form[f.key]} onSelect={(v) => setVa(f.key, v)} disabled={locked} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={2} color="var(--blue)" title="Refraction" badge={form.section_refraction_done ? 'Done' : 'Not started'} badgeCls={form.section_refraction_done ? 'b-green' : 'b-gray'}
          open={openSections.refraction} onToggle={() => toggleSection('refraction')}
        >
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {[['obj', 'Objective (Auto-Rx)'], ['subj', 'Subjective'], ['final', 'Final Rx']].map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>

          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            {refTab === 'obj' ? 'Auto-refractometer values. Review before finalizing.' : refTab === 'subj' ? 'Values obtained during subjective refraction with trial lenses.' : 'Final accepted refraction used for prescription / optical order.'}
          </div>

          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead>
              <tr>
                <th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{refTab === 'final' && <th>ADD (near)</th>}
              </tr>
            </thead>
            <tbody>
              {['re', 'le'].map((eye) => (
                <tr key={eye}>
                  <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_sph`]} onChange={(e) => setRef(refTab, eye, 'sph', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_cyl`]} onChange={(e) => setRef(refTab, eye, 'cyl', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_axis`]} onChange={(e) => setRef(refTab, eye, 'axis', e.target.value)} placeholder="--" /></td>
                  {refTab === 'final' && (
                    <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_add`]} onChange={(e) => setRef(refTab, eye, 'add', e.target.value)} placeholder="--" /></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Pupillary Distance (PD)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" />
            </div>
            <div>
              <label className="flbl">Vertex Distance (optional)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" />
            </div>
          </div>

          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-info-circle"></i> Device-imported values should be reviewed before finalizing. All 3 refraction types are recorded independently.
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={3} color="var(--purple)" title="Intraocular Pressure" badge={form.section_iop_done ? 'Done' : 'Not started'} badgeCls={form.section_iop_done ? 'b-green' : 'b-gray'}
          open={openSections.iop} onToggle={() => toggleSection('iop')}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" disabled={locked} value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {iopMethods.map((m) => <option key={m.id}>{m.name}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" disabled={locked} value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIopSorted, reIopInput, setReIopInput], ['LE', leIopSorted, leIopInput, setLeIopInput]].map(([eye, list, val, setVal]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings yet</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
                {!locked && (
                  <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                    <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                    <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                  </div>
                )}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={4} color="var(--amber)" title="Additional Measurements" badge={form.section_additional_done ? 'Done' : 'Not started'} badgeCls={form.section_additional_done ? 'b-green' : 'b-gray'}
          open={openSections.additional} onToggle={() => toggleSection('additional')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 12 }}>Complete only the measurements relevant to this visit.</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><input className="fi fi-sm" disabled={locked} value={form.add_k1} onChange={(e) => setField('add_k1', e.target.value)} placeholder="e.g. 43.50 D" /></div>
            <div><label className="flbl">Keratometry K2</label><input className="fi fi-sm" disabled={locked} value={form.add_k2} onChange={(e) => setField('add_k2', e.target.value)} placeholder="e.g. 44.25 D" /></div>
            <div><label className="flbl">Axial Length</label><input className="fi fi-sm" disabled={locked} value={form.add_axial_length} onChange={(e) => setField('add_axial_length', e.target.value)} placeholder="e.g. 23.2 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><input className="fi fi-sm" disabled={locked} value={form.add_pachymetry} onChange={(e) => setField('add_pachymetry', e.target.value)} placeholder="e.g. 542 microns" /></div>
            <div><label className="flbl">White-to-White</label><input className="fi fi-sm" disabled={locked} value={form.add_white_to_white} onChange={(e) => setField('add_white_to_white', e.target.value)} placeholder="e.g. 11.8 mm" /></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><input className="fi fi-sm" disabled={locked} value={form.add_schirmer} onChange={(e) => setField('add_schirmer', e.target.value)} placeholder="e.g. 8/6 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div>
              <label className="flbl">Color vision</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_color_vision} onChange={(e) => setField('add_color_vision', e.target.value)}>
                <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
              </select>
            </div>
            <div>
              <label className="flbl">Ocular motility</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_ocular_motility} onChange={(e) => setField('add_ocular_motility', e.target.value)}>
                <option value="">Not tested</option><option>Full in all directions</option><option>Restricted</option><option>Nystagmus present</option>
              </select>
            </div>
            <div>
              <label className="flbl">Syringing</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_syringing} onChange={(e) => setField('add_syringing', e.target.value)}>
                <option value="">Not done</option><option>Patent RE</option><option>Patent LE</option><option>Patent bilateral</option><option>Block RE</option><option>Block LE</option>
              </select>
            </div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={5} color="var(--g500)" title="Clinical Observations" badge={form.section_obs_done ? 'Done' : 'Not started'} badgeCls={form.section_obs_done ? 'b-green' : 'b-gray'}
          open={openSections.obs} onToggle={() => toggleSection('obs')}
        >
          <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-alert-triangle"></i> Observations shall be descriptive only. No diagnoses or interpretations permitted here.
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
            {obsChips.map((o) => (
              <div
                key={o.id}
                onClick={() => !locked && toggleObsChip(o.name)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.observation_chips.includes(o.name) ? 'var(--teal)' : 'var(--g200)'}`, background: form.observation_chips.includes(o.name) ? 'var(--teal)' : '#fff', color: form.observation_chips.includes(o.name) ? '#fff' : 'var(--g600)' }}
              >
                {o.name}
              </div>
            ))}
          </div>
          <label className="flbl">Additional observations (descriptive -- no diagnoses)</label>
          <textarea className="fi" disabled={locked} rows={2} value={form.observations_text} onChange={(e) => setField('observations_text', e.target.value)} placeholder="e.g. Patient had difficulty with right eye assessment due to glare sensitivity..." />
        </AsmtSection>
      </div>

      {/* AUDIT LOG */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
        {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
        {auditLog.map((a) => (
          <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8 }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
            <span>{a.message}</span>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}


EOF

echo "IOP Methods and Clinical Observations moved from hardcoded arrays into Clinical Masters."