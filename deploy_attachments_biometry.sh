#!/usr/bin/env bash
# Reusable clinical report/document attachment system -- private
# Supabase Storage bucket + metadata table (already created directly
# in Supabase, with RLS). This script adds the code side: shared
# server actions, a shared upload/list/delete component, and wires it
# into the Biometry Workspace. Investigation (M21) can reuse the same
# lib/attachments.js and AttachmentUploader component later -- just
# pass entityType="investigation_order".
#
# Usage: run from the ROOT of your veda-hmis repo checkout:
#   bash deploy_attachments_biometry.sh
set -euo pipefail

if [ ! -d "app" ]; then
  echo "ERROR: 'app' folder not found. Run this from the root of the veda-hmis repo checkout."
  exit 1
fi

mkdir -p "lib" "app/components" "app/(main)/biometry/[id]"

cat > "lib/attachments.js" << 'FILEEOF'
'use server';

import { createClient } from '@/lib/supabase-server';

const MAX_SIZE = 10 * 1024 * 1024;
const ALLOWED_TYPES = ['application/pdf', 'image/jpeg', 'image/png', 'image/jpg'];

function sanitizeFileName(name) {
  return name.replace(/[^a-zA-Z0-9.\-_]/g, '_');
}

// entityType/entityId is a generic pointer (e.g. 'biometry_record' +
// biometry_records.id) so this same action serves every module that
// needs report/document uploads -- Investigation (M21) next.
export async function uploadAttachment(formData) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const file = formData.get('file');
  const entityType = formData.get('entityType');
  const entityId = formData.get('entityId');

  if (!file || typeof file === 'string') return { error: 'No file selected.' };
  if (!entityType || !entityId) return { error: 'Missing entity reference.' };
  if (file.size > MAX_SIZE) return { error: 'File exceeds the 10MB limit.' };
  if (!ALLOWED_TYPES.includes(file.type)) return { error: 'Only PDF, JPG, and PNG files are allowed.' };

  const timestamp = Date.now();
  const safeName = sanitizeFileName(file.name);
  const storagePath = `${entityType}/${entityId}/${timestamp}_${safeName}`;

  const { error: uploadError } = await supabase.storage.from('clinical-attachments').upload(storagePath, file, { contentType: file.type });
  if (uploadError) return { error: uploadError.message };

  const { error: dbError } = await supabase.from('clinical_attachments').insert({
    entity_type: entityType,
    entity_id: entityId,
    file_name: file.name,
    storage_path: storagePath,
    file_size: file.size,
    mime_type: file.type,
    uploaded_by: userData?.user?.id || null,
  });

  if (dbError) {
    // Don't leave an orphaned file with no metadata row if the DB
    // insert failed after the upload succeeded.
    await supabase.storage.from('clinical-attachments').remove([storagePath]);
    return { error: dbError.message };
  }

  return { success: true };
}

// Bucket is private -- each file gets a short-lived signed URL at fetch
// time so the browser can view/download without the bucket being public.
export async function getAttachments(entityType, entityId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('clinical_attachments')
    .select('*, profiles(full_name)')
    .eq('entity_type', entityType)
    .eq('entity_id', entityId)
    .order('uploaded_at', { ascending: false });

  if (error) return [];

  const withUrls = await Promise.all((data || []).map(async (a) => {
    const { data: signed } = await supabase.storage.from('clinical-attachments').createSignedUrl(a.storage_path, 3600);
    return { ...a, url: signed?.signedUrl || null };
  }));

  return withUrls;
}

export async function deleteAttachment(id, storagePath) {
  const supabase = await createClient();
  await supabase.storage.from('clinical-attachments').remove([storagePath]);
  const { error } = await supabase.from('clinical_attachments').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}
FILEEOF

cat > "app/components/AttachmentUploader.js" << 'FILEEOF'
'use client';

import { useState, useEffect, useRef } from 'react';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';

function formatSize(bytes) {
  if (!bytes) return '--';
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

export default function AttachmentUploader({ entityType, entityId, title = 'Reports & Documents' }) {
  const [files, setFiles] = useState([]);
  const [uploading, setUploading] = useState(false);
  const [error, setError] = useState('');
  const inputRef = useRef(null);

  async function refresh() {
    const result = await getAttachments(entityType, entityId);
    setFiles(result);
  }

  useEffect(() => { refresh(); }, [entityType, entityId]);

  async function handleFileSelect(e) {
    const file = e.target.files?.[0];
    if (!file) return;
    setError('');
    setUploading(true);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', entityType);
    formData.append('entityId', entityId);
    const result = await uploadAttachment(formData);
    setUploading(false);
    if (inputRef.current) inputRef.current.value = '';
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleDelete(a) {
    if (!window.confirm(`Delete "${a.file_name}"? This cannot be undone.`)) return;
    await deleteAttachment(a.id, a.storage_path);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10 }}>
        <div className="card-title"><i className="ti ti-paperclip" style={{ color: 'var(--indigo)' }}></i> {title}</div>
        <label className="btn btn-sm" style={{ cursor: uploading ? 'default' : 'pointer', opacity: uploading ? 0.6 : 1, marginBottom: 0 }}>
          <i className="ti ti-upload"></i> {uploading ? 'Uploading...' : 'Upload'}
          <input ref={inputRef} type="file" accept="application/pdf,image/jpeg,image/png,image/jpg" onChange={handleFileSelect} disabled={uploading} style={{ display: 'none' }} />
        </label>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {files.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No reports uploaded yet.</div>}

      {files.map((a) => (
        <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: '1px solid var(--g100)' }}>
          <i className={`ti ${a.mime_type === 'application/pdf' ? 'ti-file-type-pdf' : 'ti-photo'}`} style={{ color: 'var(--g400)', fontSize: 16 }}></i>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.file_name}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>
              {formatSize(a.file_size)} -- {a.profiles?.full_name || 'Staff'} -- {new Date(a.uploaded_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </div>
          </div>
          {a.url && <a href={a.url} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '3px 9px', fontSize: 11 }}>View</a>}
          <button className="btn" style={{ padding: '3px 9px', fontSize: 11 }} onClick={() => handleDelete(a)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
        </div>
      ))}
    </div>
  );
}
FILEEOF

cat > "app/(main)/biometry/[id]/workspace.js" << 'FILEEOF'
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
FILEEOF

echo "Files written:"
wc -l "lib/attachments.js" "app/components/AttachmentUploader.js" "app/(main)/biometry/[id]/workspace.js"

echo ""
echo "Running build..."
npm run build

echo ""
echo "==================================================================="
echo "Build passed. Files written but NOT committed. Review with:"
echo "  git diff --stat"
echo "Then commit:"
echo "  git add \"lib/attachments.js\" \"app/components/AttachmentUploader.js\" \"app/(main)/biometry/[id]/workspace.js\""
echo "  git commit -m \"Add reusable clinical attachment system, wire into Biometry Workspace\""
echo "  git push"
echo "==================================================================="
