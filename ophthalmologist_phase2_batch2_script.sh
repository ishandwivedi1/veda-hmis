mkdir -p "app/(main)/consultation" "app/(main)/consultation/[id]"

cat > "app/(main)/consultation/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let { data: encounter } = await supabase
    .from('encounters')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'In Consultation')
    .maybeSingle();

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await addAudit(supabase, encounter.id, 'Encounter started', userData?.user?.id);
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const patientId = entry.visits.patients.id;

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('workflow_requests').select('*').eq('visit_id', visitId).order('requested_at', { ascending: false }),
    supabase.from('encounter_audit_log').select('*').eq('encounter_id', encounter.id).order('created_at', { ascending: false }),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounter.id).maybeSingle(),
    // Longitudinal (cross-visit) diagnosis history: every diagnosis this
    // patient has, across all their encounters, via visits -> encounters.
    supabase
      .from('visits')
      .select('id, encounters(id, created_at, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.created_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: auditLog || [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
  };
}

// ── EXAMINATION (Section 12, M19 Examination tab) ──
export async function saveExamination(examinationId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Examination saved', userData?.user?.id);
  return { success: true };
}

// ── STRUCTURED HISTORY (Section 11.9) ──
// Batched save, same pattern as Examination -- not per-keystroke.
export async function saveHistory(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({
      chief_complaint: fields.chiefComplaint,
      chief_complaint_chips: fields.chiefComplaintChips,
      hx_duration: fields.hxDuration,
      hx_laterality: fields.hxLaterality,
      hx_hopi: fields.hxHopi,
      ocular_history: fields.ocularHistory,
      medical_history: fields.medicalHistory,
      family_history: fields.familyHistory,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye}, ${values.category})`, userData?.user?.id);
  return { success: true };
}

export async function removeDiagnosis(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Diagnosis removed', userData?.user?.id);
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Prescription added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePrescription(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Prescription removed', userData?.user?.id);
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Investigation ordered: ${values.name} (${values.eye}, ${values.priority})`, userData?.user?.id);
  return { success: true };
}

export async function removeInvestigation(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Investigation removed', userData?.user?.id);
  return { success: true };
}

// ── WORKFLOW REQUESTS (Biometry / Medical Fitness / Counselling) ──
// Independent, non-exclusive toggles -- a visit can have more than one
// open at a time, unlike Dilation/Investigation which move the queue
// entry itself. Toggling an already-open request cancels it.
export async function toggleWorkflowRequest(visitId, encounterId, kind) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: existing } = await supabase
    .from('workflow_requests')
    .select('*')
    .eq('visit_id', visitId)
    .eq('kind', kind)
    .eq('status', 'Requested')
    .maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('workflow_requests')
      .update({ status: 'Cancelled', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
      .eq('id', existing.id);
    if (error) return { error: error.message };
    await addAudit(supabase, encounterId, `Workflow request cancelled: ${kind}`, userData?.user?.id);
    return { success: true, active: false };
  }

  const { error } = await supabase.from('workflow_requests').insert({
    visit_id: visitId, encounter_id: encounterId, kind, requested_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Workflow requested: ${kind}`, userData?.user?.id);
  return { success: true, active: true };
}

// Mark a workflow request (Biometry/Fitness/Counselling) as done --
// used by whichever staff member actually completes it (e.g. the
// counsellor marking a Counselling request resolved).
export async function completeWorkflowRequest(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('workflow_requests')
    .update({ status: 'Completed', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
    .eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Workflow request marked complete', userData?.user?.id);
  return { success: true };
}

// ── MANAGEMENT PLAN EXPANSION (Ch.14) ──
export async function addOpticalAdvice(encounterId, advice) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_optical_advice').insert({ encounter_id: encounterId, advice, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Optical advice added: ${advice}`, userData?.user?.id);
  return { success: true };
}

export async function removeOpticalAdvice(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_optical_advice').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Optical advice removed', null);
  return { success: true };
}

