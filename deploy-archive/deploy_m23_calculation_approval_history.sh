#!/usr/bin/env bash
# M23 Biometry & IOL Planning: IOL Calculation + Surgeon Approval +
# History (Step 4). Restructures /biometry/[id] into a tabbed workspace
# (Measurements / IOL Calculation / Surgeon Approval), matching your
# Consultation screen's tab pattern, plus a new cross-patient History
# page at /biometry/history.
#
# Note: the IOL Calculation "formula comparison" table does NOT compute
# real IOL power (genuine formulas like Barrett Universal II are complex
# and in some cases proprietary) -- staff transcribes each formula's
# result from the biometry device's own printout (captured via the
# Device Reports upload on the Measurements tab). The surgeon compares
# and picks. This is a deliberate departure from the prototype's
# hardcoded mock numbers.
#
# Usage: run from the ROOT of your veda-hmis repo checkout:
#   bash deploy_m23_calculation_approval_history.sh
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
      .in('status', ['Awaiting Biometry', 'Measured', 'Calculated']);
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

  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .maybeSingle();

  if (existing) return { id: existing.id };

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
export async function verifyBiometryMeasurements(id, measurements, surgicalEye, device, remarks) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  if (!surgicalEye) return { error: 'Set the surgical eye before verifying.' };

  const eyeKey = surgicalEye === 'RE' ? 're' : surgicalEye === 'LE' ? 'le' : null;
  if (!eyeKey) return { error: 'Surgical eye must be RE or LE to verify (OU not supported for a single IOL calculation).' };

  const eyeData = measurements[eyeKey] || {};
  const missing = REQUIRED_FIELDS.filter((f) => !eyeData[f] || !String(eyeData[f]).trim());
  if (missing.length > 0) {
    return { error: `Mandatory fields for the surgical eye (AXL, K1, K2, ACD) must be completed before verification. Missing: ${missing.join(', ').toUpperCase()}.` };
  }

  const { error } = await supabase
    .from('biometry_records')
    .update({
      status: 'Calculated',
      measurements,
      verify_device: device,
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

cat > "$DIR/page.js" << 'FILEEOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryQueue, getOrCreateBiometryRecord } from './actions';

const STATUS_BADGE = {
  'Awaiting Biometry': 'b-gray',
  Measured: 'b-amber',
  Calculated: 'b-blue',
};

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

export default function BiometryQueuePage() {
  const [rows, setRows] = useState([]);
  const [stats, setStats] = useState({ awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 });
  const [openingId, setOpeningId] = useState(null);
  const [error, setError] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getBiometryQueue();
    setRows(result.rows);
    setStats(result.stats);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleOpen(row) {
    setError('');
    if (row.recordId) {
      router.push(`/biometry/${row.recordId}`);
      return;
    }
    setOpeningId(row.queueEntryId);
    const result = await getOrCreateBiometryRecord(row.visitId, row.encounterId);
    setOpeningId(null);
    if (result.error) { setError(result.error); return; }
    router.push(`/biometry/${result.id}`);
  }

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Awaiting biometry" value={stats.awaiting} sub="Not yet measured" color="var(--indigo)" />
        <KpiCard label="Measured" value={stats.measured} sub="Awaiting calculation" color="var(--amber)" />
        <KpiCard label="Calculated" value={stats.calculated} sub="Awaiting surgeon" color="var(--blue)" />
        <KpiCard label="Approved today" value={stats.approvedToday} sub="IOL plan finalized" color="var(--green)" />
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Measurement before calculation. Calculation before selection. Only the surgeon may approve the final IOL plan.
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Biometry Queue</div>
          <button className="btn btn-sm" onClick={() => router.push('/biometry/history')}>
            <i className="ti ti-history"></i> History
          </button>
        </div>
        {rows.map((row) => (
          <div key={row.queueEntryId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {row.patient?.first_name?.charAt(0) || '?'}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{row.patient?.first_name} {row.patient?.last_name}</span>
              <span className={`badge ${STATUS_BADGE[row.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{row.status}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {row.patient?.uhid}{row.procedureName ? ` -- ${row.procedureName}` : ''}{row.surgicalEye ? ` ${row.surgicalEye}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={() => handleOpen(row)} disabled={openingId === row.queueEntryId}>
              <i className="ti ti-ruler-measure"></i> {openingId === row.queueEntryId ? 'Opening...' : 'Measure'}
            </button>
          </div>
        ))}
        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            Nothing pending -- all caught up.
          </div>
        )}
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
              <th>Date</th><th>Patient</th><th>Eye</th><th>AXL</th><th>K1/K2</th><th>ACD</th><th>Formula</th><th>Approved IOL</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r) => {
              const patient = r.visits?.patients;
              const eyeKey = r.surgical_eye === 'RE' ? 're' : r.surgical_eye === 'LE' ? 'le' : null;
              const m = eyeKey ? (r.measurements?.[eyeKey] || {}) : {};
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
                  <td>{r.selected_formula || r.final_iol_power ? (r.selected_formula || '--') : '--'}</td>
                  <td style={{ fontFamily: 'monospace', fontWeight: 600 }}>{r.final_iol_power ? `${r.final_iol_power} D` : '--'}</td>
                  <td><span className={`badge ${r.status === 'Approved' ? 'b-green' : 'b-blue'}`}>{r.status}</span></td>
                </tr>
              );
            })}
            {rows.length === 0 && (
              <tr><td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No biometry history found.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}
FILEEOF

cat > "$IDDIR/workspace.js" << 'FILEEOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getBiometryDetail } from '../actions';
import MeasurementsTab from './measurements-tab';
import CalculationTab from './calculation-tab';
import ApprovalTab from './approval-tab';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function BiometryWorkspace({ recordId }) {
  const [record, setRecord] = useState(null);
  const [surgeonName, setSurgeonName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [activeTab, setActiveTab] = useState('measurements');
  const router = useRouter();

  async function refresh() {
    const result = await getBiometryDetail(recordId);
    if (result.error) { setLoadError(result.error); return; }
    setRecord(result.record);
    setSurgeonName(result.surgeonName);
  }

  useEffect(() => { refresh(); }, [recordId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!record) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = record.visits?.patients;
  const visitNumber = record.visits?.visit_number;
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';
  const isApproved = record.status === 'Approved';

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
        <span className="badge" style={{ background: isApproved ? 'rgba(34,197,94,.35)' : isVerified ? 'rgba(99,102,241,.3)' : 'rgba(255,255,255,.15)', color: isApproved || isVerified ? '#fff' : '#fff', fontSize: 11 }}>
          {record.status}
        </span>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
        <TabButton active={activeTab === 'measurements'} onClick={() => setActiveTab('measurements')} icon="ti-ruler-measure" label="Measurements" />
        <TabButton active={activeTab === 'calculation'} onClick={() => setActiveTab('calculation')} icon="ti-calculator" label="IOL Calculation" disabled={!isVerified} />
        <TabButton active={activeTab === 'approval'} onClick={() => setActiveTab('approval')} icon="ti-shield-check" label="Surgeon Approval" disabled={!isVerified} />
      </div>

      {activeTab === 'measurements' && <MeasurementsTab record={record} recordId={recordId} onSaved={refresh} />}
      {activeTab === 'calculation' && <CalculationTab record={record} recordId={recordId} onSaved={refresh} />}
      {activeTab === 'approval' && <ApprovalTab record={record} recordId={recordId} surgeonName={surgeonName} onSaved={refresh} />}

      <div style={{ marginTop: 16 }}>
        <button className="btn" onClick={() => router.push('/biometry')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
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

export default function MeasurementsTab({ record, recordId, onSaved }) {
  const [measurements, setMeasurements] = useState({ re: {}, le: {} });
  const [procedureName, setProcedureName] = useState('');
  const [surgicalEye, setSurgicalEye] = useState('');
  const [device, setDevice] = useState(DEVICES[0]);
  const [remarks, setRemarks] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setMeasurements(record.measurements && Object.keys(record.measurements).length ? record.measurements : { re: {}, le: {} });
    setProcedureName(record.procedure_name || '');
    setSurgicalEye(record.surgical_eye || '');
    setDevice(record.verify_device || DEVICES[0]);
    setRemarks(record.verify_remarks || '');
  }, [record]);

  const canEdit = record.status !== 'Calculated' && record.status !== 'Approved';
  const isVerified = record.status === 'Calculated' || record.status === 'Approved';

  function setField(eyeKey, fieldKey, value) {
    setMeasurements((prev) => ({ ...prev, [eyeKey]: { ...prev[eyeKey], [fieldKey]: value } }));
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
    const result = await verifyBiometryMeasurements(recordId, measurements, surgicalEye, device, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Measurements verified. IOL Calculation tab is now available.');
    if (onSaved) onSaved();
  }

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
  const surgicalMeasurements = eyeKey ? (record.measurements?.[eyeKey] || {}) : {};

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
            {MEAS_FIELDS.map((f) => (
              <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}>{f.label}</span>
                <span style={{ fontWeight: 700, fontFamily: 'monospace' }}>{surgicalMeasurements[f.key] || '--'} {f.unit}</span>
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

cat > "$IDDIR/approval-tab.js" << 'FILEEOF'
'use client';

import { useState, useEffect } from 'react';
import { approveIolPlan, getIolVersionHistory } from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];

export default function ApprovalTab({ record, recordId, surgeonName, onSaved }) {
  const [finalPower, setFinalPower] = useState('');
  const [finalFormula, setFinalFormula] = useState(FORMULA_NAMES[0]);
  const [finalCategory, setFinalCategory] = useState(IOL_CATEGORIES[0]);
  const [finalTarget, setFinalTarget] = useState('');
  const [iolCatalogId, setIolCatalogId] = useState('');
  const [surgeonNotes, setSurgeonNotes] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [versions, setVersions] = useState([]);
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  async function loadVersions() {
    const v = await getIolVersionHistory(recordId);
    setVersions(v);
  }

  useEffect(() => {
    getActiveIolCatalog().then(setCatalog);
    loadVersions();
  }, [recordId]);

  useEffect(() => {
    const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
    setFinalPower(record.final_iol_power || selected?.power || '');
    setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
    setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
    setFinalTarget(record.target_refraction || '');
    setIolCatalogId(record.final_iol_catalog_id || '');
    setSurgeonNotes(record.surgeon_notes || '');
  }, [record]);

  const notCalculated = record.status !== 'Calculated' && record.status !== 'Approved';
  const isApproved = record.status === 'Approved';
  const catalogForCategory = catalog.filter((c) => c.category === finalCategory);

  async function handleApprove() {
    setError(''); setOkMsg('');
    if (!finalPower.trim()) { setError('Final IOL power is required.'); return; }
    setSaving(true);
    const result = await approveIolPlan(recordId, {
      finalPower, finalFormula, finalCategory, finalTarget, iolCatalogId: iolCatalogId || null, surgeonNotes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(`IOL Plan approved (version ${result.versionNo}).`);
    loadVersions();
    if (onSaved) onSaved();
  }

  if (notCalculated) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Save at least one formula result in IOL Calculation before approval is available.
      </div>
    );
  }

  const selectedCatalogItem = catalog.find((c) => c.id === record.final_iol_catalog_id);

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#166534,#15803d)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <i className="ti ti-shield-check" style={{ fontSize: 26, flexShrink: 0 }}></i>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Final IOL Plan Approval</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{record.procedure_name || 'Procedure not set'} {record.surgical_eye} -- Dr. {surgeonName}</div>
        </div>
        <div style={{ marginLeft: 'auto', textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>Only surgeon/ophthalmologist should approve</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 2 }}>{isApproved ? 'Approved' : 'Approval required'}</div>
        </div>
      </div>

      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 12 }}>
        <i className="ti ti-alert-triangle"></i> This isn't role-restricted at the database level yet -- please only approve if you're the operating surgeon or ophthalmologist for this case.
      </div>

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calculator" style={{ color: 'var(--indigo)' }}></i> Calculation Review</div>
            {record.formula_results?.length > 0 ? (
              record.formula_results.map((r, i) => (
                <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12, fontWeight: r.name === record.selected_formula ? 700 : 400, color: r.name === record.selected_formula ? 'var(--green)' : 'var(--g700)' }}>
                  <span>{r.name}{r.name === record.selected_formula ? ' (selected)' : ''}</span>
                  <span style={{ fontFamily: 'monospace' }}>{r.power} D -- {r.refraction}</span>
                </div>
              ))
            ) : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No calculation saved yet.</div>
            )}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Final IOL Plan</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">Final IOL power (D) *</label>
                <input className="fi fi-sm" placeholder="+21.5" value={finalPower} onChange={(e) => setFinalPower(e.target.value)} disabled={isApproved} />
              </div>
              <div>
                <label className="flbl">Formula used</label>
                <select className="fi fi-sm" value={finalFormula} onChange={(e) => setFinalFormula(e.target.value)} disabled={isApproved}>
                  {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                </select>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">IOL category *</label>
                <select className="fi fi-sm" value={finalCategory} onChange={(e) => { setFinalCategory(e.target.value); setIolCatalogId(''); }} disabled={isApproved}>
                  {IOL_CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Target refraction</label>
                <input className="fi fi-sm" value={finalTarget} onChange={(e) => setFinalTarget(e.target.value)} disabled={isApproved} />
              </div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Specific IOL (Master Data -- IOL Catalog)</label>
              <select className="fi fi-sm" value={iolCatalogId} onChange={(e) => setIolCatalogId(e.target.value)} disabled={isApproved}>
                <option value="">-- Not specified --</option>
                {catalogForCategory.map((c) => <option key={c.id} value={c.id}>{c.brand} -- {c.model}{c.manufacturer ? ` (${c.manufacturer})` : ''}</option>)}
              </select>
              {catalogForCategory.length === 0 && (
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 3 }}>No catalog items for {finalCategory} yet -- add them in Master Data -&gt; Clinical -&gt; IOL Catalog.</div>
              )}
            </div>
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Surgeon notes</label>
              <textarea className="fi fi-sm" rows={2} value={surgeonNotes} onChange={(e) => setSurgeonNotes(e.target.value)} disabled={isApproved} placeholder="e.g. Aim for slight myopia. Avoid multifocal due to macular finding. Toric axis to be confirmed intra-op..." />
            </div>
            {!isApproved && (
              <button className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleApprove} disabled={saving}>
                <i className="ti ti-shield-check"></i> {saving ? 'Approving...' : 'Approve Final IOL Plan'}
              </button>
            )}
            {isApproved && (
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                Approved{record.approved_at ? ` on ${new Date(record.approved_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. To change the plan, edit the fields above and approve again -- this creates a new version without deleting the old one.
              </div>
            )}
            {isApproved && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => { setFinalPower(record.final_iol_power || ''); }}>
                <i className="ti ti-edit"></i> Revise plan (creates new version)
              </button>
            )}
          </div>
        </div>

        <div>
          {isApproved && (
            <div className="card" style={{ marginBottom: 12, background: 'var(--green-lt)', borderColor: '#86efac' }}>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--green)', marginBottom: 8 }}>
                <i className="ti ti-clipboard-check"></i> IOL Planning Summary
              </div>
              <div style={{ fontSize: 12, color: 'var(--g700)', lineHeight: 1.8 }}>
                <div><strong>Power:</strong> {record.final_iol_power} D</div>
                <div><strong>Category:</strong> {record.final_iol_category}</div>
                {selectedCatalogItem && <div><strong>Lens:</strong> {selectedCatalogItem.brand} -- {selectedCatalogItem.model}</div>}
                <div><strong>Target:</strong> {record.target_refraction}</div>
              </div>
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Version History</div>
            {versions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No approved versions yet.</div>}
            {versions.map((v) => (
              <div key={v.id} style={{ padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <span style={{ fontWeight: 700 }}>v{v.version_no} -- {v.power} D ({v.formula})</span>
                  <span className={`badge ${v.status === 'Approved' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 9 }}>{v.status}</span>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>
                  {v.profiles?.full_name || 'Staff'} -- {new Date(v.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </div>
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Approval supersedes the previous plan but never deletes historical versions.</div>
          </div>
        </div>
      </div>
    </div>
  );
}
FILEEOF

echo "Files written:"
wc -l "$DIR/actions.js" "$DIR/page.js" "$HISTDIR/page.js" "$IDDIR/workspace.js" "$IDDIR/measurements-tab.js" "$IDDIR/calculation-tab.js" "$IDDIR/approval-tab.js"

echo ""
echo "Running build..."
npm run build

echo ""
echo "==================================================================="
echo "Build passed. Files written but NOT committed. Review with:"
echo "  git diff --stat \"$DIR\""
echo "Then commit:"
echo "  git add \"$DIR\""
echo "  git commit -m \"M23 Biometry: IOL Calculation, Surgeon Approval, History (Step 4)\""
echo "  git push"
echo "==================================================================="
