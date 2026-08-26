'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, addTaperedRecoveryMedication, removeRecoveryMedication, removeRecoveryTaperGroup,
  confirmDischarge, getDrugOptions, getMedDosageOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';
import { openPrintPopup } from '@/lib/printPopup';
import ConfirmActionModal from '@/app/components/ConfirmActionModal';

// IST "today" as YYYY-MM-DD -- used to default AND cap the discharge
// date input so it can't be mis-entered in the future (a future
// discharge_date isn't a real discharge yet and previously made the
// case vanish from every Recovery/Surgical Journey list -- see actions.js).
function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

const TEMPLATES = {
  cataract: 'Eye drops as prescribed -- Moxifloxacin QID x1wk, Prednisolone QID tapering over 4wks.\nUse eye shield while sleeping for 1 week.\nAvoid bending, lifting heavy objects, and swimming for 2 weeks.\nWarning signs: sudden pain, redness, decreased vision -- contact immediately.\nFollow-up: Day 1, Week 1, Month 1, Final refraction at 4-6 weeks.',
  glaucoma: 'Eye drops as prescribed. Avoid rubbing operated eye.\nAvoid straining, heavy lifting for 4 weeks.\nWarning signs: severe pain, sudden vision loss, excessive redness -- contact immediately.\nFollow-up as scheduled by surgeon.',
};

// Suggested starting point -- Day 1 / Week 1 / Month 1 / Final Refraction
// relative to the chosen discharge date. Purely a default: the doctor
// can rename, redate, remove, or add to this list before confirming
// discharge, since different surgeries need different review schedules.
let planRowSeq = 0;
function defaultFollowupPlan(dischargeDate) {
  const addDays = (n) => { const d = new Date(`${dischargeDate}T00:00:00`); d.setDate(d.getDate() + n); return d.toISOString().slice(0, 10); };
  return [
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Day 1', scheduled_date: addDays(1) },
  ];
}

