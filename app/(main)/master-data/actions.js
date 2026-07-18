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

export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

function normalizeName(s) {
  return (s || '')
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/\w\S*/g, (w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
}

async function generateUniqueCode(supabase, table, name, scopeColumn, scopeValue) {
  const base = (name || 'ITEM').toUpperCase().replace(/[^A-Z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, 24) || 'ITEM';
  let code = base;
  let n = 1;
  for (;;) {
    let q = supabase.from(table).select('id').eq('code', code).limit(1);
    if (scopeColumn) q = q.eq(scopeColumn, scopeValue);
    const { data } = await q;
    if (!data || data.length === 0) return code;
    n += 1;
    code = `${base}_${n}`;
  }
}

async function deleteMasterRecord(supabase, table, id, code) {
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) {
    if (error.code === '23503') return { error: 'Cannot delete -- this item is already in use elsewhere (e.g. on a past invoice or record). Set it to Inactive instead.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, table, code || id, 'Delete', 'Record deleted');
  return { success: true };
}

export async function getIopMethods() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iop_methods').select('*').order('name');
  return data || [];
}
export async function addIopMethod(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateUniqueCode(supabase, 'master_iop_methods', name);
  const { error } = await supabase.from('master_iop_methods').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iop_methods', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateIopMethod(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_iop_methods').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_iop_methods', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteIopMethod(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iop_methods', id, code);
}

export async function getClinicalObservations() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_clinical_observations').select('*').order('name');
  return data || [];
}
export async function addClinicalObservation(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateUniqueCode(supabase, 'master_clinical_observations', name);
  const { error } = await supabase.from('master_clinical_observations').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_clinical_observations', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateClinicalObservation(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_clinical_observations').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_clinical_observations', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteClinicalObservation(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_clinical_observations', id, code);
}

export async function getHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_history_options').select('*').order('category').order('name');
  return data || [];
}
export async function addHistoryOption(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateUniqueCode(supabase, 'master_history_options', name, 'category', values.category);
  const { error } = await supabase.from('master_history_options').insert({ code, name, category: values.category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_history_options', code, 'Create', `${name} (${values.category}) created`);
  return { success: true };
}
export async function updateHistoryOption(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_history_options').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_history_options', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteHistoryOption(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_history_options', id, code);
}

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

export async function getDoctorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name, designation, status')
    .or('designation.ilike.%ophthalmologist%,designation.ilike.%doctor%')
    .order('full_name');
  return data || [];
}

export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateUniqueCode(supabase, 'master_services', name);
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_services', code, 'Create', `${name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
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
export async function deleteService(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_services', id, code);
}

export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*, master_procedures(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes ? normalizeName(values.includes) : null,
    procedure_id: values.procedureId || null, status: 'Active',
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const includes = values.includes ? normalizeName(values.includes) : values.includes;
  const { error } = await supabase.from('master_packages').update({
    name, includes, procedure_id: values.procedureId || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.includes !== includes) changes.push('Includes updated');
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deletePackage(id, code) {
  const supabase = await createClient();
  await supabase.from('package_line_items').delete().eq('package_id', id);
  return deleteMasterRecord(supabase, 'master_packages', id, code);
}

export async function getPackageLineItems(packageId) {
  const supabase = await createClient();
  const { data } = await supabase.from('package_line_items').select('*').eq('package_id', packageId).order('sort_order');
  return data || [];
}
export async function addPackageLineItem(packageId, description, amount) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('package_line_items').select('sort_order').eq('package_id', packageId).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  const { error } = await supabase.from('package_line_items').insert({
    package_id: packageId, description: normalizeName(description), amount: parseFloat(amount) || 0, sort_order: (existing?.sort_order || 0) + 1,
  });
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', `Constituent added: ${normalizeName(description)} -- Rs.${amount}`);
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

export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateUniqueCode(supabase, 'master_procedures', name);
  const { error } = await supabase.from('master_procedures').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_procedures', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateProcedure(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_procedures').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_procedures', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteProcedure(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_procedures', id, code);
}

export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*').order('generic');
  return data || [];
}
export async function addDrug(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const code = await generateUniqueCode(supabase, 'master_drugs', generic || brand);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength, form: normalizeName(values.form),
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drugs', code, 'Create', `${generic} (${brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const form = normalizeName(values.form);
  const { error } = await supabase.from('master_drugs').update({
    brand, generic, strength: values.strength, form,
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
export async function deleteDrug(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drugs', id, code);
}

export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateUniqueCode(supabase, 'master_diagnoses', name);
  const { error } = await supabase.from('master_diagnoses').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_diagnoses', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDiagnosisMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_diagnoses').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_diagnoses', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDiagnosisMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_diagnoses', id, code);
}
