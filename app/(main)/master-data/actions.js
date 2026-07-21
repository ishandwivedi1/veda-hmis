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

// Generic toggle works the same way across all master tables -- every
// one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

// ── SHARED HELPERS: auto-code + consistent text formatting ──
// Applied everywhere a person types a free-text name/label into a
// master, so two staff members never accidentally create "iol",
// "IOL", and "Iol" as three different-looking entries, and nobody has
// to invent a unique code by hand.

// Title-cases each word, collapses repeated whitespace, trims ends.
// Deliberately simple/predictable rather than clever -- staff can
// still see exactly what they typed, just consistently capitalized.
function normalizeName(s) {
  return (s || '')
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/\w\S*/g, (w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
}

// Derives a code from the name (upper-snake-case), and appends _2,
// _3... if that code is already taken. scopeColumn/scopeValue let a
// table scope uniqueness to a subset (e.g. master_history_options
// scopes by category, since "Glaucoma" is legitimately both an Ocular
// History and a Family History option).
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

// Delete with a friendly message instead of a raw Postgres error when
// the record is still referenced elsewhere (e.g. a service used on a
// past invoice) -- staff should mark it Inactive in that case instead.
async function deleteMasterRecord(supabase, table, id, code) {
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) {
    if (error.code === '23503') return { error: 'Cannot delete -- this item is already in use elsewhere (e.g. on a past invoice or record). Set it to Inactive instead.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, table, code || id, 'Delete', 'Record deleted');
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

// ── CLINICAL OBSERVATIONS (Clinical Master -- quick-pick chips in
// Optometry Assessment's Clinical Observations section) ──
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
// User Management (needs a real login, service-role auth), and name
// changes belong there too (it's tied to their login identity) -- so
// this tab intentionally offers status management only, no Edit/Delete.
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

// ── PACKAGES ──
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
    iol_category: values.iolCategory || null, origin: values.origin || null,
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
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.includes !== includes) changes.push('Includes updated');
  if ((oldValues.iol_category || '') !== (values.iolCategory || '')) changes.push(`IOL type ${oldValues.iol_category || '--'} -> ${values.iolCategory || '--'}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deletePackage(id, code) {
  const supabase = await createClient();
  // Constituents belong to the package -- clear them first so the
  // package row itself isn't blocked by its own line items.
  await supabase.from('package_line_items').delete().eq('package_id', id);
  return deleteMasterRecord(supabase, 'master_packages', id, code);
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

// ── DRUGS ──
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

// ── DIAGNOSES ──
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

// ── IOL CATALOG (Clinical Master, M29 -- referenced by Biometry &
// IOL Planning's Surgeon Approval screen). Brand/model act as the
// name-equivalent fields for code generation and normalization. ──
export async function getIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iol_catalog').select('*').order('brand').order('model');
  return data || [];
}
export async function addIolCatalogItem(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const code = await generateUniqueCode(supabase, 'master_iol_catalog', `${brand} ${model}`);
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, manufacturer, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, manufacturer, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_iol_catalog', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteIolCatalogItem(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iol_catalog', id, code);
}

// Active-only, grouped by category -- what Surgeon Approval's "Specific
// IOL" dropdown actually consumes.
export async function getActiveIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_iol_catalog')
    .select('id, code, brand, model, manufacturer, category')
    .eq('status', 'Active')
    .order('brand');
  return data || [];
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.
