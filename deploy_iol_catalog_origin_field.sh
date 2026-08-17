#!/bin/bash
set -e
echo "Deploying: IOL Catalog - add Origin (Imported/Indian) dropdown column"

cat > "app/(main)/master-data/actions.js" << 'VEDA_EOF_1'
'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

// Change History is Administrator-only (app-layer check here is a UX
// convenience -- the real boundary is the RLS policy on
// master_data_audit_log itself, which already blocks SELECT for
// non-admins at the database level).
export async function getMasterAuditLog(masterTable) {
  const supabase = await createClient();
  if (!(await isCurrentUserAdmin(supabase))) return [];
  let q = supabase.from('master_data_audit_log').select('*, profiles(full_name)').order('changed_at', { ascending: false }).limit(30);
  if (masterTable) q = q.eq('master_table', masterTable);
  const { data } = await q;
  return data || [];
}

// Lets client components (this page is 'use client') know whether to
// show the Change History card at all, rather than fetching it and
// getting an empty array back either way.
export async function amIAdmin() {
  return isCurrentUserAdmin();
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

// Derives a short prefix from a category (or a fixed fallback for
// tables with no category concept) -- multi-word categories become an
// initialism ("Minor Procedure" -> MP, "chief_complaint" -> CC), single
// words are used whole if short enough or trimmed to 3 letters
// otherwise ("Cataract" -> CAT, "EDOF" -> EDOF).
function codePrefix(categoryOrFallback) {
  const words = (categoryOrFallback || '').trim().split(/[\s_]+/).filter(Boolean);
  if (words.length === 0) return 'GEN';
  if (words.length === 1) return words[0].length <= 4 ? words[0].toUpperCase() : words[0].slice(0, 3).toUpperCase();
  return words.map((w) => w[0]).join('').toUpperCase().slice(0, 4);
}

// Short alphanumeric codes, auto-generated and linked to category where
// one exists (e.g. Surgery category "Cataract" -> CAT01, CAT02...;
// Procedure category "Minor Procedure" -> MP01, MP02...; History
// Option category "chief_complaint" -> CC01, CC02...). For Clinical
// Master tables with no category concept (IOP Methods, Clinical
// Observations), pass a fixed short fallback prefix instead, so every
// code in Clinical Masters follows the same short PREFIX+NN pattern
// rather than some being long name-derived slugs like the old scheme
// produced.
async function generateCategoryCode(supabase, table, categoryOrFallback) {
  const prefix = codePrefix(categoryOrFallback);
  const { data } = await supabase.from(table).select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(2, '0')}`;
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

// ── EXPENSE CATEGORIES (Financial Master -- used in Cash Management > Petty Cash) ──
export async function getExpenseCategories() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').order('name');
  return data || [];
}
export async function addExpenseCategory(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_expense_categories', 'EXP');
  const { error } = await supabase.from('master_expense_categories').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_expense_categories', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateExpenseCategory(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_expense_categories').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_expense_categories', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
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
  const code = await generateCategoryCode(supabase, 'master_iop_methods', 'IOP');
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

// ── DRUG TYPES (Financial Master -- Pharmacy tab, drives what dosage
// phrasing options the doctor's Prescription picker shows) ──
export async function getDrugTypes() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drug_types').select('*').order('name');
  return data || [];
}
export async function addDrugType(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_drug_types', 'TYP');
  const { error } = await supabase.from('master_drug_types').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drug_types', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDrugType(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_drug_types').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_drug_types', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteDrugType(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drug_types', id, code);
}

// Dosage phrasing options nested under a drug type -- e.g. "Apply thin
// layer" under Eye Ointment, "1 drop" under Eye Drop. Simple list items
// (like Package line items), not full master records, so no audit code.
export async function getDosageOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_dosage_options').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}
export async function addDosageOption(drugTypeId, dosageText) {
  const supabase = await createClient();
  const text = (dosageText || '').trim();
  if (!text) return { error: 'Dosage text is required.' };
  const { data: existing } = await supabase.from('master_dosage_options').select('display_order').eq('drug_type_id', drugTypeId).order('display_order', { ascending: false }).limit(1);
  const nextOrder = (existing?.[0]?.display_order ?? 0) + 1;
  const { error } = await supabase.from('master_dosage_options').insert({ drug_type_id: drugTypeId, dosage_text: text, display_order: nextOrder });
  if (error) return { error: error.message };
  return { success: true };
}
export async function removeDosageOption(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_dosage_options').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGICAL CONSUMABLES (Clinical Master -- Patient Check-In dropdown
// and Intraoperative Management quick-pick, both in OT Intraop) ──
export async function getSurgicalConsumablesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgical_consumables').select('*').order('name');
  return data || [];
}
export async function addSurgicalConsumable(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_surgical_consumables', 'CONS');
  const { error } = await supabase.from('master_surgical_consumables').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgical_consumables', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgicalConsumable(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_surgical_consumables').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_surgical_consumables', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteSurgicalConsumable(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgical_consumables', id, code);
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
  const code = await generateCategoryCode(supabase, 'master_clinical_observations', 'OBS');
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
  const code = await generateCategoryCode(supabase, 'master_history_options', values.category);
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

  const grouped = { chief_complaint: [], ocular_history: [], medical_history: [], family_history: [], drug_history: [], allergy: [] };
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
    .select('id, code, full_name, designation, status')
    .eq('designation', 'Doctor')
    .order('full_name');
  const doctors = data || [];

  // Self-heal: any doctor profile created via User Management since this
  // was added (or missed by the one-time backfill) won't have a code yet.
  // Assign the next one in the same uniform DOC01, DOC02... sequence used
  // everywhere else in Clinical Masters, rather than anything category- or
  // designation-specific.
  const missing = doctors.filter((d) => !d.code);
  for (const d of missing) {
    // Re-queried fresh each time so each new code accounts for the one
    // just assigned above it.
    const code = await generateCategoryCode(supabase, 'profiles', 'DOC');
    const { error } = await supabase.from('profiles').update({ code }).eq('id', d.id);
    if (!error) d.code = code;
  }
  return doctors;
}

// ── SERVICES ──
// Services (Consultation, Investigation, Surgery, Pharmacy departments
// in master_services) follow their own long-established CON001, INV001...
// pattern -- 3-digit, scoped per department -- rather than the 2-digit
// generateCategoryCode scheme above. Kept separate so it stays exactly
// consistent with the codes already seeded in the database.
async function generateServiceCode(supabase, dept) {
  const prefix = (dept || 'SVC').slice(0, 3).toUpperCase();
  const { data } = await supabase.from('master_services').select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateServiceCode(supabase, values.dept);
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
    investigation_package: values.investigationPackage?.trim() || null,
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
    investigation_package: values.investigationPackage?.trim() || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  if (oldValues.dept !== values.dept) changes.push(`Dept ${oldValues.dept} -> ${values.dept}`);
  if ((oldValues.investigation_package || '') !== (values.investigationPackage || '')) changes.push(`Package ${oldValues.investigation_package || '--'} -> ${values.investigationPackage || '--'}`);
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
  const { data } = await supabase.from('master_packages').select('*, master_surgeries(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes ? normalizeName(values.includes) : null,
    surgery_id: values.surgeryId || null, status: 'Active',
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
    name, includes, surgery_id: values.surgeryId || null,
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

// ── PROCEDURES (Clinical Master -- minor, in-clinic procedures a doctor
// performs directly, e.g. "Syringing", "FB Removal". Distinct from
// SURGERIES below, which are OT-based and back billing Packages.) ──
export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_procedures', category);
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

// ── SURGERIES (Clinical Master -- the OT-based surgery a doctor advises,
// e.g. "Phaco Cataract Surgery". No price -- pure clinical classification.
// Multiple billing Packages can point at one surgery, sub-classified by
// IOL type/origin for Cataract.) ──
export async function getSurgeries() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('*').order('name');
  return data || [];
}
export async function addSurgery(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_surgeries', 'SUR');
  const { error } = await supabase.from('master_surgeries').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgeries', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgery(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_surgeries').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_surgeries', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteSurgery(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgeries', id, code);
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name)').order('generic');
  return data || [];
}
// Drugs (Pharmacy tab) -- fixed "DRG" prefix, 3-digit sequence, same
// PREFIX+NNN shape as Services (CON001...) and Packages (PKG001...)
// rather than the old name-derived slug codes.
async function generateDrugCode(supabase) {
  const { data } = await supabase.from('master_drugs').select('code').ilike('code', 'DRG%');
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(/^DRG(\d+)$/);
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `DRG${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function addDrug(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const code = await generateDrugCode(supabase);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength, form: normalizeName(values.form),
    drug_type_id: values.drugTypeId || null,
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
    drug_type_id: values.drugTypeId || null,
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

// ── VENDORS (Financial Master -- used by Inventory > Material Input) ──
export async function getVendorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('inventory_vendors').select('*').order('name');
  return data || [];
}
export async function addVendorMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'inventory_vendors', 'Vendor');
  const { error } = await supabase.from('inventory_vendors').insert({
    code, name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
    status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'inventory_vendors', code, 'Create', `${name} added`);
  return { success: true };
}
export async function updateVendorMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('inventory_vendors').update({
    name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
  }).eq('id', id);
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.phone !== values.phone) changes.push(`Phone updated`);
  await logMasterAudit(supabase, 'inventory_vendors', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteVendorMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'inventory_vendors', id, code);
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
  const code = await generateCategoryCode(supabase, 'master_diagnoses', 'DIAG');
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
  const code = await generateCategoryCode(supabase, 'master_iol_catalog', 'IOL');
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, manufacturer, category: values.category, origin: values.origin || null, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}${values.origin ? `, ${values.origin}` : ''}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, manufacturer, category: values.category, origin: values.origin || null }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
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
    .select('id, code, brand, model, manufacturer, category, origin')
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
VEDA_EOF_1

