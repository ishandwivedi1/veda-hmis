#!/bin/bash
set -e

echo "== Editable follow-up review schedule =="
echo "   1. Discharge screen: edit/remove/add reviews before confirming discharge"
echo "   2. Post-op page: add or remove any review after discharge too"

echo "-- Writing app/(main)/ot-recovery/actions.js --"
mkdir -p "$(dirname "app/(main)/ot-recovery/actions.js")"
cat > "app/(main)/ot-recovery/actions.js" << 'JSEOF_83755832'
'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs } from '../master-data/actions';

// Same Pharmacy drug list used in Financial Masters -- so post-op
// medication is picked from the real catalog, not free text.
export async function getDrugOptions() {
  const all = await getDrugs();
  return all
    .filter((d) => d.status === 'Active')
    .map((d) => ({ id: d.id, label: `${d.generic}${d.strength ? ` ${d.strength}` : ''}${d.brand ? ` (${d.brand})` : ''}` }));
}

// Called from OT Intraop's "Hand Over to Recovery" -- creates the
// episode the moment a patient actually arrives here, same
// lazy-create-on-handoff pattern used for biometry/medical fitness.
export async function ensureRecoveryEpisode(otScheduleId, surgicalCaseId, visitId, scheduledDate) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('recovery_episodes').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('recovery_episodes').insert({
    ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId, visit_id: visitId,
    admission_date: scheduledDate, surgery_date: scheduledDate,
  }).select('id').single();
  if (error) return null;
  return created.id;
}

