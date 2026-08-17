#!/bin/bash
set -e
echo "Deploying: IOL Catalog - add Price, drop Manufacturer (duplicate of Brand)"

mkdir -p "app/(main)/master-data"
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
  const price = values.price === '' || values.price == null ? null : Number(values.price);
  if (price != null && (Number.isNaN(price) || price < 0)) return { error: 'Enter a valid price.' };
  const code = await generateCategoryCode(supabase, 'master_iol_catalog', 'IOL');
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, price, category: values.category, origin: values.origin || null, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}${values.origin ? `, ${values.origin}` : ''}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const price = values.price === '' || values.price == null ? null : Number(values.price);
  if (price != null && (Number.isNaN(price) || price < 0)) return { error: 'Enter a valid price.' };
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, price, category: values.category, origin: values.origin || null }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
  if (Number(oldValues.price || 0) !== Number(price || 0)) changes.push(`Price ${oldValues.price ?? '--'} -> ${price ?? '--'}`);
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
    .select('id, code, brand, model, category, origin, price')
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

mkdir -p "app/(main)/master-data/clinical"
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
    else if (activeTab === 'iolCatalog') setEditForm({ brand: record.brand, model: record.model, category: record.category, origin: record.origin || '', price: record.price ?? '' });
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
                  <input className="fi" type="number" placeholder="Price (Rs.)" onChange={update('price')} />
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
              <thead><tr><th>Code</th><th>Brand</th><th>Model</th><th>Price</th><th>Category</th><th>Origin</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {iolCatalog.map((i) => (
                  editingId === i.id ? (
                    <tr key={i.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{i.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.model} onChange={updateEdit('model')} /></td>
                      <td><input className="fi fi-sm" type="number" value={editForm.price} onChange={updateEdit('price')} /></td>
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
                      <td style={{ fontWeight: 600 }}>{i.price != null ? `Rs.${Number(i.price).toLocaleString('en-IN')}` : '--'}</td>
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

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/actions.js" << 'VEDA_EOF_3'
'use server';

import { createClient } from '@/lib/supabase-server';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { ensureRecoveryEpisode } from '../ot-recovery/actions';
import { getSurgicalConsumablesMaster } from '../master-data/actions';

// Same Surgical Consumables Clinical Master used to seed both the
// Patient Check-In dropdown and the Intraoperative Management
// quick-pick list -- one source, two input styles for two different
// moments in the workflow.
export async function getConsumableOptions() {
  const all = await getSurgicalConsumablesMaster();
  return all.filter((c) => c.status === 'Active');
}

// ── HISTORY: completed OT cases -- everything BEFORE today. Today's
// completed cases stay on the live Dashboard (see getOTCaseList) until
// the day rolls over, so a completed case doesn't just vanish the
// moment it's marked done. ──
export async function getOTIntraopHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .eq('status', 'Completed')
    .lt('scheduled_date', todayIst)
    .order('scheduled_date', { ascending: false });
  if (error) return [];

  const ids = (data || []).map((b) => b.id);
  let intraopByBooking = {};
  if (ids.length > 0) {
    const { data: records } = await supabase.from('ot_intraop_records').select('ot_schedule_id, surgical_outcome, completed_at, completed_by').in('ot_schedule_id', ids);
    const completedByIds = [...new Set((records || []).map((r) => r.completed_by).filter(Boolean))];
    let doctorMap = {};
    if (completedByIds.length > 0) {
      const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', completedByIds);
      (profiles || []).forEach((p) => { doctorMap[p.id] = p.full_name; });
    }
    (records || []).forEach((r) => { intraopByBooking[r.ot_schedule_id] = { ...r, completedByName: doctorMap[r.completed_by] || '--' }; });
  }

  return (data || []).filter((b) => b.surgical_cases).map((b) => ({ ...b, intraopSummary: intraopByBooking[b.id] || null }));
}

// ── CASE SELECTOR ──
// Today's (and any overdue) bookings that haven't been completed or
// cancelled, PLUS today's already-completed cases -- so a case doesn't
// disappear from the Dashboard the instant it's marked Completed. It
// only moves to History (getOTIntraopHistory) once the day rolls over.
// Also computes, per case, the package price and the patient's current
// advance balance -- Open is gated on the advance fully covering the
// package (surgery billing itself now happens later, at discharge, via
// the Surgery Billing widget on the Billing Dashboard -- not here).
export async function getOTCaseList() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  const [{ data: pending, error: pendingError }, { data: completedToday, error: completedError }] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select('*, master_ot_sessions(name), surgical_cases(id, surgery_code, procedure_name, eye, package_billed, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
      .in('status', ['Scheduled', 'In Progress'])
      .lte('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true })
      .order('sequence_number', { ascending: true, nullsFirst: false }),
    supabase
      .from('ot_schedule')
      .select('*, master_ot_sessions(name), surgical_cases(id, surgery_code, procedure_name, eye, package_billed, patient_id, master_packages:package_id(price), patients:patient_id(first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
      .eq('status', 'Completed')
      .eq('scheduled_date', todayIst)
      .order('scheduled_date', { ascending: true }),
  ]);
  if (pendingError || completedError) return [];

  const cases = [...(pending || []), ...(completedToday || [])].filter((b) => b.surgical_cases);

  const balanceByPatient = {};
  const patientIds = [...new Set(cases.map((b) => b.surgical_cases.patient_id).filter(Boolean))];
  await Promise.all(patientIds.map(async (pid) => {
    const { data: bal } = await supabase.rpc('get_advance_balance', { p_patient_id: pid });
    balanceByPatient[pid] = bal || 0;
  }));

  return cases.map((b) => {
    const packagePrice = Number(b.surgical_cases.master_packages?.price || 0);
    const advanceBalance = balanceByPatient[b.surgical_cases.patient_id] || 0;
    return {
      ...b,
      packagePrice,
      advanceBalance,
      amountPayable: Math.max(0, packagePrice - advanceBalance),
      advanceCleared: packagePrice <= 0 || advanceBalance >= packagePrice,
    };
  });
}

// ── PATIENT REPORTED TO OT -- the surgery patient doesn't route through
//    Optometry or Doctor Consultation queues on the day of surgery; this
//    is how OT staff record that they've physically arrived, straight
//    from the Dashboard widget or the workspace header. ──
export async function markPatientReported(otScheduleId) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_schedule').update({ patient_reported_at: new Date().toISOString() }).eq('id', otScheduleId);
  if (error) return { error: error.message };
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_schedule_audit_log').insert({ ot_schedule_id: otScheduleId, action: 'Patient Reported', detail: 'Patient marked as reported to OT', changed_by: userData?.user?.id || null });
  return { success: true };
}

export async function unmarkPatientReported(otScheduleId) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_schedule').update({ patient_reported_at: null }).eq('id', otScheduleId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FULL CASE DETAIL ──
export async function getOTCaseDetail(otScheduleId) {
  const supabase = await createClient();
  const { data: booking, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(*, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name), master_packages:package_id(name))')
    .eq('id', otScheduleId)
    .single();
  if (error) return { error: error.message };

  const sc = booking.surgical_cases;

  // Planned IOL comes from the surgeon's IOL Approval (a separate
  // module/step now) -- NOT from biometry_records, which only holds
  // the device's raw per-brand recommendations and no longer has any
  // "approved" concept of its own. Matched by surgical_case_id (a real
  // FK), not visit_id -- eye comes from sc.eye directly, set by the
  // doctor, not from biometry at all (biometry doesn't track eye
  // anymore since it's always done for both).
  const [{ data: approval }, { data: intraop }, { data: consumables }, { data: events }] = await Promise.all([
    supabase.from('iol_approvals').select('*, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('ot_intraop_records').select('*').eq('ot_schedule_id', otScheduleId).maybeSingle(),
    supabase.from('ot_intraop_consumables').select('*').eq('ot_schedule_id', otScheduleId).order('added_at'),
    supabase.from('ot_intraop_events').select('*').eq('ot_schedule_id', otScheduleId).order('occurred_at'),
  ]);

  // Consent form uploads -- one attachment lookup per type.
  const consentForms = {};
  await Promise.all(CONSENT_FORM_TYPES.map(async (f) => {
    const { data: files } = await supabase
      .from('clinical_attachments')
      .select('*')
      .eq('entity_type', `ot_consent_${f.key}`)
      .eq('entity_id', otScheduleId)
      .order('uploaded_at', { ascending: false })
      .limit(1);
    consentForms[f.key] = files && files.length > 0 ? files[0] : null;
  }));

  return {
    booking, biometryPlans: approval ? [approval] : [],
    intraop: intraop || null,
    consumables: consumables || [],
    events: (events || []).filter((e) => e.kind === 'Event'),
    complications: (events || []).filter((e) => e.kind === 'Complication'),
    consentForms,
  };
}

async function ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId) {
  const { data: existing } = await supabase.from('ot_intraop_records').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('ot_intraop_records').insert({ ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId }).select('id').single();
  if (error) return null;
  return created.id;
}

// ── CHECK-IN ──
export async function saveCheckinItems(otScheduleId, surgicalCaseId, checkinItems) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({ checkin_items: checkinItems }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeCheckin(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  const consentsOk = await requiredConsentsUploaded(supabase, otScheduleId);
  if (!consentsOk) return { error: 'Upload all required consent forms before completing check-in.' };

  const { data: intraop } = await supabase.from('ot_intraop_records').select('checkin_items').eq('id', recordId).single();
  const checked = Object.values(intraop?.checkin_items || {}).filter(Boolean).length;
  if (checked < CHECKIN_ITEMS.length - 1) return { error: `Complete all check-in items first (${checked}/${CHECKIN_ITEMS.length - 1}).` };

  // VAL-OT-IOL-001: if an approved IOL exists for this case, its power
  // and brand must both be present. Check-in is the last point this can
  // still be corrected -- discovering it missing only after the implant
  // is already in the eye is too late to act on. A case with no
  // approval at all is left alone (non-IOL procedures legitimately have
  // none). Sourced from iol_approvals now, not biometry_records --
  // biometry no longer has an "approved" concept of its own.
  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('eye, power, master_iol_catalog:iol_catalog_id(brand)')
    .eq('surgical_case_id', surgicalCaseId)
    .eq('status', 'Approved')
    .maybeSingle();
  if (approval && (!approval.power || !approval.master_iol_catalog?.brand)) {
    const missing = !approval.power ? 'power' : 'brand';
    return { error: `Approved IOL for ${approval.eye} is missing its ${missing} -- fix this in IOL Approval before check-in can be completed.` };
  }

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_intraop_records').update({ checkin_completed_at: new Date().toISOString() }).eq('id', recordId);
  await supabase.from('ot_schedule').update({ status: 'In Progress' }).eq('id', otScheduleId);
  await supabase.from('ot_schedule_audit_log').insert({ ot_schedule_id: otScheduleId, action: 'Check-In', detail: 'OT check-in completed', changed_by: userData?.user?.id || null });
  return { success: true };
}

async function requiredConsentsUploaded(supabase, otScheduleId) {
  const required = CONSENT_FORM_TYPES.filter((f) => f.required);
  for (const f of required) {
    const { count } = await supabase.from('clinical_attachments').select('id', { count: 'exact', head: true }).eq('entity_type', `ot_consent_${f.key}`).eq('entity_id', otScheduleId);
    if (!count) return false;
  }
  return true;
}

// ── ANAESTHESIA ──
export async function recordAnaesthesia(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update({
    anaesthesia_type: values.type, anaesthetist: values.doctor || null,
    anaesthesia_start: values.start || null, anaesthesia_end: values.end || null,
    anaesthesia_remarks: values.remarks || null, anaesthesia_recorded_at: new Date().toISOString(),
  }).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEDURE / IMPLANT / NOTES / OUTCOME / RECOVERY (draft save) ──
export async function saveIntraopDraft(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };
  const { error } = await supabase.from('ot_intraop_records').update(values).eq('id', recordId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CONSUMABLES ──
export async function addConsumable(otScheduleId, name) {
  const supabase = await createClient();
  if (!name?.trim()) return { error: 'Consumable name is required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('ot_intraop_consumables').insert({ ot_schedule_id: otScheduleId, name: name.trim(), added_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeConsumable(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_intraop_consumables').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EVENTS / COMPLICATIONS ──
export async function addIntraopEvent(otScheduleId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Description is required.' };
  if (values.kind === 'Complication' && !values.management?.trim()) {
    return { error: 'VAL-OT-004: Management is mandatory when recording a complication.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('ot_intraop_events').insert({
    ot_schedule_id: otScheduleId, kind: values.kind, name: values.name.trim(), severity: values.severity,
    management: values.management?.trim() || null, outcome: values.outcome?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIntraopEvent(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('ot_intraop_events').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── COMPLETE SURGERY ──
// This is the completion path OT Scheduling deliberately deferred --
// updates both ot_schedule and the surgical_case, exactly the "future
// module" that was promised when Mark Completed was removed from there.
export async function completeSurgery(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();

  if (!values.implantPower || !values.implantSerial) {
    // Non-IOL procedures can skip this -- checked by the caller passing
    // skipImplant when there's no biometry plan at all.
    if (!values.skipImplant) return { error: 'VAL-OT-003: Implant power and serial/batch number are mandatory.' };
  }
  if (!values.recoveryInstructions) return { error: 'VAL-OT-005: Recovery handover (post-operative instructions) must be documented.' };
  if (!values.surgicalOutcome) return { error: 'VAL-OT-005: Surgical outcome must be recorded.' };
  const needsRemarks = ['Converted Procedure', 'Procedure Deferred', 'Procedure Abandoned'].includes(values.surgicalOutcome);
  if (needsRemarks && !values.outcomeRemarks) {
    return { error: `Remarks are required when the outcome is "${values.surgicalOutcome}".` };
  }
  if (values.variancePresent && !values.varianceReason) {
    return { error: 'AUTO-OT-003: Implant power differs from approved plan -- variance reason required.' };
  }

  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  // Was this already completed before? Determines whether this call is
  // the original completion or a correction to one -- both go through
  // this same function (the "Save Changes" button when unlocked reuses
  // it), but they should read differently in the audit trail.
  const { data: before } = await supabase.from('ot_intraop_records').select('completed_at').eq('id', recordId).maybeSingle();
  const isCorrection = !!before?.completed_at;

  const { data: userData } = await supabase.auth.getUser();

  const { error: recError } = await supabase.from('ot_intraop_records').update({
    implant_manufacturer: values.implantManufacturer || null, implant_model: values.implantModel || null, implant_catalog_id: values.implantCatalogId || null,
    implant_power: values.implantPower || null, implant_category: values.implantCategory || null, implant_serial: values.implantSerial || null,
    implant_expiry: values.implantExpiry || null, implant_eye: values.implantEye || null,
    variance_reason: values.varianceReason || null,
    operative_notes: values.operativeNotes || null,
    surgical_outcome: values.surgicalOutcome || null, outcome_remarks: values.outcomeRemarks || null,
    recovery_destination: values.recoveryDestination || null, recovery_monitoring: values.recoveryMonitoring || null,
    recovery_instructions: values.recoveryInstructions || null, recovery_concerns: values.recoveryConcerns || null,
    // Only stamp completed_at/completed_by the FIRST time -- a
    // correction shouldn't rewrite when the surgery was actually
    // completed or by whom; that's preserved in the audit log instead.
    ...(isCorrection ? {} : { completed_at: new Date().toISOString(), completed_by: userData?.user?.id || null }),
  }).eq('id', recordId);
  if (recError) return { error: recError.message };

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  // Completing surgery and handing over to Recovery are the same real
  // moment -- create the Recovery episode right here instead of a
  // separate "Transfer to Recovery" step.
  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date').eq('id', otScheduleId).single();
  const { data: caseRow } = await supabase.from('surgical_cases').select('visit_id').eq('id', surgicalCaseId).single();
  if (booking && caseRow) await ensureRecoveryEpisode(otScheduleId, surgicalCaseId, caseRow.visit_id, booking.scheduled_date);

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: isCorrection ? 'Corrected After Completion' : 'Completed',
    detail: isCorrection
      ? `Intraop record corrected after completion -- outcome: ${values.surgicalOutcome || '--'}`
      : `Surgery completed -- outcome: ${values.surgicalOutcome || '--'} -- handed over to Recovery (${values.recoveryDestination || '--'})`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── TRANSFER TO RECOVERY (handover, doesn't complete the surgery) ──
export async function transferToRecovery(otScheduleId, surgicalCaseId, values) {
  const supabase = await createClient();
  if (!values.recoveryInstructions?.trim()) return { error: 'Document post-operative instructions before transfer.' };
  const recordId = await ensureIntraopRecord(supabase, otScheduleId, surgicalCaseId);
  if (!recordId) return { error: 'Could not create intraop record.' };

  const { error } = await supabase.from('ot_intraop_records').update({
    recovery_destination: values.recoveryDestination || null, recovery_monitoring: values.recoveryMonitoring || null,
    recovery_instructions: values.recoveryInstructions.trim(), recovery_concerns: values.recoveryConcerns || null,
    transferred_at: new Date().toISOString(),
  }).eq('id', recordId);
  if (error) return { error: error.message };

  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date').eq('id', otScheduleId).single();
  const { data: sc } = await supabase.from('surgical_cases').select('visit_id').eq('id', surgicalCaseId).single();
  if (booking && sc) await ensureRecoveryEpisode(otScheduleId, surgicalCaseId, sc.visit_id, booking.scheduled_date);

  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Transferred to Recovery',
    detail: `Destination: ${values.recoveryDestination || '--'}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

VEDA_EOF_3

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/workspace.js" << 'VEDA_EOF_4'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  getOTCaseDetail,
  saveCheckinItems, completeCheckin, recordAnaesthesia, saveIntraopDraft,
  addConsumable, removeConsumable, addIntraopEvent, removeIntraopEvent,
  completeSurgery, getConsumableOptions, markPatientReported, unmarkPatientReported,
} from './actions';
import { CONSENT_FORM_TYPES, CHECKIN_ITEMS } from './constants';
import { uploadAttachment, deleteAttachment } from '@/lib/attachments';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const STEPS = ['Check-In', 'Anaesthesia', 'Surgery', 'Implant', 'Recovery'];
const EVENT_QUICK = ['Small Pupil', 'Zonular Weakness', 'Difficult Capsulorhexis', 'Iris Prolapse', 'Floppy Iris Syndrome'];
const COMPL_QUICK = ['Posterior Capsular Rupture', 'Dropped Nucleus', 'Vitreous Loss', 'Wound Leak', 'Endothelial Trauma'];
const CONSENT_INDEX = CHECKIN_ITEMS.indexOf('Consent availability verified');
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function fmtTime(secs) {
  const m = String(Math.floor(secs / 60)).padStart(2, '0');
  const s = String(secs % 60).padStart(2, '0');
  return `${m}:${s}`;
}

export default function Workspace({ otScheduleId, onBack, restrictTab }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [log, setLog] = useState([]);
  const [seconds, setSeconds] = useState(0);
  const timerRef = useRef(null);

  const [checkinChecked, setCheckinChecked] = useState({});
  const [uploadingKey, setUploadingKey] = useState(null);
  const [subTab, setSubTab] = useState('checkin');
  const initializedTabRef = useRef(false);

  const [anaesType, setAnaesType] = useState('Topical');
  const [anaesDoctor, setAnaesDoctor] = useState('');
  const [anaesStart, setAnaesStart] = useState('');
  const [anaesEnd, setAnaesEnd] = useState('');
  const [anaesRemarks, setAnaesRemarks] = useState('');

  const [imMfr, setImMfr] = useState('');
  const [imModel, setImModel] = useState('');
  const [imCatalogId, setImCatalogId] = useState('');
  const [imIolMode, setImIolMode] = useState('catalog'); // 'catalog' | 'other'
  const [imPower, setImPower] = useState('');
  const [imCategory, setImCategory] = useState('');
  const [imSerial, setImSerial] = useState('');
  const [imExpiry, setImExpiry] = useState('');
  const [imEye, setImEye] = useState('OD');
  const [varianceReason, setVarianceReason] = useState('');

  const [consumableName, setConsumableName] = useState('');
  const [consumableOptions, setConsumableOptions] = useState([]);
  const [iolCatalog, setIolCatalog] = useState([]);
  const [eventName, setEventName] = useState('');
  const [eventSeverity, setEventSeverity] = useState('Mild');
  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [opNotes, setOpNotes] = useState('');
  const [surgicalOutcome, setSurgicalOutcome] = useState('Successful');
  const [outcomeRemarks, setOutcomeRemarks] = useState('');

  const [recoveryDest, setRecoveryDest] = useState('Recovery Bay 1');
  const [recoveryMonitor, setRecoveryMonitor] = useState('');
  const [recoveryInstructions, setRecoveryInstructions] = useState('');
  const [recoveryConcerns, setRecoveryConcerns] = useState('');
  const [saving, setSaving] = useState(false);
  const [unlocked, setUnlocked] = useState(false);

  function addLog(msg) {
    setLog((prev) => [`${new Date().toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })} -- ${msg}`, ...prev].slice(0, 20));
  }

  const refresh = useCallback(async () => {
    const result = await getOTCaseDetail(otScheduleId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    if (!initializedTabRef.current) {
      initializedTabRef.current = true;
      if (restrictTab) setSubTab(restrictTab);
      else if (result.intraop?.checkin_completed_at || result.booking.status === 'Completed') setSubTab('intraop');
    }
    const io = result.intraop;
    if (io) {
      setCheckinChecked(io.checkin_items || {});
      setAnaesType(io.anaesthesia_type || 'Topical');
      setAnaesDoctor(io.anaesthetist || '');
      setAnaesStart(io.anaesthesia_start || '');
      setAnaesEnd(io.anaesthesia_end || '');
      setAnaesRemarks(io.anaesthesia_remarks || '');
      setImMfr(io.implant_manufacturer || '');
      setImModel(io.implant_model || '');
      setImCatalogId(io.implant_catalog_id || '');
      // Records saved before the catalog dropdown existed have
      // manufacturer/model as free text with no catalog link -- default
      // to "Other" mode so that data is immediately visible instead of
      // silently disappearing behind an unselected dropdown.
      setImIolMode(io.implant_catalog_id ? 'catalog' : (io.implant_manufacturer || io.implant_model) ? 'other' : 'catalog');
      setImPower(io.implant_power || result.biometryPlans[0]?.power || '');
      setImCategory(io.implant_category || result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImSerial(io.implant_serial || '');
      setImExpiry(io.implant_expiry || '');
      // Eye to be implanted is always derived from the Surgery section
      // (surgical_cases.eye, set by the doctor in Diagnosis & Plan) --
      // never from Biometry, which can legitimately be done for a
      // different/single eye even on a bilateral case. Surgery section
      // takes priority over a previously-saved implant_eye too, so a
      // stale value from before this derivation existed can't linger.
      setImEye(result.booking.surgical_cases.eye || io.implant_eye || 'OD');
      setVarianceReason(io.variance_reason || '');
      setOpNotes(io.operative_notes || '');
      setSurgicalOutcome(io.surgical_outcome || 'Successful');
      setOutcomeRemarks(io.outcome_remarks || '');
      setRecoveryDest(io.recovery_destination || 'Recovery Bay 1');
      setRecoveryMonitor(io.recovery_monitoring || '');
      setRecoveryInstructions(io.recovery_instructions || '');
      setRecoveryConcerns(io.recovery_concerns || '');
    } else {
      setImPower(result.biometryPlans[0]?.power || '');
      setImCategory(result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImEye(result.booking.surgical_cases.eye || 'OD');
    }
  }, [otScheduleId]);

  useEffect(() => {
    refresh();
    getConsumableOptions().then(setConsumableOptions);
    getActiveIolCatalog().then(setIolCatalog);
    initializedTabRef.current = false;
    setSubTab('checkin');
    setSeconds(0);
    setUnlocked(false);
    if (timerRef.current) clearInterval(timerRef.current);
    timerRef.current = setInterval(() => setSeconds((s) => s + 1), 1000);
    return () => clearInterval(timerRef.current);
  }, [otScheduleId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const { booking, biometryPlans, intraop, consumables, events, complications, consentForms } = data;
  const sc = booking.surgical_cases;
  const patient = sc.patients;
  const isCompleted = booking.status === 'Completed';
  // Once completed, the intraoperative fields are locked for reference
  // unless explicitly unlocked -- same "Unlock to Edit" pattern as a
  // completed Doctor Consultation, so a genuine correction (wrong
  // implant serial typed in, outcome remarks need fixing) doesn't
  // require a database intervention.
  const isReadOnly = isCompleted && !unlocked;
  const currentStep = isCompleted ? 4 : intraop?.checkin_completed_at ? (intraop?.anaesthesia_recorded_at ? (intraop?.completed_at ? 4 : 2) : 1) : 0;

  const requiredConsentsOk = CONSENT_FORM_TYPES.filter((f) => f.required).every((f) => consentForms[f.key]);
  const manualCheckinDone = CHECKIN_ITEMS.filter((_, i) => i !== CONSENT_INDEX).every((_, i) => {
    const realIdx = i >= CONSENT_INDEX ? i + 1 : i;
    return checkinChecked[realIdx];
  });

  async function handleUploadConsent(key, file) {
    if (!file) return;
    setUploadingKey(key);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', `ot_consent_${key}`);
    formData.append('entityId', otScheduleId);
    const result = await uploadAttachment(formData);
    setUploadingKey(null);
    if (result.error) { setError(result.error); return; }
    addLog(`Consent uploaded: ${CONSENT_FORM_TYPES.find((f) => f.key === key)?.label}`);
    refresh();
  }

  async function handleRemoveConsent(key) {
    const file = consentForms[key];
    if (!file) return;
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  function toggleCheckinItem(i) {
    if (i === CONSENT_INDEX) return;
    const updated = { ...checkinChecked, [i]: !checkinChecked[i] };
    setCheckinChecked(updated);
    saveCheckinItems(otScheduleId, sc.id, updated);
  }

  async function handleToggleReported() {
    if (booking.patient_reported_at) await unmarkPatientReported(otScheduleId);
    else { await markPatientReported(otScheduleId); addLog('Patient marked as reported to OT'); }
    refresh();
  }

  async function handleCompleteCheckin() {
    if (!window.confirm(`Confirm patient check-in for ${patient?.first_name} ${patient?.last_name}?`)) return;
    setError('');
    const result = await completeCheckin(otScheduleId, sc.id);
    if (result.error) { setError(result.error); return; }
    addLog('OT Check-In completed');
    setOk('Check-in complete -- patient confirmed in OT.');
    await refresh();
    // The Patient Check-In module doesn't have an Intraoperative tab to
    // switch to -- send staff back to the queue instead, where the case
    // now shows as checked-in and ready for the OT team.
    if (restrictTab === 'checkin') onBack();
    else setSubTab('intraop');
  }

  async function handleRecordAnaesthesia() {
    setError('');
    const result = await recordAnaesthesia(otScheduleId, sc.id, { type: anaesType, doctor: anaesDoctor, start: anaesStart, end: anaesEnd, remarks: anaesRemarks });
    if (result.error) { setError(result.error); return; }
    addLog(`Anaesthesia recorded: ${anaesType}`);
    refresh();
  }

  async function handleAddConsumable(name) {
    const value = name || consumableName;
    if (!value.trim()) return;
    await addConsumable(otScheduleId, value);
    setConsumableName('');
    addLog(`Consumable: ${value}`);
    refresh();
  }

  async function handleAddEvent() {
    if (!eventName.trim()) return;
    const result = await addIntraopEvent(otScheduleId, { kind: 'Event', name: eventName, severity: eventSeverity });
    if (result.error) { setError(result.error); return; }
    setEventName('');
    addLog(`Event: ${eventName} (${eventSeverity})`);
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addIntraopEvent(otScheduleId, { kind: 'Complication', name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    addLog(`COMPLICATION: ${complName} (${complSeverity})`);
    refresh();
  }

  async function handleSaveDraft() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveIntraopDraft(otScheduleId, sc.id, {
      implant_manufacturer: imMfr || null, implant_model: imModel || null, implant_catalog_id: imCatalogId || null,
      implant_power: imPower || null, implant_category: imCategory || null, implant_serial: imSerial || null, implant_expiry: imExpiry || null,
      implant_eye: imEye, variance_reason: varianceReason || null, operative_notes: opNotes || null,
      surgical_outcome: surgicalOutcome || null, outcome_remarks: outcomeRemarks || null,
      recovery_destination: recoveryDest || null, recovery_monitoring: recoveryMonitor || null,
      recovery_instructions: recoveryInstructions || null, recovery_concerns: recoveryConcerns || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    addLog('Draft saved');
    setOk('Draft saved -- documentation preserved.');
    refresh();
  }

  const plannedPlan = biometryPlans[0];
  const plannedPower = plannedPlan?.power;
  const plannedCategory = plannedPlan?.master_iol_catalog?.category;
  // eye now comes from the same source on both sides (surgical_cases.eye)
  // -- iol_approvals.eye is set from it directly at approval time, and
  // imEye is derived from it here too, so this stays as a defensive
  // check rather than something that can meaningfully drift anymore.
  const plannedEyeNorm = plannedPlan?.eye || null;
  const plannedSpecificIol = plannedPlan?.master_iol_catalog
    ? `${plannedPlan.master_iol_catalog.brand || ''} ${plannedPlan.master_iol_catalog.model || ''}`.trim().toLowerCase()
    : '';
  const actualSpecificIol = `${imMfr} ${imModel}`.trim().toLowerCase();

  const eyeMismatch = plannedEyeNorm && imEye && plannedEyeNorm !== imEye;
  const powerMismatch = plannedPower && imPower && String(plannedPower) !== String(imPower);
  const categoryMismatch = plannedCategory && imCategory && plannedCategory !== imCategory;
  // ID-based comparison when both sides have a catalog entry selected --
  // far more reliable than comparing reconstructed text. Falls back to
  // text comparison only when one side has no catalog link at all (an
  // older record, or a plan/implant that was custom-typed).
  const specificIolMismatch = (plannedPlan?.iol_catalog_id && imCatalogId)
    ? plannedPlan.iol_catalog_id !== imCatalogId
    : !!(plannedSpecificIol && actualSpecificIol && plannedSpecificIol !== actualSpecificIol);
  const variancePresent = !!(plannedPlan && (eyeMismatch || powerMismatch || categoryMismatch || specificIolMismatch));

  async function handleCompleteSurgery() {
    setError(''); setOk('');
    const wasAlreadyCompleted = isCompleted;
    const result = await completeSurgery(otScheduleId, sc.id, {
      implantPower: imPower, implantCategory: imCategory, implantSerial: imSerial, implantManufacturer: imMfr, implantModel: imModel, implantCatalogId: imCatalogId, implantExpiry: imExpiry, implantEye: imEye,
      skipImplant: biometryPlans.length === 0,
      recoveryInstructions, recoveryDestination: recoveryDest, recoveryMonitoring: recoveryMonitor, recoveryConcerns,
      variancePresent, varianceReason,
      operativeNotes: opNotes, surgicalOutcome, outcomeRemarks,
    });
    if (result.error) { setError(result.error); return; }
    clearInterval(timerRef.current);
    if (wasAlreadyCompleted) {
      addLog('INTRAOP RECORD CORRECTED -- changes saved after completion');
      setOk('Changes saved.');
      setUnlocked(false);
    } else {
      addLog('SURGERY COMPLETED -- OT Case marked complete, handed over to Recovery');
      setOk('Surgery completed and handed over to Recovery. Case marked Completed in OT Scheduling.');
    }
    refresh();
  }

  return (
    <div>
      <div style={{ background: isCompleted ? 'linear-gradient(135deg,#14532d,#157a4f)' : 'linear-gradient(135deg,#7f1d1d,#991b1b)', borderRadius: 12, padding: '11px 18px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{booking.id.slice(0, 8)}</div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name} -- {booking.master_ot_sessions?.name}</div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isCompleted ? 'Surgery Completed' : booking.status}</span>
          {isCompleted && (
            <button
              type="button"
              className="btn btn-sm"
              style={{
                borderColor: 'rgba(255,255,255,.3)',
                background: unlocked ? 'rgba(251,191,36,.35)' : 'rgba(255,255,255,.1)',
                color: '#fff',
              }}
              onClick={() => setUnlocked((v) => !v)}
            >
              <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i> {unlocked ? 'Lock' : 'Unlock to Edit'}
            </button>
          )}
          {!isCompleted && (
            <button
              type="button"
              className="btn btn-sm"
              style={{
                borderColor: 'rgba(255,255,255,.3)',
                background: booking.patient_reported_at ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.1)',
                color: '#fff',
              }}
              onClick={handleToggleReported}
              title={booking.patient_reported_at ? `Reported at ${new Date(booking.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Mark patient as reported to OT'}
            >
              <i className={`ti ${booking.patient_reported_at ? 'ti-check' : 'ti-door-enter'}`}></i> {booking.patient_reported_at ? 'Patient Reported' : 'Mark Reported'}
            </button>
          )}
          {!isCompleted && (
            <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '6px 12px' }}>
              <div style={{ fontSize: 9, opacity: .7, textTransform: 'uppercase' }}>OT Duration</div>
              <div style={{ fontSize: 17, fontWeight: 700, fontFamily: 'monospace' }}>{fmtTime(seconds)}</div>
            </div>
          )}
          <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
        </div>
      </div>

      {isCompleted && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed surgery -- changes save immediately and are logged.'
              : 'This surgery is completed. Viewing read-only for reference.'}
          </span>
        </div>
      )}

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '210px 1fr 220px', gap: 14 }}>
        {/* LEFT: Timeline */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 10 }}>OT Timeline</div>
            {STEPS.map((s, i) => (
              <div key={s} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0', borderBottom: i < STEPS.length - 1 ? '1px solid var(--g100)' : 'none' }}>
                <div style={{ width: 26, height: 26, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, flexShrink: 0, border: '2px solid', borderColor: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : 'var(--g200)', background: i < currentStep ? 'var(--green)' : i === currentStep ? 'var(--blue)' : '#fff', color: i <= currentStep ? '#fff' : 'var(--g300)' }}>
                  <i className={`ti ${i < currentStep ? 'ti-check' : i === currentStep ? 'ti-player-play' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
                </div>
                <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{s}</div>
              </div>
            ))}
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Event log</div>
            <div style={{ fontSize: 10, color: 'var(--g500)', maxHeight: 200, overflowY: 'auto' }}>
              {log.map((l, i) => <div key={i} style={{ padding: '3px 0', borderBottom: '1px solid var(--g100)' }}>{l}</div>)}
            </div>
          </div>
        </div>

        {/* CENTER: sections */}
        <div>
          {/* Big-visibility case summary */}
          <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--red)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-scalpel"></i> Procedure</div>
              <div style={{ fontSize: 15, fontWeight: 700, lineHeight: 1.2 }}>{sc.procedure_name}</div>
              {sc.surgery_code && <div style={{ fontSize: 10.5, color: 'var(--g500)', marginTop: 2 }}>{sc.surgery_code}</div>}
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--blue)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-eye"></i> Eye</div>
              <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--blue)' }}>{sc.eye}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--green)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-package"></i> Package</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2, color: sc.master_packages ? 'inherit' : 'var(--g400)' }}>{sc.master_packages?.name || 'No package'}</div>
            </div>
            <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--indigo)' }}>
              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-stethoscope"></i> Surgeon</div>
              <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2 }}>{sc.profiles?.full_name || 'Not assigned'}</div>
            </div>
          </div>

          {!restrictTab && (
            <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
              <button
                type="button"
                onClick={() => setSubTab('checkin')}
                style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'checkin' ? '#fff' : 'transparent', color: subTab === 'checkin' ? 'var(--red)' : 'var(--g500)', cursor: 'pointer', boxShadow: subTab === 'checkin' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
              >
                <i className="ti ti-clipboard-check"></i> Patient Check-In
              </button>
              <button
                type="button"
                onClick={() => (intraop?.checkin_completed_at || isCompleted) && setSubTab('intraop')}
                disabled={!intraop?.checkin_completed_at && !isCompleted}
                title={!intraop?.checkin_completed_at && !isCompleted ? 'Complete Patient Check-In first' : ''}
                style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: subTab === 'intraop' ? '#fff' : 'transparent', color: !intraop?.checkin_completed_at && !isCompleted ? 'var(--g300)' : subTab === 'intraop' ? 'var(--red)' : 'var(--g500)', cursor: !intraop?.checkin_completed_at && !isCompleted ? 'not-allowed' : 'pointer', boxShadow: subTab === 'intraop' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
              >
                <i className="ti ti-building-hospital"></i> Intraoperative Management {!intraop?.checkin_completed_at && !isCompleted && <i className="ti ti-lock" style={{ fontSize: 10 }}></i>}
              </button>
            </div>
          )}

          {restrictTab === 'intraop' && !intraop?.checkin_completed_at && !isCompleted ? (
            <div className="card" style={{ textAlign: 'center', padding: 30 }}>
              <i className="ti ti-lock" style={{ fontSize: 22, display: 'block', marginBottom: 8, color: 'var(--g400)' }}></i>
              <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 4 }}>Patient Check-In not complete</div>
              <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>This case needs to be checked in before Intraoperative Management can be recorded.</div>
              <a href="/patient-checkin" className="btn btn-primary" style={{ textDecoration: 'none' }}>
                <i className="ti ti-clipboard-check"></i> Go to Patient Check-In
              </a>
            </div>
          ) : (
          <>

          {subTab === 'checkin' && (
          <>
          {/* Consent Forms */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-file-check" style={{ color: 'var(--green)' }}></i> Consent Forms</div>
              <span className={`badge ${requiredConsentsOk ? 'b-green' : 'b-gray'}`}>{CONSENT_FORM_TYPES.filter((f) => f.required && consentForms[f.key]).length}/{CONSENT_FORM_TYPES.filter((f) => f.required).length}</span>
            </div>
            {CONSENT_FORM_TYPES.map((f) => {
              const file = consentForms[f.key];
              return (
                <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, border: '2px solid var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0, background: file ? 'var(--green)' : '#fff', borderColor: file ? 'var(--green)' : 'var(--g300)' }}>
                    {file && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}
                  </div>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12.5, fontWeight: 600 }}>{f.label} {!f.required && <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(optional)</span>}</div>
                    <div style={{ fontSize: 11, color: file ? 'var(--g500)' : 'var(--g400)', marginTop: 1 }}>
                      {file ? <><i className="ti ti-paperclip"></i> {file.file_name}</> : 'Not uploaded yet'}
                    </div>
                  </div>
                  {file ? (
                    <div style={{ display: 'flex', gap: 4 }}>
                      {file.url && <a href={file.url} target="_blank" rel="noopener noreferrer" className="btn btn-sm">View</a>}
                      <button className="btn btn-sm" onClick={() => handleRemoveConsent(f.key)}><i className="ti ti-x"></i></button>
                    </div>
                  ) : (
                    <label className="btn btn-sm btn-primary" style={{ cursor: 'pointer', marginBottom: 0 }}>
                      {uploadingKey === f.key ? 'Uploading...' : <><i className="ti ti-upload"></i> Upload</>}
                      <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadConsent(f.key, e.target.files?.[0])} disabled={uploadingKey === f.key} />
                    </label>
                  )}
                </div>
              );
            })}
          </div>

          {/* Check-In */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--blue)' }}></i> OT Check-In</div>
              <span className={`badge ${intraop?.checkin_completed_at ? 'b-green' : 'b-gray'}`}>{intraop?.checkin_completed_at ? 'Complete' : `${Object.values(checkinChecked).filter(Boolean).length}/${CHECKIN_ITEMS.length}`}</span>
            </div>
            {CHECKIN_ITEMS.map((item, i) => (
              i === CONSENT_INDEX ? (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', background: requiredConsentsOk ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: requiredConsentsOk ? 'var(--green)' : '#fff', border: '2px solid', borderColor: requiredConsentsOk ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{requiredConsentsOk && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item} <span style={{ fontSize: 10, color: 'var(--g400)' }}>(auto -- from Consent Forms above)</span></span>
                </div>
              ) : (
                <div key={i} onClick={() => !isReadOnly && toggleCheckinItem(i)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isReadOnly ? 'default' : 'pointer', background: checkinChecked[i] ? 'var(--green-lt)' : '#fff' }}>
                  <div style={{ width: 18, height: 18, borderRadius: 4, background: checkinChecked[i] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checkinChecked[i] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checkinChecked[i] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                  <span>{item}</span>
                </div>
              )
            ))}
            {!intraop?.checkin_completed_at && !isCompleted && (!manualCheckinDone || !requiredConsentsOk) && (
              <div style={{ fontSize: 11, color: 'var(--amber)', marginTop: 8 }}>
                <i className="ti ti-info-circle"></i> Complete all items above{!requiredConsentsOk ? ' and upload required consent forms' : ''} to check in.
              </div>
            )}
          </div>

          {/* Implant Verification */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-disc" style={{ color: 'var(--indigo)' }}></i> Implant Verification</div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div style={{ border: '1.5px solid var(--g200)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Approved IOL Plan</div>
                {plannedPlan ? (
                  <div style={{ fontSize: 12 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>Eye</span><strong>{EYE_LABEL[plannedPlan.eye] || plannedPlan.eye}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>IOL Power</span><strong>{plannedPower || '--'} D</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>IOL Category</span><strong>{plannedCategory || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span style={{ color: 'var(--g500)' }}>Specific IOL</span><strong style={{ textAlign: 'right' }}>{plannedPlan.master_iol_catalog ? `${plannedPlan.master_iol_catalog.brand || ''} ${plannedPlan.master_iol_catalog.model || ''}`.trim() : '--'}</strong></div>
                  </div>
                ) : <div style={{ fontSize: 11, color: 'var(--g400)' }}>No IOL plan (non-IOL procedure)</div>}
              </div>

              <div style={{ border: '1.5px solid', borderColor: variancePresent ? 'var(--red)' : 'var(--green)', background: variancePresent ? 'var(--red-lt)' : 'var(--green-lt)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>Actual Implanted IOL</div>
                  {plannedPlan && <strong style={{ fontSize: 11, color: variancePresent ? 'var(--red)' : 'var(--green)' }}>{variancePresent ? 'VARIANCE' : 'Perfect Match'}</strong>}
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">Eye implanted</label>
                  <select className="fi fi-sm" value={imEye} onChange={(e) => setImEye(e.target.value)} disabled={isReadOnly} style={{ borderColor: eyeMismatch ? 'var(--red)' : undefined }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Power (D)</label>
                  <input className="fi fi-sm" value={imPower} onChange={(e) => setImPower(e.target.value)} disabled={isReadOnly} style={{ borderColor: powerMismatch ? 'var(--red)' : undefined }} />
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Category</label>
                  <select className="fi fi-sm" value={imCategory} onChange={(e) => setImCategory(e.target.value)} disabled={isReadOnly} style={{ borderColor: categoryMismatch ? 'var(--red)' : undefined }}>
                    <option value="">-- Select --</option>
                    <option>Monofocal</option>
                    <option>Monofocal Toric</option>
                    <option>Multifocal</option>
                    <option>EDOF</option>
                  </select>
                </div>
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                    <label className="flbl">Specific IOL (Manufacturer &amp; Brand)</label>
                    {!isReadOnly && (
                      <button
                        type="button"
                        onClick={() => setImIolMode(imIolMode === 'catalog' ? 'other' : 'catalog')}
                        style={{ border: 'none', background: 'none', color: 'var(--blue)', fontSize: 10.5, cursor: 'pointer', padding: 0 }}
                      >
                        {imIolMode === 'catalog' ? 'Not in catalog? Type it in' : 'Pick from catalog instead'}
                      </button>
                    )}
                  </div>
                  {imIolMode === 'catalog' ? (
                    <>
                      <select
                        className="fi fi-sm"
                        value={imCatalogId}
                        onChange={(e) => {
                          const item = iolCatalog.find((c) => c.id === e.target.value);
                          setImCatalogId(e.target.value);
                          setImMfr(item?.brand || '');
                          setImModel(item ? `${item.brand}${item.model ? ' ' + item.model : ''}` : '');
                        }}
                        disabled={isReadOnly}
                        style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }}
                      >
                        <option value="">-- Select IOL --</option>
                        {(imCategory ? iolCatalog.filter((c) => c.category === imCategory) : iolCatalog).map((c) => (
                          <option key={c.id} value={c.id}>{c.brand}{c.model ? ` ${c.model}` : ''} ({c.code})</option>
                        ))}
                      </select>
                      {imCategory && iolCatalog.length > 0 && iolCatalog.filter((c) => c.category === imCategory).length === 0 && (
                        <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 2 }}>No catalog IOLs under &quot;{imCategory}&quot; -- showing full catalog instead.</div>
                      )}
                    </>
                  ) : (
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Manufacturer" value={imMfr} onChange={(e) => { setImMfr(e.target.value); setImCatalogId(''); }} disabled={isReadOnly} style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }} />
                      <input className="fi fi-sm" placeholder="Model" value={imModel} onChange={(e) => { setImModel(e.target.value); setImCatalogId(''); }} disabled={isReadOnly} style={{ borderColor: specificIolMismatch ? 'var(--red)' : undefined }} />
                    </div>
                  )}
                </div>
              </div>
            </div>

            {variancePresent && (
              <div style={{ marginBottom: 10 }}>
                <label className="flbl">Variance reason (mandatory to proceed)</label>
                <input className="fi fi-sm" value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isReadOnly} placeholder="Document reason for deviation from the approved plan..." />
              </div>
            )}

            <div style={{ borderTop: '1px dashed var(--g200)', paddingTop: 10 }}>
              <div style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Serial / Batch (from the implanted unit's label)</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                <div><label className="flbl">Serial / Batch number</label><input className="fi fi-sm" value={imSerial} onChange={(e) => setImSerial(e.target.value)} disabled={isReadOnly} /></div>
                <div><label className="flbl">Expiry date</label><input type="date" className="fi fi-sm" value={imExpiry} onChange={(e) => setImExpiry(e.target.value)} disabled={isReadOnly} /></div>
              </div>
            </div>
          </div>

          {/* Anaesthesia */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-injection" style={{ color: 'var(--teal)' }}></i> Anaesthesia</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Anaesthesia type</label><select className="fi fi-sm" value={anaesType} onChange={(e) => setAnaesType(e.target.value)} disabled={isReadOnly}><option>Topical</option><option>Peribulbar</option><option>Retrobulbar</option><option>Local with Sedation</option><option>General</option></select></div>
              <div><label className="flbl">Anaesthetist</label><input className="fi fi-sm" value={anaesDoctor} onChange={(e) => setAnaesDoctor(e.target.value)} disabled={isReadOnly} placeholder="If applicable" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Start time</label><input type="time" className="fi fi-sm" value={anaesStart} onChange={(e) => setAnaesStart(e.target.value)} disabled={isReadOnly} /></div>
              <div><label className="flbl">End time</label><input type="time" className="fi fi-sm" value={anaesEnd} onChange={(e) => setAnaesEnd(e.target.value)} disabled={isReadOnly} /></div>
            </div>
            <input className="fi fi-sm" value={anaesRemarks} onChange={(e) => setAnaesRemarks(e.target.value)} disabled={isReadOnly} placeholder="Sedation details / special remarks..." />
            {!intraop?.anaesthesia_recorded_at && !isCompleted && (
              <button className="btn btn-sm" style={{ background: 'var(--blue)', color: '#fff', border: 'none', marginTop: 8 }} onClick={handleRecordAnaesthesia}><i className="ti ti-check"></i> Record anaesthesia</button>
            )}
            {intraop?.anaesthesia_recorded_at && <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 6 }}><i className="ti ti-check"></i> Recorded</div>}
          </div>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={onBack}><i className="ti ti-arrow-left"></i> Back to Dashboard</button>
            {intraop?.checkin_completed_at || isCompleted ? (
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Checked In</span>
            ) : (
              <button className="btn btn-primary" onClick={handleCompleteCheckin} disabled={!manualCheckinDone || !requiredConsentsOk}>
                <i className="ti ti-check"></i> Check In
              </button>
            )}
          </div>
          </>
          )}

          {subTab === 'intraop' && (
          <>
          {/* Consumables */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-box" style={{ color: 'var(--amber)' }}></i> Consumables</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {consumableOptions.map((c) => <span key={c.id} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isReadOnly && handleAddConsumable(c.name)}>{c.name}</span>)}
            </div>
            {!isReadOnly && (
              <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} value={consumableName} onChange={(e) => setConsumableName(e.target.value)} placeholder="Consumable name..." />
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => handleAddConsumable()}><i className="ti ti-plus"></i> Add</button>
              </div>
            )}
            {consumables.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '5px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-box" style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{c.name}</span>
                {!isReadOnly && <button onClick={() => removeConsumable(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Events */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Intraoperative Events</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {EVENT_QUICK.map((e) => <span key={e} className="badge b-amber" style={{ cursor: 'pointer' }} onClick={() => setEventName(e)}>{e}</span>)}
            </div>
            {!isReadOnly && (
              <div style={{ display: 'grid', gridTemplateColumns: '1fr auto auto', gap: 8, marginBottom: 8 }}>
                <input className="fi fi-sm" value={eventName} onChange={(e) => setEventName(e.target.value)} placeholder="Event description..." />
                <select className="fi fi-sm" value={eventSeverity} onChange={(e) => setEventSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddEvent}><i className="ti ti-plus"></i></button>
              </div>
            )}
            {events.map((e) => (
              <div key={e.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginBottom: 6, fontSize: 12, border: '1px solid var(--g200)', background: e.severity === 'Severe' ? 'var(--red-lt)' : e.severity === 'Moderate' ? 'var(--amber-lt)' : 'var(--g50)' }}>
                <div style={{ flex: 1 }}><strong>{e.name}</strong> <span className={`badge ${e.severity === 'Severe' ? 'b-red' : e.severity === 'Moderate' ? 'b-amber' : 'b-gray'}`} style={{ fontSize: 10 }}>{e.severity}</span></div>
                {!isReadOnly && <button onClick={() => removeIntraopEvent(e.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Complications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Complications</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {COMPL_QUICK.map((c) => <span key={c} className="badge b-red" style={{ cursor: 'pointer' }} onClick={() => setComplName(c)}>{c}</span>)}
            </div>
            {!isReadOnly && (
              <>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication..." />
                  <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                  <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management (required)" />
                  <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome (if known)" />
                </div>
                <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
              </>
            )}
            {complications.map((c) => (
              <div key={c.id} style={{ display: 'flex', alignItems: 'flex-start', gap: 8, padding: '8px 10px', borderRadius: 8, marginTop: 8, fontSize: 12, border: '1px solid var(--g200)', background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)' }}>
                <div style={{ flex: 1 }}>
                  <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
                  <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>Management: {c.management}</div>
                  {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
                </div>
                {!isReadOnly && <button onClick={() => removeIntraopEvent(c.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
          </div>

          {/* Notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Operative Notes</div>
            <textarea className="fi fi-sm" rows={3} value={opNotes} onChange={(e) => setOpNotes(e.target.value)} disabled={isReadOnly} placeholder="Free-text operative narrative..." />
          </div>

          {/* Outcome */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--green)' }}></i> Surgical Outcome</div>
            <select className="fi fi-sm" value={surgicalOutcome} onChange={(e) => setSurgicalOutcome(e.target.value)} disabled={isReadOnly} style={{ marginBottom: 8 }}>
              <option>Successful</option><option>Successful with Complication</option><option>Converted Procedure</option><option>Procedure Deferred</option><option>Procedure Abandoned</option>
            </select>
            <input className="fi fi-sm" value={outcomeRemarks} onChange={(e) => setOutcomeRemarks(e.target.value)} disabled={isReadOnly} placeholder="Additional remarks..." />
          </div>

          {/* Recovery */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Recovery Handover</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery destination</label><select className="fi fi-sm" value={recoveryDest} onChange={(e) => setRecoveryDest(e.target.value)} disabled={isReadOnly}><option>Recovery Bay 1</option><option>Recovery Bay 2</option><option>Day Care Ward</option></select></div>
              <div><label className="flbl">Required monitoring</label><input className="fi fi-sm" value={recoveryMonitor} onChange={(e) => setRecoveryMonitor(e.target.value)} disabled={isReadOnly} placeholder="e.g. Vitals q15min x1hr" /></div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Post-operative instructions</label>
              <textarea className="fi fi-sm" rows={2} value={recoveryInstructions} onChange={(e) => setRecoveryInstructions(e.target.value)} disabled={isReadOnly} placeholder="e.g. Eye shield overnight. Moxifloxacin QID..." />
            </div>
            <input className="fi fi-sm" value={recoveryConcerns} onChange={(e) => setRecoveryConcerns(e.target.value)} disabled={isReadOnly} placeholder="Immediate concerns (if any)..." />
          </div>

          {!isCompleted && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={handleSaveDraft} disabled={saving}>
                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Draft'}
              </button>
              <button className="btn btn-primary" onClick={handleCompleteSurgery}>
                <i className="ti ti-circle-check"></i> Surgery Complete
              </button>
            </div>
          )}
          {isCompleted && !unlocked && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <span className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default' }}><i className="ti ti-circle-check"></i> Surgery Completed</span>
            </div>
          )}
          {isCompleted && unlocked && (
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={() => { setUnlocked(false); refresh(); }}>
                <i className="ti ti-x"></i> Discard & Lock
              </button>
              <button className="btn btn-primary" style={{ background: 'var(--amber)', borderColor: 'var(--amber)' }} onClick={handleCompleteSurgery}>
                <i className="ti ti-device-floppy"></i> Save Changes
              </button>
            </div>
          )}
          </>
          )}
          </>
          )}
        </div>

        {/* RIGHT: status panel */}
        <div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>OT Case Status</div>
            <div style={{ padding: 10, background: 'var(--blue-lt)', borderRadius: 8, textAlign: 'center' }}>
              <div style={{ fontSize: 11, color: 'var(--blue)', fontWeight: 700 }}>{STEPS[currentStep]}</div>
              <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>Step {currentStep + 1} of {STEPS.length}</div>
            </div>
          </div>
          <div className="card">
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Quick Stats</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Events</span><strong>{events.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Complications</span><strong style={{ color: complications.length ? 'var(--red)' : 'inherit' }}>{complications.length}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Consumables</span><strong>{consumables.length}</strong></div>
          </div>
          <div className="card" style={{ marginBottom: 0 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 8 }}>Completion Checklist</div>
            {[
              { label: 'Implant information complete', done: biometryPlans.length === 0 || !!(imPower && imSerial) },
              { label: 'Recovery handover documented', done: !!recoveryInstructions },
            ].map((it) => (
              <div key={it.label} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className={`ti ${it.done ? 'ti-circle-check' : 'ti-circle'}`} style={{ color: it.done ? 'var(--green)' : 'var(--g300)' }}></i> {it.label}
              </div>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

VEDA_EOF_4

mkdir -p "app/(main)/surgical-journey"
cat > "app/(main)/surgical-journey/actions.js" << 'VEDA_EOF_5'
'use server';

import { createClient } from '@/lib/supabase-server';
import { adviseBiometry } from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/counselling/actions';
import { getAdvanceBalance } from '@/app/(main)/payments/actions';

// This module deliberately does NOT reimplement package selection,
// biometry skip/unskip, decision recording, ready-for-scheduling, or OT
// booking -- the page imports those directly from Counselling and OT
// Schedule (same pattern Consultation already uses to call into
// Counselling), since that logic is already built, tested, and
// correct. What THIS file adds is a single page that walks through all
// of it for one patient without switching modules, plus a few
// genuinely new pieces (proceed status, IOL order notes, manual
// reminder tracking) that didn't exist anywhere before.

// ── EDIT PROCEDURE / EYE (any stage) ───────────────────────────────
// counselling's updateSurgicalCase only allows this while status is
// still 'Pending Workup' and refuses otherwise with no real
// alternative -- there was no actual place "further changes should go
// through Counselling" could happen. This lets a genuine correction
// (wrong eye picked, procedure name needs fixing) happen at ANY stage,
// same principle as changePackage/setDecision: once the case has
// progressed, a reason is required and logged, rather than the edit
// being refused outright.
export async function editSurgicalCaseDetails(caseId, procedureName, eye, reason) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status, procedure_name, eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const progressed = sc.status !== 'Pending Workup';
  if (progressed && (!reason || !reason.trim())) {
    return { error: `A reason is required to change the procedure/eye once the case has moved to "${sc.status}".` };
  }

  const { error } = await supabase.from('surgical_cases').update({ procedure_name: procedureName, eye }).eq('id', caseId);
  if (error) return { error: error.message };

  if (progressed) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Procedure/eye corrected -- was "${sc.procedure_name}" (${sc.eye}), now "${procedureName}" (${eye}). Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  return { success: true };
}

// ── IN-HOUSE INVESTIGATIONS (Step 2) ───────────────────────────────
// Flexible and optional -- add whatever this case actually needs, not
// a fixed required panel. Fully generic -- Biometry is just one more
// option in the same list, not a separate hardcoded section, per your
// instruction. Routes through the same investigation_orders table and
// Investigation module queue Doctor Consultation uses. "Further
// investigations for a surgical case go through the surgery module" --
// this is that entry point, not a trip back to Consultation.
export async function getInvestigationOptionsForCase() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

export async function addInHouseInvestigationForCase(caseId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Select an investigation.' };

  const { data: sc } = await supabase.from('surgical_cases').select('encounter_id, patient_id, visit_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!sc.encounter_id) return { error: 'This case has no linked consultation encounter to attach investigations to.' };

  const resolvedEye = eye || 'OU';

  // Don't let the same investigation get ordered twice for this case
  // while an earlier order is still open (Ordered/In Progress).
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', sc.encounter_id)
    .eq('eye', resolvedEye)
    .ilike('name', name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${name.trim()}" (${resolvedEye}) is already ordered and still pending for this case.` };
  }

  // Biometry is patient-level and fulfilled through its own dedicated
  // module -- same special-case Doctor Consultation's addInvestigation
  // already does. A normal investigation_orders row is still created so
  // it shows up in this same list with a status badge, but the actual
  // biometry_records row (device readings, IOL recommendations) is what
  // makes it real -- ensured here, same as everywhere else biometry
  // gets ordered from.
  if (name.trim().toLowerCase() === 'biometry') {
    const result = await adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, null);
    if (result.error) return result;
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: sc.encounter_id, name: name.trim(), eye: resolvedEye, priority: 'Routine',
  });
  if (error) return { error: error.message };

  await supabase.from('encounter_audit_log').insert({
    encounter_id: sc.encounter_id,
    message: `Investigation ordered from Surgical Journey: ${name.trim()} (${resolvedEye})`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}

export async function removeInHouseInvestigationForCase(investigationId) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', investigationId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EXTERNAL INVESTIGATIONS ─────────────────────────────────────────
// Named tests done elsewhere (blood work, HIV test -- not done
// in-house). Each is added by name; the report, once it comes back, is
// a normal clinical_attachments upload keyed to that specific test, not
// a generic unlabeled bucket. Also printable as a referral slip to
// hand the patient.
export async function getExternalTestsForCase(caseId) {
  const supabase = await createClient();
  const { data: tests, error } = await supabase
    .from('external_investigations')
    .select('*')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });
  if (error) return [];

  const testIds = (tests || []).map((t) => t.id);
  let attachmentCountByTest = {};
  if (testIds.length > 0) {
    const { data: attachments } = await supabase
      .from('clinical_attachments')
      .select('entity_id')
      .eq('entity_type', 'external_investigation')
      .in('entity_id', testIds);
    (attachments || []).forEach((a) => { attachmentCountByTest[a.entity_id] = (attachmentCountByTest[a.entity_id] || 0) + 1; });
  }

  return (tests || []).map((t) => ({ ...t, attachmentCount: attachmentCountByTest[t.id] || 0 }));
}

export async function addExternalTest(caseId, name) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Enter a test name.' };
  const { error } = await supabase.from('external_investigations').insert({
    surgical_case_id: caseId, test_name: name.trim(), created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeExternalTest(testId) {
  const supabase = await createClient();
  const { error } = await supabase.from('external_investigations').delete().eq('id', testId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FURTHER INSTRUCTIONS (Treatment) ───────────────────────────────
// Free text tied to the treatment itself (procedure + eye), distinct
// from the pre-op panel notes in the Investigations step.
export async function setTreatmentInstructions(caseId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ treatment_instructions: instructions || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DASHBOARD ────────────────────────────────────────────────────────

// Every open surgical case (any staff member -- a small setup doesn't
// have per-doctor case ownership walls). "Open" = not yet Completed or
// Cancelled.
export async function getMyActiveSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: false });
  if (error) return [];
  return data || [];
}

// Patients whose decision is "Wants Time to Decide" and haven't
// resolved it yet (accepted or declined). Front desk's follow-up list.
// Ordered oldest-first so the ones most overdue for a call surface at
// the top.
export async function getAwaitingReturnCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile)')
    .eq('decision', 'Wants Time to Decide')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── CASE DETAIL ─────────────────────────────────────────────────────

export async function getSurgicalCaseDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select(`
      *,
      patients:patient_id(id, first_name, last_name, uhid, mobile, age, gender),
      master_packages:package_id(id, name, price, iol_category),
      profiles:surgeon_id(full_name)
    `)
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  // Biometry is patient-level now, not case-scoped -- reused across
  // every future surgical case for that patient (readings don't
  // meaningfully change for years). No more per-eye/per-case matching
  // needed; just look up whatever's on file for this patient.
  const { data: biometryRecords } = await supabase
    .from('biometry_records')
    .select('id, status, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false });

  // In-house investigations -- ordered against this case's own
  // consultation encounter, same investigation_orders table Doctor
  // Consultation uses and the same Investigation module queue picks
  // them up from. Fully generic -- Biometry shows up here too now,
  // same as anything else (whatever the doctor feels like), not a
  // separate hardcoded section.
  let inHouseInvestigations = [];
  if (sc.encounter_id) {
    const { data } = await supabase
      .from('investigation_orders')
      .select('*')
      .eq('encounter_id', sc.encounter_id)
      .order('created_at', { ascending: false });
    inHouseInvestigations = data || [];
  }

  // Day-of-surgery live status -- OT Schedule / Intraop / Recovery
  // already have solid, tested clinical workflows; this page doesn't
  // rebuild them, it just shows where the case currently stands and
  // deep-links into whichever one applies.
  const { data: otSchedule } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, status, master_ot_sessions(name)')
    .eq('surgical_case_id', caseId)
    .order('scheduled_date', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recoveryEpisode = null;
  let checkinCompletedAt = null;
  if (otSchedule) {
    const { data } = await supabase
      .from('recovery_episodes')
      .select('id, discharge_date')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    recoveryEpisode = data;

    const { data: intraopRecord } = await supabase
      .from('ot_intraop_records')
      .select('checkin_completed_at')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    checkinCompletedAt = intraopRecord?.checkin_completed_at || null;
  }

  // Medical fitness stays a real doctor referral/review, same as
  // Counselling -- this isn't a rubber-stamp checkbox, so it keeps its
  // own dedicated review step rather than being folded into a form
  // field here.
  const { data: fitnessReferral } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status, referred_at, fitness_notes')
    .eq('surgical_case_id', caseId)
    .order('referred_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: caseNotes } = await supabase
    .from('surgical_case_notes')
    .select('*, profiles:created_by(full_name)')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });

  // The surgeon's final IOL choice -- separate module/step from both
  // Biometry (raw device recommendations) and this page's own package
  // selection (billing category only).
  const { data: iolApproval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  const externalTests = await getExternalTestsForCase(caseId);

  // Payment step (M11's held advance balance, live) -- checked against
  // the net package amount (price - discount) rather than the old
  // never-actually-set advance_payment_id flag. See workspace.js.
  const advanceBalance = sc.patient_id ? await getAdvanceBalance(sc.patient_id) : 0;

  return {
    case: { ...sc, biometry_done: biometryRecords.some((b) => b.status === 'Measured') },
    biometryRecords,
    inHouseInvestigations,
    externalTests,
    fitnessReferral: fitnessReferral || null,
    iolApproval: iolApproval || null,
    otSchedule: otSchedule || null,
    checkinCompletedAt,
    recoveryEpisode,
    caseNotes: caseNotes || [],
    advanceBalance: Number(advanceBalance) || 0,
  };
}

// ── ADVISE SURGERY (Step 1-2) ──────────────────────────────────────
// Thin wrapper so the new page's "Advise Surgery" button doesn't need
// to import from Consultation directly -- same underlying function,
// same surgical_cases row Counselling already reads.
export async function adviseSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  return markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes);
}

// ── INVESTIGATIONS (Step 3) ────────────────────────────────────────
// Biometry is real, in-house, tracked work, always covers both eyes,
// and is reused across every future surgical case for the patient
// (readings don't meaningfully change for years). Goes through the
// same mechanism a doctor uses during a normal consultation, landing
// in the actual Biometry Queue. The pre-op panel (blood work etc.) is
// done entirely by a third party -- there's nothing to "order" in this
// system, so it's just a free-text note here; the report itself comes
// in later as an attachment (see AttachmentUploader on the page).
export async function orderBiometryForCase(caseId, instructions) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('patient_id, visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  return adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, instructions);
}

export async function setPreOpPanelNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEED STATUS (Step 4) ────────────────────────────────────────
export async function setProceedStatus(caseId, status) {
  const supabase = await createClient();
  if (!['Deciding', 'Awaiting Return', 'Proceeding'].includes(status)) return { error: 'Invalid status.' };
  const { error } = await supabase.from('surgical_cases').update({ proceed_status: status }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── IOL PROCUREMENT + INFORMAL DATE (Step 6-7) ─────────────────────
// Free text by design -- "Ordered Alcon monofocal +21D from XYZ
// Optics, expected Friday". No structured supplier/PO tracking yet.
export async function setIolOrderNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ iol_order_notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── AWAITING-RETURN REMINDERS (manual for now -- WhatsApp template not
// yet approved, see conversation) -- just tracks that someone called,
// for the front-desk follow-up list. Also drops a case note so there's
// a record of what was said, reusing the same notes trail as everything
// else on the case. ──
export async function recordManualReminder(caseId, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('reminder_count').eq('id', caseId).single();
  const { error } = await supabase.from('surgical_cases').update({
    last_reminder_sent_at: new Date().toISOString(),
    reminder_count: (sc?.reminder_count || 0) + 1,
  }).eq('id', caseId);
  if (error) return { error: error.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: `Follow-up call -- ${note || 'no details recorded'}`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}
VEDA_EOF_5

mkdir -p "app/(main)/biometry"
cat > "app/(main)/biometry/actions.js" << 'VEDA_EOF_6'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──────────────────────────────────────────────────────────
// Biometry is patient-level now, not visit/case-level -- a session is
// reused across every future surgical case for that patient. The queue
// just lists records not yet Measured, regardless of which visit
// originally ordered them.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measuredToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.patients)
    .map((r) => ({
      recordId: r.id,
      patientId: r.patient_id,
      patient: r.patients,
      status: r.status,
      doctorInstructions: r.doctor_instructions,
    }));

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const { data: measuredToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC);

  const stats = {
    awaiting: rows.length,
    measuredToday: (measuredToday || []).length,
  };

  return { rows, stats };
}

// ── COMPLETED TODAY -- Measured records from today, so a session
// doesn't disappear from the Queue the instant it's done. Moves to
// History once the day rolls over -- same Dashboard/History split used
// elsewhere. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC)
    .lte('updated_at', endUTC)
    .order('updated_at', { ascending: false });
  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ recordId: r.id, patientId: r.patient_id, patient: r.patients, status: r.status }));
}

// Finds an existing biometry record for this PATIENT -- reused across
// every future surgical case (readings don't meaningfully change for
// years), so this is a lookup-or-create against patient_id, not
// visit_id like most other "ensure a record" functions in this app.
export async function getOrCreateBiometryRecord(patientId, visitId, encounterId) {
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid, age, gender)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  const { data: recommendations } = await supabase
    .from('biometry_iol_recommendations')
    .select('*, master_iol_catalog(brand, model, category)')
    .eq('biometry_record_id', id)
    .order('created_at', { ascending: true });

  // Once a record is Measured, opening it (e.g. via "View Report" from
  // Surgical Journey) should default to a locked, read-only view --
  // only a Doctor can unlock it to make a correction. Before Measured,
  // the normal technician data-entry flow is unaffected.
  const { data: userData } = await supabase.auth.getUser();
  let isDoctor = false;
  if (userData?.user) {
    const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
    isDoctor = me?.designation === 'Doctor';
  }

  return { record: data, recommendations: recommendations || [], isDoctor };
}

// Persists measurement readings without changing status -- technician
// can leave and resume later. Once the record is Measured, this is
// locked to Doctors only (correcting a finalized reading), same
// boundary the workspace UI enforces.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const lockError = await assertBiometryEditable(supabase, id);
  if (lockError) return lockError;

  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

// Marks the session done -- requires at least one complete reading for
// EACH eye (biometry is always done for both eyes now) and at least
// one IOL recommendation row entered, plus the device report attached
// (checked by the caller via AttachmentUploader's own listing, not
// re-verified here -- consistent with how other modules treat
// attachments as informational rather than a hard DB gate).
export async function markBiometryMeasured(id, measurements, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const reHasComplete = (measurements.re || []).some(isComplete);
  const leHasComplete = (measurements.le || []).some(isComplete);
  if (!reHasComplete || !leHasComplete) {
    return { error: 'At least one complete reading (AXL, K1, K2, ACD) is required for BOTH eyes.' };
  }

  const { count } = await supabase
    .from('biometry_iol_recommendations')
    .select('id', { count: 'exact', head: true })
    .eq('biometry_record_id', id);
  if (!count) return { error: 'Add at least one IOL recommendation from the device printout before marking as measured.' };

  const devicesUsed = [...new Set([...(measurements.re || []), ...(measurements.le || [])].map((s) => s.device).filter(Boolean))];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Measured',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks || null,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id, patient_id')
    .single();

  if (error) return { error: error.message };
  if (data?.visit_id) await logJourneyEvent(supabase, data.visit_id, 'biometry_completed');

  // Biometry is ordered through the regular OPD Investigations panel
  // now (selectable like any other investigation), which creates a
  // normal investigation_orders row alongside this specialized
  // fulfillment. Keep that row in sync so it doesn't sit showing
  // "Ordered" forever in the doctor's list once the actual work is
  // done -- match across ALL of this patient's encounters, since
  // biometry is patient-level and the order could have come from any
  // visit.
  if (data?.patient_id) {
    const { data: visits } = await supabase.from('visits').select('id').eq('patient_id', data.patient_id);
    const visitIds = (visits || []).map((v) => v.id);
    if (visitIds.length > 0) {
      const { data: encounters } = await supabase.from('encounters').select('id').in('visit_id', visitIds);
      const encounterIds = (encounters || []).map((e) => e.id);
      if (encounterIds.length > 0) {
        await supabase
          .from('investigation_orders')
          .update({ status: 'Available', verified_at: new Date().toISOString() })
          .in('encounter_id', encounterIds)
          .ilike('name', 'biometry')
          .eq('status', 'Ordered');
      }
    }
  }

  return { success: true };
}

// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
// The device's own printed table -- for each brand/model it evaluated,
// what power it recommends per eye. This app records what the printout
// says; it does not calculate anything itself.
// Shared lock check: once a biometry record is Measured, only a
// Doctor can modify it (readings or recommendations) -- everyone else
// gets a read-only view. Returns null if the edit is allowed, or an
// {error} object to return straight from the calling action.
async function assertBiometryEditable(supabase, biometryRecordId) {
  const { data: existing } = await supabase.from('biometry_records').select('status').eq('id', biometryRecordId).maybeSingle();
  if (existing?.status !== 'Measured') return null;
  const { data: userData } = await supabase.auth.getUser();
  const { data: me } = userData?.user
    ? await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle()
    : { data: null };
  if (me?.designation !== 'Doctor') {
    return { error: 'This biometry record is already Measured and locked. Only a Doctor can edit it.' };
  }
  return null;
}

export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
  const supabase = await createClient();
  const lockError = await assertBiometryEditable(supabase, biometryRecordId);
  if (lockError) return lockError;
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
  const { error } = await supabase.from('biometry_iol_recommendations').insert({
    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    re_power: rePower || null, le_power: lePower || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIolRecommendation(id) {
  const supabase = await createClient();
  const { data: rec } = await supabase.from('biometry_iol_recommendations').select('biometry_record_id').eq('id', id).maybeSingle();
  if (rec?.biometry_record_id) {
    const lockError = await assertBiometryEditable(supabase, rec.biometry_record_id);
    if (lockError) return lockError;
  }
  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── HISTORY -- cross-patient, Measured or Cancelled. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ patientId: r.patient_id, patient: r.patients, items: [r] }));
}

