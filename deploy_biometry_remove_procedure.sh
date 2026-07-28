#!/bin/bash
set -e
echo "Applying: remove Planned Procedure from Biometry heading, keep only Eye"

cat > "app/(main)/biometry/[id]/measurements-tab.js" << 'PYEOF_BIO'
'use client';

import { useState, useEffect } from 'react';
import {
  saveBiometryDraft, verifyBiometryMeasurements,
} from '../actions';
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

// Each eye can hold multiple tagged readings -- e.g. Manual A-Scan AND
// an optical biometer, when both were used (fallback for dense
// cataracts, or cross-checking). Every reading keeps its own device tag.
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
              {!disabled && (
                <button className="btn" style={{ padding: '1px 7px', fontSize: 10 }} onClick={() => onRemoveSet(eyeKey, idx)}>Remove</button>
              )}
            </div>
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '3px 0', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
                  <input
                    type="text"
                    value={set[f.key] || ''}
                    onChange={(e) => onFieldChange(eyeKey, idx, f.key, e.target.value)}
                    disabled={disabled}
                    placeholder="--"
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

const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)' };

export default function MeasurementsTab({ record, recordId, onSaved }) {
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [surgicalEye, setSurgicalEye] = useState('');
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    const m = record.measurements || {};
    setMeasurements({
      re: Array.isArray(m.re) ? m.re : (m.re && Object.keys(m.re).length ? [{ ...m.re, device: record.verify_device || 'Unspecified' }] : []),
      le: Array.isArray(m.le) ? m.le : (m.le && Object.keys(m.le).length ? [{ ...m.le, device: record.verify_device || 'Unspecified' }] : []),
    });
    setSurgicalEye(record.surgical_eye || '');
    setRemarks(record.verify_remarks || '');
  }, [record]);

  const canEdit = record.status !== 'Calculated' && record.status !== 'Approved';
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';

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
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleVerify() {
    setError(''); setOkMsg('');
    if (!surgicalEye) { setError('Eye is not set for this record.'); return; }
    setSaving(true);
    const result = await verifyBiometryMeasurements(recordId, measurements, surgicalEye, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Measurements verified. IOL Calculation tab is now available.');
    if (onSaved) onSaved();
  }

  const surgicalEyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  const surgicalEyeHasComplete = surgicalEyeKey ? (measurements[surgicalEyeKey] || []).some(isComplete) : false;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
        <div style={{ fontSize: 12 }}>
          <span style={{ color: 'var(--g500)' }}>Eye: </span>
          <strong>{EYE_LABEL[surgicalEye] || surgicalEye || '--'}</strong>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isVerified ? 'b-green' : 'b-gray'}`}>{isVerified ? 'Verified' : 'Not verified'}</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Add a reading per device used -- e.g. Manual A-Scan and an optical biometer both, if both were taken for this patient. Each reading keeps its own device tag.
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

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Reports (IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            Verification confirms technical accuracy -- not the surgical plan. Requires at least one complete reading (AXL, K1, K2, ACD) for the surgical eye.
            {surgicalEyeKey && !surgicalEyeHasComplete && <span style={{ color: 'var(--amber)', fontWeight: 600 }}> No complete reading yet for {surgicalEye}.</span>}
          </div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Optical biometry unreliable due to dense cataract, A-Scan used as backup..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
              <i className="ti ti-shield-check"></i> Verify Measurements
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
          </div>
        </div>
      )}

      {isVerified && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measurements verified{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Continue to the IOL Calculation tab.
          </div>
        </div>
      )}
    </div>
  );
}
PYEOF_BIO

echo "File written. Run: npm run build"
