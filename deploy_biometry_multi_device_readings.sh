#!/usr/bin/env bash
# Biometry: supports multiple tagged readings per eye (e.g. Manual
# A-Scan AND an optical biometer/IOLMaster, when both are used for the
# same patient -- common when optical biometry fails on a dense
# cataract and A-Scan is used as backup, or for cross-checking).
#
# Data model change: measurements per eye go from a single flat object
# to an array of tagged readings, each with its own device. The 2
# existing records with real data have already been migrated to the
# new shape directly in Supabase -- nothing else to run there.
#
# Usage: run from the ROOT of your veda-hmis repo checkout:
#   bash deploy_biometry_multi_device_readings.sh
set -euo pipefail

if [ ! -d "app" ]; then
  echo "ERROR: 'app' folder not found. Run this from the root of the veda-hmis repo checkout."
  exit 1
fi

DIR="app/(main)/biometry"
IDDIR="app/(main)/biometry/[id]"
HISTDIR="app/(main)/biometry/history"
mkdir -p "$DIR" "$IDDIR" "$HISTDIR"

cat > "$DIR/actions.js" << 'FILEEOF'
'use server';

import { createClient } from '@/lib/supabase-server';

const MEAS_FIELDS = ['axl', 'k1', 'k2', 'acd', 'lt', 'wtw'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE: real queue_entries with status = 'Awaiting Biometry' (set by
// Consultation's "Send for Biometry"), matched against any existing
// biometry_records for that visit so a patient shows the right stage
// even after a record's been started but not yet approved. ──
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: entries, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .eq('status', 'Awaiting Biometry')
    .order('issued_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 } };

  const visitIds = (entries || []).map((e) => e.visits?.id).filter(Boolean);

  let recordsByVisit = {};
  if (visitIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('*')
      .in('visit_id', visitIds)
      .in('status', ['Awaiting Biometry', 'Measured', 'Calculated', 'Approved']);
    (records || []).forEach((r) => { recordsByVisit[r.visit_id] = r; });
  }

  const rows = (entries || []).map((e) => {
    const record = recordsByVisit[e.visits?.id];
    return {
      queueEntryId: e.id,
      visitId: e.visits?.id,
      encounterId: null,
      doctorId: e.visits?.doctor_id,
      patient: e.visits?.patients,
      recordId: record?.id || null,
      status: record?.status || 'Awaiting Biometry',
      procedureName: record?.procedure_name || null,
      surgicalEye: record?.surgical_eye || null,
    };
  });

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: approvedToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Approved')
    .gte('approved_at', todayStart.toISOString());

  const stats = {
    awaiting: rows.filter((r) => r.status === 'Awaiting Biometry').length,
    measured: rows.filter((r) => r.status === 'Measured').length,
    calculated: rows.filter((r) => r.status === 'Calculated').length,
    approvedToday: (approvedToday || []).length,
  };

  return { rows, stats };
}

// Finds an in-flight record for this visit, or creates a fresh one --
// same lazy-create pattern as the encounter/optometry assessment.
export async function getOrCreateBiometryRecord(visitId, encounterId) {
  const supabase = await createClient();

  // Reuse ANY existing non-cancelled record for this visit -- including
  // Approved ones. Previously this only matched in-flight statuses, so
  // reopening an already-approved patient (e.g. from the Queue, since
  // queue_entries.status doesn't change on approval) silently created a
  // second, blank record for the same visit.
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)), master_iol_catalog(brand, model, manufacturer)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  let surgeonName = '--';
  if (data.surgeon_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.surgeon_id).maybeSingle();
    surgeonName = doc?.full_name || '--';
  }

  return { record: data, surgeonName };
}

// Sets/updates the procedure + surgical eye for this record -- captured
// here rather than assumed from elsewhere, since Biometry may be the
// first place this gets confirmed with the technician.
export async function setBiometrySurgicalDetails(id, procedureName, surgicalEye) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ procedure_name: procedureName, surgical_eye: surgicalEye, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// BR-BIO-002: only verified measurements may be used for calculation.
// AUTO-BIO-001: verification is what triggers calculation eligibility --
// there's no separate persisted "Measured" state in practice, mirroring
// the source workflow (jumps straight to Calculated).
export async function verifyBiometryMeasurements(id, measurements, surgicalEye, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!surgicalEye) return { error: 'Set the surgical eye before verifying.' };

  const eyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  if (!eyeKey) return { error: 'Surgical eye must be RE or LE to verify (OU not supported for a single IOL calculation).' };

  // Each eye can now hold multiple tagged readings (e.g. Manual A-Scan
  // AND an optical biometer, when both were used) -- verification just
  // needs at least ONE complete reading for the surgical eye, not every
  // reading filled in.
  const eyeSets = Array.isArray(measurements[eyeKey]) ? measurements[eyeKey] : [];
  const completeSet = eyeSets.find((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim()));
  if (!completeSet) {
    return { error: `At least one complete reading (AXL, K1, K2, ACD) is required for the surgical eye (${surgicalEye}) before verification.` };
  }

  // Summarize which device(s) actually produced complete readings for
  // the surgical eye, for a readable record -- e.g. "Manual A-Scan,
  // ZEISS IOLMaster 700" if both were used.
  const devicesUsed = [...new Set(
    eyeSets.filter((set) => REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim())).map((set) => set.device)
  )];

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Calculated',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

