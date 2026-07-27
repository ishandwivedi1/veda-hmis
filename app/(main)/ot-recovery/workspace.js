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

