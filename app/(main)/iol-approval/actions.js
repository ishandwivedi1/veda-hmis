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
    .select('id, patient_id, procedure_name, eye, package_id, surgery_code, status, patients:patient_id(first_name, last_name, uhid, age, gender, mobile), master_packages:package_id(name, iol_category), profiles:surgeon_id(full_name)')
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
