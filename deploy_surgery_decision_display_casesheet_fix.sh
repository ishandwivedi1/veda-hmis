#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/query-only change -- no DB migration needed.
#
# Three fixes:
#
# 1) "Pre-op Required" row removed from Mark for Surgery in Doctor
#    Consultation -- both the create form and the edit form. It now
#    just always requires both Biometry and Medical Fitness (the
#    variable is still passed through internally as "Both", the picker
#    is just gone from the UI).
#
# 2) "Patient Decision disappeared on reopening" -- turned out to be a
#    display bug, not data loss. Confirmed directly in the database:
#    Ishan Dwivedi's case in training still has decision="Accepted" and
#    decision_locked=true exactly as set -- it was never wiped.
#    Reopening a marked case used a completely separate "edit" form
#    that never displayed decision at all. Fixed: the read-only summary
#    for a marked surgical case now always shows Patient Decision with
#    the same Willing / Needs Time to Decide / Not Willing buttons used
#    at creation time, so it'"'"'s visible and editable every time the
#    doctor opens the patient, using the same locked+reason rule as
#    everywhere else.
#
# 3) OPD Case Sheet print was missing surgery advice entirely -- turned
#    out this was never built, not a regression. Added a "Surgery
#    Advised" section (procedure, eye, patient decision) to the case
#    sheet template, between Diagnosis and Prescription. Verified by
#    actually compiling the template with Handlebars and confirming the
#    section renders correctly with sample data before packaging this.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/consultation/[id]"
cat > "app/consultation/[id]/consultation-form.js" << 'FILEEOF_consultation_form_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addTaperedPrescription,
  removeTaperGroup,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
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
import { markForSurgery, updateSurgicalCase, setDecision } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getDosageOptions, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import OptometryWorkspace from '@/app/(main)/optometry/[id]/optometry-workspace';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';
import { openPrintPopup } from '@/lib/printPopup';

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
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [surgeryDecision, setSurgeryDecision] = useState('');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('optometry');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week' },
    { frequency: 'TDS', duration: '1 week' },
    { frequency: 'BD', duration: '1 week' },
    { frequency: 'OD', duration: '1 week' },
  ]);
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const invPriority = 'Routine'; // selector removed -- no longer needed

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
  const [dosageOptions, setDosageOptions] = useState([]);
  const [rxDrugTypeId, setRxDrugTypeId] = useState(null);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg, dg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      setDosageOptions(dg);
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation'));
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
  }, [data]);

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

  // Type-ahead for the Prescription drug field -- matches on brand or
  // generic name, case-insensitive substring, capped to keep the list
  // scannable. Falls back to free-text (rxDrug itself) when nothing
  // matches, or to the full Browse dropdown if the doctor wants to look
  // rather than type.
  const rxSuggestions = rxDrug.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(rxDrug.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(rxDrug.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectRxDrug(d) {
    setRxDrug(d.brand);
    setRxDrugTypeId(d.drug_type_id || null);
    setRxDosage('');
    setShowRxSuggestions(false);
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week' }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    if (!rxDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxEye, steps: taperSteps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setShowTaperBuilder(false);
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

  // Escape hatch for a visit that genuinely can't go through the normal
  // completion path -- patient left before being seen, token called but
  // nobody responded, etc. Doesn't touch the diagnosis requirement for
  // any other visit; just closes this one with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a diagnosis.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    if (!surgeryDecision) { setError("Select the patient's decision -- right now."); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp, surgeryNotes, surgeryDecision);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryNotes('');
    setSurgeryDecision('');
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
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
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
            isAdmin={data.isAdmin}
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
              cascades to every nested input/select/button in the embedded
              OptometryWorkspace, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'optometry' && (
            <OptometryWorkspace queueEntryId={queueEntryId} embedded />
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

              <GroupHeader num={2} color="var(--teal)" title="Diagnosis" />

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

              <GroupHeader num={3} color="var(--blue)" title="Treatment" />

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
                {(() => {
                  // Group rows sharing a taper_group_id into one block
                  // (ordered by taper_step); everything else renders as
                  // a normal single-line prescription, same as before.
                  const seen = new Set();
                  const items = [];
                  data.prescriptions.forEach((r) => {
                    if (r.taper_group_id) {
                      if (seen.has(r.taper_group_id)) return;
                      seen.add(r.taper_group_id);
                      const steps = data.prescriptions
                        .filter((x) => x.taper_group_id === r.taper_group_id)
                        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
                      items.push({ type: 'taper', key: r.taper_group_id, steps });
                    } else {
                      items.push({ type: 'single', key: r.id, row: r });
                    }
                  });
                  return items.map((item) => item.type === 'single' ? (
                    <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>
                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye}
                      </span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ) : (
                    <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <span style={{ fontSize: 13 }}>
                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye}
                          <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering Schedule</span>
                        </span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>
                      </div>
                      <div style={{ fontSize: 12.5, marginTop: 4, color: 'var(--g700)' }}>
                        {item.steps.map((s, i) => (
                          <span key={s.id}>
                            {i > 0 && <i className="ti ti-arrow-right" style={{ margin: '0 4px', color: 'var(--g400)' }}></i>}
                            {s.frequency} <span style={{ color: 'var(--g500)' }}>x {s.duration}</span>
                          </span>
                        ))}
                        <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
                      </div>
                    </div>
                  ));
                })()}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr auto', gap: 6, marginTop: 10, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span>Drug</span><span>Dosage</span><span>Frequency</span><span>Duration</span><span>Eye</span><span></span>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 4, flexWrap: 'wrap', alignItems: 'flex-start' }}>
                  <div style={{ position: 'relative', flex: '2 1 160px' }}>
                    <input
                      className="fi"
                      placeholder="Type to search medicines, or enter a new name"
                      value={rxDrug}
                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setShowRxSuggestions(true); }}
                      onFocus={() => setShowRxSuggestions(true)}
                      onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
                      style={{ width: '100%' }}
                    />
                    {showRxSuggestions && rxDrug.trim().length > 0 && (
                      <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 230, overflowY: 'auto', marginTop: 3 }}>
                        {rxSuggestions.length > 0 ? rxSuggestions.map((d) => (
                          <div key={d.id} onMouseDown={() => selectRxDrug(d)} style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 12.5, borderBottom: '1px solid var(--g100)' }}>
                            <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
                            {d.master_drug_types?.name && <span style={{ marginLeft: 6, fontSize: 10.5, color: 'var(--purple)' }}>{d.master_drug_types.name}</span>}
                          </div>
                        )) : (
                          <div style={{ padding: '8px 12px', fontSize: 12, color: 'var(--g500)' }}>
                            No match in Pharmacy master.{' '}
                            <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 11 }} onMouseDown={() => { setShowRxBrowseAll(true); setShowRxSuggestions(false); }}>Browse full list</button>
                            {' '}or keep typing to prescribe as free text.
                          </div>
                        )}
                      </div>
                    )}
                    {showRxBrowseAll && (
                      <select className="fi" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
                        if (!e.target.value) return;
                        const picked = drugOptions.find((d) => d.brand === e.target.value);
                        if (picked) selectRxDrug(picked);
                        setShowRxBrowseAll(false);
                      }}>
                        <option value="">-- Browse full Pharmacy master --</option>
                        {drugOptions.filter((d) => d.brand).map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                      </select>
                    )}
                  </div>
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option value="">-- Dosage --</option>
                    {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => (
                      <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                    ))}
                    {/* Generic fallback -- shown when the drug has no type assigned yet (free-typed name, or a master drug still missing its Type in Financial Masters) so the field never comes up empty. */}
                    {!rxDrugTypeId && (
                      <>
                        <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                      </>
                    )}
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

                {!showTaperBuilder ? (
                  <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => setShowTaperBuilder(true)}>
                    <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                  </button>
                ) : (
                  <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug, Dosage &amp; Eye entered above; frequency reduces step by step below
                    </div>
                    {taperSteps.map((s, i) => (
                      <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                        <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                        <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                          <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                        </select>
                        <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                          <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
                        </select>
                        {taperSteps.length > 2 && (
                          <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
                        )}
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                      <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                      <button className="btn btn-sm btn-primary" onClick={handleAddTaperSchedule}>Save Tapering Schedule</button>
                      <button className="btn btn-sm" onClick={() => setShowTaperBuilder(false)}>Cancel</button>
                    </div>
                  </div>
                )}
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
                            <div style={{ marginTop: 6, marginLeft: 22 }}>
                              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 4 }}>Patient's Decision</div>
                              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                                {[
                                  { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
                                  { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
                                  { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
                                ].map((d) => (
                                  <button
                                    key={d.v} type="button" className="btn" style={{ padding: '3px 9px', fontSize: 11, background: sc.decision === d.v ? d.color : '', color: sc.decision === d.v ? '#fff' : '', border: sc.decision === d.v ? 'none' : undefined }}
                                    onClick={async () => {
                                      const reason = sc.decision_locked && sc.decision !== d.v ? window.prompt(`Decision is locked (currently "${sc.decision}"). Enter a reason to change it:`) : null;
                                      if (sc.decision_locked && sc.decision !== d.v && !reason) return;
                                      const result = await setDecision(sc.id, d.v, reason);
                                      if (result.error) { setError(result.error); return; }
                                      refresh();
                                    }}
                                  >
                                    {d.label}
                                  </button>
                                ))}
                              </div>
                            </div>
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
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Patient's Decision -- Right Now</label>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {[
                          { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
                          { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
                          { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
                        ].map((d) => (
                          <button
                            key={d.v} type="button" className="btn btn-sm"
                            style={{ background: surgeryDecision === d.v ? d.color : '', color: surgeryDecision === d.v ? '#fff' : '', border: surgeryDecision === d.v ? 'none' : undefined }}
                            onClick={() => setSurgeryDecision(d.v)}
                          >
                            {d.label}
                          </button>
                        ))}
                      </div>
                      <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>
                        "Needs Time to Decide" puts this patient on Front Desk's follow-up list in Surgical Journey. This can be updated later either way.
                      </div>
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

              <GroupHeader num={4} color="var(--amber)" title="Patient Management" />

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
            {data.procedures.length > 0 && (
              <button className="btn" onClick={handleSendForProcedure} disabled={loading}>
                <i className="ti ti-tool"></i> Send for Procedure
              </button>
            )}
          </div>

          {/* Escape hatch -- for a visit that genuinely can't reach the
              diagnosis requirement above (patient left, no-show after
              being called, etc). Kept visually separate from the main
              actions so it isn't a tempting shortcut for normal visits. */}
          {!isReadOnly && (
            <div className="card" style={{ marginTop: 8 }}>
              {!showForceClose ? (
                <button className="btn" style={{ fontSize: 12, color: 'var(--g500)' }} onClick={() => setShowForceClose(true)}>
                  <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
                </button>
              ) : (
                <div>
                  <label className="flbl">Why can&apos;t this visit be completed normally? *</label>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <input className="fi" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                      {forceClosing ? 'Closing...' : 'Confirm'}
                    </button>
                    <button className="btn" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
          </fieldset>

          {/* PRINT ACTIONS -- deliberately kept OUTSIDE the <fieldset
              disabled={isReadOnly}> above. Printing a case sheet / visit
              summary doesn't change any data, so a completed (locked)
              encounter should still allow printing without requiring
              "Unlock to Edit" first. */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <button onClick={() => openPrintPopup(`/opd-case-sheet-print/${data.encounter.id}`)} className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </button>
            <button onClick={() => openPrintPopup(`/visit-summary-print/${data.encounter.id}`)} className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

FILEEOF_consultation_form_js

mkdir -p "app/(main)/consultation"
cat > "app/(main)/consultation/actions.js" << 'FILEEOF_consultation_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';
import { isCurrentUserAdmin } from '@/lib/authz';

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

  let encounter;
  if (entry.status === 'Done') {
    // Most recent encounter for this visit, any status -- not combining
    // .limit() with .maybeSingle() here, since that pairing isn't used
    // anywhere else in this codebase (getOrCreateBiometryRecord uses the
    // same array + length check instead for exactly this kind of lookup).
    const { data: encounters, error: encListError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .order('started_at', { ascending: false })
      .limit(1);
    if (encListError) return { error: encListError.message };
    encounter = encounters && encounters.length > 0 ? encounters[0] : null;
  } else {
    const { data: activeEncounter, error: encActiveError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .eq('status', 'In Consultation')
      .maybeSingle();
    if (encActiveError) return { error: encActiveError.message };
    encounter = activeEncounter;
  }

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    // For a completed (Done) queue entry there's nothing to auto-create --
    // if no encounter exists, the visit genuinely has no clinical record.
    // Auto-creating only makes sense for an active/new consultation.
    if (entry.status === 'Done') {
      return { error: 'No clinical record found for this completed visit.' };
    }
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

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // encounter_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw }, { data: surgicalCases },
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
      .select('id, encounters(id, started_at, status, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    // So "Mark for Surgery" can show what's already been marked instead
    // of silently reverting to a blank button after saving. Scoped by
    // visit_id (one visit, one surgical case), not just this encounter,
    // since a visit can span more than one encounter.
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required, decision, decision_locked').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  // Follow-up Template: same consultation engine, just extra context --
  // a patient is a "follow-up" the moment they have any prior encounter
  // at all, on a different visit, regardless of whether that encounter
  // was ever formally completed (an abandoned/in-progress note still
  // means this isn't their first time being seen).
  const priorEncounters = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorCompletedEncounters = priorEncounters.filter((e) => e.status === 'Completed');
  const isFollowUp = priorEncounters.length > 0;

  if (isFollowUp && encounter.encounter_type !== 'Follow-up') {
    await supabase.from('encounters').update({ encounter_type: 'Follow-up' }).eq('id', encounter.id);
    encounter.encounter_type = 'Follow-up';
  }

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: isAdmin ? (auditLog || []) : [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
    surgicalCases: surgicalCases || [],
    isLocked: encounter.status === 'Completed',
    isFollowUp, priorEncounterId: priorCompletedEncounters[0]?.id || null,
    isAdmin,
  };
}

// ── FOLLOW-UP TEMPLATE CONTEXT ──
// Everything the Follow-up template needs beyond what getConsultationData
// already returns: the visit timeline, patient snapshot, and a summary
// of the immediately preceding visit. Only called when isFollowUp is true.
export async function getFollowUpContext(patientId, currentVisitId, currentEncounterId) {
  const supabase = await createClient();

  const { data: visitsRaw } = await supabase
    .from('visits')
    .select('id, visit_number, encounters(id, started_at, completed_at, chief_complaint, status)')
    .eq('patient_id', patientId);

  const allPriorEncounters = (visitsRaw || [])
    .flatMap((v) => (v.encounters || []).map((e) => ({ ...e, visitId: v.id, visitNumber: v.visit_number })))
    .filter((e) => e.id !== currentEncounterId)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorEncounters = allPriorEncounters.filter((e) => e.status === 'Completed');

  // Map each prior visit back to its Doctor queue entry, so the
  // timeline can open it read-only -- same lookup pattern Patient
  // Timeline already uses.
  const priorVisitIds = [...new Set(allPriorEncounters.map((e) => e.visitId))];
  let queueEntryByVisit = {};
  if (priorVisitIds.length > 0) {
    const { data: entries } = await supabase.from('queue_entries').select('id, visit_id').in('visit_id', priorVisitIds).eq('department', 'Doctor');
    (entries || []).forEach((e) => { queueEntryByVisit[e.visit_id] = e.id; });
  }

  // Timeline shows every prior visit, including ones that were never
  // finalized -- still useful context, just labeled as such.
  const timeline = allPriorEncounters.slice(0, 15).map((e) => ({
    encounterId: e.id, date: e.started_at, chiefComplaint: e.chief_complaint,
    status: e.status, queueEntryId: queueEntryByVisit[e.visitId] || null,
  }));

  const lastEncounter = priorEncounters[0] || null;
  let snapshot = {
    lastVisitDate: lastEncounter?.started_at || null,
    currentDiagnoses: [], currentMedications: [], allergy: null,
    lastVision: null, lastIop: null, surgicalStatus: null,
    previousVisitSummary: null,
    noCompletedPriorVisit: !lastEncounter,
  };
  let newInvestigations = [];

  if (lastEncounter) {
    // Investigations ordered (anywhere -- Counselling, a walk-in
    // Investigation visit, etc.) since the last consultation, with
    // results ready -- these are easy to miss since they don't
    // necessarily belong to *this* encounter's own Investigations list.
    const allEncounterIds = (visitsRaw || []).flatMap((v) => (v.encounters || []).map((e) => e.id));
    if (allEncounterIds.length > 0) {
      const { data: recentInv } = await supabase
        .from('investigation_orders')
        .select('*')
        .in('encounter_id', allEncounterIds)
        .neq('encounter_id', currentEncounterId)
        .eq('status', 'Available')
        .gt('created_at', lastEncounter.started_at)
        .order('created_at', { ascending: false });
      newInvestigations = recentInv || [];
    }
    const [{ data: fullEncounter }, { data: diagnoses }, { data: medications }, { data: assessment }, { data: advice }, { data: fu }] = await Promise.all([
      supabase.from('encounters').select('hx_drug_allergy').eq('id', lastEncounter.id).maybeSingle(),
      supabase.from('diagnoses').select('*').eq('encounter_id', lastEncounter.id).eq('status', 'Active').order('created_at'),
      supabase.from('prescriptions').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('optometry_assessments').select('*').eq('visit_id', lastEncounter.visitId).eq('status', 'Completed').maybeSingle(),
      supabase.from('plan_optical_advice').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('plan_followups').select('*').eq('encounter_id', lastEncounter.id).maybeSingle(),
    ]);

    let lastIop = null;
    if (assessment) {
      const { data: iopReadings } = await supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: false }).limit(1);
      lastIop = iopReadings?.[0] || null;
    }

    const { data: recentSurgicalCase } = await supabase
      .from('surgical_cases').select('procedure_name, eye, status')
      .eq('patient_id', patientId).neq('status', 'Cancelled')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();

    snapshot = {
      lastVisitDate: lastEncounter.started_at,
      currentDiagnoses: diagnoses || [],
      currentMedications: medications || [],
      allergy: fullEncounter?.hx_drug_allergy || null,
      lastVision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
      lastIop,
      surgicalStatus: recentSurgicalCase || null,
      previousVisitSummary: {
        date: lastEncounter.started_at,
        diagnoses: diagnoses || [],
        medications: medications || [],
        advice: advice || [],
        followupPlan: fu || null,
        vision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
        iop: lastIop,
      },
    };
  }

  return { timeline, snapshot, newInvestigations };
}

// ── VISIT OUTCOME ──
export async function saveVisitOutcome(encounterId, outcome) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ visit_outcome: outcome }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CARRY FORWARD a prior diagnosis into the current encounter ──
export async function carryForwardDiagnosis(encounterId, diagnosis) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId, name: diagnosis.name, category: diagnosis.category, eye: diagnosis.eye, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}
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
      drug_history: fields.drugHistory,
      allergy: fields.allergy,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DOCTOR EDITS OPTOMETRY FINDINGS DIRECTLY (in-place override) ──
// The doctor edits the optometrist's own assessment record. Every
// changed field is written to that assessment's audit log (the same
// log the optometrist sees in Optometry History) as a before/after
// entry, so the optometrist can see exactly what was changed and by
// whom -- without a separate shadow record.
const OPTOM_FIELD_LABELS = {
  va_scale: 'VA Scale',
  re_dist_unaided: 'RE Dist Unaided', re_dist_glasses: 'RE Dist Glasses', re_dist_ph: 'RE Dist Pinhole', re_near_unaided: 'RE Near Unaided',
  le_dist_unaided: 'LE Dist Unaided', le_dist_glasses: 'LE Dist Glasses', le_dist_ph: 'LE Dist Pinhole', le_near_unaided: 'LE Near Unaided',
  ref_pd: 'PD', ref_vd: 'VD',
  ref_obj_re_sph: 'RE Obj Sph', ref_obj_re_cyl: 'RE Obj Cyl', ref_obj_re_axis: 'RE Obj Axis',
  ref_obj_le_sph: 'LE Obj Sph', ref_obj_le_cyl: 'LE Obj Cyl', ref_obj_le_axis: 'LE Obj Axis',
  ref_subj_re_sph: 'RE Subj Sph', ref_subj_re_cyl: 'RE Subj Cyl', ref_subj_re_axis: 'RE Subj Axis',
  ref_subj_le_sph: 'LE Subj Sph', ref_subj_le_cyl: 'LE Subj Cyl', ref_subj_le_axis: 'LE Subj Axis',
  ref_final_re_sph: 'RE Final Sph', ref_final_re_cyl: 'RE Final Cyl', ref_final_re_axis: 'RE Final Axis', ref_final_re_add: 'RE Final Add',
  ref_final_le_sph: 'LE Final Sph', ref_final_le_cyl: 'LE Final Cyl', ref_final_le_axis: 'LE Final Axis', ref_final_le_add: 'LE Final Add',
  iop_method: 'IOP Method', iop_time: 'IOP Time',
  add_k1: 'Keratometry K1', add_k2: 'Keratometry K2', add_axial_length: 'Axial Length', add_pachymetry: 'Pachymetry',
  add_white_to_white: 'White-to-White', add_schirmer: 'Schirmer', add_color_vision: 'Color Vision',
  add_ocular_motility: 'Ocular Motility', add_syringing: 'Syringing',
  observation_chips: 'Observation Tags', observations_text: 'Observations',
};

export async function updateOptometryFindings(assessmentId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: current, error: fetchError } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('id', assessmentId)
    .single();
  if (fetchError) return { error: fetchError.message };

  const changes = [];
  const updatePayload = {};
  Object.keys(OPTOM_FIELD_LABELS).forEach((key) => {
    if (fields[key] === undefined) return;
    const oldVal = current[key];
    const newVal = fields[key];
    const oldStr = Array.isArray(oldVal) ? oldVal.join(', ') : (oldVal ?? '');
    const newStr = Array.isArray(newVal) ? newVal.join(', ') : (newVal ?? '');
    if (oldStr === newStr) return;
    updatePayload[key] = newVal;
    changes.push({ label: OPTOM_FIELD_LABELS[key], oldStr: oldStr || '--', newStr: newStr || '--' });
  });

  if (changes.length === 0) return { success: true, changedCount: 0 };

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...updatePayload, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  for (const c of changes) {
    await supabase.from('optometry_audit_log').insert({
      assessment_id: assessmentId,
      message: `Doctor override -- ${c.label}: "${c.oldStr}" -> "${c.newStr}"`,
      created_by: doctorId,
    });
  }

  if (encounterId) {
    await addAudit(supabase, encounterId, `Optometry findings overridden -- ${changes.length} field(s) changed`, doctorId);
  }

  return { success: true, changedCount: changes.length };
}

// Lets the doctor start an optometry assessment directly when the
// patient never went through Optometry -- same table, just created and
// initially owned from the consultation side instead of the queue.
export async function createOptometryAssessmentForVisit(visitId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .insert({ visit_id: visitId, recorded_by: doctorId, completed_by: doctorId, status: 'Completed', completed_at: new Date().toISOString() })
    .select()
    .single();
  if (error) return { error: error.message };

  await supabase.from('optometry_audit_log').insert({ assessment_id: assessment.id, message: 'Assessment started by Doctor -- no prior Optometry visit', created_by: doctorId });
  if (encounterId) await addAudit(supabase, encounterId, 'Optometry assessment created directly by doctor', doctorId);

  return { assessment };
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

export async function updateDiagnosisNotes(id, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').update({ notes: notes?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
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

// Tapering schedule -- same drug and dosage-per-administration across
// steps (that's how tapering actually works clinically: the amount per
// dose stays the same, e.g. 1 drop, only the frequency reduces over
// time), each step a separate row sharing one taper_group_id so they
// render and print as a single continuous instruction, not N unrelated
// prescriptions.
export async function addTaperedPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: s.frequency,
    duration: s.duration,
    eye: values.eye,
    taper_group_id: taperGroupId,
    taper_step: i + 1,
  }));

  const { error } = await supabase.from('prescriptions').insert(rows);
  if (error) return { error: error.message };
  const summary = steps.map((s) => `${s.frequency} x${s.duration}`).join(' -> ');
  await addAudit(supabase, encounterId, `Tapering schedule added: ${values.drugName} (${values.eye}) -- ${summary}`, userData?.user?.id);
  return { success: true };
}

export async function removeTaperGroup(taperGroupId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: rows } = await supabase.from('prescriptions').select('drug_name, eye').eq('taper_group_id', taperGroupId).limit(1);
  const { error } = await supabase.from('prescriptions').delete().eq('taper_group_id', taperGroupId);
  if (error) return { error: error.message };
  if (rows?.[0]) await addAudit(supabase, encounterId, `Tapering schedule removed: ${rows[0].drug_name} (${rows[0].eye})`, userData?.user?.id);
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

  // Biometry is a "special" investigation -- selectable here like any
  // other, but fulfilled through its own dedicated module (device
  // readings for both eyes, IOL recommendations, report upload), not
  // the plain investigation queue. Ordering it here still creates a
  // normal investigation_orders row (shows up in this OPD list like
  // anything else), but also ensures the underlying biometry_records
  // row exists so it correctly routes there. Biometry is patient-level
  // and reusable for years -- if it's already Measured, there's
  // nothing to re-order, just say so instead of creating a duplicate.
  if (values.name.trim().toLowerCase() === 'biometry') {
    const { data: enc } = await supabase.from('encounters').select('visit_id, visits(patient_id)').eq('id', encounterId).single();
    const patientId = enc?.visits?.patient_id;
    if (!patientId) return { error: 'Could not resolve patient for this encounter.' };

    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id, status')
      .eq('patient_id', patientId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (existing && existing.length > 0 && existing[0].status === 'Measured') {
      return { error: 'Biometry is already on file for this patient (Measured) -- no need to re-order. Open it from the Biometry module if you need to review it.' };
    }

    const { error } = await supabase.from('investigation_orders').insert({
      encounter_id: encounterId, name: 'Biometry', eye: values.eye, priority: values.priority,
    });
    if (error) return { error: error.message };

    if (!existing || existing.length === 0) {
      await supabase.from('biometry_records').insert({ patient_id: patientId, visit_id: enc.visit_id, encounter_id: encounterId });
    }

    await addAudit(supabase, encounterId, 'Biometry ordered', userData?.user?.id);
    return { success: true };
  }

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

export async function addProcedure(encounterId, name, eye, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, notes: notes || null, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Minor Procedure planned: ${name} (${eye})`, userData?.user?.id);
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

// Minor Procedures are performed by the doctor directly, in the same
// sitting -- unlike Dilation/Investigation/Biometry there's no separate
// department to route the patient to, so this just confirms the
// procedure(s) for the audit trail. Billing already picks them up the
// moment they're added (billing_status defaults to 'Pending'); this
// doesn't change that.
export async function sendForProcedureFromConsultation(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Sent for Procedure', userData?.user?.id);
  return { success: true };
}

// Shared by both the "Add" button (advises Biometry without moving the
// patient anywhere yet) and "Send for Biometry" (which also routes the
// queue) -- creates the record if none exists yet for that eye, or
// Biometry is patient-level now, not visit/case-level, and always
// covers both eyes -- one session is reused across every future
// surgical case for that patient (readings don't meaningfully change
// for years). "Advise" just ensures a record exists for this patient,
// updating instructions if one already does.
async function ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: created } = await supabase.from('biometry_records').insert({
      patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null,
      doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// The "Add" step -- advises Biometry is needed (records instructions,
// if any) without moving the patient's queue position at all. Mirrors
// exactly how Investigations work: "Add" saves the order, "Send for
// Investigation" is a separate, later action that routes the patient.
export async function adviseBiometry(patientId, visitId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions);
  await addAudit(supabase, encounterId, 'Biometry advised', userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, patientId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, 'Sent for Biometry', userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  await ensureBiometryRecord(supabase, patientId, entry?.visit_id || null, encounterId, instructions);

  return result;
}

// For updating instructions on a biometry record that's already been
// sent -- eye is fixed once a record exists (changing it would mean a
// different physical record, not editing this one), but instructions
// can still be corrected/added at any point before the technician
// finishes.
// Doctor can remove a mistakenly-added/sent biometry request (wrong
// eye, duplicate, etc.) -- but only while it's still unbilled. Once
// Front Office has billed it, removing the record here would leave an
// invoice line with nothing behind it, so that has to go through
// billing's own modification flow instead.
export async function removeBiometryRecord(id, encounterId) {
  const supabase = await createClient();
  const { data: record } = await supabase.from('biometry_records').select('billing_status').eq('id', id).maybeSingle();
  if (!record) return { error: 'Record not found.' };
  if (record.billing_status === 'Billed') {
    return { error: 'This has already been billed and cannot be removed here -- use Billing to modify the invoice first.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('biometry_records').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Biometry request removed', userData?.user?.id);
  return { success: true };
}

export async function updateBiometryInstructions(id, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_records').update({ doctor_instructions: instructions?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function saveDraft(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Consultation saved as draft', userData?.user?.id);
  return { success: true };
}

FILEEOF_consultation_actions_js

mkdir -p "app/print-templates"
cat > "app/print-templates/actions.js" << 'FILEEOF_print_templates_actions_js'
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
  medicine_prescription: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    MEDICINE PRESCRIPTION\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">VISIT NO</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DATE</td><td>: <strong>{{print_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Medicines Prescribed</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 7px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">How Often</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; font-weight: 600;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 9px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 7px; text-align: center; font-size: 11.5px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{else}}\n  <div style=\"font-size: 12.5px; color: #9ca3af; margin-bottom: 14px;\">No medicines prescribed for this visit.</div>\n  {{/if}}\n\n  <div style=\"background: #eef4fb; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12px; color: #123a66; margin-bottom: 20px;\">\n    Please take medicines exactly as instructed above. If you have any doubt about how to use a medicine, ask the pharmacist before you leave.\n  </div>\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>Dr. {{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n"
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
  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ', manufacturer: 'Alcon Laboratories' },
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
    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}${catalogItem.manufacturer ? ` (${catalogItem.manufacturer})` : ''}`.trim() : '--',
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
FILEEOF_print_templates_actions_js

echo "Files written. Run: npm run build"
