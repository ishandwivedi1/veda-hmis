#!/bin/bash
set -e
echo "Applying: Diagnosis & Plan cleanup -- laterality, surgery notes, layout, remove dead/unneeded UI"

cat > "app/consultation/[id]/consultation-form.js" << 'PYEOF_6678271707830997700'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  sendForBiometryFromConsultation,
  adviseBiometry,
  updateBiometryInstructions,
  removeBiometryRecord,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  sendForProcedureFromConsultation,
  addReferral,
  removeReferral,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
  saveDraft,
  getFollowUpContext,
  saveVisitOutcome,
  carryForwardDiagnosis,
} from '@/app/(main)/consultation/actions';
import { openPopup } from '@/lib/popup';
import { markForSurgery, updateSurgicalCase } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import HistoryTab from './history-tab';
import OptometryTab from './optometry-tab';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

function DiagnosisRow({ d, index, encounterId, onRemove }) {
  const [notes, setNotes] = useState(d.notes || '');
  const [saved, setSaved] = useState(true);

  async function handleBlur() {
    if (notes === (d.notes || '')) return;
    await updateDiagnosisNotes(d.id, notes);
    setSaved(true);
  }

  return (
    <div style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
        <span>
          <span style={{ color: 'var(--g400)', fontWeight: 700, marginRight: 4 }}>{index + 1}.</span>
          <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
        </span>
        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={onRemove}>Remove</button>
      </div>
      <input
        className="fi fi-sm"
        style={{ marginTop: 5, marginLeft: 18, width: 'calc(100% - 18px)' }}
        placeholder="Doctor notes for this diagnosis (optional)"
        value={notes}
        onChange={(e) => { setNotes(e.target.value); setSaved(false); }}
        onBlur={handleBlur}
      />
      {!saved && <div style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 18, marginTop: 2 }}>Unsaved -- click away to save</div>}
    </div>
  );
}

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

// Section group divider for Diagnosis & Plan -- numbered circle badge,
// same visual language as the numbered sections in Optometry Assessment,
// so the two clinical screens feel consistent.
function GroupHeader({ num, color, title }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '4px 0 12px' }}>
      <span style={{ width: 24, height: 24, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>{num}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)' }}>{title}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--g200)' }}></div>
    </div>
  );
}

