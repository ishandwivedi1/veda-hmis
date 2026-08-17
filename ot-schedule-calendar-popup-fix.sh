#!/bin/bash
set -e

echo "== Veda HMIS: OT Schedule Calendar tab + popup date picker for Surgical Journey, IOL Approval live refresh + Edit, Fitness after IOL order/date, Package selection, Biometry lock mode, duplicate-order guard, referral print simplification ==" 

mkdir -p "app/(main)/biometry" "app/(main)/biometry/[id]" "app/(main)/consultation" "app/(main)/investigation" "app/(main)/investigation/history" "app/(main)/iol-approval" "app/(main)/medical-fitness" "app/(main)/ot-schedule" "app/(main)/patient-timeline" "app/(main)/surgical-journey" "app/(main)/surgical-journey/[id]" "app/consultation/[id]" "app/print-templates"

rm -f "app/(main)/surgical-journey/[id]/ot-calendar-picker.js"

cat > "app/(main)/biometry/[id]/workspace.js" << '__VEDA_FILE_0_END__'
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
            {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
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
__VEDA_FILE_0_END__

cat > "app/(main)/biometry/actions.js" << '__VEDA_FILE_1_END__'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──────────────────────────────────────────────────────────
// Biometry is patient-level now, not visit/case-level -- a session is
// reused across every future surgical case for that patient. The queue
// just lists records not yet Measured, regardless of which visit
// originally ordered them.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measuredToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.patients)
    .map((r) => ({
      recordId: r.id,
      patientId: r.patient_id,
      patient: r.patients,
      status: r.status,
      doctorInstructions: r.doctor_instructions,
    }));

  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const { data: measuredToday } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC);

  const stats = {
    awaiting: rows.length,
    measuredToday: (measuredToday || []).length,
  };

  return { rows, stats };
}

// ── COMPLETED TODAY -- Measured records from today, so a session
// doesn't disappear from the Queue the instant it's done. Moves to
// History once the day rolls over -- same Dashboard/History split used
// elsewhere. ──
export async function getBiometryCompletedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .gte('updated_at', startUTC)
    .lte('updated_at', endUTC)
    .order('updated_at', { ascending: false });
  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ recordId: r.id, patientId: r.patient_id, patient: r.patients, status: r.status }));
}

// Finds an existing biometry record for this PATIENT -- reused across
// every future surgical case (readings don't meaningfully change for
// years), so this is a lookup-or-create against patient_id, not
// visit_id like most other "ensure a record" functions in this app.
export async function getOrCreateBiometryRecord(patientId, visitId, encounterId) {
  const supabase = await createClient();

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0) return { id: existing[0].id };

  const { data: created, error } = await supabase
    .from('biometry_records')
    .insert({ patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null })
    .select('id')
    .single();

  if (error) return { error: error.message };
  return { id: created.id };
}

export async function getBiometryDetail(id) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(first_name, last_name, uhid, age, gender)')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  const { data: recommendations } = await supabase
    .from('biometry_iol_recommendations')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('biometry_record_id', id)
    .order('created_at', { ascending: true });

  // Once a record is Measured, opening it (e.g. via "View Report" from
  // Surgical Journey) should default to a locked, read-only view --
  // only a Doctor can unlock it to make a correction. Before Measured,
  // the normal technician data-entry flow is unaffected.
  const { data: userData } = await supabase.auth.getUser();
  let isDoctor = false;
  if (userData?.user) {
    const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
    isDoctor = me?.designation === 'Doctor';
  }

  return { record: data, recommendations: recommendations || [], isDoctor };
}

// Persists measurement readings without changing status -- technician
// can leave and resume later. Once the record is Measured, this is
// locked to Doctors only (correcting a finalized reading), same
// boundary the workspace UI enforces.
export async function saveBiometryDraft(id, measurements) {
  const supabase = await createClient();
  const lockError = await assertBiometryEditable(supabase, id);
  if (lockError) return lockError;

  const { error } = await supabase
    .from('biometry_records')
    .update({ measurements, updated_at: new Date().toISOString() })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

function isComplete(set) {
  return REQUIRED_FIELDS.every((f) => set[f] && String(set[f]).trim());
}

// Marks the session done -- requires at least one complete reading for
// EACH eye (biometry is always done for both eyes now) and at least
// one IOL recommendation row entered, plus the device report attached
// (checked by the caller via AttachmentUploader's own listing, not
// re-verified here -- consistent with how other modules treat
// attachments as informational rather than a hard DB gate).
export async function markBiometryMeasured(id, measurements, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const reHasComplete = (measurements.re || []).some(isComplete);
  const leHasComplete = (measurements.le || []).some(isComplete);
  if (!reHasComplete || !leHasComplete) {
    return { error: 'At least one complete reading (AXL, K1, K2, ACD) is required for BOTH eyes.' };
  }

  const { count } = await supabase
    .from('biometry_iol_recommendations')
    .select('id', { count: 'exact', head: true })
    .eq('biometry_record_id', id);
  if (!count) return { error: 'Add at least one IOL recommendation from the device printout before marking as measured.' };

  const devicesUsed = [...new Set([...(measurements.re || []), ...(measurements.le || [])].map((s) => s.device).filter(Boolean))];

  const { data, error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Measured',
      measurements,
      verify_device: devicesUsed.join(', '),
      verify_remarks: remarks || null,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    })
    .eq('id', id)
    .select('visit_id, patient_id')
    .single();

  if (error) return { error: error.message };
  if (data?.visit_id) await logJourneyEvent(supabase, data.visit_id, 'biometry_completed');

  // Biometry is ordered through the regular OPD Investigations panel
  // now (selectable like any other investigation), which creates a
  // normal investigation_orders row alongside this specialized
  // fulfillment. Keep that row in sync so it doesn't sit showing
  // "Ordered" forever in the doctor's list once the actual work is
  // done -- match across ALL of this patient's encounters, since
  // biometry is patient-level and the order could have come from any
  // visit.
  if (data?.patient_id) {
    const { data: visits } = await supabase.from('visits').select('id').eq('patient_id', data.patient_id);
    const visitIds = (visits || []).map((v) => v.id);
    if (visitIds.length > 0) {
      const { data: encounters } = await supabase.from('encounters').select('id').in('visit_id', visitIds);
      const encounterIds = (encounters || []).map((e) => e.id);
      if (encounterIds.length > 0) {
        await supabase
          .from('investigation_orders')
          .update({ status: 'Available', verified_at: new Date().toISOString() })
          .in('encounter_id', encounterIds)
          .ilike('name', 'biometry')
          .eq('status', 'Ordered');
      }
    }
  }

  return { success: true };
}

// ── IOL RECOMMENDATIONS ──────────────────────────────────────────
// The device's own printed table -- for each brand/model it evaluated,
// what power it recommends per eye. This app records what the printout
// says; it does not calculate anything itself.
// Shared lock check: once a biometry record is Measured, only a
// Doctor can modify it (readings or recommendations) -- everyone else
// gets a read-only view. Returns null if the edit is allowed, or an
// {error} object to return straight from the calling action.
async function assertBiometryEditable(supabase, biometryRecordId) {
  const { data: existing } = await supabase.from('biometry_records').select('status').eq('id', biometryRecordId).maybeSingle();
  if (existing?.status !== 'Measured') return null;
  const { data: userData } = await supabase.auth.getUser();
  const { data: me } = userData?.user
    ? await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle()
    : { data: null };
  if (me?.designation !== 'Doctor') {
    return { error: 'This biometry record is already Measured and locked. Only a Doctor can edit it.' };
  }
  return null;
}

export async function addIolRecommendation(biometryRecordId, iolCatalogId, rePower, lePower) {
  const supabase = await createClient();
  const lockError = await assertBiometryEditable(supabase, biometryRecordId);
  if (lockError) return lockError;
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!rePower && !lePower) return { error: 'Enter at least one power (RE or LE).' };
  const { error } = await supabase.from('biometry_iol_recommendations').insert({
    biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    re_power: rePower || null, le_power: lePower || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeIolRecommendation(id) {
  const supabase = await createClient();
  const { data: rec } = await supabase.from('biometry_iol_recommendations').select('biometry_record_id').eq('id', id).maybeSingle();
  if (rec?.biometry_record_id) {
    const lockError = await assertBiometryEditable(supabase, rec.biometry_record_id);
    if (lockError) return lockError;
  }
  const { error } = await supabase.from('biometry_iol_recommendations').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── HISTORY -- cross-patient, Measured or Cancelled. ──
export async function getBiometryHistory(patientFilter) {
  const supabase = await createClient();

  let query = supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false });

  const { data, error } = await query;
  if (error) return { rows: [], patients: [] };

  let rows = data || [];
  const patientsMap = {};
  rows.forEach((r) => {
    const p = r.patients;
    if (p) patientsMap[p.id] = `${p.first_name} ${p.last_name}`;
  });

  if (patientFilter) {
    rows = rows.filter((r) => r.patients?.id === patientFilter);
  }

  return {
    rows,
    patients: Object.entries(patientsMap).map(([id, name]) => ({ id, name })),
  };
}

// ── FRONT OFFICE BILLING QUEUE ──
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, patients(id, first_name, last_name, uhid)')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.patients)
    .map((r) => ({ patientId: r.patient_id, patient: r.patients, items: [r] }));
}

async function setBiometryBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('biometry_records')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markBiometryDenied(id, note) {
  return setBiometryBillingStatus(id, 'Denied', note);
}

export async function markBiometryDeferred(id, note) {
  return setBiometryBillingStatus(id, 'Deferred', note);
}

export async function resetBiometryBilling(id) {
  return setBiometryBillingStatus(id, 'Pending', null);
}
__VEDA_FILE_1_END__

cat > "app/(main)/consultation/actions.js" << '__VEDA_FILE_2_END__'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';
import { isCurrentUserAdmin } from '@/lib/authz';

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let encounter;
  if (entry.status === 'Done') {
    // Most recent encounter for this visit, any status -- not combining
    // .limit() with .maybeSingle() here, since that pairing isn't used
    // anywhere else in this codebase (getOrCreateBiometryRecord uses the
    // same array + length check instead for exactly this kind of lookup).
    const { data: encounters, error: encListError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .order('started_at', { ascending: false })
      .limit(1);
    if (encListError) return { error: encListError.message };
    encounter = encounters && encounters.length > 0 ? encounters[0] : null;
  } else {
    const { data: activeEncounter, error: encActiveError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .eq('status', 'In Consultation')
      .maybeSingle();
    if (encActiveError) return { error: encActiveError.message };
    encounter = activeEncounter;
  }

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    // For a completed (Done) queue entry there's nothing to auto-create --
    // if no encounter exists, the visit genuinely has no clinical record.
    // Auto-creating only makes sense for an active/new consultation.
    if (entry.status === 'Done') {
      return { error: 'No clinical record found for this completed visit.' };
    }
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await addAudit(supabase, encounter.id, 'Encounter started', userData?.user?.id);
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const patientId = entry.visits.patients.id;

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // encounter_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw }, { data: surgicalCases },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('workflow_requests').select('*').eq('visit_id', visitId).order('requested_at', { ascending: false }),
    supabase.from('encounter_audit_log').select('*').eq('encounter_id', encounter.id).order('created_at', { ascending: false }),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounter.id).maybeSingle(),
    // Longitudinal (cross-visit) diagnosis history: every diagnosis this
    // patient has, across all their encounters, via visits -> encounters.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, status, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    // So "Mark for Surgery" can show what's already been marked instead
    // of silently reverting to a blank button after saving. Scoped by
    // visit_id (one visit, one surgical case), not just this encounter,
    // since a visit can span more than one encounter.
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required, decision, decision_locked').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  // Follow-up Template: same consultation engine, just extra context --
  // a patient is a "follow-up" the moment they have any prior encounter
  // at all, on a different visit, regardless of whether that encounter
  // was ever formally completed (an abandoned/in-progress note still
  // means this isn't their first time being seen).
  const priorEncounters = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorCompletedEncounters = priorEncounters.filter((e) => e.status === 'Completed');
  const isFollowUp = priorEncounters.length > 0;

  if (isFollowUp && encounter.encounter_type !== 'Follow-up') {
    await supabase.from('encounters').update({ encounter_type: 'Follow-up' }).eq('id', encounter.id);
    encounter.encounter_type = 'Follow-up';
  }

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: isAdmin ? (auditLog || []) : [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
    surgicalCases: surgicalCases || [],
    isLocked: encounter.status === 'Completed',
    isFollowUp, priorEncounterId: priorCompletedEncounters[0]?.id || null,
    isAdmin,
  };
}

// ── FOLLOW-UP TEMPLATE CONTEXT ──
// Everything the Follow-up template needs beyond what getConsultationData
// already returns: the visit timeline, patient snapshot, and a summary
// of the immediately preceding visit. Only called when isFollowUp is true.
export async function getFollowUpContext(patientId, currentVisitId, currentEncounterId) {
  const supabase = await createClient();

  const { data: visitsRaw } = await supabase
    .from('visits')
    .select('id, visit_number, encounters(id, started_at, completed_at, chief_complaint, status)')
    .eq('patient_id', patientId);

  const allPriorEncounters = (visitsRaw || [])
    .flatMap((v) => (v.encounters || []).map((e) => ({ ...e, visitId: v.id, visitNumber: v.visit_number })))
    .filter((e) => e.id !== currentEncounterId)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorEncounters = allPriorEncounters.filter((e) => e.status === 'Completed');

  // Map each prior visit back to its Doctor queue entry, so the
  // timeline can open it read-only -- same lookup pattern Patient
  // Timeline already uses.
  const priorVisitIds = [...new Set(allPriorEncounters.map((e) => e.visitId))];
  let queueEntryByVisit = {};
  if (priorVisitIds.length > 0) {
    const { data: entries } = await supabase.from('queue_entries').select('id, visit_id').in('visit_id', priorVisitIds).eq('department', 'Doctor');
    (entries || []).forEach((e) => { queueEntryByVisit[e.visit_id] = e.id; });
  }

  // Timeline shows every prior visit, including ones that were never
  // finalized -- still useful context, just labeled as such.
  const timeline = allPriorEncounters.slice(0, 15).map((e) => ({
    encounterId: e.id, date: e.started_at, chiefComplaint: e.chief_complaint,
    status: e.status, queueEntryId: queueEntryByVisit[e.visitId] || null,
  }));

  const lastEncounter = priorEncounters[0] || null;
  let snapshot = {
    lastVisitDate: lastEncounter?.started_at || null,
    currentDiagnoses: [], currentMedications: [], allergy: null,
    lastVision: null, lastIop: null, surgicalStatus: null,
    previousVisitSummary: null,
    noCompletedPriorVisit: !lastEncounter,
  };
  let newInvestigations = [];

  if (lastEncounter) {
    // Investigations ordered (anywhere -- Counselling, a walk-in
    // Investigation visit, etc.) since the last consultation, with
    // results ready -- these are easy to miss since they don't
    // necessarily belong to *this* encounter's own Investigations list.
    const allEncounterIds = (visitsRaw || []).flatMap((v) => (v.encounters || []).map((e) => e.id));
    if (allEncounterIds.length > 0) {
      const { data: recentInv } = await supabase
        .from('investigation_orders')
        .select('*')
        .in('encounter_id', allEncounterIds)
        .neq('encounter_id', currentEncounterId)
        .eq('status', 'Available')
        .gt('created_at', lastEncounter.started_at)
        .order('created_at', { ascending: false });
      newInvestigations = recentInv || [];
    }
    const [{ data: fullEncounter }, { data: diagnoses }, { data: medications }, { data: assessment }, { data: advice }, { data: fu }] = await Promise.all([
      supabase.from('encounters').select('hx_drug_allergy').eq('id', lastEncounter.id).maybeSingle(),
      supabase.from('diagnoses').select('*').eq('encounter_id', lastEncounter.id).eq('status', 'Active').order('created_at'),
      supabase.from('prescriptions').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('optometry_assessments').select('*').eq('visit_id', lastEncounter.visitId).eq('status', 'Completed').maybeSingle(),
      supabase.from('plan_optical_advice').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('plan_followups').select('*').eq('encounter_id', lastEncounter.id).maybeSingle(),
    ]);

    let lastIop = null;
    if (assessment) {
      const { data: iopReadings } = await supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: false }).limit(1);
      lastIop = iopReadings?.[0] || null;
    }

    const { data: recentSurgicalCase } = await supabase
      .from('surgical_cases').select('procedure_name, eye, status')
      .eq('patient_id', patientId).neq('status', 'Cancelled')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();

    snapshot = {
      lastVisitDate: lastEncounter.started_at,
      currentDiagnoses: diagnoses || [],
      currentMedications: medications || [],
      allergy: fullEncounter?.hx_drug_allergy || null,
      lastVision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
      lastIop,
      surgicalStatus: recentSurgicalCase || null,
      previousVisitSummary: {
        date: lastEncounter.started_at,
        diagnoses: diagnoses || [],
        medications: medications || [],
        advice: advice || [],
        followupPlan: fu || null,
        vision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
        iop: lastIop,
      },
    };
  }

  return { timeline, snapshot, newInvestigations };
}

// ── VISIT OUTCOME ──
export async function saveVisitOutcome(encounterId, outcome) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ visit_outcome: outcome }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CARRY FORWARD a prior diagnosis into the current encounter ──
export async function carryForwardDiagnosis(encounterId, diagnosis) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId, name: diagnosis.name, category: diagnosis.category, eye: diagnosis.eye, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}
export async function saveExamination(examinationId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Examination saved', userData?.user?.id);
  return { success: true };
}

// ── STRUCTURED HISTORY (Section 11.9) ──
// Batched save, same pattern as Examination -- not per-keystroke.
export async function saveHistory(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({
      chief_complaint: fields.chiefComplaint,
      chief_complaint_chips: fields.chiefComplaintChips,
      hx_duration: fields.hxDuration,
      hx_laterality: fields.hxLaterality,
      hx_hopi: fields.hxHopi,
      ocular_history: fields.ocularHistory,
      medical_history: fields.medicalHistory,
      family_history: fields.familyHistory,
      drug_history: fields.drugHistory,
      allergy: fields.allergy,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DOCTOR EDITS OPTOMETRY FINDINGS DIRECTLY (in-place override) ──
// The doctor edits the optometrist's own assessment record. Every
// changed field is written to that assessment's audit log (the same
// log the optometrist sees in Optometry History) as a before/after
// entry, so the optometrist can see exactly what was changed and by
// whom -- without a separate shadow record.
const OPTOM_FIELD_LABELS = {
  va_scale: 'VA Scale',
  re_dist_unaided: 'RE Dist Unaided', re_dist_glasses: 'RE Dist Glasses', re_dist_ph: 'RE Dist Pinhole', re_near_unaided: 'RE Near Unaided',
  le_dist_unaided: 'LE Dist Unaided', le_dist_glasses: 'LE Dist Glasses', le_dist_ph: 'LE Dist Pinhole', le_near_unaided: 'LE Near Unaided',
  ref_pd: 'PD', ref_vd: 'VD',
  ref_obj_re_sph: 'RE Obj Sph', ref_obj_re_cyl: 'RE Obj Cyl', ref_obj_re_axis: 'RE Obj Axis',
  ref_obj_le_sph: 'LE Obj Sph', ref_obj_le_cyl: 'LE Obj Cyl', ref_obj_le_axis: 'LE Obj Axis',
  ref_subj_re_sph: 'RE Subj Sph', ref_subj_re_cyl: 'RE Subj Cyl', ref_subj_re_axis: 'RE Subj Axis',
  ref_subj_le_sph: 'LE Subj Sph', ref_subj_le_cyl: 'LE Subj Cyl', ref_subj_le_axis: 'LE Subj Axis',
  ref_final_re_sph: 'RE Final Sph', ref_final_re_cyl: 'RE Final Cyl', ref_final_re_axis: 'RE Final Axis', ref_final_re_add: 'RE Final Add',
  ref_final_le_sph: 'LE Final Sph', ref_final_le_cyl: 'LE Final Cyl', ref_final_le_axis: 'LE Final Axis', ref_final_le_add: 'LE Final Add',
  iop_method: 'IOP Method', iop_time: 'IOP Time',
  add_k1: 'Keratometry K1', add_k2: 'Keratometry K2', add_axial_length: 'Axial Length', add_pachymetry: 'Pachymetry',
  add_white_to_white: 'White-to-White', add_schirmer: 'Schirmer', add_color_vision: 'Color Vision',
  add_ocular_motility: 'Ocular Motility', add_syringing: 'Syringing',
  observation_chips: 'Observation Tags', observations_text: 'Observations',
};

export async function updateOptometryFindings(assessmentId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: current, error: fetchError } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('id', assessmentId)
    .single();
  if (fetchError) return { error: fetchError.message };

  const changes = [];
  const updatePayload = {};
  Object.keys(OPTOM_FIELD_LABELS).forEach((key) => {
    if (fields[key] === undefined) return;
    const oldVal = current[key];
    const newVal = fields[key];
    const oldStr = Array.isArray(oldVal) ? oldVal.join(', ') : (oldVal ?? '');
    const newStr = Array.isArray(newVal) ? newVal.join(', ') : (newVal ?? '');
    if (oldStr === newStr) return;
    updatePayload[key] = newVal;
    changes.push({ label: OPTOM_FIELD_LABELS[key], oldStr: oldStr || '--', newStr: newStr || '--' });
  });

  if (changes.length === 0) return { success: true, changedCount: 0 };

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...updatePayload, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  for (const c of changes) {
    await supabase.from('optometry_audit_log').insert({
      assessment_id: assessmentId,
      message: `Doctor override -- ${c.label}: "${c.oldStr}" -> "${c.newStr}"`,
      created_by: doctorId,
    });
  }

  if (encounterId) {
    await addAudit(supabase, encounterId, `Optometry findings overridden -- ${changes.length} field(s) changed`, doctorId);
  }

  return { success: true, changedCount: changes.length };
}

// Lets the doctor start an optometry assessment directly when the
// patient never went through Optometry -- same table, just created and
// initially owned from the consultation side instead of the queue.
export async function createOptometryAssessmentForVisit(visitId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .insert({ visit_id: visitId, recorded_by: doctorId, completed_by: doctorId, status: 'Completed', completed_at: new Date().toISOString() })
    .select()
    .single();
  if (error) return { error: error.message };

  await supabase.from('optometry_audit_log').insert({ assessment_id: assessment.id, message: 'Assessment started by Doctor -- no prior Optometry visit', created_by: doctorId });
  if (encounterId) await addAudit(supabase, encounterId, 'Optometry assessment created directly by doctor', doctorId);

  return { assessment };
}


// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye}, ${values.category})`, userData?.user?.id);
  return { success: true };
}

export async function removeDiagnosis(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Diagnosis removed', userData?.user?.id);
  return { success: true };
}

export async function updateDiagnosisNotes(id, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').update({ notes: notes?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Prescription added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

// Tapering schedule -- same drug and dosage-per-administration across
// steps (that's how tapering actually works clinically: the amount per
// dose stays the same, e.g. 1 drop, only the frequency reduces over
// time), each step a separate row sharing one taper_group_id so they
// render and print as a single continuous instruction, not N unrelated
// prescriptions.
export async function addTaperedPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const steps = (values.steps || []).filter((s) => s.frequency && s.duration);
  if (steps.length < 2) return { error: 'A tapering schedule needs at least 2 steps.' };

  const taperGroupId = crypto.randomUUID();
  const rows = steps.map((s, i) => ({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: s.frequency,
    duration: s.duration,
    eye: values.eye,
    taper_group_id: taperGroupId,
    taper_step: i + 1,
  }));

  const { error } = await supabase.from('prescriptions').insert(rows);
  if (error) return { error: error.message };
  const summary = steps.map((s) => `${s.frequency} x${s.duration}`).join(' -> ');
  await addAudit(supabase, encounterId, `Tapering schedule added: ${values.drugName} (${values.eye}) -- ${summary}`, userData?.user?.id);
  return { success: true };
}

export async function removeTaperGroup(taperGroupId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: rows } = await supabase.from('prescriptions').select('drug_name, eye').eq('taper_group_id', taperGroupId).limit(1);
  const { error } = await supabase.from('prescriptions').delete().eq('taper_group_id', taperGroupId);
  if (error) return { error: error.message };
  if (rows?.[0]) await addAudit(supabase, encounterId, `Tapering schedule removed: ${rows[0].drug_name} (${rows[0].eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePrescription(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Prescription removed', userData?.user?.id);
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  // Don't let the same investigation get ordered twice for this
  // encounter while an earlier order is still open (Ordered/In
  // Progress) -- same name, same eye. Cancelled/completed ones don't
  // block a fresh order.
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', encounterId)
    .eq('eye', values.eye)
    .ilike('name', values.name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${values.name.trim()}" (${values.eye}) is already ordered and still pending for this visit.` };
  }

  // Biometry is a "special" investigation -- selectable here like any
  // other, but fulfilled through its own dedicated module (device
  // readings for both eyes, IOL recommendations, report upload), not
  // the plain investigation queue. Ordering it here still creates a
  // normal investigation_orders row (shows up in this OPD list like
  // anything else), but also ensures the underlying biometry_records
  // row exists so it correctly routes there. Biometry is patient-level
  // and reusable for years -- if it's already Measured, there's
  // nothing to re-order, just say so instead of creating a duplicate.
  if (values.name.trim().toLowerCase() === 'biometry') {
    const { data: enc } = await supabase.from('encounters').select('visit_id, visits(patient_id)').eq('id', encounterId).single();
    const patientId = enc?.visits?.patient_id;
    if (!patientId) return { error: 'Could not resolve patient for this encounter.' };

    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id, status')
      .eq('patient_id', patientId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (existing && existing.length > 0 && existing[0].status === 'Measured') {
      return { error: 'Biometry is already on file for this patient (Measured) -- no need to re-order. Open it from the Biometry module if you need to review it.' };
    }

    const { error } = await supabase.from('investigation_orders').insert({
      encounter_id: encounterId, name: 'Biometry', eye: values.eye, priority: values.priority,
    });
    if (error) return { error: error.message };

    // Shared with Surgical Journey's own "order Biometry" path --
    // creates the biometry_records row if none exists yet, or just
    // reuses the one that does, instead of duplicating that logic here.
    await ensureBiometryRecord(supabase, patientId, enc.visit_id, encounterId, null);

    await addAudit(supabase, encounterId, 'Biometry ordered', userData?.user?.id);
    return { success: true };
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Investigation ordered: ${values.name} (${values.eye}, ${values.priority})`, userData?.user?.id);
  return { success: true };
}

export async function removeInvestigation(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Investigation removed', userData?.user?.id);
  return { success: true };
}

// ── WORKFLOW REQUESTS (Biometry / Medical Fitness / Counselling) ──
// Independent, non-exclusive toggles -- a visit can have more than one
// open at a time, unlike Dilation/Investigation which move the queue
// entry itself. Toggling an already-open request cancels it.
export async function toggleWorkflowRequest(visitId, encounterId, kind) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: existing } = await supabase
    .from('workflow_requests')
    .select('*')
    .eq('visit_id', visitId)
    .eq('kind', kind)
    .eq('status', 'Requested')
    .maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('workflow_requests')
      .update({ status: 'Cancelled', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
      .eq('id', existing.id);
    if (error) return { error: error.message };
    await addAudit(supabase, encounterId, `Workflow request cancelled: ${kind}`, userData?.user?.id);
    return { success: true, active: false };
  }

  const { error } = await supabase.from('workflow_requests').insert({
    visit_id: visitId, encounter_id: encounterId, kind, requested_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Workflow requested: ${kind}`, userData?.user?.id);
  return { success: true, active: true };
}

// Mark a workflow request (Biometry/Fitness/Counselling) as done --
// used by whichever staff member actually completes it (e.g. the
// counsellor marking a Counselling request resolved).
export async function completeWorkflowRequest(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('workflow_requests')
    .update({ status: 'Completed', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
    .eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Workflow request marked complete', userData?.user?.id);
  return { success: true };
}

// ── MANAGEMENT PLAN EXPANSION (Ch.14) ──
export async function addOpticalAdvice(encounterId, advice) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_optical_advice').insert({ encounter_id: encounterId, advice, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Optical advice added: ${advice}`, userData?.user?.id);
  return { success: true };
}

export async function removeOpticalAdvice(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_optical_advice').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Optical advice removed', null);
  return { success: true };
}

export async function addProcedure(encounterId, name, eye, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, notes: notes || null, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Minor Procedure planned: ${name} (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function removeProcedure(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_procedures').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Procedure removed', null);
  return { success: true };
}

export async function addReferral(encounterId, destination, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_referrals').insert({ encounter_id: encounterId, destination, reason, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Referral added: ${destination}`, userData?.user?.id);
  return { success: true };
}

export async function removeReferral(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_referrals').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Referral removed', null);
  return { success: true };
}

export async function addCounsellingItem(encounterId, topic) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_counselling_items').insert({ encounter_id: encounterId, topic, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Counselling topic added: ${topic}`, userData?.user?.id);
  return { success: true };
}

export async function removeCounsellingItem(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Counselling topic removed', null);
  return { success: true };
}

// Any plan item (optical/procedure/referral/counselling) marked done --
// used from the Action Tracker tab.
export async function completePlanItem(table, id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ status: 'Done' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Plan item marked done', null);
  return { success: true };
}

