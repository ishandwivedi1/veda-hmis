'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { formatPatientName } from '@/lib/patientName';
import {
  getConsultationData, addPrescription, removePrescription, addTaperedPrescription,
  removeTaperGroup, saveExamination, completeConsultation, getFollowUpContext,
} from '@/app/(main)/consultation/actions';
import {
  getFollowupReviewContext, markFollowupStatus, addFollowup, closeEpisode, addRecoveryComplication,
} from '@/app/(main)/ot-postop/actions';
import { getDrugs, getDosageOptions } from '@/app/(main)/master-data/actions';
import { openPrintPopup } from '@/lib/printPopup';
import { PatientSnapshotBar } from './follow-up-panel';

function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function addDays(days) {
  const d = new Date();
  d.setDate(d.getDate() + days);
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function addMonths(months) {
  const d = new Date();
  d.setMonth(d.getMonth() + months);
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}
function eyeLabel(eye) {
  if (eye === 'OD') return 'Right Eye (OD)';
  if (eye === 'OS') return 'Left Eye (OS)';
  return 'Both Eyes (OU)';
}
function vaLine(f, side) {
  if (!f || f.va_not_assessed) return 'Not assessed';
  const unaided = f[`${side}_dist_unaided`];
  const glasses = f[`${side}_dist_glasses`];
  const ph = f[`${side}_dist_ph`];
  const parts = [];
  if (unaided) parts.push(`Unaided ${unaided}`);
  if (glasses) parts.push(`With glasses ${glasses}`);
  if (ph) parts.push(`PH ${ph}`);
  return parts.length > 0 ? parts.join(' / ') : '--';
}

export default function PostOpReviewForm({ queueEntryId, followupId }) {
  const router = useRouter();
  const [data, setData] = useState(null);
  const [reviewCtx, setReviewCtx] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);

  const [drugOptions, setDrugOptions] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);

  // Review note (per operated eye) -- backed by clinical_examinations.remarks_re/remarks_le,
  // same columns the full Examination tab uses, so nothing new to store or migrate.
  const [noteRe, setNoteRe] = useState('');
  const [noteLe, setNoteLe] = useState('');
  const [noteSaved, setNoteSaved] = useState(true);

  // Prescription form -- same fields/behavior as the full consultation form's Treatment section.
  const [rxDrug, setRxDrug] = useState('');
  const [rxDrugTypeId, setRxDrugTypeId] = useState(null);
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [rxDosage, setRxDosage] = useState('');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxCustomDuration, setRxCustomDuration] = useState('');
  const [rxEye, setRxEye] = useState('BE');
  const [rxIsOcular, setRxIsOcular] = useState(true);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week', dosage: '' },
    { frequency: 'TDS', duration: '1 week', dosage: '' },
    { frequency: 'BD', duration: '1 week', dosage: '' },
    { frequency: 'OD', duration: '1 week', dosage: '' },
  ]);

  // Optional quick complication note -- same fields as ot-postop's own form.
  const [showCompl, setShowCompl] = useState(false);
  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  // Bottom decision -- schedule the next review, or close the episode outright.
  const [decisionMode, setDecisionMode] = useState('schedule');
  const [fuLabel, setFuLabel] = useState('Post-op Review');
  const [fuDate, setFuDate] = useState('');
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [queueEntryId]);

  useEffect(() => { refresh(); }, [refresh]);

  useEffect(() => {
    if (!followupId) { setLoadError('No follow-up reference was passed to this review -- open it from the Post-op dashboard\'s "Start Review" / "Open Review" button instead of this link directly.'); return; }
    getFollowupReviewContext(followupId).then((r) => {
      if (r.error) { setLoadError(r.error); return; }
      setReviewCtx(r);
    });
  }, [followupId]);

  useEffect(() => {
    (async () => {
      const [dr, dg] = await Promise.all([getDrugs(), getDosageOptions()]);
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      setDosageOptions(dg);
    })();
  }, []);

  useEffect(() => {
    if (!data) return;
    setNoteRe(data.examination?.remarks_re || '');
    setNoteLe(data.examination?.remarks_le || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
  }, [data, followUpContext]);

  const rxSuggestions = rxDrug.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(rxDrug.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(rxDrug.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectRxDrug(d) {
    setRxDrug(d.brand);
    setRxDrugTypeId(d.drug_type_id || null);
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

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const effectiveDuration = rxDuration === 'Custom' ? rxCustomDuration.trim() : rxDuration;
    if (rxDuration === 'Custom' && !effectiveDuration) { setError('Enter the custom duration.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: effectiveDuration, eye: rxIsOcular ? rxEye : 'Oral',
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddTaperSchedule() {
    setError('');
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    const steps = taperSteps.map((s) => ({ ...s, dosage: s.dosage || rxDosage }));
    if (steps.some((s) => !s.dosage.trim())) { setError('Select a dosage for every step of the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, eye: rxIsOcular ? rxEye : 'Oral', steps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setRxIsOcular(true); setShowTaperBuilder(false);
    refresh();
  }

  async function handleSaveNote() {
    setError('');
    setSaving(true);
    const eye = reviewCtx?.sc?.eye;
    const fields = {};
    if (eye !== 'OS') fields.remarks_re = noteRe;
    if (eye !== 'OD') fields.remarks_le = noteLe;
    const result = await saveExamination(data.examination.id, data.encounter.id, fields);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setNoteSaved(true);
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    if (!complName.trim()) { setError('Complication name is required.'); return; }
    const result = await addRecoveryComplication(reviewCtx.episode.id, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome(''); setShowCompl(false);
    setOk('Complication recorded.');
  }

  // This screen is meant to be opened in its own window (see
  // ot-postop's "Start Review" / "Open Review") -- closes itself once
  // the doctor is done, same pattern as the full consultation form.
  function finishAndClose() {
    window.close();
    router.push('/queue');
  }

  async function handleFinishSchedule() {
    setError('');
    if (!fuLabel.trim()) { setError('A label for the next review is required.'); return; }
    if (!fuDate) { setError('Pick a date for the next review.'); return; }
    setSaving(true);
    let result = await markFollowupStatus(reviewCtx.followup.id, 'Completed');
    if (!result.error) result = await addFollowup(reviewCtx.episode.id, fuLabel, fuDate);
    if (!result.error) result = await completeConsultation(data.encounter.id, queueEntryId);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleFinishClose() {
    setError('');
    if (!closureOutcome) { setError('Overall clinical outcome is required to close the episode.'); return; }
    setSaving(true);
    let result = await markFollowupStatus(reviewCtx.followup.id, 'Completed');
    if (!result.error) result = await closeEpisode(reviewCtx.episode.id, { status: closureStatus, outcome: closureOutcome, remarks: closureRemarks });
    if (!result.error) result = await completeConsultation(data.encounter.id, queueEntryId);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  if (loadError) return <div style={{ maxWidth: 700, margin: '40px auto' }}><div className="msg-err">{loadError}</div></div>;
  if (!data || !reviewCtx) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = data.entry.visits.patients;
  const sc = reviewCtx.sc;
  const findings = data.findings;
  // Past, already-completed reviews (opened via "View Record") are
  // shown read-only -- editing controls and the schedule/close decision
  // are hidden so nothing here can accidentally re-fire a completed
  // encounter's follow-up scheduling or episode closure a second time.
  const isLocked = data.isLocked;

  return (
    <div style={{ maxWidth: 900, margin: '0 auto', padding: '20px 26px' }}>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '14px 20px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 42, height: 42, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0 }}>
          {patient.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 16, fontWeight: 800 }}>{formatPatientName(patient)}</div>
          <div style={{ fontSize: 12, opacity: .85 }}>
            {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- {sc?.procedure_name} ({sc?.eye}) -- {sc?.profiles?.full_name}
          </div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isLocked ? 'Completed' : 'Post-op Review'} -- {reviewCtx.followup.visit_label}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={() => openPrintPopup(`/postop-review-print/${followupId}`)}>
          <i className="ti ti-printer"></i> Print
        </button>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {ok && <div className="msg-ok">{ok}</div>}
      {isLocked && (
        <div className="msg-info" style={{ marginBottom: 14 }}>
          <i className="ti ti-eye"></i> This review is already completed -- shown read-only for reference.
        </div>
      )}

      {data.isFollowUp && followUpContext && <PatientSnapshotBar snapshot={followUpContext.snapshot} />}

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-eye-check" style={{ color: 'var(--purple)' }}></i> Optometrist's Findings</div>
        {!findings ? (
          <div style={{ fontSize: 12, color: 'var(--amber)' }}><i className="ti ti-alert-triangle"></i> No completed optometry assessment on file for this visit yet.</div>
        ) : (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            <div>
              <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}>Vision -- Right Eye</div>
              <div style={{ fontSize: 13 }}>{vaLine(findings, 're')}</div>
            </div>
            <div>
              <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}>Vision -- Left Eye</div>
              <div style={{ fontSize: 13 }}>{vaLine(findings, 'le')}</div>
            </div>
            <div style={{ gridColumn: '1 / -1' }}>
              <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}>IOP{findings.iop_method ? ` -- ${findings.iop_method}` : ''}</div>
              <div style={{ fontSize: 13 }}>
                {data.iopReadings.length > 0
                  ? data.iopReadings.map((r) => `${r.eye} ${r.value}`).join(' | ')
                  : 'Not recorded'}
              </div>
            </div>
          </div>
        )}
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-microscope" style={{ color: 'var(--blue)' }}></i> Doctor's Review</div>
        <div style={{ display: 'grid', gridTemplateColumns: sc?.eye === 'OU' ? '1fr 1fr' : '1fr', gap: 10 }}>
          {sc?.eye !== 'OS' && (
            <div>
              <label className="flbl">{sc?.eye === 'OU' ? 'Right Eye' : eyeLabel(sc?.eye)} -- general impression</label>
              {isLocked ? <div style={{ fontSize: 13, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{noteRe || '--'}</div> : (
                <textarea className="fi fi-sm" rows={2} value={noteRe} onChange={(e) => { setNoteRe(e.target.value); setNoteSaved(false); }} placeholder="e.g. Quiet, healing well, no complaints..." />
              )}
            </div>
          )}
          {sc?.eye !== 'OD' && (
            <div>
              <label className="flbl">{sc?.eye === 'OU' ? 'Left Eye' : eyeLabel(sc?.eye)} -- general impression</label>
              {isLocked ? <div style={{ fontSize: 13, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{noteLe || '--'}</div> : (
                <textarea className="fi fi-sm" rows={2} value={noteLe} onChange={(e) => { setNoteLe(e.target.value); setNoteSaved(false); }} placeholder="e.g. Quiet, healing well, no complaints..." />
              )}
            </div>
          )}
        </div>
        {!isLocked && (
          <>
            <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSaveNote} disabled={saving}>{saving ? 'Saving...' : 'Save Note'}</button>
            {noteSaved && (noteRe || noteLe) && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
          </>
        )}
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Medications</div>
        {!isLocked && data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && (
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
          const seen = new Set();
          const items = [];
          data.prescriptions.forEach((r) => {
            if (r.taper_group_id) {
              if (seen.has(r.taper_group_id)) return;
              seen.add(r.taper_group_id);
              const steps = data.prescriptions.filter((x) => x.taper_group_id === r.taper_group_id).sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
              items.push({ type: 'taper', key: r.taper_group_id, steps });
            } else {
              items.push({ type: 'single', key: r.id, row: r });
            }
          });
          return items.map((item) => item.type === 'single' ? (
            <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
              <span><strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye || 'Oral'}</span>
              {!isLocked && <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>}
            </div>
          ) : (
            <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <span style={{ fontSize: 13 }}>
                  <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye || 'Oral'}
                  <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering</span>
                </span>
                {!isLocked && <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>}
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

        {!isLocked && (
        <>
        <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap', alignItems: 'flex-start' }}>
          <div style={{ position: 'relative', flex: '2 1 160px' }}>
            <input
              className="fi" placeholder="Type to search medicines, or enter a new name" value={rxDrug}
              onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setRxIsOcular(true); setShowRxSuggestions(true); }}
              onFocus={() => setShowRxSuggestions(true)} onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
              autoCapitalize="off" autoCorrect="off" spellCheck="false" style={{ width: '100%' }}
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
            {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>)}
            {!rxDrugTypeId && (<><option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option></>)}
          </select>
          <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
          </select>
          <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
            <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
            <option>1 week</option><option>2 weeks</option><option>10 days</option><option>20 days</option>
            <option>1 month</option><option>2 months</option><option>3 months</option><option>4 months</option><option>5 months</option><option>6 months</option>
            <option>Ongoing</option><option value="Custom">Custom...</option>
          </select>
          {rxDuration === 'Custom' && (
            <input className="fi" placeholder="e.g. 18 days, 3 weeks" value={rxCustomDuration} onChange={(e) => setRxCustomDuration(e.target.value)} style={{ flex: '1 1 130px' }} />
          )}
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
          <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => { setShowTaperBuilder(true); setTaperSteps((prev) => prev.map((s) => ({ ...s, dosage: s.dosage || rxDosage }))); }}>
            <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
          </button>
        ) : (
          <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
            <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
              <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug{rxIsOcular ? ' & Eye' : ''} entered above; dosage defaults to what you set above but can vary per step
            </div>
            {taperSteps.map((s, i) => (
              <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                <select className="fi fi-sm" value={s.dosage} onChange={(e) => updateTaperStep(i, 'dosage', e.target.value)} style={{ maxWidth: 110 }}>
                  <option value="">-- Dosage --</option>
                  {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>)}
                  {!rxDrugTypeId && (<><option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option></>)}
                </select>
                <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                  <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                </select>
                <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                  <option>1 day</option><option>2 days</option><option>3 days</option><option>4 days</option><option>5 days</option>
                  <option>1 week</option><option>2 weeks</option><option>10 days</option><option>20 days</option>
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
        </>
        )}
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Complication <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(optional)</span></div>
        {!showCompl ? (
          !isLocked && <button className="btn btn-sm" onClick={() => setShowCompl(true)}><i className="ti ti-plus"></i> Note a complication</button>
        ) : (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication (e.g. Raised IOP, CME)..." />
              <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management..." />
              <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome..." />
            </div>
            <div style={{ display: 'flex', gap: 6 }}>
              <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}>Save</button>
              <button className="btn btn-sm" onClick={() => setShowCompl(false)}>Cancel</button>
            </div>
          </>
        )}
      </div>

      {!isLocked ? (
      <div className="card" style={{ marginBottom: 0 }}>
        <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 420 }}>
          <button type="button" onClick={() => setDecisionMode('schedule')} style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: decisionMode === 'schedule' ? '#fff' : 'transparent', color: decisionMode === 'schedule' ? 'var(--purple)' : 'var(--g500)', cursor: 'pointer', boxShadow: decisionMode === 'schedule' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}>
            <i className="ti ti-calendar-plus"></i> Schedule Next Review
          </button>
          <button type="button" onClick={() => setDecisionMode('close')} style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: decisionMode === 'close' ? '#fff' : 'transparent', color: decisionMode === 'close' ? 'var(--purple)' : 'var(--g500)', cursor: 'pointer', boxShadow: decisionMode === 'close' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}>
            <i className="ti ti-circle-check"></i> Close Episode
          </button>
        </div>

        {decisionMode === 'schedule' ? (
          <div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Review label</label>
              <input className="fi" value={fuLabel} onChange={(e) => setFuLabel(e.target.value)} placeholder="e.g. Post-op Week 2" />
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">When</label>
              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 6 }}>
                <button className="btn btn-sm" onClick={() => setFuDate(addDays(7))}>1 week</button>
                <button className="btn btn-sm" onClick={() => setFuDate(addDays(14))}>2 weeks</button>
                <button className="btn btn-sm" onClick={() => setFuDate(addMonths(1))}>1 month</button>
                <input type="date" className="fi fi-sm" min={todayIst()} value={fuDate} onChange={(e) => setFuDate(e.target.value)} style={{ width: 160 }} />
              </div>
            </div>
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleFinishSchedule} disabled={saving}>
              {saving ? 'Saving...' : 'Schedule & Finish Review'}
            </button>
          </div>
        ) : (
          <div>
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
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleFinishClose} disabled={saving}>
              {saving ? 'Closing...' : 'Close Episode & Finish Review'}
            </button>
          </div>
        )}
      </div>
      ) : (
        <div className="msg-ok">
          <i className="ti ti-circle-check"></i> <span><strong>Review Completed</strong> -- {reviewCtx.followup.status}.</span>
        </div>
      )}
    </div>
  );
}
