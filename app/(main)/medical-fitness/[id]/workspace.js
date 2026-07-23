'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getMedicalFitnessDetail, getInvestigationMasterOptions,
  orderFitnessInvestigation, removeFitnessInvestigation,
  clearFitness, markNotFit,
} from '../actions';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

export default function MedicalFitnessWorkspace({ referralId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [invOptions, setInvOptions] = useState([]);
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('N/A');
  const [invPriority, setInvPriority] = useState('Routine');
  const [ordering, setOrdering] = useState(false);
  const [decisionNotes, setDecisionNotes] = useState('');
  const [showNotFitForm, setShowNotFitForm] = useState(false);
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getMedicalFitnessDetail(referralId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [referralId]);

  useEffect(() => {
    refresh();
    getInvestigationMasterOptions().then(setInvOptions);
  }, [refresh]);

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

  async function handleClear() {
    setError('');
    setSaving(true);
    const result = await clearFitness(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    router.push('/medical-fitness');
  }

  async function handleMarkNotFit() {
    setError('');
    if (!decisionNotes.trim()) { setError('Notes are required when marking not fit.'); return; }
    setSaving(true);
    const result = await markNotFit(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    router.push('/medical-fitness');
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const { referral, currentDiagnoses, investigations, diagnosisHistory, referredByName } = data;
  const patient = referral.visits.patients;
  const sc = referral.surgical_cases;
  const isPending = referral.status === 'Pending Review';

  return (
    <div style={{ maxWidth: 1100, margin: '0 auto' }}>
      <div style={{ background: 'linear-gradient(135deg,#b45309,#d97706)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient.uhid} -- {patient.age} {patient.gender} -- {referral.visits.visit_number}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .8 }}>Referred for surgery</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc?.procedure_name} ({sc?.eye})</div>
          <div style={{ fontSize: 10, opacity: .8 }}>By {referredByName} -- {new Date(referral.referred_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {referral.status !== 'Pending Review' && (
        <div className={`msg-${referral.status === 'Cleared' ? 'ok' : 'err'}`} style={{ marginBottom: 12 }}>
          <i className={`ti ${referral.status === 'Cleared' ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i>
          <span><strong>{referral.status}</strong>{referral.fitness_notes ? ` -- ${referral.fitness_notes}` : ''}</span>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
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

          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(prior visits)</span></div>
            <div style={{ maxHeight: 200, overflowY: 'auto' }}>
              {diagnosisHistory.map((d) => (
                <div key={d.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <span style={{ color: 'var(--g400)', fontSize: 10.5 }}>{new Date(d.encounterDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
                  {' -- '}<strong>{d.name}</strong> -- {d.eye}
                </div>
              ))}
              {diagnosisHistory.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior diagnoses on record.</div>}
            </div>
          </div>
        </div>

        <div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>

            {investigations.map((i) => {
              const type = matchInvestigationType(i.name);
              const hasResults = i.status === 'Available';
              return (
                <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 12.5 }}>
                    <span><strong>{i.name}</strong> -- {i.eye}</span>
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                      <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                      {hasResults && (
                        <a href={`/investigation/${i.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '2px 6px', fontSize: 10, textDecoration: 'none' }}>
                          <i className="ti ti-eye"></i>
                        </a>
                      )}
                      {i.status === 'Ordered' && isPending && (
                        <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => handleRemoveInvestigation(i.id)}>Remove</button>
                      )}
                    </div>
                  </div>
                  {hasResults && (
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
          </div>

          {isPending && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-clipboard-check" style={{ color: 'var(--amber)' }}></i> Fitness Decision</div>
              <textarea className="fi" rows={3} placeholder="Clinical notes / certificate remarks (required if marking not fit, optional if clearing)" value={decisionNotes} onChange={(e) => setDecisionNotes(e.target.value)} style={{ marginBottom: 8 }} />
              <div style={{ display: 'flex', gap: 8 }}>
                <button className="btn btn-primary" style={{ flex: 1 }} onClick={handleClear} disabled={saving}>
                  <i className="ti ti-circle-check"></i> {saving ? 'Saving...' : 'Clear for Surgery'}
                </button>
                <button className="btn" style={{ flex: 1, color: 'var(--red)' }} onClick={handleMarkNotFit} disabled={saving}>
                  <i className="ti ti-x"></i> Not Fit
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