cat > "app/(main)/master-data/clinical/page.js" << 'VEDA_EOF_2'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getDiagnosesMaster, addDiagnosisMaster, updateDiagnosisMaster, deleteDiagnosisMaster,
  getDoctorsMaster,
  getSurgeries, addSurgery, updateSurgery, deleteSurgery,
  getIopMethods, addIopMethod, updateIopMethod, deleteIopMethod,
  getClinicalObservations, addClinicalObservation, updateClinicalObservation, deleteClinicalObservation,
  getHistoryOptions, addHistoryOption, updateHistoryOption, deleteHistoryOption,
  getIolCatalog, addIolCatalogItem, updateIolCatalogItem, deleteIolCatalogItem,
  getSurgicalConsumablesMaster, addSurgicalConsumable, updateSurgicalConsumable, deleteSurgicalConsumable,
} from '../actions';

const TABS = [
  { key: 'doctors', label: 'Doctor' },
  { key: 'surgeries', label: 'Surgery' },
  { key: 'diagnoses', label: 'Diagnoses' },
  { key: 'iopMethods', label: 'IOP Methods' },
  { key: 'observations', label: 'Clinical Observations' },
  { key: 'historyOptions', label: 'Patient History' },
  { key: 'iolCatalog', label: 'IOL Catalog' },
  { key: 'surgicalConsumables', label: 'Surgical Consumables' },
];

