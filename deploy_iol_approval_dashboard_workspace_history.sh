#!/bin/bash
set -e
echo "Deploying: IOL Approval - Dashboard/Workspace/History tabs, full-header patient workspace"

cat > "app/(main)/iol-approval/actions.js" << 'VEDA_EOF_1'
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

// ── HISTORY: every approval ever made, newest first, with optional
// date range + patient search. Approved Today only ever showed the
// current day, so anything from yesterday or earlier had no way to be
// found again in this module. ──
export async function getIolApprovalHistory(fromDate, toDate, search) {
  const supabase = await createClient();

  let query = supabase
    .from('iol_approvals')
    .select('*, surgical_cases(id, procedure_name, eye, package_id, patients:patient_id(first_name, last_name, uhid), master_packages:package_id(name)), master_iol_catalog(brand, model)')
    .eq('status', 'Approved')
    .order('approved_at', { ascending: false })
    .limit(300);

  if (fromDate) query = query.gte('approved_at', new Date(`${fromDate}T00:00:00+05:30`).toISOString());
  if (toDate) query = query.lte('approved_at', new Date(`${toDate}T23:59:59.999+05:30`).toISOString());

  const { data, error } = await query;
  if (error) return [];
  let rows = (data || []).filter((a) => a.surgical_cases);

  if (search && search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter((a) => {
      const p = a.surgical_cases?.patients;
      return p && (
        `${p.first_name} ${p.last_name}`.toLowerCase().includes(q) ||
        (p.uhid || '').toLowerCase().includes(q)
      );
    });
  }

  return rows;
}

// ── DETAIL: a case's recommendation table + current approval ──────
export async function getIolApprovalDetail(caseId) {
  const supabase = await createClient();

  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('id, patient_id, procedure_name, eye, package_id, surgery_code, status, patients:patient_id(first_name, last_name, uhid, age, gender, mobile), master_packages:package_id(name, iol_category), profiles:surgeon_id(full_name)')
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
      .select('*, master_iol_catalog(id, brand, model, category)')
      .eq('biometry_record_id', biometry.id)
      .order('created_at', { ascending: true });
    recommendations = data || [];
  }

  const { data: approval } = await supabase
    .from('iol_approvals')
    .select('*, master_iol_catalog(brand, model, category)')
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
VEDA_EOF_1

cat > "app/(main)/iol-approval/page.js" << 'VEDA_EOF_2'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingIolApprovals, getApprovedToday, getIolApprovalHistory, getIolApprovalDetail, approveIol } from './actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// ── DASHBOARD ─────────────────────────────────────────────────────
function DashboardTab({ pending, approvedToday, loading, onOpen }) {
  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Pending Approval
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pending.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && pending.map((item) => (
          <div key={item.caseId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(item.caseId)}>
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
            <button className="btn btn-sm btn-primary" onClick={(e) => { e.stopPropagation(); onOpen(item.caseId); }}>
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
          <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(a.surgical_case_id)}>
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
            <button className="btn btn-sm" onClick={(e) => { e.stopPropagation(); onOpen(a.surgical_case_id); }}>
              <i className="ti ti-edit"></i> Edit
            </button>
          </div>
        ))}
        {approvedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>
    </div>
  );
}

// ── HISTORY -- full tab, not a collapsible aside. Every approval ever
// made, searchable by patient and filterable by date range. ──
function HistoryTab({ onOpen }) {
  const [rows, setRows] = useState([]);
  const [search, setSearch] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    setRows(await getIolApprovalHistory(fromDate || undefined, toDate || undefined, search || undefined));
    setLoading(false);
  }, [fromDate, toDate, search]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Approval History
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span>
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
        <input className="fi fi-sm" style={{ flex: 1, minWidth: 200 }} placeholder="Search patient name or UHID..." value={search} onChange={(e) => setSearch(e.target.value)} />
        <input type="date" className="fi fi-sm" value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
        <input type="date" className="fi fi-sm" value={toDate} onChange={(e) => setToDate(e.target.value)} />
        {(fromDate || toDate || search) && (
          <button className="btn btn-sm" onClick={() => { setSearch(''); setFromDate(''); setToDate(''); }}>Clear</button>
        )}
      </div>

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && rows.map((a) => (
        <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(a.surgical_case_id)}>
          <div style={{ width: 32, height: 32, borderRadius: '50%', background: 'var(--g300)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 700, flexShrink: 0 }}>
            {a.surgical_cases?.patients?.first_name?.charAt(0)}
          </div>
          <div style={{ flex: 1 }}>
            <span style={{ fontWeight: 700, fontSize: 12.5 }}>{a.surgical_cases?.patients?.first_name} {a.surgical_cases?.patients?.last_name}</span>
            <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {a.surgical_cases?.patients?.uhid} -- {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              {a.approved_at && <> -- {new Date(a.approved_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</>}
            </div>
          </div>
          <button className="btn btn-sm" onClick={(e) => { e.stopPropagation(); onOpen(a.surgical_case_id); }}>
            <i className="ti ti-edit"></i> Edit
          </button>
        </div>
      ))}
      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>No approvals found.</div>
      )}
    </div>
  );
}