export default function ConsultationForm({ queueEntryId, hideHistoryTracker = false, onBack, backLabel = 'Dashboard' }) {
  const [data, setData] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [visitOutcome, setVisitOutcome] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState(hideHistoryTracker ? 'optometry' : 'history');
  const [unlocked, setUnlocked] = useState(false);
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
  const invPriority = 'Routine'; // selector removed -- no longer needed
  const [bioEye, setBioEye] = useState('');
  const [bioInstructions, setBioInstructions] = useState('');
  const [editingBioId, setEditingBioId] = useState(null);
  const [editBioInstructions, setEditBioInstructions] = useState('');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [procNotes, setProcNotes] = useState('');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  // Master Data options for the Diagnosis/Prescription/Investigation
  // dropdowns -- fetched once on mount, not re-fetched on every add/remove.
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && !s.name.toLowerCase().includes('biometry')));
      setProcedureOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Minor Procedure'));
      setSurgeryOptions(sg.filter((s) => s.status === 'Active'));
    })();
  }, []);

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
    setVisitOutcome(data.encounter.visit_outcome || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
    if (data.biometryRecords && data.biometryRecords.length > 0) {
      const first = data.biometryRecords[0];
      setBioEye(data.biometryRecords.length === 2 ? 'Both' : (first.surgical_eye || ''));
      setBioInstructions(first.doctor_instructions || '');
    }
  }, [data]);

  async function handleAdviseBiometry() {
    setError('');
    if (!bioEye) { setError('Select which eye Biometry is required for.'); return; }
    const result = await adviseBiometry(data.entry.visits.id, data.encounter.id, bioEye, bioInstructions);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  function startEditBioInstructions(record) {
    setEditingBioId(record.id);
    setEditBioInstructions(record.doctor_instructions || '');
  }

  async function saveBioInstructions(id) {
    await updateBiometryInstructions(id, editBioInstructions);
    setEditingBioId(null);
    refresh();
  }

  async function handleRemoveBiometry(id) {
    setError('');
    const result = await removeBiometryRecord(id, data.encounter.id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVisitOutcomeChange(outcome) {
    setVisitOutcome(outcome);
    await saveVisitOutcome(data.encounter.id, outcome);
  }

  async function handleCarryForward(priorDiagnosis) {
    setError('');
    const result = await carryForwardDiagnosis(data.encounter.id, priorDiagnosis);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

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
    if (!procName) { setError('Select a procedure.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye, procNotes);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    setProcNotes('');
    refresh();
  }

  async function handleSendForProcedure() {
    setError('');
    setLoading(true);
    const result = await sendForProcedureFromConsultation(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
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

  // This page is meant to be opened in its own window (see doctor-dashboard's
  // "Call"/"Call Next" and ot-postop's "Start Review"), closing itself the
  // moment the doctor is done with this sitting -- window.close() only
  // works on script-opened windows, so this quietly falls back to
  // navigating back to the queue if it was opened by direct navigation
  // instead (e.g. a bookmark or typed URL).
  function finishAndClose() {
    window.close();
    router.push('/queue');
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
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp, surgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryNotes('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
    setEditSurgeryNotes(sc.notes || '');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp, editSurgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  async function handleSendOut(kind) {
    setError('');
    if (kind === 'biometry' && !bioEye) { setError('Select which eye Biometry is required for before sending.'); return; }
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : kind === 'biometry'
      ? await sendForBiometryFromConsultation(queueEntryId, data.encounter.id, bioEye, bioInstructions)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    // Biometry stays on the page -- a doctor may still need to add
    // diagnoses, order investigations, etc. in the same sitting. Dilation
    // and Investigation keep the existing "done with this patient for
    // now" behavior since that wasn't something you flagged.
    if (kind === 'biometry') { refresh(); return; }
    finishAndClose();
  }

  async function handleSaveDraft() {
    setError('');
    setLoading(true);
    const result = await saveDraft(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
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
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
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

  const isReadOnly = data.isLocked && !unlocked;
  // Already routed to the technician if the current queue status
  // mentions Biometry (including compound statuses like "Awaiting
  // Investigation & Biometry" -- see doctorSendOut).
  const bioSent = data.entry?.status?.includes('Biometry') || false;

  return (
    <div style={{ maxWidth: 1440, margin: '0 auto', padding: '20px 26px' }}>
      {/* STICKY HEADER + TABS -- frozen at the top of the scroll area so
          the patient's identity and which tab you're on never scroll out
          of view, no matter how long the tab's content gets. */}
      <div style={{ position: 'sticky', top: 0, zIndex: 20, background: 'var(--g50)', paddingBottom: 10, marginBottom: 6 }}>
        {onBack && (
          <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> {backLabel}
          </button>
        )}
        <div style={{
          background: 'linear-gradient(135deg, var(--blue-dk), var(--blue))', borderRadius: 'var(--r-lg)',
          padding: '14px 20px', color: '#fff', boxShadow: 'var(--shadow-md)', marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 16,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: '50%', background: 'rgba(255,255,255,.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800, flexShrink: 0,
            fontFamily: 'var(--font-display-stack)',
          }}>
            {patient.first_name?.charAt(0)?.toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
              {patient.first_name} {patient.last_name}
              {data.isFollowUp && <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontSize: 10.5 }}>Follow-up Visit</span>}
            </div>
            <div style={{ fontSize: 12, opacity: .85, marginTop: 2 }}>
              {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- Token {data.entry.token}
            </div>
          </div>
          <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.16)', borderRadius: 10, padding: '6px 16px', flexShrink: 0 }}>
            <div style={{ fontSize: 9.5, opacity: .8, textTransform: 'uppercase', letterSpacing: '.5px' }}>Duration</div>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'monospace' }}>{elapsedMin(data.encounter.started_at)}m</div>
          </div>
        </div>

        {/* TABS */}
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
          {!hideHistoryTracker && <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-message" label="History" />}
          <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
          <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
          <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
          {!hideHistoryTracker && <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />}
        </div>
      </div>

      {data.isFollowUp && followUpContext && (
        <PatientSnapshotBar snapshot={followUpContext.snapshot} />
      )}

      {data.isLocked && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed consultation -- changes save immediately.'
              : 'This consultation is completed. Viewing read-only for reference.'}
          </span>
          <button className="btn btn-sm" onClick={() => setUnlocked((v) => !v)}>
            {unlocked ? 'Lock' : 'Unlock to Edit'}
          </button>
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        {/* CONTEXT SIDEBAR -- patient history (previous visit, timeline,
            investigations) plus this encounter's own status/tasks/audit
            log, all in one place so the main column has full width. */}
        <div>
          <ContextSidebar
            patientId={patient.id}
            previousVisitSummary={data.isFollowUp && followUpContext ? followUpContext.snapshot.previousVisitSummary : null}
            encounter={data.encounter}
            auditLog={data.auditLog}
            openInvestigations={openInvestigations}
            activeWorkflows={activeWorkflows}
            pendingRx={pendingRx}
            wfItems={WF_ITEMS}
          />
        </div>

        {/* MAIN COLUMN -- tab content only; the tab bar itself now lives
            in the sticky header above so it freezes along with the
            patient identity bar. */}
        <div>
          {/* Tab content and the actions bar below are wrapped in a native
              <fieldset disabled> when the encounter is locked -- this
              cascades to every nested input/select/button in HistoryTab,
              OptometryTab, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'history' && (
            <HistoryTab
              encounter={data.encounter}
              findings={data.findings}
              onSaved={refresh}
            />
          )}

          {activeTab === 'optometry' && (
            <OptometryTab
              findings={data.findings}
              iopReadings={data.iopReadings}
              visitId={data.entry.visits.id}
              encounterId={data.encounter.id}
              onSaved={refresh}
            />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              <GroupHeader num={1} color="var(--purple)" title="Investigations" />

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>
                {data.isFollowUp && followUpContext && (
                  <NewInvestigationsSinceLastVisit
                    investigations={followUpContext.newInvestigations}
                    matchInvestigationType={matchInvestigationType}
                    summarizeResultData={summarizeResultData}
                  />
                )}
                {data.investigations.map((i) => {
                  const type = matchInvestigationType(i.name);
                  const hasResults = i.status === 'Available';
                  return (
                    <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
                        <span>
                          <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                        </span>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                          {hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {hasResults && (
                        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3 }}>{summarizeResultData(type, i.result_data)}</div>
                      )}
                      {i.status === 'Cancelled' && i.unable_reason && (
                        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}><i className="ti ti-alert-triangle"></i> Unable to perform -- {i.unable_reason}</div>
                      )}
                    </div>
                  );
                })}
                {data.investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No investigations ordered yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setInvName(e.target.value); }}>
                  <option value="">-- Pick from Investigations master (or type below) --</option>
                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              <GroupHeader num={2} color="var(--indigo)" title="Biometry" />
              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                  Device measurements, IOL power calculation, and surgeon approval -- its own dedicated workflow, separate from lab investigations.
                </div>

                {bioSent ? (
                  <>
                    <div style={{ marginBottom: 6 }}>
                      <span className="badge b-green"><i className="ti ti-check"></i> Sent for Biometry</span>
                    </div>
                    {data.biometryRecords.map((r) => (
                      <div key={r.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                          <span className={`badge ${r.status === 'Approved' ? 'b-green' : r.status === 'Calculated' ? 'b-purple' : r.status === 'Measured' ? 'b-blue' : 'b-amber'}`}>
                            {r.status}
                          </span>
                          <span className="badge b-indigo">{r.surgical_eye}</span>
                          <a href={`/biometry/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 12, textDecoration: 'none' }}>
                            <i className="ti ti-external-link"></i> Open Biometry
                          </a>
                          {editingBioId !== r.id && (
                            <button className="btn" style={{ fontSize: 11 }} onClick={() => startEditBioInstructions(r)}>
                              <i className="ti ti-edit"></i> {r.doctor_instructions ? 'Edit instructions' : 'Add instructions'}
                            </button>
                          )}
                          {r.billing_status !== 'Billed' ? (
                            <button className="btn" style={{ fontSize: 11, color: 'var(--red)' }} onClick={() => handleRemoveBiometry(r.id)}>
                              <i className="ti ti-trash"></i> Remove
                            </button>
                          ) : (
                            <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                          )}
                        </div>
                        {editingBioId === r.id ? (
                          <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                            <input className="fi" style={{ flex: 1 }} placeholder="Instructions for technician" value={editBioInstructions} onChange={(e) => setEditBioInstructions(e.target.value)} />
                            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => saveBioInstructions(r.id)}>Save</button>
                            <button className="btn" style={{ fontSize: 12 }} onClick={() => setEditingBioId(null)}>Cancel</button>
                          </div>
                        ) : r.doctor_instructions && (
                          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 4 }}><i className="ti ti-notes"></i> {r.doctor_instructions}</div>
                        )}
                      </div>
                    ))}
                  </>
                ) : (
                  <>
                    {data.biometryRecords.length > 0 && (
                      <div style={{ marginBottom: 10 }}>
                        {data.biometryRecords.map((r) => (
                          <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4, flexWrap: 'wrap' }}>
                            <span className="badge b-indigo"><i className="ti ti-check"></i> Advised -- {r.surgical_eye}</span>
                            {r.billing_status !== 'Billed' ? (
                              <button className="btn" style={{ fontSize: 10 }} onClick={() => handleRemoveBiometry(r.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i> Remove
                              </button>
                            ) : (
                              <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                            )}
                          </div>
                        ))}
                        <span style={{ fontSize: 11, color: 'var(--g500)' }}>Adjust below if needed, then use &quot;Send for Biometry&quot; at the bottom.</span>
                      </div>
                    )}
                    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                      <div>
                        <label className="flbl">Eye required</label>
                        <select className="fi" style={{ width: 130 }} value={bioEye} onChange={(e) => setBioEye(e.target.value)}>
                          <option value="">Select</option>
                          <option value="RE">Right (OD)</option>
                          <option value="LE">Left (OS)</option>
                          <option value="Both">Both (OU)</option>
                        </select>
                      </div>
                      <div style={{ flex: 1, minWidth: 200 }}>
                        <label className="flbl">Instructions for technician (optional)</label>
                        <input className="fi" placeholder="e.g. prior RK surgery, use formula X" value={bioInstructions} onChange={(e) => setBioInstructions(e.target.value)} />
                      </div>
                      <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAdviseBiometry}>
                        {data.biometryRecords.length > 0 ? 'Update' : 'Add'}
                      </button>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>
                      Adding here records the advice -- use &quot;Send for Biometry&quot; below when you&apos;re ready to actually route the patient.
                    </div>
                  </>
                )}
              </div>

              <GroupHeader num={3} color="var(--teal)" title="Diagnosis" />

              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
                {data.isFollowUp && followUpContext && !isReadOnly && (
                  <CarryForwardDiagnoses
                    priorDiagnoses={followUpContext.snapshot.currentDiagnoses}
                    alreadyAdded={data.diagnoses}
                    onCarryForward={handleCarryForward}
                  />
                )}
                {data.diagnoses.map((d, idx) => (
                  <DiagnosisRow key={d.id} d={d} index={idx} encounterId={data.encounter.id} onRemove={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }} />
                ))}
                {data.diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setDxName(e.target.value); }}>
                  <option value="">-- Pick from Diagnoses master (or type below) --</option>
                  {diagnosisOptions.map((d) => <option key={d.id} value={d.name}>{d.name}{d.category ? ` (${d.category})` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              <GroupHeader num={4} color="var(--blue)" title="Treatment" />

              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Prescription</div>
                {data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && !isReadOnly && (
                  <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Continue from last visit</div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {followUpContext.snapshot.currentMedications
                        .filter((m) => !data.prescriptions.some((r) => r.drug_name === m.drug_name && r.eye === m.eye))
                        .map((m) => (
                          <button
                            key={m.id}
                            className="btn btn-sm"
                            onClick={async () => {
                              await addPrescription(data.encounter.id, { drugName: m.drug_name, dosage: m.dosage, frequency: m.frequency, duration: m.duration, eye: m.eye });
                              refresh();
                            }}
                          >
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye})
                          </button>
                        ))}
                    </div>
                  </div>
                )}
                {data.prescriptions.map((r) => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setRxDrug(e.target.value); }}>
                  <option value="">-- Pick from Pharmacy master (or type below) --</option>
                  {drugOptions.map((d) => <option key={d.id} value={d.generic}>{d.generic}{d.brand ? ` (${d.brand})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                </select>
                <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr auto', gap: 6, marginTop: 10, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span>Drug</span><span>Dosage</span><span>Frequency</span><span>Duration</span><span>Eye</span><span></span>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 4, flexWrap: 'wrap' }}>
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
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
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

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Minor Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                      {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{p.notes}</div>}
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select minor procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name} -- Rs.{p.rate}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 110 }}>
                      <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                  </div>
                  <input className="fi fi-sm" placeholder="Notes (optional)" value={procNotes} onChange={(e) => setProcNotes(e.target.value)} />
                </div>
              </div>

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery</div>

                {data.surgicalCases.length > 0 ? (
                  <div>
                    {data.surgicalCases.map((sc) => (
                      <div key={sc.id}>
                        {editingSurgicalCaseId === sc.id ? (
                          <div style={{ padding: '8px 0' }}>
                            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                              <select className="fi" value={editSurgeryProcedure} onChange={(e) => setEditSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                                <option value="">-- Select surgery --</option>
                                {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                              </select>
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 110 }}>
                                <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Pre-op Required</label>
                              <select className="fi" value={editSurgeryPreOp} onChange={(e) => setEditSurgeryPreOp(e.target.value)}>
                                <option value="None">None</option>
                                <option value="Biometry">Biometry</option>
                                <option value="Medical Fitness">Medical Fitness</option>
                                <option value="Both">Both</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Notes</label>
                              <input className="fi" placeholder="Any notes for this surgery recommendation..." value={editSurgeryNotes} onChange={(e) => setEditSurgeryNotes(e.target.value)} />
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ padding: '6px 0' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                              <span style={{ flex: 1 }}>
                                <strong>{sc.procedure_name}</strong> -- {sc.eye === 'OD' ? 'Right (OD)' : sc.eye === 'OS' ? 'Left (OS)' : sc.eye === 'OU' ? 'Both (OU)' : sc.eye}
                                <span style={{ marginLeft: 8, fontSize: 10.5, color: 'var(--g500)' }}>
                                  Pre-op: {sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None'}
                                </span>
                              </span>
                              <span className="badge b-blue" style={{ fontSize: 10 }}>{sc.status}</span>
                              {sc.status === 'Pending Workup' && (
                                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => startEditSurgicalCase(sc)}>
                                  <i className="ti ti-edit"></i> Edit
                                </button>
                              )}
                            </div>
                            {sc.notes && (
                              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3, marginLeft: 22 }}><i className="ti ti-notes"></i> {sc.notes}</div>
                            )}
                          </div>
                        )}
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select surgery --</option>
                        {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 110 }}>
                        <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Pre-op Required</label>
                      <select className="fi" value={surgeryPreOp} onChange={(e) => setSurgeryPreOp(e.target.value)}>
                        <option value="None">None</option>
                        <option value="Biometry">Biometry</option>
                        <option value="Medical Fitness">Medical Fitness</option>
                        <option value="Both">Both</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
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

              <GroupHeader num={5} color="var(--amber)" title="Patient Management" />

              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
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

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
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

          {data.isFollowUp && (
            <VisitOutcomeSelector value={visitOutcome} onChange={handleVisitOutcomeChange} disabled={isReadOnly} />
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn" onClick={handleSaveDraft} disabled={loading}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            {data.investigations.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
                Send for Investigation
              </button>
            )}
            {!bioSent && data.biometryRecords.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('biometry')} disabled={loading}>
                <i className="ti ti-ruler-measure"></i> Send for Biometry
              </button>
            )}
            {data.procedures.length > 0 && (
              <button className="btn" onClick={handleSendForProcedure} disabled={loading}>
                <i className="ti ti-tool"></i> Send for Procedure
              </button>
            )}
            <a href={`/opd-case-sheet-print/${data.encounter.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </a>
            <a href={`/visit-summary-print/${data.encounter.id}`} target="_blank" rel="noopener noreferrer" className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </a>
          </div>
          </fieldset>
        </div>
      </div>
    </div>
  );
}
PYEOF_6678271707830997700

cat > "app/(main)/counselling/actions.js" << 'PYEOF_5591761610534398143'
'use server';

import { createClient } from '@/lib/supabase-server';

// This file replaces the old "Surgical Coordination" module's actions file.
// OT Scheduling (formerly its own module at app/(main)/ot-schedule) has been
// merged into Counselling: booking a slot is now the last step of the
// counselling workspace (see bookOTSlot/getOTAvailability below), and the
// OT Calendar (getOTSchedule/completeOT) is now the 3rd tab of this page
// instead of a standalone route.
// The following exports are used by OTHER modules and MUST keep the same
// name + signature:
//   markForSurgery, updateSurgicalCase
//     -- imported by app/(main)/consultation/[id]/consultation-form.js
// Everything else below is used only within the Counselling module.

// ── Sending a patient to an ancillary service (Biometry, Dilation, ...)
//    from Counselling. Once a doctor completes a consultation, ALL of
//    that visit's queue_entries get marked 'Done' -- so by the time a
//    case reaches Counselling (even same-day), there's nothing left to
//    "update". send_case_to_department_queue() (see migration 027)
//    issues a FRESH queue token against the patient's still-open visit
//    (found via ist_date(), so it's IST-correct rather than doing UTC
//    date math here) and flips it straight to the target status.
async function sendCaseToQueueStatus(caseId, queueStatus, auditMessage) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: queueStatus,
    p_audit_message: auditMessage,
    p_user_id: userData?.user?.id || null,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForBiometry(caseId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: queueEntry, error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: 'Awaiting Biometry',
    p_audit_message: 'Sent for Biometry (from Counselling)',
    p_user_id: userData?.user?.id || null,
  });
  if (error) return { error: error.message };

  // Also create the biometry_records stub right away (mirrors
  // getOrCreateBiometryRecord in the Biometry module) so the Counselling
  // dashboard reflects "Awaiting Biometry" immediately instead of only
  // after the technician opens the queue entry -- and so the technician
  // finds it already there rather than creating a fresh one.
  const visitId = queueEntry?.visit_id;
  if (visitId) {
    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id')
      .eq('visit_id', visitId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (!existing || existing.length === 0) {
      const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();
      await supabase.from('biometry_records').insert({ visit_id: visitId, encounter_id: sc.encounter_id || null, surgeon_id: visit?.doctor_id || null });
    }
  }

  return { success: true };
}

// For surgeries where biometry genuinely doesn't apply (retina,
// glaucoma, oculoplasty...) -- a reason is required so there's an
// audit trail for why this case skipped a normally-required step.
export async function skipBiometry(caseId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required to skip Biometry.' };
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: false, biometry_skip_reason: reason.trim() })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Undo a skip -- puts Biometry back as a required step for this case.
export async function unskipBiometry(caseId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: true, biometry_skip_reason: null })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForDilation(caseId) {
  return sendCaseToQueueStatus(caseId, 'Awaiting Dilation', 'Sent for Dilation (from Counselling)');
}

// ── Case creation (called from Consultation when doctor recommends surgery) ──
// Doctor can correct the procedure/eye on a case they marked for
// surgery, as long as Counselling hasn't already started working with
// it -- once package/decision work is underway, changes should go
// through Counselling instead to avoid corrupting what's already locked.
export async function updateSurgicalCase(caseId, procedureName, eye, preOpRequired, notes) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Pending Workup') {
    return { error: `This case has already moved to "${sc.status}" -- further changes should go through Counselling.` };
  }
  const update = { procedure_name: procedureName, eye, notes: notes || null };
  if (preOpRequired !== undefined) {
    update.biometry_required = preOpRequired === 'Biometry' || preOpRequired === 'Both';
    update.fitness_required = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';
  }
  const { error } = await supabase.from('surgical_cases').update(update).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  const supabase = await createClient();

  // Pull surgeon + visit + priority through so the case doesn't start
  // with everything null -- encounters already carries doctor_id.
  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  // BR: one visit, one surgical case -- checked against visit_id (not
  // just this encounter), since a visit can span more than one
  // encounter (e.g. consultation reopened) and the case should still
  // only be created once.
  if (encounter?.visit_id) {
    const { data: existing } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye')
      .eq('visit_id', encounter.visit_id)
      .neq('status', 'Cancelled')
      .limit(1);
    if (existing && existing.length > 0) {
      return { error: `This visit already has a surgical case marked (${existing[0].procedure_name} -- ${existing[0].eye}). Only one is allowed per visit.` };
    }
  }

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  // Doctor's call on what pre-op workup this case actually needs --
  // carried forward to Counselling, which reads biometry_required /
  // fitness_required the same way for both (see readiness() and
  // markReadyForScheduling).
  const biometryRequired = preOpRequired === 'Biometry' || preOpRequired === 'Both';
  const fitnessRequired = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';

  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: procedureName,
    eye,
    priority,
    biometry_required: biometryRequired,
    fitness_required: fitnessRequired,
    notes: notes || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Cases list for the Counselling workspace (richer -- surgeon, decision, IOL type) ──
export async function getCounsellingCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];

  // surgical_cases and biometry_records are siblings linked only by
  // encounter_id (no direct FK Supabase can auto-embed), so this is a
  // separate batch query rather than a nested select. Used to tell
  // "Surgery Advised" (nobody has sent for biometry yet) apart from
  // "Awaiting Biometry" (sent, technician hasn't finished it) on the
  // dashboard -- both are biometry_done = false, but they're different
  // stages for the counsellor.
  const encounterIds = [...new Set((data || []).map((c) => c.encounter_id).filter(Boolean))];
  let biometryByEncounter = {};
  if (encounterIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('id, encounter_id, status')
      .in('encounter_id', encounterIds);
    (records || []).forEach((r) => { biometryByEncounter[r.encounter_id] = r; });
  }

  // Same batching pattern for the medical fitness referral -- one per
  // case at most (re-referring resets the same row rather than piling
  // up history), so a simple map by surgical_case_id is enough.
  const caseIds = (data || []).map((c) => c.id);
  let fitnessByCase = {};
  if (caseIds.length > 0) {
    const { data: referrals } = await supabase
      .from('medical_fitness_referrals')
      .select('id, surgical_case_id, status, referred_at, fitness_notes')
      .in('surgical_case_id', caseIds);
    (referrals || []).forEach((r) => { fitnessByCase[r.surgical_case_id] = r; });
  }

  return (data || []).map((c) => ({
    ...c,
    biometry_record: biometryByEncounter[c.encounter_id] || null,
    fitness_referral: fitnessByCase[c.id] || null,
  }));
}

// ── History -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled). Read-only lookup, same underlying data shape
//    as getCounsellingCases minus the biometry/fitness batching, which
//    only matters for cases still in active workup. ──
export async function getCounsellingHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .not('status', 'in', '("Pending Workup","Ready for Scheduling")')
    .order('created_at', { ascending: false })
    .limit(300);
  if (error) return [];
  return data || [];
}

// ── Packages, filtered by the IOL type advised at Biometry ──
// iol_category/origin live on master_packages (Master Data, M29). A package
// with iol_category = NULL is not IOL-specific (e.g. Glaucoma surgery) and
// is shown regardless of what was advised. Filtered in JS rather than a
// PostgREST .or() filter to avoid escaping issues with values like
// "Monofocal Toric" that contain a space.
export async function getPackagesForCase(iolCategory) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return (data || []).filter((p) => !p.iol_category || p.iol_category === iolCategory);
}

// ── Package selection (BR-SCC-002: only after Biometry & IOL advice) ──
export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('biometry_done, biometry_required').eq('id', caseId).single();
  if (!sc?.biometry_done && sc?.biometry_required !== false) {
    return { error: 'BR-SCC-002: Biometry & IOL type advice must be complete before selecting a package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId, package_locked: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Changing a package once it's locked needs a reason -- logged as a
// counselling note so there's an audit trail for why it changed.
export async function changePackage(caseId, reason) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('package_locked, master_packages:package_id(name)').eq('id', caseId).single();
  if (sc?.package_locked && (!reason || !reason.trim())) {
    return { error: 'A reason is required to change a locked package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: null, package_locked: false }).eq('id', caseId);
  if (error) return { error: error.message };

  if (sc?.package_locked && reason) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Package unlocked and changed${sc.master_packages?.name ? ` (was: ${sc.master_packages.name})` : ''} -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }
  return { success: true };
}

// ── Patient decision ──
const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

export async function setDecision(caseId, decision, reason) {
  if (!DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('decision, decision_locked').eq('id', caseId).single();

  if (sc?.decision_locked && decision !== sc.decision) {
    if (!reason || !reason.trim()) {
      return { error: 'A reason is required to change a locked decision.' };
    }
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Decision unlocked and changed from "${sc.decision}" to "${decision}" -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  const { error } = await supabase.from('surgical_cases').update({
    decision, decision_reason: reason || null,
    decision_locked: decision === 'Accepted',
  }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Counselling notes log ──
export async function getCaseNotes(caseId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_case_notes')
    .select('id, note, created_at, profiles:created_by ( id, full_name )')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function addCaseNote(caseId, note) {
  if (!note || !note.trim()) return { error: 'Note cannot be empty.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: note.trim(),
    created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Patient education topics (populated by the doctor's plan, M17/M19) ──
export async function getCounsellingItems(encounterId) {
  if (!encounterId) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_counselling_items')
    .select('id, topic, status')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: true });
  if (error) return [];
  return data;
}

export async function toggleCounsellingItem(itemId, done) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').update({ status: done ? 'Done' : 'Pending' }).eq('id', itemId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Post-decision checklist (BR-SCC-004: only after package + Accepted) ──
async function requirePostDecision(supabase, caseId) {
  const { data: sc } = await supabase.from('surgical_cases').select('package_id, decision').eq('id', caseId).single();
  if (!(sc?.package_id && sc.decision === 'Accepted')) {
    return 'BR-SCC-004: Package must be confirmed and the patient decision must be Accepted first.';
  }
  return null;
}

// ── PRE-OP INVESTIGATIONS (usually blood work) ──
// Same master list Consultation's investigation picker uses (dept =
// Investigation in Financial Masters, Biometry excluded since that's
// its own dedicated step above) -- so an order placed here is the same
// kind of thing a doctor orders during a regular consultation, and
// lands in the same Investigation module queue for the lab to process.
export async function getInvestigationMasterOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  // Substring match, not exact -- the catalog entry is named
  // "Biometry (Procedure Charge)", not literally "Biometry".
  return (data || []).filter((s) => !s.name.toLowerCase().includes('biometry'));
}

// Distinct standard panels (e.g. "Cataract" -> Blood, Sugar, HIV...)
// set up in Financial Masters against Investigation services, so
// Counselling can order a whole panel in one action instead of one
// investigation at a time.
export async function getInvestigationPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('investigation_package').eq('status', 'Active').eq('dept', 'Investigation').not('investigation_package', 'is', null);
  return [...new Set((data || []).map((s) => s.investigation_package).filter(Boolean))].sort();
}

export async function orderInvestigationPackage(caseId, encounterId, packageName) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!packageName) return { error: 'Select a package.' };

  const { data: services, error: svcError } = await supabase
    .from('master_services')
    .select('name')
    .eq('status', 'Active')
    .eq('dept', 'Investigation')
    .eq('investigation_package', packageName);
  if (svcError) return { error: svcError.message };
  if (!services || services.length === 0) return { error: 'No investigations found for this package.' };

  const { error } = await supabase.from('investigation_orders').insert(
    services.map((s) => ({ encounter_id: encounterId, name: s.name, eye: 'N/A', priority: 'Routine' }))
  );
  if (error) return { error: error.message };
  return { success: true, count: services.length };
}

export async function getCounsellingInvestigationOrders(encounterId) {
  const supabase = await createClient();
  if (!encounterId) return [];
  const { data } = await supabase
    .from('investigation_orders')
    .select('*')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function orderCounsellingInvestigation(caseId, encounterId, values) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!values.name?.trim()) return { error: 'Select or enter an investigation.' };

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye || 'OU',
    priority: values.priority || 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeCounsellingInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationsComplete(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ investigations_complete: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFitnessCleared(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Medical fitness is no longer self-certified by the counsellor --
// it's referred to a doctor, who reviews clinical data, orders any
// investigations needed, and clears (or doesn't) via the Medical
// Fitness Dashboard/Workspace. This creates that referral, or -- if
// the case was previously marked Not Fit -- resets the same row back
// to Pending Review rather than creating a duplicate.
export async function referForMedicalFitness(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };

  const { data: sc } = await supabase.from('surgical_cases').select('visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: userData } = await supabase.auth.getUser();
  const { data: existing } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0 && existing[0].status === 'Pending Review') {
    return { error: 'Already referred and awaiting doctor review.' };
  }

  if (existing && existing.length > 0 && existing[0].status === 'Not Fit') {
    const { error } = await supabase.from('medical_fitness_referrals').update({
      status: 'Pending Review', referred_by: userData?.user?.id || null, referred_at: new Date().toISOString(),
      reviewing_doctor_id: null, fitness_notes: null, cleared_by: null, cleared_at: null,
    }).eq('id', existing[0].id);
    if (error) return { error: error.message };
    return { success: true };
  }

  const { error } = await supabase.from('medical_fitness_referrals').insert({
    surgical_case_id: caseId, visit_id: sc.visit_id, encounter_id: sc.encounter_id, referred_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Ready for Scheduling ──
// NOTE: this intentionally does NOT require consent_taken. Per BR-SCC-005,
// consent is taken day-of-surgery (day-care model), not a pre-scheduling
// gate here -- that belongs to the Intraoperative module (M25). This is a
// behavior change from the previous version of this function, which did
// require consent_taken.
export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  if (!sc.biometry_done && sc.biometry_required !== false) return { error: 'VAL-SCC-002: Biometry & IOL type advice must be complete.' };
  if (!sc.package_id) return { error: 'VAL-SCC-002: Select a package first.' };
  if (sc.decision !== 'Accepted') return { error: 'VAL-SCC-002: Patient decision must be Accepted.' };
  if (!sc.fitness_cleared && sc.fitness_required !== false) return { error: 'VAL-SCC-002: Medical fitness must be cleared.' };

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function referBackToDoctor(caseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ status: 'Pending Workup' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Surgeons ──
export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').eq('designation', 'Doctor').eq('status', 'Active');
  return data || [];
}

// ── OT Booking -- last step of the Counselling workspace. Availability is
//    checked against master_ot_sessions.capacity (Financial Masters -- OT
//    Sessions), not free-form date/time like the old standalone OT
//    Scheduling module. Capacity check + insert happen atomically in the
//    book_ot_slot() DB function (see migration ot_booking_functions) so two
//    counsellors booking the same session at once can't both overbook it. ──
export async function getOTAvailability(date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_ot_availability', { p_date: date });
  if (error) return [];
  return data || [];
}

export async function bookOTSlot(caseId, date, sessionId, surgeonId, notes) {
  const supabase = await createClient();
  if (!date) return { error: 'Date is required.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data, error } = await supabase.rpc('book_ot_slot', {
    p_case_id: caseId,
    p_date: date,
    p_session_id: sessionId,
    p_surgeon_id: surgeonId || null,
    p_notes: notes || null,
  });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { success: true };
}

// ── OT Calendar -- now the 3rd tab of the Counselling module (was the
//    standalone /ot-schedule page). ──
export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles!ot_schedule_surgeon_id_fkey(full_name)')
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

PYEOF_5591761610534398143

echo "Files written. Run: npm run build"
