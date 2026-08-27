'use server';

import { createClient } from '@/lib/supabase-server';

// ── DASHBOARD: every referral (all statuses), so the dashboard can show
// stats across Pending/Cleared/Not Fit -- filtering to a specific stage
// happens client-side, same pattern as Counselling's own dashboard. ──
// ── HISTORY: completed referrals (Cleared / Not Fit) ──
export async function getMedicalFitnessHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const todayStartUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();

  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(first_name, salutation, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .in('status', ['Cleared', 'Not Fit'])
    // Cases cleared today live in the "Cleared Today" section instead
    // (see getMedicalFitnessClearedToday) -- History is everything
    // before today, so a same-day clearance isn't buried in a long
    // list right after being decided.
    .lt('cleared_at', todayStartUTC)
    .order('cleared_at', { ascending: false });

  if (error) return [];

  const doctorIds = [...new Set((data || []).map((r) => r.cleared_by).filter(Boolean))];
  let doctorMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { doctorMap[p.id] = p.full_name; });
  }

  return (data || [])
    .filter((r) => r.visits)
    .map((r) => ({ ...r, clearedByName: doctorMap[r.cleared_by] || '--' }));
}

// ── CLEARED TODAY -- same-day decisions (Cleared or Not Fit), kept
// separate from full History (see above) so today's outcomes are
// visible at a glance without scrolling a long list. ──
export async function getMedicalFitnessClearedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(first_name, salutation, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .in('status', ['Cleared', 'Not Fit'])
    .gte('cleared_at', startUTC)
    .lte('cleared_at', endUTC)
    .order('cleared_at', { ascending: false });

  if (error) return [];

  const doctorIds = [...new Set((data || []).map((r) => r.cleared_by).filter(Boolean))];
  let doctorMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { doctorMap[p.id] = p.full_name; });
  }

  return (data || [])
    .filter((r) => r.visits)
    .map((r) => ({ ...r, clearedByName: doctorMap[r.cleared_by] || '--' }));
}

// ── QUEUE (TAB 1): patients referred by Counselling, awaiting doctor
// review. Reads medical_fitness_referrals directly (same architecture
// as the Biometry Queue) rather than the front-desk queue_entries
// system. ──
export async function getMedicalFitnessQueue() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, visit_type, patients(first_name, salutation, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .eq('status', 'Pending Review')
    .order('referred_at', { ascending: true });

  if (error) return [];
  return (data || []).filter((r) => r.visits);
}

// ── Used by the Doctor Dashboard's Medical Fitness widget -- pending
// referrals mapped to today's visits only. ──
export async function getMedicalFitnessToday() {
  const rows = await getMedicalFitnessQueue();
  const today = new Date().toISOString().slice(0, 10);
  return rows.filter((r) => r.referred_at?.slice(0, 10) === today);
}

