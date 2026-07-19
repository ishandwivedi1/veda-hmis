'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getBiometryDetail, setBiometrySurgicalDetails, saveBiometryDraft, verifyBiometryMeasurements,
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

function EyeColumn({ label, eyeKey, values, onChange, disabled, headColor, headBg }) {
  return (
    <div>
      <div style={{ padding: '8px 12px', fontSize: 12, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 5, background: headBg, color: headColor, borderRadius: '8px 8px 0 0' }}>
        <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {label}
      </div>
      <div style={{ border: '1px solid var(--g200)', borderTop: 'none', borderRadius: '0 0 8px 8px', padding: '10px 12px' }}>
        {MEAS_FIELDS.map((f) => (
          <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
            <span style={{ color: 'var(--g500)', flex: 1 }}>{f.label}</span>
            <div style={{ display: 'flex', alignItems: 'center', gap: 4 }}>
              <input
                type="text"
                value={values[f.key] || ''}
                onChange={(e) => onChange(eyeKey, f.key, e.target.value)}
                disabled={disabled}
                placeholder="--"
                style={{ width: 90, padding: '4px 7px', border: '1.5px solid var(--g200)', borderRadius: 8, fontSize: 12, textAlign: 'right' }}
              />
              <span style={{ fontSize: 10, color: 'var(--g400)' }}>{f.unit}</span>
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [surgeonName, setSurgeonName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [measurements, setMeasurements] = useState({ re: {}, le: {} });
  const [procedureName, setProcedureName] = useState('');
  const [surgicalEye, setSurgicalEye] = useState('');
  const [device, setDevice] = useState(DEVICES[0]);
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getBiometryDetail(recordId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setRecord(result.record);
      setSurgeonName(result.surgeonName);
      setMeasurements(result.record.measurements && Object.keys(result.record.measurements).length ? result.record.measurements : { re: {}, le: {} });
      setProcedureName(result.record.procedure_name || '');
      setSurgicalEye(result.record.surgical_eye || '');
      setDevice(result.record.verify_device || DEVICES[0]);
      setRemarks(result.record.verify_remarks || '');
    });
  }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.visits?.patients;
  const visitNumber = record.visits?.visit_number;
  const canEdit = record.status !== 'Calculated' && record.status !== 'Approved';
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';

  function setField(eyeKey, fieldKey, value) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: { ...prev[eyeKey], [fieldKey]: value } }));
  }

  async function handleSaveSurgicalDetails() {
    setError('');
    const result = await setBiometrySurgicalDetails(recordId, procedureName, surgicalEye);
    if (result.error) { setError(result.error); return; }
    setRecord((prev) => ({ ...prev, procedure_name: procedureName, surgical_eye: surgicalEye }));
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    await handleSaveSurgicalDetails();
    const result = await saveBiometryDraft(recordId, measurements);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleVerify() {
    setError(''); setOkMsg('');
    if (!procedureName.trim()) { setError('Enter the planned procedure before verifying.'); return; }
    setSaving(true);
    await handleSaveSurgicalDetails();
    const result = await verifyBiometryMeasurements(recordId, measurements, surgicalEye, device, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Measurements verified. IOL calculation is now available.');
    const refreshed = await getBiometryDetail(recordId);
    if (!refreshed.error) setRecord(refreshed.record);
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#1e1b4b,#4338ca)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Visit {visitNumber || '--'} -- Dr. {surgeonName}</div>
        </div>
        <span className="badge" style={{ background: isVerified ? 'rgba(34,197,94,.3)' : 'rgba(255,255,255,.15)', color: isVerified ? '#86efac' : '#fff', fontSize: 11 }}>
          {record.status}
        </span>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--indigo)' }}></i> Surgical Details</div>
        <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 10 }}>
          <div>
            <label className="flbl">Planned procedure</label>
            <input className="fi fi-sm" placeholder="e.g. Phacoemulsification + IOL" value={procedureName} onChange={(e) => setProcedureName(e.target.value)} disabled={!canEdit} onBlur={canEdit ? handleSaveSurgicalDetails : undefined} />
          </div>
          <div>
            <label className="flbl">Surgical eye</label>
            <select className="fi fi-sm" value={surgicalEye} onChange={(e) => setSurgicalEye(e.target.value)} disabled={!canEdit} onBlur={canEdit ? handleSaveSurgicalDetails : undefined}>
              <option value="">-- Select --</option>
              <option value="RE">Right Eye (RE)</option>
              <option value="LE">Left Eye (LE)</option>
              <option value="OU">Both Eyes (OU)</option>
            </select>
          </div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometric Measurements</div>
          <span className={`badge ${isVerified ? 'b-green' : 'b-gray'}`}>{isVerified ? 'Verified' : 'Not verified'}</span>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 0, border: '1px solid var(--g200)', borderRadius: 8, overflow: 'hidden' }}>
          <div style={{ borderRight: '1px solid var(--g200)' }}>
            <EyeColumn label="Right Eye (OD)" eyeKey="re" values={measurements.re || {}} onChange={setField} disabled={!canEdit} headColor="var(--blue)" headBg="var(--blue-lt)" />
          </div>
          <div>
            <EyeColumn label="Left Eye (OS)" eyeKey="le" values={measurements.le || {}} onChange={setField} disabled={!canEdit} headColor="var(--teal)" headBg="var(--teal-lt)" />
          </div>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginTop: 10 }}>
          <i className="ti ti-info-circle"></i> Confirm correct eye before verifying. Verification triggers IOL calculation eligibility.
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <AttachmentUploader entityType="biometry_record" entityId={recordId} title="Device Reports (IOLMaster/Lenstar printout, scanned reports)" />
      </div>

      {canEdit && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Verification confirms technical accuracy -- not the surgical plan. Only after verification can the surgeon calculate and approve.</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
            <div>
              <label className="flbl">Device used</label>
              <select className="fi fi-sm" value={device} onChange={(e) => setDevice(e.target.value)}>
                {DEVICES.map((d) => <option key={d}>{d}</option>)}
              </select>
            </div>
          </div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Technician remarks</label>
            <input className="fi fi-sm" placeholder="e.g. Good fixation, signal quality excellent, 3 readings averaged..." value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
              <i className="ti ti-shield-check"></i> Verify Measurements
            </button>
            <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-sm" onClick={() => router.push('/biometry')}>
              <i className="ti ti-arrow-left"></i> Back to Queue
            </button>
          </div>
        </div>
      )}

      {isVerified && (
        <div className="card" style={{ background: 'var(--green-lt)', borderColor: '#86efac' }}>
          <div style={{ fontSize: 13, color: 'var(--green)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 18 }}></i>
            Measurements verified{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. IOL Calculation is available next.
          </div>
          <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => router.push('/biometry')}>
            <i className="ti ti-arrow-left"></i> Back to Queue
          </button>
        </div>
      )}
    </div>
  );
}
