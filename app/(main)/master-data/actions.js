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


