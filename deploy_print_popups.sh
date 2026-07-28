#!/bin/bash
set -e
echo "Applying: all printouts open as a small popup window instead of a new tab"

mkdir -p lib

cat > "lib/printPopup.js" << 'PYEOF_4472180759137120133'
// Opens a print route (invoice, receipt, investigation report, discharge
// summary, OPD case sheet, visit summary, etc.) as a small centered popup
// window rather than a full new browser tab. Every print entry point
// across the app should route through this instead of a plain
// target="_blank" link, so the experience is consistent everywhere.
export function openPrintPopup(url) {
  const width = 900;
  const height = 760;
  const left = Math.max(0, Math.round((window.screen.width - width) / 2));
  const top = Math.max(0, Math.round((window.screen.height - height) / 2));
  window.open(
    url,
    'veda-print',
    `width=${width},height=${height},top=${top},left=${left},resizable=yes,scrollbars=yes,toolbar=no,menubar=no,location=no,status=no`
  );
}
PYEOF_4472180759137120133

cat > "app/(main)/ot-recovery/workspace.js" << 'PYEOF_948119844300507097'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getRecoveryEpisodeDetail,
  saveRecoveryFields, addRecoveryMedication, removeRecoveryMedication, confirmDischarge, getDrugOptions,
} from './actions';
import { DISCHARGE_ITEMS } from './constants';
import { openPrintPopup } from '@/lib/printPopup';

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
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
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
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.08)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSave} disabled={saving}>
            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save'}
          </button>
          {!isDischarged && (
            <button className="btn btn-sm" style={{ background: 'rgba(34,197,94,.2)', color: '#86efac', borderColor: 'rgba(34,197,94,.4)', fontWeight: 700 }} onClick={handleDischarge} disabled={!mandatoryDone}>
              <i className="ti ti-door-exit"></i> Discharge
            </button>
          )}
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
        </div>
      )}
    </div>
  );
}

PYEOF_948119844300507097

cat > "app/(main)/investigation/history/page.js" << 'PYEOF_7730412375255671305'
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

const SORT_OPTIONS = [
  { value: 'date_desc', label: 'Newest first' },
  { value: 'date_asc', label: 'Oldest first' },
  { value: 'patient_asc', label: 'Patient (A-Z)' },
  { value: 'status', label: 'Status' },
];