const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const IOL_ORIGINS = ['Imported', 'Indian'];

const HISTORY_CATEGORY_LABELS = {
  chief_complaint: 'Chief Complaint',
  ocular_history: 'Ocular History',
  medical_history: 'Medical History',
  family_history: 'Family History',
  drug_history: 'Drug History',
  allergy: 'Allergy',
};

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
  const [surgeries, setSurgeries] = useState([]);
  const [iopMethods, setIopMethods] = useState([]);
  const [observations, setObservations] = useState([]);
  const [historyOptions, setHistoryOptions] = useState([]);
  const [iolCatalog, setIolCatalog] = useState([]);
  const [surgicalConsumables, setSurgicalConsumables] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [error, setError] = useState('');

  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});

  const refresh = useCallback(async () => {
    setDiagnoses(await getDiagnosesMaster());
    setDoctors(await getDoctorsMaster());
    setSurgeries(await getSurgeries());
    setIopMethods(await getIopMethods());
    setObservations(await getClinicalObservations());
    setHistoryOptions(await getHistoryOptions());
    setIolCatalog(await getIolCatalog());
    setSurgicalConsumables(await getSurgicalConsumablesMaster());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }
  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  function switchTab(key) {
    setActiveTab(key); setShowAdd(false); setError(''); setEditingId(null);
  }

  async function handleAdd() {
    setError('');
    if (activeTab === 'historyOptions' && !form.category) { setError('Category is required.'); return; }
    if ((activeTab === 'surgeries' || activeTab === 'diagnoses') && !form.category) { setError('Category is required.'); return; }
    if (activeTab === 'iolCatalog') {
      if (!form.brand || !form.model || !form.category) { setError('Brand, model, and category are required.'); return; }
    } else if (!form.name) { setError('Name is required.'); return; }
    let result;
    if (activeTab === 'surgeries') result = await addSurgery(form);
    else if (activeTab === 'iopMethods') result = await addIopMethod(form);
    else if (activeTab === 'observations') result = await addClinicalObservation(form);
    else if (activeTab === 'historyOptions') result = await addHistoryOption(form);
    else if (activeTab === 'iolCatalog') result = await addIolCatalogItem(form);
    else if (activeTab === 'surgicalConsumables') result = await addSurgicalConsumable(form);
    else result = await addDiagnosisMaster(form);
    if (result?.error) { setError(result.error); return; }
    setForm({});
    setShowAdd(false);
    refresh();
  }

  function startEdit(record) {
    setError('');
    setEditingId(record.id);
    if (activeTab === 'surgeries' || activeTab === 'diagnoses') setEditForm({ name: record.name, category: record.category });
    else if (activeTab === 'iolCatalog') setEditForm({ brand: record.brand, model: record.model, manufacturer: record.manufacturer, category: record.category, origin: record.origin || '' });
    else setEditForm({ name: record.name });
  }
  function cancelEdit() {
    setEditingId(null);
    setError('');
  }
  async function saveEdit(record) {
    setError('');
    let result;
    if (activeTab === 'surgeries') result = await updateSurgery(record.id, record, editForm);
    else if (activeTab === 'iopMethods') result = await updateIopMethod(record.id, record, editForm);
    else if (activeTab === 'observations') result = await updateClinicalObservation(record.id, record, editForm);
    else if (activeTab === 'historyOptions') result = await updateHistoryOption(record.id, record, editForm);
    else if (activeTab === 'iolCatalog') result = await updateIolCatalogItem(record.id, record, editForm);
    else if (activeTab === 'surgicalConsumables') result = await updateSurgicalConsumable(record.id, record, editForm);
    else result = await updateDiagnosisMaster(record.id, record, editForm);
    if (result?.error) { setError(result.error); return; }
    setEditingId(null);
    refresh();
  }

  async function handleDelete(record) {
    const label = activeTab === 'iolCatalog' ? `${record.brand} -- ${record.model}` : record.name;
    if (!window.confirm(`Delete "${label}"? This cannot be undone. If it's in use elsewhere, deletion will be blocked and you should mark it Inactive instead.`)) return;
    setError('');
    let result;
    if (activeTab === 'surgeries') result = await deleteSurgery(record.id, record.code);
    else if (activeTab === 'iopMethods') result = await deleteIopMethod(record.id, record.code);
    else if (activeTab === 'observations') result = await deleteClinicalObservation(record.id, record.code);
    else if (activeTab === 'historyOptions') result = await deleteHistoryOption(record.id, record.code);
    else if (activeTab === 'iolCatalog') result = await deleteIolCatalogItem(record.id, record.code);
    else if (activeTab === 'surgicalConsumables') result = await deleteSurgicalConsumable(record.id, record.code);
    else result = await deleteDiagnosisMaster(record.id, record.code);
    if (result?.error) { setError(result.error); return; }
    refresh();
  }

  // Shared row renderer for the 3 simple code/name(/category) tabs --
  // Procedures, IOP Methods, Clinical Observations, Diagnoses. History
  // Options has its own render (extra Category column with a fixed
  // list, not free text).
  function renderSimpleRow(record, table, withCategory) {
    if (editingId === record.id) {
      return (
        <tr key={record.id} style={{ background: 'var(--g50)' }}>
          <td style={{ fontFamily: 'monospace' }}>{record.code}</td>
          <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
          {withCategory && <td><input className="fi fi-sm" value={editForm.category} onChange={updateEdit('category')} /></td>}
          <td><span className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`}>{record.status}</span></td>
          <td style={{ display: 'flex', gap: 4 }}>
            <button className="btn btn-sm btn-primary" onClick={() => saveEdit(record)}>Save</button>
            <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
          </td>
        </tr>
      );
    }
    return (
      <tr key={record.id}>
        <td style={{ fontFamily: 'monospace' }}>{record.code}</td>
        <td>{record.name}</td>
        {withCategory && <td>{record.category}</td>}
        <td><StatusToggle record={record} table={table} onUpdate={refresh} /></td>
        <td style={{ display: 'flex', gap: 4 }}>
          <button className="btn btn-sm" onClick={() => startEdit(record)}><i className="ti ti-edit"></i></button>
          <button className="btn btn-sm" onClick={() => handleDelete(record)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
        </td>
      </tr>
    );
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
            onClick={() => switchTab(t.key)}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="card">
        <div className="card-head">
          <div className="card-title">{TABS.find((t) => t.key === activeTab).label}</div>
          {(activeTab === 'diagnoses' || activeTab === 'surgeries' || activeTab === 'iopMethods' || activeTab === 'observations' || activeTab === 'historyOptions' || activeTab === 'iolCatalog' || activeTab === 'surgicalConsumables') && (
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          )}
        </div>

        {error && <div className="msg-err">{error}</div>}

        {activeTab === 'doctors' && (
          <>
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Reference list only -- the same record used everywhere a doctor is selected (Appointments, Visits, Surgery). To onboard a new doctor or change their name, use User Management (it's tied to their login); status set here (Active/Inactive) is the same status shown there.
            </div>
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Designation</th><th>Status</th></tr></thead>
              <tbody>
                {doctors.map((d) => (
                  <tr key={d.id}>
                    <td>{d.code}</td>
                    <td style={{ fontWeight: 600 }}>{d.full_name}</td><td>{d.designation}</td>
                    <td><StatusToggle record={d} table="profiles" onUpdate={refresh} codeField="full_name" /></td>
                  </tr>
                ))}
                {doctors.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No doctor profiles found. Create one in User Management.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'surgeries' && (
          <>
            <div className="msg-info" style={{ background: 'var(--red-lt, #fbe9e7)', color: 'var(--red)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> The OT-based surgery a doctor advises (e.g. "Phacoemulsification", "SICS") -- no price here. Populates the Surgery dropdown in Doctor's Diagnosis &amp; Plan and links to Counselling (M22). Billing packages for a surgery are set up separately in Financial Masters, and multiple packages can offer the same surgery at different price points (e.g. by IOL type/origin for Cataract). Code is generated automatically from the name.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Phacoemulsification)" onChange={update('name')} />
                  <input className="fi" placeholder="Category (e.g. Cataract, Glaucoma, Retina)" onChange={update('category')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {surgeries.map((s) => renderSimpleRow(s, 'master_surgeries', true))}
                {surgeries.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No surgeries added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'iopMethods' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the Method dropdown in Optometry Assessment's IOP section. Code is generated automatically from the name.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <input className="fi" placeholder="Name (e.g. Goldmann Applanation)" onChange={update('name')} />
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {iopMethods.map((m) => renderSimpleRow(m, 'master_iop_methods', false))}
                {iopMethods.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No IOP methods added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'observations' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the quick-pick chips in Optometry Assessment's Clinical Observations section. Code is generated automatically from the name.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <input className="fi" placeholder="Name (e.g. Poor fixation)" onChange={update('name')} />
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {observations.map((o) => renderSimpleRow(o, 'master_clinical_observations', false))}
                {observations.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No observations added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'historyOptions' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the selectable chips in the doctor's Consultation History tab -- Chief Complaint, Ocular History, Medical History, Family History, Drug History, and Allergy. All six heads are managed on this one page. Code is generated automatically and is unique per category, so the same chip name (e.g. "Glaucoma") can appear in more than one category.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <select className="fi" onChange={update('category')} defaultValue="">
                    <option value="" disabled>Category</option>
                    {Object.entries(HISTORY_CATEGORY_LABELS).map(([key, label]) => (
                      <option key={key} value={key}>{label}</option>
                    ))}
                  </select>
                  <input className="fi" placeholder="Name (e.g. Watering)" onChange={update('name')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Category</th><th>Code</th><th>Name</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {historyOptions.map((h) => (
                  editingId === h.id ? (
                    <tr key={h.id} style={{ background: 'var(--g50)' }}>
                      <td><span className="badge b-gray">{HISTORY_CATEGORY_LABELS[h.category] || h.category}</span></td>
                      <td style={{ fontFamily: 'monospace' }}>{h.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`}>{h.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(h)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={h.id}>
                      <td><span className="badge b-gray">{HISTORY_CATEGORY_LABELS[h.category] || h.category}</span></td>
                      <td style={{ fontFamily: 'monospace' }}>{h.code}</td>
                      <td>{h.name}</td>
                      <td><StatusToggle record={h} table="master_history_options" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(h)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(h)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {historyOptions.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No history options added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'diagnoses' && (
          <>
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Code is generated automatically from the name.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input className="fi" placeholder="Category (e.g. Lens, Retina)" onChange={update('category')} />
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {diagnoses.map((d) => renderSimpleRow(d, 'master_diagnoses', true))}
                {diagnoses.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No diagnoses added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'iolCatalog' && (
          <>
            <div className="msg-info" style={{ background: 'var(--indigo-lt, var(--purple-lt))', color: 'var(--indigo, var(--purple))', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the "Specific IOL" dropdown in Biometry &amp; IOL Planning's Surgeon Approval screen (M29). Code is generated automatically from brand + model.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Brand (e.g. Alcon)" onChange={update('brand')} />
                  <input className="fi" placeholder="Model (e.g. AcrySof IQ)" onChange={update('model')} />
                  <input className="fi" placeholder="Manufacturer" onChange={update('manufacturer')} />
                  <select className="fi" onChange={update('category')} defaultValue="">
                    <option value="" disabled>Category</option>
                    {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                  </select>
                  <select className="fi" onChange={update('origin')} defaultValue="">
                    <option value="" disabled>Origin</option>
                    {IOL_ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                  </select>
                </div>
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Brand</th><th>Model</th><th>Manufacturer</th><th>Category</th><th>Origin</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {iolCatalog.map((i) => (
                  editingId === i.id ? (
                    <tr key={i.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{i.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.model} onChange={updateEdit('model')} /></td>
                      <td><input className="fi fi-sm" value={editForm.manufacturer || ''} onChange={updateEdit('manufacturer')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.category} onChange={updateEdit('category')}>
                          {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                        </select>
                      </td>
                      <td>
                        <select className="fi fi-sm" value={editForm.origin || ''} onChange={updateEdit('origin')}>
                          <option value="">--</option>
                          {IOL_ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                        </select>
                      </td>
                      <td><span className={`badge ${i.status === 'Active' ? 'b-green' : 'b-gray'}`}>{i.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(i)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={i.id}>
                      <td style={{ fontFamily: 'monospace' }}>{i.code}</td>
                      <td style={{ fontWeight: 600 }}>{i.brand}</td>
                      <td>{i.model}</td>
                      <td style={{ color: 'var(--g500)' }}>{i.manufacturer || '--'}</td>
                      <td><span className="badge b-gray">{i.category}</span></td>
                      <td>{i.origin ? <span className={`badge ${i.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{i.origin}</span> : <span style={{ color: 'var(--g400)' }}>--</span>}</td>
                      <td><StatusToggle record={i} table="master_iol_catalog" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(i)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(i)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {iolCatalog.length === 0 && (
                  <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No IOL catalog items added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}

        {activeTab === 'surgicalConsumables' && (
          <>
            <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Populates the consumables dropdown in OT Intraoperative Management&apos;s Patient Check-In tab, and the quick-pick list in Intraoperative Management. Code is generated automatically from the name.
            </div>
            {showAdd && (
              <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
                <input className="fi" placeholder="Name (e.g. Viscoelastic)" onChange={update('name')} />
                <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
              </div>
            )}
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {surgicalConsumables.map((c) => renderSimpleRow(c, 'master_surgical_consumables', false))}
                {surgicalConsumables.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No surgical consumables added yet.</td></tr>
                )}
              </tbody>
            </table>
          </>
        )}
      </div>
    </div>
  );
}

VEDA_EOF_2

echo "Files written. No DB migration needed -- the origin column already exists on master_iol_catalog in both Supabase projects (verified directly)."
echo "Deploy script done."
