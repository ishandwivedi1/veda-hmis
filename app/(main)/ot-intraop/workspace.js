'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import {
  getOTCaseDetail,
  saveCheckinItems, completeCheckin, recordAnaesthesia, saveIntraopDraft, saveCheckinIolVerification,
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

  // Check-In's OWN verification of the physical IOL on hand vs the
  // approved plan -- separate state and separate DB columns
  // (verified_iol_*) from the im* fields above, which record what was
  // ACTUALLY implanted (recorded in Intraop, can differ from what was
  // verified at check-in if a complication forces a substitution).
  const [cvMfr, setCvMfr] = useState('');
  const [cvModel, setCvModel] = useState('');
  const [cvCatalogId, setCvCatalogId] = useState('');
  const [cvIolMode, setCvIolMode] = useState('catalog'); // 'catalog' | 'other'
  const [cvPower, setCvPower] = useState('');
  const [cvCategory, setCvCategory] = useState('');
  const [cvSerial, setCvSerial] = useState('');
  const [cvExpiry, setCvExpiry] = useState('');
  const [cvEye, setCvEye] = useState('OD');
  const [cvVarianceReason, setCvVarianceReason] = useState('');
  const [savingVerification, setSavingVerification] = useState(false);

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
  const [checkinUnlocked, setCheckinUnlocked] = useState(false);

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
      setImMfr(io.implant_manufacturer || io.verified_iol_manufacturer || '');
      setImModel(io.implant_model || io.verified_iol_model || '');
      setImCatalogId(io.implant_catalog_id || io.verified_iol_catalog_id || '');
      // Records saved before the catalog dropdown existed have
      // manufacturer/model as free text with no catalog link -- default
      // to "Other" mode so that data is immediately visible instead of
      // silently disappearing behind an unselected dropdown.
      setImIolMode((io.implant_catalog_id || io.verified_iol_catalog_id) ? 'catalog' : (io.implant_manufacturer || io.implant_model) ? 'other' : 'catalog');
      // Defaults to whatever Check-In verified as physically present --
      // that's usually what gets implanted -- but this is fully
      // editable here, since a complication can force a different IOL
      // to actually go in. Nothing here overwrites verified_iol_*.
      setImPower(io.implant_power || io.verified_iol_power || result.biometryPlans[0]?.power || '');
      setImCategory(io.implant_category || io.verified_iol_category || result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImSerial(io.implant_serial || io.verified_iol_serial || '');
      setImExpiry(io.implant_expiry || io.verified_iol_expiry || '');
      // Eye to be implanted is always derived from the Surgery section
      // (surgical_cases.eye, set by the doctor in Diagnosis & Plan) --
      // never from Biometry, which can legitimately be done for a
      // different/single eye even on a bilateral case. Surgery section
      // takes priority over a previously-saved implant_eye too, so a
      // stale value from before this derivation existed can't linger.
      setImEye(result.booking.surgical_cases.eye || io.implant_eye || io.verified_iol_eye || 'OD');
      setVarianceReason(io.variance_reason || '');
      setOpNotes(io.operative_notes || '');
      setSurgicalOutcome(io.surgical_outcome || 'Successful');
      setOutcomeRemarks(io.outcome_remarks || '');
      setRecoveryDest(io.recovery_destination || 'Recovery Bay 1');
      setRecoveryMonitor(io.recovery_monitoring || '');
      setRecoveryInstructions(io.recovery_instructions || '');
      setRecoveryConcerns(io.recovery_concerns || '');

      // Check-In's own physical-verification state -- entirely separate
      // columns from implant_*, never overwritten by what Intraop later
      // records as actually implanted.
      setCvMfr(io.verified_iol_manufacturer || '');
      setCvModel(io.verified_iol_model || '');
      setCvCatalogId(io.verified_iol_catalog_id || '');
      setCvIolMode(io.verified_iol_catalog_id ? 'catalog' : (io.verified_iol_manufacturer || io.verified_iol_model) ? 'other' : 'catalog');
      setCvPower(io.verified_iol_power || result.biometryPlans[0]?.power || '');
      setCvCategory(io.verified_iol_category || result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setCvSerial(io.verified_iol_serial || '');
      setCvExpiry(io.verified_iol_expiry || '');
      setCvEye(result.booking.surgical_cases.eye || io.verified_iol_eye || 'OD');
    } else {
      setImPower(result.biometryPlans[0]?.power || '');
      setImCategory(result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setImEye(result.booking.surgical_cases.eye || 'OD');
      setCvPower(result.biometryPlans[0]?.power || '');
      setCvCategory(result.biometryPlans[0]?.master_iol_catalog?.category || '');
      setCvEye(result.booking.surgical_cases.eye || 'OD');
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
  // Check-in's own lock, independent of the surgery-completion lock --
  // a checked-in record locks the checklist/consent/anaesthesia/implant
  // fields once check-in is complete, with its own "Unlock to Edit"
  // control (same pattern as the completed-surgery banner above).
  const checkinReadOnly = !!intraop?.checkin_completed_at && !checkinUnlocked;
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
    // Opened as a deep link from Surgical Journey (a real opener window
    // exists) -- signal completion back and close this tab instead of
    // sending staff to the Dashboard in what would otherwise become an
    // orphaned tab. Same close-on-complete pattern as IOL Approval,
    // Medical Fitness, and Advance collection.
    if (restrictTab === 'checkin' && typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'checkin-updated', otScheduleId }, window.location.origin);
      window.close();
      return;
    }
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

  // Check-In's own save -- confirms the physical IOL on hand matches
  // (or documents a variance from) the approved plan, BEFORE surgery.
  // Writes to verified_iol_* only -- never touches implant_* (what
  // Intraop later records as actually implanted).
  async function handleSaveVerification() {
    setError(''); setOk('');
    setSavingVerification(true);
    const result = await saveCheckinIolVerification(otScheduleId, sc.id, {
      manufacturer: cvMfr, model: cvModel, catalogId: cvCatalogId, power: cvPower,
      category: cvCategory, serial: cvSerial, expiry: cvExpiry, eye: cvEye,
    });
    setSavingVerification(false);
    if (result.error) { setError(result.error); return; }
    addLog('IOL verification recorded (physical check at Check-In)');
    setOk('IOL verification saved.');
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

  // Check-In's own variance check -- physically-present IOL (cv*) vs
  // the approved plan. Entirely separate from the im*/variancePresent
  // check above (which compares the approved plan to what Intraop later
  // records as ACTUALLY implanted).
  const cvSpecificIol = `${cvMfr} ${cvModel}`.trim().toLowerCase();
  const cvEyeMismatch = plannedEyeNorm && cvEye && plannedEyeNorm !== cvEye;
  const cvPowerMismatch = plannedPower && cvPower && String(plannedPower) !== String(cvPower);
  const cvCategoryMismatch = plannedCategory && cvCategory && plannedCategory !== cvCategory;
  const cvSpecificIolMismatch = (plannedPlan?.iol_catalog_id && cvCatalogId)
    ? plannedPlan.iol_catalog_id !== cvCatalogId
    : !!(plannedSpecificIol && cvSpecificIol && plannedSpecificIol !== cvSpecificIol);
  const cvVariancePresent = !!(plannedPlan && (cvEyeMismatch || cvPowerMismatch || cvCategoryMismatch || cvSpecificIolMismatch));

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
    // Opened as a deep link from Surgical Journey (a real opener window
    // exists) -- signal completion back and close this tab. Same
    // close-on-complete pattern as IOL Approval, Medical Fitness, and
    // Patient Check-In above.
    if (typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'intraop-updated', otScheduleId }, window.location.origin);
      window.close();
      return;
    }
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
        <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{sc.surgery_code || booking.id.slice(0, 8)}</div>
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
          {/* Single lock/unlock control for the entire Check-In page --
              consent forms, checklist, anaesthesia, and implant
              verification all follow this one switch, not a per-card
              toggle. */}
          {intraop?.checkin_completed_at && (
            <div
              className="msg-info"
              style={{
                display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
                background: checkinUnlocked ? 'var(--amber-lt)' : 'var(--g100)', color: checkinUnlocked ? 'var(--amber)' : 'var(--g600)',
                padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 14,
              }}
            >
              <span>
                <i className={`ti ${checkinUnlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
                {checkinUnlocked ? 'Editing a completed check-in -- changes save immediately.' : 'This check-in is complete. Viewing read-only for reference.'}
              </span>
              <button
                type="button"
                className="btn btn-sm"
                style={{ background: checkinUnlocked ? 'rgba(217,119,6,.15)' : '#fff', color: checkinUnlocked ? 'var(--amber)' : 'var(--g700)', border: '1px solid', borderColor: checkinUnlocked ? 'var(--amber)' : 'var(--g300)' }}
                onClick={() => setCheckinUnlocked((v) => !v)}
              >
                <i className={`ti ${checkinUnlocked ? 'ti-lock-open' : 'ti-lock'}`}></i> {checkinUnlocked ? 'Lock' : 'Unlock to Edit'}
              </button>
            </div>
          )}

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
                      {!checkinReadOnly && <button className="btn btn-sm" onClick={() => handleRemoveConsent(f.key)}><i className="ti ti-x"></i></button>}
                    </div>
                  ) : !checkinReadOnly ? (
                    <label className="btn btn-sm btn-primary" style={{ cursor: 'pointer', marginBottom: 0 }}>
                      {uploadingKey === f.key ? 'Uploading...' : <><i className="ti ti-upload"></i> Upload</>}
                      <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadConsent(f.key, e.target.files?.[0])} disabled={uploadingKey === f.key} />
                    </label>
                  ) : null}
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
                <div key={i} onClick={() => !checkinReadOnly && toggleCheckinItem(i)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: checkinReadOnly ? 'default' : 'pointer', background: checkinChecked[i] ? 'var(--green-lt)' : '#fff' }}>
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

          {/* Anaesthesia */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-injection" style={{ color: 'var(--teal)' }}></i> Anaesthesia</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Anaesthesia type</label><select className="fi fi-sm" value={anaesType} onChange={(e) => setAnaesType(e.target.value)} disabled={checkinReadOnly}><option>Topical</option><option>Peribulbar</option><option>Retrobulbar</option><option>Local with Sedation</option><option>General</option></select></div>
              <div><label className="flbl">Anaesthetist</label><input className="fi fi-sm" value={anaesDoctor} onChange={(e) => setAnaesDoctor(e.target.value)} disabled={checkinReadOnly} placeholder="If applicable" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Start time</label><input type="time" className="fi fi-sm" value={anaesStart} onChange={(e) => setAnaesStart(e.target.value)} disabled={checkinReadOnly} /></div>
              <div><label className="flbl">End time</label><input type="time" className="fi fi-sm" value={anaesEnd} onChange={(e) => setAnaesEnd(e.target.value)} disabled={checkinReadOnly} /></div>
            </div>
            <input className="fi fi-sm" value={anaesRemarks} onChange={(e) => setAnaesRemarks(e.target.value)} disabled={checkinReadOnly} placeholder="Sedation details / special remarks..." />
            {!intraop?.anaesthesia_recorded_at && !checkinReadOnly && (
              <button className="btn btn-sm" style={{ background: 'var(--blue)', color: '#fff', border: 'none', marginTop: 8 }} onClick={handleRecordAnaesthesia}><i className="ti ti-check"></i> Record anaesthesia</button>
            )}
            {intraop?.anaesthesia_recorded_at && <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 6 }}><i className="ti ti-check"></i> Recorded</div>}
          </div>

          {/* IOL Verification -- confirms the physical IOL on hand
              matches the approved plan, BEFORE surgery. This is
              deliberately separate from "what was actually implanted",
              which is recorded in Intraoperative Management -- a
              complication can force a different IOL to go in than the
              one verified present here. */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-disc" style={{ color: 'var(--indigo)' }}></i> IOL Verification -- Physical Check</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
              Confirms the physical IOL unit on hand matches the surgeon's approved plan. Separate from Intraoperative Management's own record of what's actually implanted.
            </div>

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

              <div style={{ border: '1.5px solid', borderColor: cvVariancePresent ? 'var(--red)' : 'var(--green)', background: cvVariancePresent ? 'var(--red-lt)' : 'var(--green-lt)', borderRadius: 12, padding: '10px 12px' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>Physically Present IOL</div>
                  {plannedPlan && <strong style={{ fontSize: 11, color: cvVariancePresent ? 'var(--red)' : 'var(--green)' }}>{cvVariancePresent ? 'VARIANCE' : 'Perfect Match'}</strong>}
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">Eye planned for</label>
                  <select className="fi fi-sm" value={cvEye} onChange={(e) => setCvEye(e.target.value)} disabled={checkinReadOnly} style={{ borderColor: cvEyeMismatch ? 'var(--red)' : undefined }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Power (D)</label>
                  <input className="fi fi-sm" value={cvPower} onChange={(e) => setCvPower(e.target.value)} disabled={checkinReadOnly} style={{ borderColor: cvPowerMismatch ? 'var(--red)' : undefined }} />
                </div>
                <div style={{ marginBottom: 6 }}>
                  <label className="flbl">IOL Category</label>
                  <select className="fi fi-sm" value={cvCategory} onChange={(e) => setCvCategory(e.target.value)} disabled={checkinReadOnly} style={{ borderColor: cvCategoryMismatch ? 'var(--red)' : undefined }}>
                    <option value="">-- Select --</option>
                    <option>Monofocal</option>
                    <option>Monofocal Toric</option>
                    <option>Multifocal</option>
                    <option>EDOF</option>
                  </select>
                </div>
                <div>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline' }}>
                    <label className="flbl">Specific IOL (Brand &amp; Model)</label>
                    {!checkinReadOnly && (
                      <button
                        type="button"
                        onClick={() => setCvIolMode(cvIolMode === 'catalog' ? 'other' : 'catalog')}
                        style={{ border: 'none', background: 'none', color: 'var(--blue)', fontSize: 10.5, cursor: 'pointer', padding: 0 }}
                      >
                        {cvIolMode === 'catalog' ? 'Not in catalog? Type it in' : 'Pick from catalog instead'}
                      </button>
                    )}
                  </div>
                  {cvIolMode === 'catalog' ? (
                    <>
                      <select
                        className="fi fi-sm"
                        value={cvCatalogId}
                        onChange={(e) => {
                          const item = iolCatalog.find((c) => c.id === e.target.value);
                          setCvCatalogId(e.target.value);
                          setCvMfr(item?.brand || '');
                          setCvModel(item ? `${item.brand}${item.model ? ' ' + item.model : ''}` : '');
                        }}
                        disabled={checkinReadOnly}
                        style={{ borderColor: cvSpecificIolMismatch ? 'var(--red)' : undefined }}
                      >
                        <option value="">-- Select IOL --</option>
                        {(cvCategory ? iolCatalog.filter((c) => c.category === cvCategory) : iolCatalog).map((c) => (
                          <option key={c.id} value={c.id}>{c.brand}{c.model ? ` ${c.model}` : ''} ({c.code})</option>
                        ))}
                      </select>
                      {cvCategory && iolCatalog.length > 0 && iolCatalog.filter((c) => c.category === cvCategory).length === 0 && (
                        <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 2 }}>No catalog IOLs under &quot;{cvCategory}&quot; -- showing full catalog instead.</div>
                      )}
                    </>
                  ) : (
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Manufacturer" value={cvMfr} onChange={(e) => { setCvMfr(e.target.value); setCvCatalogId(''); }} disabled={checkinReadOnly} style={{ borderColor: cvSpecificIolMismatch ? 'var(--red)' : undefined }} />
                      <input className="fi fi-sm" placeholder="Model" value={cvModel} onChange={(e) => { setCvModel(e.target.value); setCvCatalogId(''); }} disabled={checkinReadOnly} style={{ borderColor: cvSpecificIolMismatch ? 'var(--red)' : undefined }} />
                    </div>
                  )}
                </div>
              </div>
            </div>

            {cvVariancePresent && (
              <div style={{ marginBottom: 10 }}>
                <label className="flbl">Variance reason</label>
                <input className="fi fi-sm" value={cvVarianceReason} onChange={(e) => setCvVarianceReason(e.target.value)} disabled={checkinReadOnly} placeholder="Document reason the physical IOL on hand differs from the approved plan..." />
              </div>
            )}

            <div style={{ borderTop: '1px dashed var(--g200)', paddingTop: 10, marginBottom: 10 }}>
              <div style={{ fontSize: 10.5, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 6 }}>Serial / Batch (from the physical unit's label)</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8 }}>
                <div><label className="flbl">Serial / Batch number</label><input className="fi fi-sm" value={cvSerial} onChange={(e) => setCvSerial(e.target.value)} disabled={checkinReadOnly} /></div>
                <div><label className="flbl">Expiry date</label><input type="date" className="fi fi-sm" value={cvExpiry} onChange={(e) => setCvExpiry(e.target.value)} disabled={checkinReadOnly} /></div>
              </div>
            </div>

            {intraop?.verified_iol_at && (
              <div style={{ fontSize: 11, color: 'var(--green)', marginBottom: 10 }}>
                <i className="ti ti-check"></i> Verified {new Date(intraop.verified_iol_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
              </div>
            )}

            {!checkinReadOnly && (
              <button className="btn btn-sm btn-primary" onClick={handleSaveVerification} disabled={savingVerification}>
                <i className="ti ti-device-floppy"></i> {savingVerification ? 'Saving...' : 'Save Verification'}
              </button>
            )}
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

          {/* Implant Verification -- what was ACTUALLY implanted,
              recorded here in Intraop, checked against the approved
              plan. Deliberately independent of Check-In's own physical
              verification (cv state, verified_iol_ columns) below -- a
              complication can force a different IOL to actually go in
              than the one verified present at check-in, and this is
              where that gets documented. Defaults from Check-In's
              verification when nothing's been recorded here yet (see
              init effect), but is fully editable and never overwrites
              verified_iol_*. */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-disc" style={{ color: 'var(--indigo)' }}></i> Implant Verification</div>

            {intraop?.verified_iol_at && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                <i className="ti ti-info-circle"></i> Verified present at Check-In: {intraop.verified_iol_manufacturer || intraop.verified_iol_model ? `${intraop.verified_iol_manufacturer || ''} ${intraop.verified_iol_model || ''}`.trim() : '--'}
                {intraop.verified_iol_power ? `, ${intraop.verified_iol_power}D` : ''}{intraop.verified_iol_serial ? `, Serial ${intraop.verified_iol_serial}` : ''}.
                If a complication meant a different IOL was actually implanted, record that below.
              </div>
            )}

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
                <input className="fi fi-sm" value={varianceReason} onChange={(e) => setVarianceReason(e.target.value)} disabled={isReadOnly} placeholder="Document reason for deviation from the approved plan (e.g. complication forced a substitution)..." />
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