export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);
  const [showDischargeConfirm, setShowDischargeConfirm] = useState(false);
  const [confirming, setConfirming] = useState(false);
  // Set once discharge actually succeeds -- swaps the confirm modal
  // into a success state with a Print Discharge Summary button, since
  // this workspace usually closes itself right after (opened as a
  // popup from Surgical Journey), which meant the person never got a
  // chance to print before the window vanished.
  const [dischargeComplete, setDischargeComplete] = useState(false);

  const [admissionDate, setAdmissionDate] = useState('');
  const [surgeryDate, setSurgeryDate] = useState('');
  const [recStart, setRecStart] = useState('');
  const [recEnd, setRecEnd] = useState('');
  const [consciousness, setConsciousness] = useState('Alert');
  const [pain, setPain] = useState('None');
  const [nausea, setNausea] = useState('None');
  const [dressing, setDressing] = useState('Intact, dry');
  const [escalation, setEscalation] = useState(false);
  const [escalationReason, setEscalationReason] = useState('');
  const [observations, setObservations] = useState('');

  const [checklist, setChecklist] = useState({});
  const [dischargeDate, setDischargeDate] = useState(todayIst());

  // Medication entry -- same structured Dosage/Frequency/Duration/Eye
  // fields (plus tapering schedule builder) as the Doctor module's
  // prescription form, instead of a single free-text field.
  const [medName, setMedName] = useState('');
  const [showMedSuggestions, setShowMedSuggestions] = useState(false);
  const [showMedBrowseAll, setShowMedBrowseAll] = useState(false);
  const [medDrugTypeId, setMedDrugTypeId] = useState(null);
  const [medDosage, setMedDosage] = useState('');
  const [medFrequency, setMedFrequency] = useState('BD');
  const [medDuration, setMedDuration] = useState('1 week');
  const [medEye, setMedEye] = useState('BE');
  const [medIsOcular, setMedIsOcular] = useState(true);
  const [medReason, setMedReason] = useState('');
  const [showMedForm, setShowMedForm] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  // Dosage can now vary per step too, same as the Doctor module's
  // tapering builder -- each defaults to the main Dosage field's value
  // the moment the builder opens, then is independently editable.
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week', dosage: '' },
    { frequency: 'TDS', duration: '1 week', dosage: '' },
    { frequency: 'BD', duration: '1 week', dosage: '' },
    { frequency: 'OD', duration: '1 week', dosage: '' },
  ]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);

  const [unlocked, setUnlocked] = useState(false);

  const [instructions, setInstructions] = useState('');
  const [dischargeNotes, setDischargeNotes] = useState('');
  const [followupPlan, setFollowupPlan] = useState([]);

  const refresh = useCallback(async () => {
    const result = await getRecoveryEpisodeDetail(episodeId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    const e = result.episode;
    setAdmissionDate(e.admission_date || '');
    setSurgeryDate(e.surgery_date || '');
    setRecStart(e.recovery_start || '');
    setRecEnd(e.recovery_end || '');
    setConsciousness(e.consciousness || 'Alert');
    setPain(e.pain_level || 'None');
    setNausea(e.nausea || 'None');
    setDressing(e.dressing_status || 'Intact, dry');
    setEscalation(e.escalation_required || false);
    setEscalationReason(e.escalation_reason || '');
    setObservations(e.observations || '');
    // Checklist is only ever persisted via the explicit Save button or
    // Confirm Discharge -- never auto-saved on toggle. Adding a medicine
    // (or anything else that calls refresh() mid-session) used to wipe
    // out unsaved checkbox state by blindly reloading discharge_checklist
    // from the DB every time. Once the person has touched the checklist
    // at all, keep their local state and stop re-syncing from the DB
    // until the next full page load -- same protective pattern already
    // used for followupPlan just below.
    setChecklist((prev) => (Object.keys(prev).length > 0 ? prev : (e.discharge_checklist || {})));
    setInstructions(e.discharge_instructions || '');
    setDischargeNotes(e.discharge_notes || '');
    setDischargeDate(e.discharge_date || todayIst());
    if (!e.discharge_date) {
      setFollowupPlan((prev) => (prev.length > 0 ? prev : defaultFollowupPlan(e.discharge_date || todayIst())));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); getMedDosageOptions().then(setDosageOptions); }, [episodeId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { episode, sc, intraop, biometryPlans, meds, followups, caseProcedures } = data;
  const patient = sc.patients;
  const isDischarged = !!episode.discharge_date;
  const isClosed = !!episode.closure_status;
  // Once discharged, the record is finalized and locked by default --
  // same convention as Biometry, IOL Approval, and Medical Fitness.
  // Explicit unlock is required before any field becomes editable
  // again; a fully Closed episode (Post-Op) can never be unlocked here.
  const isLocked = isDischarged && !isClosed && !unlocked;
  const fieldsDisabled = isClosed || isLocked;

  // Type-ahead for the medicine field -- same matching logic as
  // Consultation's prescription form.
  const medSuggestions = medName.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(medName.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(medName.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectMedDrug(d) {
    setMedName(d.brand);
    setMedDrugTypeId(d.drug_type_id || null);
    // Same logic as Consultation's prescription form -- tablets,
    // capsules, syrups, and injections aren't applied to an eye.
    setMedIsOcular(d.master_drug_types?.is_ocular !== false);
    setMedDosage('');
    setShowMedSuggestions(false);
  }

  // Group rows sharing a taper_group_id into one block, same as
  // Consultation's prescription list -- so a tapering schedule renders
  // and can be removed as one item, not N unrelated medication rows.
  const medItems = [];
  { const seen = new Set();
    meds.forEach((m) => {
      if (m.taper_group_id) {
        if (seen.has(m.taper_group_id)) return;
        seen.add(m.taper_group_id);
        const steps = meds.filter((x) => x.taper_group_id === m.taper_group_id).sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
        medItems.push({ type: 'taper', key: m.taper_group_id, steps });
      } else {
        medItems.push({ type: 'single', key: m.id, row: m });
      }
    });
  }

  function toggleChecklistItem(key) {
    if (fieldsDisabled) return;
    setChecklist((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  const mandatoryTotal = DISCHARGE_ITEMS.filter((i) => i.mandatory).length;
  const mandatoryChecked = DISCHARGE_ITEMS.filter((i) => i.mandatory && checklist[i.key]).length;

  async function handleSave() {
    setError(''); setOk('');
    setSaving(true);
    const result = await saveRecoveryFields(episodeId, {
      admission_date: admissionDate || null, surgery_date: surgeryDate || null,
      recovery_start: recStart || null, recovery_end: recEnd || null,
      consciousness, pain_level: pain, nausea, dressing_status: dressing,
      escalation_required: escalation, escalation_reason: escalation ? escalationReason || null : null,
      observations: observations || null, discharge_checklist: checklist,
      discharge_instructions: instructions || null, discharge_notes: dischargeNotes || null,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Recovery documentation saved.');
  }

  async function handleAddMedicine() {
    setError('');
    if (!medName.trim()) { setError('Drug name is required.'); return; }
    const result = await addRecoveryMedication(episodeId, { name: medName, dosage: medDosage, frequency: medFrequency, duration: medDuration, eye: medIsOcular ? medEye : 'Oral' }, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowMedForm(false);
    refresh();
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week', dosage: medDosage }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!medName.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    // Dosage is per-step now -- any step left blank falls back to the
    // main Dosage field's value, but the main field itself is no longer
    // required on its own.
    const steps = taperSteps.map((s) => ({ ...s, dosage: s.dosage || medDosage }));
    if (steps.some((s) => !s.dosage.trim())) { setError('Select a dosage for every step of the tapering schedule.'); return; }
    const result = await addTaperedRecoveryMedication(episodeId, { name: medName, eye: medIsOcular ? medEye : 'Oral', steps }, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedDosage(''); setMedDrugTypeId(null); setMedIsOcular(true); setMedReason(''); setShowTaperBuilder(false);
    refresh();
  }

  function updatePlanRow(key, field, value) {
    setFollowupPlan((prev) => prev.map((r) => (r.key === key ? { ...r, [field]: value } : r)));
  }

  function removePlanRow(key) {
    setFollowupPlan((prev) => prev.filter((r) => r.key !== key));
  }

  function addPlanRow() {
    setFollowupPlan((prev) => [...prev, { key: `p${planRowSeq++}`, visit_label: '', scheduled_date: dischargeDate }]);
  }

  function resetPlanToDefault() {
    setFollowupPlan(defaultFollowupPlan(dischargeDate));
  }

  function handleDischarge() {
    setError('');
    if (!dischargeDate) { setError('Discharge date is required.'); return; }
    setShowDischargeConfirm(true);
  }

  async function runDischarge() {
    setError(''); setOk('');
    setConfirming(true);
    const result = await confirmDischarge(episodeId, checklist, dischargeNotes, instructions, dischargeDate, followupPlan);
    setConfirming(false);
    if (result.error) { setShowDischargeConfirm(false); setError(result.error); return; }
    // Don't auto-close or navigate away yet -- give the person a chance
    // to print the discharge summary right here first, since this
    // workspace is usually opened as a popup and would otherwise close
    // itself before they ever saw the print option.
    setDischargeComplete(true);
    refresh();
  }

  function finishAfterDischarge() {
    setShowDischargeConfirm(false);
    setDischargeComplete(false);
    // Opened as a deep link from Surgical Journey (a real opener window
    // exists) -- signal completion back and close this tab. Same
    // close-on-complete pattern as IOL Approval, Medical Fitness,
    // Patient Check-In, and Intraoperative Management.
    if (typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'recovery-updated', episodeId }, window.location.origin);
      window.close();
      return;
    }
    setOk('Patient discharged. Follow-up schedule generated.');
    onUpdate();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>
            {patient?.uhid} -- {sc.procedure_name} {sc.eye}{caseProcedures?.length > 0 ? ` + ${caseProcedures.map((p) => `${p.procedure_name} ${p.eye}`).join(', ')}` : ''} -- {sc.profiles?.full_name}
          </div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Episode Closed' : isDischarged ? 'Discharged' : 'Recovery'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      {isLocked && (
        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-lock"></i>
          <span style={{ flex: 1 }}>This record is finalized (discharged) and locked for viewing.</span>
          <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
            <i className="ti ti-lock-open"></i> Edit
          </button>
        </div>
      )}
      {isDischarged && !isClosed && unlocked && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-edit"></i>
          <span style={{ flex: 1 }}>Editing a discharged record. Changes are saved immediately.</span>
          <button className="btn btn-sm" onClick={() => { setUnlocked(false); refresh(); }}>
            <i className="ti ti-lock"></i> Lock again
          </button>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          {/* Surgical summary read-only */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" max={todayIst()} value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            {caseProcedures?.map((p) => (
              <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>Additional Procedure</span><strong>{p.procedure_name} ({p.eye})</strong>
              </div>
            ))}
            {biometryPlans.map((p) => (
              <div key={p.eye} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>Implanted IOL ({p.eye})</span><strong style={{ color: 'var(--indigo)', fontFamily: 'monospace', fontSize: 11 }}>{intraop?.implant_power || p.power} D -- {p.master_iol_catalog?.category}</strong>
              </div>
            ))}
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
              <span style={{ color: 'var(--g500)' }}>Surgical outcome</span>
              <span className="badge b-green" style={{ fontSize: 10 }}>{intraop?.surgical_outcome || '--'}</span>
            </div>
          </div>

          {/* Recovery assessment */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--teal)' }}></i> Recovery Assessment</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={fieldsDisabled} /></div>
              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={fieldsDisabled} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={fieldsDisabled}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={fieldsDisabled}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={fieldsDisabled}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={fieldsDisabled}><option>No</option><option>Yes</option></select></div>
            </div>
            {escalation && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Escalation reason</label>
                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={fieldsDisabled} placeholder="Document reason for escalation..." />
              </div>
            )}
            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={fieldsDisabled} placeholder="Clinical observations / immediate concerns..." />
          </div>

          {/* Discharge checklist */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--green)' }}></i> Discharge Readiness Checklist</div>
              <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
            </div>
            {DISCHARGE_ITEMS.map((item) => (
              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: fieldsDisabled ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          {/* Medications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
              Same drug catalog, dosage, frequency, and tapering options as the Doctor module's prescription form.
            </div>
            {medItems.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
            {medItems.map((item) => (
              item.type === 'single' ? (
                <div key={item.key} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                  <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
                  <span style={{ flex: 1 }}><strong>{item.row.name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye || 'Oral'}</span>
                  {!fieldsDisabled && <button onClick={() => removeRecoveryMedication(item.row.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
                </div>
              ) : (
                <div key={item.key} style={{ padding: '6px 8px', background: 'var(--purple-lt)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 3 }}>
                    <strong>{item.steps[0].name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye || 'Oral'}
                    <span style={{ fontSize: 10, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering</span>
                    {!fieldsDisabled && <button onClick={() => removeRecoveryTaperGroup(item.key).then(refresh)} style={{ marginLeft: 'auto', border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
                  </div>
                  <div style={{ fontSize: 11, color: 'var(--g600)' }}>
                    {item.steps.map((s, i) => (
                      <span key={s.id}>{i > 0 && ' -> '}{s.frequency} x {s.duration}</span>
                    ))}
                    <span style={{ marginLeft: 6, color: 'var(--g500)' }}>, then stop</span>
                  </div>
                </div>
              )
            ))}

            {!fieldsDisabled && (
              <div style={{ marginTop: 8 }}>
                {!showMedForm ? (
                  <button className="btn btn-sm btn-primary" onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                ) : (
                  <div>
                    <div style={{ position: 'relative', marginBottom: 6 }}>
                      <input
                        className="fi fi-sm" style={{ width: '100%' }}
                        placeholder="Type to search medicines, or enter a new name"
                        value={medName}
                        onChange={(e) => { setMedName(e.target.value); setMedDrugTypeId(null); setMedIsOcular(true); setShowMedSuggestions(true); }}
                        onFocus={() => setShowMedSuggestions(true)}
                        onBlur={() => setTimeout(() => setShowMedSuggestions(false), 150)}
                      />
                      {showMedSuggestions && medName.trim().length > 0 && (
                        <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 200, overflowY: 'auto', marginTop: 3 }}>
                          {medSuggestions.length > 0 ? medSuggestions.map((d) => (
                            <div key={d.id} onMouseDown={() => selectMedDrug(d)} style={{ padding: '7px 10px', cursor: 'pointer', fontSize: 12, borderBottom: '1px solid var(--g100)' }}>
                              <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}
                            </div>
                          )) : (
                            <div style={{ padding: '7px 10px', fontSize: 11.5, color: 'var(--g500)' }}>
                              No match.{' '}
                              <button className="btn btn-sm" style={{ padding: '1px 6px', fontSize: 10.5 }} onMouseDown={() => { setShowMedBrowseAll(true); setShowMedSuggestions(false); }}>Browse full list</button>
                              {' '}or keep typing for free text.
                            </div>
                          )}
                        </div>
                      )}
                      {showMedBrowseAll && (
                        <select className="fi fi-sm" style={{ marginTop: 6, width: '100%' }} value="" onChange={(e) => {
                          if (!e.target.value) return;
                          const picked = drugOptions.find((d) => d.brand === e.target.value);
                          if (picked) selectMedDrug(picked);
                          setShowMedBrowseAll(false);
                        }}>
                          <option value="">-- Browse full Pharmacy master --</option>
                          {drugOptions.map((d) => <option key={d.id} value={d.brand}>{d.brand}{d.generic ? ` (${d.generic})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                        </select>
                      )}
                    </div>

                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                      <select className="fi fi-sm" value={medDosage} onChange={(e) => setMedDosage(e.target.value)}>
                        <option value="">-- Dosage --</option>
                        {(medDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === medDrugTypeId) : []).map((o) => (
                          <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                        ))}
                        {!medDrugTypeId && (
                          <>
                            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                          </>
                        )}
                      </select>
                      {medIsOcular ? (
                        <select className="fi fi-sm" value={medEye} onChange={(e) => setMedEye(e.target.value)}>
                          <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                        </select>
                      ) : (
                        <div className="fi fi-sm" style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--g500)', fontWeight: 600 }}>Oral</div>
                      )}
                    </div>

                    {!showTaperBuilder ? (
                      <>
                        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                          <select className="fi fi-sm" value={medFrequency} onChange={(e) => setMedFrequency(e.target.value)}>
                            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                          </select>
                          <select className="fi fi-sm" value={medDuration} onChange={(e) => setMedDuration(e.target.value)}>
                            <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
                            <option>1 week</option><option>2 weeks</option><option>10 days</option>
                            <option>1 month</option><option>2 months</option><option>3 months</option><option>4 months</option><option>5 months</option><option>6 months</option>
                            <option>Ongoing</option>
                          </select>
                        </div>
                        <button
                          className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginBottom: 6 }}
                          onClick={() => { setShowTaperBuilder(true); setTaperSteps((prev) => prev.map((s) => ({ ...s, dosage: s.dosage || medDosage }))); }}
                        >
                          <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                        </button>
                      </>
                    ) : (
                      <div style={{ marginBottom: 6, padding: 10, background: 'var(--purple-lt)', borderRadius: 8 }}>
                        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--purple)', marginBottom: 6 }}>
                          <i className="ti ti-chart-line"></i> Tapering -- uses the Drug{medIsOcular ? ' & Eye' : ''} above; dosage defaults to what you set above but can vary per step, alongside frequency and duration
                        </div>
                        {taperSteps.map((s, i) => (
                          <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 5 }}>
                            <span style={{ fontSize: 10.5, color: 'var(--g500)', width: 14 }}>{i + 1}.</span>
                            <select className="fi fi-sm" value={s.dosage} onChange={(e) => updateTaperStep(i, 'dosage', e.target.value)} style={{ maxWidth: 100 }}>
                              <option value="">-- Dosage --</option>
                              {(medDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === medDrugTypeId) : []).map((o) => (
                                <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                              ))}
                              {!medDrugTypeId && (
                                <>
                                  <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                                </>
                              )}
                            </select>
                            <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 90 }}>
                              <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                            </select>
                            <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 100 }}>
                              <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
                              <option>1 week</option><option>2 weeks</option><option>10 days</option>
                              <option>1 month</option><option>2 months</option><option>3 months</option><option>4 months</option><option>5 months</option><option>6 months</option>
                            </select>
                            {taperSteps.length > 2 && (
                              <button className="btn btn-sm" style={{ padding: '1px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x" style={{ color: 'var(--red)' }}></i></button>
                            )}
                          </div>
                        ))}
                        <button className="btn btn-sm" onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                      </div>
                    )}

                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6, width: '100%' }} />

                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-sm btn-primary" onClick={showTaperBuilder ? handleAddTaperSchedule : handleAddMedicine}>
                        {showTaperBuilder ? 'Save Tapering Schedule' : 'Add'}
                      </button>
                      <button className="btn btn-sm" onClick={() => { setShowMedForm(false); setShowTaperBuilder(false); }}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>
            )}
          </div>

          {/* Discharge instructions */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !fieldsDisabled && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
            </div>
            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={fieldsDisabled} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
          </div>

          {/* Discharge notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={fieldsDisabled} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
          </div>

          {/* Follow-up schedule */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Follow-up Schedule</div>
              {!isDischarged && (
                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={resetPlanToDefault}>Reset to standard schedule</button>
              )}
            </div>
            {!isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                Suggested reviews below -- edit the label/date, remove any that don't apply, or add your own before discharging.
              </div>
            )}

            {!isDischarged && followupPlan.map((f) => (
              <div key={f.key} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', borderBottom: '1px solid var(--g100)' }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={f.visit_label} onChange={(e) => updatePlanRow(f.key, 'visit_label', e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 130 }} value={f.scheduled_date} onChange={(e) => updatePlanRow(f.key, 'scheduled_date', e.target.value)} />
                <button onClick={() => removePlanRow(f.key)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 16, padding: '0 4px' }} title="Remove this review">&times;</button>
              </div>
            ))}
            {!isDischarged && followupPlan.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No reviews planned -- add one below if needed, or leave empty if none are required.</div>
            )}
            {!isDischarged && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={addPlanRow}><i className="ti ti-plus"></i> Add review</button>
            )}

            {isDischarged && followups.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No reviews were scheduled at discharge.</div>}
            {isDischarged && followups.map((f) => (
              <div key={f.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ fontWeight: 600 }}>{f.visit_label}</span>
                <span style={{ color: 'var(--g500)' }}>{new Date(f.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                <span className={`badge ${f.status === 'Completed' ? 'b-green' : f.status === 'Due' ? 'b-red' : 'b-blue'}`} style={{ fontSize: 10 }}>{f.status}</span>
              </div>
            ))}
            {isDischarged && (
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
                Reviews can be added or removed from the Post-op page as requirements change.
              </div>
            )}
          </div>
        </div>
      </div>

      {!isClosed && (
        <div style={{ background: '#0f172a', borderRadius: 12, padding: '10px 14px', display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', marginTop: 14 }}>
          <span style={{ fontSize: 11, color: '#64748b', fontWeight: 600 }}>ACTIONS:</span>
          {isDischarged && (
            <button onClick={() => openPrintPopup(`/discharge-summary-print/${episodeId}`)} className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)' }}>
              <i className="ti ti-printer"></i> Print Discharge Summary
            </button>
          )}
          {isDischarged && (
            <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
              <i className="ti ti-circle-check"></i> Discharged
            </span>
          )}
          {isLocked ? (
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => setUnlocked(true)}>
              <i className="ti ti-lock-open"></i> Unlock to Edit
            </button>
          ) : (
            <>
              <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
                <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
              </button>
              {!isDischarged && (
                <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
                  <i className="ti ti-door-exit"></i> Discharge
                </button>
              )}
              {isDischarged && unlocked && (
                <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={() => { setUnlocked(false); refresh(); }}>
                  <i className="ti ti-lock"></i> Lock again
                </button>
              )}
            </>
          )}
        </div>
      )}

      {showDischargeConfirm && !dischargeComplete && (
        <ConfirmActionModal
          icon="ti-door-exit" iconColor="var(--green)" iconBg="var(--green-lt)"
          title="Discharge Patient?"
          description={`This finalizes recovery for ${patient?.first_name} ${patient?.last_name}, generates the follow-up schedule, and locks this record. Make sure all vitals, medicines, and the discharge checklist are complete first.`}
          confirmLabel="Yes, Discharge Patient"
          loading={confirming}
          onCancel={() => setShowDischargeConfirm(false)}
          onConfirm={runDischarge}
        />
      )}

      {dischargeComplete && (
        <ConfirmActionModal
          icon="ti-circle-check" iconColor="var(--green)" iconBg="var(--green-lt)"
          title="Patient Discharged"
          description={`${patient?.first_name} ${patient?.last_name} has been discharged and the follow-up schedule has been generated.`}
          confirmLabel="Close"
          cancelLabel="Print Later"
          onCancel={finishAfterDischarge}
          onConfirm={finishAfterDischarge}
        >
          <button
            type="button" className="btn btn-primary btn-sm" style={{ width: '100%' }}
            onClick={() => openPrintPopup(`/discharge-summary-print/${episodeId}`)}
          >
            <i className="ti ti-printer"></i> Print Discharge Summary
          </button>
        </ConfirmActionModal>
      )}
    </div>
  );
}
