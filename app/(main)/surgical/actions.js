'use server';

import { createClient } from '@/lib/supabase-server';

export async function markForSurgery(patientId, encounterId, procedureName, eye) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId, encounter_id: encounterId, procedure_name: procedureName, eye,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function getSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients(first_name, last_name, uhid), master_packages(name, price)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function getPackagesForSelection() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function updateChecklistItem(caseId, field, value) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ [field]: value }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc.consent_taken || !sc.biometry_done || !sc.fitness_cleared) {
    return { error: 'All three checklist items must be complete before scheduling.' };
  }
  if (!sc.package_id) {
    return { error: 'Select a package first.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').ilike('designation', '%ophthalmologist%').eq('status', 'Active');
  return data || [];
}

export async function scheduleOT(caseId, surgeonId, date, time, notes) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: surgeonId || null, scheduled_date: date, scheduled_time: time || null, notes,
  });
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles(full_name)')
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data;
}

export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