// Follow-up is one record per encounter -- upsert by encounter_id.
export async function saveFollowup(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_followups')
    .upsert(
      { encounter_id: encounterId, after_period: fields.after, visit_type: fields.type, clinic: fields.clinic, instructions: fields.instructions, created_by: userData?.user?.id || null },
      { onConflict: 'encounter_id' }
    );
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Follow-up scheduled: ${fields.after} -- ${fields.type}`, userData?.user?.id);
  return { success: true };
}

export async function savePatientInstructions(encounterId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ patient_instructions: instructions }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Encounter completed', userData?.user?.id);

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'dilate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Dilation', userData?.user?.id);
  return result;
}

export async function sendForInvestigationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'investigate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Investigation', userData?.user?.id);
  return result;
}

// Minor Procedures are performed by the doctor directly, in the same
// sitting -- unlike Dilation/Investigation/Biometry there's no separate
// department to route the patient to, so this just confirms the
// procedure(s) for the audit trail. Billing already picks them up the
// moment they're added (billing_status defaults to 'Pending'); this
// doesn't change that.
export async function sendForProcedureFromConsultation(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Sent for Procedure', userData?.user?.id);
  return { success: true };
}

// Shared by both the "Add" button (advises Biometry without moving the
// patient anywhere yet) and "Send for Biometry" (which also routes the
// queue) -- creates the record if none exists yet for that eye, or
// Biometry is patient-level now, not visit/case-level, and always
// covers both eyes -- one session is reused across every future
// surgical case for that patient (readings don't meaningfully change
// for years). "Advise" just ensures a record exists for this patient,
// updating instructions if one already does.
async function ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: created } = await supabase.from('biometry_records').insert({
      patient_id: patientId, visit_id: visitId || null, encounter_id: encounterId || null,
      doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// The "Add" step -- advises Biometry is needed (records instructions,
// if any) without moving the patient's queue position at all. Mirrors
// exactly how Investigations work: "Add" saves the order, "Send for
// Investigation" is a separate, later action that routes the patient.
export async function adviseBiometry(patientId, visitId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecord(supabase, patientId, visitId, encounterId, instructions);
  await addAudit(supabase, encounterId, 'Biometry advised', userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, patientId, encounterId, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, 'Sent for Biometry', userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  await ensureBiometryRecord(supabase, patientId, entry?.visit_id || null, encounterId, instructions);

  return result;
}

// For updating instructions on a biometry record that's already been
// sent -- eye is fixed once a record exists (changing it would mean a
// different physical record, not editing this one), but instructions
// can still be corrected/added at any point before the technician
// finishes.
// Doctor can remove a mistakenly-added/sent biometry request (wrong
// eye, duplicate, etc.) -- but only while it's still unbilled. Once
// Front Office has billed it, removing the record here would leave an
// invoice line with nothing behind it, so that has to go through
// billing's own modification flow instead.
export async function removeBiometryRecord(id, encounterId) {
  const supabase = await createClient();
  const { data: record } = await supabase.from('biometry_records').select('billing_status').eq('id', id).maybeSingle();
  if (!record) return { error: 'Record not found.' };
  if (record.billing_status === 'Billed') {
    return { error: 'This has already been billed and cannot be removed here -- use Billing to modify the invoice first.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('biometry_records').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Biometry request removed', userData?.user?.id);
  return { success: true };
}

export async function updateBiometryInstructions(id, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_records').update({ doctor_instructions: instructions?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function saveDraft(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Consultation saved as draft', userData?.user?.id);
  return { success: true };
}

__VEDA_FILE_2_END__

cat > "app/(main)/investigation/actions.js" << '__VEDA_FILE_3_END__'
'use server';

import { createClient } from '@/lib/supabase-server';
import { logJourneyEvent } from '@/lib/journey-events';

// ── QUEUE (Ordered + In Progress, grouped by visit) plus today's KPI
// stats for the Queue screen's summary cards. ──
export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data: pending, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    // Biometry is ordered here too (so it shows in the doctor's OPD
    // list), but it's fulfilled through its own biometry_records row,
    // which is merged into this queue separately below. Exclude it
    // here so it doesn't show twice with the second copy wrongly
    // routing to the plain Investigation workspace.
    .not('name', 'ilike', 'biometry')
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return { groups: [], stats: { ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 } };

  // Payment status is about the invoice, not just whether Front Office
  // ticked "billed" -- an invoice can be raised and still unpaid, so
  // this looks at the actual invoice net/paid amounts.
  const invoiceIds = [...new Set((pending || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  const groups = {};
  (pending || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient: io.encounters.visits.patients, items: [] };
    }
    groups[visitId].items.push({ ...io, kind: 'investigation', payment: paymentInfo(io) });
  });

  // Biometry is structurally its own thing (device measurements, IOL
  // recommendations, surgeon approval -- not a text-field investigation),
  // so it stays in its own table and dedicated workspace/dashboard. But
  // per the doctor's actual usage, it belongs in the same "what's
  // outstanding for this patient" queue as any other investigation, not
  // off in a separate module people forget to check. Only "Awaiting
  // Biometry" is pending now -- "Measured" means done (there's no more
  // Calculated/Approved in between; those concepts moved to the
  // separate IOL Approval module).
  const { data: bio } = await supabase
    .from('biometry_records')
    .select('*, visits(id, patients(first_name, last_name, uhid))')
    .eq('status', 'Awaiting Biometry')
    .order('created_at', { ascending: true });

  const bioInvoiceIds = [...new Set((bio || []).map((r) => r.invoice_id).filter(Boolean))];
  let bioInvoiceMap = invoiceMap;
  if (bioInvoiceIds.length > 0) {
    const { data: moreInvoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', bioInvoiceIds);
    (moreInvoices || []).forEach((inv) => { bioInvoiceMap[inv.id] = inv; });
  }
  function bioPaymentInfo(r) {
    if (r.billing_status !== 'Billed' || !r.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = bioInvoiceMap[r.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  (bio || []).forEach((r) => {
    // Biometry is patient-level and reusable now, not visit-scoped, so
    // visit_id can legitimately be null (e.g. ordered a while back, or
    // a case registered directly). Skip merging into this per-visit
    // queue in that case -- it still shows up in Biometry's own queue
    // either way.
    const visitId = r.visit_id;
    const patient = r.visits?.patients;
    if (!visitId || !patient) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, patient, items: [] };
    }
    groups[visitId].items.push({
      id: r.id, kind: 'biometry', name: 'Biometry', eye: 'OU', priority: 'Routine',
      status: r.status, created_at: r.created_at, payment: bioPaymentInfo(r),
    });
  });

  const ordered = (pending || []).filter((i) => i.status === 'Ordered').length;
  const inProgress = (pending || []).filter((i) => i.status === 'In Progress').length;

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);
  const { data: todayOrders } = await supabase
    .from('investigation_orders')
    .select('id, status, verified_at, created_at')
    .gte('created_at', todayStart.toISOString());

  const availableToday = (todayOrders || []).filter((o) => o.status === 'Available' && o.verified_at && new Date(o.verified_at) >= todayStart).length;
  const totalToday = (todayOrders || []).length;

  return { groups: Object.values(groups), stats: { ordered, inProgress, availableToday, totalToday } };
}

// ── TODAY'S INVESTIGATIONS -- for the Dashboard widget (patient, test
// name, billing status, view/print). IST-bounded so "today" matches
// the front desk's actual working day rather than UTC midnight.
// Returns everything ordered today regardless of status -- the page
// splits pending vs completed client-side (see investigation/page.js). ──
export async function getTodaysInvestigations() {
  const supabase = await createClient();
  const todayIST = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIST}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIST}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, visits(patients(first_name, last_name, uhid)))')
    .gte('created_at', startUTC)
    .lte('created_at', endUTC)
    .order('created_at', { ascending: false });
  if (error) return [];

  const invoiceIds = [...new Set((data || []).map((io) => io.invoice_id).filter(Boolean))];
  let invoiceMap = {};
  if (invoiceIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('id, net, paid, status').in('id', invoiceIds);
    (invoices || []).forEach((inv) => { invoiceMap[inv.id] = inv; });
  }
  function paymentInfo(io) {
    if (io.billing_status !== 'Billed' || !io.invoice_id) return { label: 'Unbilled', badge: 'b-gray' };
    const inv = invoiceMap[io.invoice_id];
    if (!inv || inv.status === 'Cancelled') return { label: 'Unbilled', badge: 'b-gray' };
    if (inv.status === 'Paid' || Number(inv.paid) >= Number(inv.net)) return { label: 'Paid', badge: 'b-green' };
    return { label: 'Billed -- Payment Due', badge: 'b-amber' };
  }

  return (data || [])
    .filter((io) => io.encounters?.visits?.patients)
    .map((io) => ({
      id: io.id,
      name: io.name,
      eye: io.eye,
      status: io.status,
      patient: io.encounters.visits.patients,
      payment: paymentInfo(io),
    }));
}


// ── WORKSPACE: single order detail, with patient/doctor context ──
export async function getInvestigationDetail(id, viewOnly) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(first_name, last_name, uhid, age, gender)))')
    .eq('id', id)
    .single();

  if (error) return { error: error.message };

  // Opening the order to work on it (not just viewing) is the "start" --
  // no separate button needed. Timestamped with whoever opened it.
  if (!viewOnly && data.status === 'Ordered') {
    const { data: userData } = await supabase.auth.getUser();
    const startedAt = new Date().toISOString();
    await supabase.from('investigation_orders').update({
      status: 'In Progress', started_at: startedAt, started_by: userData?.user?.id || null,
    }).eq('id', id);
    data.status = 'In Progress';
    data.started_at = startedAt;
    data.started_by = userData?.user?.id || null;
  }

  let doctorName = '--';
  if (data.encounters?.doctor_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', data.encounters.doctor_id).maybeSingle();
    doctorName = doc?.full_name || '--';
  }

  let startedByName = null;
  if (data.started_by) {
    const { data: tech } = await supabase.from('profiles').select('full_name').eq('id', data.started_by).maybeSingle();
    startedByName = tech?.full_name || null;
  }

  return { order: data, doctorName, startedByName };
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({ status: 'In Progress' })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_started', { name: order?.name });
  return { success: true };
}

// Persists whatever's been entered so far without changing status --
// technician can leave and resume later, patient stays in the queue.
export async function saveInvestigationDraft(id, resultData, remarks) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('investigation_orders')
    .update({ result_data: resultData, result_notes: remarks })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, resultData, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { data: order, error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_data: resultData,
      result_notes: remarks || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id)
    .select('name, encounters(visit_id)')
    .single();
  if (error) return { error: error.message };
  // This is the moment that actually matters for the patient's timeline
  // -- results are entered and they're walking back to the doctor with
  // the report. Verification (below) is a separate QA checklist step
  // that can happen much later, sometimes by someone else entirely, so
  // it shouldn't be what closes out "In Investigation" time.
  await logJourneyEvent(supabase, order?.encounters?.visit_id, 'investigation_completed', { name: order?.name });
  return { success: true };
}

// Verification is the gate between "technically done" and "visible to
// the doctor" -- status jumps straight to Available once every checklist
// item is confirmed (there's no separate persisted "Verified" state;
// it's a visual timeline step on the way to Available).
// Same "combine, don't overwrite" logic doctorSendOut uses -- a patient
// can be Awaiting more than one thing at once, so resolving Investigation
// should only clear that part, not silently blow away Biometry/Dilation
// if they're still pending.
async function resolveAwaitingPart(supabase, visitId, part) {
  if (!visitId) return;
  const { data: entry } = await supabase
    .from('queue_entries').select('id, status')
    .eq('visit_id', visitId).eq('department', 'Doctor')
    .order('issued_at', { ascending: false }).limit(1).maybeSingle();
  if (!entry || !entry.status?.startsWith('Awaiting')) return;

  const remaining = entry.status.replace('Awaiting ', '').split(' & ').filter((l) => l !== part);
  const newStatus = remaining.length > 0 ? `Awaiting ${remaining.join(' & ')}` : 'Ready for Review';
  await supabase.from('queue_entries').update({ status: newStatus }).eq('id', entry.id);
}

export async function verifyInvestigation(id, checklist) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const allChecked = Object.values(checklist).every(Boolean) && Object.keys(checklist).length > 0;
  if (!allChecked) return { error: 'All verification items must be checked before verifying.' };

  const { data: order } = await supabase.from('investigation_orders').select('name, encounter_id, encounters(visit_id)').eq('id', id).maybeSingle();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Available',
      verification_checklist: checklist,
      verified_by: userData?.user?.id || null,
      verified_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };

  await resolveAwaitingPart(supabase, order?.encounters?.visit_id, 'Investigation');

  return { success: true };
}

export async function markUnableToPerform(id, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  const { error } = await supabase
    .from('investigation_orders')
    .update({ status: 'Cancelled', unable_reason: reason })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FRONT OFFICE BILLING QUEUE ──
// Every investigation lands here the moment it's ordered from
// Consultation, regardless of lab status -- Front Office bills as soon
// as the doctor orders it, it doesn't wait on the lab. Grouped by visit
// the same way the lab's own Queue screen is, so it reads the same way.
export async function getPendingInvestigationBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, visit_number, patients(id, first_name, last_name, uhid, mobile)))')
    .in('billing_status', ['Pending', 'Deferred'])
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  (data || []).forEach((io) => {
    const visitId = io.encounters?.visit_id;
    const visit = io.encounters?.visits;
    if (!visitId || !visit) return;
    if (!groups[visitId]) {
      groups[visitId] = { visitId, visitNumber: visit.visit_number, patient: visit.patients, items: [] };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

async function setInvestigationBillingStatus(id, billingStatus, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('investigation_orders')
    .update({
      billing_status: billingStatus,
      billing_note: note || null,
      billing_updated_by: userData?.user?.id || null,
      billing_updated_at: new Date().toISOString(),
    })
    .eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationDenied(id, note) {
  return setInvestigationBillingStatus(id, 'Denied', note);
}

export async function markInvestigationDeferred(id, note) {
  return setInvestigationBillingStatus(id, 'Deferred', note);
}

// Undo a Denied/Deferred mark -- puts it back in the Front Office queue.
export async function resetInvestigationBilling(id) {
  return setInvestigationBillingStatus(id, 'Pending', null);
}

// ── HISTORY ──
// Every investigation ever ordered, regardless of status -- filtering
// happens client-side (patient/type dropdowns) since a single-hospital
// dataset is small enough that a broad fetch is simpler and fast enough,
// same approach the rest of this module already takes.
export async function getInvestigationHistory(fromDate, toDate) {
  const supabase = await createClient();
  let query = supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, doctor_id, visits(id, visit_number, patients(id, first_name, last_name, uhid)))')
    .order('created_at', { ascending: false })
    .limit(500);

  // Applied before the row cap so a date range reaches further back
  // than the default "most recent 500" would otherwise allow.
  if (fromDate) query = query.gte('created_at', `${fromDate}T00:00:00`);
  if (toDate) query = query.lte('created_at', `${toDate}T23:59:59`);

  const { data, error } = await query;
  if (error) return { error: error.message };

  const doctorIds = (data || []).map((o) => o.encounters?.doctor_id).filter(Boolean);
  const staffIds = (data || []).flatMap((o) => [o.completed_by, o.verified_by]).filter(Boolean);
  const allIds = [...new Set([...doctorIds, ...staffIds])];

  let profileMap = {};
  if (allIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', allIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }

  const rows = (data || []).map((o) => ({
    ...o,
    doctorName: profileMap[o.encounters?.doctor_id] || '--',
    performedByName: profileMap[o.verified_by] || profileMap[o.completed_by] || '--',
  }));

  return { rows };
}

// ── LONGITUDINAL COMPARISON ──
export async function searchPatientsForInvestigation(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getInvestigationComparisonData(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters!inner(id, visit_id, visits!inner(id, patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .in('status', ['Completed', 'Available'])
    .order('created_at', { ascending: true });
  if (error) return { error: error.message };
  return { rows: data || [] };
}

// ── REPORTS ──
export async function getInvestigationReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const fromIso = `${fromDate}T00:00:00`;
  const toIso = `${toDate}T23:59:59`;

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, doctor_id, visits(id, patients(first_name, last_name, uhid)))')
    .gte('created_at', fromIso)
    .lte('created_at', toIso)
    .order('created_at', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  const doctorIds = [...new Set((data || []).map((o) => o.encounters?.doctor_id).filter(Boolean))];
  let profileMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const doctorName = (o) => profileMap[o.encounters?.doctor_id] || '--';
  const patientName = (o) => {
    const p = o.encounters?.visits?.patients;
    return p ? `${p.first_name} ${p.last_name} (${p.uhid})` : '--';
  };

  if (reportId === 'register') {
    return {
      title: 'Daily Investigation Register',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: (data || []).map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'type_summary') {
    const counts = {};
    (data || []).forEach((o) => {
      const n = (o.name || '').toLowerCase();
      const type = n.includes('oct') ? 'OCT' : (n.includes('visual field') || n.includes(' vf')) ? 'Visual Field' : n.includes('fundus') ? 'Fundus Photography' : 'External Report';
      counts[type] = (counts[type] || 0) + 1;
    });
    return {
      title: 'Investigation Type Summary',
      headers: ['Type', 'Count'],
      rows: Object.entries(counts).map(([type, count]) => ({ cols: [type, count] })),
    };
  }

  if (reportId === 'pending') {
    const pending = (data || []).filter((o) => o.status === 'Ordered' || o.status === 'In Progress');
    return {
      title: 'Pending Investigations',
      headers: ['Date', 'Patient', 'Investigation', 'Eye', 'Status', 'Doctor'],
      rows: pending.map((o) => ({
        cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.eye, o.status, doctorName(o)],
      })),
    };
  }

  if (reportId === 'quality') {
    const cancelled = (data || []).filter((o) => o.status === 'Cancelled');
    const total = (data || []).length;
    const rows = cancelled.map((o) => ({
      cols: [new Date(o.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }), patientName(o), o.name, o.unable_reason || '--'],
    }));
    rows.push({ cols: [`Total ordered in period: ${total}`, `Unable to perform: ${cancelled.length}`, '', ''] });
    return {
      title: 'Quality Report -- Unable to Perform',
      headers: ['Date', 'Patient', 'Investigation', 'Reason'],
      rows,
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

__VEDA_FILE_3_END__

cat > "app/(main)/investigation/history/page.js" << '__VEDA_FILE_4_END__'
'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationHistory } from '../actions';
import { matchInvestigationType, summarizeResultData } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';
import { openPrintPopup } from '@/lib/printPopup';

const STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

const SORT_OPTIONS = [
  { value: 'date_desc', label: 'Newest first' },
  { value: 'date_asc', label: 'Oldest first' },
  { value: 'patient_asc', label: 'Patient (A-Z)' },
  { value: 'status', label: 'Status' },
];

function patientLabel(r) {
  const p = r.encounters?.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : '';
}

// Biometry rows here come from the investigation_orders copy that
// mirrors status for the doctor's OPD list -- the actual record lives
// in the Biometry module, so route there instead of the plain
// Investigation workspace.
function isBiometryName(name) {
  return (name || '').trim().toLowerCase() === 'biometry';
}

export default function InvestigationHistoryPage() {
  const [rows, setRows] = useState([]);
  const [patientFilter, setPatientFilter] = useState('');
  const [typeFilter, setTypeFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [sortBy, setSortBy] = useState('date_desc');
  const [loading, setLoading] = useState(true);
  const router = useRouter();

  const refresh = useCallback(async (from, to) => {
    setLoading(true);
    const result = await getInvestigationHistory(from || undefined, to || undefined);
    setLoading(false);
    setRows(result.rows || []);
  }, []);

  useEffect(() => { refresh(fromDate, toDate); }, [fromDate, toDate, refresh]);

  function clearDates() {
    setFromDate('');
    setToDate('');
  }

  const patients = useMemo(() => {
    const map = new Map();
    rows.forEach((r) => {
      const p = r.encounters?.visits?.patients;
      if (p && !map.has(p.id)) map.set(p.id, p);
    });
    return [...map.values()];
  }, [rows]);

  const filtered = useMemo(() => {
    const result = rows.filter((r) => {
      if (patientFilter && r.encounters?.visits?.patients?.id !== patientFilter) return false;
      if (typeFilter && matchInvestigationType(r.name) !== typeFilter) return false;
      return true;
    });

    const sorted = [...result];
    if (sortBy === 'date_desc') sorted.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    else if (sortBy === 'date_asc') sorted.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    else if (sortBy === 'patient_asc') sorted.sort((a, b) => patientLabel(a).localeCompare(patientLabel(b)));
    else if (sortBy === 'status') sorted.sort((a, b) => a.status.localeCompare(b.status));
    return sorted;
  }, [rows, patientFilter, typeFilter, sortBy]);

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Investigation History</div>
        </div>
        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
          <div>
            <label className="flbl">From</label>
            <input type="date" className="fi" style={{ width: 150 }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">To</label>
            <input type="date" className="fi" style={{ width: 150 }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
          </div>
          {(fromDate || toDate) && (
            <button className="btn btn-sm" style={{ alignSelf: 'flex-end' }} onClick={clearDates}>
              <i className="ti ti-x"></i> Clear dates
            </button>
          )}
          <div style={{ marginLeft: 'auto', display: 'flex', gap: 8, alignSelf: 'flex-end' }}>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={patientFilter} onChange={(e) => setPatientFilter(e.target.value)}>
              <option value="">All patients</option>
              {patients.map((p) => <option key={p.id} value={p.id}>{p.first_name} {p.last_name} -- {p.uhid}</option>)}
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
              <option value="">All types</option>
              <option value="OCT">OCT</option>
              <option value="Visual Field">Visual Field</option>
              <option value="Fundus Photography">Fundus Photography</option>
              <option value="External Report">External Report</option>
            </select>
            <select className="fi" style={{ width: 'auto', padding: '7px 10px', fontSize: 12 }} value={sortBy} onChange={(e) => setSortBy(e.target.value)}>
              {SORT_OPTIONS.map((s) => <option key={s.value} value={s.value}>Sort: {s.label}</option>)}
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <table className="tbl">
          <thead>
            <tr><th>Date/Time</th><th>Patient</th><th>Investigation</th><th>Eye</th><th>Key values</th><th>Status</th><th>Doctor</th><th>Performed by</th><th></th></tr>
          </thead>
          <tbody>
            {filtered.map((r) => {
              const p = r.encounters?.visits?.patients;
              const type = matchInvestigationType(r.name);
              const isBiometry = isBiometryName(r.name);
              const href = isBiometry ? '/biometry' : `/investigation/${r.id}`;
              return (
                <tr key={r.id} onClick={() => router.push(href)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                  <td>
                    <strong>{p?.first_name} {p?.last_name}</strong>
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{p?.uhid}</span>
                  </td>
                  <td style={{ fontWeight: 600 }}>{r.name}</td>
                  <td><span className="badge b-blue" style={{ fontSize: 10 }}>{r.eye}</span></td>
                  <td style={{ fontSize: 11, color: 'var(--g600)' }}>{isBiometry ? '--' : summarizeResultData(type, r.result_data)}</td>
                  <td><span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`}>{r.status}</span></td>
                  <td style={{ fontSize: 11 }}>{r.doctorName}</td>
                  <td style={{ fontSize: 11, color: 'var(--g400)' }}>{r.performedByName}</td>
                  <td style={{ display: 'flex', gap: 4 }}>
                    <a
                      href={href}
                      onClick={(e) => { e.stopPropagation(); router.push(href); }}
                      className="btn"
                      style={{ padding: '3px 8px', fontSize: 11, textDecoration: 'none' }}
                      title={isBiometry ? 'Open Biometry' : 'View'}
                    >
                      <i className={`ti ${isBiometry ? 'ti-ruler-measure' : 'ti-eye'}`}></i>
                    </a>
                    {!isBiometry && ['Completed', 'Verified', 'Available'].includes(r.status) && (
                      <button
                        onClick={(e) => { e.stopPropagation(); openPrintPopup(`/investigation-print/${r.id}`); }}
                        className="btn"
                        style={{ padding: '3px 8px', fontSize: 11 }}
                        title="Print / PDF"
                      >
                        <i className="ti ti-printer"></i>
                      </button>
                    )}
                  </td>
                </tr>
              );
            })}
            {!loading && filtered.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No records found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

__VEDA_FILE_4_END__

cat > "app/(main)/investigation/page.js" << '__VEDA_FILE_5_END__'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvestigationQueue, getTodaysInvestigations } from './actions';
import InvestigationTabs from './investigation-tabs';
import { openPrintPopup } from '@/lib/printPopup';

const PRIORITY_BADGE = { Urgent: 'b-red', Routine: 'b-gray' };

// Same type-matching heuristic as the workspace uses -- kept in sync
// so the Queue's type filter and badges agree with what the workspace
// will actually render when opened.
function matchType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) return 'OCT';
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) return 'Visual Field';
  if (n.includes('fundus')) return 'Fundus Photography';
  if (n.includes('pachymetry')) return 'Pachymetry';
  return 'External Report';
}

const TYPE_ICON = { OCT: 'ti-eye', 'Visual Field': 'ti-activity', 'Fundus Photography': 'ti-camera', Pachymetry: 'ti-ruler', 'External Report': 'ti-file-import', Biometry: 'ti-ruler-measure' };

// Biometry is ordered through the regular Investigations panel (so it
// shows up here like anything else) but is fulfilled through its own
// dedicated module, not the plain investigation workspace -- any row
// named "Biometry" routes to /biometry instead of /investigation/[id].
function isBiometryName(name) {
  return (name || '').trim().toLowerCase() === 'biometry';
}
function investigationHref(r) {
  return isBiometryName(r.name) ? '/biometry' : `/investigation/${r.id}`;
}

