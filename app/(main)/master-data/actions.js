'use server';

import { createClient } from '@/lib/supabase-server';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

// Matches the database's initcap() normalization used for patient names
// (see app/(main)/patients/new/registration-form.js) -- applied here so
// master data names are consistent no matter how staff typed them in.
function toTitleCase(str) {
  if (!str) return str;
  return str.trim().toLowerCase().replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

// Codes are never typed by staff -- every master table auto-generates its
// own PREFIX + zero-padded sequence number, continuing from whatever's
// already in the table. `filter` scopes the sequence (e.g. per-department
// for services, per-category for history options) since those tables
// share one physical table across several logical code sequences.
async function nextCode(supabase, table, prefix, width, filter) {
  let q = supabase.from(table).select('code');
  if (filter) q = filter(q);
  const { data } = await q;
  const re = new RegExp(`^${prefix}(\\d+)$`);
  let max = 0;
  (data || []).forEach((row) => {
    const m = row.code?.match(re);
    if (m) max = Math.max(max, parseInt(m[1], 10));
  });
  return `${prefix}${String(max + 1).padStart(width, '0')}`;
}

// Generic hard delete works the same way across all master tables --
// permanent removal, logged like every other change. Foreign-key-backed
// references (e.g. a Package linked to a Procedure) surface as a normal
// error rather than silently cascading.
export async function deleteMasterRecord(table, id, code) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, 'Delete', `${code || id} deleted`);
  return { success: true };
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
  const name = toTitleCase(values.name);
  const code = await nextCode(supabase, 'master_iop_methods', 'IOPM', 2);
  const { error } = await supabase.from('master_iop_methods').insert({ code, name, status: 'Active' });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_iop_methods', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateIopMethod(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_iop_methods').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iop_methods', oldValues.code, 'Edit', oldValues.name !== name ? `Name ${oldValues.name} -> ${name}` : 'No field changes');
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
  const name = toTitleCase(values.name);
  const code = await nextCode(supabase, 'master_clinical_observations', 'OBS', 2);
  const { error } = await supabase.from('master_clinical_observations').insert({ code, name, status: 'Active' });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_clinical_observations', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateClinicalObservation(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_clinical_observations').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_clinical_observations', oldValues.code, 'Edit', oldValues.name !== name ? `Name ${oldValues.name} -> ${name}` : 'No field changes');
  return { success: true };
}

// ── HISTORY OPTIONS (Clinical Master -- chip options in the doctor's
// Consultation History tab: Chief Complaint, Ocular/Medical/Family
// History). Four categories in one table; code is unique per category
// (not globally) since e.g. "Glaucoma" is a legitimate chip in both
// Ocular History and Family History. ──
export async function getHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_history_options').select('*').order('category').order('name');
  return data || [];
}
// Code prefix is per-category since the same table backs all four
// categories but code uniqueness (and the sequence numbering) is scoped
// to one category at a time -- see master_history_options_category_code_key.
const HISTORY_CODE_PREFIXES = {
  chief_complaint: 'CC', ocular_history: 'OH', medical_history: 'MH', family_history: 'FH',
};

export async function addHistoryOption(values) {
  const supabase = await createClient();
  const prefix = HISTORY_CODE_PREFIXES[values.category];
  if (!prefix) return { error: 'Invalid category.' };
  const name = toTitleCase(values.name);
  const code = await nextCode(supabase, 'master_history_options', prefix, 3, (q) => q.eq('category', values.category));
  const { error } = await supabase.from('master_history_options').insert({
    code, name, category: values.category, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_history_options', code, 'Create', `${name} (${values.category}) created`);
  return { success: true };
}
export async function updateHistoryOption(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_history_options').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_history_options', oldValues.code, 'Edit', oldValues.name !== name ? `Name ${oldValues.name} -> ${name}` : 'No field changes');
  return { success: true };
}

// Active-only, grouped by category -- what the doctor's Consultation
// History tab actually renders as selectable chips
// (app/(main)/consultation/[id]/history-tab.js).
export async function getActiveHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_history_options')
    .select('category, name')
    .eq('status', 'Active')
    .order('name');

  const grouped = { chief_complaint: [], ocular_history: [], medical_history: [], family_history: [] };
  (data || []).forEach((row) => {
    if (grouped[row.category]) grouped[row.category].push(row.name);
  });
  return grouped;
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
  const name = toTitleCase(values.name);
  const prefix = values.dept.slice(0, 3).toUpperCase();
  const code = await nextCode(supabase, 'master_services', prefix, 3, (q) => q.eq('dept', values.dept));
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_services', code, 'Create', `${name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_services').update({
    name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
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
  const name = toTitleCase(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes || null,
    procedure_id: values.procedureId || null, status: 'Active',
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_packages').update({
    name, includes: values.includes, procedure_id: values.procedureId || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
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
  const name = toTitleCase(values.name);
  const code = await nextCode(supabase, 'master_procedures', 'PR', 3);
  const { error } = await supabase.from('master_procedures').insert({
    code, name, category: values.category, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_procedures', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateProcedure(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_procedures').update({ name, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_procedures', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
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
  const brand = toTitleCase(values.brand);
  const generic = toTitleCase(values.generic);
  const code = await nextCode(supabase, 'master_drugs', 'DRG', 3);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength,
    form: values.form, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_drugs', code, 'Create', `${generic} (${brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const brand = toTitleCase(values.brand);
  const generic = toTitleCase(values.generic);
  const { error } = await supabase.from('master_drugs').update({
    brand, generic, strength: values.strength, form: values.form,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.generic !== generic) changes.push(`Generic ${oldValues.generic} -> ${generic}`);
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
  const name = toTitleCase(values.name);
  const code = await nextCode(supabase, 'master_diagnoses', 'DIAG', 4);
  const { error } = await supabase.from('master_diagnoses').insert({
    code, name, category: values.category, status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'Code collision generating a new code -- please try again.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'master_diagnoses', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDiagnosisMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = toTitleCase(values.name);
  const { error } = await supabase.from('master_diagnoses').update({ name, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_diagnoses', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.


