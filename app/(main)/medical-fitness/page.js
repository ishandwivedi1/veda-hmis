'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { formatPatientName, formatPatientAge } from '@/lib/patientName';
import { useSearchParams } from 'next/navigation';
import {
  getMedicalFitnessQueue, getMedicalFitnessHistory, getMedicalFitnessClearedToday, getMedicalFitnessDetail,
  getInvestigationMasterOptions, orderFitnessInvestigation, removeFitnessInvestigation,
  clearFitness, markNotFit, saveFitnessFormDraft, submitFitnessForm, getCurrentDoctorProfile,
} from './actions';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { openPopup } from '@/lib/popup';
import { openPrintPopup } from '@/lib/printPopup';
import AttachmentUploader from '@/app/components/AttachmentUploader';

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };
const HISTORY_STATUS_BADGE = { Cleared: 'b-green', 'Not Fit': 'b-red' };

function daysWaiting(referral) {
  const ms = new Date() - new Date(referral.referred_at);
  return Math.floor(ms / (1000 * 60 * 60 * 24));
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--amber)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// ── TAB 1: QUEUE (Pending Review) ──
function QueueTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  let filtered = rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${formatPatientName(r.visits?.patients)}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  filtered = [...filtered].sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.referred_at) - new Date(b.referred_at);
    if (sortBy === 'newest') return new Date(b.referred_at) - new Date(a.referred_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.surgical_cases?.priority] ?? 9) - (order[b.surgical_cases?.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Pending Review <span className="badge b-amber">{rows.length}</span></div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
          <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
            <option value="oldest">Oldest first</option>
            <option value="newest">Newest first</option>
            <option value="priority">Priority</option>
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && filtered.map((r) => {
        const dw = daysWaiting(r);
        return (
          <div key={r.id} onClick={() => onOpen(r.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {r.visits?.patients?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1, minWidth: 0 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(r.visits?.patients)}{formatPatientAge(r.visits?.patients) ? ` (${formatPatientAge(r.visits?.patients)})` : ''}</span>
              <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Pending Review</span>
              {r.surgical_cases?.priority && r.surgical_cases.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{r.surgical_cases.priority}</span>}
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})
              </div>
            </div>
            <div style={{ textAlign: 'right', fontSize: 10, color: dw > 3 ? 'var(--red)' : dw > 1 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
              {dw === 0 ? 'Today' : `${dw}d waiting`}
            </div>
            <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
          </div>
        );
      })}

      {!loading && filtered.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          {rows.length === 0 ? 'No referrals pending review. Counsellors refer patients from Counselling once package is confirmed and accepted.' : 'No referrals match this search.'}
        </div>
      )}
    </div>
  );
}