function patientLabel(r) {
  const p = r.encounters?.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : '';
}

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [sortBy, setSortBy] = useState('date_desc');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (from, to) => {
    setLoading(true);
    const result = await getInvestigationHistory(from || undefined, to || undefined);
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(fromDate, toDate); }, [fromDate, toDate, refresh]);

  function clearDates() {
    setFromDate('');
    setToDate('');
  }

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = useMemo(() => {
    const result = rows.filter((r) => {
      if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
      if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
      return true;
    });

    const sorted = [...result];
    if (sortBy === 'date_desc') sorted.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    else if (sortBy === 'date_asc') sorted.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    else if (sortBy === 'patient_asc') sorted.sort((a, b) => patientLabel(a).localeCompare(patientLabel(b)));
    else if (sortBy === 'status') sorted.sort((a, b) => a.status.localeCompare(b.status));
    return sorted;
  }, [rows, patientFilter, typeFilter, sortBy]);

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <label className="flbl">From</label>
            <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">To</label>
            <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          </div>
          {(fromDate || toDate) && (
            <button className="btn btn-sm" style={{ alignSelf: 'flex-end' }} onClick={clearDates}>
              <i className="ti ti-x"></i> Clear dates
            </button>
          )}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignSelf: 'flex-end' }}>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
              {SORT_OPTIONS.map((s) => <option key={s.value} value={s.value}>Sort: {s.label}</option>)}
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Date/Time</th><th>Patient</th><th>Investigation</th><th>Eye</th><th>Key values</th><th>Status</th><th>Doctor</th><th>Performed by</th><th></th></tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const p = r.encounters?.visits?.patients;
              const type = matchInvestigationType(r.name);
              return (
                <tr key={r.id} onClick={() => router.push(`/investigation/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <strong>{p?.first_name} {p?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{p?.uhid}</span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td><span className="badge b-blue" style={{ fontSize: 10 }}>{r.eye}</span></td>
                  <td style={{ fontSize: 11, color: 'var(--g600)' }}>{summarizeResultData(type, r.result_data)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 11 }}>{r.doctorName}</td>
                  <td style={{ fontSize: 11, color: 'var(--g400)' }}>{r.performedByName}</td>
                  <td style={{ display: 'flex', gap: 4 }}>
                    <a
                      href={`/investigation/${r.id}`}
                      onClick={(e) => { e.stopPropagation(); router.push(`/investigation/${r.id}`); }}
                      className="btn"
                      style={{ padding: '3px 8px', fontSize: 11, textDecoration: 'none' }}
                      title="View"
                    >
                      <i className="ti ti-eye"></i>
                    </a>
                    {['Completed', 'Verified', 'Available'].includes(r.status) && (
                      <button
                        onClick={(e) => { e.stopPropagation(); openPrintPopup(`/investigation-print/${r.id}`); }}
                        className="btn"
                        style={{ padding: '3px 8px', fontSize: 11 }}
                        title="Print / PDF"
                      >
                        <i className="ti ti-printer"></i>
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
            {!loading && filtered.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No records found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

PYEOF_7730412375255671305

cat > "app/(main)/investigation/page.js" << 'PYEOF_4443743459354412566'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationQueue, getTodaysInvestigations } from './actions';
import InvestigationTabs from './investigation-tabs';
import { openPrintPopup } from '@/lib/printPopup';

const PRIORITY_BADGE = { Urgent: 'b-red', Routine: 'b-gray' };

// Same type-matching heuristic as the workspace uses -- kept in sync
// so the Queue's type filter and badges agree with what the workspace
// will actually render when opened.
function matchType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) return 'OCT';
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) return 'Visual Field';
  if (n.includes('fundus')) return 'Fundus Photography';
  if (n.includes('pachymetry')) return 'Pachymetry';
  return 'External Report';
}

const TYPE_ICON = { OCT: 'ti-eye', 'Visual Field': 'ti-activity', 'Fundus Photography': 'ti-camera', Pachymetry: 'ti-ruler', 'External Report': 'ti-file-import', Biometry: 'ti-ruler-measure' };

// Investigation and Biometry use different status vocabularies
// (Ordered/In Progress/... vs Awaiting Biometry/Measured/Calculated),
// so the Queue badge needs to know which one it's looking at.
const STATUS_BADGE = {
  investigation: { 'In Progress': 'b-blue' },
  biometry: { 'Awaiting Biometry': 'b-amber', Measured: 'b-blue', Calculated: 'b-purple' },
};
function statusBadgeClass(item) {
  return STATUS_BADGE[item.kind]?.[item.status] || 'b-amber';
}

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function InvestigationPage() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 });
  const [typeFilter, setTypeFilter] = useState('');
  const [todaysInvestigations, setTodaysInvestigations] = useState([]);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvestigationQueue();
    setGroups(result.groups);
    setStats(result.stats);
    setTodaysInvestigations(await getTodaysInvestigations());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const filteredGroups = typeFilter
    ? groups.map((g) => ({ ...g, items: g.items.filter((i) => (i.kind === 'biometry' ? 'Biometry' : matchType(i.name)) === typeFilter) })).filter((g) => g.items.length > 0)
    : groups;

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Ordered" value={stats.ordered} sub="Awaiting performance" color="var(--teal)" />
        <KpiCard label="In progress" value={stats.inProgress} sub="Currently being done" color="var(--amber)" />
        <KpiCard label="Verified today" value={stats.availableToday} sub="Available for review" color="var(--green)" />
        <KpiCard label="Total today" value={stats.totalToday} sub="All investigations" color="var(--blue)" />
      </div>

      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Today&apos;s Investigations
          <span className="badge b-gray" style={{ marginLeft: 8 }}>{todaysInvestigations.length}</span>
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Patient Name</th><th>Investigation</th><th>Billing Status</th><th></th></tr>
          </thead>
          <tbody>
            {todaysInvestigations.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{r.patient?.first_name} {r.patient?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.patient?.uhid}</span>
                </td>
                <td style={{ fontWeight: 600 }}>{r.name} <span style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 400 }}>({r.eye})</span></td>
                <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                <td style={{ display: 'flex', gap: 4 }}>
                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(`/investigation/${r.id}`)} title="View">
                    <i className="ti ti-eye"></i>
                  </button>
                  {['Completed', 'Verified', 'Available'].includes(r.status) && (
                    <button
                      onClick={() => openPrintPopup(`/investigation-print/${r.id}`)}
                      className="btn"
                      style={{ padding: '3px 8px', fontSize: 11 }}
                      title="Print / PDF"
                    >
                      <i className="ti ti-printer"></i>
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {todaysInvestigations.length === 0 && (
              <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No investigations today yet.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--teal)' }}></i> Investigation Queue</div>
          <select className="fi" style={{ width: 'auto', padding: '5px 8px', fontSize: 11 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
            <option value="">All types</option>
            <option value="OCT">OCT</option>
            <option value="Visual Field">Visual Field</option>
            <option value="Fundus Photography">Fundus Photography</option>
            <option value="Pachymetry">Pachymetry</option>
            <option value="External Report">External Report</option>
            <option value="Biometry">Biometry</option>
          </select>
        </div>
      </div>

      {filteredGroups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-user" style={{ color: 'var(--purple)' }}></i>
            {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
          </div>
          {g.items.map((item) => {
            const type = item.kind === 'biometry' ? 'Biometry' : matchType(item.name);
            const href = item.kind === 'biometry' ? `/biometry/${item.id}` : `/investigation/${item.id}`;
            return (
              <div
                key={item.id}
                onClick={() => router.push(href)}
                style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
              >
                <i className={`ti ${TYPE_ICON[type] || 'ti-flask'}`} style={{ color: item.kind === 'biometry' ? 'var(--indigo)' : 'var(--teal)', fontSize: 16 }}></i>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{item.name}</span>
                  <span style={{ fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>{item.eye}</span>
                </div>
                <span className={`badge ${PRIORITY_BADGE[item.priority] || 'b-gray'}`}>{item.priority}</span>
                <span className={`badge ${statusBadgeClass(item)}`}>{item.status}</span>
                <span className={`badge ${item.payment?.badge || 'b-gray'}`}>{item.payment?.label || 'Unbilled'}</span>
                <button className="btn btn-sm btn-primary"><i className={`ti ${item.kind === 'biometry' ? 'ti-ruler-measure' : 'ti-flask'}`}></i> Open</button>
              </div>
            );
          })}
        </div>
      ))}

      {filteredGroups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

PYEOF_4443743459354412566

cat > "app/(main)/investigation/[id]/workspace.js" << 'PYEOF_2241277149623554035'
'use client';

import { useState, useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  getInvestigationDetail, saveInvestigationDraft,
  completeInvestigation, verifyInvestigation, markUnableToPerform,
} from '../actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import { openPrintPopup } from '@/lib/printPopup';

// Maps a doctor's free-text investigation name to the closest workspace
// template -- same heuristic as the prototype's matchInvestigationType,
// with External Report as the generic fallback for anything unrecognised
// (e.g. external lab reports, blood work).
function matchInvestigationType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) {
    return {
      type: 'OCT', icon: 'ti-eye',
      fields: [
        { lbl: 'Central Macular Thickness (OD)', id: 'cmt-re', placeholder: 'e.g. 245 um' },
        { lbl: 'RNFL Thickness', id: 'rnfl', placeholder: 'e.g. Average 85 um' },
        { lbl: 'Signal Strength', id: 'signal', placeholder: 'e.g. 8/10' },
        { lbl: 'GCC', id: 'gcc', placeholder: 'Optional' },
      ],
      note: 'Clinical interpretation reserved for Ophthalmologist. Enter measurements only.',
      verifyItems: ['Scan quality acceptable', 'Central macula imaged', 'Both eyes captured if bilateral', 'Signal strength >= 6'],
    };
  }
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) {
    return {
      type: 'Visual Field', icon: 'ti-activity',
      fields: [
        { lbl: 'Test strategy', id: 'vf-strategy', placeholder: 'e.g. SITA Standard 24-2' },
        { lbl: 'MD (RE)', id: 'md-re', placeholder: 'e.g. -6.2 dB' },
        { lbl: 'PSD (RE)', id: 'psd-re', placeholder: 'e.g. 5.1 dB' },
        { lbl: 'MD (LE)', id: 'md-le', placeholder: 'e.g. -4.1 dB' },
        { lbl: 'PSD (LE)', id: 'psd-le', placeholder: 'e.g. 3.8 dB' },
        { lbl: 'VFI (%)', id: 'vfi', placeholder: 'e.g. 72%' },
        { lbl: 'Reliability indices', id: 'vf-rel', placeholder: 'FP<5%, FN<5%, FL<20%' },
      ],
      note: 'PDF report or device output should be uploaded once document upload is available.',
      verifyItems: ['Test completed bilaterally', 'Reliability indices acceptable', 'Patient cooperation noted'],
    };
  }
  if (n.includes('fundus')) {
    return {
      type: 'Fundus Photography', icon: 'ti-camera',
      fields: [
        { lbl: 'Image quality', id: 'img-qual', placeholder: 'Good / Fair / Poor' },
        { lbl: 'Field coverage', id: 'img-field', placeholder: 'e.g. Macula-centred, Disc-centred' },
        { lbl: 'Photography notes', id: 'photo-notes', placeholder: 'e.g. Media clear, good view...' },
      ],
      note: null,
      verifyItems: ['Images captured for required fields', 'Image quality acceptable', 'Linked to correct eye and encounter'],
    };
  }
  return {
    type: 'External Report', icon: 'ti-file-import',
    fields: [
      { lbl: 'Document type', id: 'doc-type', placeholder: 'e.g. Blood sugar report, ECG' },
      { lbl: 'Issuing lab/hospital', id: 'doc-source', placeholder: 'e.g. Pathology Lab, Haridwar' },
      { lbl: 'Report date', id: 'doc-date', placeholder: 'DD/MM/YYYY' },
      { lbl: 'Summary findings', id: 'doc-summary', placeholder: 'e.g. FBS 112 mg/dL, ECG normal sinus rhythm' },
    ],
    note: null,
    verifyItems: ['Document details recorded', 'Source and date documented', 'Linked to Clinical Encounter'],
  };
}

const STATUS_STEPS = ['Ordered', 'In Progress', 'Completed', 'Verified', 'Available'];
function statusIdx(status) {
  if (status === 'Available') return 4;
  const i = STATUS_STEPS.indexOf(status);
  return i === -1 ? 0 : i;
}

function StatusTimeline({ status }) {
  const currentIdx = statusIdx(status);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 0, flexWrap: 'wrap' }}>
      {STATUS_STEPS.map((s, i) => {
        const cls = i < currentIdx ? 'done' : i === currentIdx ? 'active' : 'pending';
        const bg = cls === 'done' ? 'var(--green)' : cls === 'active' ? 'var(--teal)' : '#fff';
        const border = cls === 'pending' ? 'var(--g200)' : (cls === 'done' ? 'var(--green)' : 'var(--teal)');
        const color = cls === 'pending' ? 'var(--g300)' : '#fff';
        return (
          <div key={s} style={{ display: 'flex', alignItems: 'center', flex: i < STATUS_STEPS.length - 1 ? 1 : 'none' }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, minWidth: 80 }}>
              <div style={{ width: 28, height: 28, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, border: `2px solid ${border}`, background: bg, color, boxShadow: cls === 'active' ? '0 0 0 4px var(--teal-lt)' : 'none' }}>
                <i className={`ti ${cls === 'done' ? 'ti-check' : cls === 'active' ? 'ti-loader' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
              </div>
              <div style={{ fontSize: 10, color: 'var(--g400)', textAlign: 'center' }}>{s}</div>
            </div>
            {i < STATUS_STEPS.length - 1 && <div style={{ flex: 1, height: 2, background: i < currentIdx ? 'var(--green)' : 'var(--g200)', minWidth: 20 }}></div>}
          </div>
        );
      })}
    </div>
  );
}