async function setBiometryBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markBiometryDenied(id, note) {
  return setBiometryBillingStatus(id, 'Denied', note);
}

export async function markBiometryDeferred(id, note) {
  return setBiometryBillingStatus(id, 'Deferred', note);
}

export async function resetBiometryBilling(id) {
  return setBiometryBillingStatus(id, 'Pending', null);
}
VEDA_EOF_6

mkdir -p "app/(main)/biometry/[id]"
cat > "app/(main)/biometry/[id]/workspace.js" << 'VEDA_EOF_7'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
  addIolRecommendation, removeIolRecommendation,
} from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];
const DEVICES = ['ZEISS IOLMaster 700', 'Haag-Streit Lenstar', 'NIDEK AL-Scan', 'Manual A-Scan'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

function emptySet(device) {
  return { device, axl: '', k1: '', k2: '', acd: '', lt: '', wtw: '' };
}
function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, disabled, headColor, headBg }) {
  const [newDevice, setNewDevice] = useState(DEVICES[0]);
  return (
    <div>
      <div style={{ padding: '8px 12px', fontSize: 12, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, background: headBg, color: headColor, borderRadius: '8px 8px 0 0' }}>
        <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {label}
      </div>
      <div style={{ border: '1px solid var(--g200)', borderTop: 'none', borderRadius: '0 0 8px 8px', padding: '10px 12px' }}>
        {sets.length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)', padding: '4px 0' }}>No readings yet.</div>}
        {sets.map((set, idx) => (
          <div key={idx} style={{ marginBottom: 10, paddingBottom: 10, borderBottom: idx < sets.length - 1 || !disabled ? '1px dashed var(--g200)' : 'none' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
              <span className={`badge ${isComplete(set) ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>
                <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
              </span>
              {!disabled && <button className="btn" style={{ padding: '1px 7px', fontSize: 10 }} onClick={() => onRemoveSet(eyeKey, idx)}>Remove</button>}
            </div>
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <input
                    type="text" value={set[f.key] || ''} onChange={(e) => onFieldChange(eyeKey, idx, f.key, e.target.value)}
                    disabled={disabled} placeholder="--"
                    style={{ width: 90, padding: '4px 7px', border: '1.5px solid var(--g200)', borderRadius: 8, fontSize: 12, textAlign: 'right' }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--g400)' }}>{f.unit}</span>
                </div>
              </div>
            ))}
          </div>
        ))}
        {!disabled && (
          <div style={{ display: 'flex', gap: 6 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={newDevice} onChange={(e) => setNewDevice(e.target.value)}>
              {DEVICES.map((d) => <option key={d}>{d}</option>)}
            </select>
            <button className="btn btn-sm" onClick={() => onAddSet(eyeKey, newDevice)}><i className="ti ti-plus"></i> Add reading</button>
          </div>
        )}
      </div>
    </div>
  );
}

function RecommendationsSection({ recordId, recommendations, catalog, disabled, onSaved }) {
  const [catalogId, setCatalogId] = useState('');
  const [rePower, setRePower] = useState('');
  const [lePower, setLePower] = useState('');
  const [error, setError] = useState('');

  async function handleAdd() {
    setError('');
    const result = await addIolRecommendation(recordId, catalogId, rePower, lePower);
    if (result.error) { setError(result.error); return; }
    setCatalogId(''); setRePower(''); setLePower('');
    onSaved();
  }

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> IOL Recommendations (from device printout)</div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
        For each IOL brand/model the device evaluated, enter the power it recommends per eye -- transcribed straight from the printout, not calculated here.
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}

      {recommendations.length > 0 && (
        <table className="tbl" style={{ marginBottom: 10 }}>
          <thead><tr><th>Brand / Model</th><th>RE Power</th><th>LE Power</th><th></th></tr></thead>
          <tbody>
            {recommendations.map((r) => (
              <tr key={r.id}>
                <td>{r.master_iol_catalog?.brand} {r.master_iol_catalog?.model}</td>
                <td>{r.re_power ?? '--'}</td>
                <td>{r.le_power ?? '--'}</td>
                <td>
                  {!disabled && (
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeIolRecommendation(r.id); onSaved(); }}>
                      <i className="ti ti-trash"></i>
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {!disabled && (
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 8 }}>
          <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
            <option value="">Select brand/model...</option>
            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
          </select>
          <input className="fi fi-sm" placeholder="RE power" value={rePower} onChange={(e) => setRePower(e.target.value)} />
          <input className="fi fi-sm" placeholder="LE power" value={lePower} onChange={(e) => setLePower(e.target.value)} />
          <button className="btn btn-sm btn-primary" onClick={handleAdd}><i className="ti ti-plus"></i></button>
        </div>
      )}
    </div>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [recommendations, setRecommendations] = useState([]);
  const [catalog, setCatalog] = useState([]);
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [remarks, setRemarks] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [isDoctor, setIsDoctor] = useState(false);
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  async function refresh() {
    const result = await getBiometryDetail(recordId);
    if (result.error) { setLoadError(result.error); return; }
    setRecord(result.record);
    setRecommendations(result.recommendations);
    setIsDoctor(!!result.isDoctor);
    const m = result.record.measurements || {};
    setMeasurements({
      re: Array.isArray(m.re) ? m.re : (m.re && Object.keys(m.re).length ? [{ ...m.re, device: result.record.verify_device || 'Unspecified' }] : []),
      le: Array.isArray(m.le) ? m.le : (m.le && Object.keys(m.le).length ? [{ ...m.le, device: result.record.verify_device || 'Unspecified' }] : []),
    });
    setRemarks(result.record.verify_remarks || '');
  }

  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.patients;
  const isMeasured = record.status === 'Measured';
  // Once Measured, this is a finalized report -- locked by default for
  // everyone. A Doctor can unlock it to make a correction; anyone else
  // only ever sees it read-only, no matter how they arrived here.
  const canEdit = !isMeasured || (isDoctor && unlocked);

  function setFieldInSet(eyeKey, idx, fieldKey, value) {
    setMeasurements((prev) => {
      const list = [...(prev[eyeKey] || [])];
      list[idx] = { ...list[idx], [fieldKey]: value };
      return { ...prev, [eyeKey]: list };
    });
  }
  function addSet(eyeKey, device) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: [...(prev[eyeKey] || []), emptySet(device)] }));
  }
  function removeSet(eyeKey, idx) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: (prev[eyeKey] || []).filter((_, i) => i !== idx) }));
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveBiometryDraft(recordId, measurements);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved.');
  }

  async function handleMarkMeasured() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await markBiometryMeasured(recordId, measurements, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Marked as measured.');
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#3730a3)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Biometry (both eyes)</div>
        </div>
        <span className="badge" style={{ background: isMeasured ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.15)', color: '#fff', fontSize: 11 }}>{record.status}</span>
      </div>

      {record.doctor_instructions && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12 }}>
          <i className="ti ti-notes"></i> <strong>Doctor's instructions:</strong> {record.doctor_instructions}
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      {isMeasured && !unlocked && (
        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-lock"></i>
          <span style={{ flex: 1 }}>This report is finalized and locked for viewing.</span>
          {isDoctor && (
            <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
              <i className="ti ti-lock-open"></i> Edit (Doctor)
            </button>
          )}
        </div>
      )}
      {isMeasured && unlocked && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-edit"></i>
          <span style={{ flex: 1 }}>Editing a finalized report. Changes are saved immediately.</span>
          <button className="btn btn-sm" onClick={() => setUnlocked(false)}>
            <i className="ti ti-lock"></i> Lock again
          </button>
        </div>
      )}

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isMeasured ? 'b-green' : 'b-gray'}`}>{isMeasured ? 'Measured' : 'Not measured'}</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Biometry is always done for both eyes. Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken.
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
          <div style={{ borderRight: '1px solid var(--g200)' }}>
            <EyeSets label="Right Eye (OD)" eyeKey="re" sets={measurements.re || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--blue)" headBg="var(--blue-lt)" />
          </div>
          <div>
            <EyeSets label="Left Eye (OS)" eyeKey="le" sets={measurements.le || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--teal)" headBg="var(--teal-lt)" />
          </div>
        </div>
      </div>

      <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {!isMeasured && canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-check" style={{ color: 'var(--green)' }}></i> Mark as Measured</div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleMarkMeasured} disabled={saving}>
              <i className="ti ti-check"></i> Mark as Measured
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
          </div>
        </div>
      )}

      {isMeasured && canEdit && (
        <div className="card">
          <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleSaveDraft} disabled={saving}>
            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Correction'}
          </button>
        </div>
      )}

      {isMeasured && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measured{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Ready for Surgeon IOL Approval when a surgical case needs it.
          </div>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        <button className="btn" onClick={() => router.push('/biometry')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}
VEDA_EOF_7

mkdir -p "app/(main)/biometry/[id]"
cat > "app/(main)/biometry/[id]/approval-tab.js" << 'VEDA_EOF_8'
'use client';

import { useState, useEffect } from 'react';
import { approveIolPlan, getIolVersionHistory } from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
import { openPrintPopup } from '@/lib/printPopup';

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

export default function ApprovalTab({ record, recordId, surgeonName, onSaved }) {
  const [finalPower, setFinalPower] = useState('');
  const [finalFormula, setFinalFormula] = useState(FORMULA_NAMES[0]);
  const [finalCategory, setFinalCategory] = useState(IOL_CATEGORIES[0]);
  const [finalTarget, setFinalTarget] = useState('');
  const [iolCatalogId, setIolCatalogId] = useState('');
  const [surgeonNotes, setSurgeonNotes] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [versions, setVersions] = useState([]);
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [revising, setRevising] = useState(false);

  async function loadVersions() {
    const v = await getIolVersionHistory(recordId);
    setVersions(v);
  }

  useEffect(() => {
    getActiveIolCatalog().then(setCatalog);
    loadVersions();
  }, [recordId]);

  useEffect(() => {
    const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
    setFinalPower(record.final_iol_power || selected?.power || '');
    setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
    setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
    setFinalTarget(record.target_refraction || '');
    setIolCatalogId(record.final_iol_catalog_id || '');
    setSurgeonNotes(record.surgeon_notes || '');
  }, [record]);

  const notCalculated = record.status !== 'Calculated' && record.status !== 'Approved';
  const isApproved = record.status === 'Approved' && !revising;
  const catalogForCategory = catalog.filter((c) => c.category === finalCategory);

  async function handleApprove() {
    setError(''); setOkMsg('');
    if (!finalPower.trim()) { setError('Final IOL power is required.'); return; }
    setSaving(true);
    const result = await approveIolPlan(recordId, {
      finalPower, finalFormula, finalCategory, finalTarget, iolCatalogId: iolCatalogId || null, surgeonNotes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(`IOL Plan approved (version ${result.versionNo}).`);
    setRevising(false);
    loadVersions();
    if (onSaved) onSaved();
  }

  if (notCalculated) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Save at least one formula result in IOL Calculation before approval is available.
      </div>
    );
  }

  const selectedCatalogItem = catalog.find((c) => c.id === record.final_iol_catalog_id);

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#166534,#157a4f)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <i className="ti ti-shield-check" style={{ fontSize: 26, flexShrink: 0 }}></i>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Final IOL Plan Approval</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{record.procedure_name || 'Procedure not set'} -- Dr. {surgeonName}</div>
        </div>
        <div style={{ marginLeft: 16, background: 'rgba(255,255,255,.15)', borderRadius: 8, padding: '6px 12px' }}>
          <div style={{ fontSize: 9, opacity: .8, textTransform: 'uppercase', letterSpacing: .4 }}>Eye to be Operated</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--'}</div>
        </div>
        <div style={{ marginLeft: 'auto', textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>Only surgeon/ophthalmologist should approve</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 2 }}>{isApproved ? 'Approved' : revising ? 'Revising' : 'Approval required'}</div>
        </div>
      </div>

      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 12 }}>
        <i className="ti ti-alert-triangle"></i> This isn't role-restricted at the database level yet -- please only approve if you're the operating surgeon or ophthalmologist for this case.
      </div>

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}
      {revising && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-edit"></i> Revising the approved plan. Approving again will add a new version -- the current approved version stays in history, marked Superseded.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calculator" style={{ color: 'var(--indigo)' }}></i> Calculation Review</div>
            {record.formula_results?.length > 0 ? (
              record.formula_results.map((r, i) => (
                <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12, fontWeight: r.name === record.selected_formula ? 700 : 400, color: r.name === record.selected_formula ? 'var(--green)' : 'var(--g700)' }}>
                  <span>{r.name}{r.name === record.selected_formula ? ' (selected)' : ''}</span>
                  <span style={{ fontFamily: 'monospace' }}>{r.power} D -- {r.refraction}</span>
                </div>
              ))
            ) : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No calculation saved yet.</div>
            )}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Final IOL Plan</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">Final IOL power (D) *</label>
                <input className="fi fi-sm" placeholder="+21.5" value={finalPower} onChange={(e) => setFinalPower(e.target.value)} disabled={isApproved} />
              </div>
              <div>
                <label className="flbl">Formula used</label>
                <select className="fi fi-sm" value={finalFormula} onChange={(e) => setFinalFormula(e.target.value)} disabled={isApproved}>
                  {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                </select>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">IOL category *</label>
                <select className="fi fi-sm" value={finalCategory} onChange={(e) => { setFinalCategory(e.target.value); setIolCatalogId(''); }} disabled={isApproved}>
                  {IOL_CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Target refraction</label>
                <input className="fi fi-sm" value={finalTarget} onChange={(e) => setFinalTarget(e.target.value)} disabled={isApproved} />
              </div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Specific IOL (Master Data -- IOL Catalog)</label>
              <select className="fi fi-sm" value={iolCatalogId} onChange={(e) => setIolCatalogId(e.target.value)} disabled={isApproved}>
                <option value="">-- Not specified --</option>
                {catalogForCategory.map((c) => <option key={c.id} value={c.id}>{c.brand} -- {c.model}</option>)}
              </select>
              {catalogForCategory.length === 0 && (
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 3 }}>No catalog items for {finalCategory} yet -- add them in Master Data -&gt; Clinical -&gt; IOL Catalog.</div>
              )}
            </div>
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Surgeon notes</label>
              <textarea className="fi fi-sm" rows={2} value={surgeonNotes} onChange={(e) => setSurgeonNotes(e.target.value)} disabled={isApproved} placeholder="e.g. Aim for slight myopia. Avoid multifocal due to macular finding. Toric axis to be confirmed intra-op..." />
            </div>

            {!isApproved && (
              <button className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleApprove} disabled={saving}>
                <i className="ti ti-shield-check"></i> {saving ? 'Approving...' : revising ? 'Approve Revised Plan' : 'Approve Final IOL Plan'}
              </button>
            )}
            {revising && (
              <button
                className="btn btn-sm"
                style={{ marginLeft: 8 }}
                onClick={() => {
                  setRevising(false);
                  const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
                  setFinalPower(record.final_iol_power || selected?.power || '');
                  setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
                  setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
                  setFinalTarget(record.target_refraction || '');
                  setIolCatalogId(record.final_iol_catalog_id || '');
                  setSurgeonNotes(record.surgeon_notes || '');
                  setError(''); setOkMsg('');
                }}
              >
                Cancel revision
              </button>
            )}
            {record.status === 'Approved' && !revising && (
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                Approved{record.approved_at ? ` on ${new Date(record.approved_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. To change the plan (e.g. patient requests a different IOL), click Revise -- this creates a new version without deleting the old one.
              </div>
            )}
            {record.status === 'Approved' && !revising && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => setRevising(true)}>
                <i className="ti ti-edit"></i> Revise plan (creates new version)
              </button>
            )}
          </div>
        </div>

        <div>
          {record.status === 'Approved' && (
            <div className="card" style={{ marginBottom: 12, background: 'var(--green-lt)', borderColor: '#86efac' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--green)' }}>
                  <i className="ti ti-clipboard-check"></i> IOL Planning Summary
                </div>
                <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={() => openPrintPopup(`/biometry-print/${recordId}`)}>
                  <i className="ti ti-printer"></i> Print Biometry Report
                </button>
              </div>
              <div style={{ fontSize: 12, color: 'var(--g700)', lineHeight: 1.8 }}>
                <div><strong>Power:</strong> {record.final_iol_power} D</div>
                <div><strong>Category:</strong> {record.final_iol_category}</div>
                {selectedCatalogItem && <div><strong>Lens:</strong> {selectedCatalogItem.brand} -- {selectedCatalogItem.model}</div>}
                <div><strong>Target:</strong> {record.target_refraction}</div>
              </div>
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Version History</div>
            {versions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No approved versions yet.</div>}
            {versions.map((v) => (
              <div key={v.id} style={{ padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <span style={{ fontWeight: 700 }}>v{v.version_no} -- {v.power} D ({v.formula})</span>
                  <span className={`badge ${v.status === 'Approved' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 9 }}>{v.status}</span>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>
                  {v.profiles?.full_name || 'Staff'} -- {new Date(v.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </div>
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Approval supersedes the previous plan but never deletes historical versions.</div>
          </div>
        </div>
      </div>
    </div>
  );
}

VEDA_EOF_8

mkdir -p "app/(main)/iol-approval"
cat > "app/(main)/iol-approval/actions.js" << 'VEDA_EOF_9'
'use server';

import { createClient } from '@/lib/supabase-server';

// The surgeon's sign-off on the specific IOL brand/model/power to
// actually use for a surgical case -- separate from Biometry (which
// just records the device's raw recommendations) and Counselling
// (which picks the billing package/category). Eye comes from
// surgical_cases.eye (set by the doctor); power comes from whichever
// brand row in biometry_iol_recommendations the surgeon picks.

// ── QUEUE: cases needing approval ──────────────────────────────────
// A case needs this once biometry is Measured for the patient and
// there's no Approved iol_approvals row yet for the case.
export async function getPendingIolApprovals() {
  const supabase = await createClient();

  const { data: cases, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name, iol_category)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .neq('biometry_required', false);
  if (error) return [];

  const patientIds = [...new Set((cases || []).map((c) => c.patient_id).filter(Boolean))];
  if (patientIds.length === 0) return [];

  const { data: measured } = await supabase
    .from('biometry_records')
    .select('id, patient_id')
    .in('patient_id', patientIds)
    .eq('status', 'Measured');
  const measuredByPatient = {};
  (measured || []).forEach((m) => { measuredByPatient[m.patient_id] = m.id; });

  const caseIds = (cases || []).map((c) => c.id);
  const { data: approvals } = await supabase
    .from('iol_approvals')
    .select('surgical_case_id, status')
    .in('surgical_case_id', caseIds);
  const approvalByCase = {};
  (approvals || []).forEach((a) => { approvalByCase[a.surgical_case_id] = a.status; });

  return (cases || [])
    .filter((c) => measuredByPatient[c.patient_id] && approvalByCase[c.id] !== 'Approved')
    .map((c) => ({
      caseId: c.id,
      patient: c.patients,
      procedureName: c.procedure_name,
      eye: c.eye,
      packageName: c.master_packages?.name || null,
      biometryRecordId: measuredByPatient[c.patient_id],
      approvalStatus: approvalByCase[c.id] || 'Pending',
    }));
}

export async function getApprovedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('iol_approvals')
    .select('*, surgical_cases(id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name)), master_iol_catalog(brand, model)')
    .eq('status', 'Approved')
    .gte('approved_at', startUTC)
    .lte('approved_at', endUTC)
    .order('approved_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((a) => a.surgical_cases);
}

// ── HISTORY: every approval ever made, newest first, with optional
// date range + patient search. Approved Today only ever showed the
// current day, so anything from yesterday or earlier had no way to be
// found again in this module. ──
export async function getIolApprovalHistory(fromDate, toDate, search) {
  const supabase = await createClient();

  let query = supabase
    .from('iol_approvals')
    .select('*, surgical_cases(id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name)), master_iol_catalog(brand, model)')
    .eq('status', 'Approved')
    .order('approved_at', { ascending: false })
    .limit(300);

  if (fromDate) query = query.gte('approved_at', new Date(`${fromDate}T00:00:00+05:30`).toISOString());
  if (toDate) query = query.lte('approved_at', new Date(`${toDate}T23:59:59.999+05:30`).toISOString());

  const { data, error } = await query;
  if (error) return [];
  let rows = (data || []).filter((a) => a.surgical_cases);

  if (search && search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter((a) => {
      const p = a.surgical_cases?.patients;
      return p && (
        `${p.first_name} ${p.last_name}`.toLowerCase().includes(q) ||
        (p.uhid || '').toLowerCase().includes(q)
      );
    });
  }

  return rows;
}

// ── DETAIL: a case's recommendation table + current approval ──────
export async function getIolApprovalDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid, age, gender), master_packages:package_id(name, iol_category)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: biometry } = await supabase
    .from('biometry_records')
    .select('id, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recommendations = [];
  if (biometry) {
    const { data } = await supabase
      .from('biometry_iol_recommendations')
      .select('*, master_iol_catalog(id, brand, model, category)')
      .eq('biometry_record_id', biometry.id)
      .order('created_at', { ascending: true });
    recommendations = data || [];
  }

  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  return { case: sc, biometry, recommendations, approval: approval || null };
}

// ── APPROVE ─────────────────────────────────────────────────────────
export async function approveIol(caseId, biometryRecordId, iolCatalogId, power, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  if (approverProfile?.designation !== 'Doctor') return { error: 'Only a doctor can approve an IOL.' };

  const { data: sc } = await supabase.from('surgical_cases').select('eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!power) return { error: 'Power is required.' };

  const { data: existing } = await supabase.from('iol_approvals').select('id').eq('surgical_case_id', caseId).maybeSingle();

  const payload = {
    surgical_case_id: caseId, biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    eye: sc.eye, power, surgeon_id: userData?.user?.id || null, status: 'Approved',
    approved_at: new Date().toISOString(), notes: notes || null, updated_at: new Date().toISOString(),
  };

  const { error } = existing
    ? await supabase.from('iol_approvals').update(payload).eq('id', existing.id)
    : await supabase.from('iol_approvals').insert(payload);
  if (error) return { error: error.message };
  return { success: true };
}
VEDA_EOF_9

mkdir -p "app/(main)/iol-approval"
cat > "app/(main)/iol-approval/page.js" << 'VEDA_EOF_10'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingIolApprovals, getApprovedToday, getIolApprovalHistory, getIolApprovalDetail, approveIol } from './actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function ApproveModal({ item, onClose, onDone }) {
  const [detail, setDetail] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [catalogId, setCatalogId] = useState('');
  const [power, setPower] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getIolApprovalDetail(item.caseId).then(setDetail);
    getActiveIolCatalog().then(setCatalog);
  }, [item.caseId]);

  // Pre-fill from the existing approval when re-opening to revise it --
  // otherwise Edit silently opened a blank form and looked like nothing
  // could be changed.
  useEffect(() => {
    if (detail?.approval) {
      setCatalogId(detail.approval.iol_catalog_id || '');
      setPower(detail.approval.power || '');
      setNotes(detail.approval.notes || '');
    }
  }, [detail]);

  const eyeKey = item.eye === 'OD' ? 're_power' : item.eye === 'OS' ? 'le_power' : null;

  function pickRecommendation(rec) {
    setCatalogId(rec.master_iol_catalog.id);
    setPower(eyeKey ? (rec[eyeKey] ?? '') : '');
  }

  // Flags when the doctor's choice doesn't match any device
  // recommendation on file -- either a brand/model with no
  // recommendation row at all, or a power that differs from what the
  // device recommended for this eye. A genuine clinical call either
  // way, but worth surfacing rather than silently letting it slide.
  const matchingRec = catalogId ? detail?.recommendations.find((r) => r.master_iol_catalog.id === catalogId) : null;
  const recommendedPower = matchingRec && eyeKey ? matchingRec[eyeKey] : null;
  const deviatesNoRec = !!catalogId && !matchingRec && (detail?.recommendations.length || 0) > 0;
  const deviatesPower = !!matchingRec && !!power && recommendedPower != null && String(power).trim() !== String(recommendedPower).trim();
  const deviates = deviatesNoRec || deviatesPower;

  async function handleApprove() {
    setError('');
    if (!detail?.biometry) { setError('No measured biometry on file for this patient.'); return; }
    setSaving(true);
    const result = await approveIol(item.caseId, detail.biometry.id, catalogId, power, notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100, padding: 16 }} onClick={onClose}>
      <div className="card" style={{ width: 520, maxWidth: '95vw', maxHeight: '90vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        <div className="card-head" style={{ marginBottom: 4, alignItems: 'flex-start' }}>
          <div className="card-title">
            <i className="ti ti-lens" style={{ color: 'var(--indigo)' }}></i> {detail?.approval ? 'Revise IOL Approval' : 'IOL Approval'}
          </div>
          {detail?.biometry && (
            <a href={`/biometry/${detail.biometry.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-file-report"></i> View Biometry Report
            </a>
          )}
        </div>
        <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 12 }}>
          {item.patient?.first_name} {item.patient?.last_name} ({item.patient?.uhid}) -- {item.procedureName} -- {EYE_LABEL[item.eye] || item.eye}
          {item.packageName && <> -- Package: {item.packageName}</>}
        </div>

        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

        {!detail ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)' }}>Loading...</div>
        ) : !detail.biometry ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--red)' }}>No measured biometry on file for this patient.</div>
        ) : (
          <>
            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Device Recommendations</div>
            {detail.recommendations.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 10 }}>No recommendations recorded on the biometry report.</div>
            )}
            <table className="tbl" style={{ marginBottom: 14 }}>
              <thead><tr><th>Brand / Model</th><th>RE</th><th>LE</th><th></th></tr></thead>
              <tbody>
                {detail.recommendations.map((r) => (
                  <tr key={r.id} style={{ background: catalogId === r.master_iol_catalog.id ? 'var(--indigo-lt, var(--blue-lt))' : 'transparent' }}>
                    <td>{r.master_iol_catalog.brand} {r.master_iol_catalog.model}</td>
                    <td>{r.re_power ?? '--'}</td>
                    <td>{r.le_power ?? '--'}</td>
                    <td>
                      <button className="btn btn-sm" onClick={() => pickRecommendation(r)}>
                        {catalogId === r.master_iol_catalog.id ? <i className="ti ti-check"></i> : 'Use this'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Confirm Choice for {EYE_LABEL[item.eye] || item.eye}</div>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
                <option value="">Select brand/model...</option>
                {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
              </select>
              <input className="fi fi-sm" placeholder="Power" value={power} onChange={(e) => setPower(e.target.value)} />
            </div>

            {deviates && (
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11.5, marginBottom: 10 }}>
                <i className="ti ti-alert-triangle"></i>{' '}
                {deviatesNoRec
                  ? 'This brand/model has no device recommendation on file for this patient -- deviating from the biometry report.'
                  : `Device recommended ${recommendedPower ?? '--'} D for ${EYE_LABEL[item.eye] || item.eye}, but ${power} D is being approved -- deviating from the biometry report.`}
              </div>
            )}

            <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={onClose}>Cancel</button>
              <button className="btn btn-primary" onClick={handleApprove} disabled={saving || !catalogId || !power}>
                {saving ? 'Saving...' : detail?.approval ? 'Update Approval' : 'Approve'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function IolApprovalPage() {
  const [pending, setPending] = useState([]);
  const [approvedToday, setApprovedToday] = useState([]);
  const [loading, setLoading] = useState(true);
  const [approving, setApproving] = useState(null);

  const refresh = useCallback(async () => {
    const [pendingList, approvedList] = await Promise.all([getPendingIolApprovals(), getApprovedToday()]);
    setPending(pendingList);
    setApprovedToday(approvedList);
    setLoading(false);
  }, []);

  // Same live-queue pattern used elsewhere (Queue, OT Intraop, etc) --
  // without this, an approval made by someone else, or just leaving
  // this tab open, never shows up until a manual hard refresh.
  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>IOL Approval</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>The surgeon's final sign-off on which IOL brand/model/power to actually use, per case.</div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Pending Approval
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pending.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && pending.map((item) => (
          <div key={item.caseId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {item.patient?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{item.patient?.first_name} {item.patient?.last_name}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[item.eye] || item.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {item.patient?.uhid} -- {item.procedureName}{item.packageName ? ` -- ${item.packageName}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => setApproving(item)}>
              <i className="ti ti-lens"></i> Approve
            </button>
          </div>
        ))}
        {!loading && pending.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing pending approval.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Approved Today</div>
        {approvedToday.map((a) => (
          <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {a.surgical_cases?.patients?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{a.surgical_cases?.patients?.first_name} {a.surgical_cases?.patients?.last_name}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              </div>
            </div>
            <button
              className="btn btn-sm"
              onClick={() => setApproving({
                caseId: a.surgical_case_id,
                patient: a.surgical_cases?.patients,
                procedureName: a.surgical_cases?.procedure_name,
                eye: a.eye,
                packageName: a.surgical_cases?.master_packages?.name || null,
              })}
            >
              <i className="ti ti-edit"></i> Edit
            </button>
          </div>
        ))}
        {approvedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>

      <IolApprovalHistorySection onEdit={setApproving} />

      {approving && (
        <ApproveModal item={approving} onClose={() => setApproving(null)} onDone={() => { setApproving(null); refresh(); }} />
      )}
    </div>
  );
}

function IolApprovalHistorySection({ onEdit }) {
  const [rows, setRows] = useState([]);
  const [search, setSearch] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(true);
  const [expanded, setExpanded] = useState(false);

  const refresh = useCallback(async () => {
    setLoading(true);
    setRows(await getIolApprovalHistory(fromDate || undefined, toDate || undefined, search || undefined));
    setLoading(false);
  }, [fromDate, toDate, search]);

  useEffect(() => { if (expanded) refresh(); }, [expanded, refresh]);

  return (
    <div className="card" style={{ marginTop: 14 }}>
      <div
        className="card-title"
        style={{ marginBottom: expanded ? 10 : 0, cursor: 'pointer', display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}
        onClick={() => setExpanded((v) => !v)}
      >
        <span><i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Approval History</span>
        <i className={`ti ti-chevron-${expanded ? 'up' : 'down'}`}></i>
      </div>

      {expanded && (
        <>
          <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
            <input className="fi fi-sm" style={{ flex: 1, minWidth: 160 }} placeholder="Search patient name or UHID..." value={search} onChange={(e) => setSearch(e.target.value)} />
            <input type="date" className="fi fi-sm" value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
            <input type="date" className="fi fi-sm" value={toDate} onChange={(e) => setToDate(e.target.value)} />
            {(fromDate || toDate || search) && (
              <button className="btn btn-sm" onClick={() => { setSearch(''); setFromDate(''); setToDate(''); }}>Clear</button>
            )}
          </div>

          {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Loading...</div>}

          {!loading && rows.map((a) => (
            <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', background: 'var(--g300)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>
                {a.surgical_cases?.patients?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 12.5 }}>{a.surgical_cases?.patients?.first_name} {a.surgical_cases?.patients?.last_name}</span>
                <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {a.surgical_cases?.patients?.uhid} -- {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
                  {a.approved_at && <> -- {new Date(a.approved_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</>}
                </div>
              </div>
              <button
                className="btn btn-sm"
                onClick={() => onEdit({
                  caseId: a.surgical_case_id,
                  patient: a.surgical_cases?.patients,
                  procedureName: a.surgical_cases?.procedure_name,
                  eye: a.eye,
                  packageName: a.surgical_cases?.master_packages?.name || null,
                })}
              >
                <i className="ti ti-edit"></i> Edit
              </button>
            </div>
          ))}
          {!loading && rows.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>No approvals found.</div>
          )}
        </>
      )}
    </div>
  );
}
VEDA_EOF_10

mkdir -p "app/print-templates"
cat > "app/print-templates/actions.js" << 'VEDA_EOF_11'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';
import { plainFrequency, groupPrescriptionsForPrint } from '@/lib/prescriptionFormatting';

// ── Editable print templates ──────────────────────────────────────────
// Each template's HTML lives here as a code-level DEFAULT (versioned,
// reviewable) which the database can override once someone edits and
// saves it from the Print Templates admin page. getPrintTemplate()
// always returns *something renderable* -- the DB row if one exists,
// otherwise this default -- so there's never a missing-template state.
//
// Hospital-wide info (name, address, logo, etc) is deliberately NOT
// hardcoded into these templates -- it lives in hospital_settings and
// gets merged into the render context, edited once as a proper form
// rather than hunted down inside every template's HTML.
//
// Templates use Handlebars {field} tokens ({{field}} for the one
// HTML field, the logo). All formatting (currency, dates) happens in
// the *data-building* functions below, so editors only ever see plain
// tokens, never format-string logic.

const DEFAULT_TEMPLATES = {
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<style>\n  @media print {\n    @page { size: A4; margin: 8mm 10mm; }\n  }\n</style>\n<div style=\"max-width: 800px; margin: 0 auto; padding: 10px 16px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 10.5px; line-height: 1.3;\">\n\n  {{#if hide_header}}\n  <!-- Header hidden -- printing on pre-printed letterhead. Blank space\n       left at top matches the pad's own header height. -->\n  <div style=\"height: {{header_space_cm}}cm;\"></div>\n  {{else}}\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 3px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 16px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 9px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 8.5px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 9px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n  {{/if}}\n\n  <div style=\"text-align: center; font-size: 13px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 4px 0; margin: 5px 0 6px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 8px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Chief Complaint</div>\n    <div style=\"font-size: 10.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n    {{#if hx_hopi}}<div style=\"font-size: 10px; color: #444; margin-top: 3px;\">{{hx_hopi}}</div>{{/if}}\n  </div>\n  {{/if}}\n\n  <!-- STRUCTURED HISTORY -->\n  {{#if hasHistory}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">History</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each historyLines}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 130px; color: #444; vertical-align: top;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{text}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#if hasViUnaided}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViGlasses}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViPh}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Pinhole)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_ph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_ph}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViNear}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Near)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_near}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_near}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasIop}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg){{#if iop_method}} -- {{iop_method}}{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n      {{/if}}\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasDistRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{dist_rx_source}}) -- Distance</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasNearRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{near_rx_source}}) -- Near</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADDITIONAL PRE-OP TESTS -->\n  {{#if hasAdditionalTests}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Additional Tests</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each additionalTests}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- OPTOMETRY OBSERVATIONS -->\n  {{#if hasOptObservations}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Optometry Observations</div>\n    <div style=\"font-size: 10.5px;\">{{optObservations}}</div>\n  </div>\n  {{/if}}\n\n  <!-- EXAMINATION -->\n  {{#if hasExamination}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Examination Findings</div>\n\n    {{#if hasExternal}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">External Examination</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each externalRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasAnterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Anterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each anteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasPosterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Posterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each posteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasApplanation}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Applanation Tonometry</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (OD)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (OS)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_le}}</td>\n      </tr>\n    </table>\n    {{/if}}\n\n    {{#if hasGonioscopy}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Gonioscopy</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each gonioscopyRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#unless hasExternal}}{{#unless hasAnterior}}{{#unless hasPosterior}}{{#unless hasApplanation}}{{#unless hasGonioscopy}}\n    <div style=\"font-size: 10px; color: #666; margin-bottom: 3px;\">External Examination and Anterior Segment -- all findings within normal limits. No Posterior Segment, Applanation Tonometry, or Gonioscopy data recorded.</div>\n    {{/unless}}{{/unless}}{{/unless}}{{/unless}}{{/unless}}\n\n    {{#if hasExamExtra}}\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Clinical Remarks</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each examExtra}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 10.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- SURGERY ADVISED -->\n  {{#if hasSurgery}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Surgery Advised</div>\n    <div style=\"font-size: 10.5px;\">{{surgery_procedure_name}} -- {{surgery_eye}}{{#if surgery_decision}} -- Patient Decision: {{surgery_decision}}{{/if}}</div>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 8.5px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 3px; text-align: center; font-size: 9px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Advice</div>\n    <div style=\"font-size: 10.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 5px 10px; font-size: 10.5px; color: #123a66; margin-bottom: 8px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 14px;\">\n    <tr>\n      <td style=\"font-size: 10px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 10px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 9px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 8px; font-size: 9px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  glasses_prescription: `<div style="max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  {{#if hide_header}}
  <!-- Header hidden -- printing on pre-printed letterhead / prescription
       pad. Blank space left at the top matches the pad's own header
       height so the printed content starts below it. -->
  <div style="height: {{header_space_cm}}cm;"></div>
  {{else}}
  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>
  {{/if}}

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    SPECTACLE PRESCRIPTION
  </div>

  <!-- PATIENT / RX INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444;">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>{{rx_date}}</strong></td></tr>
          <tr><td style="color: #444;">VA SCALE</td><td>: <strong>{{va_scale}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  {{#if hasDistRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Distance</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#if hasNearRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Near</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#unless hasDistRx}}{{#unless hasNearRx}}
  <div style="padding: 20px; text-align: center; color: #9ca3af; font-size: 12px; border: 1px dashed #d1d5db; border-radius: 8px; margin-bottom: 16px;">
    No Final Rx recorded for this assessment.
  </div>
  {{/unless}}{{/unless}}

  <table style="width: 60%; margin-bottom: 20px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444;">IPD (Interpupillary Distance)</td>
      <td style="padding: 4px 0; text-align: right; font-weight: 700;">{{ipd}}</td>
    </tr>
  </table>

  <div style="background: #eef2f7; border-left: 3px solid #1e4e8c; padding: 8px 12px; font-size: 11.5px; color: #444; margin-bottom: 30px;">
    This prescription is valid for 6 months from the date of issue. Please carry this slip to your optician.
  </div>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 50%; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;">
          <div style="font-weight: 600;">{{optometrist_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Optometrist</div>
        </div>
      </td>
      <td style="width: 50%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;">
          <div style="font-weight: 600;">{{doctor_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{doctor_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  biometry_report: `<div style="max-width: 720px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    IOL BIOMETRY &amp; POWER CALCULATION REPORT
  </div>

  <!-- PATIENT / SURGICAL INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 55%; padding: 10px 14px; vertical-align: top; font-size: 12px; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444; padding: 2px 0;">PATIENT ID</td><td style="padding: 2px 0;">: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">NAME</td><td style="padding: 2px 0;">: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">AGE/GENDER</td><td style="padding: 2px 0;">: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">VISIT NO</td><td style="padding: 2px 0;">: <strong>{{visit_number}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 45%; padding: 10px 14px; vertical-align: top; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 90px; color: #444; padding: 2px 0;">DATE</td><td style="padding: 2px 0;">: <strong>{{report_date}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">PROCEDURE</td><td style="padding: 2px 0;">: <strong>{{procedure_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">EYE</td><td style="padding: 2px 0;">: <strong>{{surgical_eye}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">SURGEON</td><td style="padding: 2px 0;">: <strong>{{surgeon_name}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <!-- BIOMETRY READINGS -->
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Biometry Readings</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 50%; vertical-align: top; padding-right: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Right Eye (RE / OD) -- Oculus Dexter</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasReReadings}}
          {{#each reSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
      <td style="width: 50%; vertical-align: top; padding-left: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Left Eye (LE / OS) -- Oculus Sinister</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasLeReadings}}
          {{#each leSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
    </tr>
  </table>

  <!-- IOL POWER CALCULATION -->
  {{#if hasFormulaResults}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Power Calculation</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
    <tr style="background: #e9edf2;">
      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Formula</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">IOL Power</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">Predicted Refraction</th>
    </tr>
    {{#each formulaResults}}
    <tr style="{{#if isSelected}}background: #f0fdf4; font-weight: 700;{{/if}}">
      <td style="border: 1px solid #999; padding: 7px;">{{name}}{{#if isSelected}} <span style="color: #16a34a;">(Selected)</span>{{/if}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{power}} D</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{refraction}}</td>
    </tr>
    {{/each}}
  </table>
  {{/if}}

  <!-- FINAL APPROVED PLAN -->
  <div style="font-size: 13px; font-weight: 700; color: #16a34a; margin-bottom: 8px; text-transform: uppercase;">Final Approved Plan</div>
  <table style="width: 100%; border: 1.5px solid #16a34a; border-collapse: collapse; margin-bottom: 18px; background: #f0fdf4;">
    <tr>
      <td style="padding: 10px 14px; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 160px; color: #444; padding: 3px 0;">Final IOL Power</td><td style="padding: 3px 0;"><strong>{{final_iol_power}} D</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Formula Used</td><td style="padding: 3px 0;"><strong>{{final_iol_formula}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">IOL Category</td><td style="padding: 3px 0;"><strong>{{final_iol_category}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Lens</td><td style="padding: 3px 0;"><strong>{{final_iol_lens}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Target Refraction</td><td style="padding: 3px 0;"><strong>{{target_refraction}}</strong></td></tr>
          {{#if surgeon_notes}}
          <tr><td style="color: #444; padding: 3px 0; vertical-align: top;">Surgeon Notes</td><td style="padding: 3px 0;">{{surgeon_notes}}</td></tr>
          {{/if}}
          <tr><td style="color: #444; padding: 3px 0;">Approved On</td><td style="padding: 3px 0;">{{approved_date}}</td></tr>
        </table>
      </td>
    </tr>
  </table>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
          <div style="font-weight: 600;">{{surgeon_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{surgeon_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n",
  medicine_prescription: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    MEDICINE PRESCRIPTION\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">VISIT NO</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DATE</td><td>: <strong>{{print_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Medicines Prescribed</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 7px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">How Often</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; font-weight: 600;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 9px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 7px; text-align: center; font-size: 11.5px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{else}}\n  <div style=\"font-size: 12.5px; color: #9ca3af; margin-bottom: 14px;\">No medicines prescribed for this visit.</div>\n  {{/if}}\n\n  <div style=\"background: #eef4fb; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12px; color: #123a66; margin-bottom: 20px;\">\n    Please take medicines exactly as instructed above. If you have any doubt about how to use a medicine, ask the pharmacist before you leave.\n  </div>\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>Dr. {{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  medical_fitness_form: `<div style="max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 12.5px; line-height: 1.5;">

  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 90px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 20px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 10px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 9px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 9.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 14px;">
    <div style="font-size: 15px; font-weight: 700;">Medical Fitness Form for Eye Surgery</div>
    <div style="font-size: 13px; font-weight: 600; margin-top: 2px;">नेत्र सर्जरी हेतु चिकित्सकीय फिटनेस प्रमाणपत्र</div>
  </div>

  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 14px;">
    <tr>
      <td style="width: 50%; padding: 8px 12px; font-size: 12px; border-right: 1px solid #999;">PATIENT NAME/ रोगी का नाम: <strong>{{patient_name}}</strong></td>
      <td style="width: 50%; padding: 8px 12px; font-size: 12px;">AGE/आयु: <strong>{{patient_age}}</strong></td>
    </tr>
    <tr>
      <td style="padding: 8px 12px; font-size: 12px; border-right: 1px solid #999; border-top: 1px solid #999;">UHID/रजिस्ट्रेशन संख्या: <strong>{{patient_uhid}}</strong></td>
      <td style="padding: 8px 12px; font-size: 12px; border-top: 1px solid #999;">GENDER/ लिंग: <strong>{{patient_gender}}</strong></td>
    </tr>
    <tr>
      <td colspan="2" style="padding: 8px 12px; font-size: 12px; border-top: 1px solid #999;">TYPE OF SURGERY/ शल्य चिकित्सा का प्रकार: <strong>{{surgery_type}}</strong></td>
    </tr>
  </table>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">1. SYSTEMIC HISTORY / सामान्य चिकित्सा इतिहास</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">{{box_diabetes}} Diabetes / मधुमेह</td>
        <td style="width: 50%; padding: 2px 0;">{{box_hypertension}} Hypertension / उच्च रक्तचाप</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">{{box_heart}} Heart Disease / हृदय रोग</td>
        <td style="padding: 2px 0;">{{box_thyroid}} Thyroid Disorder/ थायराइड विकार</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">{{box_asthma}} Asthma / दमा रोग</td>
        <td style="padding: 2px 0;">{{box_kidney}} Kidney Disease/ गुर्दे की बीमारी</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">{{box_systemic_other}} Other: {{systemic_other_text}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">2. PREVIOUS SURGERY /HOSPITALIZATION/ पूर्व सर्जरी / अस्पताल में भर्ती</div>
    <div style="min-height: 30px; border-bottom: 1px solid #999; font-size: 12px; white-space: pre-wrap;">{{previous_surgery}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">3. CURRENT MEDICATIONS/ वर्तमान दवाइयां</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 60%; padding: 2px 0;">{{box_med_antidiabetic}} Anti-diabetic medicines / Insulin</td>
        <td style="width: 40%; padding: 2px 0;">{{box_med_bp}} Blood pressure medicines</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">{{box_med_bloodthinners}} Blood thinners (Aspirin / Clopidogrel / Warfarin etc.)</div>
    <div style="padding: 2px 0;">{{box_med_other}} Other medicines: {{med_other_text}}</div>
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">4. DRUG ALLERGIES/ दवाओं से एलर्जी</div>
    <div style="padding: 2px 0;">{{box_allergy_none}} No Known Allergy</div>
    <div style="padding: 2px 0;">{{box_allergy_yes}} Yes / हां &rarr; {{allergy_details}}</div>
    {{#if allergy_notes}}<div style="padding: 2px 0; font-size: 11.5px; color: #444;">Notes: {{allergy_notes}}</div>{{/if}}
  </div>

  <div style="margin-bottom: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">5. VITAL SIGNS/ महत्वपूर्ण शारीरिक संकेत</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">Blood Pressure: <strong>{{vital_bp}}</strong> mmHg</td>
        <td style="width: 50%; padding: 2px 0;">Pulse: <strong>{{vital_pulse}}</strong> / min</td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">SpO&#8322;: <strong>{{vital_spo2}}</strong> %</td>
        <td style="padding: 2px 0;">Blood Sugar (if diabetic): <strong>{{vital_blood_sugar}}</strong> mg/dl</td>
      </tr>
    </table>
    {{#if vital_notes}}<div style="padding: 2px 0; font-size: 11.5px; color: #444;">Notes: {{vital_notes}}</div>{{/if}}
  </div>

  <div style="margin-bottom: 12px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 4px;">6. INVESTIGATIONS/ जांच</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 12px;">
      <tr>
        <td style="width: 50%; padding: 2px 0;">Hemoglobin (Hb): <strong>{{inv_hb}}</strong></td>
        <td style="width: 50%; padding: 2px 0;">Random Blood Sugar (RBS): <strong>{{inv_rbs}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">Fasting Blood Sugar (FBS): <strong>{{inv_fbs}}</strong></td>
        <td style="padding: 2px 0;">PPBS: <strong>{{inv_ppbs}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 2px 0;">HIV I &amp; II: {{box_hiv_nonreactive}} Non-Reactive &nbsp; {{box_hiv_reactive}} Reactive</td>
        <td style="padding: 2px 0;">HBsAg: {{box_hbsag_nonreactive}} Non-Reactive &nbsp; {{box_hbsag_reactive}} Reactive</td>
      </tr>
    </table>
    <div style="padding: 2px 0;">Other: {{inv_other}}</div>
  </div>

  <div style="border-top: 1px solid #999; padding-top: 10px;">
    <div style="font-weight: 700; font-size: 12.5px; margin-bottom: 6px;">7. PHYSICIAN CERTIFICATION/ चिकित्सक प्रमाणन</div>
    <div style="font-size: 11.5px; margin-bottom: 4px;">
      I have examined the patient and certify that the patient is medically <strong>{{fitness_word}}</strong> for cataract surgery under local / topical anesthesia.
    </div>
    <div style="font-size: 11.5px; margin-bottom: 10px;">
      मैंने रोगी का परीक्षण किया है और प्रमाणित करता / करती हूं कि रोगी लोकल / टॉपिकल एनेस्थीसिया में मोतीयाबिंद सर्जरी के लिए चिकित्सकीय रूप से <strong>{{fitness_word_hi}}</strong> है।
    </div>
    {{#if fitness_notes}}
    <div style="font-size: 11.5px; margin-bottom: 10px; color: #b91c1c;"><strong>Remarks:</strong> {{fitness_notes}}</div>
    {{/if}}

    <table style="width: 100%; border-collapse: collapse; font-size: 12px; margin-top: 10px;">
      <tr>
        <td style="width: 50%; padding: 4px 0;">Doctor Name / चिकित्सक का नाम: <strong>{{doctor_name}}</strong></td>
        <td style="width: 50%; padding: 4px 0;">Qualification / योग्यता: <strong>{{doctor_qualification}}</strong></td>
      </tr>
      <tr>
        <td style="padding: 4px 0;">Registration Number / पंजीकरण संख्या: <strong>{{doctor_regn_no}}</strong></td>
        <td style="padding: 4px 0;">Date / दिनांक: <strong>{{cert_date}}</strong></td>
      </tr>
    </table>

    <div style="margin-top: 30px;">
      Signature / हस्ताक्षर: ______________________
    </div>
  </div>

</div>
`
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'glasses_prescription', name: 'Glasses Prescription', description: 'Printed from the Optometry screen -- Final Rx spectacle prescription for the patient / optician.' },
  { key: 'biometry_report', name: 'Biometry Report', description: 'Printed from Surgeon Approval (Biometry) -- raw biometry readings, IOL power calculation, and the final approved plan.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Printed for a completed investigation -- findings, notes, technician/verifier sign-off.' },
  { key: 'medicine_prescription', name: 'Medicine Prescription', description: 'Printed from Pharmacy -- the medicine list on its own, independent of the bill, for the patient to keep or take elsewhere.' },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Printed at Post-op discharge -- procedure, IOL, medications, instructions, follow-up schedule.' },
  { key: 'external_tests_requisition', name: 'External Tests Requisition', description: 'Printed from Surgical Journey -- list of external tests (blood work, HIV test, etc) for the patient to take to an outside lab.' },
  { key: 'medical_fitness_form', name: 'Medical Fitness Form (Cataract Surgery)', description: 'Bilingual pre-op fitness certificate, printed from Medical Fitness once the doctor gives clearance -- goes in the patient file.' },
];

// ── Hospital Settings -- the "actual fields to edit" form (name,
//    address, logo, etc), shared across every template. Singleton row
//    (id is always `true`). ──
export async function getHospitalSettings() {
  const supabase = await createClient();
  const { data } = await supabase.from('hospital_settings').select('*').eq('id', true).maybeSingle();
  return data || {};
}

export async function saveHospitalSettings(fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('hospital_settings').update({
    ...fields, updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }).eq('id', true);
  if (error) return { error: error.message };
  return { success: true };
}

function logoHtml(settings) {
  if (settings?.logo_data_url) {
    return `<img src="${settings.logo_data_url}" style="width: 88px; height: 88px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="88" height="88" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
    <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>
    <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>
    <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>
  </svg>`;
}

export async function listPrintTemplates() {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('template_key, updated_at, updated_by, profiles(full_name)');
  const byKey = {};
  (data || []).forEach((r) => { byKey[r.template_key] = r; });
  return PRINT_TEMPLATE_CATALOG.map((t) => ({
    ...t,
    customized: !!byKey[t.key],
    updatedAt: byKey[t.key]?.updated_at || null,
    updatedBy: byKey[t.key]?.profiles?.full_name || null,
  }));
}

export async function getPrintTemplate(key) {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('html, updated_at').eq('template_key', key).maybeSingle();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  return {
    key,
    name: catalog?.name || key,
    html: data?.html || DEFAULT_TEMPLATES[key] || '<div>No template found.</div>',
    isCustomized: !!data,
    updatedAt: data?.updated_at || null,
  };
}

export async function savePrintTemplate(key, html) {
  const supabase = await createClient();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('print_templates').upsert({
    template_key: key, name: catalog?.name || key, html,
    updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }, { onConflict: 'template_key' });
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetPrintTemplate(key) {
  const supabase = await createClient();
  const { error } = await supabase.from('print_templates').delete().eq('template_key', key);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Preview arbitrary (possibly unsaved) template HTML against sample
//    data -- lets the editor see changes before committing them. ──
export async function previewTemplateHtml(key, html) {
  try {
    const compiled = Handlebars.compile(html);
    return { html: compiled(await getSampleData(key)) };
  } catch (e) {
    return { error: `Template error: ${e.message}` };
  }
}

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  const settings = await getHospitalSettings();
  if (key === 'invoice_opd') return buildInvoiceContext(settings, SAMPLE_OPD_RAW);
  if (key === 'invoice_surgery') return buildInvoiceContext(settings, SAMPLE_SURGERY_RAW);
  if (key === 'receipt') return buildReceiptContext(settings, SAMPLE_RECEIPT_RAW);
  if (key === 'receipt_advance') return buildReceiptContext(settings, SAMPLE_ADVANCE_RAW);
  if (key === 'opd_case_sheet') return buildOpdCaseSheetContext(settings, SAMPLE_CASE_SHEET_RAW);
  if (key === 'glasses_prescription') return buildGlassesPrescriptionContext(settings, SAMPLE_GLASSES_RX_RAW);
  if (key === 'biometry_report') return buildBiometryReportContext(settings, SAMPLE_BIOMETRY_RAW);
  if (key === 'discharge_summary') return buildDischargeSummaryContext(settings, SAMPLE_DISCHARGE_RAW);
  if (key === 'investigation_report') return SAMPLE_INVESTIGATION_CONTEXT(settings);
  return {};
}

const SAMPLE_DISCHARGE_RAW = {
  patient: { uhid: 'VEH-00004', first_name: 'Utkarsh', last_name: 'Prakash', mobile: '9876543210', age: 62, gender: 'M' },
  surgeon: { full_name: 'Nisha Bachkheti' },
  procedureName: 'Phaco Cataract Surgery', eye: 'OD',
  episode: {
    admission_date: '2026-06-10', surgery_date: '2026-06-10', discharge_date: '2026-06-11',
    discharge_notes: 'Uneventful surgery. Patient tolerated procedure well.',
    discharge_instructions: 'Avoid rubbing the eye. No water contact for 1 week. Use dark glasses outdoors. Report immediately for redness, pain, or sudden vision loss.',
  },
  intraop: { implant_power: '21.5', implant_manufacturer: 'Alcon', implant_model: 'AcrySof IQ' },
  biometry: [{ surgical_eye: 'OD', final_iol_power: '21.5', final_iol_category: 'Monofocal' }],
  meds: [
    { name: 'Moxifloxacin 0.5%', sig: '1 drop QID x 1 week, then taper' },
    { name: 'Prednisolone Acetate 1%', sig: '1 drop QID x 2 weeks, then taper' },
  ],
  followups: [
    { visit_label: 'Post-op Day 1', scheduled_date: '2026-06-12', status: 'Completed' },
    { visit_label: 'Post-op Week 1', scheduled_date: '2026-06-18', status: 'Scheduled' },
    { visit_label: 'Post-op Month 1', scheduled_date: '2026-07-11', status: 'Scheduled' },
  ],
};

function SAMPLE_INVESTIGATION_CONTEXT(settings) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),
    patient_id: 'VEH-00004', patient_name: 'Utkarsh Prakash', patient_age: 62, patient_gender: 'M', patient_mobile: '9876543210',
    investigation_name: 'OCT Macula', investigation_type: 'OCT', eye: 'OD',
    doctor_name: 'Nisha Bachkheti', ordered_date: '04 Jun 2026', completed_date: '05 Jun 2026',
    isUnable: false, unable_reason: null,
    hasFields: true,
    fields: [
      { label: 'Central Macular Thickness (OD)', value: '245 um' },
      { label: 'RNFL Thickness', value: 'Average 85 um' },
      { label: 'Signal Strength', value: '8/10' },
    ],
    hasNotes: true, result_notes: 'Scan quality good. No macular edema noted.',
    technician_name: 'Rohit Pratap', hasVerifiedBy: true, verified_by_name: 'Nisha Bachkheti',
  };
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_number: 'V26-000042' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  packageBreakup: [
    { description: 'Surgeon fee', amount: 15000 },
    { description: 'IOL (Standard Monofocal)', amount: 8000 },
    { description: 'OT charges', amount: 7000 },
    { description: 'Consumables & disposables', amount: 3000 },
    { description: 'Pre-op investigations', amount: 2000 },
  ],
};

const SAMPLE_RECEIPT_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970' },
  payment: {
    receipt_number: 'VEH/RECEIPT/-0054', collected_at: '2026-06-03T00:00:00Z', total_amount: 300,
    payment_type: 'invoice_payment', reference: null, remarks: null,
  },
  collector: { full_name: 'Front Desk' },
  modes: [{ mode: 'Cash', amount: 300 }],
  allocations: [{ amount: 300, invoices: { invoice_number: 'VEH-BILL-0143' } }],
};

const SAMPLE_ADVANCE_RAW = {
  ...SAMPLE_RECEIPT_RAW,
  payment: {
    receipt_number: 'VEH/RECEIPT/-0060', collected_at: '2026-06-15T00:00:00Z', total_amount: 10000,
    payment_type: 'advance', reference: null, remarks: null,
  },
  modes: [{ mode: 'UPI', amount: 10000 }],
  allocations: [],
};

const SAMPLE_CASE_SHEET_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  encounter: {
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes', hx_hopi: 'Gradual, painless, progressive blurring of vision, worse for distance.',
    ocular_history: ['Diabetic Retinopathy screening -- 2024'], medical_history: ['Diabetes Mellitus Type 2'], family_history: ['Glaucoma -- father'],
    drug_history: ['Metformin 500mg BD'], allergy: ['Sulfa drugs'],
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    re_dist_ph: '6/6', le_dist_ph: '6/6', re_near_unaided: 'N8', le_near_unaided: 'N6',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '', ref_final_re_near_axis: '', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
    iop_method: 'NCT', add_k1_re: '43.5', add_k1_le: '43.7', add_k2_re: '44.2', add_k2_le: '44.4', add_axial_length_re: '23.4 mm', add_axial_length_le: '23.3 mm',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  examination: {
    external_findings: {}, anterior_findings: { Lens: { re: 'NS2', le: 'NS1', re_custom: '', le_custom: '' } }, posterior_findings: { without: { Disc: { re: 'Healthy', le: 'Healthy' }, CDR: { re: '0.4', le: '0.3' } }, with: {} },
    applanation_re: '16', applanation_le: '15',
    gonioscopy_findings: { angle_re: 'Open Angle', angle_le: 'Open Angle' },
  },
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// Deliberately includes one eye with SPH-only (no CYL/AXIS) so the
// preview shows how a spherical-only Rx renders cleanly.
const SAMPLE_GLASSES_RX_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', age: 39, gender: 'Male' },
  assessment: {
    created_at: '2026-06-01T00:00:00Z', va_scale: 'Snellen', ref_pd: '62mm',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '-0.50', ref_final_re_near_axis: '90', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
  },
  optometrist: { full_name: 'Rohit Pratap' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
};

const SAMPLE_BIOMETRY_RAW = {
  patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
  visit: { visit_number: 'VN26-000112' },
  record: {
    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Approved',
    created_at: '2026-06-01T00:00:00Z', approved_at: '2026-06-02T00:00:00Z',
    measurements: {
      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', lt: '4.50', wtw: '11.80' }],
      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', lt: '4.48', wtw: '11.75' }],
    },
    formula_results: [
      { name: 'Barrett Universal II', power: '21.5', refraction: '-0.15' },
      { name: 'SRK/T', power: '21.0', refraction: '-0.30' },
    ],
    selected_formula: 'Barrett Universal II',
    final_iol_power: '21.5', final_iol_category: 'Monofocal', target_refraction: '-0.15 D',
    surgeon_notes: 'Aim for slight myopia. Standard monofocal, no toric correction needed.',
  },
  surgeon: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ' },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, visit_number, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: rawLineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');

  // The invoice itself stays itemized (individual medicine names/rates
  // visible in Invoice Details) -- no pharmacy license yet, so only the
  // printed/PDF copy collapses every Pharmacy-dept line into one "OPD
  // Procedure Consumables" line at qty 1 for the combined total.
  const pharmacyLines = (rawLineItems || []).filter((li) => li.dept === 'Pharmacy');
  const nonPharmacyLines = (rawLineItems || []).filter((li) => li.dept !== 'Pharmacy');
  const pharmacyTotal = pharmacyLines.reduce((s, li) => s + Number(li.net), 0);
  const lineItems = pharmacyLines.length > 0
    ? [...nonPharmacyLines, { service_name: 'OPD Procedure Consumables', dept: 'Pharmacy', qty: 1, rate: pharmacyTotal, disc: 0, net: pharmacyTotal }]
    : nonPharmacyLines;

  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (rawLineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let packageCode = null;
  let surgeryName = null;
  let surgeryCode = null;
  let surgeryEye = null;
  let surgeonForBill = null; // Surgery Bill shows the operating surgeon, not the visit's consulting doctor
  let packageBreakup = [];
  let breakupAvailable = false;
  if (isSurgery) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created -- no visit_id
    // needed for this part at all.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    // Enrichment only -- a surgical case registered directly (OT
    // Schedule's "Register Surgery Directly") or billed without a visit
    // selected has no visit_id to look this up by. That's fine: the
    // manual_surgery_* fields below (always saved at billing time,
    // whether prefilled from a case or typed by hand) cover exactly
    // this situation, which is why they exist.
    let surgicalCase = null;
    if (invoice.visit_id) {
      const { data } = await supabase
        .from('surgical_cases')
        .select('id, procedure_name, eye, surgeon_id')
        .eq('visit_id', invoice.visit_id)
        .neq('status', 'Cancelled')
        .maybeSingle();
      surgicalCase = data;
    }

    // Surgery/Eye/Doctor are always editable in New Invoice now (whether
    // prefilled from a case or entered by hand), and whatever was
    // confirmed at billing time is saved onto the invoice itself
    // (manual_surgery_*). That takes priority over the surgical case,
    // which is live data that can keep changing after the bill was
    // printed -- same reasoning as the package name/code above.
    surgeryName = invoice.manual_surgery_name || surgicalCase?.procedure_name || null;
    surgeryEye = invoice.manual_surgery_eye || surgicalCase?.eye || null;
    const surgeonId = invoice.manual_surgeon_id || surgicalCase?.surgeon_id || null;
    if (surgeonId) {
      const { data: surgeon } = await supabase.from('profiles').select('full_name, registration_no').eq('id', surgeonId).maybeSingle();
      surgeonForBill = surgeon || null;
    }
    if (surgeryName) {
      // surgical_cases stores the surgery as free text (matched from the
      // Clinical Masters -- Surgery list at the time it was picked), not
      // a foreign key, so the code is looked up by name here.
      const { data: surgery } = await supabase.from('master_surgeries').select('code').eq('name', surgeryName).maybeSingle();
      surgeryCode = surgery?.code || null;
    }
    // Breakup lookup is keyed off packageCode (the invoice's own line
    // item, always available for a surgery invoice) -- not the
    // surgical case, so this works regardless of whether one was found.
    if (packageCode) {
      const { data: pkgForBreakup } = await supabase.from('master_packages').select('id').eq('code', packageCode).maybeSingle();
      if (pkgForBreakup) {
        const { data: breakupItems } = await supabase
          .from('package_line_items')
          .select('description, amount')
          .eq('package_id', pkgForBreakup.id)
          .order('sort_order');
        breakupAvailable = (breakupItems || []).length > 0;
        // Only actually included in the printed HTML when explicitly
        // requested (e.g. an insurance copy) -- most prints should stay
        // as the single package line item, no itemized breakup.
        if (includeBreakup) packageBreakup = breakupItems || [];
      }
    }
  }

  const settings = await getHospitalSettings();
  const context = buildInvoiceContext(settings, {
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: isSurgery ? (surgeonForBill || invoice.visits?.profiles) : invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    packageCode,
    surgeryName,
    surgeryCode,
    surgeryEye,
    packageBreakup,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context), breakupAvailable };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

// Same mapping used in OT Intraop's workspace -- kept identical so an eye
// code reads the same way everywhere in the app, including on printouts.
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
function fmtEye(code) {
  if (!code) return '--';
  return EYE_LABEL[code] || code;
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, packageBreakup }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    terms_text: settings.terms_text || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',
    surgery_name: surgeryName || '--',
    surgery_code: surgeryCode || '--',
    eye: fmtEye(surgeryEye),
    package_name: packageName || '--',
    package_code: packageCode || '--',
    // Discharge date always mirrors the visit date -- day-care surgery
    // discharge happens the same day, and the printed bill should never
    // show a different (or missing) date from a separately recorded
    // recovery episode.
    discharge_date: fmtDate(visit?.created_at),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_number: visit?.visit_number || '--',
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1,
      name: (li.dept === 'Surgery' && li.service_code) ? `${li.service_name} (${li.service_code})` : li.service_name,
      qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    // Optional itemized breakup of what a surgery package includes --
    // not part of the accounting (the invoice still has one net line
    // item for the package), just a printed reference so staff can show
    // a patient what's covered when asked. Only present when a package
    // with a saved breakup was actually billed.
    has_breakup: (packageBreakup || []).length > 0,
    package_breakup: (packageBreakup || []).map((b) => ({ description: b.description, amount: inr(b.amount) })),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}

const PAYMENT_TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

// ── Renders the actual receipt HTML for a given paymentId. Picks the
//    Advance Receipt variant when payment_type is 'advance' (a fresh
//    advance collection, not yet applied to any invoice); everything
//    else (a regular payment, or an advance being adjusted against an
//    invoice) uses the standard Payment Receipt. ──
export async function renderReceiptHtml(paymentId) {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(uhid, first_name, last_name, mobile), profiles:collected_by(full_name)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: 'Receipt not found.' };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const settings = await getHospitalSettings();
  const context = buildReceiptContext(settings, {
    patient: {
      patient_code: payment.patients?.uhid, first_name: payment.patients?.first_name, last_name: payment.patients?.last_name,
      mobile: payment.patients?.mobile,
    },
    payment,
    collector: payment.profiles,
    modes: modes || [],
    allocations: allocations || [],
  });

  const templateKey = payment.payment_type === 'advance' ? 'receipt_advance' : 'receipt';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildReceiptContext(settings, { patient, payment, collector, modes, allocations }) {
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_id: patient.patient_code || '--',
    patient_mobile: patient.mobile || '--',

    receipt_no: payment.receipt_number,
    receipt_date: fmtDate(payment.collected_at),
    payment_type_label: PAYMENT_TYPE_LABEL[payment.payment_type] || payment.payment_type,
    collected_by: collector?.full_name || '--',

    amount_received: inr(payment.total_amount),
    amount_in_words: amountInWords(payment.total_amount),

    hasAllocations: (allocations || []).length > 0,
    allocations: (allocations || []).map((a) => ({ invoiceNumber: a.invoices?.invoice_number || '--', amount: inr(a.amount) })),

    modes: (modes || []).map((m) => ({ mode: m.mode, amount: inr(m.amount) })),

    reference: payment.reference || null,
    remarks: payment.remarks || null,
  };
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

function twoDigitWords(n) {
  if (n < 20) return ONES[n];
  return `${TENS[Math.floor(n / 10)]}${n % 10 ? ' ' + ONES[n % 10] : ''}`;
}
function threeDigitWords(n) {
  if (n < 100) return twoDigitWords(n);
  return `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? ' ' + twoDigitWords(n % 100) : ''}`;
}

// Indian numbering (lakh/crore), matching how amounts are normally
// written out on Indian receipts.
function amountInWords(amount) {
  let n = Math.round(Number(amount || 0));
  if (n === 0) return 'Rupees Zero Only';
  const parts = [];
  const crore = Math.floor(n / 10000000); n %= 10000000;
  const lakh = Math.floor(n / 100000); n %= 100000;
  const thousand = Math.floor(n / 1000); n %= 1000;
  const hundred = n;
  if (crore) parts.push(`${threeDigitWords(crore)} Crore`);
  if (lakh) parts.push(`${threeDigitWords(lakh)} Lakh`);
  if (thousand) parts.push(`${threeDigitWords(thousand)} Thousand`);
  if (hundred) parts.push(threeDigitWords(hundred));
  return `Rupees ${parts.join(' ')} Only`;
}

// ── Renders a simple referral slip listing external investigations
//    requested for a surgical case (blood work, HIV test, etc -- not
//    done in-house) -- handed to the patient to get done elsewhere.
//    Self-contained rather than going through the editable
//    print_templates table, since this is a short, fixed-format slip. ──
export async function renderExternalInvestigationReferralHtml(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, created_at, patients:patient_id(uhid, first_name, last_name, age, gender, mobile), profiles:surgeon_id(full_name, registration_no)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: tests } = await supabase
    .from('external_investigations')
    .select('test_name, created_at')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });

  if (!tests || tests.length === 0) return { error: 'No external investigations have been added for this case yet.' };

  const settings = await getHospitalSettings();
  const patient = sc.patients;

  const rows = tests.map((t, i) => `
    <tr>
      <td style="border: 1px solid #999; padding: 8px; text-align: center; width: 40px;">${i + 1}</td>
      <td style="border: 1px solid #999; padding: 8px;">${t.test_name}</td>
      <td style="border: 1px solid #999; padding: 8px;"></td>
    </tr>`).join('');

  const html = `
<div style="max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">${logoHtml(settings)}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">${settings.name || ''}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">${settings.unit_line || ''}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : ${settings.regn_no || ''}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        ${settings.address_line1 || ''}<br/>
        ${settings.address_line2 || ''}<br/>
        ${settings.city_state_pin || ''}<br/>
        Tel: ${settings.phone || ''}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;">
    INVESTIGATION REFERRAL
  </div>

  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 110px; color: #444;">PATIENT ID</td><td>: <strong>${patient?.uhid || '--'}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>${patient?.first_name || ''} ${patient?.last_name || ''}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>${patient?.age ?? '--'} / ${patient?.gender || '--'}</strong></td></tr>
          <tr><td style="color: #444;">MOBILE</td><td>: <strong>${patient?.mobile || '--'}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>${fmtDate(new Date().toISOString())}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <div style="font-size: 12px; margin-bottom: 10px;">The following investigations are requested. Please get these done and bring the reports on your next visit.</div>

  <table style="width: 100%; border-collapse: collapse; font-size: 12.5px; margin-bottom: 30px;">
    <thead>
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px;">S.NO</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left;">Investigation</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 160px;">Report / Remarks</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  </table>

  <table style="width: 100%; margin-top: 50px;">
    <tr>
      <td style="font-size: 12px;">&nbsp;</td>
      <td style="text-align: right; font-size: 12px;">
        <div>Dr. ${sc.profiles?.full_name || ''}</div>
        <div style="font-size: 10.5px; color: #666;">Reg No: ${sc.profiles?.registration_no || ''}</div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at ${settings.phone || ''} or Email us at ${settings.email || ''}
  </div>
</div>`;

  return { html };
}

// ── Renders the OPD Case Sheet for a given encounterId -- the
//    patient-facing handout: chief complaint, vision/IOP/refraction,
//    diagnosis, prescription, advice, and follow-up. ──
export async function renderOpdCaseSheetHtml(encounterId) {
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(id, created_at, visit_type, doctor_id, patients(uhid, first_name, last_name, mobile, age, gender), profiles:doctor_id(full_name, registration_no))')
    .eq('id', encounterId)
    .single();
  if (error || !encounter) return { error: 'Consultation not found.' };

  const visit = encounter.visits;

  const { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visit?.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let iopReadings = [];
  if (assessment) {
    const { data: readings } = await supabase.from('optometry_iop_readings').select('eye, value').eq('assessment_id', assessment.id);
    iopReadings = readings || [];
  }

  const { data: examination } = await supabase.from('clinical_examinations').select('*').eq('encounter_id', encounterId).maybeSingle();

  const { data: diagnoses } = await supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: prescriptions } = await supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: followup } = await supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle();

  // Surgery advice -- if this encounter marked the patient for surgery,
  // it should show on the case sheet: what was advised, which eye, and
  // the patient's decision at the time.
  const { data: surgicalCase } = await supabase
    .from('surgical_cases')
    .select('procedure_name, eye, decision')
    .eq('encounter_id', encounterId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const settings = await getHospitalSettings();
  const context = buildOpdCaseSheetContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      mobile: visit?.patients?.mobile, age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    encounter,
    visit,
    doctor: visit?.profiles,
    assessment,
    iopReadings,
    examination,
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
    surgicalCase,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── GLASSES PRESCRIPTION -- printed from the Optometry screen. Always
//    the Final Rx (the accepted prescription, not the working
//    Objective/Subjective values). Rows are only shown when at least
//    one eye has an SPH recorded; CYL/AXIS are shown blank (not "0.00")
//    when only the spherical power was given, since axis is meaningless
//    without a cylinder. ──
function fmtRxVal(v) {
  return v || '--';
}

// Falls back Final Rx -> Subjective -> Objective when the earlier one
// wasn't filled in for that eye/distance -- for the internal OPD case
// sheet only. A patient's Distance refraction is very often recorded
// in the Subjective or Objective tab and never re-typed into Final Rx,
// which otherwise makes it silently vanish from the printed sheet even
// though it was genuinely measured. Falls back per whole row (not per
// individual SPH/CYL/AXIS field) so figures from different refraction
// types are never mixed together in one row, and the source actually
// used is labeled on the printout rather than implied to be "Final".
// A distance/near refraction row can be entirely valid with SPH left
// blank (plano/zero) while the real correction sits in CYL+AXIS -- pure
// astigmatism with no spherical component is clinically common. Only
// checking SPH for "was this row filled in" silently drops exactly
// that case, so every field is checked here.
function rowHasData(assessment, prefix) {
  return !!(assessment?.[`${prefix}_sph`] || assessment?.[`${prefix}_cyl`] || assessment?.[`${prefix}_axis`] || assessment?.[`${prefix}_va`]);
}

const REFRACTION_SOURCE_LABEL = { final: 'Final Rx', subj: 'Subjective', obj: 'Objective (Auto-Rx)' };
function pickRxRow(assessment, eye, distNear) {
  for (const type of ['final', 'subj', 'obj']) {
    const prefix = `ref_${type}_${eye}_${distNear}`;
    if (rowHasData(assessment, prefix)) {
      return { cells: buildRxCells(assessment, prefix), source: type };
    }
  }
  return { cells: buildRxCells(assessment, `ref_final_${eye}_${distNear}`), source: 'final' };
}

function buildRxCells(assessment, prefix) {
  const sph = assessment?.[`${prefix}_sph`];
  const cyl = assessment?.[`${prefix}_cyl`];
  const axis = assessment?.[`${prefix}_axis`];
  const va = assessment?.[`${prefix}_va`];
  return {
    sph: fmtRxVal(sph),
    // Only spherical power is common in real prescriptions -- axis is
    // meaningless without a cylinder, so both stay blank together.
    cyl: cyl ? cyl : '--',
    axis: cyl ? fmtRxVal(axis) : '--',
    va: fmtRxVal(va),
  };
}

function buildGlassesPrescriptionContext(settings, { patient, assessment, optometrist, doctor }) {
  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');

  const hasDistRx = rowHasData(assessment, 'ref_final_re_dist') || rowHasData(assessment, 'ref_final_le_dist');
  const hasNearRx = rowHasData(assessment, 'ref_final_re_near') || rowHasData(assessment, 'ref_final_le_near');

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed prescription pad (hospital header already
    // on the paper) -- hide the digital header and leave blank space
    // matching the pad's own header height instead.
    hide_header: !!settings.glasses_rx_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    rx_date: fmtDate(assessment?.created_at),
    va_scale: assessment?.va_scale || 'Snellen',

    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,

    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,

    ipd: assessment?.ref_pd || '--',
    optometrist_name: optometrist?.full_name || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',
  };
}

export async function renderGlassesPrescriptionHtml(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select('*, visits(id, doctor_id, patients(uhid, first_name, last_name, age, gender), profiles:doctor_id(full_name, registration_no)), profiles:recorded_by(full_name)')
    .eq('id', assessmentId)
    .single();
  if (error || !assessment) return { error: 'Optometry assessment not found.' };

  const visit = assessment.visits;
  const settings = await getHospitalSettings();
  const context = buildGlassesPrescriptionContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    assessment,
    optometrist: assessment.profiles,
    doctor: visit?.profiles,
  });

  const template = await getPrintTemplate('glasses_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── BIOMETRY REPORT -- printed from Surgeon Approval once the IOL plan
//    is approved. Shows the raw biometry readings (per eye, per device --
//    a technician may have taken more than one reading, e.g. a manual
//    A-scan fallback for a dense cataract) alongside the calculated
//    formula results and the final approved plan. ──
function buildBiometryReadingSets(sets) {
  return (Array.isArray(sets) ? sets : []).map((s) => ({
    device: s.device || 'Unspecified device',
    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', lt: s.lt || '--', wtw: s.wtw || '--',
  }));
}

function buildBiometryReportContext(settings, { patient, visit, record, surgeon, catalogItem }) {
  const reSets = buildBiometryReadingSets(record.measurements?.re);
  const leSets = buildBiometryReadingSets(record.measurements?.le);

  const formulaResults = (record.formula_results || []).map((r) => ({
    name: r.name, power: r.power || '--', refraction: r.refraction || '--',
    isSelected: r.name === record.selected_formula,
  }));

  const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_id: patient.uhid || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    visit_number: visit?.visit_number || '--',
    report_date: fmtDate(record.approved_at || record.created_at),

    procedure_name: record.procedure_name || '--',
    surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
    surgeon_name: surgeon?.full_name || '--',
    surgeon_regn_no: surgeon?.registration_no || '--',

    hasReReadings: reSets.length > 0,
    reSets,
    hasLeReadings: leSets.length > 0,
    leSets,

    hasFormulaResults: formulaResults.length > 0,
    formulaResults,

    isApproved: record.status === 'Approved',
    final_iol_power: record.final_iol_power || '--',
    final_iol_formula: record.selected_formula || '--',
    final_iol_category: record.final_iol_category || '--',
    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}`.trim() : '--',
    target_refraction: record.target_refraction || '--',
    surgeon_notes: record.surgeon_notes || null,
    approved_date: record.approved_at ? fmtDate(record.approved_at) : '--',
  };
}

export async function renderBiometryReportHtml(recordId) {
  const supabase = await createClient();

  const { data: record, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(uhid, first_name, last_name, age, gender))')
    .eq('id', recordId)
    .single();
  if (error || !record) return { error: 'Biometry record not found.' };

  let surgeon = null;
  if (record.verified_by) {
    const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', record.verified_by).maybeSingle();
    surgeon = doc;
  }

  const settings = await getHospitalSettings();
  const context = buildBiometryReportContext(settings, {
    patient: record.visits?.patients || {},
    visit: record.visits,
    record,
    surgeon,
    catalogItem: null,
  });

  const template = await getPrintTemplate('biometry_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// Each structure's first/baseline template option is its "normal" value
// (mirrors EXT_TEMPLATES/ANT_TEMPLATES/POST_TEMPLATES in the Examination
// tab -- kept in sync manually since the template lists live client-side).
const EXAM_NORMAL_VALUE = {
  Lids: 'Normal', Adnexa: 'Normal', Lacrimal: 'Patent', Motility: 'Full',
  Conjunctiva: 'Normal', Cornea: 'Clear', 'Anterior Chamber': 'Deep & Quiet', Iris: 'Normal Pattern', Pupil: 'Round & Reactive', Lens: 'Clear',
  Vitreous: 'Clear', Disc: 'Healthy', Macula: 'Normal', Vessels: 'Normal', 'Peripheral Retina': 'Attached',
};

const EXAM_STRUCT_LABEL = { CDR: 'C.D Ratio' };

// Pivoted RE/LE rows (label | RE | LE), matching the Vision & Intraocular
// Pressure table's layout rather than one row per eye.
//
// mode 'abnormalOnly' (External Examination, Anterior Segment): a
// structure is only shown when at least one eye deviates from normal --
// a case sheet listing every structure as "Normal" is noise. The other
// eye still shows "Normal" alongside it for a complete row.
//
// mode 'anyData' (Posterior Segment): shown whenever either eye has
// anything recorded at all, normal or not -- Posterior/CDR findings are
// specialist, surgery-relevant readings a doctor wants on the printed
// record regardless of whether they happen to be normal.
//
// Handles both the current staged shape ({without:{...}, with:{...}})
// and the legacy flat shape from before dilatation staging existed.
function summarizeExamRegionPivoted(findingsJson, structs, mode) {
  const isStaged = findingsJson && (findingsJson.without || findingsJson.with);
  const stages = isStaged
    ? [['without', 'Without Dilatation'], ['with', 'With Dilatation']]
    : [[null, null]];

  const rows = [];
  stages.forEach(([stageKey, stageLabel]) => {
    const stageData = stageKey ? findingsJson[stageKey] : findingsJson;
    structs.forEach((struct) => {
      const f = stageData?.[struct] || {};
      const reRaw = f.re || '';
      const leRaw = f.le || '';
      const reCustom = f.re_custom || '';
      const leCustom = f.le_custom || '';
      const normal = EXAM_NORMAL_VALUE[struct];
      const reIsNormal = (!reRaw || reRaw === normal) && !reCustom;
      const leIsNormal = (!leRaw || leRaw === normal) && !leCustom;

      if (mode === 'abnormalOnly') {
        if (reIsNormal && leIsNormal) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || 'Normal',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || 'Normal',
        });
      } else {
        if (!reRaw && !leRaw && !reCustom && !leCustom) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || '--',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || '--',
        });
      }
    });
  });
  return rows;
}

const GONIO_ROW_DEFS = [
  { key: 'angle', label: 'Angle Configuration' },
  { key: 'ptm', label: 'PTM Pigmentation' },
  { key: 'iris', label: 'Iris Configuration' },
];

// Same pivoted RE/LE shape as summarizeExamRegionPivoted, but Gonioscopy
// is stored flat ({angle_re, angle_le, ...}) rather than per-structure,
// so it needs its own row builder. Shown whenever either eye has
// anything recorded.
function buildGonioscopyRows(gonioFindings) {
  const rows = [];
  if (!gonioFindings) return rows;
  // Gonioscopy used to be recorded in two passes (without/with dilatation);
  // it's now a single flat pass. Legacy staged records: read "without"
  // first (it was always the primary pass), falling back to "with" so
  // nothing already recorded is lost.
  const flat = (gonioFindings.without || gonioFindings.with) ? (gonioFindings.without || gonioFindings.with) : gonioFindings;
  GONIO_ROW_DEFS.forEach(({ key, label }) => {
    const re = flat[`${key}_re`];
    const le = flat[`${key}_le`];
    if (!re && !le) return;
    rows.push({ structure: label, re: re || '--', le: le || '--' });
  });
  return rows;
}

// Frequency-shorthand translation and taper-schedule grouping is
// imported at the top of this file (lib/prescriptionFormatting.js).

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, examination, diagnoses, prescriptions, followup, surgicalCase }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const distReRow = pickRxRow(assessment, 're', 'dist');
  const distLeRow = pickRxRow(assessment, 'le', 'dist');
  const nearReRow = pickRxRow(assessment, 're', 'near');
  const nearLeRow = pickRxRow(assessment, 'le', 'near');
  const distRe = distReRow.cells;
  const distLe = distLeRow.cells;
  const nearRe = nearReRow.cells;
  const nearLe = nearLeRow.cells;
  const cellHasData = (c) => c.sph !== '--' || c.cyl !== '--' || c.axis !== '--' || c.va !== '--';
  const hasDistRx = cellHasData(distRe) || cellHasData(distLe);
  const hasNearRx = cellHasData(nearRe) || cellHasData(nearLe);
  // Whichever eye actually supplied the row decides the label -- if
  // both eyes came from the same source this is just that source; if
  // they differed (rare), RE's source wins since it's listed first.
  const distSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(distRe) ? distReRow.source : distLeRow.source];
  const nearSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(nearRe) ? nearReRow.source : nearLeRow.source];

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

  // ── HISTORY -- Chief Complaint already existed; Ocular/Medical/Family/
  // Drug History and Allergy were captured on the encounter but never
  // made it onto the printed case sheet. ──
  const historyLines = [
    { label: 'Ocular History', items: encounter.ocular_history },
    { label: 'Medical History', items: encounter.medical_history },
    { label: 'Family History', items: encounter.family_history },
    { label: 'Drug History', items: encounter.drug_history },
    { label: 'Allergy', items: encounter.allergy },
  ].filter((h) => h.items && h.items.length > 0).map((h) => ({ label: h.label, text: h.items.join(', ') }));

  // ── OPTOMETRY -- previously only unaided/glasses vision, IOP, and
  // final refraction ("readings") made it onto the case sheet. Pinhole,
  // near vision, IOP method, additional pre-op tests, and the
  // optometrist's own recorded observations were captured but never
  // printed. ──
  const additionalTests = [
    { label: 'K1 (RE/LE)', value: (assessment?.add_k1_re || assessment?.add_k1_le) ? `${assessment?.add_k1_re || '--'} / ${assessment?.add_k1_le || '--'}` : null },
    { label: 'K2 (RE/LE)', value: (assessment?.add_k2_re || assessment?.add_k2_le) ? `${assessment?.add_k2_re || '--'} / ${assessment?.add_k2_le || '--'}` : null },
    { label: 'Axial Length (RE/LE)', value: (assessment?.add_axial_length_re || assessment?.add_axial_length_le) ? `${assessment?.add_axial_length_re || '--'} / ${assessment?.add_axial_length_le || '--'}` : null },
    { label: 'Pachymetry (RE/LE)', value: (assessment?.add_pachymetry_re || assessment?.add_pachymetry_le) ? `${assessment?.add_pachymetry_re || '--'} / ${assessment?.add_pachymetry_le || '--'}` : null },
    { label: 'Schirmer (RE/LE)', value: (assessment?.add_schirmer_re || assessment?.add_schirmer_le) ? `${assessment?.add_schirmer_re || '--'} / ${assessment?.add_schirmer_le || '--'}` : null },
    { label: 'Color Vision (RE/LE)', value: (assessment?.add_color_vision_re || assessment?.add_color_vision_le) ? `${assessment?.add_color_vision_re || '--'} / ${assessment?.add_color_vision_le || '--'}` : null },
    { label: 'Syringing (RE/LE)', value: (assessment?.add_syringing_re || assessment?.add_syringing_le) ? `${assessment?.add_syringing_re || '--'} / ${assessment?.add_syringing_le || '--'}` : null },
  ].filter((t) => t.value);

  // ── EXAMINATION -- doctor's own clinical exam (External / Anterior /
  // Posterior Segment) was captured but not printed at all. Normal
  // findings are deliberately left off -- only what's actually abnormal
  // is worth a doctor's or reviewer's attention on the printed sheet. ──
  const externalRows = examination ? summarizeExamRegionPivoted(examination.external_findings, ['Lids', 'Adnexa', 'Lacrimal', 'Motility'], 'abnormalOnly') : [];
  const anteriorRows = examination ? summarizeExamRegionPivoted(examination.anterior_findings, ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'], 'abnormalOnly') : [];
  const posteriorRows = examination ? summarizeExamRegionPivoted(examination.posterior_findings, ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'], 'anyData') : [];
  const hasApplanation = !!(examination?.applanation_re || examination?.applanation_le);
  const gonioscopyRows = examination ? buildGonioscopyRows(examination.gonioscopy_findings) : [];

  const examExtra = [
    { label: 'Remarks (RE)', value: examination?.remarks_re },
    { label: 'Remarks (LE)', value: examination?.remarks_le },
  ].filter((e) => e.value);

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed letterhead (hospital header already on
    // the paper) -- hide the digital header and leave blank space
    // matching the letterhead's own header height instead.
    hide_header: !!settings.case_sheet_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || (encounter.chief_complaint_chips || []).join(', ') || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,
    hx_hopi: encounter.hx_hopi || null,
    hasHistory: historyLines.length > 0,
    historyLines,

    hasVision: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided || assessment?.re_dist_glasses || assessment?.le_dist_glasses || assessment?.re_dist_ph || assessment?.le_dist_ph || assessment?.re_near_unaided || assessment?.le_near_unaided || reIop != null || leIop != null),
    hasViUnaided: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided),
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    hasViGlasses: !!(assessment?.re_dist_glasses || assessment?.le_dist_glasses),
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    hasViPh: !!(assessment?.re_dist_ph || assessment?.le_dist_ph),
    re_vision_ph: assessment?.re_dist_ph || '--',
    le_vision_ph: assessment?.le_dist_ph || '--',
    hasViNear: !!(assessment?.re_near_unaided || assessment?.le_near_unaided),
    re_vision_near: assessment?.re_near_unaided || '--',
    le_vision_near: assessment?.le_near_unaided || '--',
    hasIop: reIop != null || leIop != null,
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    iop_method: assessment?.iop_method || null,
    hasDistRx,
    dist_rx_source: distSourceLabel,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    hasNearRx,
    near_rx_source: nearSourceLabel,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    hasAdditionalTests: additionalTests.length > 0,
    additionalTests,
    hasOptObservations: false,
    optObservations: '',

    hasExamination: externalRows.length > 0 || anteriorRows.length > 0 || posteriorRows.length > 0 || hasApplanation || gonioscopyRows.length > 0 || examExtra.length > 0,
    hasExternal: externalRows.length > 0,
    externalRows,
    hasAnterior: anteriorRows.length > 0,
    anteriorRows,
    hasPosterior: posteriorRows.length > 0,
    posteriorRows,
    hasApplanation,
    applanation_re: examination?.applanation_re || '--',
    applanation_le: examination?.applanation_le || '--',
    hasGonioscopy: gonioscopyRows.length > 0,
    gonioscopyRows,
    hasExamExtra: examExtra.length > 0,
    examExtra,

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    // Surgery advice, if this encounter marked the patient for surgery
    // -- shows what was advised, which eye, and the patient's decision
    // at the time (Willing / Needs Time to Decide / Not Willing etc).
    hasSurgery: !!surgicalCase,
    surgery_procedure_name: surgicalCase?.procedure_name || null,
    surgery_eye: EYE_LABEL[surgicalCase?.eye] || surgicalCase?.eye || null,
    surgery_decision: surgicalCase?.decision || null,

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: groupPrescriptionsForPrint(prescriptions),

    advice: encounter.patient_instructions || null,
    followup_text: followupParts.length > 0 ? followupParts.join(' ') : null,
  };
}

// ── DISCHARGE SUMMARY -- printed from Post-op / Recovery once a patient
//    has been discharged. Mirrors what used to be a hardcoded page
//    (app/discharge-summary-print) so it's now editable like every
//    other print template and picks up hospital branding/logo. ──
export async function renderDischargeSummaryHtml(episodeId) {
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, visit_id, patients:patient_id(uhid, first_name, last_name, mobile, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error || !episode) return { error: 'Episode not found.' };
  if (!episode.discharge_date) return { error: "This patient hasn't been discharged yet." };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, not
    // biometry_records (which no longer has any "approved" concept).
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc?.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  const settings = await getHospitalSettings();
  const context = buildDischargeSummaryContext(settings, {
    patient: sc?.patients,
    surgeon: sc?.profiles,
    procedureName: sc?.procedure_name,
    eye: sc?.eye,
    episode,
    intraop,
    biometry: approval ? [approval] : [],
    meds: meds || [],
    followups: followups || [],
  });

  const template = await getPrintTemplate('discharge_summary');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildDischargeSummaryContext(settings, { patient, surgeon, procedureName, eye, episode, intraop, biometry, meds, followups }) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    surgeon_name: surgeon?.full_name || '--',
    admission_date: fmtDate(episode.admission_date),
    surgery_date: fmtDate(episode.surgery_date),
    discharge_date: fmtDate(episode.discharge_date),

    procedure_name: procedureName, eye,
    iol_lines: biometry.map((p) => ({
      eye: p.eye,
      text: `${intraop?.implant_power || p.power} D -- ${p.master_iol_catalog?.category || ''}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
    })),

    hasMedications: meds.length > 0,
    medications: meds.map((m) => ({ name: m.name, sig: m.sig })),

    hasDischargeNotes: !!episode.discharge_notes,
    discharge_notes: episode.discharge_notes,
    discharge_instructions: episode.discharge_instructions || 'As advised by the surgeon.',

    followups: followups.map((f) => ({ visit_label: f.visit_label, date: fmtDate(f.scheduled_date), status: f.status })),
  };
}

// ── INVESTIGATION REPORT -- printed for a completed (or unable-to-
//    perform) investigation order. Field labels mirror exactly what
//    the Investigation Workspace saves (investigation-types.js), so
//    the printed report always matches what's on screen. ──
export async function renderInvestigationHtml(orderId) {
  const supabase = await createClient();

  const { data: order, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, doctor_id, visits(patients(uhid, first_name, last_name, mobile, age, gender)), profiles:doctor_id(full_name))')
    .eq('id', orderId)
    .single();
  if (error || !order) return { error: 'Investigation not found.' };

  const [{ data: completedBy }, { data: verifiedBy }] = await Promise.all([
    order.completed_by ? supabase.from('profiles').select('full_name').eq('id', order.completed_by).maybeSingle() : Promise.resolve({ data: null }),
    order.verified_by ? supabase.from('profiles').select('full_name').eq('id', order.verified_by).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const settings = await getHospitalSettings();
  const patient = order.encounters?.visits?.patients;
  const type = matchInvestigationType(order.name);
  const fields = getFullFieldValues(type, order.result_data);

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    investigation_name: order.name, investigation_type: type, eye: order.eye,
    doctor_name: order.encounters?.profiles?.full_name || '--',
    ordered_date: fmtDate(order.created_at), completed_date: order.completed_at ? fmtDate(order.completed_at) : '--',

    isUnable: order.status === 'Cancelled' && !!order.unable_reason,
    unable_reason: order.unable_reason,

    hasFields: fields.length > 0,
    fields,

    hasNotes: !!order.result_notes,
    result_notes: order.result_notes,

    technician_name: completedBy?.full_name || '--',
    hasVerifiedBy: !!verifiedBy?.full_name,
    verified_by_name: verifiedBy?.full_name || null,
  };

  const template = await getPrintTemplate('investigation_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICINE PRESCRIPTION -- printed from Pharmacy, independent of
//    the bill. This is the patient-facing dosage sheet: what to take,
//    how much, how often (in plain language, not medical shorthand),
//    and for how long -- not prices or invoice numbers. Reuses the
//    same plainFrequency()/groupPrescriptionsForPrint() logic as the
//    OPD Case Sheet's own Prescription section, so the two always
//    read identically wherever a patient sees them. ──
export async function renderMedicinePrescriptionHtml(visitId) {
  const supabase = await createClient();

  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, doctor_id, patients(uhid, first_name, last_name, age, gender, mobile), profiles:doctor_id(full_name, registration_no)')
    .eq('id', visitId)
    .single();
  if (error || !visit) return { error: 'Visit not found.' };

  const { data: rows } = await supabase
    .from('prescriptions')
    .select('drug_name, eye, dosage, frequency, duration, taper_group_id, taper_step, encounters!inner(visit_id)')
    .eq('encounters.visit_id', visitId)
    .order('created_at', { ascending: true });

  const prescriptions = groupPrescriptionsForPrint(
    (rows || []).map((r) => ({ drug: r.drug_name, eye: r.eye, dosage: r.dosage, frequency: r.frequency, duration: r.duration, taper_group_id: r.taper_group_id, taper_step: r.taper_step }))
  );

  const settings = await getHospitalSettings();
  const patient = visit.patients;

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid || '--', patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_mobile: patient?.mobile || '--',
    visit_number: visit.visit_number || '--',
    print_date: fmtDate(new Date().toISOString()),

    doctor_name: visit.profiles?.full_name || '--',
    doctor_regn_no: visit.profiles?.registration_no || '--',

    hasPrescriptions: prescriptions.length > 0,
    prescriptions,
  };

  const template = await getPrintTemplate('medicine_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICAL FITNESS FORM -- bilingual pre-op certificate, printed from
// the Medical Fitness module once a decision is made. Checkboxes are
// rendered as filled/empty Unicode box characters based on form_data. ──
function chk(flag) {
  return flag ? '\u2611' : '\u2610';
}

export async function renderMedicalFitnessFormHtml(referralId) {
  const supabase = await createClient();

  const { data: referral, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(patients(first_name, last_name, uhid, age, gender)), surgical_cases(procedure_name)')
    .eq('id', referralId)
    .single();
  if (error || !referral) return { error: 'Referral not found.' };

  const patient = referral.visits?.patients;
  const fd = referral.form_data || {};
  const sys = fd.systemicHistory || {};
  const med = fd.currentMedications || {};
  const allergy = fd.allergies || {};
  const vitals = fd.vitals || {};
  const inv = fd.investigations || {};
  const cert = fd.certification || {};

  const settings = await getHospitalSettings();

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone,
    logo_html: logoHtml(settings),

    patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim() || '--',
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_uhid: patient?.uhid || '--',
    surgery_type: referral.surgical_cases?.procedure_name || '--',

    box_diabetes: chk(sys.diabetes), box_hypertension: chk(sys.hypertension),
    box_heart: chk(sys.heartDisease), box_thyroid: chk(sys.thyroid),
    box_asthma: chk(sys.asthma), box_kidney: chk(sys.kidneyDisease),
    box_systemic_other: chk(!!sys.other), systemic_other_text: sys.other || '',

    previous_surgery: fd.previousSurgeryHistory || '',

    box_med_antidiabetic: chk(med.antiDiabetic), box_med_bp: chk(med.bpMedicines),
    box_med_bloodthinners: chk(med.bloodThinners),
    box_med_other: chk(!!med.other), med_other_text: med.other || '',

    box_allergy_none: chk(allergy.none), box_allergy_yes: chk(allergy.yes), allergy_details: allergy.details || '',
    allergy_notes: allergy.notes || '',

    vital_bp: vitals.bp || '--', vital_pulse: vitals.pulse || '--',
    vital_spo2: vitals.spo2 || '--', vital_blood_sugar: vitals.bloodSugar || '--',
    vital_notes: vitals.notes || '',

    inv_hb: inv.hb || '--', inv_rbs: inv.rbs || '--', inv_fbs: inv.fbs || '--', inv_ppbs: inv.ppbs || '--',
    box_hiv_nonreactive: chk(inv.hiv === 'Non-Reactive'), box_hiv_reactive: chk(inv.hiv === 'Reactive'),
    box_hbsag_nonreactive: chk(inv.hbsag === 'Non-Reactive'), box_hbsag_reactive: chk(inv.hbsag === 'Reactive'),
    inv_other: inv.other || '--',

    fitness_word: referral.status === 'Not Fit' ? 'not fit' : 'fit',
    fitness_word_hi: referral.status === 'Not Fit' ? '\u0905\u0928\u092b\u093f\u091f' : '\u092b\u093f\u091f',
    fitness_notes: referral.fitness_notes || '',

    doctor_name: cert.doctorName || '--', doctor_qualification: cert.qualification || '--',
    doctor_regn_no: cert.registrationNo || '--',
    cert_date: referral.cleared_at ? fmtDate(referral.cleared_at) : fmtDate(new Date().toISOString()),
  };

  const template = await getPrintTemplate('medical_fitness_form');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}
VEDA_EOF_11

echo "Files written. No further DB migration needed -- price column added and manufacturer column dropped directly on both Supabase projects (production + training) already."
echo "Deploy script done."
