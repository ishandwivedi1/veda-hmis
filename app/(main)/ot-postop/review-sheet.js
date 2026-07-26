'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPostOpReviewData } from './actions';
import { addDiagnosis, removeDiagnosis, updateDiagnosisNotes } from '@/app/(main)/consultation/actions';
import { getDiagnosesMaster } from '@/app/(main)/master-data/actions';
import OptometryTab from '@/app/(main)/consultation/[id]/optometry-tab';
import ExaminationTab from '@/app/(main)/consultation/[id]/examination-tab';

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--purple)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

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

// ── DIAGNOSIS TAB (trimmed down from Consultation's Diagnosis & Plan --
//    just the Diagnosis section, none of the prescriptions/investigations/
//    referrals/workflow machinery that belongs to a fresh OPD consult). ──
function DiagnosisTab({ diagnoses, encounterId, onSaved }) {
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');
  const [error, setError] = useState('');

  useEffect(() => { getDiagnosesMaster().then(setDiagnosisOptions); }, []);

  async function handleAdd() {
    setError('');
    if (!dxName.trim()) return;
    const result = await addDiagnosis(encounterId, { name: dxName.trim(), category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    onSaved();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
      {error && <div className="msg-err">{error}</div>}
      {diagnoses.map((d, idx) => (
        <DiagnosisRow key={d.id} d={d} index={idx} encounterId={encounterId} onRemove={async () => { await removeDiagnosis(d.id, encounterId); onSaved(); }} />
      ))}
      {diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
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
        <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
          <option value="OD">OD</option>
          <option value="OS">OS</option>
          <option value="OU">OU</option>
        </select>
        <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAdd}>Add</button>
      </div>
    </div>
  );
}

export default function ReviewSheet({ followup, visitId, encounterId, onBack }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [activeTab, setActiveTab] = useState('optometry');

  const refresh = useCallback(async () => {
    const result = await getPostOpReviewData(encounterId, visitId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [encounterId, visitId]);

  useEffect(() => { refresh(); }, [refresh]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{followup.visit_label}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>
            {new Date(followup.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })} -- Post-op Review
          </div>
        </div>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
          <i className="ti ti-arrow-left"></i> Back to Post-op
        </button>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 460 }}>
        <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
        <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
        <TabButton active={activeTab === 'diagnosis'} onClick={() => setActiveTab('diagnosis')} icon="ti-stethoscope" label="Diagnosis" />
      </div>

      {activeTab === 'optometry' && (
        <OptometryTab findings={data.findings} iopReadings={data.iopReadings} visitId={visitId} encounterId={encounterId} onSaved={refresh} />
      )}
      {activeTab === 'exam' && (
        <ExaminationTab examination={data.examination} encounterId={encounterId} onSaved={refresh} />
      )}
      {activeTab === 'diagnosis' && (
        <DiagnosisTab diagnoses={data.diagnoses} encounterId={encounterId} onSaved={refresh} />
      )}
    </div>
  );
}