// ── IOL CALCULATION ──
// Formula results are NOT computed by this system -- real IOL power
// formulas (Barrett Universal II, SRK/T, Haigis, etc.) are complex and
// in some cases proprietary. These numbers come from the biometry
// device's own built-in formula software (the same printout captured
// in Device Reports); staff transcribes each formula's result here so
// the surgeon has a structured side-by-side comparison to choose from.
export async function saveFormulaResults(id, targetRefraction, formulaResults, selectedFormula) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      target_refraction: targetRefraction,
      formula_results: formulaResults,
      selected_formula: selectedFormula,
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGEON APPROVAL ──
// BR-BIO-003: only surgeon sign-off finalizes a plan (soft UX check
// only -- see note in the Approval tab; not DB-enforced by role).
// BR-BIO-005: approval supersedes but never deletes a prior version --
// every approve call adds a new biometry_iol_versions row and marks
// any previous Approved version for this record as Superseded.
export async function approveIolPlan(id, plan) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!plan.finalPower || !plan.finalCategory) return { error: 'Final IOL power and category are required.' };

  const { data: priorVersions } = await supabase
    .from('biometry_iol_versions')
    .select('id, version_no')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });

  const nextVersionNo = (priorVersions?.[0]?.version_no || 0) + 1;

  if (priorVersions && priorVersions.length > 0) {
    await supabase.from('biometry_iol_versions').update({ status: 'Superseded' }).eq('biometry_record_id', id).eq('status', 'Approved');
  }

  const { error: versionError } = await supabase.from('biometry_iol_versions').insert({
    biometry_record_id: id,
    version_no: nextVersionNo,
    power: plan.finalPower,
    formula: plan.finalFormula,
    status: 'Approved',
    created_by: userData?.user?.id || null,
  });
  if (versionError) return { error: versionError.message };

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Approved',
      final_iol_power: plan.finalPower,
      final_iol_category: plan.finalCategory,
      final_iol_catalog_id: plan.iolCatalogId || null,
      target_refraction: plan.finalTarget,
      surgeon_notes: plan.surgeonNotes,
      approved_by: userData?.user?.id || null,
      approved_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true, versionNo: nextVersionNo };
}

export async function getIolVersionHistory(id) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_iol_versions')
    .select('*, profiles(full_name)')
    .eq('biometry_record_id', id)
    .order('version_no', { ascending: false });
  if (error) return [];
  return data || [];
}

// ── HISTORY (Section 17.15) -- cross-patient, all statuses past
// Awaiting Biometry. BR-BIO-005: nothing here is ever overwritten;
// re-approvals just add rows to biometry_iol_versions. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, visits(visit_number, patients(id, first_name, last_name, uhid))')
    .in('status', ['Calculated', 'Approved'])
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.visits?.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.visits?.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}
FILEEOF

cat > "$IDDIR/measurements-tab.js" << 'FILEEOF'
'use client';