// ── WORKSPACE: full clinical picture + ability to order investigations ──
export async function getMedicalFitnessDetail(referralId) {
  const supabase = await createClient();
  const { data: referral, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(id, first_name, salutation, last_name, uhid, age, gender)), surgical_cases(procedure_name, eye, priority, decision)')
    .eq('id', referralId)
    .single();

  if (error) return { error: error.message };

  const patientId = referral.visits.patients.id;

  const [{ data: currentDiagnoses }, { data: investigations }, { data: externalTestsRaw }, { data: diagnosisHistoryRaw }, { data: referredByProfile }, { data: clearedByProfile }] = await Promise.all([
    referral.encounter_id
      ? supabase.from('diagnoses').select('*').eq('encounter_id', referral.encounter_id).order('created_at')
      : Promise.resolve({ data: [] }),
    referral.encounter_id
      ? supabase.from('investigation_orders').select('*').eq('encounter_id', referral.encounter_id).order('created_at', { ascending: false })
      : Promise.resolve({ data: [] }),
    // External investigations (blood work, HIV test, etc) live on the
    // surgical case, not the encounter -- same table Surgical Journey
    // uses. Without this, anything ordered there was invisible here,
    // even though it's exactly the kind of pre-op workup a doctor
    // reviews before signing off on fitness.
    referral.surgical_case_id
      ? supabase.from('external_investigations').select('*').eq('surgical_case_id', referral.surgical_case_id).order('created_at', { ascending: true })
      : Promise.resolve({ data: [] }),
    // Longitudinal (cross-visit) diagnosis history, same pattern as Consultation.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    referral.referred_by
      ? supabase.from('profiles').select('full_name').eq('id', referral.referred_by).maybeSingle()
      : Promise.resolve({ data: null }),
    referral.cleared_by
      ? supabase.from('profiles').select('full_name').eq('id', referral.cleared_by).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const externalTestIds = (externalTestsRaw || []).map((t) => t.id);
  let externalAttachmentCounts = {};
  if (externalTestIds.length > 0) {
    const { data: attachments } = await supabase
      .from('clinical_attachments')
      .select('entity_id')
      .eq('entity_type', 'external_investigation')
      .in('entity_id', externalTestIds);
    (attachments || []).forEach((a) => { externalAttachmentCounts[a.entity_id] = (externalAttachmentCounts[a.entity_id] || 0) + 1; });
  }
  const externalTests = (externalTestsRaw || []).map((t) => ({ ...t, attachmentCount: externalAttachmentCounts[t.id] || 0 }));

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== referral.encounter_id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  return {
    referral,
    currentDiagnoses: currentDiagnoses || [],
    investigations: investigations || [],
    externalTests,
    diagnosisHistory,
    referredByName: referredByProfile?.full_name || '--',
    clearedByName: clearedByProfile?.full_name || null,
  };
}

// Same master list Consultation/Counselling's investigation pickers use.
export async function getInvestigationMasterOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

export async function orderFitnessInvestigation(referralId, encounterId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Select or enter an investigation.' };
  if (!encounterId) return { error: 'This referral has no linked clinical encounter to attach the investigation to.' };

  const { data: userData } = await supabase.auth.getUser();
  // Claim the referral for whichever doctor is the first to open and
  // act on it, without overwriting if someone already has.
  await supabase.from('medical_fitness_referrals').update({ reviewing_doctor_id: userData?.user?.id || null }).eq('id', referralId).is('reviewing_doctor_id', null);

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId, name: values.name, eye: values.eye || 'N/A', priority: values.priority || 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeFitnessInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function clearFitness(referralId, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: referral } = await supabase.from('medical_fitness_referrals').select('surgical_case_id').eq('id', referralId).single();
  if (!referral) return { error: 'Referral not found.' };

  const { error } = await supabase.from('medical_fitness_referrals').update({
    status: 'Cleared', fitness_notes: notes?.trim() || null,
    cleared_by: userData?.user?.id || null, cleared_at: new Date().toISOString(),
    reviewing_doctor_id: userData?.user?.id || null,
  }).eq('id', referralId);
  if (error) return { error: error.message };

  // The one thing Counselling's readiness checklist has always checked --
  // now set by the doctor's actual clearance instead of a self-service tick.
  await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', referral.surgical_case_id);
  return { success: true };
}

export async function markNotFit(referralId, notes) {
  const supabase = await createClient();
  if (!notes || !notes.trim()) return { error: 'Notes are required when marking a patient not fit -- Counselling needs to know why.' };
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('medical_fitness_referrals').update({
    status: 'Not Fit', fitness_notes: notes.trim(),
    cleared_by: userData?.user?.id || null, cleared_at: new Date().toISOString(),
    reviewing_doctor_id: userData?.user?.id || null,
  }).eq('id', referralId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FITNESS FORM (Medical Fitness Form for Cataract Surgery) --
// structured bilingual form data saved as the doctor fills it in
// (systemic history, medications, allergies, vitals, investigation
// summary values, physician certification). Printed as a PDF for the
// patient file once a decision is made. ──
export async function saveFitnessFormDraft(referralId, formData) {
  const supabase = await createClient();
  const { error } = await supabase.from('medical_fitness_referrals').update({ form_data: formData }).eq('id', referralId);
  if (error) return { error: error.message };
  return { success: true };
}

// Saves the form and records the clearance decision in one step --
// what the doctor actually uses day to day, instead of a separate
// save-then-decide flow.
export async function submitFitnessForm(referralId, formData, decision, notes) {
  const supabase = await createClient();
  if (!['Cleared', 'Not Fit'].includes(decision)) return { error: 'Invalid decision.' };
  if (decision === 'Not Fit' && !notes?.trim()) return { error: 'Notes are required when marking not fit.' };

  const { data: userData } = await supabase.auth.getUser();
  const { data: referral } = await supabase.from('medical_fitness_referrals').select('surgical_case_id').eq('id', referralId).single();
  if (!referral) return { error: 'Referral not found.' };

  const { error } = await supabase.from('medical_fitness_referrals').update({
    status: decision, fitness_notes: notes?.trim() || null, form_data: formData,
    cleared_by: userData?.user?.id || null, cleared_at: new Date().toISOString(),
    reviewing_doctor_id: userData?.user?.id || null,
  }).eq('id', referralId);
  if (error) return { error: error.message };

  if (decision === 'Cleared') {
    await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', referral.surgical_case_id);
  }
  return { success: true };
}

// Pre-fills the physician certification block with whoever's signed
// in -- doctor still confirms/edits before printing.
export async function getCurrentDoctorProfile() {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return null;
  const { data } = await supabase.from('profiles').select('full_name, registration_no').eq('id', userData.user.id).maybeSingle();
  return data || null;
}