// ── DASHBOARD: patients still in recovery, not yet discharged ──
export async function getRecoveryCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .is('discharge_date', null)
    .order('created_at', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: discharged episodes (Recovery's part is done -- Post Op
// takes over follow-up tracking and closure from here) ──
export async function getRecoveryHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .order('discharge_date', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL ──
export async function getRecoveryEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, ot_schedule_id, surgical_cases(*, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }, { data: complications }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model, surgical_outcome, outcome_remarks').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', episode.visit_id).eq('status', 'Approved'),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return {
    episode, sc, intraop: intraop || null, biometryPlans: biometry || [],
    meds: meds || [], followups: followups || [], complications: complications || [],
  };
}

// ── RECOVERY ASSESSMENT / GENERAL SAVE ──
export async function saveRecoveryFields(episodeId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_episodes').update(values).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── MEDICATIONS ──
export async function addRecoveryMedication(episodeId, name, sig, reason) {
  const supabase = await createClient();
  if (!name?.trim() || !sig?.trim()) return { error: 'Medicine name and dose/frequency are required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_medications').insert({ recovery_episode_id: episodeId, name: name.trim(), sig: sig.trim(), reason: reason?.trim() || null, added_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeRecoveryMedication(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_medications').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DISCHARGE ──
// The 4 suggested review dates (Day 1 / Week 1 / Month 1 / Final
// Refraction) are a starting point, not a rule -- different surgeries
// need different review schedules, so the doctor can edit labels/dates
// or remove any of them before confirming discharge. followupPlan is
// whatever's left in that editable list at the time of discharge.
export async function confirmDischarge(episodeId, checklist, dischargeNotes, dischargeInstructions, dischargeDate, followupPlan) {
  const supabase = await createClient();

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  if (!mandatoryDone) return { error: 'VAL-POST-002: All mandatory discharge items must be checked.' };
  if (!dischargeDate) return { error: 'Discharge date is required.' };

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('recovery_episodes').update({
    discharge_date: dischargeDate, discharge_checklist: checklist,
    discharge_notes: dischargeNotes || null, discharge_instructions: dischargeInstructions || null,
    discharged_by: userData?.user?.id || null, discharged_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };

  const followups = (followupPlan || [])
    .filter((f) => f.visit_label?.trim() && f.scheduled_date)
    .map((f) => ({ recovery_episode_id: episodeId, visit_label: f.visit_label.trim(), scheduled_date: f.scheduled_date }));
  if (followups.length > 0) {
    await supabase.from('recovery_followups').insert(followups);
  }

  return { success: true };
}

// ── QUALITY INDICATORS (real, computed from actual data) ──
export async function getQualityIndicators() {
  const supabase = await createClient();
  const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);

  const { data: closedThisMonth } = await supabase.from('recovery_episodes').select('id, closure_outcome, admission_date, discharge_date').gte('closed_at', monthStart.toISOString());
  const { data: complicationsThisMonth } = await supabase.from('recovery_complications').select('id, recovery_episode_id').gte('occurred_at', monthStart.toISOString());
  const { data: escalations } = await supabase.from('recovery_episodes').select('id').eq('escalation_required', true).gte('created_at', monthStart.toISOString());

  const total = closedThisMonth?.length || 0;
  const withComplications = new Set((complicationsThisMonth || []).map((c) => c.recovery_episode_id)).size;
  const sameDayDischarge = (closedThisMonth || []).filter((e) => e.admission_date && e.discharge_date && e.admission_date === e.discharge_date).length;

  return [
    { name: 'Episodes closed this month', value: String(total), sub: 'All procedures' },
    { name: 'Post-op complication rate', value: total > 0 ? `${((withComplications / total) * 100).toFixed(1)}%` : '--', sub: `${withComplications} of ${total} episodes` },
    { name: 'Same-day discharge rate', value: total > 0 ? `${((sameDayDischarge / total) * 100).toFixed(1)}%` : '--', sub: `${sameDayDischarge} of ${total} episodes` },
    { name: 'Escalations flagged', value: String(escalations?.length || 0), sub: 'This month' },
  ];
}

JSEOF_83755832

echo "-- Writing app/(main)/ot-recovery/workspace.js --"
mkdir -p "$(dirname "app/(main)/ot-recovery/workspace.js")"
cat > "app/(main)/ot-recovery/workspace.js" << 'JSEOF_44340604'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, removeRecoveryMedication, confirmDischarge, getDrugOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';

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
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Week 1', scheduled_date: addDays(7) },
    { key: `p${planRowSeq++}`, visit_label: 'Post-op Month 1', scheduled_date: addDays(30) },
    { key: `p${planRowSeq++}`, visit_label: 'Final Refraction', scheduled_date: addDays(45) },
  ];
}

export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);

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
  const [medName, setMedName] = useState('');
  const [drugOptions, setDrugOptions] = useState([]);
  const [dischargeDate, setDischargeDate] = useState(new Date().toISOString().slice(0, 10));
  const [medSig, setMedSig] = useState('');
  const [medReason, setMedReason] = useState('');
  const [showMedForm, setShowMedForm] = useState(false);

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
    setChecklist(e.discharge_checklist || {});
    setInstructions(e.discharge_instructions || '');
    setDischargeNotes(e.discharge_notes || '');
    setDischargeDate(e.discharge_date || new Date().toISOString().slice(0, 10));
    if (!e.discharge_date) {
      setFollowupPlan((prev) => (prev.length > 0 ? prev : defaultFollowupPlan(e.discharge_date || new Date().toISOString().slice(0, 10))));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); getDrugOptions().then(setDrugOptions); }, [episodeId, refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { episode, sc, intraop, biometryPlans, meds, followups } = data;
  const patient = sc.patients;
  const isDischarged = !!episode.discharge_date;
  const isClosed = !!episode.closure_status;

  function toggleChecklistItem(key) {
    if (isClosed) return;
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
    const result = await addRecoveryMedication(episodeId, medName, medSig, medReason);
    if (result.error) { setError(result.error); return; }
    setMedName(''); setMedSig(''); setMedReason(''); setShowMedForm(false);
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

  async function handleDischarge() {
    setError(''); setOk('');
    if (!dischargeDate) { setError('Discharge date is required.'); return; }
    const result = await confirmDischarge(episodeId, checklist, dischargeNotes, instructions, dischargeDate, followupPlan);
    if (result.error) { setError(result.error); return; }
    setOk('Patient discharged. Discharge summary is ready to print. Follow-up schedule generated.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0f766e,#0d9488)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Episode Closed' : isDischarged ? 'Discharged' : 'Recovery'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}
      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          {/* Surgical summary read-only */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i> Surgical Summary (read-only)</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 10 }}>
              <div><label className="flbl">Admission date</label><input type="date" className="fi fi-sm" value={admissionDate} onChange={(e) => setAdmissionDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Surgery date</label><input type="date" className="fi fi-sm" value={surgeryDate} onChange={(e) => setSurgeryDate(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Discharge date</label><input type="date" className="fi fi-sm" value={isDischarged ? episode.discharge_date : dischargeDate} onChange={(e) => setDischargeDate(e.target.value)} disabled={isDischarged || isClosed} /></div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            {biometryPlans.map((p) => (
              <div key={p.surgical_eye} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>Implanted IOL ({p.surgical_eye})</span><strong style={{ color: 'var(--indigo)', fontFamily: 'monospace', fontSize: 11 }}>{intraop?.implant_power || p.final_iol_power} D -- {p.final_iol_category}</strong>
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
              <div><label className="flbl">Recovery start</label><input type="time" className="fi fi-sm" value={recStart} onChange={(e) => setRecStart(e.target.value)} disabled={isClosed} /></div>
              <div><label className="flbl">Recovery end</label><input type="time" className="fi fi-sm" value={recEnd} onChange={(e) => setRecEnd(e.target.value)} disabled={isClosed} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Consciousness</label><select className="fi fi-sm" value={consciousness} onChange={(e) => setConsciousness(e.target.value)} disabled={isClosed}><option>Alert</option><option>Drowsy</option><option>Confused</option></select></div>
              <div><label className="flbl">Pain</label><select className="fi fi-sm" value={pain} onChange={(e) => setPain(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Moderate</option><option>Severe</option></select></div>
              <div><label className="flbl">Nausea</label><select className="fi fi-sm" value={nausea} onChange={(e) => setNausea(e.target.value)} disabled={isClosed}><option>None</option><option>Mild</option><option>Vomiting</option></select></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">Eye dressing status</label><select className="fi fi-sm" value={dressing} onChange={(e) => setDressing(e.target.value)} disabled={isClosed}><option>Intact, dry</option><option>Slight ooze</option><option>Needs change</option></select></div>
              <div><label className="flbl">Escalation required?</label><select className="fi fi-sm" value={escalation ? 'Yes' : 'No'} onChange={(e) => setEscalation(e.target.value === 'Yes')} disabled={isClosed}><option>No</option><option>Yes</option></select></div>
            </div>
            {escalation && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Escalation reason</label>
                <input className="fi fi-sm" value={escalationReason} onChange={(e) => setEscalationReason(e.target.value)} disabled={isClosed} placeholder="Document reason for escalation..." />
              </div>
            )}
            <textarea className="fi fi-sm" rows={2} value={observations} onChange={(e) => setObservations(e.target.value)} disabled={isClosed} placeholder="Clinical observations / immediate concerns..." />
          </div>

          {/* Discharge checklist */}
          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-clipboard-check" style={{ color: 'var(--green)' }}></i> Discharge Readiness Checklist</div>
              <span className={`badge ${mandatoryDone ? 'b-green' : 'b-gray'}`}>{Math.round((mandatoryChecked / mandatoryTotal) * 100)}%</span>
            </div>
            {DISCHARGE_ITEMS.map((item) => (
              <div key={item.key} onClick={() => toggleChecklistItem(item.key)} style={{ display: 'flex', alignItems: 'center', gap: 9, padding: '7px 10px', borderRadius: 8, marginBottom: 5, fontSize: 12, border: '1px solid var(--g200)', cursor: isClosed ? 'default' : 'pointer', background: checklist[item.key] ? 'var(--green-lt)' : '#fff', opacity: item.mandatory ? 1 : 0.85 }}>
                <div style={{ width: 18, height: 18, borderRadius: 4, background: checklist[item.key] ? 'var(--green)' : '#fff', border: '2px solid', borderColor: checklist[item.key] ? 'var(--green)' : 'var(--g300)', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>{checklist[item.key] && <i className="ti ti-check" style={{ fontSize: 11, color: '#fff' }}></i>}</div>
                <span>{item.label} {!item.mandatory && <span style={{ fontSize: 10, color: 'var(--g400)' }}>(optional)</span>}</span>
              </div>
            ))}
          </div>
        </div>

        <div>
          {/* Medications */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Post-operative Medication Plan</div>
            {meds.map((m) => (
              <div key={m.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 8px', background: 'var(--g50)', borderRadius: 8, marginBottom: 4, fontSize: 12 }}>
                <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i>
                <span style={{ flex: 1 }}><strong>{m.name}</strong> -- {m.sig}</span>
                {!isClosed && <button onClick={() => removeRecoveryMedication(m.id).then(refresh)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer' }}>x</button>}
              </div>
            ))}
            {meds.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No medications added yet.</div>}
            {!isClosed && (
              <>
                {!showMedForm ? (
                  <button className="btn btn-sm btn-primary" style={{ marginTop: 8 }} onClick={() => setShowMedForm(true)}><i className="ti ti-plus"></i> Add / modify medicine</button>
                ) : (
                  <div style={{ marginTop: 8 }}>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
                      <select className="fi fi-sm" value={medName} onChange={(e) => setMedName(e.target.value)}>
                        <option value="">-- Select medicine --</option>
                        {drugOptions.map((d) => <option key={d.id} value={d.label}>{d.label}</option>)}
                      </select>
                      <input className="fi fi-sm" value={medSig} onChange={(e) => setMedSig(e.target.value)} placeholder="Dose/Freq/Duration" />
                    </div>
                    <input className="fi fi-sm" value={medReason} onChange={(e) => setMedReason(e.target.value)} placeholder="Reason for change (if modifying existing plan)..." style={{ marginBottom: 6 }} />
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-sm btn-primary" onClick={handleAddMedicine}>Add</button>
                      <button className="btn btn-sm" onClick={() => setShowMedForm(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </>
            )}
          </div>

          {/* Discharge instructions */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--teal)' }}></i> Discharge Instructions</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              <span className="badge b-teal" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.cataract)}>Standard cataract template</span>
              <span className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => !isClosed && setInstructions(TEMPLATES.glaucoma)}>Glaucoma surgery template</span>
            </div>
            <textarea className="fi fi-sm" rows={4} value={instructions} onChange={(e) => setInstructions(e.target.value)} disabled={isClosed} placeholder="Eye drop schedule, eye shield usage, activity restrictions, warning symptoms..." />
          </div>

          {/* Discharge notes */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-stethoscope" style={{ color: 'var(--indigo)' }}></i> Discharge Notes (Doctor)</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Clinical condition at discharge -- distinct from the patient-facing instructions above.</div>
            <textarea className="fi fi-sm" rows={3} value={dischargeNotes} onChange={(e) => setDischargeNotes(e.target.value)} disabled={isClosed} placeholder="e.g. Eye quiet, cornea clear, IOP within normal limits..." />
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
                <span style={{ color: 'var(--g500)' }}>{new Date(f.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
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
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
          </button>
          {!isDischarged && (
            <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
              <i className="ti ti-door-exit"></i> Discharge
            </button>
          )}
          {isDischarged && (
            <a href={`/discharge-summary-print/${episodeId}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ background: 'rgba(15,118,110,.2)', color: '#5eead4', borderColor: 'rgba(15,118,110,.4)', textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Discharge Summary
            </a>
          )}
          {isDischarged && (
            <span className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none', cursor: 'default', fontWeight: 700 }}>
              <i className="ti ti-circle-check"></i> Discharged
            </span>
          )}
        </div>
      )}
    </div>
  );
}

JSEOF_44340604

echo "-- Writing app/(main)/ot-postop/actions.js --"
mkdir -p "$(dirname "app/(main)/ot-postop/actions.js")"
cat > "app/(main)/ot-postop/actions.js" << 'JSEOF_37265451'
'use server';

import { createClient } from '@/lib/supabase-server';

// Used by Doctor Dashboard: a Post-operative Review visit routes here
// instead of the normal Consultation form -- find the patient's most
// recent still-open episode (discharged, not yet closed).
export async function getOpenPostOpEpisodeForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('recovery_episodes')
    .select('id, surgical_case_id')
    .is('closure_status', null)
    .not('discharge_date', 'is', null)
    .order('created_at', { ascending: false });
  if (!data || data.length === 0) return null;

  const caseIds = data.map((e) => e.surgical_case_id);
  const { data: cases } = await supabase.from('surgical_cases').select('id, patient_id').in('id', caseIds).eq('patient_id', patientId);
  if (!cases || cases.length === 0) return null;

  const match = data.find((e) => cases.some((c) => c.id === e.surgical_case_id));
  return match?.id || null;
}

// ── DASHBOARD: discharged episodes not yet closed ──
export async function getPostOpCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .is('closure_status', null)
    .order('discharge_date', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: closed episodes ──
export async function getPostOpHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('closure_status', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL (post-op focus: milestones, followups, complications) ──
export async function getPostOpEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const [{ data: followups }, { data: complications }] = await Promise.all([
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return { episode, sc: episode.surgical_cases, followups: followups || [], complications: complications || [] };
}

// ── ADD / REMOVE a review from the schedule -- requirements can change
//    after discharge (e.g. an unplanned complication needs an extra
//    check, or a review turns out unnecessary). Removal is blocked once
//    a review has an actual clinical visit tied to it (encounter already
//    started), so a real record never gets silently orphaned. ──
export async function addFollowup(episodeId, visitLabel, scheduledDate) {
  const supabase = await createClient();
  if (!visitLabel?.trim()) return { error: 'A label for the review is required.' };
  if (!scheduledDate) return { error: 'A date is required.' };
  const { error } = await supabase.from('recovery_followups').insert({
    recovery_episode_id: episodeId, visit_label: visitLabel.trim(), scheduled_date: scheduledDate,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeFollowup(followupId) {
  const supabase = await createClient();
  const { data: followup } = await supabase.from('recovery_followups').select('visit_id, status').eq('id', followupId).single();
  if (followup?.visit_id) {
    return { error: 'This review already has a visit recorded against it and cannot be removed -- reschedule it instead if it needs to move.' };
  }
  const { error } = await supabase.from('recovery_followups').delete().eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── RESCHEDULE / NOTES on a follow-up visit ──
export async function rescheduleFollowup(followupId, newDate, notes) {
  const supabase = await createClient();
  if (!newDate) return { error: 'A new date is required.' };
  const { data: existing } = await supabase.from('recovery_followups').select('rescheduled_count').eq('id', followupId).single();
  const { error } = await supabase.from('recovery_followups').update({
    scheduled_date: newDate, notes: notes?.trim() || null,
    rescheduled_count: (existing?.rescheduled_count || 0) + 1,
  }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// For adding/editing notes without necessarily changing the date.
export async function saveFollowupNotes(followupId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_followups').update({ notes: notes?.trim() || null }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFollowupStatus(followupId, status) {
  const supabase = await createClient();

  if (status === 'Completed') {
    const { data: followup } = await supabase.from('recovery_followups').select('scheduled_date').eq('id', followupId).single();
    const today = new Date().toISOString().slice(0, 10);
    if (followup && followup.scheduled_date > today) {
      return { error: `This visit is scheduled for ${followup.scheduled_date}, which hasn't happened yet -- it can't be marked Completed in advance.` };
    }
  }

  const { error } = await supabase.from('recovery_followups').update({ status }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PATIENT REVIEW -- reuses the real Consultation screen ──
// Post-op patients now queue through Optometry like anyone else
// (refraction/clinical recording may be needed post-surgery too), with
// the exception of the surgery-day visit itself. Clicking "Start Review"
// here is the doctor's "Call Directly" override -- same mechanism as the
// "Waiting in Optometry" list on Doctor Dashboard: it completes the
// patient's Optometry entry (issuing them a Doctor token) if they
// haven't been seen yet, or just reuses the Doctor entry if Optometry
// already finished. get_or_create_postop_review_visit() reuses the
// patient's visit for today if one already exists (front desk check-in,
// or an earlier follow-up already opened today) instead of failing on
// the one-visit-per-day rule. The resulting queueEntryId is handed
// straight to <ConsultationForm queueEntryId hideHistoryTracker /> --
// the exact same screen as a normal consultation, just without History
// and Action Tracker. Reopening the same follow-up later reuses the same
// visit instead of creating a new one each time.
export async function openFollowupReview(followupId) {
  const supabase = await createClient();
  const { data: followup, error } = await supabase
    .from('recovery_followups')
    .select('*, recovery_episodes(surgical_case_id, surgical_cases(patient_id, surgeon_id))')
    .eq('id', followupId)
    .single();
  if (error) return { error: error.message };

  let visitId = followup.visit_id;

  if (!visitId) {
    const sc = followup.recovery_episodes?.surgical_cases;
    if (!sc) return { error: 'Could not find the surgical case for this follow-up.' };

    const { data: visit, error: visitError } = await supabase.rpc('get_or_create_postop_review_visit', {
      p_patient_id: sc.patient_id,
      p_doctor_id: sc.surgeon_id,
    });
    if (visitError) return { error: visitError.message };
    visitId = visit.id;

    const { error: linkError } = await supabase.from('recovery_followups').update({ visit_id: visitId }).eq('id', followupId);
    if (linkError) return { error: linkError.message };
  }

  // Already routed to Doctor (either Optometry finished normally, or
  // this follow-up's review was already opened before)?
  let { data: queueEntry } = await supabase
    .from('queue_entries')
    .select('id')
    .eq('visit_id', visitId)
    .eq('department', 'Doctor')
    .order('issued_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!queueEntry) {
    // Still waiting in Optometry -- pull them straight in, same as
    // "Call Directly" on Doctor Dashboard.
    const { data: optEntry } = await supabase
      .from('queue_entries')
      .select('id')
      .eq('visit_id', visitId)
      .eq('department', 'Optometry')
      .order('issued_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (optEntry) {
      const { error: rpcError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: optEntry.id });
      if (rpcError) return { error: rpcError.message };
      const { data: routedEntry } = await supabase
        .from('queue_entries')
        .select('id')
        .eq('visit_id', visitId)
        .eq('department', 'Doctor')
        .order('issued_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      queueEntry = routedEntry;
    }
  }

  if (!queueEntry) {
    const { data: newEntry, error: tokenError } = await supabase.rpc('issue_queue_token', { p_visit_id: visitId, p_department: 'Doctor' });
    if (tokenError) return { error: tokenError.message };
    queueEntry = newEntry;
  }

  return { queueEntryId: queueEntry.id };
}

// ── POST-OP COMPLICATIONS ──
export async function addRecoveryComplication(episodeId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Complication name is required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_complications').insert({
    recovery_episode_id: episodeId, name: values.name.trim(), severity: values.severity,
    management: values.management?.trim() || null, outcome: values.outcome?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── CLOSE EPISODE ──
export async function closeEpisode(episodeId, values) {
  const supabase = await createClient();
  if (!values.outcome) return { error: 'VAL-POST-005: Overall clinical outcome is required.' };

  const { data: complications } = await supabase.from('recovery_complications').select('management').eq('recovery_episode_id', episodeId);
  const unmanaged = (complications || []).filter((c) => !c.management);
  if (unmanaged.length > 0) return { error: 'VAL-POST-004: Unmanaged complications exist -- episode cannot close.' };

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_episodes').update({
    closure_status: values.status, closure_outcome: values.outcome, closure_remarks: values.remarks || null,
    closed_by: userData?.user?.id || null, closed_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

JSEOF_37265451

echo "-- Writing app/(main)/ot-postop/workspace.js --"
mkdir -p "$(dirname "app/(main)/ot-postop/workspace.js")"
cat > "app/(main)/ot-postop/workspace.js" << 'JSEOF_94797450'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostOpEpisodeDetail, rescheduleFollowup, saveFollowupNotes, markFollowupStatus,
  addRecoveryComplication, closeEpisode, openFollowupReview, addFollowup, removeFollowup,
} from './actions';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';
import ConsultationForm from '@/app/(main)/consultation/[id]/consultation-form';

const MILESTONES_START = [
  { key: 'recovery', label: 'Recovery', icon: 'ti-bed' },
  { key: 'discharge', label: 'Discharge', icon: 'ti-door-exit' },
];
const MILESTONES_END = [
  { key: 'closure', label: 'Episode Closure', icon: 'ti-circle-check' },
];


export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [editingFollowupId, setEditingFollowupId] = useState(null);
  const [editDate, setEditDate] = useState('');
  const [notesEditingId, setNotesEditingId] = useState(null);
  const [notesDraft, setNotesDraft] = useState('');
  const [attachmentsByFollowup, setAttachmentsByFollowup] = useState({});
  const [uploadingFollowupId, setUploadingFollowupId] = useState(null);
  const [saving, setSaving] = useState(false);

  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [showClose, setShowClose] = useState(false);
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const [reviewingFollowup, setReviewingFollowup] = useState(null);
  const [reviewQueueEntryId, setReviewQueueEntryId] = useState(null);
  const [openingReview, setOpeningReview] = useState(null);

  const [showAddFollowup, setShowAddFollowup] = useState(false);
  const [newFollowupLabel, setNewFollowupLabel] = useState('');
  const [newFollowupDate, setNewFollowupDate] = useState('');
  const [addingFollowup, setAddingFollowup] = useState(false);
  const [removingFollowupId, setRemovingFollowupId] = useState(null);

  const refresh = useCallback(async () => {
    const result = await getPostOpEpisodeDetail(episodeId);
    setData(result);
    if (!result.error && result.followups?.length > 0) {
      const entries = await Promise.all(result.followups.map(async (f) => [f.id, await getAttachments('postop_followup', f.id)]));
      setAttachmentsByFollowup(Object.fromEntries(entries));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); }, [episodeId, refresh]);

  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
  if (data.error) return <div className="msg-err">{data.error}</div>;

  if (reviewingFollowup && reviewQueueEntryId) {
    return (
      <div>
        <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBackFromReview}>
          <i className="ti ti-arrow-left"></i> Back to Post-op
        </button>
        <ConsultationForm queueEntryId={reviewQueueEntryId} hideHistoryTracker />
      </div>
    );
  }


  const { episode, sc, followups, complications } = data;
  const patient = sc?.patients;
  const isClosed = !!episode.closure_status;
  const todayStr = new Date().toISOString().slice(0, 10);

  const milestoneStatus = (key) => {
    if (key === 'recovery') return 'done';
    if (key === 'discharge') return episode.discharge_date ? 'done' : 'pending';
    if (key === 'closure') return episode.closure_status ? 'done' : 'pending';
    return 'pending';
  };

  function startEdit(f) {
    setError('');
    setEditingFollowupId(f.id);
    setEditDate(f.scheduled_date);
  }

  function startNotesEdit(f) {
    setError('');
    setNotesEditingId(f.id);
    setNotesDraft(f.notes || '');
  }

  async function handleSaveNotesOnly(f) {
    setError('');
    setSaving(true);
    const result = await saveFollowupNotes(f.id, notesDraft);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setNotesEditingId(null);
    refresh();
  }

  async function handleUploadFollowupFile(followupId, file) {
    if (!file) return;
    setUploadingFollowupId(followupId);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', 'postop_followup');
    formData.append('entityId', followupId);
    const result = await uploadAttachment(formData);
    setUploadingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleRemoveFollowupFile(file) {
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  async function handleSaveFollowup(f) {
    setError('');
    if (!editDate || editDate === f.scheduled_date) { setEditingFollowupId(null); return; }
    setSaving(true);
    const result = await rescheduleFollowup(f.id, editDate, f.notes || '');
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEditingFollowupId(null);
    refresh();
  }

  async function handleMarkStatus(f, status) {
    setError('');
    const result = await markFollowupStatus(f.id, status);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addRecoveryComplication(episodeId, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    refresh();
  }

  async function handleOpenReview(f) {
    setError('');
    setOpeningReview(f.id);
    const result = await openFollowupReview(f.id);
    setOpeningReview(null);
    if (result.error) { setError(result.error); return; }
    setReviewQueueEntryId(result.queueEntryId);
    setReviewingFollowup(f);
  }

  function handleBackFromReview() {
    setReviewingFollowup(null);
    setReviewQueueEntryId(null);
    refresh();
  }

  async function handleAddFollowup() {
    setError('');
    if (!newFollowupLabel.trim()) { setError('A label for the review is required.'); return; }
    if (!newFollowupDate) { setError('A date is required.'); return; }
    setAddingFollowup(true);
    const result = await addFollowup(episodeId, newFollowupLabel, newFollowupDate);
    setAddingFollowup(false);
    if (result.error) { setError(result.error); return; }
    setNewFollowupLabel(''); setNewFollowupDate(''); setShowAddFollowup(false);
    refresh();
  }

  async function handleRemoveFollowup(followupId) {
    setError('');
    setRemovingFollowupId(followupId);
    const result = await removeFollowup(followupId);
    setRemovingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleCloseEpisode() {
    setError('');
    if (!closureOutcome) { setError('VAL-POST-005: Overall clinical outcome is required.'); return; }
    setSaving(true);
    const result = await closeEpisode(episodeId, { status: closureStatus, outcome: closureOutcome, remarks: closureRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowClose(false);
    setOk('Episode closed.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient?.uhid} -- {sc?.procedure_name} {sc?.eye} -- {sc?.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Closed' : 'Post-op'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {ok && <div className="msg-ok">{ok}</div>}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Surgical Episode Dashboard</div>

        {MILESTONES_START.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}

        {followups.length === 0 && (
          <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No follow-ups scheduled yet.</div>
        )}
        {followups.map((f) => {
          const color = f.status === 'Completed' ? 'var(--green)' : f.status === 'Due' ? 'var(--red)' : 'var(--blue)';
          const bg = f.status === 'Completed' ? 'var(--green-lt)' : f.status === 'Due' ? 'var(--red-lt)' : 'var(--blue-lt)';
          const icon = f.status === 'Completed' ? 'ti-check' : 'ti-calendar';
          return (
            <div key={f.id} style={{ padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 12, marginBottom: 8, background: bg }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color, flexShrink: 0 }}><i className={`ti ${icon}`}></i></div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 13 }}>{f.visit_label}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {new Date(f.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                    {f.scheduled_date > todayStr && f.status !== 'Completed' && <span style={{ color: 'var(--blue)', marginLeft: 6 }}>-- upcoming</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  {f.rescheduled_count > 0 && <span style={{ fontSize: 10, color: 'var(--amber)' }}>Rescheduled {f.rescheduled_count}x</span>}
                  <span className="badge" style={{ background: `${color}20`, color }}>{f.status}</span>
                </div>
              </div>

              {f.notes && notesEditingId !== f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: '8px 10px', background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}><i className="ti ti-notes"></i> Notes</div>
                  <div style={{ fontSize: 12.5, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{f.notes}</div>
                </div>
              )}

              {notesEditingId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <textarea className="fi fi-sm" rows={3} value={notesDraft} onChange={(e) => setNotesDraft(e.target.value)} placeholder="Notes for this visit..." style={{ marginBottom: 6 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveNotesOnly(f)} disabled={saving}>Save Notes</button>
                    <button className="btn btn-sm" onClick={() => setNotesEditingId(null)}>Cancel</button>
                  </div>
                </div>
              )}

              {/* Optional attachment -- any file relevant to this visit */}
              <div style={{ marginTop: 8, marginLeft: 42 }}>
                {(attachmentsByFollowup[f.id] || []).map((file) => (
                  <div key={file.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11.5, padding: '4px 0' }}>
                    <i className="ti ti-paperclip" style={{ color: 'var(--g500)' }}></i>
                    {file.url ? <a href={file.url} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--blue)' }}>{file.file_name}</a> : <span>{file.file_name}</span>}
                    {!isClosed && <button onClick={() => handleRemoveFollowupFile(file)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 11 }}>Remove</button>}
                  </div>
                ))}
                {!isClosed && (
                  <label className="btn btn-sm" style={{ cursor: 'pointer', marginTop: 4, display: 'inline-flex' }}>
                    {uploadingFollowupId === f.id ? 'Uploading...' : <><i className="ti ti-upload"></i> Attach file (optional)</>}
                    <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadFollowupFile(f.id, e.target.files?.[0])} disabled={uploadingFollowupId === f.id} />
                  </label>
                )}
              </div>

              {!isClosed && editingFollowupId !== f.id && (
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 42 }}>
                  <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                    <i className="ti ti-clipboard-text"></i> {openingReview === f.id ? 'Opening...' : f.visit_id ? 'Open Review' : 'Start Review'}
                  </button>
                  <button className="btn btn-sm" onClick={() => startEdit(f)}><i className="ti ti-calendar-time"></i> Reschedule</button>
                  {notesEditingId !== f.id && (
                    <button className="btn btn-sm" onClick={() => startNotesEdit(f)}><i className="ti ti-edit"></i> {f.notes ? 'Edit Notes' : 'Add Notes'}</button>
                  )}
                  {f.status !== 'Completed' && (
                    <button
                      className="btn btn-sm"
                      style={{ background: 'var(--green)', color: '#fff', border: 'none', opacity: f.scheduled_date > todayStr ? 0.5 : 1, cursor: f.scheduled_date > todayStr ? 'not-allowed' : 'pointer' }}
                      onClick={() => handleMarkStatus(f, 'Completed')}
                      disabled={f.scheduled_date > todayStr}
                      title={f.scheduled_date > todayStr ? "This visit hasn't happened yet" : ''}
                    >
                      Mark Completed
                    </button>
                  )}
                  <button
                    className="btn btn-sm"
                    style={{ color: 'var(--red)' }}
                    onClick={() => handleRemoveFollowup(f.id)}
                    disabled={removingFollowupId === f.id}
                    title={f.visit_id ? 'A review that already has a visit recorded cannot be removed' : 'Remove this review'}
                  >
                    <i className="ti ti-trash"></i> {removingFollowupId === f.id ? 'Removing...' : 'Remove'}
                  </button>
                </div>
              )}

              {editingFollowupId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8 }}>
                  <div style={{ marginBottom: 6 }}>
                    <label className="flbl">New date</label>
                    <input type="date" className="fi fi-sm" value={editDate} onChange={(e) => setEditDate(e.target.value)} />
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveFollowup(f)} disabled={saving}>Save</button>
                    <button className="btn btn-sm" onClick={() => setEditingFollowupId(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          );
        })}

        {!isClosed && (
          showAddFollowup ? (
            <div style={{ padding: '10px 12px', border: '1px dashed var(--g300)', borderRadius: 12, marginBottom: 8 }}>
              <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={newFollowupLabel} onChange={(e) => setNewFollowupLabel(e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 150 }} value={newFollowupDate} onChange={(e) => setNewFollowupDate(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={handleAddFollowup} disabled={addingFollowup}>{addingFollowup ? 'Adding...' : 'Add Review'}</button>
                <button className="btn btn-sm" onClick={() => { setShowAddFollowup(false); setNewFollowupLabel(''); setNewFollowupDate(''); }}>Cancel</button>
              </div>
            </div>
          ) : (
            <button className="btn btn-sm" style={{ marginBottom: 8 }} onClick={() => setShowAddFollowup(true)}><i className="ti ti-plus"></i> Add Review</button>
          )
        )}

        {MILESTONES_END.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Post-operative Complications <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(separate from intraop)</span></div>
        {!isClosed && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication (e.g. Raised IOP, CME)..." />
              <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management..." />
              <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome..." />
            </div>
            <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
          </>
        )}
        <div style={{ marginTop: 8 }}>
          {complications.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No post-operative complications recorded.</div>}
          {complications.map((c) => (
            <div key={c.id} style={{ padding: '8px 10px', borderRadius: 8, background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)', marginBottom: 6, fontSize: 12 }}>
              <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>{c.management ? `Management: ${c.management}` : <span style={{ color: 'var(--red)' }}>Management pending -- required before episode can close</span>}</div>
              {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
            </div>
          ))}
        </div>
      </div>

      {!isClosed && !showClose && (
        <div className="card" style={{ textAlign: 'center', marginBottom: 0 }}>
          <button className="btn btn-primary" onClick={() => setShowClose(true)}><i className="ti ti-circle-check"></i> Close Surgical Episode</button>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 6 }}>Only the Ophthalmologist should close an episode. Overall outcome must be documented.</div>
        </div>
      )}

      {showClose && (
        <div className="card" style={{ marginBottom: 0 }}>
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-circle-check" style={{ color: 'var(--purple)' }}></i> Close Surgical Episode</div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Episode closure status</label>
            <select className="fi" value={closureStatus} onChange={(e) => setClosureStatus(e.target.value)}>
              <option>Successfully Completed</option><option>Completed with Residual Condition</option><option>Requires Ongoing Follow-up</option><option>Transferred to Long-term Care</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Overall clinical outcome *</label>
            <select className="fi" value={closureOutcome} onChange={(e) => setClosureOutcome(e.target.value)}>
              <option value="">-- Select --</option>
              <option>Excellent Visual Outcome</option><option>Expected Recovery</option><option>Delayed Recovery</option><option>Complication Managed</option><option>Additional Surgery Required</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Closure remarks</label>
            <textarea className="fi" rows={2} value={closureRemarks} onChange={(e) => setClosureRemarks(e.target.value)} placeholder="Final remarks..." />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleCloseEpisode} disabled={saving}>{saving ? 'Closing...' : 'Close Episode'}</button>
            <button className="btn" onClick={() => setShowClose(false)}>Cancel</button>
          </div>
        </div>
      )}

      {isClosed && (
        <div className="msg-ok">
          <i className="ti ti-circle-check"></i>
          <span><strong>Episode Closed</strong> -- {episode.closure_status}. Outcome: {episode.closure_outcome}. {episode.closure_remarks}</span>
        </div>
      )}
    </div>
  );
}

JSEOF_94797450

echo "-- Installing deps & building --"
npm install --no-audit --no-fund
npm run build

echo "== Done. Review changes, then commit. =="