// Investigation and Biometry use different status vocabularies
// (Ordered/In Progress/... vs Awaiting Biometry/Measured/Calculated),
// so the Queue badge needs to know which one it's looking at.
const STATUS_BADGE = {
  investigation: { 'In Progress': 'b-blue' },
  biometry: { 'Awaiting Biometry': 'b-amber', Measured: 'b-blue', Calculated: 'b-purple' },
};
function statusBadgeClass(item) {
  return STATUS_BADGE[item.kind]?.[item.status] || 'b-amber';
}

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function InvestigationPage() {
  const [groups, setGroups] = useState([]);
  const [stats, setStats] = useState({ ordered: 0, inProgress: 0, availableToday: 0, totalToday: 0 });
  const [typeFilter, setTypeFilter] = useState('');
  const [todaysInvestigations, setTodaysInvestigations] = useState([]);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvestigationQueue();
    setGroups(result.groups);
    setStats(result.stats);
    setTodaysInvestigations(await getTodaysInvestigations());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  const filteredGroups = typeFilter
    ? groups.map((g) => ({ ...g, items: g.items.filter((i) => (i.kind === 'biometry' ? 'Biometry' : matchType(i.name)) === typeFilter) })).filter((g) => g.items.length > 0)
    : groups;

  const todaysPending = todaysInvestigations.filter((r) => ['Ordered', 'In Progress'].includes(r.status));
  const todaysCompleted = todaysInvestigations.filter((r) => ['Completed', 'Available', 'Verified'].includes(r.status));

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Ordered" value={stats.ordered} sub="Awaiting performance" color="var(--teal)" />
        <KpiCard label="In progress" value={stats.inProgress} sub="Currently being done" color="var(--amber)" />
        <KpiCard label="Verified today" value={stats.availableToday} sub="Available for review" color="var(--green)" />
        <KpiCard label="Total today" value={stats.totalToday} sub="All investigations" color="var(--blue)" />
      </div>

      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Today&apos;s Pending
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{todaysPending.length}</span>
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Patient Name</th><th>Investigation</th><th>Status</th><th>Billing Status</th><th></th></tr>
          </thead>
          <tbody>
            {todaysPending.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{r.patient?.first_name} {r.patient?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.patient?.uhid}</span>
                </td>
                <td style={{ fontWeight: 600 }}>{r.name} <span style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 400 }}>({r.eye})</span></td>
                <td><span className="badge b-amber">{r.status}</span></td>
                <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                <td>
                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(investigationHref(r))} title={isBiometryName(r.name) ? 'Open Biometry' : 'View'}>
                    <i className={`ti ${isBiometryName(r.name) ? 'ti-ruler-measure' : 'ti-eye'}`}></i>
                  </button>
                </td>
              </tr>
            ))}
            {todaysPending.length === 0 && (
              <tr><td colSpan={5} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Nothing pending from today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Today&apos;s Completed
          <span className="badge b-green" style={{ marginLeft: 8 }}>{todaysCompleted.length}</span>
        </div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still viewable/printable from here today.</div>
        <table className="tbl">
          <thead>
            <tr><th>Patient Name</th><th>Investigation</th><th>Billing Status</th><th></th></tr>
          </thead>
          <tbody>
            {todaysCompleted.map((r) => (
              <tr key={r.id}>
                <td>
                  <strong>{r.patient?.first_name} {r.patient?.last_name}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{r.patient?.uhid}</span>
                </td>
                <td style={{ fontWeight: 600 }}>{r.name} <span style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 400 }}>({r.eye})</span></td>
                <td><span className={`badge ${r.payment?.badge || 'b-gray'}`}>{r.payment?.label || 'Unbilled'}</span></td>
                <td style={{ display: 'flex', gap: 4 }}>
                  <button className="btn" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => router.push(investigationHref(r))} title={isBiometryName(r.name) ? 'Open Biometry' : 'View'}>
                    <i className={`ti ${isBiometryName(r.name) ? 'ti-ruler-measure' : 'ti-eye'}`}></i>
                  </button>
                  {!isBiometryName(r.name) && (
                    <button
                      onClick={() => openPrintPopup(`/investigation-print/${r.id}`)}
                      className="btn"
                      style={{ padding: '3px 8px', fontSize: 11 }}
                      title="Print / PDF"
                    >
                      <i className="ti ti-printer"></i>
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {todaysCompleted.length === 0 && (
              <tr><td colSpan={4} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Nothing completed yet today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--teal)' }}></i> Investigation Queue <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(all pending, any date)</span></div>
          <select className="fi" style={{ width: 'auto', padding: '5px 8px', fontSize: 11 }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
            <option value="">All types</option>
            <option value="OCT">OCT</option>
            <option value="Visual Field">Visual Field</option>
            <option value="Fundus Photography">Fundus Photography</option>
            <option value="Pachymetry">Pachymetry</option>
            <option value="External Report">External Report</option>
            <option value="Biometry">Biometry</option>
          </select>
        </div>
      </div>

      {filteredGroups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 12 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-user" style={{ color: 'var(--purple)' }}></i>
            {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
          </div>
          {g.items.map((item) => {
            const type = item.kind === 'biometry' ? 'Biometry' : matchType(item.name);
            const href = item.kind === 'biometry' ? `/biometry/${item.id}` : `/investigation/${item.id}`;
            return (
              <div
                key={item.id}
                onClick={() => router.push(href)}
                style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
              >
                <i className={`ti ${TYPE_ICON[type] || 'ti-flask'}`} style={{ color: item.kind === 'biometry' ? 'var(--indigo)' : 'var(--teal)', fontSize: 16 }}></i>
                <div style={{ flex: 1 }}>
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{item.name}</span>
                  <span style={{ fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>{item.eye}</span>
                </div>
                <span className={`badge ${PRIORITY_BADGE[item.priority] || 'b-gray'}`}>{item.priority}</span>
                <span className={`badge ${statusBadgeClass(item)}`}>{item.status}</span>
                <span className={`badge ${item.payment?.badge || 'b-gray'}`}>{item.payment?.label || 'Unbilled'}</span>
                <button className="btn btn-sm btn-primary"><i className={`ti ${item.kind === 'biometry' ? 'ti-ruler-measure' : 'ti-flask'}`}></i> Open</button>
              </div>
            );
          })}
        </div>
      ))}

      {filteredGroups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

__VEDA_FILE_5_END__

cat > "app/(main)/iol-approval/actions.js" << '__VEDA_FILE_6_END__'
'use server';

import { createClient } from '@/lib/supabase-server';

// The surgeon's sign-off on the specific IOL brand/model/power to
// actually use for a surgical case -- separate from Biometry (which
// just records the device's raw recommendations) and Counselling
// (which picks the billing package/category). Eye comes from
// surgical_cases.eye (set by the doctor); power comes from whichever
// brand row in biometry_iol_recommendations the surgeon picks.

// ── QUEUE: cases needing approval ──────────────────────────────────
// A case needs this once biometry is Measured for the patient and
// there's no Approved iol_approvals row yet for the case.
export async function getPendingIolApprovals() {
  const supabase = await createClient();

  const { data: cases, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name, iol_category)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .neq('biometry_required', false);
  if (error) return [];

  const patientIds = [...new Set((cases || []).map((c) => c.patient_id).filter(Boolean))];
  if (patientIds.length === 0) return [];

  const { data: measured } = await supabase
    .from('biometry_records')
    .select('id, patient_id')
    .in('patient_id', patientIds)
    .eq('status', 'Measured');
  const measuredByPatient = {};
  (measured || []).forEach((m) => { measuredByPatient[m.patient_id] = m.id; });

  const caseIds = (cases || []).map((c) => c.id);
  const { data: approvals } = await supabase
    .from('iol_approvals')
    .select('surgical_case_id, status')
    .in('surgical_case_id', caseIds);
  const approvalByCase = {};
  (approvals || []).forEach((a) => { approvalByCase[a.surgical_case_id] = a.status; });

  return (cases || [])
    .filter((c) => measuredByPatient[c.patient_id] && approvalByCase[c.id] !== 'Approved')
    .map((c) => ({
      caseId: c.id,
      patient: c.patients,
      procedureName: c.procedure_name,
      eye: c.eye,
      packageName: c.master_packages?.name || null,
      biometryRecordId: measuredByPatient[c.patient_id],
      approvalStatus: approvalByCase[c.id] || 'Pending',
    }));
}

export async function getApprovedToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const startUTC = new Date(`${todayIst}T00:00:00+05:30`).toISOString();
  const endUTC = new Date(`${todayIst}T23:59:59.999+05:30`).toISOString();

  const { data, error } = await supabase
    .from('iol_approvals')
    .select('*, surgical_cases(id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name)), master_iol_catalog(brand, model)')
    .eq('status', 'Approved')
    .gte('approved_at', startUTC)
    .lte('approved_at', endUTC)
    .order('approved_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((a) => a.surgical_cases);
}

// ── DETAIL: a case's recommendation table + current approval ──────
export async function getIolApprovalDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid, age, gender), master_packages:package_id(name, iol_category)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: biometry } = await supabase
    .from('biometry_records')
    .select('id, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .eq('status', 'Measured')
    .order('updated_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recommendations = [];
  if (biometry) {
    const { data } = await supabase
      .from('biometry_iol_recommendations')
      .select('*, master_iol_catalog(id, brand, model, manufacturer, category)')
      .eq('biometry_record_id', biometry.id)
      .order('created_at', { ascending: true });
    recommendations = data || [];
  }

  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  return { case: sc, biometry, recommendations, approval: approval || null };
}

// ── APPROVE ─────────────────────────────────────────────────────────
export async function approveIol(caseId, biometryRecordId, iolCatalogId, power, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  if (approverProfile?.designation !== 'Doctor') return { error: 'Only a doctor can approve an IOL.' };

  const { data: sc } = await supabase.from('surgical_cases').select('eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!iolCatalogId) return { error: 'Select an IOL brand/model.' };
  if (!power) return { error: 'Power is required.' };

  const { data: existing } = await supabase.from('iol_approvals').select('id').eq('surgical_case_id', caseId).maybeSingle();

  const payload = {
    surgical_case_id: caseId, biometry_record_id: biometryRecordId, iol_catalog_id: iolCatalogId,
    eye: sc.eye, power, surgeon_id: userData?.user?.id || null, status: 'Approved',
    approved_at: new Date().toISOString(), notes: notes || null, updated_at: new Date().toISOString(),
  };

  const { error } = existing
    ? await supabase.from('iol_approvals').update(payload).eq('id', existing.id)
    : await supabase.from('iol_approvals').insert(payload);
  if (error) return { error: error.message };
  return { success: true };
}
__VEDA_FILE_6_END__

cat > "app/(main)/iol-approval/page.js" << '__VEDA_FILE_7_END__'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingIolApprovals, getApprovedToday, getIolApprovalDetail, approveIol } from './actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function ApproveModal({ item, onClose, onDone }) {
  const [detail, setDetail] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [catalogId, setCatalogId] = useState('');
  const [power, setPower] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getIolApprovalDetail(item.caseId).then(setDetail);
    getActiveIolCatalog().then(setCatalog);
  }, [item.caseId]);

  // Pre-fill from the existing approval when re-opening to revise it --
  // otherwise Edit silently opened a blank form and looked like nothing
  // could be changed.
  useEffect(() => {
    if (detail?.approval) {
      setCatalogId(detail.approval.iol_catalog_id || '');
      setPower(detail.approval.power || '');
      setNotes(detail.approval.notes || '');
    }
  }, [detail]);

  const eyeKey = item.eye === 'OD' ? 're_power' : item.eye === 'OS' ? 'le_power' : null;

  function pickRecommendation(rec) {
    setCatalogId(rec.master_iol_catalog.id);
    setPower(eyeKey ? (rec[eyeKey] ?? '') : '');
  }

  // Flags when the doctor's choice doesn't match any device
  // recommendation on file -- either a brand/model with no
  // recommendation row at all, or a power that differs from what the
  // device recommended for this eye. A genuine clinical call either
  // way, but worth surfacing rather than silently letting it slide.
  const matchingRec = catalogId ? detail?.recommendations.find((r) => r.master_iol_catalog.id === catalogId) : null;
  const recommendedPower = matchingRec && eyeKey ? matchingRec[eyeKey] : null;
  const deviatesNoRec = !!catalogId && !matchingRec && (detail?.recommendations.length || 0) > 0;
  const deviatesPower = !!matchingRec && !!power && recommendedPower != null && String(power).trim() !== String(recommendedPower).trim();
  const deviates = deviatesNoRec || deviatesPower;

  async function handleApprove() {
    setError('');
    if (!detail?.biometry) { setError('No measured biometry on file for this patient.'); return; }
    setSaving(true);
    const result = await approveIol(item.caseId, detail.biometry.id, catalogId, power, notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100, padding: 16 }} onClick={onClose}>
      <div className="card" style={{ width: 520, maxWidth: '95vw', maxHeight: '90vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        <div className="card-head" style={{ marginBottom: 4, alignItems: 'flex-start' }}>
          <div className="card-title">
            <i className="ti ti-lens" style={{ color: 'var(--indigo)' }}></i> {detail?.approval ? 'Revise IOL Approval' : 'IOL Approval'}
          </div>
          {detail?.biometry && (
            <a href={`/biometry/${detail.biometry.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-file-report"></i> View Biometry Report
            </a>
          )}
        </div>
        <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 12 }}>
          {item.patient?.first_name} {item.patient?.last_name} ({item.patient?.uhid}) -- {item.procedureName} -- {EYE_LABEL[item.eye] || item.eye}
          {item.packageName && <> -- Package: {item.packageName}</>}
        </div>

        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

        {!detail ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)' }}>Loading...</div>
        ) : !detail.biometry ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--red)' }}>No measured biometry on file for this patient.</div>
        ) : (
          <>
            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Device Recommendations</div>
            {detail.recommendations.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 10 }}>No recommendations recorded on the biometry report.</div>
            )}
            <table className="tbl" style={{ marginBottom: 14 }}>
              <thead><tr><th>Brand / Model</th><th>RE</th><th>LE</th><th></th></tr></thead>
              <tbody>
                {detail.recommendations.map((r) => (
                  <tr key={r.id} style={{ background: catalogId === r.master_iol_catalog.id ? 'var(--indigo-lt, var(--blue-lt))' : 'transparent' }}>
                    <td>{r.master_iol_catalog.brand} {r.master_iol_catalog.model}</td>
                    <td>{r.re_power ?? '--'}</td>
                    <td>{r.le_power ?? '--'}</td>
                    <td>
                      <button className="btn btn-sm" onClick={() => pickRecommendation(r)}>
                        {catalogId === r.master_iol_catalog.id ? <i className="ti ti-check"></i> : 'Use this'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Confirm Choice for {EYE_LABEL[item.eye] || item.eye}</div>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
                <option value="">Select brand/model...</option>
                {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
              </select>
              <input className="fi fi-sm" placeholder="Power" value={power} onChange={(e) => setPower(e.target.value)} />
            </div>

            {deviates && (
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11.5, marginBottom: 10 }}>
                <i className="ti ti-alert-triangle"></i>{' '}
                {deviatesNoRec
                  ? 'This brand/model has no device recommendation on file for this patient -- deviating from the biometry report.'
                  : `Device recommended ${recommendedPower ?? '--'} D for ${EYE_LABEL[item.eye] || item.eye}, but ${power} D is being approved -- deviating from the biometry report.`}
              </div>
            )}

            <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={onClose}>Cancel</button>
              <button className="btn btn-primary" onClick={handleApprove} disabled={saving || !catalogId || !power}>
                {saving ? 'Saving...' : detail?.approval ? 'Update Approval' : 'Approve'}
              </button>
            </div>
          </>
        )}
      </div>
    </div>
  );
}

export default function IolApprovalPage() {
  const [pending, setPending] = useState([]);
  const [approvedToday, setApprovedToday] = useState([]);
  const [loading, setLoading] = useState(true);
  const [approving, setApproving] = useState(null);

  const refresh = useCallback(async () => {
    const [pendingList, approvedList] = await Promise.all([getPendingIolApprovals(), getApprovedToday()]);
    setPending(pendingList);
    setApprovedToday(approvedList);
    setLoading(false);
  }, []);

  // Same live-queue pattern used elsewhere (Queue, OT Intraop, etc) --
  // without this, an approval made by someone else, or just leaving
  // this tab open, never shows up until a manual hard refresh.
  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>IOL Approval</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>The surgeon's final sign-off on which IOL brand/model/power to actually use, per case.</div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Pending Approval
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pending.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && pending.map((item) => (
          <div key={item.caseId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {item.patient?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{item.patient?.first_name} {item.patient?.last_name}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[item.eye] || item.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {item.patient?.uhid} -- {item.procedureName}{item.packageName ? ` -- ${item.packageName}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => setApproving(item)}>
              <i className="ti ti-lens"></i> Approve
            </button>
          </div>
        ))}
        {!loading && pending.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing pending approval.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Approved Today</div>
        {approvedToday.map((a) => (
          <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {a.surgical_cases?.patients?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{a.surgical_cases?.patients?.first_name} {a.surgical_cases?.patients?.last_name}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              </div>
            </div>
            <button
              className="btn btn-sm"
              onClick={() => setApproving({
                caseId: a.surgical_case_id,
                patient: a.surgical_cases?.patients,
                procedureName: a.surgical_cases?.procedure_name,
                eye: a.eye,
                packageName: a.surgical_cases?.master_packages?.name || null,
              })}
            >
              <i className="ti ti-edit"></i> Edit
            </button>
          </div>
        ))}
        {approvedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>

      {approving && (
        <ApproveModal item={approving} onClose={() => setApproving(null)} onDone={() => { setApproving(null); refresh(); }} />
      )}
    </div>
  );
}
__VEDA_FILE_7_END__

cat > "app/(main)/medical-fitness/page.js" << '__VEDA_FILE_8_END__'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getMedicalFitnessQueue, getMedicalFitnessHistory, getMedicalFitnessDetail,
  getInvestigationMasterOptions, orderFitnessInvestigation, removeFitnessInvestigation,
  clearFitness, markNotFit,
} from './actions';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { openPopup } from '@/lib/popup';

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };
const HISTORY_STATUS_BADGE = { Cleared: 'b-green', 'Not Fit': 'b-red' };
const TIMELINE_TYPE_COLOR = { Visit: 'var(--blue)', Diagnosis: 'var(--red)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--amber)' };
const TIMELINE_TYPE_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };

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
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
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
              <span style={{ fontWeight: 700, fontSize: 13 }}>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</span>
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
      `${r.visits?.patients?.first_name} ${r.visits?.patients?.last_name}`.toLowerCase().includes(q) ||
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
                  <strong>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</strong>
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

  const [timeline, setTimeline] = useState(null);
  const [timelineLoading, setTimelineLoading] = useState(false);

  const [decisionNotes, setDecisionNotes] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getMedicalFitnessDetail(referralId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [referralId]);

  useEffect(() => {
    setData(null); setLoadError(''); setSubTab('summary'); setTimeline(null); setDecisionNotes('');
    refresh();
    getInvestigationMasterOptions().then(setInvOptions);
  }, [referralId, refresh]);

  useEffect(() => {
    if (subTab === 'timeline' && !timeline && data) {
      setTimelineLoading(true);
      getPatientTimeline(data.referral.visits.patients.id).then((t) => { setTimeline(t); setTimelineLoading(false); });
    }
  }, [subTab, timeline, data]);

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
    onDone();
  }

  async function handleMarkNotFit() {
    setError('');
    if (!decisionNotes.trim()) { setError('Notes are required when marking not fit.'); return; }
    setSaving(true);
    const result = await markNotFit(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { referral, currentDiagnoses, investigations, diagnosisHistory, referredByName, clearedByName } = data;
  const patient = referral.visits.patients;
  const sc = referral.surgical_cases;
  const isPending = referral.status === 'Pending Review';

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#a15c00,#d97706)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
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
            <TabButton active={subTab === 'timeline'} onClick={() => setSubTab('timeline')} icon="ti-timeline" label="Visit Timeline" />
            <TabButton active={subTab === 'investigations'} onClick={() => setSubTab('investigations')} icon="ti-flask" label={`Investigations${investigations.length > 0 ? ` (${investigations.length})` : ''}`} />
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

          {subTab === 'timeline' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Visit Timeline</div>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Every visit this patient has had. Click a Visit to open the doctor&apos;s full clinical record for it, read-only.</div>

              {timelineLoading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 16, textAlign: 'center' }}>Loading timeline...</div>}

              {!timelineLoading && timeline && (
                <div style={{ maxHeight: 420, overflowY: 'auto' }}>
                  {timeline.events.map((ev, i) => {
                    const isVisit = ev.type === 'Visit';
                    const clickable = isVisit && ev.queueEntryId;
                    return (
                      <div
                        key={i}
                        onClick={clickable ? () => window.open(`/consultation/${ev.queueEntryId}`, '_blank', 'noopener,noreferrer') : undefined}
                        style={{
                          border: clickable ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', marginBottom: 6,
                          display: 'flex', alignItems: 'center', gap: 8, cursor: clickable ? 'pointer' : 'default',
                        }}
                      >
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 10, color: 'var(--g400)', marginBottom: 2 }}>{new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</div>
                          <div style={{ fontSize: 12.5, fontWeight: 700, display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TIMELINE_TYPE_ICON[ev.type]}`} style={{ color: TIMELINE_TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>{ev.detail}</div>
                        </div>
                        {clickable && <i className="ti ti-external-link" style={{ color: 'var(--blue)' }}></i>}
                      </div>
                    );
                  })}
                  {timeline.events.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', textAlign: 'center', padding: 16 }}>No prior events.</div>}
                </div>
              )}
            </div>
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
            </div>
          )}
        </div>

        <div>
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

// ── PAGE: single SPA with client-side tab switching, matching Counselling ──
export default function MedicalFitnessPage() {
  const [queueRows, setQueueRows] = useState([]);
  const [historyRows, setHistoryRows] = useState([]);
  const [loadingQueue, setLoadingQueue] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState('queue');
  const [selectedReferralId, setSelectedReferralId] = useState(null);

  const refreshQueue = useCallback(async () => {
    setQueueRows(await getMedicalFitnessQueue());
    setLoadingQueue(false);
  }, []);
  const refreshHistory = useCallback(async () => {
    setHistoryRows(await getMedicalFitnessHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refreshQueue(); refreshHistory(); }, [refreshQueue, refreshHistory]);

  function openReferral(id) {
    setSelectedReferralId(id);
    setActiveTab('workspace');
  }

  function handleWorkspaceDone() {
    // A decision was just made -- refresh both lists (patient moves out
    // of Queue and into History) and go back to the Queue.
    refreshQueue();
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

      {activeTab === 'queue' && <QueueTab rows={queueRows} loading={loadingQueue} onOpen={openReferral} />}
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

__VEDA_FILE_8_END__

cat > "app/(main)/ot-schedule/actions.js" << '__VEDA_FILE_9_END__'
'use server';

import { createClient } from '@/lib/supabase-server';

const OT_SELECT = '*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles!ot_schedule_surgeon_id_fkey(full_name)';

// ── SCHEDULED OT -- upcoming bookings that haven't happened yet.
// Reschedulable while still in this state; once a patient checks in
// (In Progress) or the case is Completed/Cancelled, it moves to OT
// History instead. ──
export async function getScheduledOT() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select(OT_SELECT)
    .eq('status', 'Scheduled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── OT HISTORY -- everything no longer sitting in the active schedule:
// In Progress (currently in surgery), Completed, and Cancelled. ──
export async function getOTHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select(OT_SELECT)
    .in('status', ['In Progress', 'Completed', 'Cancelled'])
    .order('scheduled_date', { ascending: false });
  if (error) return [];
  return data || [];
}

// Reuses the same capacity-checked availability RPC Counselling uses to
// book a slot in the first place, so the reschedule picker shows the
// same real-time remaining-slot info.
export async function getOTAvailability(date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_ot_availability', { p_date: date });
  if (error) return [];
  return data || [];
}

// ── MONTH SUMMARY -- for the calendar-view date picker (Surgical
// Journey's "Give This Date" / Reschedule). Total daily capacity is
// constant (sum of all Active sessions' capacity, sessions don't vary
// by day of week), so this just needs per-day booked counts plus the
// actual case list for each day so prior bookings are visible before
// the date is finalized. ──
export async function getOTMonthSummary(startDate, endDate) {
  const supabase = await createClient();

  const { data: sessions } = await supabase.from('master_ot_sessions').select('capacity').eq('status', 'Active');
  const dailyCapacity = (sessions || []).reduce((sum, s) => sum + (s.capacity || 0), 0);

  const { data: bookings, error } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid))')
    .gte('scheduled_date', startDate)
    .lte('scheduled_date', endDate)
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return { dailyCapacity, byDate: {} };

  const byDate = {};
  (bookings || []).forEach((b) => {
    if (!byDate[b.scheduled_date]) byDate[b.scheduled_date] = [];
    byDate[b.scheduled_date].push({
      id: b.id,
      sessionName: b.master_ot_sessions?.name || '--',
      procedureName: b.surgical_cases?.procedure_name || '--',
      eye: b.surgical_cases?.eye || '',
      patientName: b.surgical_cases?.patients ? `${b.surgical_cases.patients.first_name} ${b.surgical_cases.patients.last_name}` : '--',
      uhid: b.surgical_cases?.patients?.uhid || '',
    });
  });

  return { dailyCapacity, byDate };
}

export async function rescheduleOTSlot(otScheduleId, date, sessionId, reason) {
  const supabase = await createClient();
  if (!date) return { error: 'Pick a new date.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data, error } = await supabase.rpc('reschedule_ot_slot', {
    p_ot_schedule_id: otScheduleId,
    p_date: date,
    p_session_id: sessionId,
    p_reason: reason || null,
  });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { success: true };
}

// Kept here (moved from Counselling) since completing a booking now
// belongs to OT Schedule's own Scheduled tab, not Counselling.
export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

// Self-serve fix for an accidental Complete click, without needing a
// database intervention. Only allowed if no intraop record exists yet
// for this booking -- that's the real safety boundary: a surgery with
// actual recorded intraoperative details has genuinely happened and
// should never be silently reverted this way, only one that was marked
// Complete by mistake before ever being checked in.
export async function undoCompleteOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { data: intraop } = await supabase.from('ot_intraop_records').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (intraop) {
    return { error: 'This surgery already has recorded intraoperative details, so it cannot be undone this way. Contact your administrator if this was still marked Complete in error.' };
  }

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Scheduled' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

// ── REGISTER SURGERY DIRECTLY ──────────────────────────────────────────
// Fast-track for a surgical case that never went through today's
// Doctor -> Counselling pipeline -- a patient returning for a surgery
// that was decided a month ago (before HMIS existed), an external
// referral arriving with their own workup, or an emergency. Without
// this, such a patient's surgical_cases row never gets created, so they
// can never appear in OT Schedule no matter how many times front desk
// checks them in.
//
// Deliberately open to any signed-in staff member for now (no role
// restriction) -- there's a backlog of exactly this kind of case to
// clear. Restricting it to OT Schedule/Administrator only is a
// follow-up, not done here.
//
// This does NOT bypass biometry/fitness silently -- it reuses the exact
// same "skip with a mandatory reason" pattern Counselling already uses
// for biometry (biometry_skip_reason), extended to fitness the same way
// (fitness_skip_reason), so the case honestly records why those steps
// weren't done in this system rather than faking that they were.

export async function searchPatientsForDirectSurgery(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  if (error) return [];
  return data || [];
}

// All active packages, unfiltered by IOL category -- the normal
// Counselling picker (getPackagesForCase) filters by iol_category, but
// that comes from Biometry, which this fast-track deliberately skips.
// Staff pick the correct package directly instead.
export async function getPackagesForDirectSurgery() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return data || [];
}

export async function getSurgeonsForDirectSurgery() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name')
    .eq('designation', 'Doctor')
    .eq('status', 'Active')
    .order('full_name');
  if (error) return [];
  return data || [];
}

export async function registerSurgeryDirect(input) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { patientId, procedureName, eye, surgeonId, priority, workupNote, packageId, date, sessionId, notes } = input || {};

  if (!patientId) return { error: 'Select a patient.' };
  if (!procedureName || !procedureName.trim()) return { error: 'Enter the procedure.' };
  if (!workupNote || !workupNote.trim()) {
    return { error: 'Explain where biometry & medical fitness clearance came from (e.g. "done before HMIS", "external hospital referral -- reports attached", "emergency"). This is recorded on the case for audit purposes.' };
  }
  if (!packageId) return { error: 'Select a billing package.' };
  if (!date) return { error: 'Select a date.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  // Guard against accidentally duplicating an already-open case for this
  // patient + procedure. This bypasses the normal pipeline entirely, so
  // there's no visit_id-scoped check to lean on like markForSurgery has
  // -- check across all of this patient's open cases instead.
  const { data: existingCases } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, status')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .neq('status', 'Completed');
  const dup = (existingCases || []).find((c) => c.procedure_name?.trim().toLowerCase() === procedureName.trim().toLowerCase());
  if (dup) {
    return { error: `This patient already has an open case for ${dup.procedure_name} (${dup.status}). Use OT Schedule or Counselling to manage that one instead of creating a duplicate.` };
  }

  const trimmedNote = workupNote.trim();

  // If front desk already checked this patient in today (the normal
  // order of events -- Surgery visit created, then OT discovers no
  // matching case), attach that visit now so Recovery can show the
  // pre-approved biometry/IOL plan later if one exists. Not required --
  // recovery_episodes.visit_id is nullable specifically so this case
  // still works cleanly when no visit exists yet either way.
  const { data: openVisit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .eq('status', 'Open')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: created, error: insertError } = await supabase
    .from('surgical_cases')
    .insert({
      patient_id: patientId,
      visit_id: openVisit?.id || null,
      procedure_name: procedureName.trim(),
      eye: eye || null,
      surgeon_id: surgeonId || null,
      priority: priority || 'Routine',
      biometry_required: false,
      biometry_skip_reason: trimmedNote,
      fitness_required: false,
      fitness_skip_reason: trimmedNote,
      decision: 'Accepted',
      decision_locked: true,
      package_id: packageId,
      package_locked: true,
      status: 'Ready for Scheduling',
      notes: notes?.trim() || null,
    })
    .select('id')
    .single();

  if (insertError) return { error: insertError.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: created.id,
    note: `Case registered directly, bypassing Doctor/Counselling -- ${trimmedNote}`,
    created_by: userData?.user?.id || null,
  });

  // Reuses the exact same booking RPC Counselling uses -- same capacity
  // checks, same ot_schedule row shape, nothing duplicated.
  const { data: bookResult, error: bookError } = await supabase.rpc('book_ot_slot', {
    p_case_id: created.id,
    p_date: date,
    p_session_id: sessionId,
    p_surgeon_id: surgeonId || null,
    p_notes: notes?.trim() || null,
  });
  if (bookError) return { error: bookError.message, caseId: created.id };
  if (bookResult?.error) return { error: bookResult.error, caseId: created.id };

  return { success: true, caseId: created.id, otScheduleId: bookResult.ot_schedule_id };
}
__VEDA_FILE_9_END__

cat > "app/(main)/ot-schedule/page.js" << '__VEDA_FILE_10_END__'
'use client';

import { useState, useEffect, useCallback, Fragment, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  getScheduledOT, getOTHistory, getOTAvailability, getOTMonthSummary, rescheduleOTSlot, completeOT, undoCompleteOT,
  searchPatientsForDirectSurgery, getPackagesForDirectSurgery, getSurgeonsForDirectSurgery, registerSurgeryDirect,
} from './actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';

const STATUS_BADGE = { Scheduled: 'b-blue', 'In Progress': 'b-amber', Completed: 'b-green', Cancelled: 'b-red' };
const DOW = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function toISODate(d) {
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

function loadColor(count, capacity) {
  if (!capacity || count <= 0) return null;
  const ratio = count / capacity;
  if (ratio >= 1) return 'var(--red)';
  if (ratio >= 0.6) return 'var(--amber)';
  return 'var(--green)';
}

// Month-grid calendar of OT bookings. Doubles as a "picker": opened as
// a popup window from Surgical Journey with ?pickFor=<caseId>&pickLabel=..,
// clicking a date and then a session posts the choice back to the
// window that opened it and closes itself, instead of duplicating the
// booking UI in two places.
function CalendarTab() {
  const searchParams = useSearchParams();
  const pickFor = searchParams.get('pickFor');
  const pickLabel = searchParams.get('pickLabel') || '';
  const isPicker = !!pickFor;

  const today = new Date();
  const [viewYear, setViewYear] = useState(today.getFullYear());
  const [viewMonth, setViewMonth] = useState(today.getMonth());
  const [summary, setSummary] = useState({ dailyCapacity: 0, byDate: {} });
  const [loading, setLoading] = useState(true);
  const [selectedDate, setSelectedDate] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [loadingSessions, setLoadingSessions] = useState(false);

  const todayISO = toISODate(today);

  const loadMonth = useCallback(async (year, month) => {
    setLoading(true);
    const start = new Date(year, month, 1);
    const end = new Date(year, month + 1, 0);
    const result = await getOTMonthSummary(toISODate(start), toISODate(end));
    setSummary(result);
    setLoading(false);
  }, []);

  useEffect(() => { loadMonth(viewYear, viewMonth); }, [viewYear, viewMonth, loadMonth]);

  useEffect(() => {
    if (!selectedDate) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(selectedDate).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [selectedDate]);

  function changeMonth(delta) {
    let m = viewMonth + delta;
    let y = viewYear;
    if (m < 0) { m = 11; y -= 1; }
    if (m > 11) { m = 0; y += 1; }
    setViewYear(y); setViewMonth(m);
  }

  function pickSlot(session) {
    if (window.opener) {
      window.opener.postMessage({ type: 'ot-slot-picked', caseId: pickFor, date: selectedDate, sessionId: session.session_id, sessionName: session.name }, window.location.origin);
    }
    window.close();
  }

  const firstOfMonth = new Date(viewYear, viewMonth, 1);
  const startWeekday = firstOfMonth.getDay();
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < startWeekday; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  const dayBookings = selectedDate ? (summary.byDate[selectedDate] || []) : [];

  return (
    <div>
      {isPicker && (
        <div style={{ background: 'var(--indigo-lt, var(--blue-lt))', border: '1px solid var(--indigo)', borderRadius: 8, padding: '8px 12px', fontSize: 12.5, marginBottom: 14 }}>
          <i className="ti ti-calendar-plus"></i> Picking a surgery date{pickLabel ? ` for ${pickLabel}` : ''} -- pick a date, then a session, to send it back.
        </div>
      )}

      <div className="card">
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <button type="button" className="btn" onClick={() => changeMonth(-1)}><i className="ti ti-chevron-left"></i></button>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{MONTH_NAMES[viewMonth]} {viewYear}</div>
          <button type="button" className="btn" onClick={() => changeMonth(1)}><i className="ti ti-chevron-right"></i></button>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 4, marginBottom: 4 }}>
          {DOW.map((d, i) => (
            <div key={i} style={{ textAlign: 'center', fontSize: 11, fontWeight: 700, color: 'var(--g400)', padding: '3px 0' }}>{d}</div>
          ))}
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 4, opacity: loading ? 0.5 : 1 }}>
          {cells.map((day, idx) => {
            if (day === null) return <div key={`e${idx}`} />;
            const dateISO = toISODate(new Date(viewYear, viewMonth, day));
            const isPast = dateISO < todayISO;
            const bookings = summary.byDate[dateISO] || [];
            const count = bookings.length;
            const color = loadColor(count, summary.dailyCapacity);
            const isSelected = selectedDate === dateISO;

            return (
              <button
                type="button"
                key={dateISO}
                disabled={isPast}
                onClick={() => setSelectedDate(dateISO)}
                style={{
                  aspectRatio: '1', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                  border: isSelected ? '2px solid var(--teal)' : '1px solid var(--g100)',
                  borderRadius: 8, background: isSelected ? 'var(--teal-lt, var(--green-lt))' : isPast ? 'var(--g50)' : '#fff',
                  cursor: isPast ? 'default' : 'pointer', color: isPast ? 'var(--g300)' : 'var(--g700)', fontSize: 13, fontWeight: 600, padding: 2,
                }}
              >
                {day}
                {count > 0 && !isPast && (
                  <span style={{ width: 6, height: 6, borderRadius: '50%', background: color, marginTop: 2 }}></span>
                )}
              </button>
            );
          })}
        </div>

        {summary.dailyCapacity > 0 && (
          <div style={{ display: 'flex', gap: 12, alignItems: 'center', marginTop: 10, fontSize: 11, color: 'var(--g400)' }}>
            <span><span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: '50%', background: 'var(--green)', marginRight: 4 }}></span>Light</span>
            <span><span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: '50%', background: 'var(--amber)', marginRight: 4 }}></span>Busy</span>
            <span><span style={{ display: 'inline-block', width: 7, height: 7, borderRadius: '50%', background: 'var(--red)', marginRight: 4 }}></span>Full</span>
            <span style={{ marginLeft: 'auto' }}>{summary.dailyCapacity} slots/day total</span>
          </div>
        )}
      </div>

      {selectedDate && (
        <div className="card" style={{ marginTop: 14 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-calendar-event"></i> {new Date(`${selectedDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
          </div>

          <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Prior bookings</div>
          {dayBookings.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>Nothing booked yet on this date.</div>
          ) : (
            <div style={{ marginBottom: 14 }}>
              {dayBookings.map((b) => (
                <div key={b.id} style={{ fontSize: 12, padding: '5px 0', borderBottom: '1px solid var(--g50)' }}>
                  <strong>{b.patientName}</strong> ({b.uhid}) -- {b.procedureName}{b.eye ? ` (${b.eye})` : ''} -- <span style={{ color: 'var(--g500)' }}>{b.sessionName}</span>
                </div>
              ))}
            </div>
          )}

          <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Sessions</div>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => isPicker && pickSlot(s)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: full ? 'var(--g100)' : '',
                      color: full ? 'var(--g400)' : '',
                      cursor: full ? 'not-allowed' : isPicker ? 'pointer' : 'default',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>{s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>{full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}</div>
                    {isPicker && !full && <div style={{ fontSize: 10.5, marginTop: 3, fontWeight: 700 }}><i className="ti ti-arrow-back"></i> Use this slot</div>}
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function RescheduleForm({ booking, onDone }) {
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [reason, setReason] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!date) { setError('Pick a new date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setSaving(true);
    const result = await rescheduleOTSlot(booking.id, date, sessionId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div style={{ padding: '10px 0', borderTop: '1px dashed var(--g200)' }}>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 8 }}>
        <div>
          <label className="flbl">New Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">Reason (optional)</label>
          <input className="fi fi-sm" placeholder="e.g. Patient requested, surgeon unavailable..." value={reason} onChange={(e) => setReason(e.target.value)} />
        </div>
      </div>

      {date && (
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      borderColor: selected ? 'transparent' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}
                    </div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      <div style={{ display: 'flex', gap: 6 }}>
        <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={saving}>{saving ? 'Saving...' : 'Confirm Reschedule'}</button>
        <button className="btn btn-sm" onClick={() => onDone(false)} disabled={saving}>Cancel</button>
      </div>
    </div>
  );
}

function ScheduledOTTab() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);
  const [reschedulingId, setReschedulingId] = useState(null);

  const refresh = useCallback(async () => {
    setSchedule(await getScheduledOT());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId, patientName) {
    if (!window.confirm(`Mark ${patientName}'s surgery as Complete? This should only be done AFTER the surgery has actually happened -- it will move out of Scheduled and cannot be easily undone once intraoperative details are recorded.`)) return;
    await completeOT(otId, caseId);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Scheduled OT
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{schedule.length}</span>
      </div>

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {schedule.map((s) => (
              <Fragment key={s.id}>
                <tr>
                  <td>{fmtDate(s.scheduled_date)}</td>
                  <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                  <td>{s.room || '--'}</td>
                  <td>
                    {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                    <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                  </td>
                  <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                  <td>{s.profiles?.full_name || '--'}</td>
                  <td>
                    <span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span>
                    {s.reschedule_count > 0 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>(rescheduled {s.reschedule_count}x)</span>}
                  </td>
                  <td>
                    <div style={{ display: 'flex', gap: 4 }}>
                      <button className="btn btn-sm" onClick={() => setReschedulingId(reschedulingId === s.id ? null : s.id)}>
                        <i className="ti ti-calendar-time"></i> Reschedule
                      </button>
                      <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id, `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`)}>Complete</button>
                    </div>
                  </td>
                </tr>
                {reschedulingId === s.id && (
                  <tr>
                    <td colSpan={8} style={{ padding: 0, border: 'none' }}>
                      <RescheduleForm booking={s} onDone={(saved) => { setReschedulingId(null); if (saved) refresh(); }} />
                    </td>
                  </tr>
                )}
              </Fragment>
            ))}
            {schedule.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

function OTHistoryTab() {
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [search, setSearch] = useState('');
  const [undoingId, setUndoingId] = useState(null);
  const [undoError, setUndoError] = useState('');

  const refresh = useCallback(() => {
    getOTHistory().then((data) => { setHistory(data); setLoading(false); });
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleUndo(s) {
    const name = `${s.surgical_cases?.patients?.first_name} ${s.surgical_cases?.patients?.last_name}`;
    if (!window.confirm(`Undo the Complete on ${name}'s surgery and move it back to Scheduled?`)) return;
    setUndoError('');
    setUndoingId(s.id);
    const result = await undoCompleteOT(s.id, s.surgical_case_id);
    setUndoingId(null);
    if (result.error) { setUndoError(result.error); return; }
    refresh();
  }

  const filtered = search.trim()
    ? history.filter((s) => {
        const q = search.trim().toLowerCase();
        const p = s.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : history;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> OT History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Patients no longer in the active schedule -- currently in surgery, completed, or cancelled.
      </div>
      {undoError && <div className="msg-err" style={{ marginBottom: 10 }}>{undoError}</div>}

      {loading && <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead>
            <tr><th>Date</th><th>Session</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
          </thead>
          <tbody>
            {filtered.map((s) => (
              <tr key={s.id}>
                <td>{fmtDate(s.scheduled_date)}</td>
                <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
                <td>
                  {s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{s.surgical_cases?.patients?.uhid}</span>
                </td>
                <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
                <td>{s.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[s.status] || 'b-gray'}`}>{s.status}</span></td>
                <td>
                  {s.status === 'Completed' && (
                    <button className="btn btn-sm" onClick={() => handleUndo(s)} disabled={undoingId === s.id} title="Undo an accidental Complete click">
                      {undoingId === s.id ? 'Undoing...' : <><i className="ti ti-arrow-back-up"></i> Undo</>}
                    </button>
                  )}
                </td>
              </tr>
            ))}
            {filtered.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>Nothing here yet.</td></tr>
            )}
          </tbody>
        </table>
      )}
    </div>
  );
}

// ── REGISTER SURGERY DIRECTLY ──────────────────────────────────────────
// Fast-track for a patient whose surgical decision was made outside
// today's Doctor -> Counselling pipeline: a returning patient whose
// surgery was arranged before HMIS existed, an external referral, an
// emergency. Creates the surgical case AND books the OT slot in one go,
// with biometry & medical fitness recorded as skipped-with-a-reason
// rather than the app pretending they went through the normal workup.
function RegisterSurgeryDirectForm({ onDone }) {
  const [patientQuery, setPatientQuery] = useState('');
  const [patientResults, setPatientResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searching, setSearching] = useState(false);

  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState('');
  const [eye, setEye] = useState('');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState('');
  const [priority, setPriority] = useState('Routine');
  const [workupNote, setWorkupNote] = useState('');

  const [packages, setPackages] = useState([]);
  const [packageId, setPackageId] = useState('');

  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    getSurgeries().then(setSurgeries);
    getSurgeonsForDirectSurgery().then(setSurgeons);
    getPackagesForDirectSurgery().then(setPackages);
  }, []);

  useEffect(() => {
    if (!patientQuery.trim()) { setPatientResults([]); return; }
    setSearching(true);
    const t = setTimeout(() => {
      searchPatientsForDirectSurgery(patientQuery.trim()).then((rows) => { setPatientResults(rows); setSearching(false); });
    }, 300);
    return () => clearTimeout(t);
  }, [patientQuery]);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleSave() {
    setError('');
    if (!selectedPatient) { setError('Select a patient.'); return; }
    if (!procedureName) { setError('Select the procedure.'); return; }
    if (!workupNote.trim()) { setError('Explain where biometry & fitness clearance came from -- required so this case has an honest audit trail.'); return; }
    if (!packageId) { setError('Select a billing package.'); return; }
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }

    setSaving(true);
    const result = await registerSurgeryDirect({
      patientId: selectedPatient.id, procedureName, eye: eye || null, surgeonId: surgeonId || null,
      priority, workupNote, packageId, date, sessionId, notes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <div className="card" style={{ marginBottom: 16, borderColor: 'var(--amber)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Register Surgery Directly
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 14 }}>
        For a patient whose surgery was decided outside today's Doctor / Counselling flow -- a returning patient from before HMIS existed, an external referral, or an emergency. Biometry & medical fitness are recorded as not-required-in-system with your reason, not faked.
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Patient</label>
        {selectedPatient ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
            <span className="badge b-blue">{selectedPatient.uhid}</span>
            <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
            <span style={{ color: 'var(--g400)', fontSize: 11 }}>{selectedPatient.mobile}</span>
            <button type="button" className="btn btn-sm" onClick={() => { setSelectedPatient(null); setPatientQuery(''); }}>Change</button>
          </div>
        ) : (
          <>
            <input className="fi fi-sm" placeholder="Search by name, UHID, or mobile..." value={patientQuery} onChange={(e) => setPatientQuery(e.target.value)} />
            {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>Searching...</div>}
            {patientResults.length > 0 && (
              <div style={{ marginTop: 6, border: '1px solid var(--g100)', borderRadius: 8, maxHeight: 180, overflowY: 'auto' }}>
                {patientResults.map((p) => (
                  <div
                    key={p.id}
                    onClick={() => { setSelectedPatient(p); setPatientResults([]); }}
                    style={{ padding: '8px 10px', fontSize: 12.5, cursor: 'pointer', borderBottom: '1px solid var(--g100)' }}
                  >
                    <span className="badge b-blue" style={{ marginRight: 6 }}>{p.uhid}</span>
                    {p.first_name} {p.last_name} <span style={{ color: 'var(--g400)' }}>-- {p.mobile}</span>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Procedure</label>
          <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
            <option value="">Select...</option>
            {surgeries.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Eye</label>
          <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
            <option value="">--</option>
            <option value="RE">RE</option>
            <option value="LE">LE</option>
          </select>
        </div>
      </div>

      {procedureName && (
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: -6, marginBottom: 12 }}>
          For a bilateral case, register each eye separately (they're normally booked into different OT sessions/dates anyway) -- submit this form once per eye.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">--</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Priority</label>
          <select className="fi fi-sm" value={priority} onChange={(e) => setPriority(e.target.value)}>
            <option value="Routine">Routine</option>
            <option value="Urgent">Urgent</option>
            <option value="Emergency">Emergency</option>
          </select>
        </div>
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Where did biometry & medical fitness clearance come from?</label>
        <input className="fi fi-sm" placeholder='e.g. "Done before HMIS -- surgery decided 1 month ago", "External hospital referral, reports attached", "Emergency"' value={workupNote} onChange={(e) => setWorkupNote(e.target.value)} />
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">Billing Package</label>
        <select className="fi fi-sm" value={packageId} onChange={(e) => setPackageId(e.target.value)}>
          <option value="">Select...</option>
          {packages.map((p) => <option key={p.id} value={p.id}>{p.name} -- ₹{p.price}</option>)}
        </select>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 8, marginBottom: 12 }}>
        <div>
          <label className="flbl">OT Date</label>
          <input type="date" className="fi fi-sm" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
        <div>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>{date ? 'No active OT sessions configured.' : 'Pick a date first.'}</div>
          ) : (
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id} type="button" disabled={full} onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    {s.name} ({s.remaining} left)
                  </button>
                );
              })}
            </div>
          )}
        </div>
      </div>

      <div style={{ marginBottom: 14 }}>
        <label className="flbl">Notes (optional)</label>
        <input className="fi fi-sm" placeholder="Anything else worth recording..." value={notes} onChange={(e) => setNotes(e.target.value)} />
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Registering...' : <><i className="ti ti-check"></i> Register & Book OT Slot</>}
        </button>
        <button className="btn" onClick={() => onDone(false)}>Cancel</button>
      </div>
    </div>
  );
}

export default function OTSchedulePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <OTScheduleInner />
    </Suspense>
  );
}

function OTScheduleInner() {
  const searchParams = useSearchParams();
  const isPicker = !!searchParams.get('pickFor');
  const [activeTab, setActiveTab] = useState(isPicker ? 'calendar' : 'scheduled');
  const [showDirectForm, setShowDirectForm] = useState(false);
  const [refreshKey, setRefreshKey] = useState(0);

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 10, marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 480 }}>
          <button
            type="button"
            onClick={() => setActiveTab('scheduled')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'scheduled' ? '#fff' : 'transparent', color: activeTab === 'scheduled' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'scheduled' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar-event"></i> Scheduled OT
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('calendar')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'calendar' ? '#fff' : 'transparent', color: activeTab === 'calendar' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'calendar' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-calendar"></i> Calendar
          </button>
          <button
            type="button"
            onClick={() => setActiveTab('history')}
            style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'history' ? '#fff' : 'transparent', color: activeTab === 'history' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'history' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
          >
            <i className="ti ti-history"></i> OT History
          </button>
        </div>

        {!isPicker && (
          <button type="button" className="btn" style={{ borderColor: 'var(--amber)', color: 'var(--amber)' }} onClick={() => setShowDirectForm(!showDirectForm)}>
            <i className="ti ti-calendar-plus"></i> {showDirectForm ? 'Close' : 'Register Surgery Directly'}
          </button>
        )}
      </div>

      {showDirectForm && (
        <RegisterSurgeryDirectForm
          onDone={(saved) => {
            setShowDirectForm(false);
            if (saved) { setActiveTab('scheduled'); setRefreshKey((k) => k + 1); }
          }}
        />
      )}

      {activeTab === 'scheduled' && <ScheduledOTTab key={refreshKey} />}
      {activeTab === 'calendar' && <CalendarTab />}
      {activeTab === 'history' && <OTHistoryTab />}
    </div>
  );
}
__VEDA_FILE_10_END__

cat > "app/(main)/patient-timeline/page.js" << '__VEDA_FILE_11_END__'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback, useRef, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchPatients, getPatientTimeline } from './actions';
import { openPopup } from '@/lib/popup';

// Same mapping used in the Consultation workspace's context sidebar --
// kept identical across both so an event type reads as the same color
// everywhere in the app.
const TYPE_COLOR = {
  Visit: 'var(--indigo)',
  Diagnosis: 'var(--blue)',
  Investigation: 'var(--teal)',
  Prescription: 'var(--purple)',
  Surgery: 'var(--red)',
};
const TYPE_ICON = {
  Visit: 'ti-door-enter',
  Diagnosis: 'ti-clipboard-list',
  Investigation: 'ti-flask',
  Prescription: 'ti-pill',
  Surgery: 'ti-scalpel',
};

function PatientTimelineInner() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [events, setEvents] = useState([]);
  const [filter, setFilter] = useState('');
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [loading, setLoading] = useState(false);
  const searchParams = useSearchParams();
  const skipNextSearch = useRef(false);

  function handleSearch(val) {
    setQuery(val);
  }

  // Debounced live search -- waits for a short pause in typing before
  // querying, rather than firing a request on every keystroke. Skipped
  // once when the query box is set programmatically (e.g. after picking
  // a patient below), so the dropdown doesn't reopen right after selection.
  useEffect(() => {
    if (skipNextSearch.current) { skipNextSearch.current = false; return; }
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => {
      setResults(await searchPatients(q));
    }, 300);
    return () => clearTimeout(t);
  }, [query]);

  const loadPatientById = useCallback(async (patientId) => {
    setLoading(true);
    setResults([]);
    setSelectedEvent(null);
    const result = await getPatientTimeline(patientId);
    setLoading(false);
    setPatient(result.patient);
    setEvents(result.events || []);
    if (result.patient) {
      skipNextSearch.current = true;
      setQuery(`${result.patient.first_name} ${result.patient.last_name} -- ${result.patient.uhid}`);
    }
  }, []);

  async function handleSelectPatient(p) {
    await loadPatientById(p.id);
  }

  // Deep link from elsewhere in the app (e.g. the Consultation workspace's
  // "Open full timeline" link) -- skip the search step and load directly.
  useEffect(() => {
    const patientId = searchParams.get('patientId');
    if (patientId) loadPatientById(patientId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  const filteredEvents = filter ? events.filter((e) => e.type === filter) : events;
  const counts = {};
  events.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Clinical Timeline</div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Read-only longitudinal history, aggregated across every visit this patient has had.
        </div>
        <div style={{ position: 'relative' }}>
          <input className="fi" placeholder="Search patient by name or UHID..." value={query} onChange={(e) => handleSearch(e.target.value)} />
          {results.length > 0 && (
            <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, zIndex: 10, boxShadow: '0 4px 16px rgba(0,0,0,.1)' }}>
              {results.map((p) => (
                <div
                  key={p.id}
                  onClick={() => handleSelectPatient(p)}
                  style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 13, borderBottom: '1px solid var(--g100)' }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g50)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = '#fff')}
                >
                  <strong>{p.first_name} {p.last_name}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {loading && <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading timeline...</div>}

      {!loading && patient && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
          <div>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 14px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)', display: 'flex', gap: 8 }}>
                <select className="fi fi-sm" style={{ width: 'auto' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
                  <option value="">All events</option>
                  <option value="Visit">OPD Visits</option>
                  <option value="Diagnosis">Diagnoses</option>
                  <option value="Investigation">Investigations</option>
                  <option value="Surgery">Surgeries</option>
                  <option value="Prescription">Prescriptions</option>
                </select>
              </div>
              <div style={{ padding: 16 }}>
                {filteredEvents.length === 0 && (
                  <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No events match this filter.</div>
                )}
                {filteredEvents.map((ev, i) => (
                  <div key={i} style={{ display: 'flex', gap: 12 }}>
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 16, flexShrink: 0 }}>
                      <div style={{ width: 12, height: 12, borderRadius: '50%', background: TYPE_COLOR[ev.type], border: '2px solid #fff', boxShadow: '0 0 0 2px var(--g200)', flexShrink: 0 }}></div>
                      {i < filteredEvents.length - 1 && <div style={{ width: 2, background: 'var(--g200)', flex: 1, minHeight: 20, margin: '3px 0' }}></div>}
                    </div>
                    <div style={{ flex: 1, paddingBottom: 16, cursor: 'pointer' }} onClick={() => setSelectedEvent(ev)}>
                      <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 3 }}>
                        {new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                      </div>
                      <div style={{ border: ev.type === 'Visit' && ev.queueEntryId ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TYPE_ICON[ev.type]}`} style={{ color: TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{ev.detail}</div>
                        </div>
                        {ev.type === 'Visit' && ev.queueEntryId && (
                          <i className="ti ti-chevron-right" style={{ color: 'var(--blue)' }}></i>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div>
            {selectedEvent && (
              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-file"></i> Event Detail</div>
                <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Type</span><span className="badge" style={{ background: `${TYPE_COLOR[selectedEvent.type]}20`, color: TYPE_COLOR[selectedEvent.type] }}>{selectedEvent.type}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Date</span><span>{new Date(selectedEvent.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visit</span><span style={{ fontFamily: 'monospace' }}>{selectedEvent.visit}</span></div>
                  <div style={{ marginTop: 6 }}><strong>{selectedEvent.title}</strong></div>
                  <div style={{ color: 'var(--g500)', marginTop: 2 }}>{selectedEvent.detail}</div>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Read-only. Editing happens through the corresponding encounter only.</div>
                {selectedEvent.type === 'Visit' && selectedEvent.queueEntryId && (
                  <Link
                    href={`/consultation/${selectedEvent.queueEntryId}`}
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', textAlign: 'center', textDecoration: 'none', display: 'block' }}
                  >
                    <i className="ti ti-file-text"></i> Open Clinical Record
                  </Link>
                )}
                {selectedEvent.type === 'Visit' && !selectedEvent.queueEntryId && (
                  <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 6 }}>No clinical record was created for this visit.</div>
                )}
                {selectedEvent.type === 'Investigation' && selectedEvent.id && (
                  selectedEvent.title?.trim().toLowerCase() === 'biometry' ? (
                    <a
                      href="/biometry"
                      target="_blank"
                      rel="noopener noreferrer"
                      className="btn btn-primary btn-sm"
                      style={{ marginTop: 10, width: '100%', justifyContent: 'center', textDecoration: 'none' }}
                    >
                      <i className="ti ti-ruler-measure"></i> Open Biometry
                    </a>
                  ) : (
                    <button
                      className="btn btn-primary btn-sm"
                      style={{ marginTop: 10, width: '100%', justifyContent: 'center' }}
                      onClick={() => openPopup(`/investigation/${selectedEvent.id}?mode=view`, `inv-${selectedEvent.id}`)}
                    >
                      <i className="ti ti-eye"></i> View Result
                    </button>
                  )
                )}
              </div>
            )}

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Timeline Summary</div>
              <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Patient</span><span style={{ fontWeight: 600 }}>{patient.first_name} {patient.last_name}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total events</span><span style={{ fontWeight: 700 }}>{events.length}</span></div>
                {Object.entries(counts).map(([type, count]) => (
                  <div key={type} style={{ display: 'flex', justifyContent: 'space-between' }}>
                    <span>{type}</span><span className="badge" style={{ background: `${TYPE_COLOR[type]}20`, color: TYPE_COLOR[type] }}>{count}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {!loading && !patient && (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
          Search for a patient above to view their clinical timeline.
        </div>
      )}
    </div>
  );
}

export default function PatientTimelinePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <PatientTimelineInner />
    </Suspense>
  );
}

__VEDA_FILE_11_END__

cat > "app/(main)/surgical-journey/[id]/workspace.js" << '__VEDA_FILE_12_END__'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import {
  getSurgicalCaseDetail,
  setIolOrderNotes, editSurgicalCaseDetails, setTreatmentInstructions,
  getInvestigationOptionsForCase, addInHouseInvestigationForCase, removeInHouseInvestigationForCase,
  addExternalTest, removeExternalTest,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, getPackagesForCase,
  setDecision, referForMedicalFitness, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
} from '@/app/(main)/counselling/actions';
import { getOTAvailability, rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
import { openPopup } from '@/lib/popup';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

// ── HEADER (editable) ──────────────────────────────────────────────
function CaseHeader({ sc, patient, onAction }) {
  const [editing, setEditing] = useState(false);
  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState(sc.procedure_name);
  const [eye, setEye] = useState(sc.eye || 'OD');
  const [reason, setReason] = useState('');
  const [instructions, setInstructions] = useState(sc.treatment_instructions || '');
  const [savingInstructions, setSavingInstructions] = useState(false);
  const progressed = sc.status !== 'Pending Workup';

  useEffect(() => { if (editing) getSurgeries().then(setSurgeries); }, [editing]);

  function startEdit() {
    setProcedureName(sc.procedure_name); setEye(sc.eye || 'OD'); setReason(''); setEditing(true);
  }

  async function handleSaveInstructions() {
    setSavingInstructions(true);
    await onAction(setTreatmentInstructions)(sc.id, instructions);
    setSavingInstructions(false);
  }

  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--indigo)', color: '#fff' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 12, opacity: 0.85 }}>{patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile}</div>
        </div>
        {!editing ? (
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 700, fontSize: 14 }}>
              {sc.procedure_name}
              <button
                className="btn btn-sm" style={{ marginLeft: 8, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff', padding: '2px 8px' }}
                onClick={startEdit} title="Edit procedure/eye"
              >
                <i className="ti ti-pencil"></i>
              </button>
            </div>
            <div style={{ fontSize: 12, opacity: 0.85 }}>{EYE_LABEL[sc.eye] || sc.eye}</div>
            <div style={{ fontSize: 10.5, opacity: 0.7, marginTop: 2 }}>
              Advised: {new Date(sc.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
            </div>
          </div>
        ) : null}
      </div>

      {editing && (
        <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
              <option value={sc.procedure_name}>{sc.procedure_name}</option>
              {surgeries.filter((s) => s.name !== sc.procedure_name).map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
            </select>
            <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
              <option value="OD">Right (OD)</option>
              <option value="OS">Left (OS)</option>
              <option value="OU">Both (OU)</option>
            </select>
          </div>
          {progressed && (
            <input
              className="fi fi-sm" style={{ marginBottom: 8 }}
              placeholder={`Reason for changing (required -- case has already moved to "${sc.status}")`}
              value={reason} onChange={(e) => setReason(e.target.value)}
            />
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              className="btn btn-sm btn-primary"
              onClick={async () => {
                const r = await onAction(editSurgicalCaseDetails)(sc.id, procedureName, eye, reason);
                if (r?.error) return;
                setEditing(false);
              }}
            >
              Save
            </button>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={() => setEditing(false)}>Cancel</button>
          </div>
        </div>
      )}

      {/* Further instructions -- tied to the treatment itself (what's
          being done, which eye), not the pre-op investigations note. */}
      <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
        <div style={{ fontSize: 10, fontWeight: 700, opacity: 0.75, textTransform: 'uppercase', marginBottom: 6 }}>Further Instructions</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="fi fi-sm" style={{ flex: 1 }}
            placeholder="Anything else about this treatment worth noting..."
            value={instructions} onChange={(e) => setInstructions(e.target.value)}
          />
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={handleSaveInstructions} disabled={savingInstructions}>
            {savingInstructions ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ num, color, title, done, children, defaultOpen, active }) {
  const [open, setOpen] = useState(!!defaultOpen || !!active);
  return (
    <div
      className="card"
      style={{
        marginBottom: 12,
        border: active ? `2px solid ${color}` : '1px solid var(--g200)',
        background: active ? `color-mix(in srgb, ${color} 10%, white)` : '#fff',
        boxShadow: active ? `0 0 0 3px color-mix(in srgb, ${color} 20%, transparent)` : 'none',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }} onClick={() => setOpen((v) => !v)}>
        <div style={{ width: 24, height: 24, borderRadius: '50%', background: done ? 'var(--green)' : color, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
          {done ? <i className="ti ti-check"></i> : num}
        </div>
        <div style={{ fontWeight: 700, fontSize: 13, flex: 1 }}>
          {title}
          {active && <span className="badge" style={{ marginLeft: 8, background: color, color: '#fff', fontSize: 10 }}><i className="ti ti-arrow-right"></i> Next Step</span>}
        </div>
        <i className={`ti ${open ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ marginTop: 12, paddingLeft: 34 }}>{children}</div>}
    </div>
  );
}

export default function Workspace({ caseId }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getSurgicalCaseDetail(caseId);
    if (result.error) { setError(result.error); return; }
    setData(result);
  }, [caseId]);

  useEffect(() => { refresh(); }, [refresh]);

  function flash(fn) {
    return async (...args) => {
      setError(''); setOk('');
      const result = await fn(...args);
      if (result?.error) { setError(result.error); return result; }
      setOk('Saved.');
      await refresh();
      setTimeout(() => setOk(''), 2000);
      return result;
    };
  }

  if (error && !data) return <div className="msg-err">{error}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = data.case;
  const patient = sc.patients;

  // Drives the "Next Step" highlight -- the first not-yet-done stage in
  // the natural order gets the full-color treatment, everything else
  // stays normal. Reports and Notes aren't part of this sequence (they
  // don't have a natural "done" state -- reports trickle in whenever,
  // notes are an ongoing log), so they're excluded.
  const stepDone = {
    decision: sc.decision === 'Accepted',
    investigations: data.biometryRecords.length > 0,
    package: !!sc.package_id,
    iolApproval: data.iolApproval?.status === 'Approved',
    iol: !!data.otSchedule,
    fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
    advance: !!sc.advance_payment_id,
    dayof: !!data.recoveryEpisode?.discharge_date,
  };
  const currentStep = Object.keys(stepDone).find((k) => !stepDone[k]) || null;

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/surgical-journey')}>
        <i className="ti ti-arrow-left"></i> All Cases
      </button>

      <CaseHeader sc={sc} patient={patient} onAction={flash} />

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      {/* 1. PATIENT DECISION -- the very first step. Investigations (and
          everything after) only unlock once this is Accepted. */}
      <DecisionSection sc={sc} onAction={flash} active={currentStep === 'decision'} />

      {/* 2. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} inHouseInvestigations={data.inHouseInvestigations} externalTests={data.externalTests} onAction={flash} active={currentStep === 'investigations'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} onAction={flash} active={currentStep === 'package'} />

      {/* 4. IOL APPROVAL -- separate module: surgeon's final brand/power
          sign-off, based on Biometry's device recommendations. */}
      <IolApprovalSection iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />

      {/* 5. IOL PROCUREMENT + DATE + BOOK */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} onAction={flash} active={currentStep === 'iol'} num={5} />

      {/* 6. MEDICAL FITNESS -- comes after the surgery date is booked
          (pre-anaesthesia clearance closer to the actual surgery date
          is more clinically useful than clearing weeks in advance). */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={6} />

      {/* 7. ADVANCE */}
      <Section num={7} color="var(--teal)" title="Advance Payment" done={stepDone.advance} active={currentStep === 'advance'}>
        {sc.advance_payment_id ? (
          <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Advance collected.</div>
        ) : (
          <div>
            <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>Not yet collected.</div>
            <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => router.push(`/payments/advance?patientId=${patient.id}&returnTo=surgical-journey`)}>
              <i className="ti ti-cash"></i> Collect Advance
            </button>
          </div>
        )}
      </Section>

      {/* 8. DAY OF SURGERY */}
      <DayOfSurgerySection sc={sc} otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'dayof'} num={8} />

      {/* 9. NOTES / FOLLOW-UP */}
      <NotesSection caseId={sc.id} notes={data.caseNotes} onAction={flash} />
    </div>
  );
}

// ── FITNESS ─────────────────────────────────────────────────────────
// Kept as a real doctor referral/review (same as Counselling), not a
// self-certify checkbox -- clearing a patient for anaesthesia is a
// genuine clinical judgment, not paperwork. Deep-links to the Medical
// Fitness module for the actual review.
function FitnessSection({ sc, fitnessReferral, onAction, active, num }) {
  const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';
  return (
    <Section num={num} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>Refer to a doctor to review and clear for anaesthesia/surgery.</div>
          <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
            <i className="ti ti-heart-rate-monitor"></i> Refer to Doctor
          </button>
        </div>
      ) : fitnessReferral.status === 'Pending Review' ? (
        <span className="badge b-amber"><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}) -- <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Medical Fitness &rarr;</a></span>
      ) : fitnessReferral.status === 'Cleared' ? (
        <div>
          <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
        </div>
      ) : (
        <div>
          <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
          <div style={{ marginTop: 8 }}>
            <button className="btn btn-sm" onClick={() => onAction(referForMedicalFitness)(sc.id)}>
              <i className="ti ti-refresh"></i> Refer Again
            </button>
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. ──
function IolApprovalSection({ iolApproval, active }) {
  const approved = iolApproval?.status === 'Approved';
  return (
    <Section num={5} color="var(--indigo)" title="IOL Approval" done={approved} active={active}>
      {approved ? (
        <div style={{ fontSize: 12.5 }}>
          <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
          <div style={{ marginTop: 6 }}>
            {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
          </div>
        </div>
      ) : (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
            The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
          </div>
          <a href="/iol-approval" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>
            <i className="ti ti-lens"></i> Open IOL Approval
          </a>
        </div>
      )}
    </Section>
  );
}

// ── 1. INVESTIGATIONS -- flexible and optional, not a fixed required
// panel. Biometry stays its own thing (patient-level, dedicated flow).
// Everything else splits into In-House (routes through our own
// Investigation module, status + View Report) and External (done
// elsewhere -- add multiple named tests, upload/view each one's report
// separately, and print the whole list as a referral slip). ──
function InvestigationsSection({ sc, biometryRecords, inHouseInvestigations, externalTests, onAction, active }) {
  const [invOptions, setInvOptions] = useState([]);
  const [selectedInv, setSelectedInv] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [extTestName, setExtTestName] = useState('');
  const [expandedTestId, setExpandedTestId] = useState(null);
  const biometryOrdered = biometryRecords.length > 0;
  const decided = sc.decision === 'Accepted';

  useEffect(() => { if (decided) getInvestigationOptionsForCase().then(setInvOptions); }, [decided]);

  if (!decided) {
    return (
      <Section num={2} color="var(--purple)" title="Investigations" done={false}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }

  return (
    <Section num={2} color="var(--purple)" title="Investigations" done={biometryOrdered} active={active}>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 14 }}>
        Optional -- add whatever this case actually needs, not a fixed checklist.
      </div>

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>In-House Investigations</div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>Anything we do ourselves -- including Biometry, whatever the doctor feels this case needs.</div>
        {inHouseInvestigations.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {inHouseInvestigations.map((inv) => {
              const isBiometry = inv.name.toLowerCase() === 'biometry';
              const bioRecord = isBiometry ? biometryRecords[0] : null;
              return (
                <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
                  <span>{inv.name} -- {inv.eye}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${inv.status === 'Available' ? 'b-green' : inv.status === 'Cancelled' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{inv.status}</span>
                    {isBiometry ? (
                      <a href={bioRecord?.id ? `/biometry/${bioRecord.id}` : '/biometry'} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
                        {bioRecord?.status === 'Measured' ? 'View Report' : 'Open Biometry'}
                      </a>
                    ) : inv.status === 'Available' ? (
                      <a href={`/investigation/${inv.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>View Report</a>
                    ) : inv.status === 'Ordered' ? (
                      <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={() => onAction(removeInHouseInvestigationForCase)(inv.id)}>Remove</button>
                    ) : null}
                  </div>
                </div>
              );
            })}
          </div>
        )}
        <div style={{ display: 'flex', gap: 8 }}>
          <select className="fi fi-sm" style={{ flex: 1 }} value={selectedInv} onChange={(e) => setSelectedInv(e.target.value)}>
            <option value="">Select investigation...</option>
            {invOptions.map((o) => <option key={o.code} value={o.name}>{o.name}</option>)}
          </select>
          <select className="fi fi-sm" style={{ width: 90 }} value={invEye} onChange={(e) => setInvEye(e.target.value)}>
            <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
          </select>
          <button
            className="btn btn-sm btn-primary" disabled={!selectedInv}
            onClick={async () => { const r = await onAction(addInHouseInvestigationForCase)(sc.id, selectedInv, invEye); if (!r?.error) setSelectedInv(''); }}
          >
            <i className="ti ti-plus"></i> Add
          </button>
        </div>
      </div>

      <div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
          <div style={{ fontWeight: 600, fontSize: 12 }}>External Investigations</div>
          {externalTests.length > 0 && (
            <a href={`/external-investigation-referral-print/${sc.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Referral
            </a>
          )}
        </div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 8 }}>Blood work, HIV test, etc -- not done in-house. Add each test, upload its report whenever it comes back.</div>

        {externalTests.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {externalTests.map((t) => (
              <div key={t.id} style={{ background: 'var(--g50)', borderRadius: 6, marginBottom: 4 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', fontSize: 12, cursor: 'pointer' }} onClick={() => setExpandedTestId(expandedTestId === t.id ? null : t.id)}>
                  <span>{t.test_name}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className="badge b-gray" style={{ fontSize: 10 }}>{t.attachmentCount > 0 ? `${t.attachmentCount} file${t.attachmentCount > 1 ? 's' : ''}` : 'No report yet'}</span>
                    <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={(e) => { e.stopPropagation(); onAction(removeExternalTest)(t.id); }}>Remove</button>
                    <i className={`ti ${expandedTestId === t.id ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
                  </div>
                </div>
                {expandedTestId === t.id && (
                  <div style={{ padding: '0 8px 10px' }}>
                    <AttachmentUploader entityType="external_investigation" entityId={t.id} title="" />
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "CBC", "HIV Test", "RBS"' value={extTestName} onChange={(e) => setExtTestName(e.target.value)} />
          <button
            className="btn btn-sm btn-primary" disabled={!extTestName.trim()}
            onClick={async () => { const r = await onAction(addExternalTest)(sc.id, extTestName); if (!r?.error) setExtTestName(''); }}
          >
            <i className="ti ti-plus"></i> Add Test
          </button>
        </div>
      </div>
    </Section>
  );
}

// ── 1. PATIENT DECISION -- the first step. Set by the doctor at
// advise-surgery time in OPD (Consultation), reflected here, and
// updatable by Front Desk once the patient calls back. Uses the same
// locked+reason semantics setDecision already enforces everywhere else
// (locks automatically once Accepted; changing away from a locked
// decision needs a reason). ──
function DecisionSection({ sc, onAction, active }) {
  const [reason, setReason] = useState('');
  const OPTIONS = [
    { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
    { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
    { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
  ];
  return (
    <Section num={1} color="var(--amber)" title="Patient Decision" done={sc.decision === 'Accepted'} active={active}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 8 }}>
        {OPTIONS.map((o) => (
          <button
            key={o.v}
            className="btn btn-sm"
            style={{ background: sc.decision === o.v ? o.color : '', color: sc.decision === o.v ? '#fff' : '', border: sc.decision === o.v ? 'none' : undefined }}
            onClick={() => onAction(setDecision)(sc.id, o.v, reason)}
          >
            {o.label}
          </button>
        ))}
      </div>
      {sc.decision_locked && (
        <input className="fi fi-sm" placeholder="Reason to change decision..." value={reason} onChange={(e) => setReason(e.target.value)} />
      )}
      {sc.decision === 'Accepted' && sc.decision_accepted_at && (
        <div style={{ fontSize: 11.5, color: 'var(--green)', marginTop: 8 }}>
          <i className="ti ti-lock"></i> Accepted on {new Date(sc.decision_accepted_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })} -- locked.
        </div>
      )}
      {sc.decision === 'Wants Time to Decide' && (
        <div style={{ fontSize: 11.5, color: 'var(--amber)', marginTop: 8 }}>
          <i className="ti ti-clock-pause"></i> On Front Desk's follow-up list until this is updated.
        </div>
      )}
      {sc.decision === 'Declined' && (
        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 8 }}>
          <i className="ti ti-x"></i> Patient declined surgery.
        </div>
      )}
      {!sc.decision && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 8 }}>No decision recorded yet.</div>
      )}
    </Section>
  );
}

// ── 3. PACKAGE & IOL DECISION ──────────────────────────────────────
function PackageDecisionSection({ sc, onAction, active }) {
  const [packages, setPackages] = useState([]);
  const [loadingPackages, setLoadingPackages] = useState(true);
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [selecting, setSelecting] = useState(false);
  const [selectError, setSelectError] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changing, setChanging] = useState(false);
  const biometryReady = sc.biometry_done || sc.biometry_required === false;

  useEffect(() => {
    if (biometryReady) getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoadingPackages(false); });
  }, [biometryReady, sc.iol_category]);

  if (!biometryReady) {
    return (
      <Section num={3} color="var(--indigo)" title="Package" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Biometry approval first.</div>
      </Section>
    );
  }

  const selectedPreview = packages.find((p) => p.id === selectedPackageId);

  async function handleSelect() {
    setSelectError('');
    if (!selectedPackageId) { setSelectError('Choose a package first.'); return; }
    setSelecting(true);
    const result = await onAction(selectPackage)(sc.id, selectedPackageId);
    setSelecting(false);
    if (result?.error) { setSelectError(result.error); return; }
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package" done={!!sc.package_id} defaultOpen={biometryReady && !sc.package_id} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Package</div>
        {sc.master_packages ? (
          <div>
            <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: changing ? 8 : 0 }}>
              <span style={{ fontWeight: 600, fontSize: 12.5 }}>{sc.master_packages.name}</span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
                {!changing && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
              </div>
            </div>
            {changing && (
              <div>
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a new package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                  <button
                    className="btn btn-sm btn-primary"
                    disabled={!selectedPackageId || !changeReason.trim()}
                    onClick={async () => {
                      const r = await onAction(changePackage)(sc.id, changeReason);
                      if (r?.error) return;
                      await onAction(selectPackage)(sc.id, selectedPackageId);
                      setChanging(false); setChangeReason(''); setSelectedPackageId('');
                    }}
                  >
                    Confirm Change
                  </button>
                  <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); }}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        ) : loadingPackages ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>
        ) : (
          <div>
            {selectError && <div className="msg-err" style={{ marginBottom: 8 }}>{selectError}</div>}
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
              Packages from Financial Masters &gt; Surgery.
            </div>
            {packages.length === 0 ? (
              <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)', background: 'var(--g50)', borderRadius: 8 }}>
                No active packages found. Add one under Financial Masters &gt; Surgery.
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
                  <select className="fi fi-sm" style={{ flex: 1 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                  <button className="btn btn-sm btn-primary" disabled={!selectedPackageId || selecting} onClick={handleSelect}>
                    <i className="ti ti-check"></i> {selecting ? 'Selecting...' : 'Select'}
                  </button>
                </div>
                {selectedPreview && (
                  <div style={{ border: '1.5px solid var(--g200)', borderRadius: 8, padding: 10 }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                      <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
                        {selectedPreview.name}
                        {selectedPreview.origin && <span className={`badge ${selectedPreview.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{selectedPreview.origin}</span>}
                      </div>
                      <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(selectedPreview.price).toLocaleString('en-IN')}</div>
                    </div>
                    {selectedPreview.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{selectedPreview.includes}</div>}
                  </div>
                )}
              </>
            )}
          </div>
        )}
      </div>
    </Section>
  );
}

// ── 4. IOL PROCUREMENT + DATE + BOOK SLOT ──────────────────────────
function IolAndBookingSection({ sc, otSchedule, onAction, active, num }) {
  const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [sessionName, setSessionName] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  // The date+session picker lives in the OT Schedule module's own
  // Calendar tab (prior bookings visible there, one place instead of
  // duplicating a calendar here) -- opened as a real popup window, and
  // the chosen slot comes back via postMessage instead of a page
  // redirect, since this is a multi-step form the user shouldn't lose.
  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== 'ot-slot-picked' || e.data.caseId !== sc.id) return;
      setDate(e.data.date);
      setSessionId(e.data.sessionId);
      setSessionName(e.data.sessionName || '');
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [sc.id]);

  function openCalendarPicker() {
    const label = encodeURIComponent(`${sc.patients?.first_name || ''} ${sc.patients?.last_name || ''} -- ${sc.procedure_name || ''} (${sc.eye || ''})`.trim());
    openPopup(`/ot-schedule?pickFor=${sc.id}&pickLabel=${label}`, `ot-calendar-${sc.id}`);
  }

  const canBook = sc.status === 'Ready for Scheduling';
  const readyGateMet = sc.package_id && sc.decision === 'Accepted' && (sc.biometry_done || sc.biometry_required === false);

  const [rescheduling, setRescheduling] = useState(false);
  const [rescheduleReason, setRescheduleReason] = useState('');

  if (otSchedule) {
    return (
      <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done active={active}>
        <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>

        {!rescheduling ? (
          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><i className="ti ti-calendar-check"></i> Booked -- {new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}, {otSchedule.master_ot_sessions?.name} session</span>
            {otSchedule.status === 'Scheduled' && <button className="btn btn-sm" onClick={() => setRescheduling(true)}>Reschedule</button>}
          </div>
        ) : (
          <div>
            <div style={{ marginBottom: 8 }}>
              {date ? (
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
                  <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
                  <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
                </div>
              ) : (
                <button className="btn btn-sm" onClick={openCalendarPicker}>
                  <i className="ti ti-calendar"></i> Open OT Calendar
                </button>
              )}
            </div>
            {date && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Session</label>
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {loadingSessions ? <span style={{ fontSize: 12, color: 'var(--g400)' }}>Checking...</span> : sessions.map((s) => {
                    const full = s.remaining <= 0;
                    return (
                      <button key={s.session_id} disabled={full} className="btn btn-sm"
                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                        onClick={() => setSessionId(s.session_id)}>
                        {s.name} ({s.remaining} left)
                      </button>
                    );
                  })}
                </div>
              </div>
            )}
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
              <button
                className="btn btn-sm btn-primary"
                disabled={!date || !sessionId || !rescheduleReason.trim()}
                onClick={async () => {
                  const r = await onAction(rescheduleOTSlot)(otSchedule.id, date, sessionId, rescheduleReason);
                  if (r?.error) return;
                  setRescheduling(false); setRescheduleReason(''); setDate(''); setSessionId(''); setSessionName('');
                }}
              >
                Confirm
              </button>
              <button className="btn btn-sm" onClick={() => setRescheduling(false)}>Cancel</button>
            </div>
          </div>
        )}
      </Section>
    );
  }

  return (
    <Section num={num} color="var(--teal)" title="IOL Order &amp; Surgery Date" done={false} defaultOpen={readyGateMet} active={active}>
      <div style={{ marginBottom: 12 }}>
        <label className="flbl">IOL Order Notes</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>
      </div>

      {!readyGateMet && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 10 }}>
          <i className="ti ti-info-circle"></i> Package, decision, and biometry must all be settled before booking a date. Medical Fitness clearance happens after the date is booked.
        </div>
      )}

      {readyGateMet && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 8, marginBottom: 10 }}>
            <div>
              <label className="flbl">Surgeon</label>
              <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                <option value="">--</option>
                {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
              </select>
            </div>
          </div>
          <div style={{ marginBottom: 10 }}>
            <label className="flbl">Date</label>
            {date ? (
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
                <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
                <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
              </div>
            ) : (
              <button className="btn btn-sm" onClick={openCalendarPicker}>
                <i className="ti ti-calendar"></i> Open OT Calendar
              </button>
            )}
          </div>
          {date && (
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Session</label>
              {loadingSessions ? (
                <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
              ) : (
                <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                  {sessions.map((s) => {
                    const full = s.remaining <= 0;
                    return (
                      <button
                        key={s.session_id} disabled={full} className="btn btn-sm"
                        style={{ background: sessionId === s.session_id ? 'var(--teal)' : full ? 'var(--g100)' : '', color: sessionId === s.session_id ? '#fff' : full ? 'var(--g400)' : '' }}
                        onClick={() => setSessionId(s.session_id)}
                      >
                        {s.name} ({s.remaining} left)
                      </button>
                    );
                  })}
                </div>
              )}
            </div>
          )}
          <button
            className="btn btn-primary btn-sm"
            disabled={!date || !sessionId}
            onClick={async () => {
              if (!canBook) {
                const r = await onAction(markReadyForScheduling)(sc.id);
                if (r?.error) return;
              }
              await onAction(bookOTSlot)(sc.id, date, sessionId, surgeonId || null, null);
            }}
          >
            <i className="ti ti-calendar-check"></i> Give This Date
          </button>
        </>
      )}
    </Section>
  );
}

// ── 7. DAY OF SURGERY (live status, deep-links only -- OT Intraop and
// Recovery remain their own solid clinical workflows) ──
function DayOfSurgerySection({ sc, otSchedule, recoveryEpisode, router, active, num }) {
  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;

  if (otSchedule) {
    if (otSchedule.status === 'Scheduled') {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
      color = 'var(--blue)';
      action = { label: 'Open in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in OT Intraop', onClick: () => router.push('/ot-intraop') };
    } else if (otSchedule.status === 'Completed') {
      if (recoveryEpisode && !recoveryEpisode.discharge_date) {
        status = 'Surgery done -- in Recovery';
        color = 'var(--teal)';
        action = { label: 'Open in Recovery', onClick: () => router.push('/ot-recovery') };
      } else if (recoveryEpisode?.discharge_date) {
        status = `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
        color = 'var(--green)';
        action = { label: 'Open in Post-Op', onClick: () => router.push('/ot-postop') };
      } else {
        status = 'Surgery completed';
        color = 'var(--green)';
      }
    }
  }

  return (
    <Section num={num} color={color} title="Day of Surgery" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!otSchedule} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, the surgery itself, and discharge all happen in the Operation Theatre / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── 8. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
function NotesSection({ caseId, notes, onAction }) {
  const [text, setText] = useState('');
  return (
    <Section num={9} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
      <div style={{ display: 'flex', gap: 8, marginBottom: 10 }}>
        <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Add a note (e.g. follow-up call outcome)..." value={text} onChange={(e) => setText(e.target.value)} />
        <button
          className="btn btn-sm"
          onClick={async () => { if (!text.trim()) return; await onAction(addCaseNote)(caseId, text); setText(''); }}
        >
          Add
        </button>
      </div>
      {notes.map((n) => (
        <div key={n.id} style={{ fontSize: 11.5, color: 'var(--g600)', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
          <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })} -- {n.profiles?.full_name || 'Staff'}:</span> {n.note}
        </div>
      ))}
      {notes.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No notes yet.</div>}
    </Section>
  );
}
__VEDA_FILE_12_END__

cat > "app/(main)/surgical-journey/actions.js" << '__VEDA_FILE_13_END__'
'use server';

import { createClient } from '@/lib/supabase-server';
import { adviseBiometry } from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/counselling/actions';

// This module deliberately does NOT reimplement package selection,
// biometry skip/unskip, decision recording, ready-for-scheduling, or OT
// booking -- the page imports those directly from Counselling and OT
// Schedule (same pattern Consultation already uses to call into
// Counselling), since that logic is already built, tested, and
// correct. What THIS file adds is a single page that walks through all
// of it for one patient without switching modules, plus a few
// genuinely new pieces (proceed status, IOL order notes, manual
// reminder tracking) that didn't exist anywhere before.

// ── EDIT PROCEDURE / EYE (any stage) ───────────────────────────────
// counselling's updateSurgicalCase only allows this while status is
// still 'Pending Workup' and refuses otherwise with no real
// alternative -- there was no actual place "further changes should go
// through Counselling" could happen. This lets a genuine correction
// (wrong eye picked, procedure name needs fixing) happen at ANY stage,
// same principle as changePackage/setDecision: once the case has
// progressed, a reason is required and logged, rather than the edit
// being refused outright.
export async function editSurgicalCaseDetails(caseId, procedureName, eye, reason) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status, procedure_name, eye').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const progressed = sc.status !== 'Pending Workup';
  if (progressed && (!reason || !reason.trim())) {
    return { error: `A reason is required to change the procedure/eye once the case has moved to "${sc.status}".` };
  }

  const { error } = await supabase.from('surgical_cases').update({ procedure_name: procedureName, eye }).eq('id', caseId);
  if (error) return { error: error.message };

  if (progressed) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Procedure/eye corrected -- was "${sc.procedure_name}" (${sc.eye}), now "${procedureName}" (${eye}). Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  return { success: true };
}

// ── IN-HOUSE INVESTIGATIONS (Step 2) ───────────────────────────────
// Flexible and optional -- add whatever this case actually needs, not
// a fixed required panel. Fully generic -- Biometry is just one more
// option in the same list, not a separate hardcoded section, per your
// instruction. Routes through the same investigation_orders table and
// Investigation module queue Doctor Consultation uses. "Further
// investigations for a surgical case go through the surgery module" --
// this is that entry point, not a trip back to Consultation.
export async function getInvestigationOptionsForCase() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

export async function addInHouseInvestigationForCase(caseId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Select an investigation.' };

  const { data: sc } = await supabase.from('surgical_cases').select('encounter_id, patient_id, visit_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (!sc.encounter_id) return { error: 'This case has no linked consultation encounter to attach investigations to.' };

  const resolvedEye = eye || 'OU';

  // Don't let the same investigation get ordered twice for this case
  // while an earlier order is still open (Ordered/In Progress).
  const { data: dupe } = await supabase
    .from('investigation_orders')
    .select('id')
    .eq('encounter_id', sc.encounter_id)
    .eq('eye', resolvedEye)
    .ilike('name', name.trim())
    .in('status', ['Ordered', 'In Progress'])
    .limit(1);
  if (dupe && dupe.length > 0) {
    return { error: `"${name.trim()}" (${resolvedEye}) is already ordered and still pending for this case.` };
  }

  // Biometry is patient-level and fulfilled through its own dedicated
  // module -- same special-case Doctor Consultation's addInvestigation
  // already does. A normal investigation_orders row is still created so
  // it shows up in this same list with a status badge, but the actual
  // biometry_records row (device readings, IOL recommendations) is what
  // makes it real -- ensured here, same as everywhere else biometry
  // gets ordered from.
  if (name.trim().toLowerCase() === 'biometry') {
    const result = await adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, null);
    if (result.error) return result;
  }

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: sc.encounter_id, name: name.trim(), eye: resolvedEye, priority: 'Routine',
  });
  if (error) return { error: error.message };

  await supabase.from('encounter_audit_log').insert({
    encounter_id: sc.encounter_id,
    message: `Investigation ordered from Surgical Journey: ${name.trim()} (${resolvedEye})`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}

export async function removeInHouseInvestigationForCase(investigationId) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', investigationId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EXTERNAL INVESTIGATIONS ─────────────────────────────────────────
// Named tests done elsewhere (blood work, HIV test -- not done
// in-house). Each is added by name; the report, once it comes back, is
// a normal clinical_attachments upload keyed to that specific test, not
// a generic unlabeled bucket. Also printable as a referral slip to
// hand the patient.
export async function getExternalTestsForCase(caseId) {
  const supabase = await createClient();
  const { data: tests, error } = await supabase
    .from('external_investigations')
    .select('*')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });
  if (error) return [];

  const testIds = (tests || []).map((t) => t.id);
  let attachmentCountByTest = {};
  if (testIds.length > 0) {
    const { data: attachments } = await supabase
      .from('clinical_attachments')
      .select('entity_id')
      .eq('entity_type', 'external_investigation')
      .in('entity_id', testIds);
    (attachments || []).forEach((a) => { attachmentCountByTest[a.entity_id] = (attachmentCountByTest[a.entity_id] || 0) + 1; });
  }

  return (tests || []).map((t) => ({ ...t, attachmentCount: attachmentCountByTest[t.id] || 0 }));
}

export async function addExternalTest(caseId, name) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!name || !name.trim()) return { error: 'Enter a test name.' };
  const { error } = await supabase.from('external_investigations').insert({
    surgical_case_id: caseId, test_name: name.trim(), created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeExternalTest(testId) {
  const supabase = await createClient();
  const { error } = await supabase.from('external_investigations').delete().eq('id', testId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── FURTHER INSTRUCTIONS (Treatment) ───────────────────────────────
// Free text tied to the treatment itself (procedure + eye), distinct
// from the pre-op panel notes in the Investigations step.
export async function setTreatmentInstructions(caseId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ treatment_instructions: instructions || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DASHBOARD ────────────────────────────────────────────────────────

// Every open surgical case (any staff member -- a small setup doesn't
// have per-doctor case ownership walls). "Open" = not yet Completed or
// Cancelled.
export async function getMyActiveSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile), master_packages:package_id(name, price)')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: false });
  if (error) return [];
  return data || [];
}

// Patients whose decision is "Wants Time to Decide" and haven't
// resolved it yet (accepted or declined). Front desk's follow-up list.
// Ordered oldest-first so the ones most overdue for a call surface at
// the top.
export async function getAwaitingReturnCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(first_name, last_name, uhid, mobile)')
    .eq('decision', 'Wants Time to Decide')
    .not('status', 'in', '("Completed","Cancelled")')
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── CASE DETAIL ─────────────────────────────────────────────────────

export async function getSurgicalCaseDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select(`
      *,
      patients:patient_id(id, first_name, last_name, uhid, mobile, age, gender),
      master_packages:package_id(id, name, price, iol_category),
      profiles:surgeon_id(full_name)
    `)
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  // Biometry is patient-level now, not case-scoped -- reused across
  // every future surgical case for that patient (readings don't
  // meaningfully change for years). No more per-eye/per-case matching
  // needed; just look up whatever's on file for this patient.
  const { data: biometryRecords } = await supabase
    .from('biometry_records')
    .select('id, status, verify_remarks, verified_at')
    .eq('patient_id', sc.patient_id)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false });

  // In-house investigations -- ordered against this case's own
  // consultation encounter, same investigation_orders table Doctor
  // Consultation uses and the same Investigation module queue picks
  // them up from. Fully generic -- Biometry shows up here too now,
  // same as anything else (whatever the doctor feels like), not a
  // separate hardcoded section.
  let inHouseInvestigations = [];
  if (sc.encounter_id) {
    const { data } = await supabase
      .from('investigation_orders')
      .select('*')
      .eq('encounter_id', sc.encounter_id)
      .order('created_at', { ascending: false });
    inHouseInvestigations = data || [];
  }

  // Day-of-surgery live status -- OT Schedule / Intraop / Recovery
  // already have solid, tested clinical workflows; this page doesn't
  // rebuild them, it just shows where the case currently stands and
  // deep-links into whichever one applies.
  const { data: otSchedule } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, status, master_ot_sessions(name)')
    .eq('surgical_case_id', caseId)
    .order('scheduled_date', { ascending: false })
    .limit(1)
    .maybeSingle();

  let recoveryEpisode = null;
  if (otSchedule) {
    const { data } = await supabase
      .from('recovery_episodes')
      .select('id, discharge_date')
      .eq('ot_schedule_id', otSchedule.id)
      .maybeSingle();
    recoveryEpisode = data;
  }

  // Medical fitness stays a real doctor referral/review, same as
  // Counselling -- this isn't a rubber-stamp checkbox, so it keeps its
  // own dedicated review step rather than being folded into a form
  // field here.
  const { data: fitnessReferral } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status, referred_at, fitness_notes')
    .eq('surgical_case_id', caseId)
    .order('referred_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data: caseNotes } = await supabase
    .from('surgical_case_notes')
    .select('*, profiles:created_by(full_name)')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });

  // The surgeon's final IOL choice -- separate module/step from both
  // Biometry (raw device recommendations) and this page's own package
  // selection (billing category only).
  const { data: iolApproval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, manufacturer, category)')
    .eq('surgical_case_id', caseId)
    .maybeSingle();

  const externalTests = await getExternalTestsForCase(caseId);

  return {
    case: { ...sc, biometry_done: biometryRecords.some((b) => b.status === 'Measured') },
    biometryRecords,
    inHouseInvestigations,
    externalTests,
    fitnessReferral: fitnessReferral || null,
    iolApproval: iolApproval || null,
    otSchedule: otSchedule || null,
    recoveryEpisode,
    caseNotes: caseNotes || [],
  };
}

// ── ADVISE SURGERY (Step 1-2) ──────────────────────────────────────
// Thin wrapper so the new page's "Advise Surgery" button doesn't need
// to import from Consultation directly -- same underlying function,
// same surgical_cases row Counselling already reads.
export async function adviseSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes) {
  return markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired, notes);
}

// ── INVESTIGATIONS (Step 3) ────────────────────────────────────────
// Biometry is real, in-house, tracked work, always covers both eyes,
// and is reused across every future surgical case for the patient
// (readings don't meaningfully change for years). Goes through the
// same mechanism a doctor uses during a normal consultation, landing
// in the actual Biometry Queue. The pre-op panel (blood work etc.) is
// done entirely by a third party -- there's nothing to "order" in this
// system, so it's just a free-text note here; the report itself comes
// in later as an attachment (see AttachmentUploader on the page).
export async function orderBiometryForCase(caseId, instructions) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('patient_id, visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  return adviseBiometry(sc.patient_id, sc.visit_id, sc.encounter_id, instructions);
}

export async function setPreOpPanelNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PROCEED STATUS (Step 4) ────────────────────────────────────────
export async function setProceedStatus(caseId, status) {
  const supabase = await createClient();
  if (!['Deciding', 'Awaiting Return', 'Proceeding'].includes(status)) return { error: 'Invalid status.' };
  const { error } = await supabase.from('surgical_cases').update({ proceed_status: status }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── IOL PROCUREMENT + INFORMAL DATE (Step 6-7) ─────────────────────
// Free text by design -- "Ordered Alcon monofocal +21D from XYZ
// Optics, expected Friday". No structured supplier/PO tracking yet.
export async function setIolOrderNotes(caseId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ iol_order_notes: notes || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── AWAITING-RETURN REMINDERS (manual for now -- WhatsApp template not
// yet approved, see conversation) -- just tracks that someone called,
// for the front-desk follow-up list. Also drops a case note so there's
// a record of what was said, reusing the same notes trail as everything
// else on the case. ──
export async function recordManualReminder(caseId, note) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('reminder_count').eq('id', caseId).single();
  const { error } = await supabase.from('surgical_cases').update({
    last_reminder_sent_at: new Date().toISOString(),
    reminder_count: (sc?.reminder_count || 0) + 1,
  }).eq('id', caseId);
  if (error) return { error: error.message };

  await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: `Follow-up call -- ${note || 'no details recorded'}`,
    created_by: userData?.user?.id || null,
  });

  return { success: true };
}
__VEDA_FILE_13_END__

cat > "app/consultation/[id]/consultation-form.js" << '__VEDA_FILE_14_END__'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addTaperedPrescription,
  removeTaperGroup,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  sendForProcedureFromConsultation,
  addReferral,
  removeReferral,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
  saveDraft,
  getFollowUpContext,
  saveVisitOutcome,
  carryForwardDiagnosis,
} from '@/app/(main)/consultation/actions';
import { openPopup } from '@/lib/popup';
import { markForSurgery, updateSurgicalCase, setDecision } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getDosageOptions, getServices, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import OptometryWorkspace from '@/app/(main)/optometry/[id]/optometry-workspace';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';
import { openPrintPopup } from '@/lib/printPopup';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

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

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// Section group divider for Diagnosis & Plan -- numbered circle badge,
// same visual language as the numbered sections in Optometry Assessment,
// so the two clinical screens feel consistent.
function GroupHeader({ num, color, title }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '4px 0 12px' }}>
      <span style={{ width: 24, height: 24, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>{num}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)' }}>{title}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--g200)' }}></div>
    </div>
  );
}

export default function ConsultationForm({ queueEntryId, hideHistoryTracker = false, onBack, backLabel = 'Dashboard' }) {
  const [data, setData] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [visitOutcome, setVisitOutcome] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [surgeryNotes, setSurgeryNotes] = useState('');
  const [surgeryDecision, setSurgeryDecision] = useState('');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [editSurgeryNotes, setEditSurgeryNotes] = useState('');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('optometry');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [showRxSuggestions, setShowRxSuggestions] = useState(false);
  const [showRxBrowseAll, setShowRxBrowseAll] = useState(false);
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([
    { frequency: 'QID', duration: '1 week' },
    { frequency: 'TDS', duration: '1 week' },
    { frequency: 'BD', duration: '1 week' },
    { frequency: 'OD', duration: '1 week' },
  ]);
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const invPriority = 'Routine'; // selector removed -- no longer needed

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [procNotes, setProcNotes] = useState('');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  // Master Data options for the Diagnosis/Prescription/Investigation
  // dropdowns -- fetched once on mount, not re-fetched on every add/remove.
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);
  const [rxDrugTypeId, setRxDrugTypeId] = useState(null);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, sg, dg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      setDosageOptions(dg);
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation'));
      setProcedureOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Minor Procedure'));
      setSurgeryOptions(sg.filter((s) => s.status === 'Active'));
    })();
  }, []);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    setVisitOutcome(data.encounter.visit_outcome || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
  }, [data]);

  async function handleVisitOutcomeChange(outcome) {
    setVisitOutcome(outcome);
    await saveVisitOutcome(data.encounter.id, outcome);
  }

  async function handleCarryForward(priorDiagnosis) {
    setError('');
    const result = await carryForwardDiagnosis(data.encounter.id, priorDiagnosis);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  // Type-ahead for the Prescription drug field -- matches on brand or
  // generic name, case-insensitive substring, capped to keep the list
  // scannable. Falls back to free-text (rxDrug itself) when nothing
  // matches, or to the full Browse dropdown if the doctor wants to look
  // rather than type.
  const rxSuggestions = rxDrug.trim().length > 0
    ? drugOptions.filter((d) => d.brand && (
        d.brand.toLowerCase().includes(rxDrug.toLowerCase()) ||
        (d.generic && d.generic.toLowerCase().includes(rxDrug.toLowerCase()))
      )).slice(0, 8)
    : [];

  function selectRxDrug(d) {
    setRxDrug(d.brand);
    setRxDrugTypeId(d.drug_type_id || null);
    setRxDosage('');
    setShowRxSuggestions(false);
  }

  function updateTaperStep(index, field, value) {
    setTaperSteps((prev) => prev.map((s, i) => (i === index ? { ...s, [field]: value } : s)));
  }
  function addTaperStep() {
    setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week' }]);
  }
  function removeTaperStep(index) {
    setTaperSteps((prev) => prev.filter((_, i) => i !== index));
  }
  async function handleAddTaperSchedule() {
    setError('');
    if (!rxDrug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    if (!rxDosage.trim()) { setError('Select a dosage for the tapering schedule.'); return; }
    const result = await addTaperedPrescription(data.encounter.id, { drugName: rxDrug, dosage: rxDosage, eye: rxEye, steps: taperSteps });
    if (result.error) { setError(result.error); return; }
    setRxDrug(''); setRxDosage(''); setRxDrugTypeId(null); setShowTaperBuilder(false);
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName) { setError('Select a procedure.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye, procNotes);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    setProcNotes('');
    refresh();
  }

  async function handleSendForProcedure() {
    setError('');
    setLoading(true);
    const result = await sendForProcedureFromConsultation(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  // This page is meant to be opened in its own window (see doctor-dashboard's
  // "Call"/"Call Next" and ot-postop's "Start Review"), closing itself the
  // moment the doctor is done with this sitting -- window.close() only
  // works on script-opened windows, so this quietly falls back to
  // navigating back to the queue if it was opened by direct navigation
  // instead (e.g. a bookmark or typed URL).
  function finishAndClose() {
    window.close();
    router.push('/queue');
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  // Escape hatch for a visit that genuinely can't go through the normal
  // completion path -- patient left before being seen, token called but
  // nobody responded, etc. Doesn't touch the diagnosis requirement for
  // any other visit; just closes this one with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a diagnosis.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    if (!surgeryDecision) { setError("Select the patient's decision -- right now."); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp, surgeryNotes, surgeryDecision);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    setSurgeryNotes('');
    setSurgeryDecision('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
    setEditSurgeryNotes(sc.notes || '');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp, editSurgeryNotes);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleSaveDraft() {
    setError('');
    setLoading(true);
    const result = await saveDraft(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    finishAndClose();
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  const isReadOnly = data.isLocked && !unlocked;

  return (
    <div style={{ maxWidth: 1440, margin: '0 auto', padding: '20px 26px' }}>
      {/* STICKY HEADER + TABS -- frozen at the top of the scroll area so
          the patient's identity and which tab you're on never scroll out
          of view, no matter how long the tab's content gets. */}
      <div style={{ position: 'sticky', top: 0, zIndex: 20, background: 'var(--g50)', paddingBottom: 10, marginBottom: 6 }}>
        {onBack && (
          <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> {backLabel}
          </button>
        )}
        <div style={{
          background: 'linear-gradient(135deg, var(--blue-dk), var(--blue))', borderRadius: 'var(--r-lg)',
          padding: '14px 20px', color: '#fff', boxShadow: 'var(--shadow-md)', marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 16,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: '50%', background: 'rgba(255,255,255,.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800, flexShrink: 0,
            fontFamily: 'var(--font-display-stack)',
          }}>
            {patient.first_name?.charAt(0)?.toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
              {patient.first_name} {patient.last_name}
              {data.isFollowUp && <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontSize: 10.5 }}>Follow-up Visit</span>}
            </div>
            <div style={{ fontSize: 12, opacity: .85, marginTop: 2 }}>
              {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- Token {data.entry.token}
            </div>
          </div>
          <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.16)', borderRadius: 10, padding: '6px 16px', flexShrink: 0 }}>
            <div style={{ fontSize: 9.5, opacity: .8, textTransform: 'uppercase', letterSpacing: '.5px' }}>Duration</div>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'monospace' }}>{elapsedMin(data.encounter.started_at)}m</div>
          </div>
        </div>

        {/* TABS */}
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
          <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
          <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
          <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
          {!hideHistoryTracker && <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />}
        </div>
      </div>

      {data.isFollowUp && followUpContext && (
        <PatientSnapshotBar snapshot={followUpContext.snapshot} />
      )}

      {data.isLocked && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed consultation -- changes save immediately.'
              : 'This consultation is completed. Viewing read-only for reference.'}
          </span>
          <button className="btn btn-sm" onClick={() => setUnlocked((v) => !v)}>
            {unlocked ? 'Lock' : 'Unlock to Edit'}
          </button>
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        {/* CONTEXT SIDEBAR -- patient history (previous visit, timeline,
            investigations) plus this encounter's own status/tasks/audit
            log, all in one place so the main column has full width. */}
        <div>
          <ContextSidebar
            patientId={patient.id}
            previousVisitSummary={data.isFollowUp && followUpContext ? followUpContext.snapshot.previousVisitSummary : null}
            encounter={data.encounter}
            auditLog={data.auditLog}
            isAdmin={data.isAdmin}
            openInvestigations={openInvestigations}
            activeWorkflows={activeWorkflows}
            pendingRx={pendingRx}
            wfItems={WF_ITEMS}
          />
        </div>

        {/* MAIN COLUMN -- tab content only; the tab bar itself now lives
            in the sticky header above so it freezes along with the
            patient identity bar. */}
        <div>
          {/* Tab content and the actions bar below are wrapped in a native
              <fieldset disabled> when the encounter is locked -- this
              cascades to every nested input/select/button in the embedded
              OptometryWorkspace, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'optometry' && (
            <OptometryWorkspace queueEntryId={queueEntryId} embedded />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              <GroupHeader num={1} color="var(--purple)" title="Investigations" />

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>
                {data.isFollowUp && followUpContext && (
                  <NewInvestigationsSinceLastVisit
                    investigations={followUpContext.newInvestigations}
                    matchInvestigationType={matchInvestigationType}
                    summarizeResultData={summarizeResultData}
                  />
                )}
                {data.investigations.map((i) => {
                  // Biometry is a special investigation -- it's fulfilled
                  // through its own dedicated module (device readings,
                  // IOL recommendations, surgeon approval), not the plain
                  // Investigation workspace. Route it to /biometry instead
                  // of /investigation/[id], same as Surgical Journey does.
                  const isBiometry = i.name.trim().toLowerCase() === 'biometry';
                  const type = matchInvestigationType(i.name);
                  const hasResults = i.status === 'Available';
                  return (
                    <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
                        <span>
                          <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                        </span>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                          {isBiometry ? (
                            <a href="/biometry" target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '2px 8px', fontSize: 11, textDecoration: 'none' }}>
                              <i className="ti ti-ruler-measure"></i> Open Biometry
                            </a>
                          ) : hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {!isBiometry && i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {!isBiometry && hasResults && (
                        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3 }}>{summarizeResultData(type, i.result_data)}</div>
                      )}
                      {i.status === 'Cancelled' && i.unable_reason && (
                        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}><i className="ti ti-alert-triangle"></i> Unable to perform -- {i.unable_reason}</div>
                      )}
                    </div>
                  );
                })}
                {data.investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No investigations ordered yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setInvName(e.target.value); }}>
                  <option value="">-- Pick from Investigations master (or type below) --</option>
                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              <GroupHeader num={2} color="var(--teal)" title="Diagnosis" />

              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
                {data.isFollowUp && followUpContext && !isReadOnly && (
                  <CarryForwardDiagnoses
                    priorDiagnoses={followUpContext.snapshot.currentDiagnoses}
                    alreadyAdded={data.diagnoses}
                    onCarryForward={handleCarryForward}
                  />
                )}
                {data.diagnoses.map((d, idx) => (
                  <DiagnosisRow key={d.id} d={d} index={idx} encounterId={data.encounter.id} onRemove={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }} />
                ))}
                {data.diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
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
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="OD">Right (OD)</option>
                    <option value="OS">Left (OS)</option>
                    <option value="OU">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              <GroupHeader num={3} color="var(--blue)" title="Treatment" />

              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Prescription</div>
                {data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && !isReadOnly && (
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
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye})
                          </button>
                        ))}
                    </div>
                  </div>
                )}
                {(() => {
                  // Group rows sharing a taper_group_id into one block
                  // (ordered by taper_step); everything else renders as
                  // a normal single-line prescription, same as before.
                  const seen = new Set();
                  const items = [];
                  data.prescriptions.forEach((r) => {
                    if (r.taper_group_id) {
                      if (seen.has(r.taper_group_id)) return;
                      seen.add(r.taper_group_id);
                      const steps = data.prescriptions
                        .filter((x) => x.taper_group_id === r.taper_group_id)
                        .sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0));
                      items.push({ type: 'taper', key: r.taper_group_id, steps });
                    } else {
                      items.push({ type: 'single', key: r.id, row: r });
                    }
                  });
                  return items.map((item) => item.type === 'single' ? (
                    <div key={item.key} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <span>
                        <strong>{item.row.drug_name}</strong> -- {item.row.dosage} {item.row.frequency} x {item.row.duration} -- {item.row.eye}
                      </span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(item.row.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ) : (
                    <div key={item.key} style={{ padding: '8px 10px', margin: '6px 0', background: 'var(--purple-lt)', borderRadius: 8, borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                        <span style={{ fontSize: 13 }}>
                          <strong>{item.steps[0].drug_name}</strong> -- {item.steps[0].dosage} -- {item.steps[0].eye}
                          <span style={{ marginLeft: 8, fontSize: 10.5, fontWeight: 700, color: 'var(--purple)', textTransform: 'uppercase' }}><i className="ti ti-chart-line"></i> Tapering Schedule</span>
                        </span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeTaperGroup(item.key, data.encounter.id); refresh(); }}>Remove Schedule</button>
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
                <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr 1fr 1fr 1fr auto', gap: 6, marginTop: 10, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase' }}>
                  <span>Drug</span><span>Dosage</span><span>Frequency</span><span>Duration</span><span>Eye</span><span></span>
                </div>
                <div style={{ display: 'flex', gap: 6, marginTop: 4, flexWrap: 'wrap', alignItems: 'flex-start' }}>
                  <div style={{ position: 'relative', flex: '2 1 160px' }}>
                    <input
                      className="fi"
                      placeholder="Type to search medicines, or enter a new name"
                      value={rxDrug}
                      onChange={(e) => { setRxDrug(e.target.value); setRxDrugTypeId(null); setShowRxSuggestions(true); }}
                      onFocus={() => setShowRxSuggestions(true)}
                      onBlur={() => setTimeout(() => setShowRxSuggestions(false), 150)}
                      style={{ width: '100%' }}
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
                    {(rxDrugTypeId ? dosageOptions.filter((o) => o.drug_type_id === rxDrugTypeId) : []).map((o) => (
                      <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>
                    ))}
                    {/* Generic fallback -- shown when the drug has no type assigned yet (free-typed name, or a master drug still missing its Type in Financial Masters) so the field never comes up empty. */}
                    {!rxDrugTypeId && (
                      <>
                        <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                      </>
                    )}
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 110 }}>
                    <option value="RE">Right (OD)</option><option value="LE">Left (OS)</option><option value="BE">Both (OU)</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>

                {!showTaperBuilder ? (
                  <button className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }} onClick={() => setShowTaperBuilder(true)}>
                    <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
                  </button>
                ) : (
                  <div style={{ marginTop: 10, padding: 12, background: 'var(--purple-lt)', borderRadius: 8 }}>
                    <div style={{ fontSize: 11.5, fontWeight: 700, color: 'var(--purple)', marginBottom: 8 }}>
                      <i className="ti ti-chart-line"></i> Tapering Schedule -- uses the Drug, Dosage &amp; Eye entered above; frequency reduces step by step below
                    </div>
                    {taperSteps.map((s, i) => (
                      <div key={i} style={{ display: 'flex', gap: 6, alignItems: 'center', marginBottom: 6 }}>
                        <span style={{ fontSize: 11, color: 'var(--g500)', width: 16 }}>{i + 1}.</span>
                        <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ maxWidth: 100 }}>
                          <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                        </select>
                        <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ maxWidth: 110 }}>
                          <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option>
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
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                  {data.opticalAdvice.map((o) => (
                    <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{o.advice}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                    {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                      <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                    ))}
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Minor Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                        <span>{p.name} -- {p.eye}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                      {p.notes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{p.notes}</div>}
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select minor procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name} -- Rs.{p.rate}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 110 }}>
                      <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                  </div>
                  <input className="fi fi-sm" placeholder="Notes (optional)" value={procNotes} onChange={(e) => setProcNotes(e.target.value)} />
                </div>
              </div>

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery</div>

                {data.surgicalCases.length > 0 ? (
                  <div>
                    {data.surgicalCases.map((sc) => (
                      <div key={sc.id}>
                        {editingSurgicalCaseId === sc.id ? (
                          <div style={{ padding: '8px 0' }}>
                            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                              <select className="fi" value={editSurgeryProcedure} onChange={(e) => setEditSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                                <option value="">-- Select surgery --</option>
                                {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                              </select>
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 110 }}>
                                <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Notes</label>
                              <input className="fi" placeholder="Any notes for this surgery recommendation..." value={editSurgeryNotes} onChange={(e) => setEditSurgeryNotes(e.target.value)} />
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ padding: '6px 0' }}>
                            <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
                              <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                              <span style={{ flex: 1 }}>
                                <strong>{sc.procedure_name}</strong> -- {sc.eye === 'OD' ? 'Right (OD)' : sc.eye === 'OS' ? 'Left (OS)' : sc.eye === 'OU' ? 'Both (OU)' : sc.eye}
                              </span>
                              <span className="badge b-blue" style={{ fontSize: 10 }}>{sc.status}</span>
                              {sc.status === 'Pending Workup' && (
                                <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => startEditSurgicalCase(sc)}>
                                  <i className="ti ti-edit"></i> Edit
                                </button>
                              )}
                            </div>
                            {sc.notes && (
                              <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3, marginLeft: 22 }}><i className="ti ti-notes"></i> {sc.notes}</div>
                            )}
                            <div style={{ marginTop: 6, marginLeft: 22 }}>
                              <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', marginBottom: 4 }}>Patient's Decision</div>
                              <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                                {[
                                  { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
                                  { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
                                  { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
                                ].map((d) => (
                                  <button
                                    key={d.v} type="button" className="btn" style={{ padding: '3px 9px', fontSize: 11, background: sc.decision === d.v ? d.color : '', color: sc.decision === d.v ? '#fff' : '', border: sc.decision === d.v ? 'none' : undefined }}
                                    onClick={async () => {
                                      const reason = sc.decision_locked && sc.decision !== d.v ? window.prompt(`Decision is locked (currently "${sc.decision}"). Enter a reason to change it:`) : null;
                                      if (sc.decision_locked && sc.decision !== d.v && !reason) return;
                                      const result = await setDecision(sc.id, d.v, reason);
                                      if (result.error) { setError(result.error); return; }
                                      refresh();
                                    }}
                                  >
                                    {d.label}
                                  </button>
                                ))}
                              </div>
                            </div>
                          </div>
                        )}
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select surgery --</option>
                        {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 110 }}>
                        <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Notes</label>
                      <input className="fi" placeholder="Any notes for this surgery recommendation..." value={surgeryNotes} onChange={(e) => setSurgeryNotes(e.target.value)} />
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Patient's Decision -- Right Now</label>
                      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
                        {[
                          { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
                          { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
                          { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
                        ].map((d) => (
                          <button
                            key={d.v} type="button" className="btn btn-sm"
                            style={{ background: surgeryDecision === d.v ? d.color : '', color: surgeryDecision === d.v ? '#fff' : '', border: surgeryDecision === d.v ? 'none' : undefined }}
                            onClick={() => setSurgeryDecision(d.v)}
                          >
                            {d.label}
                          </button>
                        ))}
                      </div>
                      <div style={{ fontSize: 10.5, color: 'var(--g400)', marginTop: 4 }}>
                        "Needs Time to Decide" puts this patient on Front Desk's follow-up list in Surgical Journey. This can be updated later either way.
                      </div>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              <GroupHeader num={4} color="var(--amber)" title="Patient Management" />

              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                  {data.referrals.map((r) => (
                    <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                    <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Destination --</option>
                      <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                    </select>
                    <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                    <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                      <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                    </select>
                    <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                      <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                    </select>
                    <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                      <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                    </select>
                  </div>
                  <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                  <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                  {fuSaved && (
                    <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                      Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                    </div>
                  )}
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {data.isFollowUp && (
            <VisitOutcomeSelector value={visitOutcome} onChange={handleVisitOutcomeChange} disabled={isReadOnly} />
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn" onClick={handleSaveDraft} disabled={loading}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            {data.investigations.length > 0 && (
              <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
                Send for Investigation
              </button>
            )}
            {data.procedures.length > 0 && (
              <button className="btn" onClick={handleSendForProcedure} disabled={loading}>
                <i className="ti ti-tool"></i> Send for Procedure
              </button>
            )}
          </div>

          {/* Escape hatch -- for a visit that genuinely can't reach the
              diagnosis requirement above (patient left, no-show after
              being called, etc). Kept visually separate from the main
              actions so it isn't a tempting shortcut for normal visits. */}
          {!isReadOnly && (
            <div className="card" style={{ marginTop: 8 }}>
              {!showForceClose ? (
                <button className="btn" style={{ fontSize: 12, color: 'var(--g500)' }} onClick={() => setShowForceClose(true)}>
                  <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
                </button>
              ) : (
                <div>
                  <label className="flbl">Why can&apos;t this visit be completed normally? *</label>
                  <div style={{ display: 'flex', gap: 8 }}>
                    <input className="fi" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                    <button className="btn" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                      {forceClosing ? 'Closing...' : 'Confirm'}
                    </button>
                    <button className="btn" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          )}
          </fieldset>

          {/* PRINT ACTIONS -- deliberately kept OUTSIDE the <fieldset
              disabled={isReadOnly}> above. Printing a case sheet / visit
              summary doesn't change any data, so a completed (locked)
              encounter should still allow printing without requiring
              "Unlock to Edit" first. */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 8 }}>
            <button onClick={() => openPrintPopup(`/opd-case-sheet-print/${data.encounter.id}`)} className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-file-description"></i> Print Case Sheet
            </button>
            <button onClick={() => openPrintPopup(`/visit-summary-print/${data.encounter.id}`)} className="btn">
              <i className="ti ti-printer"></i> Print Visit Summary
            </button>
          </div>
        </div>
      </div>
    </div>
  );
}

__VEDA_FILE_14_END__

cat > "app/consultation/[id]/follow-up-panel.js" << '__VEDA_FILE_15_END__'
'use client';

import { useState, useEffect } from 'react';
import { openPopup } from '@/lib/popup';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';

const VISIT_OUTCOMES = [
  'Continue Follow-up', 'Surgery Advised', 'Proceed to Pre-operative Consultation',
  'Surgery Planned', 'Referred', 'Admitted', 'Discharged',
];

function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function visionStr(v) {
  if (!v) return '--';
  return `RE ${v.re || '--'} / LE ${v.le || '--'}`;
}

function iopStr(iop) {
  if (!iop) return '--';
  return `RE ${iop.re ?? '--'} / LE ${iop.le ?? '--'} mmHg`;
}

// Biometry investigations are fulfilled through the Biometry module,
// not the plain Investigation workspace -- route clicks accordingly.
function isBiometryTitle(title) {
  return (title || '').trim().toLowerCase() === 'biometry';
}

function openInvestigation(e) {
  if (isBiometryTitle(e.title)) window.open('/biometry', '_blank', 'noopener,noreferrer');
  else openPopup(`/investigation/${e.id}?mode=view`, `inv-${e.id}`);
}

// ── Patient Snapshot (top panel, always visible for a Follow-up encounter) ──
export function PatientSnapshotBar({ snapshot }) {
  if (!snapshot) return null;
  if (snapshot.noCompletedPriorVisit) {
    return (
      <div className="card" style={{ marginBottom: 16, background: 'var(--amber-lt)', border: '1px solid #fcd34d' }}>
        <div style={{ fontSize: 12, color: 'var(--amber)' }}>
          <i className="ti ti-info-circle"></i> This patient has prior visits, but none were ever finalized -- no completed clinical record to summarize yet.
        </div>
      </div>
    );
  }
  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--blue-lt)', border: '1px solid #93c5fd' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Patient Snapshot -- Follow-up Visit
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10 }}>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Diagnosis</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentDiagnoses.length > 0 ? snapshot.currentDiagnoses.map((d) => d.name).join(', ') : 'None on record'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Surgery Status</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.surgicalStatus ? `${snapshot.surgicalStatus.procedure_name} -- ${snapshot.surgicalStatus.status}` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Medications</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentMedications.length > 0 ? `${snapshot.currentMedications.length} active` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Drug Allergies</div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: snapshot.allergy ? 'var(--red)' : 'inherit' }}>{snapshot.allergy || 'None recorded'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Visit</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{fmtDate(snapshot.lastVisitDate)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Vision</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{visionStr(snapshot.lastVision)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last IOP</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{iopStr(snapshot.lastIop)}</div>
        </div>
      </div>
    </div>
  );
}

// ── Previous visits, shown as an in-flow horizontal strip at the top of
// the workspace (not floating -- sits inside the consultation content,
// same as everything else). ──
export function PatientTimelineSidebar({ timeline }) {
  return (
    <div className="card" style={{ marginBottom: 16, borderLeft: '4px solid var(--indigo)' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--indigo)', textTransform: 'uppercase', marginBottom: 10, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Previous Visits
      </div>
      {timeline.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior visits.</div>
      ) : (
        <div style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
          {timeline.map((t) => {
            const clickable = !!t.queueEntryId;
            return (
              <div
                key={t.encounterId}
                onClick={clickable ? () => window.open(`/consultation/${t.queueEntryId}`, '_blank', 'noopener,noreferrer') : undefined}
                style={{ minWidth: 160, flexShrink: 0, padding: '10px 12px', borderRadius: 10, border: '1.5px solid var(--indigo)', cursor: clickable ? 'pointer' : 'default', background: 'var(--indigo-lt)' }}
              >
                <div style={{ fontSize: 12, fontWeight: 800, color: 'var(--indigo)' }}>{fmtDate(t.date)}</div>
                <div style={{ fontSize: 11.5, color: 'var(--g700)', marginTop: 2 }}>{t.chiefComplaint || 'Consultation'}</div>
                {t.status !== 'Completed' && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 4, fontWeight: 600 }}>Not finalized -- {t.status}</div>}
                {clickable && <div style={{ fontSize: 10.5, color: 'var(--indigo)', marginTop: 4, fontWeight: 700 }}><i className="ti ti-eye"></i> {t.status === 'Completed' ? 'View read-only' : 'Open'}</div>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ── Previous Visit Summary (read-only card) ──
export function PreviousVisitSummary({ summary }) {
  if (!summary) return null;
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--g500)' }}></i> Previous Visit Summary -- {fmtDate(summary.date)}</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, fontSize: 12.5 }}>
        <div><span style={{ color: 'var(--g500)' }}>Vision: </span>{visionStr(summary.vision)}</div>
        <div><span style={{ color: 'var(--g500)' }}>IOP: </span>{iopStr(summary.iop)}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Diagnosis: </span>{summary.diagnoses.length > 0 ? summary.diagnoses.map((d) => d.name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Medications: </span>{summary.medications.length > 0 ? summary.medications.map((m) => m.drug_name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Advice: </span>{summary.advice.length > 0 ? summary.advice.map((a) => a.text || a.advice_text || a.note).filter(Boolean).join('; ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Follow-up Plan: </span>{summary.followupPlan?.instructions || summary.followupPlan?.notes || '--'}</div>
      </div>
    </div>
  );
}

// Same mapping as the standalone Patient Timeline module -- kept
// identical across both so an event type reads as the same color
// everywhere in the app, not just within this sidebar.
const EVENT_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };
const EVENT_COLOR = { Visit: 'var(--indigo)', Diagnosis: 'var(--blue)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--red)' };

function EventTypeChip({ type }) {
  const color = EVENT_COLOR[type] || 'var(--g500)';
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 7px', borderRadius: 999, background: `${color}1a`, color, fontSize: 9.5, fontWeight: 800, textTransform: 'uppercase', letterSpacing: '.3px' }}>
      <i className={`ti ${EVENT_ICON[type] || 'ti-point'}`} style={{ fontSize: 10 }}></i> {type}
    </span>
  );
}

function elapsedMin(iso) {
  return Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
}

// ── Context sidebar -- lives alongside the workspace. Combines patient
//    history (previous visit, timeline, past investigations) with this
//    encounter's own status/tasks/audit log, all in one column so the
//    main workspace gets the full remaining width. ──
export function ContextSidebar({ patientId, previousVisitSummary, encounter, auditLog, isAdmin, openInvestigations, activeWorkflows, pendingRx, wfItems }) {
  const [showSummary, setShowSummary] = useState(false);
  const [events, setEvents] = useState(null);

  useEffect(() => {
    if (!patientId) return;
    let cancelled = false;
    getPatientTimeline(patientId).then((r) => { if (!cancelled) setEvents(r.events || []); });
    return () => { cancelled = true; };
  }, [patientId]);

  const investigations = (events || []).filter((e) => e.type === 'Investigation');

  return (
    <div>
      <button
        className="btn"
        style={{ width: '100%', justifyContent: 'center', marginBottom: 16 }}
        onClick={() => setShowSummary(true)}
        disabled={!previousVisitSummary}
        title={previousVisitSummary ? '' : 'No previous visit on record'}
      >
        <i className="ti ti-file-text"></i> Previous Visit Summary
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-timeline" style={{ color: 'var(--indigo)' }}></i> Patient Timeline</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && events.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No prior history.</div>}
        {events && events.length > 0 && (
          <div style={{ maxHeight: 300, overflowY: 'auto' }}>
            {events.slice(0, 25).map((e, idx) => {
              const clickable = (e.type === 'Visit' && !!e.queueEntryId) || (e.type === 'Investigation' && !!e.id);
              function handleClick() {
                if (e.type === 'Visit' && e.queueEntryId) window.open(`/consultation/${e.queueEntryId}`, '_blank', 'noopener,noreferrer');
                else if (e.type === 'Investigation' && e.id) openInvestigation(e);
              }
              return (
                <div
                  key={idx}
                  onClick={clickable ? handleClick : undefined}
                  style={{ padding: '8px 4px', borderBottom: '1px solid var(--g100)', cursor: clickable ? 'pointer' : 'default', borderRadius: 6 }}
                  onMouseEnter={clickable ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
                  onMouseLeave={clickable ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <EventTypeChip type={e.type} />
                    <span style={{ marginLeft: 'auto', color: 'var(--g400)', fontSize: 10 }}>{fmtDate(e.date)}</span>
                    {clickable && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR[e.type], fontSize: 12 }}></i>}
                  </div>
                  <div style={{ fontSize: 11.5, fontWeight: 600, marginTop: 4 }}>{e.title}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
                </div>
              );
            })}
          </div>
        )}
        <a href={patientId ? `/patient-timeline?patientId=${patientId}` : '/patient-timeline'} target="_blank" rel="noopener noreferrer" style={{ fontSize: 10.5, color: 'var(--blue)', display: 'inline-flex', alignItems: 'center', gap: 4, marginTop: 8 }}>
          <i className="ti ti-external-link"></i> Open full timeline
        </a>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Previous Investigations</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && investigations.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>None on record.</div>}
        {investigations.slice(0, 15).map((e, idx) => (
          <div
            key={idx}
            onClick={e.id ? () => openInvestigation(e) : undefined}
            style={{ padding: '7px 4px', borderBottom: '1px solid var(--g100)', cursor: e.id ? 'pointer' : 'default', borderRadius: 6 }}
            onMouseEnter={e.id ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
            onMouseLeave={e.id ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11.5, fontWeight: 600, flex: 1 }}>{e.title}</span>
              <span className="badge" style={{ background: `${EVENT_COLOR.Investigation}1a`, color: EVENT_COLOR.Investigation, fontSize: 9 }}>{e.status || '--'}</span>
              {e.id && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR.Investigation, fontSize: 12 }}></i>}
            </div>
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>{fmtDate(e.date)}</div>
          </div>
        ))}
      </div>

      {encounter && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Encounter Status</div>
          <div style={{ fontSize: 11.5, color: 'var(--g600)', lineHeight: 1.9 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Status</span><span className="badge b-blue">{encounter.status}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(encounter.started_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>In progress</span><span style={{ fontWeight: 700 }}>{elapsedMin(encounter.started_at)}m</span></div>
          </div>
        </div>
      )}

      {(openInvestigations || activeWorkflows || pendingRx) && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-list-checks" style={{ color: 'var(--amber)' }}></i> Outstanding Tasks</div>
          {(openInvestigations || []).length === 0 && (activeWorkflows || []).length === 0 && (pendingRx || []).length === 0 && (
            <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Nothing outstanding.</div>
          )}
          {(openInvestigations || []).map((i) => (
            <div key={i.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i><span style={{ flex: 1 }}>{i.name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{i.status}</span>
            </div>
          ))}
          {(activeWorkflows || []).map((w) => (
            <div key={w.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className={`ti ${wfItems?.[w.kind]?.icon || 'ti-clipboard'}`} style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{w.kind}</span><span className="badge b-amber" style={{ fontSize: 9 }}>Requested</span>
            </div>
          ))}
          {(pendingRx || []).map((r) => (
            <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i><span style={{ flex: 1 }}>{r.drug_name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{r.status}</span>
            </div>
          ))}
        </div>
      )}

      {/* Audit Log is Administrator-only. */}
      {isAdmin && auditLog && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
          <div style={{ maxHeight: 240, overflowY: 'auto' }}>
            {auditLog.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No activity yet.</div>}
            {auditLog.map((a) => (
              <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
                <div>{a.message}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {showSummary && previousVisitSummary && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={() => setShowSummary(false)}>
          <div style={{ width: 480, maxHeight: '80vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <PreviousVisitSummary summary={previousVisitSummary} />
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setShowSummary(false)}>Close</button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Carry Forward: bring an unresolved diagnosis from the last visit
// into this one, without silently duplicating it -- doctor picks. ──
export function CarryForwardDiagnoses({ priorDiagnoses, alreadyAdded, onCarryForward }) {
  const available = priorDiagnoses.filter((pd) => !alreadyAdded.some((d) => d.name === pd.name && d.eye === pd.eye));
  if (available.length === 0) return null;
  return (
    <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Carry forward from last visit</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
        {available.map((pd) => (
          <button key={pd.id} className="btn btn-sm" onClick={() => onCarryForward(pd)}>
            <i className="ti ti-plus"></i> {pd.name} ({pd.eye})
          </button>
        ))}
      </div>
    </div>
  );
}

// ── New investigations since the last visit, with results ready ──
export function NewInvestigationsSinceLastVisit({ investigations, matchInvestigationType, summarizeResultData }) {
  if (!investigations || investigations.length === 0) return null;
  return (
    <div style={{ background: 'var(--teal-lt)', borderRadius: 8, padding: 10, marginBottom: 12 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--teal)', marginBottom: 6 }}>
        <i className="ti ti-flask"></i> New since last visit -- {investigations.length} result{investigations.length > 1 ? 's' : ''} ready
      </div>
      {investigations.map((i) => {
        const isBiometry = isBiometryTitle(i.name);
        const type = matchInvestigationType(i.name);
        return (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', fontSize: 12.5 }}>
            <span><strong>{i.name}</strong> -- {i.eye} -- <span style={{ color: 'var(--g500)' }}>{isBiometry ? 'Measured' : summarizeResultData(type, i.result_data)}</span></span>
            {isBiometry ? (
              <button className="btn btn-sm" onClick={() => window.open('/biometry', '_blank', 'noopener,noreferrer')}>
                <i className="ti ti-ruler-measure"></i> Open Biometry
              </button>
            ) : (
              <button className="btn btn-sm" onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                <i className="ti ti-eye"></i> View
              </button>
            )}
          </div>
        );
      })}
    </div>
  );
}

// ── Visit Outcome selector ──
export function VisitOutcomeSelector({ value, onChange, disabled }) {
  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--purple)' }}></i> Visit Outcome</div>
      <select className="fi" value={value || ''} onChange={(e) => onChange(e.target.value)} disabled={disabled}>
        <option value="">-- Select outcome --</option>
        {VISIT_OUTCOMES.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

__VEDA_FILE_15_END__

cat > "app/print-templates/actions.js" << '__VEDA_FILE_16_END__'
'use server';

import { createClient } from '@/lib/supabase-server';
import Handlebars from 'handlebars';
import { matchInvestigationType, getFullFieldValues } from '@/app/(main)/investigation/investigation-types';
import { plainFrequency, groupPrescriptionsForPrint } from '@/lib/prescriptionFormatting';

// ── Editable print templates ──────────────────────────────────────────
// Each template's HTML lives here as a code-level DEFAULT (versioned,
// reviewable) which the database can override once someone edits and
// saves it from the Print Templates admin page. getPrintTemplate()
// always returns *something renderable* -- the DB row if one exists,
// otherwise this default -- so there's never a missing-template state.
//
// Hospital-wide info (name, address, logo, etc) is deliberately NOT
// hardcoded into these templates -- it lives in hospital_settings and
// gets merged into the render context, edited once as a proper form
// rather than hunted down inside every template's HTML.
//
// Templates use Handlebars {field} tokens ({{field}} for the one
// HTML field, the logo). All formatting (currency, dates) happens in
// the *data-building* functions below, so editors only ever see plain
// tokens, never format-string logic.

const DEFAULT_TEMPLATES = {
  invoice_opd: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    OPD BILL/INVOICE\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  invoice_surgery: "<div style=\"max-width: 800px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">\n        {{{logo_html}}}\n      </td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 26px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 12px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 11px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 11px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        <br/>\n        Tel: {{hospital_phone}}<br/>\n        <strong>{{hospital_email}}</strong>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    SURGERY BILL\n  </div>\n\n  <!-- PATIENT / BILL INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 130px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT ID</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PATIENT NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE NUMBER</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY</td><td>: <strong>{{surgery_name}} ({{surgery_code}})</strong></td></tr>\n          <tr><td style=\"color: #444;\">OPERATED EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">PACKAGE</td><td>: <strong>{{package_name}} ({{package_code}})</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 140px; color: #444;\">BILL NO</td><td>: <strong>{{bill_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">BILL DATE</td><td>: <strong>{{bill_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n          <tr><td colspan=\"2\">&nbsp;</td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR NAME</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">HOSPITAL REGN NO</td><td>: <strong>{{hospital_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- ITEMS -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 4px; font-size: 12px;\">\n    <thead>\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 50px;\">S.NO</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: left;\">Billing_Item</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: center; width: 70px;\">QTY</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 110px;\">RATE</th>\n        <th style=\"border: 1px solid #999; padding: 8px; text-align: right; width: 120px;\">AMOUNT</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each items}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{sno}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px;\">{{name}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{qty}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{rate}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n\n  {{#if has_breakup}}\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 16px; font-size: 11.5px;\">\n    <thead>\n      <tr>\n        <th style=\"text-align: left; padding: 4px 8px; font-weight: 700; color: #555;\">Package Includes</th>\n        <th style=\"text-align: right; padding: 4px 8px; font-weight: 700; color: #555; width: 120px;\">Indicative Amount</th>\n      </tr>\n    </thead>\n    <tbody>\n      {{#each package_breakup}}\n      <tr>\n        <td style=\"padding: 3px 8px; color: #444;\">{{description}}</td>\n        <td style=\"padding: 3px 8px; text-align: right; color: #444;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </tbody>\n  </table>\n  {{/if}}\n\n  <!-- TOTALS -->\n  <table style=\"width: 260px; margin: 14px 0 0 auto; border-collapse: collapse; font-size: 12px;\">\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">GROSS AMOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{gross_amount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">DISCOUNT</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right;\">{{discount}}</td>\n    </tr>\n    <tr>\n      <td style=\"border: 1px solid #999; background: #e9edf2; padding: 6px 10px; font-weight: 700;\">NET AMOUNT PAYABLE</td>\n      <td style=\"border: 1px solid #999; padding: 6px 10px; text-align: right; font-weight: 700;\">{{net_amount}}</td>\n    </tr>\n  </table>\n\n  <!-- SIGNATURE + PAYMENT DETAILS -->\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 45%; vertical-align: bottom; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n      <td style=\"width: 55%; vertical-align: top;\">\n        <div style=\"font-size: 12px; margin-bottom: 6px;\">Payment Details</div>\n        <table style=\"width: 100%; border-collapse: collapse; font-size: 11.5px;\">\n          <tr style=\"background: #e9edf2;\">\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment Date</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Ref Number</th>\n            <th style=\"border: 1px solid #999; padding: 6px;\">Payment</th>\n          </tr>\n          {{#each payments}}\n          <tr>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{date}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: center;\">{{ref_number}}</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n          </tr>\n          {{/each}}\n          <tr>\n            <td colspan=\"2\" style=\"border: 1px solid #999; padding: 6px; background: #e9edf2; font-weight: 700;\">Payments Received</td>\n            <td style=\"border: 1px solid #999; padding: 6px; text-align: right; font-weight: 700;\">{{total_paid}}</td>\n          </tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- TERMS -->\n  <div style=\"margin-top: 30px; font-size: 11.5px;\">\n    <div style=\"font-weight: 700; margin-bottom: 4px;\">Terms &amp; Conditions</div>\n    <div>{{terms_text}}</div>\n    <div style=\"margin-top: 4px;\">For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}</div>\n  </div>\n\n</div>\n",
  receipt: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    PAYMENT RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  {{#if hasAllocations}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Applied Against</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Invoice No</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount Applied</th>\n      </tr>\n      {{#each allocations}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{invoiceNumber}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  receipt_advance: "<div style=\"max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    ADVANCE RECEIPT\n  </div>\n\n  <!-- RECEIVED FROM / RECEIPT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; border-right: 1px solid #999;\">\n        <div style=\"font-size: 10px; color: #666; text-transform: uppercase;\">Received From</div>\n        <div style=\"font-size: 14px; font-weight: 700;\">{{patient_name}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_id}}</div>\n        <div style=\"font-size: 11.5px; color: #444;\">{{patient_mobile}}</div>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 90px; color: #444;\">Receipt No</td><td>: <strong>{{receipt_no}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Date</td><td>: <strong>{{receipt_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Type</td><td>: <strong>{{payment_type_label}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">Collected By</td><td>: <strong>{{collected_by}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- AMOUNT -->\n  <div style=\"background: #e3f5ec; border: 1.5px solid #157a4f; border-radius: 8px; padding: 14px; text-align: center; margin-bottom: 18px;\">\n    <div style=\"font-size: 10.5px; color: #157a4f; text-transform: uppercase; letter-spacing: .5px;\">Advance Amount Received</div>\n    <div style=\"font-size: 26px; font-weight: 800; color: #157a4f;\">{{amount_received}}</div>\n    <div style=\"font-size: 11px; color: #157a4f; margin-top: 2px;\">{{amount_in_words}}</div>\n  </div>\n\n  \n\n  <div style=\"background: #f6ecd7; border: 1px solid #a6791f; border-radius: 8px; padding: 10px 14px; font-size: 11.5px; color: #7d5a12; margin-bottom: 16px;\">\n    <i></i>This advance is held against {{patient_name}}\\'s account and will be adjusted against future invoices.\n  </div>\n\n  <!-- PAYMENT MODES -->\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; margin-bottom: 6px;\">Payment Mode(s)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: left;\">Mode</th>\n        <th style=\"border: 1px solid #999; padding: 6px; text-align: right;\">Amount</th>\n      </tr>\n      {{#each modes}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 6px;\">{{mode}}</td>\n        <td style=\"border: 1px solid #999; padding: 6px; text-align: right;\">{{amount}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n\n  {{#if reference}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Reference: {{reference}}</div>{{/if}}\n  {{#if remarks}}<div style=\"font-size: 11.5px; color: #444; margin-bottom: 4px;\">Remarks: {{remarks}}</div>{{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>AUTHORISED SIGNATURE</div>\n        <div>FOR {{hospital_name}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;\">\n    This is a computer-generated receipt.\n  </div>\n</div>\n",
  opd_case_sheet: "<style>\n  @media print {\n    @page { size: A4; margin: 8mm 10mm; }\n  }\n</style>\n<div style=\"max-width: 800px; margin: 0 auto; padding: 10px 16px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 10.5px; line-height: 1.3;\">\n\n  {{#if hide_header}}\n  <!-- Header hidden -- printing on pre-printed letterhead. Blank space\n       left at top matches the pad's own header height. -->\n  <div style=\"height: {{header_space_cm}}cm;\"></div>\n  {{else}}\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 3px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 16px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 9px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 8.5px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 9px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n  {{/if}}\n\n  <div style=\"text-align: center; font-size: 13px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 4px 0; margin: 5px 0 6px;\">\n    OPD CASE SHEET\n  </div>\n\n  <!-- PATIENT / VISIT INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 8px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 5px 10px; vertical-align: top; font-size: 10px; line-height: 1.35;\">\n        <table style=\"width: 100%; font-size: 10px;\">\n          <tr><td style=\"width: 100px; color: #444;\">VISIT DATE</td><td>: <strong>{{visit_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">VISIT TYPE</td><td>: <strong>{{visit_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>{{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- CHIEF COMPLAINT -->\n  {{#if chief_complaint}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Chief Complaint</div>\n    <div style=\"font-size: 10.5px;\">{{chief_complaint}}{{#if hx_duration}} -- {{hx_duration}}{{/if}}{{#if hx_laterality}} ({{hx_laterality}}){{/if}}</div>\n    {{#if hx_hopi}}<div style=\"font-size: 10px; color: #444; margin-top: 3px;\">{{hx_hopi}}</div>{{/if}}\n  </div>\n  {{/if}}\n\n  <!-- STRUCTURED HISTORY -->\n  {{#if hasHistory}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">History</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each historyLines}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 130px; color: #444; vertical-align: top;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{text}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- VISION / IOP -->\n  {{#if hasVision}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Vision &amp; Intraocular Pressure</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#if hasViUnaided}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Unaided)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_unaided}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_unaided}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViGlasses}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (With Glasses)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_glasses}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_glasses}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViPh}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Pinhole)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_ph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_ph}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasViNear}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">Vision (Near)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_vision_near}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_vision_near}}</td>\n      </tr>\n      {{/if}}\n      {{#if hasIop}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg){{#if iop_method}} -- {{iop_method}}{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re_iop}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le_iop}}</td>\n      </tr>\n      {{/if}}\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasDistRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{dist_rx_source}}) -- Distance</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{dist_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dist_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  {{#if hasNearRx}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Refraction ({{near_rx_source}}) -- Near</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 70px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">SPH</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">CYL</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">AXIS</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">VA</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">RE (OD)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_re_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_re_va}}</td>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 700;\">LE (OS)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center; font-weight: 600;\">{{near_le_sph}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_cyl}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_axis}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{near_le_va}}</td>\n      </tr>\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADDITIONAL PRE-OP TESTS -->\n  {{#if hasAdditionalTests}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Additional Tests</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each additionalTests}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- OPTOMETRY OBSERVATIONS -->\n  {{#if hasOptObservations}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Optometry Observations</div>\n    <div style=\"font-size: 10.5px;\">{{optObservations}}</div>\n  </div>\n  {{/if}}\n\n  <!-- EXAMINATION -->\n  {{#if hasExamination}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Examination Findings</div>\n\n    {{#if hasExternal}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">External Examination</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each externalRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasAnterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Anterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each anteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasPosterior}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Posterior Segment</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each posteriorRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#if hasApplanation}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Applanation Tonometry</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (OD)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (OS)</th>\n      </tr>\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">IOP (mmHg)</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{applanation_le}}</td>\n      </tr>\n    </table>\n    {{/if}}\n\n    {{#if hasGonioscopy}}\n    <div style=\"font-size: 9px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px; padding-left: 6px; border-left: 2px solid #ccc;\">Gonioscopy</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px; margin-bottom: 5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left; width: 46%;\"></th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Right Eye (RE)</th>\n        <th style=\"border: 1px solid #999; padding: 3px; width: 27%;\">Left Eye (LE)</th>\n      </tr>\n      {{#each gonioscopyRows}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px; font-weight: 600;\">{{structure}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{re}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{le}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n\n    {{#unless hasExternal}}{{#unless hasAnterior}}{{#unless hasPosterior}}{{#unless hasApplanation}}{{#unless hasGonioscopy}}\n    <div style=\"font-size: 10px; color: #666; margin-bottom: 3px;\">External Examination and Anterior Segment -- all findings within normal limits. No Posterior Segment, Applanation Tonometry, or Gonioscopy data recorded.</div>\n    {{/unless}}{{/unless}}{{/unless}}{{/unless}}{{/unless}}\n\n    {{#if hasExamExtra}}\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Clinical Remarks</div>\n    <table style=\"width: 100%; font-size: 10px; border-collapse: collapse;\">\n      {{#each examExtra}}\n      <tr>\n        <td style=\"padding: 2px 0; width: 150px; color: #444;\">{{label}}</td>\n        <td style=\"padding: 2px 0;\">{{value}}</td>\n      </tr>\n      {{/each}}\n    </table>\n    {{/if}}\n  </div>\n  {{/if}}\n\n  <!-- DIAGNOSIS -->\n  {{#if hasDiagnoses}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Diagnosis</div>\n    <ul style=\"margin: 0; padding-left: 18px; font-size: 10.5px;\">\n      {{#each diagnoses}}\n      <li>{{name}} -- {{eye}}{{#if notes}} ({{notes}}){{/if}}</li>\n      {{/each}}\n    </ul>\n  </div>\n  {{/if}}\n\n  <!-- SURGERY ADVISED -->\n  {{#if hasSurgery}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Surgery Advised</div>\n    <div style=\"font-size: 10.5px;\">{{surgery_procedure_name}} -- {{surgery_eye}}{{#if surgery_decision}} -- Patient Decision: {{surgery_decision}}{{/if}}</div>\n  </div>\n  {{/if}}\n\n  <!-- PRESCRIPTION -->\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 3px;\">Prescription (Rx)</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 10px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 3px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Frequency</th>\n        <th style=\"border: 1px solid #999; padding: 3px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 3px;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 8.5px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 3px; text-align: center; font-size: 9px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 3px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{/if}}\n\n  <!-- ADVICE -->\n  {{#if advice}}\n  <div style=\"margin-bottom: 6px;\">\n    <div style=\"font-size: 9.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 2px;\">Advice</div>\n    <div style=\"font-size: 10.5px; white-space: pre-wrap;\">{{advice}}</div>\n  </div>\n  {{/if}}\n\n  <!-- FOLLOW UP -->\n  {{#if followup_text}}\n  <div style=\"background: #e7eff8; border: 1px solid #1e4e8c; border-radius: 8px; padding: 5px 10px; font-size: 10.5px; color: #123a66; margin-bottom: 8px;\">\n    <strong>Follow-up:</strong> {{followup_text}}\n  </div>\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 14px;\">\n    <tr>\n      <td style=\"font-size: 10px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 10px;\">\n        <div>{{doctor_name}}</div>\n        <div style=\"font-size: 9px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 8px; font-size: 9px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n",
  glasses_prescription: `<div style="max-width: 650px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  {{#if hide_header}}
  <!-- Header hidden -- printing on pre-printed letterhead / prescription
       pad. Blank space left at the top matches the pad's own header
       height so the printed content starts below it. -->
  <div style="height: {{header_space_cm}}cm;"></div>
  {{else}}
  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>
  {{/if}}

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    SPECTACLE PRESCRIPTION
  </div>

  <!-- PATIENT / RX INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444;">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>{{rx_date}}</strong></td></tr>
          <tr><td style="color: #444;">VA SCALE</td><td>: <strong>{{va_scale}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  {{#if hasDistRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Distance</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{dist_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{dist_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#if hasNearRx}}
  <div style="margin-bottom: 16px;">
    <div style="font-size: 12px; font-weight: 700; text-transform: uppercase; color: #1e4e8c; margin-bottom: 6px;">Near</div>
    <table style="width: 100%; border-collapse: collapse; font-size: 13px;">
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 70px;">Eye</th>
        <th style="border: 1px solid #999; padding: 8px;">SPH</th>
        <th style="border: 1px solid #999; padding: 8px;">CYL</th>
        <th style="border: 1px solid #999; padding: 8px;">AXIS</th>
        <th style="border: 1px solid #999; padding: 8px;">VA</th>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">RE (OD)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_re_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_re_va}}</td>
      </tr>
      <tr>
        <td style="border: 1px solid #999; padding: 8px; font-weight: 700;">LE (OS)</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center; font-weight: 600;">{{near_le_sph}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_cyl}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_axis}}</td>
        <td style="border: 1px solid #999; padding: 8px; text-align: center;">{{near_le_va}}</td>
      </tr>
    </table>
  </div>
  {{/if}}

  {{#unless hasDistRx}}{{#unless hasNearRx}}
  <div style="padding: 20px; text-align: center; color: #9ca3af; font-size: 12px; border: 1px dashed #d1d5db; border-radius: 8px; margin-bottom: 16px;">
    No Final Rx recorded for this assessment.
  </div>
  {{/unless}}{{/unless}}

  <table style="width: 60%; margin-bottom: 20px; font-size: 12px;">
    <tr>
      <td style="padding: 4px 0; color: #444;">IPD (Interpupillary Distance)</td>
      <td style="padding: 4px 0; text-align: right; font-weight: 700;">{{ipd}}</td>
    </tr>
  </table>

  <div style="background: #eef2f7; border-left: 3px solid #1e4e8c; padding: 8px 12px; font-size: 11.5px; color: #444; margin-bottom: 30px;">
    This prescription is valid for 6 months from the date of issue. Please carry this slip to your optician.
  </div>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 50%; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;">
          <div style="font-weight: 600;">{{optometrist_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Optometrist</div>
        </div>
      </td>
      <td style="width: 50%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;">
          <div style="font-weight: 600;">{{doctor_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{doctor_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  biometry_report: `<div style="max-width: 720px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">

  <!-- HEADER -->
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">{{{logo_html}}}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 22px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">{{hospital_name}}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">{{hospital_unit_line}}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : {{hospital_regn_no}}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        {{hospital_address_line1}}<br/>
        {{hospital_address_line2}}<br/>
        {{hospital_city_state_pin}}<br/>
        Tel: {{hospital_phone}}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; letter-spacing: .5px; border-top: 1.5px solid #1e4e8c; border-bottom: 1.5px solid #1e4e8c; padding: 8px 0; margin: 10px 0 16px; color: #1e4e8c;">
    IOL BIOMETRY &amp; POWER CALCULATION REPORT
  </div>

  <!-- PATIENT / SURGICAL INFO -->
  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 55%; padding: 10px 14px; vertical-align: top; font-size: 12px; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 100px; color: #444; padding: 2px 0;">PATIENT ID</td><td style="padding: 2px 0;">: <strong>{{patient_id}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">NAME</td><td style="padding: 2px 0;">: <strong>{{patient_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">AGE/GENDER</td><td style="padding: 2px 0;">: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">VISIT NO</td><td style="padding: 2px 0;">: <strong>{{visit_number}}</strong></td></tr>
        </table>
      </td>
      <td style="width: 45%; padding: 10px 14px; vertical-align: top; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 90px; color: #444; padding: 2px 0;">DATE</td><td style="padding: 2px 0;">: <strong>{{report_date}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">PROCEDURE</td><td style="padding: 2px 0;">: <strong>{{procedure_name}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">EYE</td><td style="padding: 2px 0;">: <strong>{{surgical_eye}}</strong></td></tr>
          <tr><td style="color: #444; padding: 2px 0;">SURGEON</td><td style="padding: 2px 0;">: <strong>{{surgeon_name}}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <!-- BIOMETRY READINGS -->
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">Biometry Readings</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 50%; vertical-align: top; padding-right: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Right Eye (RE / OD) -- Oculus Dexter</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasReReadings}}
          {{#each reSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
      <td style="width: 50%; vertical-align: top; padding-left: 8px;">
        <div style="background: #e9edf2; padding: 6px 10px; font-size: 12px; font-weight: 700; border-radius: 6px 6px 0 0;">Left Eye (LE / OS) -- Oculus Sinister</div>
        <div style="border: 1px solid #999; border-top: none; border-radius: 0 0 6px 6px; padding: 8px 10px;">
          {{#if hasLeReadings}}
          {{#each leSets}}
          <div style="margin-bottom: 8px; padding-bottom: 8px; {{#unless @last}}border-bottom: 1px dashed #ccc;{{/unless}}">
            <table style="width: 100%; font-size: 11.5px;">
              <tr><td style="color: #555; padding: 1px 0;">Axial Length</td><td style="text-align: right; font-weight: 600;">{{axl}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K1</td><td style="text-align: right; font-weight: 600;">{{k1}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">K2</td><td style="text-align: right; font-weight: 600;">{{k2}} D</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">ACD</td><td style="text-align: right; font-weight: 600;">{{acd}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">Lens Thickness</td><td style="text-align: right; font-weight: 600;">{{lt}} mm</td></tr>
              <tr><td style="color: #555; padding: 1px 0;">White-to-White</td><td style="text-align: right; font-weight: 600;">{{wtw}} mm</td></tr>
            </table>
          </div>
          {{/each}}
          {{else}}
          <div style="font-size: 11.5px; color: #9ca3af;">No readings recorded.</div>
          {{/if}}
        </div>
      </td>
    </tr>
  </table>

  <!-- IOL POWER CALCULATION -->
  {{#if hasFormulaResults}}
  <div style="font-size: 13px; font-weight: 700; color: #1e4e8c; margin-bottom: 8px; text-transform: uppercase;">IOL Power Calculation</div>
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 18px; font-size: 12px;">
    <tr style="background: #e9edf2;">
      <th style="border: 1px solid #999; padding: 7px; text-align: left;">Formula</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">IOL Power</th>
      <th style="border: 1px solid #999; padding: 7px; text-align: center;">Predicted Refraction</th>
    </tr>
    {{#each formulaResults}}
    <tr style="{{#if isSelected}}background: #f0fdf4; font-weight: 700;{{/if}}">
      <td style="border: 1px solid #999; padding: 7px;">{{name}}{{#if isSelected}} <span style="color: #16a34a;">(Selected)</span>{{/if}}</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{power}} D</td>
      <td style="border: 1px solid #999; padding: 7px; text-align: center;">{{refraction}}</td>
    </tr>
    {{/each}}
  </table>
  {{/if}}

  <!-- FINAL APPROVED PLAN -->
  <div style="font-size: 13px; font-weight: 700; color: #16a34a; margin-bottom: 8px; text-transform: uppercase;">Final Approved Plan</div>
  <table style="width: 100%; border: 1.5px solid #16a34a; border-collapse: collapse; margin-bottom: 18px; background: #f0fdf4;">
    <tr>
      <td style="padding: 10px 14px; font-size: 12px;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 160px; color: #444; padding: 3px 0;">Final IOL Power</td><td style="padding: 3px 0;"><strong>{{final_iol_power}} D</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Formula Used</td><td style="padding: 3px 0;"><strong>{{final_iol_formula}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">IOL Category</td><td style="padding: 3px 0;"><strong>{{final_iol_category}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Lens</td><td style="padding: 3px 0;"><strong>{{final_iol_lens}}</strong></td></tr>
          <tr><td style="color: #444; padding: 3px 0;">Target Refraction</td><td style="padding: 3px 0;"><strong>{{target_refraction}}</strong></td></tr>
          {{#if surgeon_notes}}
          <tr><td style="color: #444; padding: 3px 0; vertical-align: top;">Surgeon Notes</td><td style="padding: 3px 0;">{{surgeon_notes}}</td></tr>
          {{/if}}
          <tr><td style="color: #444; padding: 3px 0;">Approved On</td><td style="padding: 3px 0;">{{approved_date}}</td></tr>
        </table>
      </td>
    </tr>
  </table>

  <table style="width: 100%; margin-top: 40px; border-collapse: collapse;">
    <tr>
      <td style="width: 100%; text-align: right; font-size: 12px; vertical-align: bottom;">
        <div style="border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px; margin-left: auto;">
          <div style="font-weight: 600;">{{surgeon_name}}</div>
          <div style="font-size: 10px; color: #9ca3af;">Reg No: {{surgeon_regn_no}}</div>
        </div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 24px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}
  </div>
</div>
`,
  discharge_summary: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <!-- HEADER -->\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline; color: #0f766e;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #0f766e; border-bottom: 1.5px solid #0f766e; padding: 8px 0; margin: 10px 0 16px; color: #0f766e;\">\n    DISCHARGE SUMMARY\n  </div>\n\n  <!-- PATIENT / SURGEON INFO -->\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">SURGEON</td><td>: <strong>Dr. {{surgeon_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ADMISSION</td><td>: <strong>{{admission_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">SURGERY DATE</td><td>: <strong>{{surgery_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DISCHARGE DATE</td><td>: <strong>{{discharge_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  <!-- PROCEDURE SUMMARY -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Procedure Summary</div>\n    <div style=\"font-size: 13px; padding: 2px 0;\">Procedure: <strong>{{procedure_name}}</strong> ({{eye}})</div>\n    {{#each iol_lines}}\n    <div style=\"font-size: 13px; padding: 2px 0;\">IOL ({{eye}}): <strong>{{text}}</strong></div>\n    {{/each}}\n  </div>\n\n  <!-- MEDICATIONS -->\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Medications</div>\n    {{#unless hasMedications}}<div style=\"font-size: 12px; color: #9ca3af;\">None prescribed.</div>{{/unless}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <tbody>\n        {{#each medications}}\n        <tr>\n          <td style=\"padding: 4px 8px 4px 0; font-weight: 600;\">{{name}}</td>\n          <td style=\"padding: 4px 0; color: #4b5563;\">{{sig}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  {{#if hasDischargeNotes}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Notes (Doctor)</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_notes}}</div>\n  </div>\n  {{/if}}\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Discharge Instructions</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{discharge_instructions}}</div>\n  </div>\n\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #0f766e; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Follow-up Schedule</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12px;\">\n      <thead>\n        <tr style=\"background: #f0fdfa;\">\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Visit</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Date</th>\n          <th style=\"text-align: left; padding: 5px 8px; color: #0f766e;\">Status</th>\n        </tr>\n      </thead>\n      <tbody>\n        {{#each followups}}\n        <tr>\n          <td style=\"padding: 4px 8px;\">{{visit_label}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{date}}</td>\n          <td style=\"padding: 4px 8px; color: #4b5563;\">{{status}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n  </div>\n\n  <div style=\"margin-top: 50px; display: flex; justify-content: flex-end;\">\n    <div style=\"text-align: center; border-top: 1px solid #9ca3af; padding-top: 6px; width: 220px;\">\n      <div style=\"font-size: 12px; font-weight: 600;\">Dr. {{surgeon_name}}</div>\n      <div style=\"font-size: 10px; color: #9ca3af;\">Signature</div>\n    </div>\n  </div>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 11px; color: #9ca3af;\">\n    This is a computer-generated discharge summary -- {{hospital_name}}.\n  </div>\n</div>\n",
  investigation_report: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    INVESTIGATION REPORT\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 100px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">INVESTIGATION</td><td>: <strong>{{investigation_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">TYPE</td><td>: <strong>{{investigation_type}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">EYE</td><td>: <strong>{{eye}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED BY</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">ORDERED ON</td><td>: <strong>{{ordered_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">COMPLETED ON</td><td>: <strong>{{completed_date}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if isUnable}}\n  <div style=\"background: #fef2f2; border: 1px solid #b91c1c; border-radius: 8px; padding: 10px 14px; font-size: 12.5px; color: #b91c1c; margin-bottom: 16px;\">\n    <strong>Unable to perform:</strong> {{unable_reason}}\n  </div>\n  {{else}}\n\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Findings</div>\n    {{#if hasFields}}\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tbody>\n        {{#each fields}}\n        <tr>\n          <td style=\"padding: 5px 8px 5px 0; width: 45%; color: #444; border-bottom: 1px solid #f3f4f6;\">{{label}}</td>\n          <td style=\"padding: 5px 0; font-weight: 600; border-bottom: 1px solid #f3f4f6;\">{{value}}</td>\n        </tr>\n        {{/each}}\n      </tbody>\n    </table>\n    {{else}}\n    <div style=\"font-size: 12px; color: #9ca3af;\">No measurements recorded.</div>\n    {{/if}}\n  </div>\n\n  {{#if hasNotes}}\n  <div style=\"margin-bottom: 16px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; border-bottom: 1px solid #e5e7eb; padding-bottom: 4px; margin-bottom: 8px;\">Notes</div>\n    <div style=\"font-size: 13px; white-space: pre-wrap;\">{{result_notes}}</div>\n  </div>\n  {{/if}}\n  {{/if}}\n\n  <table style=\"width: 100%; margin-top: 50px; border-collapse: collapse;\">\n    <tr>\n      <td style=\"width: 50%; vertical-align: bottom; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px;\">\n          <div style=\"font-weight: 600;\">{{technician_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Performed by</div>\n        </div>\n      </td>\n      {{#if hasVerifiedBy}}\n      <td style=\"width: 50%; vertical-align: bottom; text-align: right; font-size: 12px;\">\n        <div style=\"border-top: 1px solid #9ca3af; padding-top: 6px; width: 200px; margin-left: auto;\">\n          <div style=\"font-weight: 600;\">{{verified_by_name}}</div>\n          <div style=\"font-size: 10px; color: #9ca3af;\">Verified by</div>\n        </div>\n      </td>\n      {{/if}}\n    </tr>\n  </table>\n\n  <div style=\"margin-top: 30px; text-align: center; font-size: 10.5px; color: #999;\">\n    This is a computer-generated report -- {{hospital_name}}.\n  </div>\n</div>\n",
  medicine_prescription: "<div style=\"max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;\">\n\n  <table style=\"width: 100%; border-collapse: collapse; margin-bottom: 6px;\">\n    <tr>\n      <td style=\"width: 100px; vertical-align: top;\">{{{logo_html}}}</td>\n      <td style=\"vertical-align: top;\">\n        <div style=\"font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;\">{{hospital_name}}</div>\n        <div style=\"font-size: 11px; font-weight: 700; margin-top: 2px;\">{{hospital_unit_line}}</div>\n        <div style=\"font-size: 10px; font-weight: 700;\">REGN NO : {{hospital_regn_no}}</div>\n      </td>\n      <td style=\"text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;\">\n        {{hospital_address_line1}}<br/>\n        {{hospital_address_line2}}<br/>\n        {{hospital_city_state_pin}}<br/>\n        Tel: {{hospital_phone}}\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;\">\n    MEDICINE PRESCRIPTION\n  </div>\n\n  <table style=\"width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 16px;\">\n    <tr>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">PATIENT ID</td><td>: <strong>{{patient_id}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">NAME</td><td>: <strong>{{patient_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">AGE/GENDER</td><td>: <strong>{{patient_age}} / {{patient_gender}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">MOBILE</td><td>: <strong>{{patient_mobile}}</strong></td></tr>\n        </table>\n      </td>\n      <td style=\"width: 50%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;\">\n        <table style=\"width: 100%; font-size: 12px;\">\n          <tr><td style=\"width: 110px; color: #444;\">VISIT NO</td><td>: <strong>{{visit_number}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DATE</td><td>: <strong>{{print_date}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR</td><td>: <strong>Dr. {{doctor_name}}</strong></td></tr>\n          <tr><td style=\"color: #444;\">DOCTOR REGN NO</td><td>: <strong>{{doctor_regn_no}}</strong></td></tr>\n        </table>\n      </td>\n    </tr>\n  </table>\n\n  {{#if hasPrescriptions}}\n  <div style=\"margin-bottom: 14px;\">\n    <div style=\"font-size: 11.5px; font-weight: 700; text-transform: uppercase; color: #444; margin-bottom: 6px;\">Medicines Prescribed</div>\n    <table style=\"width: 100%; border-collapse: collapse; font-size: 12.5px;\">\n      <tr style=\"background: #e9edf2;\">\n        <th style=\"border: 1px solid #999; padding: 7px; text-align: left;\">Medicine</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Eye</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Dosage</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">How Often</th>\n        <th style=\"border: 1px solid #999; padding: 7px;\">Duration</th>\n      </tr>\n      {{#each prescriptions}}\n      <tr>\n        <td style=\"border: 1px solid #999; padding: 7px; font-weight: 600;\">{{drug}}{{#if isTaper}} <span style=\"font-size: 9px; font-weight: 700; color: #7c3aed; text-transform: uppercase;\">(Taper)</span>{{/if}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{eye}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{dosage}}</td>\n        {{#if isTaper}}\n        <td colspan=\"2\" style=\"border: 1px solid #999; padding: 7px; text-align: center; font-size: 11.5px;\">{{frequency}}</td>\n        {{else}}\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{frequency}}</td>\n        <td style=\"border: 1px solid #999; padding: 7px; text-align: center;\">{{duration}}</td>\n        {{/if}}\n      </tr>\n      {{/each}}\n    </table>\n  </div>\n  {{else}}\n  <div style=\"font-size: 12.5px; color: #9ca3af; margin-bottom: 14px;\">No medicines prescribed for this visit.</div>\n  {{/if}}\n\n  <div style=\"background: #eef4fb; border: 1px solid #1e4e8c; border-radius: 8px; padding: 10px 14px; font-size: 12px; color: #123a66; margin-bottom: 20px;\">\n    Please take medicines exactly as instructed above. If you have any doubt about how to use a medicine, ask the pharmacist before you leave.\n  </div>\n\n  <table style=\"width: 100%; margin-top: 40px;\">\n    <tr>\n      <td style=\"font-size: 12px;\">&nbsp;</td>\n      <td style=\"text-align: right; font-size: 12px;\">\n        <div>Dr. {{doctor_name}}</div>\n        <div style=\"font-size: 10.5px; color: #666;\">Reg No: {{doctor_regn_no}}</div>\n      </td>\n    </tr>\n  </table>\n\n  <div style=\"text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;\">\n    For any Queries please contact us at {{hospital_phone}} or Email us at {{hospital_email}}\n  </div>\n</div>\n"
};

const PRINT_TEMPLATE_CATALOG = [
  { key: 'invoice_opd', name: 'OPD Bill / Invoice', description: 'Printed for OPD invoices (Billing module -> Print).' },
  { key: 'invoice_surgery', name: 'Surgery Bill / Invoice', description: 'Printed for invoices containing a surgical package.' },
  { key: 'receipt', name: 'Payment Receipt', description: 'Printed for a payment collected against one or more invoices.' },
  { key: 'receipt_advance', name: 'Advance Receipt', description: 'Printed when an advance is collected, before it is applied to any invoice.' },
  { key: 'opd_case_sheet', name: 'OPD Case Sheet', description: 'Handed to the patient after an OPD consultation -- complaint, findings, diagnosis, prescription, advice, follow-up.' },
  { key: 'glasses_prescription', name: 'Glasses Prescription', description: 'Printed from the Optometry screen -- Final Rx spectacle prescription for the patient / optician.' },
  { key: 'biometry_report', name: 'Biometry Report', description: 'Printed from Surgeon Approval (Biometry) -- raw biometry readings, IOL power calculation, and the final approved plan.' },
  { key: 'investigation_report', name: 'Investigation Report', description: 'Printed for a completed investigation -- findings, notes, technician/verifier sign-off.' },
  { key: 'medicine_prescription', name: 'Medicine Prescription', description: 'Printed from Pharmacy -- the medicine list on its own, independent of the bill, for the patient to keep or take elsewhere.' },
  { key: 'consent_form', name: 'Consent Form', description: 'Coming soon.', comingSoon: true },
  { key: 'discharge_summary', name: 'Discharge Summary', description: 'Printed at Post-op discharge -- procedure, IOL, medications, instructions, follow-up schedule.' },
  { key: 'external_tests_requisition', name: 'External Tests Requisition', description: 'Printed from Surgical Journey -- list of external tests (blood work, HIV test, etc) for the patient to take to an outside lab.' },
];

// ── Hospital Settings -- the "actual fields to edit" form (name,
//    address, logo, etc), shared across every template. Singleton row
//    (id is always `true`). ──
export async function getHospitalSettings() {
  const supabase = await createClient();
  const { data } = await supabase.from('hospital_settings').select('*').eq('id', true).maybeSingle();
  return data || {};
}

export async function saveHospitalSettings(fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('hospital_settings').update({
    ...fields, updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }).eq('id', true);
  if (error) return { error: error.message };
  return { success: true };
}

function logoHtml(settings) {
  if (settings?.logo_data_url) {
    return `<img src="${settings.logo_data_url}" style="width: 88px; height: 88px; object-fit: contain;" />`;
  }
  // Fallback mark if no logo has been uploaded yet.
  return `<svg width="88" height="88" viewBox="0 0 100 100" xmlns="http://www.w3.org/2000/svg">
    <path d="M10 50 Q50 15 90 50 Q50 85 10 50 Z" fill="none" stroke="#1e4e8c" stroke-width="6"/>
    <circle cx="50" cy="50" r="16" fill="#1e4e8c"/>
    <path d="M8 52 Q3 60 12 66 Q10 56 8 52 Z" fill="#a6791f"/>
  </svg>`;
}

export async function listPrintTemplates() {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('template_key, updated_at, updated_by, profiles(full_name)');
  const byKey = {};
  (data || []).forEach((r) => { byKey[r.template_key] = r; });
  return PRINT_TEMPLATE_CATALOG.map((t) => ({
    ...t,
    customized: !!byKey[t.key],
    updatedAt: byKey[t.key]?.updated_at || null,
    updatedBy: byKey[t.key]?.profiles?.full_name || null,
  }));
}

export async function getPrintTemplate(key) {
  const supabase = await createClient();
  const { data } = await supabase.from('print_templates').select('html, updated_at').eq('template_key', key).maybeSingle();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  return {
    key,
    name: catalog?.name || key,
    html: data?.html || DEFAULT_TEMPLATES[key] || '<div>No template found.</div>',
    isCustomized: !!data,
    updatedAt: data?.updated_at || null,
  };
}

export async function savePrintTemplate(key, html) {
  const supabase = await createClient();
  const catalog = PRINT_TEMPLATE_CATALOG.find((t) => t.key === key);
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('print_templates').upsert({
    template_key: key, name: catalog?.name || key, html,
    updated_at: new Date().toISOString(), updated_by: userData?.user?.id || null,
  }, { onConflict: 'template_key' });
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetPrintTemplate(key) {
  const supabase = await createClient();
  const { error } = await supabase.from('print_templates').delete().eq('template_key', key);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Preview arbitrary (possibly unsaved) template HTML against sample
//    data -- lets the editor see changes before committing them. ──
export async function previewTemplateHtml(key, html) {
  try {
    const compiled = Handlebars.compile(html);
    return { html: compiled(await getSampleData(key)) };
  } catch (e) {
    return { error: `Template error: ${e.message}` };
  }
}

// ── Sample data for the admin preview pane -- deliberately fake/generic
//    so editors can see the layout without needing a real invoice. ──
export async function getSampleData(key) {
  const settings = await getHospitalSettings();
  if (key === 'invoice_opd') return buildInvoiceContext(settings, SAMPLE_OPD_RAW);
  if (key === 'invoice_surgery') return buildInvoiceContext(settings, SAMPLE_SURGERY_RAW);
  if (key === 'receipt') return buildReceiptContext(settings, SAMPLE_RECEIPT_RAW);
  if (key === 'receipt_advance') return buildReceiptContext(settings, SAMPLE_ADVANCE_RAW);
  if (key === 'opd_case_sheet') return buildOpdCaseSheetContext(settings, SAMPLE_CASE_SHEET_RAW);
  if (key === 'glasses_prescription') return buildGlassesPrescriptionContext(settings, SAMPLE_GLASSES_RX_RAW);
  if (key === 'biometry_report') return buildBiometryReportContext(settings, SAMPLE_BIOMETRY_RAW);
  if (key === 'discharge_summary') return buildDischargeSummaryContext(settings, SAMPLE_DISCHARGE_RAW);
  if (key === 'investigation_report') return SAMPLE_INVESTIGATION_CONTEXT(settings);
  return {};
}

const SAMPLE_DISCHARGE_RAW = {
  patient: { uhid: 'VEH-00004', first_name: 'Utkarsh', last_name: 'Prakash', mobile: '9876543210', age: 62, gender: 'M' },
  surgeon: { full_name: 'Nisha Bachkheti' },
  procedureName: 'Phaco Cataract Surgery', eye: 'OD',
  episode: {
    admission_date: '2026-06-10', surgery_date: '2026-06-10', discharge_date: '2026-06-11',
    discharge_notes: 'Uneventful surgery. Patient tolerated procedure well.',
    discharge_instructions: 'Avoid rubbing the eye. No water contact for 1 week. Use dark glasses outdoors. Report immediately for redness, pain, or sudden vision loss.',
  },
  intraop: { implant_power: '21.5', implant_manufacturer: 'Alcon', implant_model: 'AcrySof IQ' },
  biometry: [{ surgical_eye: 'OD', final_iol_power: '21.5', final_iol_category: 'Monofocal' }],
  meds: [
    { name: 'Moxifloxacin 0.5%', sig: '1 drop QID x 1 week, then taper' },
    { name: 'Prednisolone Acetate 1%', sig: '1 drop QID x 2 weeks, then taper' },
  ],
  followups: [
    { visit_label: 'Post-op Day 1', scheduled_date: '2026-06-12', status: 'Completed' },
    { visit_label: 'Post-op Week 1', scheduled_date: '2026-06-18', status: 'Scheduled' },
    { visit_label: 'Post-op Month 1', scheduled_date: '2026-07-11', status: 'Scheduled' },
  ],
};

function SAMPLE_INVESTIGATION_CONTEXT(settings) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),
    patient_id: 'VEH-00004', patient_name: 'Utkarsh Prakash', patient_age: 62, patient_gender: 'M', patient_mobile: '9876543210',
    investigation_name: 'OCT Macula', investigation_type: 'OCT', eye: 'OD',
    doctor_name: 'Nisha Bachkheti', ordered_date: '04 Jun 2026', completed_date: '05 Jun 2026',
    isUnable: false, unable_reason: null,
    hasFields: true,
    fields: [
      { label: 'Central Macular Thickness (OD)', value: '245 um' },
      { label: 'RNFL Thickness', value: 'Average 85 um' },
      { label: 'Signal Strength', value: '8/10' },
    ],
    hasNotes: true, result_notes: 'Scan quality good. No macular edema noted.',
    technician_name: 'Rohit Pratap', hasVerifiedBy: true, verified_by_name: 'Nisha Bachkheti',
  };
}

const SAMPLE_OPD_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  invoice: { invoice_number: 'VEH-BILL-0143', created_at: '2026-06-04T00:00:00Z', gross: 300, gst: 0, net: 300, paid: 300, purpose: 'OPD Services' },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_number: 'V26-000042' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  lineItems: [{ service_name: 'OPD Consultation', qty: 1, rate: 300, disc: 0, net: 300, dept: 'Consultation' }],
  payments: [{ created_at: '2026-06-03T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0054', amount: 300 }],
  packageName: null, packageCode: null, surgeryName: null, surgeryCode: null, surgeryEye: null, packageBreakup: [],
};

const SAMPLE_SURGERY_RAW = {
  ...SAMPLE_OPD_RAW,
  invoice: { invoice_number: 'VEH-BILL-0200', created_at: '2026-06-10T00:00:00Z', gross: 35000, gst: 0, net: 35000, paid: 35000, purpose: 'Surgery Package' },
  lineItems: [{ service_name: 'Cataract Surgery Package', qty: 1, rate: 35000, disc: 0, net: 35000, dept: 'Surgery' }],
  payments: [{ created_at: '2026-06-10T00:00:00Z', receipt_number: 'VEH/RECEIPT/-0091', amount: 35000 }],
  packageName: 'Cataract Surgery -- Standard IOL Package', packageCode: 'PKG001',
  surgeryName: 'Phaco Cataract Surgery', surgeryCode: 'SUR012', surgeryEye: 'OD',
  packageBreakup: [
    { description: 'Surgeon fee', amount: 15000 },
    { description: 'IOL (Standard Monofocal)', amount: 8000 },
    { description: 'OT charges', amount: 7000 },
    { description: 'Consumables & disposables', amount: 3000 },
    { description: 'Pre-op investigations', amount: 2000 },
  ],
};

const SAMPLE_RECEIPT_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970' },
  payment: {
    receipt_number: 'VEH/RECEIPT/-0054', collected_at: '2026-06-03T00:00:00Z', total_amount: 300,
    payment_type: 'invoice_payment', reference: null, remarks: null,
  },
  collector: { full_name: 'Front Desk' },
  modes: [{ mode: 'Cash', amount: 300 }],
  allocations: [{ amount: 300, invoices: { invoice_number: 'VEH-BILL-0143' } }],
};

const SAMPLE_ADVANCE_RAW = {
  ...SAMPLE_RECEIPT_RAW,
  payment: {
    receipt_number: 'VEH/RECEIPT/-0060', collected_at: '2026-06-15T00:00:00Z', total_amount: 10000,
    payment_type: 'advance', reference: null, remarks: null,
  },
  modes: [{ mode: 'UPI', amount: 10000 }],
  allocations: [],
};

const SAMPLE_CASE_SHEET_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', mobile: '+919758041970', age: 39, gender: 'Male' },
  encounter: {
    chief_complaint: 'Diminution of vision', hx_duration: '3 months', hx_laterality: 'Both eyes', hx_hopi: 'Gradual, painless, progressive blurring of vision, worse for distance.',
    ocular_history: ['Diabetic Retinopathy screening -- 2024'], medical_history: ['Diabetes Mellitus Type 2'], family_history: ['Glaucoma -- father'],
    drug_history: ['Metformin 500mg BD'], allergy: ['Sulfa drugs'],
    patient_instructions: 'Use prescribed eye drops as directed. Avoid rubbing the eyes. Wear dark glasses outdoors.',
  },
  visit: { created_at: '2026-06-01T00:00:00Z', visit_type: 'New Consultation' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  assessment: {
    re_dist_unaided: '6/18', le_dist_unaided: '6/12', re_dist_glasses: '6/9', le_dist_glasses: '6/6',
    re_dist_ph: '6/6', le_dist_ph: '6/6', re_near_unaided: 'N8', le_near_unaided: 'N6',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '', ref_final_re_near_axis: '', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
    iop_method: 'NCT', add_k1_re: '43.5', add_k1_le: '43.7', add_k2_re: '44.2', add_k2_le: '44.4', add_axial_length_re: '23.4 mm', add_axial_length_le: '23.3 mm',
  },
  iopReadings: [{ eye: 'RE', value: 18 }, { eye: 'LE', value: 16 }],
  examination: {
    external_findings: {}, anterior_findings: { Lens: { re: 'NS2', le: 'NS1', re_custom: '', le_custom: '' } }, posterior_findings: { without: { Disc: { re: 'Healthy', le: 'Healthy' }, CDR: { re: '0.4', le: '0.3' } }, with: {} },
    applanation_re: '16', applanation_le: '15',
    gonioscopy_findings: { angle_re: 'Open Angle', angle_le: 'Open Angle' },
  },
  diagnoses: [{ name: 'Immature Cataract', eye: 'OU', notes: null }],
  prescriptions: [{ drug_name: 'CMC 0.5%', eye: 'BE', dosage: '1 drop', frequency: 'QID', duration: '1 month' }],
  followup: { after_period: '2 weeks', visit_type: 'Follow-up', instructions: null },
};

// Deliberately includes one eye with SPH-only (no CYL/AXIS) so the
// preview shows how a spherical-only Rx renders cleanly.
const SAMPLE_GLASSES_RX_RAW = {
  patient: { patient_code: 'VEH-P-00031', first_name: 'Dharam', last_name: '', age: 39, gender: 'Male' },
  assessment: {
    created_at: '2026-06-01T00:00:00Z', va_scale: 'Snellen', ref_pd: '62mm',
    ref_final_re_dist_sph: '-2.00', ref_final_re_dist_cyl: '-0.50', ref_final_re_dist_axis: '90', ref_final_re_dist_va: '6/6',
    ref_final_le_dist_sph: '-1.50', ref_final_le_dist_cyl: '', ref_final_le_dist_axis: '', ref_final_le_dist_va: '6/6',
    ref_final_re_near_sph: '+1.00', ref_final_re_near_cyl: '-0.50', ref_final_re_near_axis: '90', ref_final_re_near_va: 'N6',
    ref_final_le_near_sph: '+1.00', ref_final_le_near_cyl: '', ref_final_le_near_axis: '', ref_final_le_near_va: 'N6',
  },
  optometrist: { full_name: 'Rohit Pratap' },
  doctor: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
};

const SAMPLE_BIOMETRY_RAW = {
  patient: { uhid: 'VEH000031', first_name: 'Dharam', last_name: '', age: 68, gender: 'Male' },
  visit: { visit_number: 'VN26-000112' },
  record: {
    procedure_name: 'Phacoemulsification with IOL', surgical_eye: 'RE', status: 'Approved',
    created_at: '2026-06-01T00:00:00Z', approved_at: '2026-06-02T00:00:00Z',
    measurements: {
      re: [{ device: 'ZEISS IOLMaster 700', axl: '23.45', k1: '43.25', k2: '44.10', acd: '3.12', lt: '4.50', wtw: '11.80' }],
      le: [{ device: 'ZEISS IOLMaster 700', axl: '23.38', k1: '43.40', k2: '44.05', acd: '3.08', lt: '4.48', wtw: '11.75' }],
    },
    formula_results: [
      { name: 'Barrett Universal II', power: '21.5', refraction: '-0.15' },
      { name: 'SRK/T', power: '21.0', refraction: '-0.30' },
    ],
    selected_formula: 'Barrett Universal II',
    final_iol_power: '21.5', final_iol_category: 'Monofocal', target_refraction: '-0.15 D',
    surgeon_notes: 'Aim for slight myopia. Standard monofocal, no toric correction needed.',
  },
  surgeon: { full_name: 'Dr. Nisha Bachkheti', registration_no: 'UKMC-3436' },
  catalogItem: { brand: 'Alcon', model: 'AcrySof IQ', manufacturer: 'Alcon Laboratories' },
};

// ── Renders the actual invoice HTML for a given invoiceId. Picks the
//    OPD or Surgery variant based on whether any line item was billed
//    under the Surgery department (package billing tags its line item
//    dept: 'Surgery' -- see billing/new/new-invoice-tab.js). ──
export async function renderInvoiceHtml(invoiceId, includeBreakup = false) {
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(uhid, first_name, last_name, mobile, age, gender), visits(id, visit_number, created_at, doctor_id, profiles:doctor_id(full_name, registration_no))')
    .eq('id', invoiceId)
    .single();
  if (error || !invoice) return { error: 'Invoice not found.' };

  const { data: rawLineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');

  // The invoice itself stays itemized (individual medicine names/rates
  // visible in Invoice Details) -- no pharmacy license yet, so only the
  // printed/PDF copy collapses every Pharmacy-dept line into one "OPD
  // Procedure Consumables" line at qty 1 for the combined total.
  const pharmacyLines = (rawLineItems || []).filter((li) => li.dept === 'Pharmacy');
  const nonPharmacyLines = (rawLineItems || []).filter((li) => li.dept !== 'Pharmacy');
  const pharmacyTotal = pharmacyLines.reduce((s, li) => s + Number(li.net), 0);
  const lineItems = pharmacyLines.length > 0
    ? [...nonPharmacyLines, { service_name: 'OPD Procedure Consumables', dept: 'Pharmacy', qty: 1, rate: pharmacyTotal, disc: 0, net: pharmacyTotal }]
    : nonPharmacyLines;

  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('amount, payments(receipt_number, collected_at)')
    .eq('invoice_id', invoiceId);
  const payments = (allocations || []).map((a) => ({
    amount: a.amount, receipt_number: a.payments?.receipt_number, created_at: a.payments?.collected_at,
  }));

  const isSurgery = (rawLineItems || []).some((li) => li.dept === 'Surgery');

  let packageName = null;
  let packageCode = null;
  let surgeryName = null;
  let surgeryCode = null;
  let surgeryEye = null;
  let surgeonForBill = null; // Surgery Bill shows the operating surgeon, not the visit's consulting doctor
  let packageBreakup = [];
  let breakupAvailable = false;
  if (isSurgery) {
    // The package/surgery header shown on the bill must reflect what was
    // actually billed on THIS invoice, not whatever the surgical case's
    // package currently is -- a patient's package can be changed after
    // billing (Counselling supports this), or a case can be rebilled
    // under a different package entirely, and past invoices must not
    // silently start showing today's package on reprint. The billed
    // package name/code therefore comes straight from this invoice's own
    // Surgery line item, which is immutable once created -- no visit_id
    // needed for this part at all.
    const surgeryLine = (rawLineItems || []).find((li) => li.dept === 'Surgery');
    packageName = surgeryLine?.service_name || null;
    packageCode = surgeryLine?.service_code || null;

    // Enrichment only -- a surgical case registered directly (OT
    // Schedule's "Register Surgery Directly") or billed without a visit
    // selected has no visit_id to look this up by. That's fine: the
    // manual_surgery_* fields below (always saved at billing time,
    // whether prefilled from a case or typed by hand) cover exactly
    // this situation, which is why they exist.
    let surgicalCase = null;
    if (invoice.visit_id) {
      const { data } = await supabase
        .from('surgical_cases')
        .select('id, procedure_name, eye, surgeon_id')
        .eq('visit_id', invoice.visit_id)
        .neq('status', 'Cancelled')
        .maybeSingle();
      surgicalCase = data;
    }

    // Surgery/Eye/Doctor are always editable in New Invoice now (whether
    // prefilled from a case or entered by hand), and whatever was
    // confirmed at billing time is saved onto the invoice itself
    // (manual_surgery_*). That takes priority over the surgical case,
    // which is live data that can keep changing after the bill was
    // printed -- same reasoning as the package name/code above.
    surgeryName = invoice.manual_surgery_name || surgicalCase?.procedure_name || null;
    surgeryEye = invoice.manual_surgery_eye || surgicalCase?.eye || null;
    const surgeonId = invoice.manual_surgeon_id || surgicalCase?.surgeon_id || null;
    if (surgeonId) {
      const { data: surgeon } = await supabase.from('profiles').select('full_name, registration_no').eq('id', surgeonId).maybeSingle();
      surgeonForBill = surgeon || null;
    }
    if (surgeryName) {
      // surgical_cases stores the surgery as free text (matched from the
      // Clinical Masters -- Surgery list at the time it was picked), not
      // a foreign key, so the code is looked up by name here.
      const { data: surgery } = await supabase.from('master_surgeries').select('code').eq('name', surgeryName).maybeSingle();
      surgeryCode = surgery?.code || null;
    }
    // Breakup lookup is keyed off packageCode (the invoice's own line
    // item, always available for a surgery invoice) -- not the
    // surgical case, so this works regardless of whether one was found.
    if (packageCode) {
      const { data: pkgForBreakup } = await supabase.from('master_packages').select('id').eq('code', packageCode).maybeSingle();
      if (pkgForBreakup) {
        const { data: breakupItems } = await supabase
          .from('package_line_items')
          .select('description, amount')
          .eq('package_id', pkgForBreakup.id)
          .order('sort_order');
        breakupAvailable = (breakupItems || []).length > 0;
        // Only actually included in the printed HTML when explicitly
        // requested (e.g. an insurance copy) -- most prints should stay
        // as the single package line item, no itemized breakup.
        if (includeBreakup) packageBreakup = breakupItems || [];
      }
    }
  }

  const settings = await getHospitalSettings();
  const context = buildInvoiceContext(settings, {
    patient: {
      patient_code: invoice.patients?.uhid, first_name: invoice.patients?.first_name, last_name: invoice.patients?.last_name,
      mobile: invoice.patients?.mobile, age: invoice.patients?.age, gender: invoice.patients?.gender,
    },
    invoice,
    visit: invoice.visits,
    doctor: isSurgery ? (surgeonForBill || invoice.visits?.profiles) : invoice.visits?.profiles,
    lineItems: lineItems || [],
    payments,
    packageName,
    packageCode,
    surgeryName,
    surgeryCode,
    surgeryEye,
    packageBreakup,
  });

  const templateKey = isSurgery ? 'invoice_surgery' : 'invoice_opd';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context), breakupAvailable };
}

function inr(n) {
  return `Rs. ${Number(n || 0).toFixed(2)}`;
}
function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

// Same mapping used in OT Intraop's workspace -- kept identical so an eye
// code reads the same way everywhere in the app, including on printouts.
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };
function fmtEye(code) {
  if (!code) return '--';
  return EYE_LABEL[code] || code;
}

function buildInvoiceContext(settings, { patient, invoice, visit, doctor, lineItems, payments, packageName, packageCode, surgeryName, surgeryCode, surgeryEye, packageBreakup }) {
  const totalPaid = (payments || []).reduce((s, p) => s + Number(p.amount || 0), 0);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc || 0), 0);
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    terms_text: settings.terms_text || '',
    logo_html: logoHtml(settings),

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    procedure: invoice.purpose || 'OPD Services',
    surgery_name: surgeryName || '--',
    surgery_code: surgeryCode || '--',
    eye: fmtEye(surgeryEye),
    package_name: packageName || '--',
    package_code: packageCode || '--',
    // Discharge date always mirrors the visit date -- day-care surgery
    // discharge happens the same day, and the printed bill should never
    // show a different (or missing) date from a separately recorded
    // recovery episode.
    discharge_date: fmtDate(visit?.created_at),

    bill_no: invoice.invoice_number,
    bill_date: fmtDate(invoice.created_at),
    visit_number: visit?.visit_number || '--',
    visit_date: fmtDate(visit?.created_at),
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    items: (lineItems || []).map((li, idx) => ({
      sno: idx + 1,
      name: (li.dept === 'Surgery' && li.service_code) ? `${li.service_name} (${li.service_code})` : li.service_name,
      qty: li.qty, rate: inr(li.rate), amount: inr(li.net),
    })),
    gross_amount: inr(invoice.gross),
    discount: inr(totalDisc),
    net_amount: inr(invoice.net),

    // Optional itemized breakup of what a surgery package includes --
    // not part of the accounting (the invoice still has one net line
    // item for the package), just a printed reference so staff can show
    // a patient what's covered when asked. Only present when a package
    // with a saved breakup was actually billed.
    has_breakup: (packageBreakup || []).length > 0,
    package_breakup: (packageBreakup || []).map((b) => ({ description: b.description, amount: inr(b.amount) })),

    payments: (payments || []).map((p) => ({
      date: fmtDate(p.created_at), ref_number: p.receipt_number || '--', amount: inr(p.amount),
    })),
    total_paid: inr(totalPaid),
  };
}

const PAYMENT_TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

// ── Renders the actual receipt HTML for a given paymentId. Picks the
//    Advance Receipt variant when payment_type is 'advance' (a fresh
//    advance collection, not yet applied to any invoice); everything
//    else (a regular payment, or an advance being adjusted against an
//    invoice) uses the standard Payment Receipt. ──
export async function renderReceiptHtml(paymentId) {
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(uhid, first_name, last_name, mobile), profiles:collected_by(full_name)')
    .eq('id', paymentId)
    .single();
  if (error || !payment) return { error: 'Receipt not found.' };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const settings = await getHospitalSettings();
  const context = buildReceiptContext(settings, {
    patient: {
      patient_code: payment.patients?.uhid, first_name: payment.patients?.first_name, last_name: payment.patients?.last_name,
      mobile: payment.patients?.mobile,
    },
    payment,
    collector: payment.profiles,
    modes: modes || [],
    allocations: allocations || [],
  });

  const templateKey = payment.payment_type === 'advance' ? 'receipt_advance' : 'receipt';
  const template = await getPrintTemplate(templateKey);
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildReceiptContext(settings, { patient, payment, collector, modes, allocations }) {
  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_id: patient.patient_code || '--',
    patient_mobile: patient.mobile || '--',

    receipt_no: payment.receipt_number,
    receipt_date: fmtDate(payment.collected_at),
    payment_type_label: PAYMENT_TYPE_LABEL[payment.payment_type] || payment.payment_type,
    collected_by: collector?.full_name || '--',

    amount_received: inr(payment.total_amount),
    amount_in_words: amountInWords(payment.total_amount),

    hasAllocations: (allocations || []).length > 0,
    allocations: (allocations || []).map((a) => ({ invoiceNumber: a.invoices?.invoice_number || '--', amount: inr(a.amount) })),

    modes: (modes || []).map((m) => ({ mode: m.mode, amount: inr(m.amount) })),

    reference: payment.reference || null,
    remarks: payment.remarks || null,
  };
}

const ONES = ['', 'One', 'Two', 'Three', 'Four', 'Five', 'Six', 'Seven', 'Eight', 'Nine', 'Ten',
  'Eleven', 'Twelve', 'Thirteen', 'Fourteen', 'Fifteen', 'Sixteen', 'Seventeen', 'Eighteen', 'Nineteen'];
const TENS = ['', '', 'Twenty', 'Thirty', 'Forty', 'Fifty', 'Sixty', 'Seventy', 'Eighty', 'Ninety'];

function twoDigitWords(n) {
  if (n < 20) return ONES[n];
  return `${TENS[Math.floor(n / 10)]}${n % 10 ? ' ' + ONES[n % 10] : ''}`;
}
function threeDigitWords(n) {
  if (n < 100) return twoDigitWords(n);
  return `${ONES[Math.floor(n / 100)]} Hundred${n % 100 ? ' ' + twoDigitWords(n % 100) : ''}`;
}

// Indian numbering (lakh/crore), matching how amounts are normally
// written out on Indian receipts.
function amountInWords(amount) {
  let n = Math.round(Number(amount || 0));
  if (n === 0) return 'Rupees Zero Only';
  const parts = [];
  const crore = Math.floor(n / 10000000); n %= 10000000;
  const lakh = Math.floor(n / 100000); n %= 100000;
  const thousand = Math.floor(n / 1000); n %= 1000;
  const hundred = n;
  if (crore) parts.push(`${threeDigitWords(crore)} Crore`);
  if (lakh) parts.push(`${threeDigitWords(lakh)} Lakh`);
  if (thousand) parts.push(`${threeDigitWords(thousand)} Thousand`);
  if (hundred) parts.push(threeDigitWords(hundred));
  return `Rupees ${parts.join(' ')} Only`;
}

// ── Renders a simple referral slip listing external investigations
//    requested for a surgical case (blood work, HIV test, etc -- not
//    done in-house) -- handed to the patient to get done elsewhere.
//    Self-contained rather than going through the editable
//    print_templates table, since this is a short, fixed-format slip. ──
export async function renderExternalInvestigationReferralHtml(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, procedure_name, eye, created_at, patients:patient_id(uhid, first_name, last_name, age, gender, mobile), profiles:surgeon_id(full_name, registration_no)')
    .eq('id', caseId)
    .single();
  if (error || !sc) return { error: 'Case not found.' };

  const { data: tests } = await supabase
    .from('external_investigations')
    .select('test_name, created_at')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: true });

  if (!tests || tests.length === 0) return { error: 'No external investigations have been added for this case yet.' };

  const settings = await getHospitalSettings();
  const patient = sc.patients;

  const rows = tests.map((t, i) => `
    <tr>
      <td style="border: 1px solid #999; padding: 8px; text-align: center; width: 40px;">${i + 1}</td>
      <td style="border: 1px solid #999; padding: 8px;">${t.test_name}</td>
      <td style="border: 1px solid #999; padding: 8px;"></td>
    </tr>`).join('');

  const html = `
<div style="max-width: 780px; margin: 0 auto; padding: 24px; font-family: Arial, Helvetica, sans-serif; color: #1a1a1a; font-size: 13px;">
  <table style="width: 100%; border-collapse: collapse; margin-bottom: 6px;">
    <tr>
      <td style="width: 100px; vertical-align: top;">${logoHtml(settings)}</td>
      <td style="vertical-align: top;">
        <div style="font-size: 24px; font-weight: 800; letter-spacing: .3px; text-decoration: underline;">${settings.name || ''}</div>
        <div style="font-size: 11px; font-weight: 700; margin-top: 2px;">${settings.unit_line || ''}</div>
        <div style="font-size: 10px; font-weight: 700;">REGN NO : ${settings.regn_no || ''}</div>
      </td>
      <td style="text-align: right; vertical-align: top; font-size: 10.5px; line-height: 1.5;">
        ${settings.address_line1 || ''}<br/>
        ${settings.address_line2 || ''}<br/>
        ${settings.city_state_pin || ''}<br/>
        Tel: ${settings.phone || ''}
      </td>
    </tr>
  </table>

  <div style="text-align: center; font-size: 16px; font-weight: 700; border-top: 1.5px solid #333; border-bottom: 1.5px solid #333; padding: 8px 0; margin: 10px 0 16px;">
    INVESTIGATION REFERRAL
  </div>

  <table style="width: 100%; border: 1.5px solid #333; border-collapse: collapse; margin-bottom: 18px;">
    <tr>
      <td style="width: 60%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9; border-right: 1px solid #999;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 110px; color: #444;">PATIENT ID</td><td>: <strong>${patient?.uhid || '--'}</strong></td></tr>
          <tr><td style="color: #444;">NAME</td><td>: <strong>${patient?.first_name || ''} ${patient?.last_name || ''}</strong></td></tr>
          <tr><td style="color: #444;">AGE/GENDER</td><td>: <strong>${patient?.age ?? '--'} / ${patient?.gender || '--'}</strong></td></tr>
          <tr><td style="color: #444;">MOBILE</td><td>: <strong>${patient?.mobile || '--'}</strong></td></tr>
        </table>
      </td>
      <td style="width: 40%; padding: 10px 14px; vertical-align: top; font-size: 12px; line-height: 1.9;">
        <table style="width: 100%; font-size: 12px;">
          <tr><td style="width: 60px; color: #444;">DATE</td><td>: <strong>${fmtDate(new Date().toISOString())}</strong></td></tr>
        </table>
      </td>
    </tr>
  </table>

  <div style="font-size: 12px; margin-bottom: 10px;">The following investigations are requested. Please get these done and bring the reports on your next visit.</div>

  <table style="width: 100%; border-collapse: collapse; font-size: 12.5px; margin-bottom: 30px;">
    <thead>
      <tr style="background: #e9edf2;">
        <th style="border: 1px solid #999; padding: 8px;">S.NO</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left;">Investigation</th>
        <th style="border: 1px solid #999; padding: 8px; text-align: left; width: 160px;">Report / Remarks</th>
      </tr>
    </thead>
    <tbody>${rows}</tbody>
  </table>

  <table style="width: 100%; margin-top: 50px;">
    <tr>
      <td style="font-size: 12px;">&nbsp;</td>
      <td style="text-align: right; font-size: 12px;">
        <div>Dr. ${sc.profiles?.full_name || ''}</div>
        <div style="font-size: 10.5px; color: #666;">Reg No: ${sc.profiles?.registration_no || ''}</div>
      </td>
    </tr>
  </table>

  <div style="text-align: center; margin-top: 20px; font-size: 10.5px; color: #999;">
    For any Queries please contact us at ${settings.phone || ''} or Email us at ${settings.email || ''}
  </div>
</div>`;

  return { html };
}

// ── Renders the OPD Case Sheet for a given encounterId -- the
//    patient-facing handout: chief complaint, vision/IOP/refraction,
//    diagnosis, prescription, advice, and follow-up. ──
export async function renderOpdCaseSheetHtml(encounterId) {
  const supabase = await createClient();

  const { data: encounter, error } = await supabase
    .from('encounters')
    .select('*, visits(id, created_at, visit_type, doctor_id, patients(uhid, first_name, last_name, mobile, age, gender), profiles:doctor_id(full_name, registration_no))')
    .eq('id', encounterId)
    .single();
  if (error || !encounter) return { error: 'Consultation not found.' };

  const visit = encounter.visits;

  const { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visit?.id)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let iopReadings = [];
  if (assessment) {
    const { data: readings } = await supabase.from('optometry_iop_readings').select('eye, value').eq('assessment_id', assessment.id);
    iopReadings = readings || [];
  }

  const { data: examination } = await supabase.from('clinical_examinations').select('*').eq('encounter_id', encounterId).maybeSingle();

  const { data: diagnoses } = await supabase.from('diagnoses').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: prescriptions } = await supabase.from('prescriptions').select('*').eq('encounter_id', encounterId).order('created_at');
  const { data: followup } = await supabase.from('plan_followups').select('*').eq('encounter_id', encounterId).maybeSingle();

  // Surgery advice -- if this encounter marked the patient for surgery,
  // it should show on the case sheet: what was advised, which eye, and
  // the patient's decision at the time.
  const { data: surgicalCase } = await supabase
    .from('surgical_cases')
    .select('procedure_name, eye, decision')
    .eq('encounter_id', encounterId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const settings = await getHospitalSettings();
  const context = buildOpdCaseSheetContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      mobile: visit?.patients?.mobile, age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    encounter,
    visit,
    doctor: visit?.profiles,
    assessment,
    iopReadings,
    examination,
    diagnoses: diagnoses || [],
    prescriptions: (prescriptions || []).map((r) => ({ ...r, drug: r.drug_name })),
    followup,
    surgicalCase,
  });

  const template = await getPrintTemplate('opd_case_sheet');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── GLASSES PRESCRIPTION -- printed from the Optometry screen. Always
//    the Final Rx (the accepted prescription, not the working
//    Objective/Subjective values). Rows are only shown when at least
//    one eye has an SPH recorded; CYL/AXIS are shown blank (not "0.00")
//    when only the spherical power was given, since axis is meaningless
//    without a cylinder. ──
function fmtRxVal(v) {
  return v || '--';
}

// Falls back Final Rx -> Subjective -> Objective when the earlier one
// wasn't filled in for that eye/distance -- for the internal OPD case
// sheet only. A patient's Distance refraction is very often recorded
// in the Subjective or Objective tab and never re-typed into Final Rx,
// which otherwise makes it silently vanish from the printed sheet even
// though it was genuinely measured. Falls back per whole row (not per
// individual SPH/CYL/AXIS field) so figures from different refraction
// types are never mixed together in one row, and the source actually
// used is labeled on the printout rather than implied to be "Final".
// A distance/near refraction row can be entirely valid with SPH left
// blank (plano/zero) while the real correction sits in CYL+AXIS -- pure
// astigmatism with no spherical component is clinically common. Only
// checking SPH for "was this row filled in" silently drops exactly
// that case, so every field is checked here.
function rowHasData(assessment, prefix) {
  return !!(assessment?.[`${prefix}_sph`] || assessment?.[`${prefix}_cyl`] || assessment?.[`${prefix}_axis`] || assessment?.[`${prefix}_va`]);
}

const REFRACTION_SOURCE_LABEL = { final: 'Final Rx', subj: 'Subjective', obj: 'Objective (Auto-Rx)' };
function pickRxRow(assessment, eye, distNear) {
  for (const type of ['final', 'subj', 'obj']) {
    const prefix = `ref_${type}_${eye}_${distNear}`;
    if (rowHasData(assessment, prefix)) {
      return { cells: buildRxCells(assessment, prefix), source: type };
    }
  }
  return { cells: buildRxCells(assessment, `ref_final_${eye}_${distNear}`), source: 'final' };
}

function buildRxCells(assessment, prefix) {
  const sph = assessment?.[`${prefix}_sph`];
  const cyl = assessment?.[`${prefix}_cyl`];
  const axis = assessment?.[`${prefix}_axis`];
  const va = assessment?.[`${prefix}_va`];
  return {
    sph: fmtRxVal(sph),
    // Only spherical power is common in real prescriptions -- axis is
    // meaningless without a cylinder, so both stay blank together.
    cyl: cyl ? cyl : '--',
    axis: cyl ? fmtRxVal(axis) : '--',
    va: fmtRxVal(va),
  };
}

function buildGlassesPrescriptionContext(settings, { patient, assessment, optometrist, doctor }) {
  const distRe = buildRxCells(assessment, 'ref_final_re_dist');
  const distLe = buildRxCells(assessment, 'ref_final_le_dist');
  const nearRe = buildRxCells(assessment, 'ref_final_re_near');
  const nearLe = buildRxCells(assessment, 'ref_final_le_near');

  const hasDistRx = rowHasData(assessment, 'ref_final_re_dist') || rowHasData(assessment, 'ref_final_le_dist');
  const hasNearRx = rowHasData(assessment, 'ref_final_re_near') || rowHasData(assessment, 'ref_final_le_near');

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed prescription pad (hospital header already
    // on the paper) -- hide the digital header and leave blank space
    // matching the pad's own header height instead.
    hide_header: !!settings.glasses_rx_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    rx_date: fmtDate(assessment?.created_at),
    va_scale: assessment?.va_scale || 'Snellen',

    hasDistRx,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,

    hasNearRx,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,

    ipd: assessment?.ref_pd || '--',
    optometrist_name: optometrist?.full_name || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',
  };
}

export async function renderGlassesPrescriptionHtml(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select('*, visits(id, doctor_id, patients(uhid, first_name, last_name, age, gender), profiles:doctor_id(full_name, registration_no)), profiles:recorded_by(full_name)')
    .eq('id', assessmentId)
    .single();
  if (error || !assessment) return { error: 'Optometry assessment not found.' };

  const visit = assessment.visits;
  const settings = await getHospitalSettings();
  const context = buildGlassesPrescriptionContext(settings, {
    patient: {
      patient_code: visit?.patients?.uhid, first_name: visit?.patients?.first_name, last_name: visit?.patients?.last_name,
      age: visit?.patients?.age, gender: visit?.patients?.gender,
    },
    assessment,
    optometrist: assessment.profiles,
    doctor: visit?.profiles,
  });

  const template = await getPrintTemplate('glasses_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── BIOMETRY REPORT -- printed from Surgeon Approval once the IOL plan
//    is approved. Shows the raw biometry readings (per eye, per device --
//    a technician may have taken more than one reading, e.g. a manual
//    A-scan fallback for a dense cataract) alongside the calculated
//    formula results and the final approved plan. ──
function buildBiometryReadingSets(sets) {
  return (Array.isArray(sets) ? sets : []).map((s) => ({
    device: s.device || 'Unspecified device',
    axl: s.axl || '--', k1: s.k1 || '--', k2: s.k2 || '--', acd: s.acd || '--', lt: s.lt || '--', wtw: s.wtw || '--',
  }));
}

function buildBiometryReportContext(settings, { patient, visit, record, surgeon, catalogItem }) {
  const reSets = buildBiometryReadingSets(record.measurements?.re);
  const leSets = buildBiometryReadingSets(record.measurements?.le);

  const formulaResults = (record.formula_results || []).map((r) => ({
    name: r.name, power: r.power || '--', refraction: r.refraction || '--',
    isSelected: r.name === record.selected_formula,
  }));

  const EYE_LABEL = { RE: 'Right Eye (RE / OD)', LE: 'Left Eye (LE / OS)', Both: 'Both Eyes (OU)', OD: 'Right Eye (RE / OD)', OS: 'Left Eye (LE / OS)', OU: 'Both Eyes (OU)' };

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    patient_id: patient.uhid || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',
    visit_number: visit?.visit_number || '--',
    report_date: fmtDate(record.approved_at || record.created_at),

    procedure_name: record.procedure_name || '--',
    surgical_eye: EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--',
    surgeon_name: surgeon?.full_name || '--',
    surgeon_regn_no: surgeon?.registration_no || '--',

    hasReReadings: reSets.length > 0,
    reSets,
    hasLeReadings: leSets.length > 0,
    leSets,

    hasFormulaResults: formulaResults.length > 0,
    formulaResults,

    isApproved: record.status === 'Approved',
    final_iol_power: record.final_iol_power || '--',
    final_iol_formula: record.selected_formula || '--',
    final_iol_category: record.final_iol_category || '--',
    final_iol_lens: catalogItem ? `${catalogItem.brand || ''} -- ${catalogItem.model || ''}${catalogItem.manufacturer ? ` (${catalogItem.manufacturer})` : ''}`.trim() : '--',
    target_refraction: record.target_refraction || '--',
    surgeon_notes: record.surgeon_notes || null,
    approved_date: record.approved_at ? fmtDate(record.approved_at) : '--',
  };
}

export async function renderBiometryReportHtml(recordId) {
  const supabase = await createClient();

  const { data: record, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(uhid, first_name, last_name, age, gender))')
    .eq('id', recordId)
    .single();
  if (error || !record) return { error: 'Biometry record not found.' };

  let surgeon = null;
  if (record.verified_by) {
    const { data: doc } = await supabase.from('profiles').select('full_name, registration_no').eq('id', record.verified_by).maybeSingle();
    surgeon = doc;
  }

  const settings = await getHospitalSettings();
  const context = buildBiometryReportContext(settings, {
    patient: record.visits?.patients || {},
    visit: record.visits,
    record,
    surgeon,
    catalogItem: null,
  });

  const template = await getPrintTemplate('biometry_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// Each structure's first/baseline template option is its "normal" value
// (mirrors EXT_TEMPLATES/ANT_TEMPLATES/POST_TEMPLATES in the Examination
// tab -- kept in sync manually since the template lists live client-side).
const EXAM_NORMAL_VALUE = {
  Lids: 'Normal', Adnexa: 'Normal', Lacrimal: 'Patent', Motility: 'Full',
  Conjunctiva: 'Normal', Cornea: 'Clear', 'Anterior Chamber': 'Deep & Quiet', Iris: 'Normal Pattern', Pupil: 'Round & Reactive', Lens: 'Clear',
  Vitreous: 'Clear', Disc: 'Healthy', Macula: 'Normal', Vessels: 'Normal', 'Peripheral Retina': 'Attached',
};

const EXAM_STRUCT_LABEL = { CDR: 'C.D Ratio' };

// Pivoted RE/LE rows (label | RE | LE), matching the Vision & Intraocular
// Pressure table's layout rather than one row per eye.
//
// mode 'abnormalOnly' (External Examination, Anterior Segment): a
// structure is only shown when at least one eye deviates from normal --
// a case sheet listing every structure as "Normal" is noise. The other
// eye still shows "Normal" alongside it for a complete row.
//
// mode 'anyData' (Posterior Segment): shown whenever either eye has
// anything recorded at all, normal or not -- Posterior/CDR findings are
// specialist, surgery-relevant readings a doctor wants on the printed
// record regardless of whether they happen to be normal.
//
// Handles both the current staged shape ({without:{...}, with:{...}})
// and the legacy flat shape from before dilatation staging existed.
function summarizeExamRegionPivoted(findingsJson, structs, mode) {
  const isStaged = findingsJson && (findingsJson.without || findingsJson.with);
  const stages = isStaged
    ? [['without', 'Without Dilatation'], ['with', 'With Dilatation']]
    : [[null, null]];

  const rows = [];
  stages.forEach(([stageKey, stageLabel]) => {
    const stageData = stageKey ? findingsJson[stageKey] : findingsJson;
    structs.forEach((struct) => {
      const f = stageData?.[struct] || {};
      const reRaw = f.re || '';
      const leRaw = f.le || '';
      const reCustom = f.re_custom || '';
      const leCustom = f.le_custom || '';
      const normal = EXAM_NORMAL_VALUE[struct];
      const reIsNormal = (!reRaw || reRaw === normal) && !reCustom;
      const leIsNormal = (!leRaw || leRaw === normal) && !leCustom;

      if (mode === 'abnormalOnly') {
        if (reIsNormal && leIsNormal) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || 'Normal',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || 'Normal',
        });
      } else {
        if (!reRaw && !leRaw && !reCustom && !leCustom) return;
        rows.push({
          structure: (EXAM_STRUCT_LABEL[struct] || struct) + (stageLabel ? ` (${stageLabel})` : ''),
          re: [reRaw, reCustom].filter(Boolean).join(' -- ') || '--',
          le: [leRaw, leCustom].filter(Boolean).join(' -- ') || '--',
        });
      }
    });
  });
  return rows;
}

const GONIO_ROW_DEFS = [
  { key: 'angle', label: 'Angle Configuration' },
  { key: 'ptm', label: 'PTM Pigmentation' },
  { key: 'iris', label: 'Iris Configuration' },
];

// Same pivoted RE/LE shape as summarizeExamRegionPivoted, but Gonioscopy
// is stored flat ({angle_re, angle_le, ...}) rather than per-structure,
// so it needs its own row builder. Shown whenever either eye has
// anything recorded.
function buildGonioscopyRows(gonioFindings) {
  const rows = [];
  if (!gonioFindings) return rows;
  // Gonioscopy used to be recorded in two passes (without/with dilatation);
  // it's now a single flat pass. Legacy staged records: read "without"
  // first (it was always the primary pass), falling back to "with" so
  // nothing already recorded is lost.
  const flat = (gonioFindings.without || gonioFindings.with) ? (gonioFindings.without || gonioFindings.with) : gonioFindings;
  GONIO_ROW_DEFS.forEach(({ key, label }) => {
    const re = flat[`${key}_re`];
    const le = flat[`${key}_le`];
    if (!re && !le) return;
    rows.push({ structure: label, re: re || '--', le: le || '--' });
  });
  return rows;
}

// Frequency-shorthand translation and taper-schedule grouping is
// imported at the top of this file (lib/prescriptionFormatting.js).

function buildOpdCaseSheetContext(settings, { patient, encounter, visit, doctor, assessment, iopReadings, examination, diagnoses, prescriptions, followup, surgicalCase }) {
  const reIop = iopReadings.find((r) => r.eye === 'RE' || r.eye === 'OD')?.value;
  const leIop = iopReadings.find((r) => r.eye === 'LE' || r.eye === 'OS')?.value;

  const distReRow = pickRxRow(assessment, 're', 'dist');
  const distLeRow = pickRxRow(assessment, 'le', 'dist');
  const nearReRow = pickRxRow(assessment, 're', 'near');
  const nearLeRow = pickRxRow(assessment, 'le', 'near');
  const distRe = distReRow.cells;
  const distLe = distLeRow.cells;
  const nearRe = nearReRow.cells;
  const nearLe = nearLeRow.cells;
  const cellHasData = (c) => c.sph !== '--' || c.cyl !== '--' || c.axis !== '--' || c.va !== '--';
  const hasDistRx = cellHasData(distRe) || cellHasData(distLe);
  const hasNearRx = cellHasData(nearRe) || cellHasData(nearLe);
  // Whichever eye actually supplied the row decides the label -- if
  // both eyes came from the same source this is just that source; if
  // they differed (rare), RE's source wins since it's listed first.
  const distSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(distRe) ? distReRow.source : distLeRow.source];
  const nearSourceLabel = REFRACTION_SOURCE_LABEL[cellHasData(nearRe) ? nearReRow.source : nearLeRow.source];

  const followupParts = [];
  if (followup?.after_period) followupParts.push(followup.after_period);
  if (followup?.visit_type) followupParts.push(`(${followup.visit_type})`);
  if (followup?.instructions) followupParts.push(`-- ${followup.instructions}`);

  // ── HISTORY -- Chief Complaint already existed; Ocular/Medical/Family/
  // Drug History and Allergy were captured on the encounter but never
  // made it onto the printed case sheet. ──
  const historyLines = [
    { label: 'Ocular History', items: encounter.ocular_history },
    { label: 'Medical History', items: encounter.medical_history },
    { label: 'Family History', items: encounter.family_history },
    { label: 'Drug History', items: encounter.drug_history },
    { label: 'Allergy', items: encounter.allergy },
  ].filter((h) => h.items && h.items.length > 0).map((h) => ({ label: h.label, text: h.items.join(', ') }));

  // ── OPTOMETRY -- previously only unaided/glasses vision, IOP, and
  // final refraction ("readings") made it onto the case sheet. Pinhole,
  // near vision, IOP method, additional pre-op tests, and the
  // optometrist's own recorded observations were captured but never
  // printed. ──
  const additionalTests = [
    { label: 'K1 (RE/LE)', value: (assessment?.add_k1_re || assessment?.add_k1_le) ? `${assessment?.add_k1_re || '--'} / ${assessment?.add_k1_le || '--'}` : null },
    { label: 'K2 (RE/LE)', value: (assessment?.add_k2_re || assessment?.add_k2_le) ? `${assessment?.add_k2_re || '--'} / ${assessment?.add_k2_le || '--'}` : null },
    { label: 'Axial Length (RE/LE)', value: (assessment?.add_axial_length_re || assessment?.add_axial_length_le) ? `${assessment?.add_axial_length_re || '--'} / ${assessment?.add_axial_length_le || '--'}` : null },
    { label: 'Pachymetry (RE/LE)', value: (assessment?.add_pachymetry_re || assessment?.add_pachymetry_le) ? `${assessment?.add_pachymetry_re || '--'} / ${assessment?.add_pachymetry_le || '--'}` : null },
    { label: 'Schirmer (RE/LE)', value: (assessment?.add_schirmer_re || assessment?.add_schirmer_le) ? `${assessment?.add_schirmer_re || '--'} / ${assessment?.add_schirmer_le || '--'}` : null },
    { label: 'Color Vision (RE/LE)', value: (assessment?.add_color_vision_re || assessment?.add_color_vision_le) ? `${assessment?.add_color_vision_re || '--'} / ${assessment?.add_color_vision_le || '--'}` : null },
    { label: 'Syringing (RE/LE)', value: (assessment?.add_syringing_re || assessment?.add_syringing_le) ? `${assessment?.add_syringing_re || '--'} / ${assessment?.add_syringing_le || '--'}` : null },
  ].filter((t) => t.value);

  // ── EXAMINATION -- doctor's own clinical exam (External / Anterior /
  // Posterior Segment) was captured but not printed at all. Normal
  // findings are deliberately left off -- only what's actually abnormal
  // is worth a doctor's or reviewer's attention on the printed sheet. ──
  const externalRows = examination ? summarizeExamRegionPivoted(examination.external_findings, ['Lids', 'Adnexa', 'Lacrimal', 'Motility'], 'abnormalOnly') : [];
  const anteriorRows = examination ? summarizeExamRegionPivoted(examination.anterior_findings, ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'], 'abnormalOnly') : [];
  const posteriorRows = examination ? summarizeExamRegionPivoted(examination.posterior_findings, ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'], 'anyData') : [];
  const hasApplanation = !!(examination?.applanation_re || examination?.applanation_le);
  const gonioscopyRows = examination ? buildGonioscopyRows(examination.gonioscopy_findings) : [];

  const examExtra = [
    { label: 'Remarks (RE)', value: examination?.remarks_re },
    { label: 'Remarks (LE)', value: examination?.remarks_le },
  ].filter((e) => e.value);

  return {
    hospital_name: settings.name || 'VEDA EYE HOSPITAL',
    hospital_unit_line: settings.unit_line || '',
    hospital_regn_no: settings.regn_no || '',
    hospital_address_line1: settings.address_line1 || '',
    hospital_address_line2: settings.address_line2 || '',
    hospital_city_state_pin: settings.city_state_pin || '',
    hospital_phone: settings.phone || '',
    hospital_email: settings.email || '',
    logo_html: logoHtml(settings),

    // Printing on a pre-printed letterhead (hospital header already on
    // the paper) -- hide the digital header and leave blank space
    // matching the letterhead's own header height instead.
    hide_header: !!settings.case_sheet_hide_header,
    header_space_cm: settings.print_letterhead_space_cm ?? 5,

    patient_id: patient.patient_code || '--',
    patient_name: `${patient.first_name || ''} ${patient.last_name || ''}`.trim(),
    patient_mobile: patient.mobile || '--',
    patient_age: patient.age ?? '--',
    patient_gender: patient.gender || '--',

    visit_date: fmtDate(visit?.created_at),
    visit_type: visit?.visit_type || '--',
    doctor_name: doctor?.full_name || '--',
    doctor_regn_no: doctor?.registration_no || '--',

    chief_complaint: encounter.chief_complaint || (encounter.chief_complaint_chips || []).join(', ') || null,
    hx_duration: encounter.hx_duration || null,
    hx_laterality: encounter.hx_laterality || null,
    hx_hopi: encounter.hx_hopi || null,
    hasHistory: historyLines.length > 0,
    historyLines,

    hasVision: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided || assessment?.re_dist_glasses || assessment?.le_dist_glasses || assessment?.re_dist_ph || assessment?.le_dist_ph || assessment?.re_near_unaided || assessment?.le_near_unaided || reIop != null || leIop != null),
    hasViUnaided: !!(assessment?.re_dist_unaided || assessment?.le_dist_unaided),
    re_vision_unaided: assessment?.re_dist_unaided || '--',
    le_vision_unaided: assessment?.le_dist_unaided || '--',
    hasViGlasses: !!(assessment?.re_dist_glasses || assessment?.le_dist_glasses),
    re_vision_glasses: assessment?.re_dist_glasses || '--',
    le_vision_glasses: assessment?.le_dist_glasses || '--',
    hasViPh: !!(assessment?.re_dist_ph || assessment?.le_dist_ph),
    re_vision_ph: assessment?.re_dist_ph || '--',
    le_vision_ph: assessment?.le_dist_ph || '--',
    hasViNear: !!(assessment?.re_near_unaided || assessment?.le_near_unaided),
    re_vision_near: assessment?.re_near_unaided || '--',
    le_vision_near: assessment?.le_near_unaided || '--',
    hasIop: reIop != null || leIop != null,
    re_iop: reIop != null ? `${reIop}` : '--',
    le_iop: leIop != null ? `${leIop}` : '--',
    iop_method: assessment?.iop_method || null,
    hasDistRx,
    dist_rx_source: distSourceLabel,
    dist_re_sph: distRe.sph, dist_re_cyl: distRe.cyl, dist_re_axis: distRe.axis, dist_re_va: distRe.va,
    dist_le_sph: distLe.sph, dist_le_cyl: distLe.cyl, dist_le_axis: distLe.axis, dist_le_va: distLe.va,
    hasNearRx,
    near_rx_source: nearSourceLabel,
    near_re_sph: nearRe.sph, near_re_cyl: nearRe.cyl, near_re_axis: nearRe.axis, near_re_va: nearRe.va,
    near_le_sph: nearLe.sph, near_le_cyl: nearLe.cyl, near_le_axis: nearLe.axis, near_le_va: nearLe.va,
    hasAdditionalTests: additionalTests.length > 0,
    additionalTests,
    hasOptObservations: false,
    optObservations: '',

    hasExamination: externalRows.length > 0 || anteriorRows.length > 0 || posteriorRows.length > 0 || hasApplanation || gonioscopyRows.length > 0 || examExtra.length > 0,
    hasExternal: externalRows.length > 0,
    externalRows,
    hasAnterior: anteriorRows.length > 0,
    anteriorRows,
    hasPosterior: posteriorRows.length > 0,
    posteriorRows,
    hasApplanation,
    applanation_re: examination?.applanation_re || '--',
    applanation_le: examination?.applanation_le || '--',
    hasGonioscopy: gonioscopyRows.length > 0,
    gonioscopyRows,
    hasExamExtra: examExtra.length > 0,
    examExtra,

    hasDiagnoses: diagnoses.length > 0,
    diagnoses: diagnoses.map((d) => ({ name: d.name, eye: d.eye, notes: d.notes })),

    // Surgery advice, if this encounter marked the patient for surgery
    // -- shows what was advised, which eye, and the patient's decision
    // at the time (Willing / Needs Time to Decide / Not Willing etc).
    hasSurgery: !!surgicalCase,
    surgery_procedure_name: surgicalCase?.procedure_name || null,
    surgery_eye: EYE_LABEL[surgicalCase?.eye] || surgicalCase?.eye || null,
    surgery_decision: surgicalCase?.decision || null,

    hasPrescriptions: prescriptions.length > 0,
    prescriptions: groupPrescriptionsForPrint(prescriptions),

    advice: encounter.patient_instructions || null,
    followup_text: followupParts.length > 0 ? followupParts.join(' ') : null,
  };
}

// ── DISCHARGE SUMMARY -- printed from Post-op / Recovery once a patient
//    has been discharged. Mirrors what used to be a hardcoded page
//    (app/discharge-summary-print) so it's now editable like every
//    other print template and picks up hospital branding/logo. ──
export async function renderDischargeSummaryHtml(episodeId) {
  const supabase = await createClient();

  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, visit_id, patients:patient_id(uhid, first_name, last_name, mobile, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error || !episode) return { error: 'Episode not found.' };
  if (!episode.discharge_date) return { error: "This patient hasn't been discharged yet." };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: approval }, { data: meds }, { data: followups }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // Planned IOL comes from the surgeon's IOL Approval now, not
    // biometry_records (which no longer has any "approved" concept).
    supabase.from('iol_approvals').select('power, eye, master_iol_catalog(brand, model, category)').eq('surgical_case_id', sc?.id).eq('status', 'Approved').maybeSingle(),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
  ]);

  const settings = await getHospitalSettings();
  const context = buildDischargeSummaryContext(settings, {
    patient: sc?.patients,
    surgeon: sc?.profiles,
    procedureName: sc?.procedure_name,
    eye: sc?.eye,
    episode,
    intraop,
    biometry: approval ? [approval] : [],
    meds: meds || [],
    followups: followups || [],
  });

  const template = await getPrintTemplate('discharge_summary');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

function buildDischargeSummaryContext(settings, { patient, surgeon, procedureName, eye, episode, intraop, biometry, meds, followups }) {
  return {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    surgeon_name: surgeon?.full_name || '--',
    admission_date: fmtDate(episode.admission_date),
    surgery_date: fmtDate(episode.surgery_date),
    discharge_date: fmtDate(episode.discharge_date),

    procedure_name: procedureName, eye,
    iol_lines: biometry.map((p) => ({
      eye: p.eye,
      text: `${intraop?.implant_power || p.power} D -- ${p.master_iol_catalog?.category || ''}${intraop?.implant_manufacturer ? ` -- ${intraop.implant_manufacturer} ${intraop.implant_model || ''}` : ''}`,
    })),

    hasMedications: meds.length > 0,
    medications: meds.map((m) => ({ name: m.name, sig: m.sig })),

    hasDischargeNotes: !!episode.discharge_notes,
    discharge_notes: episode.discharge_notes,
    discharge_instructions: episode.discharge_instructions || 'As advised by the surgeon.',

    followups: followups.map((f) => ({ visit_label: f.visit_label, date: fmtDate(f.scheduled_date), status: f.status })),
  };
}

// ── INVESTIGATION REPORT -- printed for a completed (or unable-to-
//    perform) investigation order. Field labels mirror exactly what
//    the Investigation Workspace saves (investigation-types.js), so
//    the printed report always matches what's on screen. ──
export async function renderInvestigationHtml(orderId) {
  const supabase = await createClient();

  const { data: order, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(visit_id, doctor_id, visits(patients(uhid, first_name, last_name, mobile, age, gender)), profiles:doctor_id(full_name))')
    .eq('id', orderId)
    .single();
  if (error || !order) return { error: 'Investigation not found.' };

  const [{ data: completedBy }, { data: verifiedBy }] = await Promise.all([
    order.completed_by ? supabase.from('profiles').select('full_name').eq('id', order.completed_by).maybeSingle() : Promise.resolve({ data: null }),
    order.verified_by ? supabase.from('profiles').select('full_name').eq('id', order.verified_by).maybeSingle() : Promise.resolve({ data: null }),
  ]);

  const settings = await getHospitalSettings();
  const patient = order.encounters?.visits?.patients;
  const type = matchInvestigationType(order.name);
  const fields = getFullFieldValues(type, order.result_data);

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid, patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age, patient_gender: patient?.gender, patient_mobile: patient?.mobile,

    investigation_name: order.name, investigation_type: type, eye: order.eye,
    doctor_name: order.encounters?.profiles?.full_name || '--',
    ordered_date: fmtDate(order.created_at), completed_date: order.completed_at ? fmtDate(order.completed_at) : '--',

    isUnable: order.status === 'Cancelled' && !!order.unable_reason,
    unable_reason: order.unable_reason,

    hasFields: fields.length > 0,
    fields,

    hasNotes: !!order.result_notes,
    result_notes: order.result_notes,

    technician_name: completedBy?.full_name || '--',
    hasVerifiedBy: !!verifiedBy?.full_name,
    verified_by_name: verifiedBy?.full_name || null,
  };

  const template = await getPrintTemplate('investigation_report');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}

// ── MEDICINE PRESCRIPTION -- printed from Pharmacy, independent of
//    the bill. This is the patient-facing dosage sheet: what to take,
//    how much, how often (in plain language, not medical shorthand),
//    and for how long -- not prices or invoice numbers. Reuses the
//    same plainFrequency()/groupPrescriptionsForPrint() logic as the
//    OPD Case Sheet's own Prescription section, so the two always
//    read identically wherever a patient sees them. ──
export async function renderMedicinePrescriptionHtml(visitId) {
  const supabase = await createClient();

  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, doctor_id, patients(uhid, first_name, last_name, age, gender, mobile), profiles:doctor_id(full_name, registration_no)')
    .eq('id', visitId)
    .single();
  if (error || !visit) return { error: 'Visit not found.' };

  const { data: rows } = await supabase
    .from('prescriptions')
    .select('drug_name, eye, dosage, frequency, duration, taper_group_id, taper_step, encounters!inner(visit_id)')
    .eq('encounters.visit_id', visitId)
    .order('created_at', { ascending: true });

  const prescriptions = groupPrescriptionsForPrint(
    (rows || []).map((r) => ({ drug: r.drug_name, eye: r.eye, dosage: r.dosage, frequency: r.frequency, duration: r.duration, taper_group_id: r.taper_group_id, taper_step: r.taper_step }))
  );

  const settings = await getHospitalSettings();
  const patient = visit.patients;

  const context = {
    hospital_name: settings.name, hospital_unit_line: settings.unit_line, hospital_regn_no: settings.regn_no,
    hospital_address_line1: settings.address_line1, hospital_address_line2: settings.address_line2,
    hospital_city_state_pin: settings.city_state_pin, hospital_phone: settings.phone, hospital_email: settings.email,
    logo_html: logoHtml(settings),

    patient_id: patient?.uhid || '--', patient_name: `${patient?.first_name || ''} ${patient?.last_name || ''}`.trim(),
    patient_age: patient?.age ?? '--', patient_gender: patient?.gender || '--', patient_mobile: patient?.mobile || '--',
    visit_number: visit.visit_number || '--',
    print_date: fmtDate(new Date().toISOString()),

    doctor_name: visit.profiles?.full_name || '--',
    doctor_regn_no: visit.profiles?.registration_no || '--',

    hasPrescriptions: prescriptions.length > 0,
    prescriptions,
  };

  const template = await getPrintTemplate('medicine_prescription');
  const compiled = Handlebars.compile(template.html);
  return { html: compiled(context) };
}
__VEDA_FILE_16_END__

git add -A
git reset -- *.sh 2>/dev/null || true
git commit -m "OT Schedule: new Calendar tab (month grid, prior bookings, session availability); Surgical Journey now opens it as a popup window to pick the surgery date, selection returned via postMessage; IOL Approval live 15s refresh + Edit to revise same-day approvals; Medical Fitness after IOL order & surgery date; Package selection matches Counselling; Biometry lock mode with doctor-only edit; duplicate-order guard; Biometry queue routing fix; simplified external investigation referral print"
git push origin main

echo "== Done. Vercel will redeploy production and training automatically. =="
echo "== NOTE: the DB-side fix (stale trigger drop + test-data cleanup) was already applied directly to both Supabase projects and needs no action here. =="