export default function InvestigationWorkspace({ orderId }) {
  const [order, setOrder] = useState(null);
  const [doctorName, setDoctorName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [fields, setFields] = useState({});
  const [remarks, setRemarks] = useState('');
  const [checklist, setChecklist] = useState({});
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [startedByName, setStartedByName] = useState(null);
  const router = useRouter();
  const searchParams = useSearchParams();
  const viewOnly = searchParams.get('mode') === 'view';

  useEffect(() => {
    getInvestigationDetail(orderId, viewOnly).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setOrder(result.order);
      setDoctorName(result.doctorName);
      setStartedByName(result.startedByName);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    });
  }, [orderId, viewOnly]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!order) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = order.encounters?.visits?.patients;
  const visitNumber = order.encounters?.visits?.visit_number;
  const template = matchInvestigationType(order.name);

  function setField(id, value) {
    setFields((prev) => ({ ...prev, [id]: value }));
  }
  function toggleCheck(item) {
    setChecklist((prev) => ({ ...prev, [item]: !prev[item] }));
  }

  async function refresh() {
    const result = await getInvestigationDetail(orderId, viewOnly);
    if (!result.error) {
      setOrder(result.order);
      setStartedByName(result.startedByName);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    }
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveInvestigationDraft(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleComplete() {
    setError(''); setSaving(true);
    const result = await completeInvestigation(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVerify() {
    setError('');
    const allChecked = template.verifyItems.every((item) => checklist[item]);
    if (!allChecked) {
      setError(`All verification items must be checked before verifying (${template.verifyItems.filter((i) => checklist[i]).length}/${template.verifyItems.length} checked).`);
      return;
    }
    setSaving(true);
    const result = await verifyInvestigation(orderId, checklist);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Investigation verified and released. Now available in Clinical Encounter.');
    refresh();
  }

  async function handleUnable() {
    const reason = window.prompt('Enter reason for unable to perform:');
    if (!reason) return;
    setError(''); setSaving(true);
    const result = await markUnableToPerform(orderId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  const isCancelled = order.status === 'Cancelled';
  const isAvailable = order.status === 'Available';
  const canEdit = !viewOnly && !isCancelled && !isAvailable;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Visit {visitNumber || '--'} -- Dr. {doctorName}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .7 }}>Investigation</div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{order.name}</div>
          <span className={`badge ${order.status === 'Available' ? 'b-green' : order.status === 'Cancelled' ? 'b-red' : order.status === 'Completed' ? 'b-teal' : order.status === 'In Progress' ? 'b-blue' : 'b-amber'}`} style={{ fontSize: 10, marginTop: 3 }}>
            {order.status}
          </span>
          {['Completed', 'Verified', 'Available'].includes(order.status) && (
            <button
              onClick={() => openPrintPopup(`/investigation-print/${order.id}`)}
              className="btn btn-sm"
              style={{ marginLeft: 6, background: 'rgba(255,255,255,.15)', color: '#fff', borderColor: 'rgba(255,255,255,.3)' }}
            >
              <i className="ti ti-printer"></i> Print
            </button>
          )}
          {viewOnly && <span className="badge b-purple" style={{ fontSize: 10, marginTop: 3, marginLeft: 4 }}><i className="ti ti-eye"></i> Read-only</span>}
          {order.started_at && (
            <div style={{ fontSize: 10, opacity: .8, marginTop: 3 }}>
              Started by {startedByName || '--'} -- {new Date(order.started_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </div>
          )}
        </div>
      </div>

      {!isCancelled && (
        <div className="card" style={{ padding: 12 }}>
          <StatusTimeline status={order.status} />
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      {isCancelled ? (
        <div className="card" style={{ background: 'var(--red-lt)', borderColor: '#fca5a5' }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--red)', marginBottom: 6 }}>
            <i className="ti ti-x-circle"></i> Unable to Perform
          </div>
          <div style={{ fontSize: 13, color: 'var(--red)' }}>{order.unable_reason}</div>
        </div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
          <div>
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className={`ti ${template.icon}`} style={{ color: 'var(--teal)' }}></i> {order.name} workspace</div>
              {template.fields.map((f) => (
                <div key={f.id} style={{ marginBottom: 10 }}>
                  <label className="flbl">{f.lbl}</label>
                  <input className="fi fi-sm" placeholder={f.placeholder} value={fields[f.id] || ''} onChange={(e) => setField(f.id, e.target.value)} disabled={!canEdit} />
                </div>
              ))}
              {template.note && (
                <div style={{ marginTop: 8, padding: '8px 10px', background: 'var(--blue-lt)', borderRadius: 8, fontSize: 11, color: 'var(--blue)' }}>
                  <i className="ti ti-info-circle"></i> {template.note}
                </div>
              )}
            </div>
          </div>

          <div>
            <div className="card" style={{ marginBottom: 12 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Technician Remarks</div>
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 8 }}>
                <i className="ti ti-alert-triangle"></i> Factual observations only. Clinical interpretation is reserved for the Ophthalmologist.
              </div>
              <textarea className="fi fi-sm" rows={3} value={remarks} onChange={(e) => setRemarks(e.target.value)} disabled={!canEdit} placeholder="e.g. Poor fixation due to dense cataract. Scan quality: Good. Signal strength 7/10..." />
            </div>

            <div style={{ marginBottom: 12 }}>
              <AttachmentUploader entityType="investigation_order" entityId={order.id} title="Report / Document" />
            </div>

            {!viewOnly && (order.status === 'Completed') && (
              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Verification confirms technical completeness -- not clinical interpretation.</div>
                {template.verifyItems.map((item) => (
                  <label key={item} style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, cursor: 'pointer', marginBottom: 5 }}>
                    <input type="checkbox" checked={!!checklist[item]} onChange={() => toggleCheck(item)} style={{ accentColor: 'var(--green)', width: 14, height: 14 }} />
                    {item}
                  </label>
                ))}
              </div>
            )}

            {viewOnly ? (
              <div className="card" style={{ marginBottom: 0, textAlign: 'center', color: 'var(--g400)', fontSize: 12 }}>
                <i className="ti ti-lock" style={{ display: 'block', fontSize: 18, marginBottom: 4 }}></i>
                Read-only view -- close this window to return.
              </div>
            ) : (
              <div className="card" style={{ marginBottom: 0 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrows-right" style={{ color: 'var(--teal)' }}></i> Workflow Controls</div>
                <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                  {order.status === 'In Progress' && (
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleComplete} disabled={saving}>
                      <i className="ti ti-check"></i> Mark Complete
                    </button>
                  )}
                  {order.status === 'Completed' && (
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
                      <i className="ti ti-shield-check"></i> Verify &amp; Release
                    </button>
                  )}
                  {canEdit && (
                    <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
                      <i className="ti ti-device-floppy"></i> Save Draft
                    </button>
                  )}
                  {canEdit && (
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleUnable} disabled={saving}>
                      <i className="ti ti-x-circle"></i> Unable to Perform
                    </button>
                  )}
                  <button className="btn btn-sm" onClick={() => router.push('/investigation')}>
                    <i className="ti ti-arrow-left"></i> Back to Queue
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  );
}

PYEOF_2241277149623554035

cat > "app/(main)/billing/cancel/invoice-modification-tab.js" << 'PYEOF_260353459948725020'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, getServiceCatalog, addLineItem, removeLineItem, cancelInvoice, getTodaysInvoicesForModification, getInvoicesForVisit } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);
  const [visitInvoices, setVisitInvoices] = useState(null);
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const visitLoadedFor = useRef(null);

  const [dept, setDept] = useState('');
  const [serviceCode, setServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [removeReasonFor, setRemoveReasonFor] = useState(null);
  const [removeReason, setRemoveReason] = useState('');

  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [todaysInvoices, setTodaysInvoices] = useState([]);
  const [searched, setSearched] = useState(false);
  const [confirmedMessage, setConfirmedMessage] = useState('');

  const loadToday = useCallback(async () => {
    setTodaysInvoices(await getTodaysInvoicesForModification());
  }, []);

  useEffect(() => { getServiceCatalog().then(setCatalog); loadToday(); }, [loadToday]);

  // Arrived via "Modify" from Front Office Dashboard or New Invoice --
  // jump straight to this visit's invoice(s) instead of a generic
  // search. If there's exactly one, open it directly; if more than
  // one, show them as a pre-filtered pick list.
  useEffect(() => {
    if (!urlVisitId) return;
    if (visitLoadedFor.current === urlVisitId) return;
    visitLoadedFor.current = urlVisitId;
    (async () => {
      const result = await getInvoicesForVisit(urlVisitId);
      const invoices = result.invoices || [];
      if (invoices.length === 1) {
        openInvoice(invoices[0]);
      } else {
        setVisitInvoices(invoices);
      }
    })();
  }, [urlVisitId]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setVisitInvoices(null);
    setResults(await searchInvoices(searchQuery.trim()));
    setSearched(true);
  }

  async function openInvoice(inv) {
    setError(''); setInfo(''); setConfirmedMessage('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
    setShowCancelForm(false);
    setCancelReason('');
  }

  async function refresh() {
    const details = await getInvoiceById(selected.id);
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  async function handleAddLine() {
    setError('');
    if (!serviceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(selected.id, serviceCode, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }
    setDept(''); setServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
    refresh();
  }

  async function confirmRemoveLine() {
    setError('');
    if (!removeReason.trim()) { setError('A reason is required to remove a line item from an existing invoice.'); return; }
    const result = await removeLineItem(removeReasonFor, removeReason);
    if (result.error) { setError(result.error); return; }
    setRemoveReasonFor(null);
    setRemoveReason('');
    setInfo('Line item removed and logged.');
    refresh();
  }

  function handleConfirmModification() {
    setConfirmedMessage(`Modification confirmed for ${selected.invoice_number} -- Net Total: Rs.${selected.net}.`);
    setSelected(null);
    setLineItems([]);
    loadToday();
  }

  async function handleCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A cancellation reason is required.'); return; }
    const result = await cancelInvoice(selected.id, cancelReason);
    if (result.error) { setError(result.error); return; }
    setInfo('Invoice cancelled and logged for audit.');
    setShowCancelForm(false);
    setCancelReason('');
    refresh();
    loadToday();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.3fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Find Invoice
        </div>
        {confirmedMessage && (
          <div className="msg-success"><i className="ti ti-circle-check"></i> {confirmedMessage}</div>
        )}
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={searchQuery} onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }} placeholder="Patient name or UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
        </div>

        {visitInvoices ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6 }}>
              Invoices for this visit
            </div>
            {visitInvoices.map((inv) => (
              <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.purpose}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {visitInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices found for this visit.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setVisitInvoices(null)}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : searched ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>
              Search Results
            </div>
            {results.map((inv) => (
              <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No matches found.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => { setSearched(false); setSearchQuery(''); }}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
              <i className="ti ti-calendar-event"></i> Today&apos;s Invoices
              <span className="badge b-blue">{todaysInvoices.length}</span>
            </div>
            {todaysInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => openInvoice(inv)}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12, background: 'var(--blue-lt)', borderRadius: 4, marginBottom: 4 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g600)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {todaysInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices generated today yet.</div>}
          </>
        )}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.invoice_number}</div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <button onClick={() => openPrintPopup(`/invoice-print/${selected.id}`)} className="btn btn-sm">
                <i className="ti ti-printer"></i> Print / PDF
              </button>
              <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
            </div>
          </div>
          <div style={{ fontSize: 13, marginBottom: 12 }}>
            <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          <table className="tbl">
            <thead><tr><th>Service</th><th>Qty</th><th>Net</th><th></th></tr></thead>
            <tbody>
              {lineItems.map((li) => (
                <tr key={li.id}>
                  <td>{li.service_name}</td>
                  <td>{li.qty}</td>
                  <td>Rs.{li.net}</td>
                  <td>
                    {selected.status !== 'Cancelled' && (
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => { setRemoveReasonFor(li.id); setRemoveReason(''); setError(''); }}>
                        Remove
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {removeReasonFor && (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12, marginTop: 10 }}>
              <label className="flbl">Reason for removing this line item *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={removeReason} onChange={(e) => setRemoveReason(e.target.value)} placeholder="e.g. Billed in error" />
                <button className="btn btn-primary btn-sm" onClick={confirmRemoveLine}>Confirm</button>
                <button className="btn btn-sm" onClick={() => setRemoveReasonFor(null)}>Cancel</button>
              </div>
            </div>
          )}

          {selected.status !== 'Cancelled' && (
            <>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '16px 0 8px' }}>Add Line Item</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <select className="fi" value={dept} onChange={(e) => { setDept(e.target.value); setServiceCode(''); setRate(''); setGstPct(''); }}>
                  <option value="">-- Dept --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
                <select className="fi" value={serviceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">-- Service --</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div>
                  <label className="flbl">Qty</label>
                  <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
                </div>
                <div>
                  <label className="flbl">Unit rate (Rs.)</label>
                  <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
                </div>
                <div>
                  <label className="flbl">GST %</label>
                  <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
                <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                  <option value="none">No discount</option>
                  <option value="pct">Percentage (%)</option>
                  <option value="fixed">Fixed (Rs.)</option>
                </select>
                <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
                <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
              </div>
              <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
                <i className="ti ti-plus"></i> Add
              </button>
            </>
          )}

          <div style={{ borderTop: '1px solid var(--g200)', paddingTop: 12, marginTop: 4 }}>
            <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Net Total: Rs.{selected.net} -- Paid: Rs.{selected.paid}</div>

            {selected.status === 'Cancelled' ? (
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>
                <i className="ti ti-x-circle" style={{ color: 'var(--red)' }}></i> Cancelled -- reason: {selected.cancellation_reason}
              </div>
            ) : selected.paid > 0 ? (
              <div className="msg-info" style={{ margin: 0 }}>
                <i className="ti ti-info-circle"></i> This invoice has payments recorded and cannot be cancelled. Contact an administrator if needed.
              </div>
            ) : !showCancelForm ? (
              <button className="btn" style={{ color: 'var(--red)' }} onClick={() => setShowCancelForm(true)}>
                <i className="ti ti-x-circle"></i> Cancel Invoice
              </button>
            ) : (
              <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12 }}>
                <label className="flbl">Cancellation reason *</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
                  <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleCancel}>Confirm Cancel</button>
                  <button className="btn btn-sm" onClick={() => setShowCancelForm(false)}>Back</button>
                </div>
              </div>
            )}

            {selected.status !== 'Cancelled' && !showCancelForm && (
              <button className="btn btn-green" style={{ marginTop: 12 }} onClick={handleConfirmModification}>
                <i className="ti ti-circle-check"></i> Confirm Modification &amp; Close
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}


PYEOF_260353459948725020

cat > "app/(main)/billing/recent-invoices-table.js" << 'PYEOF_9184337683489336113'
'use client';

import { useState } from 'react';
import Link from 'next/link';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Paid: 'b-green', Pending: 'b-amber', Partial: 'b-blue', Cancelled: 'b-gray' };

export default function RecentInvoicesTable({ invoices }) {
  const [filter, setFilter] = useState('');
  const filtered = filter ? invoices.filter((i) => i.status === filter) : invoices;

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title"><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> Recent Invoices</div>
        <select className="fi" style={{ width: 'auto', padding: '4px 8px', fontSize: 12 }} value={filter} onChange={(e) => setFilter(e.target.value)}>
          <option value="">All</option>
          <option value="Paid">Paid</option>
          <option value="Pending">Pending</option>
          <option value="Partial">Partial</option>
        </select>
      </div>
      <div style={{ maxHeight: 420, overflowY: 'auto' }}>
        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Patient</th><th>Visit</th><th>Dept</th><th>Amount</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {filtered.map((inv) => (
              <tr key={inv.id}>
                <td style={{ fontFamily: 'monospace', fontSize: 11, color: 'var(--blue)' }}>{inv.invoice_number || '--'}</td>
                <td>
                  <div style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.patients?.uhid}</div>
                </td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td style={{ fontSize: 12 }}>{inv.purpose || '--'}</td>
                <td style={{ fontWeight: 600 }}>Rs.{Number(inv.net).toLocaleString('en-IN')}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <Link href={`/billing/details?q=${inv.patients?.uhid || ''}`} className="btn btn-sm" style={{ textDecoration: 'none' }} title="View">
                      <i className="ti ti-eye"></i>
                    </Link>
                    <button onClick={() => openPrintPopup(`/invoice-print/${inv.id}`)} className="btn btn-sm" title="Print">
                      <i className="ti ti-printer"></i>
                    </button>
                  </div>
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices {filter ? `with status "${filter}"` : 'yet today'}.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
PYEOF_9184337683489336113

cat > "app/(main)/billing/details/invoice-details-tab.js" << 'PYEOF_2980362005923187441'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'net_high', label: 'Net (High-Low)' },
  { value: 'net_low', label: 'Net (Low-High)' },
];

function sortInvoices(invoices, sort) {
  const list = [...invoices];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'net_high': return list.sort((a, b) => Number(b.net) - Number(a.net));
    case 'net_low': return list.sort((a, b) => Number(a.net) - Number(b.net));
    default: return list.sort((a, b) => new Date(b.created_at) - new Date(a.created_at)); // newest
  }
}

export default function InvoiceDetailsTab() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [invoices, setInvoices] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [error, setError] = useState('');

  const runSearch = useCallback(async () => {
    setInvoices(await searchInvoices(query, deptFilter));
  }, [query, deptFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  const sortedInvoices = sortInvoices(invoices, sortBy);

  async function openInvoice(inv) {
    setError('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  const balanceDue = selected ? Number(selected.net) - Number(selected.paid) : 0;

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Search Invoices
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 16, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 200 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Patient name or UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={deptFilter} onChange={(e) => setDeptFilter(e.target.value)}>
            <option value="">All departments</option>
            <option>Consultation</option>
            <option>Investigation</option>
            <option>Surgery</option>
            <option>Pharmacy</option>
          </select>
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>

        <table className="tbl">
          <thead><tr><th>Invoice #</th><th>Date</th><th>Patient</th><th>Visit</th><th>Gross</th><th>Disc</th><th>Net</th><th>Paid</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {sortedInvoices.map((inv) => (
              <tr key={inv.id} onClick={() => openInvoice(inv)} style={{ cursor: 'pointer', background: selected?.id === inv.id ? 'var(--blue-lt)' : 'transparent' }}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{inv.invoice_number || '--'}</td>
                <td>{new Date(inv.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}</td>
                <td style={{ fontWeight: 600 }}>{inv.patients?.first_name} {inv.patients?.last_name}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                <td>Rs.{inv.gross}</td>
                <td>{inv.gross - inv.net > 0 ? `Rs.${(inv.gross - inv.net).toFixed(2)}` : '--'}</td>
                <td>Rs.{inv.net}</td>
                <td>Rs.{inv.paid}</td>
                <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span></td>
                <td>
                  <button
                    onClick={(e) => { e.stopPropagation(); openPrintPopup(`/invoice-print/${inv.id}`); }}
                    className="btn"
                    style={{ padding: '3px 8px', fontSize: 11 }}
                    title="Print / PDF"
                  >
                    <i className="ti ti-printer"></i>
                  </button>
                </td>
              </tr>
            ))}
            {sortedInvoices.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No invoices found.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {selected && (
        <div>
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> {selected.invoice_number || 'Invoice Detail'}</div>
              <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
                <button onClick={() => openPrintPopup(`/invoice-print/${selected.id}`)} className="btn btn-sm">
                  <i className="ti ti-printer"></i> Print / PDF
                </button>
                <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
              </div>
            </div>
            {error && <div className="msg-err">{error}</div>}
            <div style={{ fontSize: 13, marginBottom: 12 }}>
              <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
            </div>
            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Net</th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id}><td>{li.service_name}</td><td>{li.qty}</td><td>Rs.{li.net}</td></tr>
                ))}
              </tbody>
            </table>
            <div style={{ fontSize: 13, lineHeight: 1.9, marginTop: 12, borderTop: '1px solid var(--g200)', paddingTop: 10 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Net Total</span><span style={{ fontWeight: 700 }}>Rs.{selected.net}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>Rs.{selected.paid}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, color: balanceDue > 0 ? 'var(--red)' : 'var(--green)' }}><span>Balance Due</span><span>Rs.{balanceDue}</span></div>
            </div>
          </div>

          {balanceDue > 0 && selected.status !== 'Cancelled' && (
            <div className="card">
              <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
                Balance of Rs.{balanceDue} still due on this invoice.
              </div>
              <a
                href={`/payments/collect?patientId=${selected.patient_id}&invoiceId=${selected.id}`}
                className="btn btn-primary"
                style={{ textDecoration: 'none' }}
              >
                <i className="ti ti-cash"></i> Collect Payment
              </a>
            </div>
          )}
        </div>
      )}
    </div>
  );
}


PYEOF_2980362005923187441

cat > "app/(main)/payments/receipt/receipt-tab.js" << 'PYEOF_3598455253585968263'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import { searchReceipts, editPaymentClerical, getPaymentEditHistory } from '../actions';
import { openPrintPopup } from '@/lib/printPopup';

const MODE_OPTIONS = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];
const TYPE_BADGE = { invoice_payment: 'b-blue', advance: 'b-purple', advance_adjustment: 'b-amber', credit_note: 'b-teal' };
const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Adjustment', credit_note: 'Credit Note' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'amount_high', label: 'Amount (High-Low)' },
  { value: 'amount_low', label: 'Amount (Low-High)' },
];