export async function addProcedure(encounterId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Procedure planned: ${name} (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function removeProcedure(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_procedures').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Procedure removed', null);
  return { success: true };
}

export async function addReferral(encounterId, destination, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_referrals').insert({ encounter_id: encounterId, destination, reason, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Referral added: ${destination}`, userData?.user?.id);
  return { success: true };
}

export async function removeReferral(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_referrals').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Referral removed', null);
  return { success: true };
}

export async function addCounsellingItem(encounterId, topic) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_counselling_items').insert({ encounter_id: encounterId, topic, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Counselling topic added: ${topic}`, userData?.user?.id);
  return { success: true };
}

export async function removeCounsellingItem(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Counselling topic removed', null);
  return { success: true };
}

// Any plan item (optical/procedure/referral/counselling) marked done --
// used from the Action Tracker tab.
export async function completePlanItem(table, id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ status: 'Done' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Plan item marked done', null);
  return { success: true };
}

// Follow-up is one record per encounter -- upsert by encounter_id.
export async function saveFollowup(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_followups')
    .upsert(
      { encounter_id: encounterId, after_period: fields.after, visit_type: fields.type, clinic: fields.clinic, instructions: fields.instructions, created_by: userData?.user?.id || null },
      { onConflict: 'encounter_id' }
    );
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Follow-up scheduled: ${fields.after} -- ${fields.type}`, userData?.user?.id);
  return { success: true };
}

export async function savePatientInstructions(encounterId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ patient_instructions: instructions }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Encounter completed', userData?.user?.id);

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'dilate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Dilation', userData?.user?.id);
  return result;
}

export async function sendForInvestigationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'investigate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Investigation', userData?.user?.id);
  return result;
}


EOF

cat > "app/(main)/consultation/[id]/consultation-form.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  toggleWorkflowRequest,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  addReferral,
  removeReferral,
  addCounsellingItem,
  removeCounsellingItem,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
} from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/surgical/actions';
import ExaminationTab from './examination-tab';
import HistoryTab from './history-tab';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('history');
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [counselTopic, setCounselTopic] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
  }, [data]);

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName.trim()) { setError('Procedure name is required.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    refresh();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleAddCounsel() {
    setError('');
    if (!counselTopic.trim()) { setError('Counselling topic is required.'); return; }
    const result = await addCounsellingItem(data.encounter.id, counselTopic);
    if (result.error) { setError(result.error); return; }
    setCounselTopic('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure.trim()) { setError('Procedure name is required.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleToggleWorkflow(kind) {
    setError('');
    const result = await toggleWorkflowRequest(data.entry.visits.id, data.encounter.id, kind);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const f = data.findings;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Completed' && i.status !== 'Verified');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  return (
    <div style={{ maxWidth: 1180, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Consultation -- {data.entry.token}</div>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.age} {patient.gender}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {f && (() => {
        const latestIop = (eye) => {
          const readings = (data.iopReadings || []).filter((r) => r.eye === eye);
          return readings.length ? readings[readings.length - 1].value : null;
        };
        const reIop = latestIop('RE');
        const leIop = latestIop('LE');
        const reSph = f.ref_final_re_sph || f.ref_obj_re_sph;
        const leSph = f.ref_final_le_sph || f.ref_obj_le_sph;
        const reCyl = f.ref_final_re_cyl || f.ref_obj_re_cyl;
        const leCyl = f.ref_final_le_cyl || f.ref_obj_le_cyl;
        return (
          <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>
              Optometry Findings <span style={{ fontWeight: 400, color: 'var(--g400)' }}>({f.va_scale})</span>
            </div>
            <div style={{ fontSize: 12, color: 'var(--g600)' }}>
              VA: RE {f.re_dist_unaided || '--'} / LE {f.le_dist_unaided || '--'} &nbsp;&nbsp;
              IOP: RE {reIop ?? '--'} / LE {leIop ?? '--'} &nbsp;&nbsp;
              Sph: RE {reSph || '--'} / LE {leSph || '--'} &nbsp;&nbsp;
              Cyl: RE {reCyl || '--'} / LE {leCyl || '--'}
            </div>
            {f.observations_text && (
              <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 6 }}>Observations: {f.observations_text}</div>
            )}
          </div>
        );
      })()}

      {/* WORKFLOW CONTROLS -- Biometry / Medical Fitness / Counselling.
          Independent toggles: a patient can need more than one at once.
          Dilation/Investigation stay in the Actions bar below since
          those physically move the queue entry, not just flag a task. */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginBottom: 16 }}>
        <span style={{ fontSize: 11, fontWeight: 700, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.5px', marginRight: 4 }}>Request:</span>
        {Object.keys(WF_ITEMS).map((kind) => {
          const isActive = activeWorkflows.some((w) => w.kind === kind);
          return (
            <button
              key={kind}
              type="button"
              className="btn btn-sm"
              style={{
                background: isActive ? WF_ITEMS[kind].color : 'rgba(255,255,255,.08)',
                color: isActive ? '#0f172a' : '#e2e8f0',
                borderColor: isActive ? WF_ITEMS[kind].color : 'rgba(255,255,255,.2)',
                fontWeight: isActive ? 700 : 600,
              }}
              onClick={() => handleToggleWorkflow(kind)}
            >
              <i className={`ti ${WF_ITEMS[kind].icon}`}></i> {kind}{isActive ? ' -- Requested' : ''}
            </button>
          );
        })}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
        {/* MAIN COLUMN */}
        <div>
          {/* TABS */}
          <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-message" label="History" />
            <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
            <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
            <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />
          </div>

          {activeTab === 'history' && (
            <HistoryTab encounter={data.encounter} onSaved={refresh} />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              {/* DIAGNOSIS HISTORY (longitudinal, read-only, Section 13.15) */}
              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              {/* DIAGNOSIS */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Diagnosis</div>
                {data.diagnoses.map((d) => (
                  <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option>
                    <option value="OS">OS</option>
                    <option value="OU">OU</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              {/* PRESCRIPTION */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Prescription</div>
                {data.prescriptions.map((r) => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap' }}>
                  <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>
              </div>

              {/* INVESTIGATIONS */}
              <div className="card" style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Investigations</div>
                {data.investigations.map((i) => (
                  <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
                    <option>Routine</option><option>Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              {/* SURGERY */}
              <div className="card" style={{ marginBottom: 16 }}>
                {!showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Mark for Surgery</div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <input className="fi" placeholder="Procedure (e.g. Phacoemulsification + IOL)" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }} />
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                        <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                      </select>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              {/* MANAGEMENT PLAN EXPANSION (Ch.14) */}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div>
                  {/* OPTICAL ADVICE */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                    {data.opticalAdvice.map((o) => (
                      <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{o.advice}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                    </div>
                  </div>

                  {/* PROCEDURES */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Procedures</div>
                    {data.procedures.map((p) => (
                      <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['YAG Capsulotomy', 'Intravitreal Injection', 'FB Removal', 'Syringing'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setProcName(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Procedure name..." value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }} />
                      <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 70 }}>
                        <option>OD</option><option>OS</option><option>OU</option>
                      </select>
                      <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                    </div>
                  </div>
                </div>

                <div>
                  {/* REFERRAL */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                    {data.referrals.map((r) => (
                      <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                      <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                        <option value="">-- Destination --</option>
                        <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                      </select>
                      <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                    </div>
                  </div>

                  {/* COUNSELLING TOPICS */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-messages" style={{ color: 'var(--teal)' }}></i> Counselling Topics</div>
                    {data.counsellingItems.map((c) => (
                      <div key={c.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{c.topic}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeCounsellingItem(c.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Cataract counselling', 'Premium IOL discussion', 'Financial counselling', 'Consent education'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setCounselTopic(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Counselling topic..." value={counselTopic} onChange={(e) => setCounselTopic(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleAddCounsel}>Add</button>
                    </div>
                  </div>

                  {/* FOLLOW-UP */}
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                      <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                        <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                      </select>
                      <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                        <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                      </select>
                      <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                        <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                      </select>
                    </div>
                    <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                    {fuSaved && (
                      <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                        Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                      </div>
                    )}
                  </div>

                  {/* PATIENT INSTRUCTIONS */}
                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                    <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                    {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
                  </div>
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
              Send for Investigation
            </button>
          </div>
        </div>

        {/* RIGHT PANEL */}
        <div>
          {/* ENCOUNTER STATUS */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Encounter Status</div>
            <div style={{ fontSize: 12, color: 'var(--g600)', lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Status</span><span className="badge b-blue">{data.encounter.status}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(data.encounter.started_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>In progress</span><span style={{ fontWeight: 700 }}>{elapsedMin(data.encounter.started_at)}m</span></div>
            </div>
          </div>

          {/* OUTSTANDING TASKS */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list-checks" style={{ color: 'var(--amber)' }}></i> Outstanding Tasks</div>
            {openInvestigations.length === 0 && activeWorkflows.length === 0 && pendingRx.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding.</div>
            )}
            {openInvestigations.map((i) => (
              <div key={i.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i><span style={{ flex: 1 }}>{i.name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{i.status}</span>
              </div>
            ))}
            {activeWorkflows.map((w) => (
              <div key={w.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className={`ti ${WF_ITEMS[w.kind]?.icon || 'ti-clipboard'}`} style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{w.kind}</span><span className="badge b-amber" style={{ fontSize: 9 }}>Requested</span>
              </div>
            ))}
            {pendingRx.map((r) => (
              <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i><span style={{ flex: 1 }}>{r.drug_name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{r.status}</span>
              </div>
            ))}
          </div>

          {/* AUDIT LOG */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
            <div style={{ maxHeight: 260, overflowY: 'auto' }}>
              {data.auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
              {data.auditLog.map((a) => (
                <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
                  <div>{a.message}</div>
                </div>
              ))}
            </div>
          </div>
        </div>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/consultation/[id]/history-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { saveHistory } from '@/app/(main)/consultation/actions';

const CC_TEMPLATES = ['Diminution of vision', 'Watering', 'Pain', 'Redness', 'Headache', 'Floaters', 'Flashes', 'Double vision', 'Blurring', 'Follow-up'];
const OCULAR_HX = ['Cataract surgery', 'Glaucoma', 'Trauma', 'LASIK', 'Retinal disease', 'Laser procedure', 'Intravitreal injection'];
const MEDICAL_HX = ['Diabetes', 'Hypertension', 'Thyroid disease', 'Cardiac disease', 'Renal disease', 'Autoimmune'];
const FAMILY_HX = ['Glaucoma', 'High myopia', 'Retinal disorders', 'None known'];

function Chip({ label, selected, onClick }) {
  return (
    <span
      onClick={onClick}
      style={{
        padding: '3px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
        border: `1.5px solid ${selected ? 'var(--blue)' : 'var(--g200)'}`,
        background: selected ? 'var(--blue)' : '#fff',
        color: selected ? '#fff' : 'var(--g600)',
      }}
    >
      {label}
    </span>
  );
}

export default function HistoryTab({ encounter, onSaved }) {
  const [chiefComplaint, setChiefComplaint] = useState('');
  const [ccChips, setCcChips] = useState([]);
  const [duration, setDuration] = useState('');
  const [laterality, setLaterality] = useState('');
  const [hopi, setHopi] = useState('');
  const [ocular, setOcular] = useState([]);
  const [medical, setMedical] = useState([]);
  const [family, setFamily] = useState([]);
  const [drugAllergy, setDrugAllergy] = useState('');
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState('');

  useEffect(() => {
    if (!encounter) return;
    setChiefComplaint(encounter.chief_complaint || '');
    setCcChips(encounter.chief_complaint_chips || []);
    setDuration(encounter.hx_duration || '');
    setLaterality(encounter.hx_laterality || '');
    setHopi(encounter.hx_hopi || '');
    setOcular(encounter.ocular_history || []);
    setMedical(encounter.medical_history || []);
    setFamily(encounter.family_history || []);
    setDrugAllergy(encounter.hx_drug_allergy || '');
  }, [encounter]);

  function toggle(list, setList, val) {
    setList(list.includes(val) ? list.filter((v) => v !== val) : [...list, val]);
  }

  async function handleSave() {
    setSaving(true);
    setSavedMsg('');
    const result = await saveHistory(encounter.id, {
      chiefComplaint, chiefComplaintChips: ccChips, hxDuration: duration, hxLaterality: laterality,
      hxHopi: hopi, ocularHistory: ocular, medicalHistory: medical, familyHistory: family, hxDrugAllergy: drugAllergy,
    });
    setSaving(false);
    if (result.error) return;
    setSavedMsg('History saved.');
    if (onSaved) onSaved();
  }

  return (
    <div>
      {/* CHIEF COMPLAINT */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-message" style={{ color: 'var(--blue)' }}></i> Chief Complaint</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
          {CC_TEMPLATES.map((c) => (
            <Chip key={c} label={c} selected={ccChips.includes(c)} onClick={() => toggle(ccChips, setCcChips, c)} />
          ))}
        </div>
        <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Or type complaint..." value={chiefComplaint} onChange={(e) => setChiefComplaint(e.target.value)} />
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
          <div>
            <label className="flbl">Duration</label>
            <input className="fi fi-sm" value={duration} onChange={(e) => setDuration(e.target.value)} placeholder="e.g. 3 months" />
          </div>
          <div>
            <label className="flbl">Laterality</label>
            <select className="fi fi-sm" value={laterality} onChange={(e) => setLaterality(e.target.value)}>
              <option value="">--</option>
              <option>Right eye</option><option>Left eye</option><option>Bilateral</option>
            </select>
          </div>
        </div>
        <label className="flbl">History of present illness</label>
        <textarea className="fi fi-sm" rows={2} value={hopi} onChange={(e) => setHopi(e.target.value)} placeholder="Duration, onset, progression, associated symptoms, previous treatment..." />
      </div>

      {/* STRUCTURED HISTORY */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-forms" style={{ color: 'var(--purple)' }}></i> Structured History</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
          <div>
            <label className="flbl">Ocular history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {OCULAR_HX.map((c) => <Chip key={c} label={c} selected={ocular.includes(c)} onClick={() => toggle(ocular, setOcular, c)} />)}
            </div>
          </div>
          <div>
            <label className="flbl">Medical history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {MEDICAL_HX.map((c) => <Chip key={c} label={c} selected={medical.includes(c)} onClick={() => toggle(medical, setMedical, c)} />)}
            </div>
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
          <div>
            <label className="flbl">Drug history / Allergy</label>
            <input className="fi fi-sm" value={drugAllergy} onChange={(e) => setDrugAllergy(e.target.value)} placeholder="Current meds, allergies..." />
          </div>
          <div>
            <label className="flbl">Family history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {FAMILY_HX.map((c) => <Chip key={c} label={c} selected={family.includes(c)} onClick={() => toggle(family, setFamily, c)} />)}
            </div>
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Saving...' : 'Save History'}
        </button>
        {savedMsg && <span style={{ fontSize: 12, color: 'var(--green)' }}><i className="ti ti-check"></i> {savedMsg}</span>}
      </div>
    </div>
  );
}

EOF

echo "Ophthalmologist Section Phase 2 batch 2 (History + Management Plan expansion + Diagnosis History) created/updated."