import { useState, useEffect } from 'react';
import {
  setBiometrySurgicalDetails, saveBiometryDraft, verifyBiometryMeasurements,
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

export default function MeasurementsTab({ record, recordId, onSaved }) {
  const [measurements, setMeasurements] = useState({ re: [], le: [] });
  const [procedureName, setProcedureName] = useState('');
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
    setProcedureName(record.procedure_name || '');
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

  async function handleSaveSurgicalDetails() {
    setError('');
    await setBiometrySurgicalDetails(recordId, procedureName, surgicalEye);
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
            Measurements verified{record.verified_at ? ` on ${new Date(record.verified_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. Continue to the IOL Calculation tab.
          </div>
        </div>
      )}
    </div>
  );
}
FILEEOF

cat > "$IDDIR/calculation-tab.js" << 'FILEEOF'
'use client';

import { useState, useEffect } from 'react';
import { saveFormulaResults } from '../actions';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const TARGETS = ['Plano (Emmetropia)', '-0.50 D (Mild myopia)', 'Monovision'];

export default function CalculationTab({ record, recordId, onSaved }) {
  const [targetRefraction, setTargetRefraction] = useState('Plano (Emmetropia)');
  const [rows, setRows] = useState([]);
  const [selectedIdx, setSelectedIdx] = useState(null);
  const [newFormula, setNewFormula] = useState(FORMULA_NAMES[0]);
  const [newPower, setNewPower] = useState('');
  const [newRefraction, setNewRefraction] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setTargetRefraction(record.target_refraction || 'Plano (Emmetropia)');
    setRows(Array.isArray(record.formula_results) ? record.formula_results : []);
    if (record.selected_formula) {
      const idx = (record.formula_results || []).findIndex((r) => r.name === record.selected_formula);
      setSelectedIdx(idx >= 0 ? idx : null);
    }
  }, [record]);

  const eyeKey = record.surgical_eye === 'RE' ? 're' : record.surgical_eye === 'LE' ? 'le' : null;
  const surgicalEyeSets = eyeKey && Array.isArray(record.measurements?.[eyeKey]) ? record.measurements[eyeKey] : [];

  const notVerified = record.status !== 'Calculated' && record.status !== 'Approved';
  const readOnlyRows = record.status === 'Approved';

  function addRow() {
    if (!newPower.trim()) { setError('Enter the IOL power for this formula.'); return; }
    setError('');
    setRows((prev) => [...prev, { name: newFormula, power: newPower, refraction: newRefraction || '--' }]);
    setNewPower(''); setNewRefraction('');
  }

  function removeRow(idx) {
    setRows((prev) => prev.filter((_, i) => i !== idx));
    if (selectedIdx === idx) setSelectedIdx(null);
  }

  async function handleSave() {
    setError(''); setOkMsg('');
    if (rows.length === 0) { setError('Add at least one formula result before saving.'); return; }
    setSaving(true);
    const selectedFormula = selectedIdx !== null ? rows[selectedIdx]?.name : null;
    const result = await saveFormulaResults(recordId, targetRefraction, rows, selectedFormula);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Calculation saved. Continue to Surgeon Approval.');
    if (onSaved) onSaved();
  }

  if (notVerified) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Measurements must be verified first (see the Measurements tab) before IOL Calculation is available.
      </div>
    );
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry Summary ({record.surgical_eye || '--'})</div>
            {surgicalEyeSets.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No readings recorded.</div>}
            {surgicalEyeSets.map((set, idx) => (
              <div key={idx} style={{ marginBottom: idx < surgicalEyeSets.length - 1 ? 10 : 0, paddingBottom: idx < surgicalEyeSets.length - 1 ? 10 : 0, borderBottom: idx < surgicalEyeSets.length - 1 ? '1px dashed var(--g200)' : 'none' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--indigo)', marginBottom: 4 }}>
                  <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
                </div>
                {MEAS_FIELDS.map((f) => (
                  <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', fontSize: 12 }}>
                    <span style={{ color: 'var(--g500)' }}>{f.label}</span>
                    <span style={{ fontWeight: 700, fontFamily: 'monospace' }}>{set[f.key] || '--'} {f.unit}</span>
                  </div>
                ))}
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-target" style={{ color: 'var(--amber)' }}></i> Target Refraction</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5 }}>
              {TARGETS.map((t) => (
                <span
                  key={t}
                  className={`badge ${targetRefraction === t ? 'b-green' : 'b-gray'}`}
                  style={{ cursor: readOnlyRows ? 'default' : 'pointer' }}
                  onClick={() => !readOnlyRows && setTargetRefraction(t)}
                >
                  {t}
                </span>
              ))}
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>Selected: <strong>{targetRefraction}</strong></div>
          </div>
        </div>

        <div>
          <div className="card">
            <div className="card-head" style={{ marginBottom: 8 }}>
              <div className="card-title"><i className="ti ti-table" style={{ color: 'var(--blue)' }}></i> Formula Comparison</div>
              <span className="badge b-indigo" style={{ fontSize: 10 }}>From device printout</span>
            </div>
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
              <i className="ti ti-info-circle"></i> This system does not compute IOL power -- transcribe each formula's result from the biometry device's own printout (see Device Reports in the Measurements tab). The surgeon makes the clinical decision on which formula to use.
            </div>

            <table className="tbl" style={{ marginBottom: 10 }}>
              <thead><tr><th></th><th>Formula</th><th>IOL Power</th><th>Predicted Refraction</th><th></th></tr></thead>
              <tbody>
                {rows.map((r, idx) => (
                  <tr key={idx} style={{ background: selectedIdx === idx ? 'var(--green-lt)' : 'transparent' }}>
                    <td>
                      <input type="radio" checked={selectedIdx === idx} onChange={() => setSelectedIdx(idx)} disabled={readOnlyRows} style={{ accentColor: 'var(--green)' }} />
                    </td>
                    <td style={{ fontWeight: 600 }}>{r.name}</td>
                    <td style={{ fontFamily: 'monospace', fontWeight: 700, color: 'var(--indigo)' }}>{r.power} D</td>
                    <td>{r.refraction}</td>
                    <td>
                      {!readOnlyRows && <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => removeRow(idx)}>Remove</button>}
                    </td>
                  </tr>
                ))}
                {rows.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No formula results entered yet.</td></tr>
                )}
              </tbody>
            </table>

            {!readOnlyRows && (
              <div style={{ display: 'flex', gap: 6, alignItems: 'flex-end', flexWrap: 'wrap', borderTop: '1px solid var(--g100)', paddingTop: 10 }}>
                <div>
                  <label className="flbl">Formula</label>
                  <select className="fi fi-sm" value={newFormula} onChange={(e) => setNewFormula(e.target.value)}>
                    {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                  </select>
                </div>
                <div>
                  <label className="flbl">IOL Power (D)</label>
                  <input className="fi fi-sm" style={{ width: 90 }} placeholder="+21.5" value={newPower} onChange={(e) => setNewPower(e.target.value)} />
                </div>
                <div>
                  <label className="flbl">Predicted Refraction</label>
                  <input className="fi fi-sm" style={{ width: 110 }} placeholder="Plano" value={newRefraction} onChange={(e) => setNewRefraction(e.target.value)} />
                </div>
                <button className="btn btn-sm btn-primary" onClick={addRow}><i className="ti ti-plus"></i> Add row</button>
              </div>
            )}

            {selectedIdx !== null && (
              <div style={{ marginTop: 10, padding: '8px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                <i className="ti ti-circle-check"></i> {rows[selectedIdx]?.name} selected as the surgeon's preferred formula. Proceed to Surgeon Approval.
              </div>
            )}

            {!readOnlyRows && (
              <button className="btn btn-primary" style={{ marginTop: 10 }} onClick={handleSave} disabled={saving}>
                {saving ? 'Saving...' : 'Save Calculation'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
FILEEOF

cat > "$HISTDIR/page.js" << 'FILEEOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryHistory } from './actions';

export default function BiometryHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patients, setPatients] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const router = useRouter();

  const refresh = useCallback(async (filter) => {
    const result = await getBiometryHistory(filter || undefined);
    setRows(result.rows);
    setPatients(result.patients);
  }, []);

  useEffect(() => { refresh(patientFilter); }, [patientFilter, refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Biometry History</div>
          <select className="fi" style={{ width: 'auto', padding: '6px 8px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
            <option value="">All patients</option>
            {patients.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
          </select>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>
          Historical measurements are never overwritten. Recalculations and re-approvals create new versions, visible in each record's Surgeon Approval tab.
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr>
              <th>Date</th><th>Patient</th><th>Eye</th><th>AXL</th><th>K1/K2</th><th>ACD</th><th>Device</th><th>Formula</th><th>Approved IOL</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.visits?.patients;
              const eyeKey = r.surgical_eye === 'RE' ? 're' : r.surgical_eye === 'LE' ? 'le' : null;
              const eyeSets = eyeKey && Array.isArray(r.measurements?.[eyeKey]) ? r.measurements[eyeKey] : [];
              const m = eyeSets.find((s) => s.axl && s.k1 && s.k2 && s.acd) || eyeSets[0] || {};
              return (
                <tr key={r.id} onClick={() => router.push(`/biometry/${r.id}`)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.updated_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td>
                    <strong>{patient?.first_name} {patient?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span>
                  </td>
                  <td>{r.surgical_eye || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.axl || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.k1 || '--'}/{m.k2 || '--'}</td>
                  <td style={{ fontFamily: 'monospace' }}>{m.acd || '--'}</td>
                  <td style={{ fontSize: 11 }}>{m.device || '--'}</td>
                  <td>{r.selected_formula || r.final_iol_power ? (r.selected_formula || '--') : '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.final_iol_power ? `${r.final_iol_power} D` : '--'}</td>
                  <td><span className={`badge ${r.status === 'Approved' ? 'b-green' : 'b-blue'}`}>{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={10} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
FILEEOF

echo "Files written:"
wc -l "$DIR/actions.js" "$IDDIR/measurements-tab.js" "$IDDIR/calculation-tab.js" "$HISTDIR/page.js"

echo ""
echo "Running build..."
npm run build

echo ""
echo "==================================================================="
echo "Build passed. Files written but NOT committed. Review with:"
echo "  git diff --stat \"$DIR\""
echo "Then commit:"
echo "  git add \"$DIR/actions.js\" \"$IDDIR/measurements-tab.js\" \"$IDDIR/calculation-tab.js\" \"$HISTDIR/page.js\""
echo "  git commit -m \"Biometry: support multiple tagged readings per eye (A-Scan + Optical Biometer)\""
echo "  git push"
echo "==================================================================="