// ── CLEARED TODAY -- same-day decisions, shown separately from the
// full History so a doctor can see what's been decided today at a
// glance, matching the pattern IOL Approval uses. ──
function ClearedTodayCard({ rows, loading, onOpen }) {
  return (
    <div className="card" style={{ marginTop: 14 }}>
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Cleared Today</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 16, textAlign: 'center' }}>Loading...</div>}
      {!loading && rows.map((r) => (
        <div key={r.id} onClick={() => onOpen(r.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
          <div style={{ width: 34, height: 34, borderRadius: '50%', background: r.status === 'Cleared' ? 'var(--green)' : 'var(--red)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
            {r.visits?.patients?.first_name?.charAt(0) || '?'}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(r.visits?.patients)}{formatPatientAge(r.visits?.patients) ? ` (${formatPatientAge(r.visits?.patients)})` : ''}</span>
            <span className={`badge ${HISTORY_STATUS_BADGE[r.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{r.status}</span>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye}) -- by {r.clearedByName}
            </div>
          </div>
          <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
        </div>
      ))}
      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing decided yet today.</div>
      )}
    </div>
  );
}

// ── TAB 3: HISTORY (completed referrals) ──
function HistoryTab({ rows, loading, onOpen }) {
  const [statusFilter, setStatusFilter] = useState('');
  const [search, setSearch] = useState('');

  const counts = {
    Cleared: rows.filter((r) => r.status === 'Cleared').length,
    'Not Fit': rows.filter((r) => r.status === 'Not Fit').length,
  };

  let filtered = statusFilter ? rows.filter((r) => r.status === statusFilter) : rows;
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    filtered = filtered.filter((r) =>
      `${formatPatientName(r.visits?.patients)}`.toLowerCase().includes(q) ||
      (r.visits?.patients?.uhid || '').toLowerCase().includes(q)
    );
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Medical Fitness History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
        <button className={`btn btn-sm ${!statusFilter ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('')}>All ({rows.length})</button>
        <button className={`btn btn-sm ${statusFilter === 'Cleared' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Cleared')}>Cleared ({counts.Cleared})</button>
        <button className={`btn btn-sm ${statusFilter === 'Not Fit' ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('Not Fit')}>Not Fit ({counts['Not Fit']})</button>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Decided By</th><th>Date</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => (
              <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                <td>
                  <strong>{formatPatientName(r.visits?.patients)}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 12 }}>{r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})</td>
                <td><span className={`badge ${HISTORY_STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                <td style={{ fontSize: 12 }}>{r.clearedByName}</td>
                <td style={{ fontSize: 11 }}>{r.cleared_at ? new Date(r.cleared_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed referrals yet.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── TAB 2: WORKSPACE (per-patient clinical review) ──
function emptyFitnessForm() {
  return {
    systemicHistory: { diabetes: false, hypertension: false, heartDisease: false, thyroid: false, asthma: false, kidneyDisease: false, other: '' },
    previousSurgeryHistory: '',
    currentMedications: { antiDiabetic: false, bpMedicines: false, bloodThinners: false, other: '' },
    allergies: { none: false, yes: false, details: '', notes: '' },
    vitals: { bp: '', pulse: '', spo2: '', bloodSugar: '', notes: '' },
    investigations: { hb: '', rbs: '', fbs: '', ppbs: '', hiv: '', hbsag: '', other: '' },
    certification: { doctorName: '', qualification: '', registrationNo: '', notes: '' },
  };
}

function mergeFitnessForm(saved) {
  const base = emptyFitnessForm();
  if (!saved) return base;
  return {
    systemicHistory: { ...base.systemicHistory, ...saved.systemicHistory },
    previousSurgeryHistory: saved.previousSurgeryHistory || '',
    currentMedications: { ...base.currentMedications, ...saved.currentMedications },
    allergies: { ...base.allergies, ...saved.allergies },
    vitals: { ...base.vitals, ...saved.vitals },
    investigations: { ...base.investigations, ...saved.investigations },
    certification: { ...base.certification, ...saved.certification },
  };
}

export function WorkspaceTab({ referralId, onDone }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [subTab, setSubTab] = useState('summary');

  const [invOptions, setInvOptions] = useState([]);
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('N/A');
  const [invPriority, setInvPriority] = useState('Routine');
  const [ordering, setOrdering] = useState(false);
  const [expandedExternalId, setExpandedExternalId] = useState(null);

  const [form, setForm] = useState(emptyFitnessForm());
  const [saving, setSaving] = useState(false);
  const [savingDraft, setSavingDraft] = useState(false);
  const [okMsg, setOkMsg] = useState('');
  const [unlocked, setUnlocked] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getMedicalFitnessDetail(referralId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    setForm(mergeFitnessForm(result.referral.form_data));
  }, [referralId]);

  useEffect(() => {
    setData(null); setLoadError(''); setSubTab('summary'); setUnlocked(false);
    refresh();
    getInvestigationMasterOptions().then(setInvOptions);
    getCurrentDoctorProfile().then((profile) => {
      if (profile) {
        setForm((f) => (f.certification.doctorName ? f : {
          ...f, certification: { ...f.certification, doctorName: profile.full_name || '', registrationNo: profile.registration_no || '' },
        }));
      }
    });
  }, [referralId, refresh]);

  async function handleOrderInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Select or enter an investigation.'); return; }
    setOrdering(true);
    const result = await orderFitnessInvestigation(referralId, data.referral.encounter_id, { name: invName, eye: invEye, priority: invPriority });
    setOrdering(false);
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleRemoveInvestigation(id) {
    await removeFitnessInvestigation(id);
    refresh();
  }

  // Opened as a deep link from Surgical Journey (a real opener window
  // exists) -- signal the update back and close this tab so the person
  // lands right back on Surgical Journey instead of switching tabs and
  // manually refreshing. Returns true if it closed the tab (caller
  // should skip its own post-save cleanup in that case). Opened
  // normally from the sidebar (no opener), returns false so the
  // caller falls through to its usual in-place refresh/navigation.
  function notifyParentAndClose() {
    if (typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'fitness-updated', referralId }, window.location.origin);
      window.close();
      return true;
    }
    return false;
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg('');
    setSavingDraft(true);
    const result = await saveFitnessFormDraft(referralId, form);
    setSavingDraft(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved.');
    setTimeout(() => setOkMsg(''), 2000);
  }

  async function handleClear() {
    setError('');
    setSaving(true);
    const result = await submitFitnessForm(referralId, form, 'Cleared', form.certification.notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    if (notifyParentAndClose()) return;
    onDone();
  }

  async function handleMarkNotFit() {
    setError('');
    if (!form.certification.notes?.trim()) { setError('Notes are required when marking not fit.'); return; }
    setSaving(true);
    const result = await submitFitnessForm(referralId, form, 'Not Fit', form.certification.notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    if (notifyParentAndClose()) return;
    onDone();
  }

  // Correcting an already-decided form (same status, e.g. fixing a
  // vitals typo) instead of re-running the Cleared/Not Fit decision.
  async function handleUpdateDecided() {
    setError(''); setOkMsg('');
    setSaving(true);
    const result = await submitFitnessForm(referralId, form, data.referral.status, form.certification.notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    if (notifyParentAndClose()) return;
    setOkMsg('Updated.');
    setUnlocked(false);
    refresh();
    setTimeout(() => setOkMsg(''), 2000);
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { referral, currentDiagnoses, investigations, externalTests, diagnosisHistory, referredByName, clearedByName } = data;
  const patient = referral.visits.patients;
  const sc = referral.surgical_cases;
  const isPending = referral.status === 'Pending Review';
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const isTodayDecision = !!referral.cleared_at && new Date(referral.cleared_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) === todayIst;
  const formEditable = isPending || unlocked;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#a15c00,#d97706)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{formatPatientName(patient)}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient.uhid} -- {patient.age} {patient.gender} -- {referral.visits.visit_number}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .8 }}>Referred for surgery</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc?.procedure_name} ({sc?.eye})</div>
          <div style={{ fontSize: 10, opacity: .8 }}>By {referredByName} -- {new Date(referral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {referral.status !== 'Pending Review' && (
        <div className={`msg-${referral.status === 'Cleared' ? 'ok' : 'err'}`} style={{ marginBottom: 12 }}>
          <i className={`ti ${referral.status === 'Cleared' ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i>
          <span>
            <strong>{referral.status}</strong>{referral.fitness_notes ? ` -- ${referral.fitness_notes}` : ''}
            <span style={{ display: 'block', fontSize: 11, opacity: 0.85, marginTop: 2 }}>
              By Dr. {clearedByName || '--'} -- {referral.cleared_at ? new Date(referral.cleared_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '--'}
            </span>
          </span>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 14 }}>
        <div>
          <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <TabButton active={subTab === 'summary'} onClick={() => setSubTab('summary')} icon="ti-report-medical" label="Clinical Summary" />
            <TabButton active={subTab === 'investigations'} onClick={() => setSubTab('investigations')} icon="ti-flask" label={`Investigations${(investigations.length + externalTests.length) > 0 ? ` (${investigations.length + externalTests.length})` : ''}`} />
            <TabButton active={subTab === 'form'} onClick={() => setSubTab('form')} icon="ti-file-certificate" label="Fitness Form" />
          </div>

          {subTab === 'summary' && (
            <>
              <div className="card">
                <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-report-medical" style={{ color: 'var(--blue)' }}></i> Current Diagnoses</div>
                {currentDiagnoses.map((d) => (
                  <div key={d.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
                    <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
                    {d.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{d.notes}</div>}
                  </div>
                ))}
                {currentDiagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>None recorded.</div>}
              </div>

              <div className="card" style={{ marginBottom: 0 }}>
                <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(prior visits)</span></div>
                <div style={{ maxHeight: 260, overflowY: 'auto' }}>
                  {diagnosisHistory.map((d) => (
                    <div key={d.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 10.5 }}>{new Date(d.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      {' -- '}<strong>{d.name}</strong> -- {d.eye}
                    </div>
                  ))}
                  {diagnosisHistory.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior diagnoses on record.</div>}
                </div>
              </div>
            </>
          )}

          {subTab === 'investigations' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>

              {investigations.map((i) => {
                const isBiometry = i.name.trim().toLowerCase() === 'biometry';
                const type = matchInvestigationType(i.name);
                const hasResults = i.status === 'Available';
                return (
                  <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 12.5 }}>
                      <span><strong>{i.name}</strong> -- {i.eye}</span>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                        {isBiometry ? (
                          <a href="/biometry" target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '2px 6px', fontSize: 10, textDecoration: 'none' }}>
                            <i className="ti ti-ruler-measure"></i> Open Biometry
                          </a>
                        ) : hasResults && (
                          <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                            <i className="ti ti-eye"></i> View
                          </button>
                        )}
                        {!isBiometry && i.status === 'Ordered' && isPending && (
                          <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => handleRemoveInvestigation(i.id)}>Remove</button>
                        )}
                      </div>
                    </div>
                    {!isBiometry && hasResults && (
                      <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{summarizeResultData(type, i.result_data)}</div>
                    )}
                  </div>
                );
              })}
              {investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>None ordered yet.</div>}

              {isPending && (
                <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                  <select className="fi" style={{ flex: 2, minWidth: 140 }} value={invOptions.some((o) => o.name === invName) ? invName : ''} onChange={(e) => setInvName(e.target.value)}>
                    <option value="">-- Pick investigation --</option>
                    {invOptions.map((o) => <option key={o.code} value={o.name}>{o.name}</option>)}
                  </select>
                  <select className="fi" style={{ width: 80 }} value={invEye} onChange={(e) => setInvEye(e.target.value)}>
                    <option value="N/A">N/A</option><option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" style={{ width: 100 }} value={invPriority} onChange={(e) => setInvPriority(e.target.value)}>
                    <option value="Routine">Routine</option><option value="Urgent">Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleOrderInvestigation} disabled={ordering}>
                    {ordering ? 'Ordering...' : 'Order'}
                  </button>
                </div>
              )}

              <div style={{ borderTop: '1px solid var(--g100)', marginTop: 16, paddingTop: 12 }}>
                <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 2 }}>External Investigations</div>
                <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 8 }}>Blood work, HIV test, etc -- ordered from Surgical Journey, not done in-house. Reports shown here as they come back.</div>
                {externalTests.length === 0 ? (
                  <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>None ordered.</div>
                ) : (
                  externalTests.map((t) => (
                    <div key={t.id} style={{ background: 'var(--g50)', borderRadius: 6, marginBottom: 4 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', fontSize: 12, cursor: 'pointer' }} onClick={() => setExpandedExternalId(expandedExternalId === t.id ? null : t.id)}>
                        <span>{t.test_name}</span>
                        <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                          <span className="badge b-gray" style={{ fontSize: 10 }}>{t.attachmentCount > 0 ? `${t.attachmentCount} file${t.attachmentCount > 1 ? 's' : ''}` : 'No report yet'}</span>
                          <i className={`ti ${expandedExternalId === t.id ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
                        </div>
                      </div>
                      {expandedExternalId === t.id && (
                        <div style={{ padding: '0 8px 10px' }}>
                          <AttachmentUploader entityType="external_investigation" entityId={t.id} title="" />
                        </div>
                      )}
                    </div>
                  ))
                )}
              </div>
            </div>
          )}

          {subTab === 'form' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-head" style={{ marginBottom: 4, alignItems: 'flex-start' }}>
                <div className="card-title"><i className="ti ti-file-certificate" style={{ color: 'var(--amber)' }}></i> Medical Fitness Form for Eye Surgery</div>
                <div style={{ display: 'flex', gap: 6 }}>
                  {!isPending && isTodayDecision && !unlocked && (
                    <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
                      <i className="ti ti-edit"></i> Edit
                    </button>
                  )}
                  <button className="btn btn-sm" onClick={() => setSubTab('investigations')}>
                    <i className="ti ti-flask"></i> View Investigation Reports
                  </button>
                </div>
              </div>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 12 }}>Review the patient&apos;s investigation reports before filling in the values below.</div>
              {okMsg && <div className="msg-ok" style={{ marginBottom: 10 }}><i className="ti ti-circle-check"></i> {okMsg}</div>}
              {!isPending && !unlocked && (
                <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
                  <i className="ti ti-lock"></i> This form is finalized{isTodayDecision ? ' -- use Edit above to correct it.' : '.'}
                </div>
              )}

              <fieldset disabled={!formEditable} style={{ border: 'none', padding: 0, margin: 0 }}>
                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>1. Systemic History</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 4, marginBottom: 6, fontSize: 12.5 }}>
                  {[
                    ['diabetes', 'Diabetes'], ['hypertension', 'Hypertension'],
                    ['heartDisease', 'Heart Disease'], ['thyroid', 'Thyroid Disorder'],
                    ['asthma', 'Asthma'], ['kidneyDisease', 'Kidney Disease'],
                  ].map(([key, label]) => (
                    <label key={key} style={{ display: 'flex', alignItems: 'center', gap: 6, cursor: isPending ? 'pointer' : 'default' }}>
                      <input type="checkbox" checked={!!form.systemicHistory[key]} onChange={(e) => setForm((f) => ({ ...f, systemicHistory: { ...f.systemicHistory, [key]: e.target.checked } }))} />
                      {label}
                    </label>
                  ))}
                </div>
                <input className="fi fi-sm" placeholder="Other systemic history..." value={form.systemicHistory.other} onChange={(e) => setForm((f) => ({ ...f, systemicHistory: { ...f.systemicHistory, other: e.target.value } }))} style={{ marginBottom: 14 }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>2. Previous Surgery / Hospitalization</div>
                <textarea className="fi fi-sm" rows={2} value={form.previousSurgeryHistory} onChange={(e) => setForm((f) => ({ ...f, previousSurgeryHistory: e.target.value }))} style={{ marginBottom: 14, width: '100%' }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>3. Current Medications</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 4, marginBottom: 6, fontSize: 12.5 }}>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <input type="checkbox" checked={form.currentMedications.antiDiabetic} onChange={(e) => setForm((f) => ({ ...f, currentMedications: { ...f.currentMedications, antiDiabetic: e.target.checked } }))} />
                    Anti-diabetic / Insulin
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <input type="checkbox" checked={form.currentMedications.bpMedicines} onChange={(e) => setForm((f) => ({ ...f, currentMedications: { ...f.currentMedications, bpMedicines: e.target.checked } }))} />
                    Blood pressure medicines
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <input type="checkbox" checked={form.currentMedications.bloodThinners} onChange={(e) => setForm((f) => ({ ...f, currentMedications: { ...f.currentMedications, bloodThinners: e.target.checked } }))} />
                    Blood thinners
                  </label>
                </div>
                <input className="fi fi-sm" placeholder="Other medicines..." value={form.currentMedications.other} onChange={(e) => setForm((f) => ({ ...f, currentMedications: { ...f.currentMedications, other: e.target.value } }))} style={{ marginBottom: 14 }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>4. Drug Allergies</div>
                <div style={{ display: 'flex', gap: 14, marginBottom: 6, fontSize: 12.5 }}>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <input type="radio" name={`allergy-${referralId}`} checked={form.allergies.none} onChange={() => setForm((f) => ({ ...f, allergies: { ...f.allergies, none: true, yes: false } }))} />
                    No Known Allergy
                  </label>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <input type="radio" name={`allergy-${referralId}`} checked={form.allergies.yes} onChange={() => setForm((f) => ({ ...f, allergies: { ...f.allergies, none: false, yes: true } }))} />
                    Yes
                  </label>
                </div>
                {form.allergies.yes && (
                  <input className="fi fi-sm" placeholder="Allergy details..." value={form.allergies.details} onChange={(e) => setForm((f) => ({ ...f, allergies: { ...f.allergies, details: e.target.value } }))} style={{ marginBottom: 6 }} />
                )}
                <input className="fi fi-sm" placeholder="Notes (optional)..." value={form.allergies.notes} onChange={(e) => setForm((f) => ({ ...f, allergies: { ...f.allergies, notes: e.target.value } }))} style={{ marginBottom: 14 }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>5. Vital Signs</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 6, marginBottom: 6 }}>
                  <div><label className="flbl">BP (mmHg)</label><input className="fi fi-sm" value={form.vitals.bp} onChange={(e) => setForm((f) => ({ ...f, vitals: { ...f.vitals, bp: e.target.value } }))} /></div>
                  <div><label className="flbl">Pulse (/min)</label><input className="fi fi-sm" value={form.vitals.pulse} onChange={(e) => setForm((f) => ({ ...f, vitals: { ...f.vitals, pulse: e.target.value } }))} /></div>
                  <div><label className="flbl">SpO2 (%)</label><input className="fi fi-sm" value={form.vitals.spo2} onChange={(e) => setForm((f) => ({ ...f, vitals: { ...f.vitals, spo2: e.target.value } }))} /></div>
                  <div><label className="flbl">Blood Sugar</label><input className="fi fi-sm" value={form.vitals.bloodSugar} onChange={(e) => setForm((f) => ({ ...f, vitals: { ...f.vitals, bloodSugar: e.target.value } }))} /></div>
                </div>
                <input className="fi fi-sm" placeholder="Notes (optional)..." value={form.vitals.notes} onChange={(e) => setForm((f) => ({ ...f, vitals: { ...f.vitals, notes: e.target.value } }))} style={{ marginBottom: 14 }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>6. Investigations</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 8 }}>
                  <div><label className="flbl">Hemoglobin (Hb)</label><input className="fi fi-sm" value={form.investigations.hb} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, hb: e.target.value } }))} /></div>
                  <div><label className="flbl">Random Blood Sugar (RBS)</label><input className="fi fi-sm" value={form.investigations.rbs} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, rbs: e.target.value } }))} /></div>
                  <div><label className="flbl">Fasting Blood Sugar (FBS)</label><input className="fi fi-sm" value={form.investigations.fbs} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, fbs: e.target.value } }))} /></div>
                  <div><label className="flbl">PPBS</label><input className="fi fi-sm" value={form.investigations.ppbs} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, ppbs: e.target.value } }))} /></div>
                </div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 8, fontSize: 12 }}>
                  <div>
                    <label className="flbl">HIV I &amp; II</label>
                    <select className="fi fi-sm" value={form.investigations.hiv} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, hiv: e.target.value } }))}>
                      <option value="">--</option><option value="Non-Reactive">Non-Reactive</option><option value="Reactive">Reactive</option>
                    </select>
                  </div>
                  <div>
                    <label className="flbl">HBsAg</label>
                    <select className="fi fi-sm" value={form.investigations.hbsag} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, hbsag: e.target.value } }))}>
                      <option value="">--</option><option value="Non-Reactive">Non-Reactive</option><option value="Reactive">Reactive</option>
                    </select>
                  </div>
                </div>
                <input className="fi fi-sm" placeholder="Other investigations..." value={form.investigations.other} onChange={(e) => setForm((f) => ({ ...f, investigations: { ...f.investigations, other: e.target.value } }))} style={{ marginBottom: 14 }} />

                <div style={{ fontWeight: 700, fontSize: 12.5, marginBottom: 6 }}>7. Physician Certification</div>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 8 }}>
                  <div><label className="flbl">Doctor Name</label><input className="fi fi-sm" value={form.certification.doctorName} onChange={(e) => setForm((f) => ({ ...f, certification: { ...f.certification, doctorName: e.target.value } }))} /></div>
                  <div><label className="flbl">Qualification</label><input className="fi fi-sm" value={form.certification.qualification} onChange={(e) => setForm((f) => ({ ...f, certification: { ...f.certification, qualification: e.target.value } }))} /></div>
                  <div><label className="flbl">Registration Number</label><input className="fi fi-sm" value={form.certification.registrationNo} onChange={(e) => setForm((f) => ({ ...f, certification: { ...f.certification, registrationNo: e.target.value } }))} /></div>
                </div>
                <textarea className="fi fi-sm" rows={2} placeholder="Clinical notes / certificate remarks (required if marking not fit, optional if clearing)" value={form.certification.notes} onChange={(e) => setForm((f) => ({ ...f, certification: { ...f.certification, notes: e.target.value } }))} style={{ marginBottom: 10, width: '100%' }} />
              </fieldset>

              {isPending ? (
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn" onClick={handleSaveDraft} disabled={savingDraft}>
                    <i className="ti ti-device-floppy"></i> {savingDraft ? 'Saving...' : 'Save Draft'}
                  </button>
                  <button className="btn btn-primary" style={{ flex: 1 }} onClick={handleClear} disabled={saving}>
                    <i className="ti ti-circle-check"></i> {saving ? 'Saving...' : 'Give Clearance'}
                  </button>
                  <button className="btn" style={{ flex: 1, color: 'var(--red)' }} onClick={handleMarkNotFit} disabled={saving}>
                    <i className="ti ti-x"></i> Not Fit
                  </button>
                </div>
              ) : unlocked ? (
                <div style={{ display: 'flex', gap: 8 }}>
                  <button className="btn btn-primary" style={{ flex: 1 }} onClick={handleUpdateDecided} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Changes'}
                  </button>
                  <button className="btn" onClick={() => { setUnlocked(false); setForm(mergeFitnessForm(data.referral.form_data)); }}>
                    Cancel
                  </button>
                </div>
              ) : (
                <button className="btn btn-primary" onClick={() => openPrintPopup(`/medical-fitness-print/${referralId}`)}>
                  <i className="ti ti-printer"></i> Print / PDF Certificate
                </button>
              )}
            </div>
          )}
        </div>

        <div>
          {isPending ? (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-clipboard-check" style={{ color: 'var(--amber)' }}></i> Fitness Decision</div>
              <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>
                Fill in the <button className="btn btn-sm" style={{ display: 'inline', padding: '1px 6px' }} onClick={() => setSubTab('form')}>Fitness Form</button> tab, then Give Clearance or mark Not Fit from there.
              </div>
            </div>
          ) : (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-certificate" style={{ color: 'var(--green)' }}></i> Certificate</div>
              <button className="btn btn-primary" style={{ width: '100%', marginBottom: isTodayDecision ? 8 : 0 }} onClick={() => openPrintPopup(`/medical-fitness-print/${referralId}`)}>
                <i className="ti ti-printer"></i> Print / PDF
              </button>
              {isTodayDecision && (
                <button className="btn" style={{ width: '100%' }} onClick={() => { setUnlocked(true); setSubTab('form'); }}>
                  <i className="ti ti-edit"></i> Edit Today&apos;s Form
                </button>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

// ── PAGE: single SPA with client-side tab switching, matching Counselling ──
// Deep-linkable via ?referralId=... -- Surgical Journey's Medical
// Fitness step links straight here with the referral's id so it opens
// that patient's own record instead of dropping onto the Queue for a
// manual pick. An already-decided referral opens read-only by default
// (formEditable = isPending || unlocked, see WorkspaceTab above) --
// same locked-until-unlocked treatment used in Biometry and IOL
// Approval, so no separate "view mode" flag is needed here.
function MedicalFitnessInner() {
  const searchParams = useSearchParams();
  const deepLinkReferralId = searchParams.get('referralId');

  const [queueRows, setQueueRows] = useState([]);
  const [clearedTodayRows, setClearedTodayRows] = useState([]);
  const [historyRows, setHistoryRows] = useState([]);
  const [loadingQueue, setLoadingQueue] = useState(true);
  const [loadingClearedToday, setLoadingClearedToday] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState(deepLinkReferralId ? 'workspace' : 'queue');
  const [selectedReferralId, setSelectedReferralId] = useState(deepLinkReferralId || null);

  const refreshQueue = useCallback(async () => {
    setQueueRows(await getMedicalFitnessQueue());
    setLoadingQueue(false);
  }, []);
  const refreshClearedToday = useCallback(async () => {
    setClearedTodayRows(await getMedicalFitnessClearedToday());
    setLoadingClearedToday(false);
  }, []);
  const refreshHistory = useCallback(async () => {
    setHistoryRows(await getMedicalFitnessHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refreshQueue(); refreshClearedToday(); refreshHistory(); }, [refreshQueue, refreshClearedToday, refreshHistory]);

  function openReferral(id) {
    setSelectedReferralId(id);
    setActiveTab('workspace');
  }

  function handleWorkspaceDone() {
    // A decision was just made -- refresh all three lists (patient
    // moves out of Queue and into Cleared Today) and go back to the Queue.
    refreshQueue();
    refreshClearedToday();
    refreshHistory();
    setSelectedReferralId(null);
    setActiveTab('queue');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'queue'} onClick={() => setActiveTab('queue')} icon="ti-list-numbers" label="Queue (Pending Review)" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-user-square" label="Workspace" disabled={!selectedReferralId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'queue' && (
        <>
          <QueueTab rows={queueRows} loading={loadingQueue} onOpen={openReferral} />
          <ClearedTodayCard rows={clearedTodayRows} loading={loadingClearedToday} onOpen={openReferral} />
        </>
      )}
      {activeTab === 'history' && <HistoryTab rows={historyRows} loading={loadingHistory} onOpen={openReferral} />}
      {activeTab === 'workspace' && selectedReferralId && <WorkspaceTab referralId={selectedReferralId} onDone={handleWorkspaceDone} />}
      {activeTab === 'workspace' && !selectedReferralId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Queue or History tab.
        </div>
      )}
    </div>
  );
}

export default function MedicalFitnessPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <MedicalFitnessInner />
    </Suspense>
  );
}