// ── WORKSPACE -- one patient's full record. Same header/summary layout
// convention as Patient Check-In / Intraoperative Management (gradient
// banner with all patient/case info up top, big-visibility summary
// cards below), instead of the small popup this used to be. ──
function WorkspaceView({ caseId, onBack, onDone }) {
  const [detail, setDetail] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [catalogId, setCatalogId] = useState('');
  const [power, setPower] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const result = await getIolApprovalDetail(caseId);
    if (result.error) { setLoadError(result.error); return; }
    setDetail(result);
  }, [caseId]);

  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [refresh]);

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

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!detail) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = detail.case;
  const patient = sc.patients;
  const approved = detail.approval?.status === 'Approved';
  const eyeKey = sc.eye === 'OD' ? 're_power' : sc.eye === 'OS' ? 'le_power' : null;

  function pickRecommendation(rec) {
    setCatalogId(rec.master_iol_catalog.id);
    setPower(eyeKey ? (rec[eyeKey] ?? '') : '');
  }

  // Flags when the doctor's choice doesn't match any device
  // recommendation on file -- either a brand/model with no
  // recommendation row at all, or a power that differs from what the
  // device recommended for this eye. A genuine clinical call either
  // way, but worth surfacing rather than silently letting it slide.
  const matchingRec = catalogId ? detail.recommendations.find((r) => r.master_iol_catalog.id === catalogId) : null;
  const recommendedPower = matchingRec && eyeKey ? matchingRec[eyeKey] : null;
  const deviatesNoRec = !!catalogId && !matchingRec && detail.recommendations.length > 0;
  const deviatesPower = !!matchingRec && !!power && recommendedPower != null && String(power).trim() !== String(recommendedPower).trim();
  const deviates = deviatesNoRec || deviatesPower;

  async function handleApprove() {
    setError(''); setOk('');
    if (!detail.biometry) { setError('No measured biometry on file for this patient.'); return; }
    setSaving(true);
    const result = await approveIol(caseId, detail.biometry.id, catalogId, power, notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Saved.');
    refresh();
    onDone();
  }

  return (
    <div>
      <div style={{ background: approved ? 'linear-gradient(135deg,#312e81,#4338ca)' : 'linear-gradient(135deg,#78350f,#b45309)', borderRadius: 12, padding: '11px 18px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        {sc.surgery_code && <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{sc.surgery_code}</div>}
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>
            {patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile || 'No mobile on file'} -- {sc.procedure_name} {sc.eye ? `(${EYE_LABEL[sc.eye] || sc.eye})` : ''} -- {sc.profiles?.full_name || 'No surgeon assigned'}
          </div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{approved ? 'Approved' : 'Pending Approval'}</span>
          {detail.biometry && (
            <a href={`/biometry/${detail.biometry.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none', borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }}>
              <i className="ti ti-file-report"></i> Biometry Report
            </a>
          )}
          <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
        </div>
      </div>

      {/* Big-visibility case summary -- same convention as Patient
          Check-In / Intraoperative Management */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--indigo)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-scalpel"></i> Procedure</div>
          <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2 }}>{sc.procedure_name}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--blue)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-eye"></i> Eye</div>
          <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--blue)' }}>{sc.eye}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--green)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-package"></i> Package</div>
          <div style={{ fontSize: 13, fontWeight: 700, lineHeight: 1.2, color: sc.master_packages ? 'inherit' : 'var(--g400)' }}>{sc.master_packages?.name || 'No package'}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--amber)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-stethoscope"></i> Surgeon</div>
          <div style={{ fontSize: 13, fontWeight: 700, lineHeight: 1.2 }}>{sc.profiles?.full_name || 'Not assigned'}</div>
        </div>
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      <div className="card">
        {!detail.biometry ? (
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

            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Confirm Choice for {EYE_LABEL[sc.eye] || sc.eye}</div>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
                <option value="">Select brand/model...</option>
                {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
              </select>
              <input className="fi fi-sm" placeholder="Power" value={power} onChange={(e) => setPower(e.target.value)} />
            </div>

            {deviates && (
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11.5, marginBottom: 10 }}>
                <i className="ti ti-alert-triangle"></i>{' '}
                {deviatesNoRec
                  ? 'This brand/model has no device recommendation on file for this patient -- deviating from the biometry report.'
                  : `Device recommended ${recommendedPower ?? '--'} D for ${EYE_LABEL[sc.eye] || sc.eye}, but ${power} D is being approved -- deviating from the biometry report.`}
              </div>
            )}

            <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

            <button className="btn btn-primary" onClick={handleApprove} disabled={saving || !catalogId || !power}>
              {saving ? 'Saving...' : approved ? 'Update Approval' : 'Approve'}
            </button>
          </>
        )}
      </div>
    </div>
  );
}

export default function IolApprovalPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);
  const [pending, setPending] = useState([]);
  const [approvedToday, setApprovedToday] = useState([]);
  const [loading, setLoading] = useState(true);

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

  function openCase(caseId) {
    setSelectedCaseId(caseId);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh();
    setSelectedCaseId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>IOL Approval</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>The surgeon's final sign-off on which IOL brand/model/power to actually use, per case.</div>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 420 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-lens" label="Workspace" disabled={!selectedCaseId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab pending={pending} approvedToday={approvedToday} loading={loading} onOpen={openCase} />}
      {activeTab === 'history' && <HistoryTab onOpen={openCase} />}
      {activeTab === 'workspace' && selectedCaseId && <WorkspaceView caseId={selectedCaseId} onBack={handleBack} onDone={refresh} />}
      {activeTab === 'workspace' && !selectedCaseId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}
VEDA_EOF_2

echo "Files written. No DB migration needed for this change."
echo "Deploy script done."