function sortReceipts(receipts, sort) {
  const list = [...receipts];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.collected_at) - new Date(b.collected_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'amount_high': return list.sort((a, b) => Number(b.total_amount) - Number(a.total_amount));
    case 'amount_low': return list.sort((a, b) => Number(a.total_amount) - Number(b.total_amount));
    default: return list.sort((a, b) => new Date(b.collected_at) - new Date(a.collected_at)); // newest
  }
}

export default function ReceiptTab() {
  const [query, setQuery] = useState('');
  const [modeFilter, setModeFilter] = useState('');
  const [sortBy, setSortBy] = useState('newest');
  const [receipts, setReceipts] = useState([]);

  const [editingId, setEditingId] = useState(null);
  const [editModes, setEditModes] = useState([]);
  const [editReference, setEditReference] = useState('');
  const [editRemarks, setEditRemarks] = useState('');
  const [editReason, setEditReason] = useState('');
  const [editHistory, setEditHistory] = useState([]);
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [saving, setSaving] = useState(false);

  const runSearch = useCallback(async () => {
    setReceipts(await searchReceipts(query, modeFilter));
  }, [query, modeFilter]);

  useEffect(() => { runSearch(); }, [runSearch]);

  const sortedReceipts = sortReceipts(receipts, sortBy);

  async function startEdit(r) {
    setError(''); setSuccess('');
    setEditingId(r.id);
    setEditModes((r.payment_modes || []).map((m) => ({ mode: m.mode, amount: String(m.amount) })));
    setEditReference(r.reference || '');
    setEditRemarks(r.remarks || '');
    setEditReason('');
    setEditHistory(await getPaymentEditHistory(r.id));
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  function updateModeRow(idx, field, value) {
    setEditModes((rows) => rows.map((row, i) => (i === idx ? { ...row, [field]: value } : row)));
  }

  function addModeRow() {
    setEditModes((rows) => [...rows, { mode: 'Cash', amount: '' }]);
  }

  function removeModeRow(idx) {
    setEditModes((rows) => rows.filter((_, i) => i !== idx));
  }

  async function saveEdit(receipt) {
    setError(''); setSuccess('');
    if (!editReason.trim()) { setError('A reason is required to edit this payment.'); return; }
    const modesPayload = editModes.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const modesSum = modesPayload.reduce((s, m) => s + m.amount, 0);
    if (Math.abs(modesSum - Number(receipt.total_amount)) > 0.01) {
      setError(`Mode split (Rs.${modesSum.toFixed(2)}) must still add up to the original amount collected (Rs.${Number(receipt.total_amount).toFixed(2)}). To change the amount itself, use Refund or Credit Note instead.`);
      return;
    }

    setSaving(true);
    const result = await editPaymentClerical(receipt.id, modesPayload, editReference, editRemarks, editReason);
    setSaving(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`${receipt.receipt_number} updated.`);
    setEditingId(null);
    runSearch();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-receipt" style={{ color: 'var(--green)' }}></i> Receipt Register
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          <input
            className="fi"
            style={{ flex: 2, minWidth: 220 }}
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Receipt #, patient, UHID..."
          />
          <select className="fi" style={{ flex: 1 }} value={modeFilter} onChange={(e) => setModeFilter(e.target.value)}>
            <option value="">All modes</option>
            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
          </select>
          <select className="fi" style={{ flex: 1 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
            {SORT_OPTIONS.map((o) => <option key={o.value} value={o.value}>Sort: {o.label}</option>)}
          </select>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

      <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
        <table className="tbl">
          <thead>
            <tr><th>Receipt #</th><th>Date/Time</th><th>Patient</th><th>Invoice ref</th><th>Mode(s)</th><th>Amount</th><th>Type</th><th></th></tr>
          </thead>
          <tbody>
            {sortedReceipts.map((r) => (
              <Fragment key={r.id}>
                <tr>
                  <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{r.receipt_number}</td>
                  <td>{new Date(r.collected_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td style={{ fontWeight: 600 }}>{r.patients?.first_name} {r.patients?.last_name}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_allocations || []).map((a) => a.invoices?.invoice_number).filter(Boolean).join(', ') || '--'}</td>
                  <td style={{ fontSize: 11 }}>{(r.payment_modes || []).map((m) => `${m.mode} Rs.${m.amount}`).join(', ')}</td>
                  <td style={{ fontWeight: 600 }}>Rs.{r.total_amount}</td>
                  <td><span className={`badge ${TYPE_BADGE[r.payment_type] || 'b-gray'}`}>{TYPE_LABEL[r.payment_type] || r.payment_type || 'Payment'}</span></td>
                  <td style={{ display: 'flex', gap: 4 }}>
                    <button className="btn btn-sm" onClick={() => openPrintPopup(`/receipt-print/${r.id}`)}>
                      <i className="ti ti-printer"></i>
                    </button>
                    <button className="btn btn-sm" onClick={() => (editingId === r.id ? cancelEdit() : startEdit(r))}>
                      <i className="ti ti-edit"></i> {editingId === r.id ? 'Close' : 'Edit'}
                    </button>
                  </td>
                </tr>
                {editingId === r.id && (
                  <tr key={`${r.id}-edit`}>
                    <td colSpan={8} style={{ background: 'var(--g50)', padding: 16 }}>
                      <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 10 }}>
                        <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Edit clerical details for {r.receipt_number}
                      </div>
                      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                        <i className="ti ti-info-circle"></i> For correcting clerical mistakes only -- payment mode, reference number, remarks. The mode split must still total Rs.{r.total_amount}. To change the amount collected, use Refund or Credit Note instead.
                      </div>

                      <label className="flbl">Payment mode(s)</label>
                      {editModes.map((row, idx) => (
                        <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                          <select className="fi" style={{ flex: 1 }} value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)}>
                            {MODE_OPTIONS.map((m) => <option key={m} value={m}>{m}</option>)}
                          </select>
                          <input type="number" className="fi" style={{ flex: 1 }} value={row.amount} onChange={(e) => updateModeRow(idx, 'amount', e.target.value)} placeholder="Amount" />
                          {editModes.length > 1 && <button className="btn" style={{ padding: '4px 10px' }} onClick={() => removeModeRow(idx)}>x</button>}
                        </div>
                      ))}
                      <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Add mode</button>

                      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
                        <div>
                          <label className="flbl">Reference / Transaction ID</label>
                          <input className="fi" value={editReference} onChange={(e) => setEditReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
                        </div>
                        <div>
                          <label className="flbl">Remarks</label>
                          <input className="fi" value={editRemarks} onChange={(e) => setEditRemarks(e.target.value)} />
                        </div>
                      </div>

                      <label className="flbl">Reason for this edit *</label>
                      <input className="fi" style={{ marginBottom: 10 }} value={editReason} onChange={(e) => setEditReason(e.target.value)} placeholder="e.g. Staff mis-entered UPI as Cash" />

                      <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                        <button className="btn btn-primary btn-sm" onClick={() => saveEdit(r)} disabled={saving}>{saving ? 'Saving...' : 'Save Correction'}</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </div>

                      {editHistory.length > 0 && (
                        <div>
                          <label className="flbl" style={{ marginBottom: 6 }}>Edit history</label>
                          {editHistory.map((h) => (
                            <div key={h.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g200)' }}>
                              {new Date(h.edited_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {h.profiles?.full_name || 'Staff'} -- {h.reason}
                            </div>
                          ))}
                        </div>
                      )}
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {sortedReceipts.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No receipts found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

PYEOF_3598455253585968263

cat > "app/consultation/[id]/consultation-form.js" << 'PYEOF_7907874723615931918'
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
            <button onClick={() => openPrintPopup(`/opd-case-sheet-print/${data.encounter.id}`)} className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </button>
            <button onClick={() => openPrintPopup(`/visit-summary-print/${data.encounter.id}`)} className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </button>
          </div>
          </fieldset>
        </div>
      </div>
    </div>
  );
}
PYEOF_7907874723615931918

echo "Files written. Run: npm run build"
