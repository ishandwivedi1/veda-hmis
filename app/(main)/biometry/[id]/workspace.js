'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getBiometryDetail, saveBiometryDraft, markBiometryMeasured,
  addIolRecommendation, removeIolRecommendation,
} from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
import AttachmentUploader from '@/app/components/AttachmentUploader';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];
const DEVICES = ['ZEISS IOLMaster 700', 'Haag-Streit Lenstar', 'NIDEK AL-Scan', 'Manual A-Scan'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

function emptySet(device) {
  return { device, axl: '', k1: '', k2: '', acd: '', lt: '', wtw: '' };
}
function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

function EyeSets({ label, eyeKey, sets, onFieldChange, onRemoveSet, onAddSet, disabled, headColor, headBg }) {
  const [newDevice, setNewDevice] = useState(DEVICES[0]);
  return (
    <div>
      <div style={{ padding: '8px 12px', fontSize: 12, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, background: headBg, color: headColor, borderRadius: '8px 8px 0 0' }}>
        <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {label}
      </div>
      <div style={{ border: '1px solid var(--g200)', borderTop: 'none', borderRadius: '0 0 8px 8px', padding: '10px 12px' }}>
        {sets.length === 0 && <div style={{ fontSize: 11, color: 'var(--g400)', padding: '4px 0' }}>No readings yet.</div>}
        {sets.map((set, idx) => (
          <div key={idx} style={{ marginBottom: 10, paddingBottom: 10, borderBottom: idx < sets.length - 1 || !disabled ? '1px dashed var(--g200)' : 'none' }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
              <span className={`badge ${isComplete(set) ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>
                <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
              </span>
              {!disabled && <button className="btn" style={{ padding: '1px 7px', fontSize: 10 }} onClick={() => onRemoveSet(eyeKey, idx)}>Remove</button>}
            </div>
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <input
                    type="text" value={set[f.key] || ''} onChange={(e) => onFieldChange(eyeKey, idx, f.key, e.target.value)}
                    disabled={disabled} placeholder="--"
                    style={{ width: 90, padding: '4px 7px', border: '1.5px solid var(--g200)', borderRadius: 8, fontSize: 12, textAlign: 'right' }}
                  />
                  <span style={{ fontSize: 10, color: 'var(--g400)' }}>{f.unit}</span>
                </div>
              </div>
            ))}
          </div>
        ))}
        {!disabled && (
          <div style={{ display: 'flex', gap: 6 }}>
            <select className="fi fi-sm" style={{ flex: 1 }} value={newDevice} onChange={(e) => setNewDevice(e.target.value)}>
              {DEVICES.map((d) => <option key={d}>{d}</option>)}
            </select>
            <button className="btn btn-sm" onClick={() => onAddSet(eyeKey, newDevice)}><i className="ti ti-plus"></i> Add reading</button>
          </div>
        )}
      </div>
    </div>
  );
}

function RecommendationsSection({ recordId, recommendations, catalog, disabled, onSaved }) {
  const [catalogId, setCatalogId] = useState('');
  const [rePower, setRePower] = useState('');
  const [lePower, setLePower] = useState('');
  const [error, setError] = useState('');

  async function handleAdd() {
    setError('');
    const result = await addIolRecommendation(recordId, catalogId, rePower, lePower);
    if (result.error) { setError(result.error); return; }
    setCatalogId(''); setRePower(''); setLePower('');
    onSaved();
  }

  return (
    <div className="card" style={{ marginBottom: 12 }}>
      <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> IOL Recommendations (from device printout)</div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
        For each IOL brand/model the device evaluated, enter the power it recommends per eye -- transcribed straight from the printout, not calculated here.
      </div>
      {error && <div className="msg-err" style={{ marginBottom: 8 }}>{error}</div>}

      {recommendations.length > 0 && (
        <table className="tbl" style={{ marginBottom: 10 }}>
          <thead><tr><th>Brand / Model</th><th>RE Power</th><th>LE Power</th><th></th></tr></thead>
          <tbody>
            {recommendations.map((r) => (
              <tr key={r.id}>
                <td>{r.master_iol_catalog?.brand} {r.master_iol_catalog?.model}</td>
                <td>{r.re_power ?? '--'}</td>
                <td>{r.le_power ?? '--'}</td>
                <td>
                  {!disabled && (
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeIolRecommendation(r.id); onSaved(); }}>
                      <i className="ti ti-trash"></i>
                    </button>
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {!disabled && (
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr auto', gap: 8 }}>
          <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
            <option value="">Select brand/model...</option>
            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
          </select>
          <input className="fi fi-sm" placeholder="RE power" value={rePower} onChange={(e) => setRePower(e.target.value)} />
          <input className="fi fi-sm" placeholder="LE power" value={lePower} onChange={(e) => setLePower(e.target.value)} />
          <button className="btn btn-sm btn-primary" onClick={handleAdd}><i className="ti ti-plus"></i></button>
        </div>
      )}
    </div>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [recommendations, setRecommendations] = useState([]);
  const [catalog, setCatalog] = useState([]);
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [remarks, setRemarks] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [isDoctor, setIsDoctor] = useState(false);
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  async function refresh() {
    const result = await getBiometryDetail(recordId);
    if (result.error) { setLoadError(result.error); return; }
    setRecord(result.record);
    setRecommendations(result.recommendations);
    setIsDoctor(!!result.isDoctor);
    const m = result.record.measurements || {};
    setMeasurements({
      re: Array.isArray(m.re) ? m.re : (m.re && Object.keys(m.re).length ? [{ ...m.re, device: result.record.verify_device || 'Unspecified' }] : []),
      le: Array.isArray(m.le) ? m.le : (m.le && Object.keys(m.le).length ? [{ ...m.le, device: result.record.verify_device || 'Unspecified' }] : []),
    });
    setRemarks(result.record.verify_remarks || '');
  }

  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.patients;
  const isMeasured = record.status === 'Measured';
  // Once Measured, this is a finalized report -- locked by default for
  // everyone. A Doctor can unlock it to make a correction; anyone else
  // only ever sees it read-only, no matter how they arrived here.
  const canEdit = !isMeasured || (isDoctor && unlocked);

  function setFieldInSet(eyeKey, idx, fieldKey, value) {
    setMeasurements((prev) => {
      const list = [...(prev[eyeKey] || [])];
      list[idx] = { ...list[idx], [fieldKey]: value };
      return { ...prev, [eyeKey]: list };
    });
  }
  function addSet(eyeKey, device) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: [...(prev[eyeKey] || []), emptySet(device)] }));
  }
  function removeSet(eyeKey, idx) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: (prev[eyeKey] || []).filter((_, i) => i !== idx) }));
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveBiometryDraft(recordId, measurements);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved.');
  }

  async function handleMarkMeasured() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await markBiometryMeasured(recordId, measurements, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Marked as measured.');
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#3730a3)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Biometry (both eyes)</div>
        </div>
        <span className="badge" style={{ background: isMeasured ? 'rgba(34,197,94,.35)' : 'rgba(255,255,255,.15)', color: '#fff', fontSize: 11 }}>{record.status}</span>
      </div>

      {record.doctor_instructions && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12 }}>
          <i className="ti ti-notes"></i> <strong>Doctor's instructions:</strong> {record.doctor_instructions}
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      {isMeasured && !unlocked && (
        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-lock"></i>
          <span style={{ flex: 1 }}>This report is finalized and locked for viewing.</span>
          {isDoctor && (
            <button className="btn btn-sm" onClick={() => setUnlocked(true)}>
              <i className="ti ti-lock-open"></i> Edit (Doctor)
            </button>
          )}
        </div>
      )}
      {isMeasured && unlocked && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-edit"></i>
          <span style={{ flex: 1 }}>Editing a finalized report. Changes are saved immediately.</span>
          <button className="btn btn-sm" onClick={() => setUnlocked(false)}>
            <i className="ti ti-lock"></i> Lock again
          </button>
        </div>
      )}

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isMeasured ? 'b-green' : 'b-gray'}`}>{isMeasured ? 'Measured' : 'Not measured'}</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Biometry is always done for both eyes. Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken.
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
          <div style={{ borderRight: '1px solid var(--g200)' }}>
            <EyeSets label="Right Eye (OD)" eyeKey="re" sets={measurements.re || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--blue)" headBg="var(--blue-lt)" />
          </div>
          <div>
            <EyeSets label="Left Eye (OS)" eyeKey="le" sets={measurements.le || []} onFieldChange={setFieldInSet} onRemoveSet={removeSet} onAddSet={addSet} disabled={!canEdit} headColor="var(--teal)" headBg="var(--teal-lt)" />
          </div>
        </div>
      </div>

      <RecommendationsSection recordId={recordId} recommendations={recommendations} catalog={catalog} disabled={!canEdit} onSaved={refresh} />

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Report (required -- IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {!isMeasured && canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-check" style={{ color: 'var(--green)' }}></i> Mark as Measured</div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleMarkMeasured} disabled={saving}>
              <i className="ti ti-check"></i> Mark as Measured
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
          </div>
        </div>
      )}

      {isMeasured && canEdit && (
        <div className="card">
          <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleSaveDraft} disabled={saving}>
            <i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save Correction'}
          </button>
        </div>
      )}

      {isMeasured && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measured{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Ready for Surgeon IOL Approval when a surgical case needs it.
          </div>
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        <button className="btn" onClick={() => router.push('/biometry')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}
