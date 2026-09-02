'use client';

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
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
import { markForSurgery, markSameDaySurgicalEval, updateSurgicalCase, setDecision, addCaseProcedure, removeCaseProcedure } from '@/app/(main)/counselling/actions';
import { SURGICAL_TRACK_VISIT_TYPES } from '@/lib/visit-types';
import { getDiagnosesMaster, getDrugs, getDosageOptions, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import OptometryWorkspace from '@/app/(main)/optometry/[id]/optometry-workspace';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';
import { openPrintPopup } from '@/lib/printPopup';
import ConfirmActionModal from '@/app/components/ConfirmActionModal';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// "15 Aug 2026" style, for the biometry re-order confirmation message.
function formatDateReadable(isoTimestamp) {
  if (!isoTimestamp) return 'an earlier visit';
  return new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(isoTimestamp));
}

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
          <strong>{d.name}</strong> -- {d.eye}
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
  // null | 'complete' | 'dilate' | 'investigate' | 'procedure' -- which
  // of the bottom action bar's confirmation modals is currently open.
  const [confirmAction, setConfirmAction] = useState(null);
  // Set when addInvestigation comes back asking to confirm a fresh
  // Biometry order despite an existing "Measured" record on file --
  // holds the date so the modal can show it, and the in-flight
  // name/eye/priority so "Yes, order a fresh one" can resubmit with
  // confirmFreshBiometry: true without the doctor retyping anything.
  const [biometryReorderPrompt, setBiometryReorderPrompt] = useState(null);
  const [biometryReorderLoading, setBiometryReorderLoading] = useState(false);
  // Asked inside the Complete Visit confirmation, only when this
  // encounter just advised a surgery AND the visit itself isn't
  // already a surgical-track visit type (Surgery Evaluation etc.) --
  // those already show on the Surgeon Dashboard on their own. null
  // means "not answered yet" (default is treated as No on complete).
  const [sameDayEvalChoice, setSameDayEvalChoice] = useState(null);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  // Pre Op Requirement -- doctor picks the actual pre-op investigations
  // this surgery needs (e.g. Biometry, or none) from the same
  // Investigations master used in Section 1. These are indicative only
  // -- NOT ordered from here. Surgical Journey's own Investigations
  // step shows them as one-click suggestions; the actual order only
  // gets placed when someone acts on it there. Medical Fitness
  // clearance is required for every surgical case (see
  // fitness_required in markForSurgery), so there's no per-case choice
  // for it here.
  const [surgeryInvestigations, setSurgeryInvestigations] = useState([]);
  const [surgeryInvEye, setSurgeryInvEye] = useState('OU');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [surgeryDecision, setSurgeryDecision] = useState('');
  // Additional procedures for a combined surgery, staged client-side
  // BEFORE Save is even clicked (the surgical case doesn't exist yet,
  // so there's nothing to attach these to in the database until then).
  // On Save, handleMarkForSurgery creates the primary case first, then
  // loops through this list calling addCaseProcedure for each --
  // functionally identical to adding them one at a time afterward via
  // the "Additional Procedures" section below, just batched into one
  // click. Cleared on save/cancel like the other surgery-advice fields.
  const [pendingCaseProcedures, setPendingCaseProcedures] = useState([]);
  const [showPendingProc, setShowPendingProc] = useState(false);
  const [pendingProcName, setPendingProcName] = useState('');
  const [pendingProcEye, setPendingProcEye] = useState('OU');
  const [pendingProcNotes, setPendingProcNotes] = useState('');
  // Additional procedures performed within the same surgery (e.g. this
  // case is Cataract, adding Anti-VEGF Injection alongside it) --
  // staging fields for the small add-procedure form under the saved
  // case. Package/price for each is picked later in Surgical Journey,
  // same as the primary case's own package.
  const [showAddProcedure, setShowAddProcedure] = useState(false);
  const [addProcName, setAddProcName] = useState('');
  const [addProcEye, setAddProcEye] = useState('OU');
  const [addProcNotes, setAddProcNotes] = useState('');
  const [addProcLoading, setAddProcLoading] = useState(false);
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryInvestigations, setEditSurgeryInvestigations] = useState([]);
  const [editSurgeryInvEye, setEditSurgeryInvEye] = useState('OU');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('optometry');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  // Dosage can now vary per step too (e.g. 2 tablets tapering down to
  // 1 tablet, not just the frequency reducing) -- each step defaults to
  // whatever's in the main Dosage field the moment the builder opens
  // (the "first instance"), then is independently editable per step.
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week', dosage: '' },
    { frequency: 'TDS', duration: '1 week', dosage: '' },
    { frequency: 'BD', duration: '1 week', dosage: '' },
    { frequency: 'OD', duration: '1 week', dosage: '' },
  ]);
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');
  const [rxIsOcular, setRxIsOcular] = useState(true);

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const invPriority = 'Routine'; // selector removed -- no longer needed

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [procNotes, setProcNotes] = useState('');
  // Defaults to today -- most OPD procedures are still done in the same
  // sitting. Change it to a future date when the patient needs to come
  // back separately; see the Doctor Dashboard's "OPD Procedures Due
  // Today" widget for how that surfaces later.
  const [procDate, setProcDate] = useState(todayIst());
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [fuAfter, setFuAfter] = useState('1 month');
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
      setProcedureOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'OPD Procedure'));
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
      setFuAfter(data.followup.after_period || '1 month');
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
    const result = await addDiagnosis(data.encounter.id, { name: dxName, eye: dxEye });
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
    // Tablets/capsules/syrups/injections aren't applied to an eye --
    // skip the Eye field entirely for those instead of forcing a
    // meaningless RE/LE/BE choice. Unknown/free-text drugs default to
    // showing it (can't tell, and most of this hospital's prescribing
    // is ocular anyway).
    setRxIsOcular(d.master_drug_types?.is_ocular !== false);
    setRxDosage('');
    setShowRxSuggestions(false);
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week', dosage: rxDosage }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    // Dosage is per-step now -- any step left blank falls back to the
    // main Dosage field's value, but the main field itself is no longer
    // required on its own (a doctor may fill dosage only in the steps).
    const steps = taperSteps.map((s) => ({ ...s, dosage: s.dosage || rxDosage }));
    if (steps.some((s) => !s.dosage.trim())) { setError('Select a dosage for every step of the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, eye: rxIsOcular ? rxEye : 'Oral', steps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setRxIsOcular(true); setShowTaperBuilder(false);
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxIsOcular ? rxEye : 'Oral',
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const values = { name: invName, eye: invEye, priority: invPriority };
    const result = await addInvestigation(data.encounter.id, values);
    if (result.needsConfirmation === 'biometry') {
      setBiometryReorderPrompt({ values, existingDate: result.existingBiometryDate });
      return;
    }
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  // Resolves the biometry re-order confirmation -- both choices create
  // this visit's investigation_orders row (so it shows up in the list
  // below either way); they only differ in whether ensureBiometryRecord
  // makes a fresh biometry_records row or attaches the existing one.
  // 'existing' is NOT a no-op/cancel -- the whole point of asking was
  // that silently doing nothing left nothing visible on this visit.
  async function resolveBiometryReorder(choice) {
    if (!biometryReorderPrompt) return;
    setError('');
    setBiometryReorderLoading(true);
    const result = await addInvestigation(data.encounter.id, { ...biometryReorderPrompt.values, biometryChoice: choice });
    setBiometryReorderLoading(false);
    setBiometryReorderPrompt(null);
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
    const result = await addProcedure(data.encounter.id, procName, procEye, procNotes, procDate);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    setProcNotes('');
    setProcDate(todayIst());
    refresh();
  }

  function handleSendForProcedure() {
    setConfirmAction('procedure');
  }

  async function runSendForProcedure() {
    setError('');
    setLoading(true);
    const result = await sendForProcedureFromConsultation(data.encounter.id);
    setLoading(false);
    if (result.error) { setConfirmAction(null); setError(result.error); return; }
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

  function handleComplete() {
    setSameDayEvalChoice(null);
    setConfirmAction('complete');
  }

  async function runComplete() {
    setError('');
    setLoading(true);
    // Some patients undergo surgical evaluation the SAME day a surgery
    // is advised, independent of whether they've decided yet -- flip
    // this before completing so they show on the Surgeon Dashboard's
    // Surgical Evaluation section today rather than only being
    // reachable from the Surgical Journey screen.
    if (needsSameDayEvalPrompt && sameDayEvalChoice !== null) {
      await markSameDaySurgicalEval(data.encounter.id, sameDayEvalChoice);
    }
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setConfirmAction(null); setError(result.error); return; }
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

  function addSurgeryInvestigation(name) {
    if (!name?.trim()) return;
    setSurgeryInvestigations((list) => [...list, { name: name.trim(), eye: surgeryInvEye }]);
  }
  function removeSurgeryInvestigation(idx) {
    setSurgeryInvestigations((list) => list.filter((_, i) => i !== idx));
  }
  function addEditSurgeryInvestigation(name) {
    if (!name?.trim()) return;
    setEditSurgeryInvestigations((list) => [...list, { name: name.trim(), eye: editSurgeryInvEye }]);
  }
  function removeEditSurgeryInvestigation(idx) {
    setEditSurgeryInvestigations((list) => list.filter((_, i) => i !== idx));
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    // Decision is deliberately NOT required here anymore -- markForSurgery
    // already accepts a null decision (the DB column is nullable, and
    // every downstream read of .decision checks it against a specific
    // value like 'Accepted'/'Declined', both false for null, so an
    // undecided case behaves correctly everywhere it's read). This lets
    // the doctor save the primary procedure first, which immediately
    // reveals "Additional Procedures in This Surgery" below, so a
    // combined surgery (e.g. Cataract + Anti-VEGF) can be fully listed
    // before the decision is ever touched -- the decision buttons stay
    // right there in the same expanded view for whenever it's ready.
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryInvestigations, surgeryNotes, surgeryDecision || null);
    if (result.error) {
      setSurgeryLoading(false);
      setError(result.error);
      return;
    }
    // Attach whatever additional procedures were staged before Save --
    // sequential, not Promise.all, so a failure partway through leaves
    // a predictable, reportable set of what did/didn't make it rather
    // than a race between rows that all reference the same brand-new
    // caseId.
    const failedProcedures = [];
    for (const p of pendingCaseProcedures) {
      const addResult = await addCaseProcedure(result.caseId, p.name, p.eye, p.notes);
      if (addResult.error) failedProcedures.push(`${p.name} (${addResult.error})`);
    }
    setSurgeryLoading(false);
    if (failedProcedures.length > 0) {
      // The primary case saved fine either way -- this only reports the
      // additional procedures that didn't attach, so nothing here is
      // silently lost. They can still be added from the "Additional
      // Procedures" section that appears now that the case exists.
      setError(`Surgery saved, but these additional procedures could not be added: ${failedProcedures.join(', ')}. You can add them below.`);
    }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryInvestigations([]);
    setSurgeryNotes('');
    setSurgeryDecision('');
    setPendingCaseProcedures([]);
    setShowPendingProc(false);
    setPendingProcName('');
    setPendingProcNotes('');
    refresh();
  }

  async function handleAddCaseProcedure(caseId) {
    setError('');
    if (!addProcName) { setError('Select a procedure.'); return; }
    setAddProcLoading(true);
    const result = await addCaseProcedure(caseId, addProcName, addProcEye, addProcNotes);
    setAddProcLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowAddProcedure(false);
    setAddProcName('');
    setAddProcNotes('');
    refresh();
  }

  async function handleRemoveCaseProcedure(procedureId) {
    setError('');
    if (!window.confirm('Remove this procedure from the surgery?')) return;
    const result = await removeCaseProcedure(procedureId);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  // Purely local -- nothing hits the database until handleMarkForSurgery
  // saves the primary case and then attaches each of these. Mirrors
  // handleAddCaseProcedure/handleRemoveCaseProcedure's validation and
  // reset behavior so the two flows feel identical to use even though
  // one is staged and one writes immediately.
  function addPendingCaseProcedure() {
    setError('');
    if (!pendingProcName) { setError('Select a procedure.'); return; }
    setPendingCaseProcedures((list) => [...list, { name: pendingProcName, eye: pendingProcEye, notes: pendingProcNotes.trim() }]);
    setShowPendingProc(false);
    setPendingProcName('');
    setPendingProcNotes('');
  }
  function removePendingCaseProcedure(idx) {
    setPendingCaseProcedures((list) => list.filter((_, i) => i !== idx));
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryInvestigations(sc.indicative_investigations || []);
    setEditSurgeryNotes(sc.notes || '');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryInvestigations, editSurgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  function handleSendOut(kind) {
    setConfirmAction(kind === 'dilate' ? 'dilate' : 'investigate');
  }

  async function runSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setConfirmAction(null); setError(result.error); return; }
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
  // Only prompted when this encounter actually advised a surgery AND
  // the visit itself isn't already a surgical-track visit type
  // (Surgery Evaluation, Investigation Only) -- those already surface
  // on the Surgeon Dashboard on their own via visit_type, no flag
  // needed.
  const needsSameDayEvalPrompt = data.surgicalCases.length > 0 && !SURGICAL_TRACK_VISIT_TYPES.includes(data.entry.visits.visit_type);
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye || 'Oral'})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    // Future-dated procedures (or ones a decision has already been
    // recorded for) now live in the OPD Procedures module's own
    // decision -> schedule -> check-in -> complete flow, so the
    // one-click "mark done" here is only offered for the original
    // same-sitting/same-day case.
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' && !p.decision && (!p.scheduled_date || p.scheduled_date <= todayIst()) })),
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
              {formatPatientName(patient)}
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
            <OptometryWorkspace queueEntryId={queueEntryId} embedded forceUnlocked={unlocked} />
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
                  // Biometry is a special investigation -- it's fulfilled
                  // through its own dedicated module (device readings,
                  // IOL recommendations, surgeon approval), not the plain
                  // Investigation workspace. Route it to the specific
                  // biometry_records row instead of the module's generic
                  // landing page, same as Surgical Journey's own version
                  // of this list -- so choosing "keep existing" in the
                  // re-order confirmation still opens straight to that
                  // record here, exactly like a freshly-ordered one would.
                  const isBiometry = i.name.trim().toLowerCase() === 'biometry';
                  const bioRecord = isBiometry ? data.biometryRecords[0] : null;
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
                          {isBiometry ? (
                            <a href={bioRecord?.id ? `/biometry/${bioRecord.id}` : '/biometry'} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '2px 8px', fontSize: 11, textDecoration: 'none' }}>
                              <i className="ti ti-ruler-measure"></i> {bioRecord?.status === 'Measured' ? 'View Report' : 'Open Biometry'}
                            </a>
                          ) : hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {!isBiometry && i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {!isBiometry && hasResults && (
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
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye || 'Oral'})
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
                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye || 'Oral'}
                      </span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ) : (
                    <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <span style={{ fontSize: 13 }}>
                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye || 'Oral'}
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
                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setRxIsOcular(true); setShowRxSuggestions(true); }}
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
                    <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
                    <option>1 week</option><option>2 weeks</option><option>10 days</option>
                    <option>1 month</option><option>2 months</option><option>3 months</option><option>4 months</option><option>5 months</option><option>6 months</option>
                    <option>Ongoing</option>
                  </select>
                  {rxIsOcular ? (
                    <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
                      <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                    </select>
                  ) : (
                    <div className="fi" style={{ width: 110, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--g500)', fontWeight: 600 }}>Oral</div>
                  )}
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>

                {!showTaperBuilder ? (
                  <button
                    className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }}
                    onClick={() => { setShowTaperBuilder(true); setTaperSteps((prev) => prev.map((s) => ({ ...s, dosage: s.dosage || rxDosage }))); }}
                  >
                    <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                  </button>
                ) : (
                  <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug{rxIsOcular ? ' & Eye' : ''} entered above; dosage defaults to what you set above but can vary per step below, alongside frequency and duration
                    </div>
                    {taperSteps.map((s, i) => (
                      <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                        <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                        <select className="fi fi-sm" value={s.dosage} onChange={(e) => updateTaperStep(i, 'dosage', e.target.value)} style={{ maxWidth: 110 }}>
                          <option value="">-- Dosage --</option>
                          {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => (
                            <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                          ))}
                          {!rxDrugTypeId && (
                            <>
                              <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                            </>
                          )}
                        </select>
                        <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                          <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                        </select>
                        <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                          <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
                          <option>1 week</option><option>2 weeks</option><option>10 days</option>
                          <option>1 month</option><option>2 months</option><option>3 months</option><option>4 months</option><option>5 months</option><option>6 months</option>
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
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> OPD Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span>
                          {p.name} -- {p.eye}
                          {p.scheduled_date && p.scheduled_date !== todayIst() && (
                            <span className="badge b-amber" style={{ marginLeft: 6, fontSize: 10 }}>
                              <i className="ti ti-calendar-event"></i> {new Date(p.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}
                            </span>
                          )}
                        </span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                      {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{p.notes}</div>}
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select OPD procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name} -- Rs.{p.rate}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 110 }}>
                      <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                    </select>
                    <input
                      type="date" className="fi fi-sm" value={procDate} min={todayIst()} onChange={(e) => setProcDate(e.target.value)}
                      style={{ width: 140 }} title="Date this procedure is to be performed -- defaults to today"
                    />
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
                              <label className="flbl">Pre Op Requirement</label>
                              <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>
                                Indicative pre-op investigations for this surgery -- shown as one-click suggestions in Surgical Journey&apos;s own Investigations step; the actual order is placed from there, not here.
                              </div>
                              {editSurgeryInvestigations.length > 0 && (
                                <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 6 }}>
                                  {editSurgeryInvestigations.map((inv, idx) => (
                                    <span key={idx} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 8px', borderRadius: 20, fontSize: 11, fontWeight: 600, background: 'var(--g50)', color: 'var(--red)', border: '1px solid var(--red)' }}>
                                      {inv.name} ({inv.eye})
                                      <i className="ti ti-x" style={{ cursor: 'pointer' }} onClick={() => removeEditSurgeryInvestigation(idx)}></i>
                                    </span>
                                  ))}
                                </div>
                              )}
                              <div style={{ display: 'flex', gap: 6 }}>
                                <select className="fi fi-sm" value="" onChange={(e) => addEditSurgeryInvestigation(e.target.value)} style={{ flex: 1 }}>
                                  <option value="">-- Pick an investigation to add --</option>
                                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                                </select>
                                <select className="fi fi-sm" value={editSurgeryInvEye} onChange={(e) => setEditSurgeryInvEye(e.target.value)} style={{ width: 90 }}>
                                  <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
                                </select>
                              </div>
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
                            {sc.indicative_investigations && sc.indicative_investigations.length > 0 && (
                              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3, marginLeft: 22 }}>
                                <i className="ti ti-flask"></i> Pre Op Requirement: {sc.indicative_investigations.map((inv) => `${inv.name} (${inv.eye})`).join(', ')}
                              </div>
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

                        {/* ADDITIONAL PROCEDURES -- deliberately OUTSIDE the
                            edit/display ternary above so it stays visible
                            even while the primary procedure is being
                            edited, instead of disappearing until Save is
                            clicked. This surgical_cases row is still the
                            whole surgery: one OT booking, one check-in,
                            one consent. This just lists other procedures
                            performed in the same sitting (e.g. Anti-VEGF
                            Injection alongside Cataract) -- each gets its
                            own package/price, picked later in Surgical
                            Journey. */}
                        <div style={{ marginTop: 10, marginLeft: 22 }}>
                          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 4 }}>Additional Procedures in This Surgery</div>
                          {data.caseProcedures.map((p) => (
                            <div key={p.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0', fontSize: 12 }}>
                              <i className="ti ti-point" style={{ color: 'var(--g400)' }}></i>
                              <span style={{ flex: 1 }}>
                                {p.procedure_name} -- {p.eye === 'OD' ? 'Right (OD)' : p.eye === 'OS' ? 'Left (OS)' : 'Both (OU)'}
                                {p.notes && <span style={{ color: 'var(--g400)' }}> ({p.notes})</span>}
                              </span>
                              {sc.status === 'Pending Workup' && (
                                <i className="ti ti-trash" style={{ cursor: 'pointer', color: 'var(--red)' }} onClick={() => handleRemoveCaseProcedure(p.id)}></i>
                              )}
                            </div>
                          ))}
                          {sc.status === 'Pending Workup' && (
                            !showAddProcedure ? (
                              <button className="btn" style={{ padding: '2px 8px', fontSize: 11, marginTop: 4 }} onClick={() => setShowAddProcedure(true)}>
                                <i className="ti ti-plus"></i> Add Procedure
                              </button>
                            ) : (
                              <div style={{ marginTop: 6, padding: 8, background: 'var(--g50)', borderRadius: 6 }}>
                                <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                                  <select className="fi fi-sm" value={addProcName} onChange={(e) => setAddProcName(e.target.value)} style={{ flex: 2 }}>
                                    <option value="">-- Select procedure --</option>
                                    {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                                  </select>
                                  <select className="fi fi-sm" value={addProcEye} onChange={(e) => setAddProcEye(e.target.value)} style={{ width: 100 }}>
                                    <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
                                  </select>
                                </div>
                                <input className="fi fi-sm" placeholder="Notes (optional)" value={addProcNotes} onChange={(e) => setAddProcNotes(e.target.value)} style={{ marginBottom: 6 }} />
                                <div style={{ display: 'flex', gap: 6 }}>
                                  <button className="btn btn-primary btn-sm" onClick={() => handleAddCaseProcedure(sc.id)} disabled={addProcLoading}>
                                    {addProcLoading ? 'Adding...' : 'Add'}
                                  </button>
                                  <button className="btn btn-sm" onClick={() => { setShowAddProcedure(false); setAddProcName(''); setAddProcNotes(''); }}>Cancel</button>
                                </div>
                              </div>
                            )
                          )}
                        </div>
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for IPD Procedure
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
                      <label className="flbl">Pre Op Requirement</label>
                      <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>
                        Only IOL/lens surgeries (e.g. cataract) genuinely need Biometry -- most surgeries (pterygium, DCR, chalazion, oculoplasty, etc.) need no pre-op investigation at all. Pick whatever this specific case needs from the Investigations master, same list as Section 1 -- these are indicative only, shown as one-click suggestions in Surgical Journey&apos;s own Investigations step; the actual order is placed from there, not here. Medical Fitness clearance is required for every case, so there's nothing to pick for that.
                      </div>
                      {surgeryInvestigations.length > 0 && (
                        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 6 }}>
                          {surgeryInvestigations.map((inv, idx) => (
                            <span key={idx} style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 8px', borderRadius: 20, fontSize: 11, fontWeight: 600, background: 'var(--g50)', color: 'var(--red)', border: '1px solid var(--red)' }}>
                              {inv.name} ({inv.eye})
                              <i className="ti ti-x" style={{ cursor: 'pointer' }} onClick={() => removeSurgeryInvestigation(idx)}></i>
                            </span>
                          ))}
                        </div>
                      )}
                      <div style={{ display: 'flex', gap: 6 }}>
                        <select className="fi fi-sm" value="" onChange={(e) => addSurgeryInvestigation(e.target.value)} style={{ flex: 1 }}>
                          <option value="">-- Pick an investigation to add --</option>
                          {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                        </select>
                        <select className="fi fi-sm" value={surgeryInvEye} onChange={(e) => setSurgeryInvEye(e.target.value)} style={{ width: 90 }}>
                          <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
                        </select>
                      </div>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Additional Procedures in This Surgery (optional)</label>
                      <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>
                        Other procedures done in the same sitting as the one above (e.g. Anti-VEGF Injection alongside Cataract). Added here now, or from the same section after Save -- either way, before or after the decision is recorded.
                      </div>
                      {pendingCaseProcedures.map((p, idx) => (
                        <div key={idx} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0', fontSize: 12 }}>
                          <i className="ti ti-point" style={{ color: 'var(--g400)' }}></i>
                          <span style={{ flex: 1 }}>
                            {p.name} -- {p.eye === 'OD' ? 'Right (OD)' : p.eye === 'OS' ? 'Left (OS)' : 'Both (OU)'}
                            {p.notes && <span style={{ color: 'var(--g400)' }}> ({p.notes})</span>}
                          </span>
                          <i className="ti ti-trash" style={{ cursor: 'pointer', color: 'var(--red)' }} onClick={() => removePendingCaseProcedure(idx)}></i>
                        </div>
                      ))}
                      {!showPendingProc ? (
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11, marginTop: 4 }} onClick={() => setShowPendingProc(true)}>
                          <i className="ti ti-plus"></i> Add Procedure
                        </button>
                      ) : (
                        <div style={{ marginTop: 6, padding: 8, background: 'var(--g50)', borderRadius: 6 }}>
                          <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                            <select className="fi fi-sm" value={pendingProcName} onChange={(e) => setPendingProcName(e.target.value)} style={{ flex: 2 }}>
                              <option value="">-- Select procedure --</option>
                              {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                            </select>
                            <select className="fi fi-sm" value={pendingProcEye} onChange={(e) => setPendingProcEye(e.target.value)} style={{ width: 100 }}>
                              <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
                            </select>
                          </div>
                          <input className="fi fi-sm" placeholder="Notes (optional)" value={pendingProcNotes} onChange={(e) => setPendingProcNotes(e.target.value)} style={{ marginBottom: 6 }} />
                          <div style={{ display: 'flex', gap: 6 }}>
                            <button className="btn btn-primary btn-sm" onClick={addPendingCaseProcedure}>Add</button>
                            <button className="btn btn-sm" onClick={() => { setShowPendingProc(false); setPendingProcName(''); setPendingProcNotes(''); }}>Cancel</button>
                          </div>
                        </div>
                      )}
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Patient's Decision -- Right Now (optional)</label>
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
                        "Needs Time to Decide" puts this patient on Front Desk's follow-up list in Surgical Journey. This can be updated later either way -- and so can the additional procedures above, from the same section once the case exists.
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => { setShowSurgery(false); setPendingCaseProcedures([]); setShowPendingProc(false); setPendingProcName(''); setPendingProcNotes(''); }}>Cancel</button>
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
                      <option>1 day</option><option>5 days</option><option>10 days</option><option>15 days</option><option>3 weeks</option><option>1 month</option><option>2 months</option><option>3 months</option><option>SOS</option>
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

          {confirmAction === 'complete' && (
            <ConfirmActionModal
              icon="ti-circle-check" iconColor="var(--teal)" iconBg="rgba(13,148,136,.12)"
              title="Complete Visit?"
              description="This finalizes the consultation and closes this window. Make sure findings, diagnosis, and prescriptions are all saved before continuing."
              confirmLabel="Yes, Complete Visit"
              loading={loading}
              onCancel={() => setConfirmAction(null)}
              onConfirm={runComplete}
            >
              {needsSameDayEvalPrompt && (
                <div style={{ padding: '10px 12px', background: 'var(--g50)', border: '1px solid var(--indigo)', borderRadius: 8 }}>
                  <div style={{ fontSize: 12.5, fontWeight: 600, color: 'var(--g700)', marginBottom: 8 }}>
                    <i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Does the patient want to get evaluated for surgery today?
                  </div>
                  <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 8 }}>
                    Independent of their decision -- if yes, they'll show up in the Surgeon Dashboard's Surgical Evaluation section right away instead of only on Surgical Journey.
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button
                      type="button" className="btn btn-sm"
                      style={{ background: sameDayEvalChoice === true ? 'var(--green)' : '', color: sameDayEvalChoice === true ? '#fff' : '', border: sameDayEvalChoice === true ? 'none' : undefined }}
                      onClick={() => setSameDayEvalChoice(true)}
                    >
                      Yes
                    </button>
                    <button
                      type="button" className="btn btn-sm"
                      style={{ background: sameDayEvalChoice === false ? 'var(--g500)' : '', color: sameDayEvalChoice === false ? '#fff' : '', border: sameDayEvalChoice === false ? 'none' : undefined }}
                      onClick={() => setSameDayEvalChoice(false)}
                    >
                      No
                    </button>
                  </div>
                </div>
              )}
            </ConfirmActionModal>
          )}
          {confirmAction === 'dilate' && (
            <ConfirmActionModal
              icon="ti-droplet" iconColor="var(--blue)" iconBg="var(--blue-lt)"
              title="Send for Dilation?"
              description="Routes the patient out for pupil dilation and closes this window. You'll pick the consultation back up once they return."
              confirmLabel="Yes, Send for Dilation"
              loading={loading}
              onCancel={() => setConfirmAction(null)}
              onConfirm={() => runSendOut('dilate')}
            />
          )}
          {confirmAction === 'investigate' && (
            <ConfirmActionModal
              icon="ti-flask" iconColor="var(--purple)" iconBg="rgba(124,58,237,.12)"
              title="Send for Investigation?"
              description="Routes the patient for their pending investigation(s) and closes this window."
              confirmLabel="Yes, Send for Investigation"
              loading={loading}
              onCancel={() => setConfirmAction(null)}
              onConfirm={() => runSendOut('investigate')}
            />
          )}
          {confirmAction === 'procedure' && (
            <ConfirmActionModal
              icon="ti-tool" iconColor="var(--amber)" iconBg="rgba(217,119,6,.12)"
              title="Send for Procedure?"
              description="Routes the patient for their pending procedure(s) and closes this window."
              confirmLabel="Yes, Send for Procedure"
              loading={loading}
              onCancel={() => setConfirmAction(null)}
              onConfirm={runSendForProcedure}
            />
          )}

          {biometryReorderPrompt && (
            <ConfirmActionModal
              icon="ti-ruler-2" iconColor="var(--purple)" iconBg="rgba(124,58,237,.12)"
              title="Biometry already on file"
              description={`Biometry for this patient was already measured on ${formatDateReadable(biometryReorderPrompt.existingDate)} and is available in the Biometry module. Order a fresh measurement, or attach the existing record to this visit?`}
              confirmLabel="Yes, order a fresh one"
              cancelLabel="No, use existing"
              loading={biometryReorderLoading}
              onCancel={() => resolveBiometryReorder('existing')}
              onConfirm={() => resolveBiometryReorder('fresh')}
            />
          )}

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

