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


