#!/bin/bash
set -e
echo "Deploying: deep-link Patient Check-In and Intraoperative Management from Surgical Journey directly to the patients record"

mkdir -p "app/(main)/patient-checkin"
cat > "app/(main)/patient-checkin/page.js" << 'VEDA_EOF_1'
'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import { getOTCaseList } from '../ot-intraop/actions';
import { DashboardTab, TabButton } from '../ot-intraop/page';
import Workspace from '../ot-intraop/workspace';

// Patient Check-In is split out from what used to be the combined
// "Operation Theatre" module (Patient Check-In + Intraoperative
// Management as two tabs in one screen) into its own module. The
// underlying case list, data, and check-in checklist itself are
// unchanged -- only the navigation/entry point is split; Intraoperative
// Management lives at /ot-intraop.
//
// Deep-linkable via ?otScheduleId=... -- Surgical Journey's Patient
// Check-In step links straight here with the case's OT schedule id so
// it opens the patient's own record instead of dropping onto the
// Dashboard for a manual pick.
function PatientCheckinInner() {
  const searchParams = useSearchParams();
  const deepLinkId = searchParams.get('otScheduleId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);

  useEffect(() => { refreshCases(); }, [refreshCases]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 360 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-check" label="Workspace" disabled={!selectedId} />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} returnTo="patient-checkin" variant="checkin" />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="checkin" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard.</div>
      )}
    </div>
  );
}

export default function PatientCheckinPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <PatientCheckinInner />
    </Suspense>
  );
}
VEDA_EOF_1

mkdir -p "app/(main)/ot-intraop"
cat > "app/(main)/ot-intraop/page.js" << 'VEDA_EOF_2'
'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { getOTCaseList, getOTIntraopHistory, markPatientReported, unmarkPatientReported } from './actions';
import Workspace from './workspace';

const STATUS_BADGE = { Scheduled: 'b-amber', 'In Progress': 'b-blue' };

export function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--red)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export function DashboardTab({ cases, loading, onOpen, onRefresh, returnTo = 'ot-intraop', variant = 'intraop' }) {
  const [busyId, setBusyId] = useState(null);

  async function handleToggleReported(e, otId, currentlyReported) {
    e.stopPropagation();
    setBusyId(otId);
    if (currentlyReported) await unmarkPatientReported(otId);
    else await markPatientReported(otId);
    setBusyId(null);
    onRefresh();
  }

  // Patient Check-In cares about a different split than Intraoperative
  // Management: "checked in" here just means check-in is done (status
  // moves Scheduled -> In Progress the moment check-in completes, see
  // completeCheckin), not that the surgery itself is finished.
  const isCheckin = variant === 'checkin';
  const topCases = isCheckin ? cases.filter((c) => c.status === 'Scheduled') : cases.filter((c) => c.status !== 'Completed');
  const bottomCases = isCheckin ? cases.filter((c) => c.status !== 'Scheduled') : cases.filter((c) => c.status === 'Completed');
  const topTitle = isCheckin ? 'Pending Check-In' : "Today's Pending Cases";
  const bottomTitle = isCheckin ? 'Checked-In Patients (Today)' : "Today's Completed Cases";
  const bottomSubtitle = isCheckin ? 'Already checked in and handed off to the OT team.' : 'Moves to OT History tomorrow -- still editable from here today if a correction is needed.';

  const counts = {
    Scheduled: cases.filter((c) => c.status === 'Scheduled').length,
    'In Progress': cases.filter((c) => c.status === 'In Progress').length,
    Completed: cases.filter((c) => c.status === 'Completed').length,
  };

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Scheduled, not checked in</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Scheduled}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In Progress</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts['In Progress']}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Completed today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{counts.Completed}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Total today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-building-hospital" style={{ color: 'var(--red)' }}></i> {topTitle}</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && topCases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          const canOpen = c.advanceCleared;
          return (
            <div
              key={c.id}
              onClick={canOpen ? () => onOpen(c.id) : undefined}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: canOpen ? 'pointer' : 'default' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--red)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${STATUS_BADGE[c.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{c.status}</span>
                <button
                  type="button"
                  className={`badge ${c.patient_reported_at ? 'b-green' : 'b-gray'}`}
                  style={{ marginLeft: 6, fontSize: 10, border: 'none', cursor: 'pointer' }}
                  disabled={busyId === c.id}
                  onClick={(e) => handleToggleReported(e, c.id, !!c.patient_reported_at)}
                  title={c.patient_reported_at ? `Reported at ${new Date(c.patient_reported_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })} -- click to undo` : 'Click to mark patient as reported'}
                >
                  {busyId === c.id ? '...' : c.patient_reported_at ? 'Reported' : 'Mark Reported'}
                </button>
                {!canOpen && <span className="badge b-red" style={{ marginLeft: 6, fontSize: 10 }}>Advance Due: Rs.{c.amountPayable.toFixed(0)}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.surgery_code ? `${sc.surgery_code} -- ` : ''}{patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              {canOpen ? (
                <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
              ) : (
                <Link
                  href={`/payments/advance?patientId=${sc.patient_id}&amount=${c.amountPayable.toFixed(2)}&returnTo=${returnTo}`}
                  onClick={(e) => e.stopPropagation()}
                  className="btn btn-sm"
                  style={{ background: 'var(--amber)', color: '#fff', border: 'none', textDecoration: 'none' }}
                  title="Collect the advance needed before this case can be opened"
                >
                  <i className="ti ti-cash"></i> Collect Advance -- Rs.{c.amountPayable.toFixed(0)}
                </Link>
              )}
            </div>
          );
        })}
        {!loading && topCases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>{isCheckin ? 'No patients pending check-in.' : 'No pending OT cases for today.'}</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> {bottomTitle}</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>{bottomSubtitle}</div>
        {!loading && bottomCases.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div
              key={c.id}
              onClick={() => onOpen(c.id)}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className={`badge ${isCheckin ? (STATUS_BADGE[c.status] || 'b-gray') : 'b-green'}`} style={{ marginLeft: 8, fontSize: 10 }}>{isCheckin ? c.status : 'Completed'}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.surgery_code ? `${sc.surgery_code} -- ` : ''}{patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'} -- {c.master_ot_sessions?.name} Session
                </div>
              </div>
              <button className="btn btn-sm"><i className="ti ti-edit"></i> View / Edit</button>
            </div>
          );
        })}
        {!loading && bottomCases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>{isCheckin ? 'Nothing checked in yet today.' : 'Nothing completed yet today.'}</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((r) => {
        const q = search.trim().toLowerCase();
        const patient = r.surgical_cases?.patients;
        return `${patient?.first_name} ${patient?.last_name}`.toLowerCase().includes(q) || (patient?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Completed OT Cases</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Date</th><th>Patient</th><th>Procedure</th><th>Outcome</th><th>Completed By</th><th></th></tr></thead>
          <tbody>
            {filtered.map((r) => {
              const sc = r.surgical_cases;
              const patient = sc?.patients;
              return (
                <tr key={r.id} onClick={() => onOpen(r.id)} style={{ cursor: 'pointer' }}>
                  <td style={{ fontSize: 11 }}>{new Date(r.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</td>
                  <td><strong>{patient?.first_name} {patient?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{patient?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>{sc?.procedure_name} ({sc?.eye})</td>
                  <td><span className="badge b-green" style={{ fontSize: 10 }}>{r.intraopSummary?.surgical_outcome || '--'}</span></td>
                  <td style={{ fontSize: 12 }}>{r.intraopSummary?.completedByName || '--'}</td>
                  <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
                </tr>
              );
            })}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

// Deep-linkable via ?otScheduleId=... -- Surgical Journey's
// Intraoperative Management step links straight here with the case's
// OT schedule id so it opens the patient's own record instead of
// dropping onto the Dashboard for a manual pick.
function OTIntraopInner() {
  const searchParams = useSearchParams();
  const deepLinkId = searchParams.get('otScheduleId');

  const [activeTab, setActiveTab] = useState(deepLinkId ? 'workspace' : 'dashboard');
  const [selectedId, setSelectedId] = useState(deepLinkId || null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getOTCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getOTIntraopHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-building-hospital" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} onRefresh={refreshCases} />}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace otScheduleId={selectedId} onBack={handleBack} restrictTab="intraop" />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

export default function OTIntraopPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <OTIntraopInner />
    </Suspense>
  );
}

VEDA_EOF_2

mkdir -p "app/(main)/surgical-journey/[id]"
cat > "app/(main)/surgical-journey/[id]/workspace.js" << 'VEDA_EOF_3'
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
  selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
  setDecision, markReadyForScheduling, bookOTSlot, getSurgeons, addCaseNote,
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
          {sc.surgery_code && <div style={{ fontSize: 11, opacity: 0.75, marginTop: 2 }}><i className="ti ti-hash"></i> {sc.surgery_code}</div>}
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

  // Net payable for the Payment step = package list price minus
  // whatever discount was recorded at Package Selection. Advance
  // balance is the patient's live held-advance total (M11), not the
  // old advance_payment_id flag, which nothing in the app ever
  // actually set.
  const netPackageAmount = sc.master_packages ? Math.max(0, Number(sc.master_packages.price) - Number(sc.package_discount || 0)) : 0;
  const advanceBalance = Number(data.advanceBalance || 0);

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
    payment: netPackageAmount > 0 && advanceBalance >= netPackageAmount - 0.01,
    checkin: !!data.checkinCompletedAt,
    intraop: !!data.recoveryEpisode?.discharge_date,
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

      {/* 1. PATIENT DECISION -- the very first step. Once the patient
          gives assent (Accepted), Investigations through Payment (steps
          2-7) all unlock together -- no interdependency between them.
          Patient Check-In and beyond stay locked until Payment is
          complete. */}
      <DecisionSection sc={sc} onAction={flash} active={currentStep === 'decision'} />

      {/* 2. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} inHouseInvestigations={data.inHouseInvestigations} externalTests={data.externalTests} onAction={flash} active={currentStep === 'investigations'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} onAction={flash} active={currentStep === 'package'} />

      {/* 4. IOL APPROVAL -- separate module: surgeon's final brand/power
          sign-off, based on Biometry's device recommendations. */}
      <IolApprovalSection sc={sc} iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} />

      {/* 5. IOL PROCUREMENT + DATE + BOOK */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} iolApproval={data.iolApproval} onAction={flash} active={currentStep === 'iol'} num={5} />

      {/* 6. MEDICAL FITNESS -- comes after the surgery date is booked
          (pre-anaesthesia clearance closer to the actual surgery date
          is more clinically useful than clearing weeks in advance). */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={6} />

      {/* 7. PAYMENT */}
      <Section num={7} color="var(--teal)" title="Payment" done={stepDone.payment} active={currentStep === 'payment'}>
        {sc.decision !== 'Accepted' ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
        ) : !sc.master_packages ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Select a package first to determine the amount payable.</div>
        ) : (
          <div>
            <div style={{ background: 'var(--g50)', borderRadius: 8, padding: 10, marginBottom: 10, fontSize: 12.5 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>Package price</span><span>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
              </div>
              {Number(sc.package_discount || 0) > 0 && (
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--red)' }}>
                  <span>Discount</span><span>&minus; Rs.{Number(sc.package_discount).toLocaleString('en-IN')}</span>
                </div>
              )}
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, borderTop: '1px solid var(--g200)', marginTop: 6, paddingTop: 6 }}>
                <span>Net payable</span><span>Rs.{netPackageAmount.toLocaleString('en-IN')}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6 }}>
                <span>Advance received</span><span style={{ fontWeight: 600, color: 'var(--purple)' }}>Rs.{advanceBalance.toLocaleString('en-IN')}</span>
              </div>
            </div>
            {stepDone.payment ? (
              <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Paid in full.</div>
            ) : (
              <div>
                <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>
                  Balance due: <strong style={{ color: 'var(--amber)' }}>Rs.{Math.max(0, netPackageAmount - advanceBalance).toLocaleString('en-IN')}</strong>
                </div>
                <button
                  className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
                  onClick={() => router.push(`/payments/advance?patientId=${patient.id}&amount=${Math.max(0, netPackageAmount - advanceBalance)}&returnTo=surgical-journey`)}
                >
                  <i className="ti ti-cash"></i> Collect Advance
                </button>
              </div>
            )}
          </div>
        )}
      </Section>

      {/* 8. PATIENT CHECK-IN */}
      <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} router={router} active={currentStep === 'checkin'} num={8} />

      {/* 9. INTRAOPERATIVE MANAGEMENT */}
      <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} recoveryEpisode={data.recoveryEpisode} router={router} active={currentStep === 'intraop'} num={9} />

      {/* 10. NOTES / FOLLOW-UP */}
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
  if (sc.decision !== 'Accepted') {
    return (
      <Section num={num} color="var(--red)" title="Medical Fitness" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }
  return (
    <Section num={num} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>
          <i className="ti ti-info-circle"></i> Will appear in the Medical Fitness module automatically once the OT date is booked.
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
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>
            <i className="ti ti-info-circle"></i> Doctor can review again from the <a href="/medical-fitness" style={{ color: 'var(--blue)', fontWeight: 600 }}>Medical Fitness module</a>.
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. ──
function IolApprovalSection({ sc, iolApproval, active }) {
  const approved = iolApproval?.status === 'Approved';
  if (sc.decision !== 'Accepted') {
    return (
      <Section num={5} color="var(--indigo)" title="IOL Approval" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }
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
  const [discountInput, setDiscountInput] = useState('');
  const [selecting, setSelecting] = useState(false);
  const [selectError, setSelectError] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changeDiscountInput, setChangeDiscountInput] = useState('');
  const [changing, setChanging] = useState(false);
  const [editingDiscount, setEditingDiscount] = useState(false);
  const [discountEditValue, setDiscountEditValue] = useState('');
  const [discountEditReason, setDiscountEditReason] = useState('');
  const [discountError, setDiscountError] = useState('');
  const [savingDiscount, setSavingDiscount] = useState(false);
  const decided = sc.decision === 'Accepted';

  useEffect(() => {
    if (decided) getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoadingPackages(false); });
  }, [decided, sc.iol_category]);

  if (!decided) {
    return (
      <Section num={3} color="var(--indigo)" title="Package" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Waiting on Patient Decision first.</div>
      </Section>
    );
  }

  const selectedPreview = packages.find((p) => p.id === selectedPackageId);
  const discountNum = Number(discountInput) || 0;
  const netPreview = selectedPreview ? Math.max(0, Number(selectedPreview.price) - discountNum) : null;
  const currentDiscount = Number(sc.package_discount || 0);
  const currentNet = sc.master_packages ? Math.max(0, Number(sc.master_packages.price) - currentDiscount) : 0;

  async function handleSelect() {
    setSelectError('');
    if (!selectedPackageId) { setSelectError('Choose a package first.'); return; }
    if (discountNum < 0) { setSelectError('Discount cannot be negative.'); return; }
    setSelecting(true);
    const result = await onAction(selectPackage)(sc.id, selectedPackageId, discountNum);
    setSelecting(false);
    if (result?.error) { setSelectError(result.error); return; }
    setDiscountInput('');
  }

  async function handleSaveDiscount() {
    setDiscountError('');
    if (!discountEditReason.trim()) { setDiscountError('Reason is required.'); return; }
    setSavingDiscount(true);
    const result = await onAction(updatePackageDiscount)(sc.id, Number(discountEditValue) || 0, discountEditReason);
    setSavingDiscount(false);
    if (result?.error) { setDiscountError(result.error); return; }
    setEditingDiscount(false); setDiscountEditReason('');
  }

  return (
    <Section num={3} color="var(--indigo)" title="Package" done={!!sc.package_id} defaultOpen={decided && !sc.package_id} active={active}>
      <div style={{ marginBottom: 14 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Package</div>
        {sc.master_packages ? (
          <div>
            <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, marginBottom: (changing || editingDiscount) ? 8 : 0 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span style={{ fontWeight: 600, fontSize: 12.5 }}>{sc.master_packages.name}</span>
                <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                  <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</span>
                  {!changing && !editingDiscount && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
                </div>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, color: 'var(--g600)' }}>
                <span>Discount: {currentDiscount > 0 ? `Rs.${currentDiscount.toLocaleString('en-IN')}` : 'None'}</span>
                <span style={{ fontWeight: 700 }}>Net: Rs.{currentNet.toLocaleString('en-IN')}</span>
              </div>
              {!changing && !editingDiscount && (
                <button className="btn btn-sm" style={{ marginTop: 6 }} onClick={() => { setEditingDiscount(true); setDiscountEditValue(currentDiscount || ''); }}>
                  <i className="ti ti-percentage"></i> Edit discount
                </button>
              )}
            </div>

            {editingDiscount && (
              <div>
                {discountError && <div className="msg-err" style={{ marginBottom: 8 }}>{discountError}</div>}
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount amount (Rs.)" value={discountEditValue} onChange={(e) => setDiscountEditValue(e.target.value)} />
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for discount change..." value={discountEditReason} onChange={(e) => setDiscountEditReason(e.target.value)} />
                  <button className="btn btn-sm btn-primary" disabled={savingDiscount} onClick={handleSaveDiscount}>
                    {savingDiscount ? 'Saving...' : 'Save'}
                  </button>
                  <button className="btn btn-sm" onClick={() => { setEditingDiscount(false); setDiscountError(''); }}>Cancel</button>
                </div>
              </div>
            )}

            {changing && (
              <div>
                <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                  <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a new package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={changeDiscountInput} onChange={(e) => setChangeDiscountInput(e.target.value)} />
                </div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                  <button
                    className="btn btn-sm btn-primary"
                    disabled={!selectedPackageId || !changeReason.trim()}
                    onClick={async () => {
                      const r = await onAction(changePackage)(sc.id, changeReason);
                      if (r?.error) return;
                      await onAction(selectPackage)(sc.id, selectedPackageId, Number(changeDiscountInput) || 0);
                      setChanging(false); setChangeReason(''); setSelectedPackageId(''); setChangeDiscountInput('');
                    }}
                  >
                    Confirm Change
                  </button>
                  <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); setChangeDiscountInput(''); }}>Cancel</button>
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
                  <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                    <option value="">Select a package...</option>
                    {packages.map((p) => (
                      <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                    ))}
                  </select>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={discountInput} onChange={(e) => setDiscountInput(e.target.value)} />
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
                    {discountNum > 0 && (
                      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, paddingTop: 6, borderTop: '1px solid var(--g200)' }}>
                        <span style={{ color: 'var(--red)' }}>Discount: Rs.{discountNum.toLocaleString('en-IN')}</span>
                        <span style={{ fontWeight: 700 }}>Net: Rs.{netPreview.toLocaleString('en-IN')}</span>
                      </div>
                    )}
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
function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, num }) {
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
    openPopup(`/ot-calendar-picker?pickFor=${sc.id}&pickLabel=${label}`, `ot-calendar-${sc.id}`, { width: 460, height: 680 });
  }

  const canBook = sc.status === 'Ready for Scheduling';
  const readyGateMet = sc.decision === 'Accepted';

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
          <i className="ti ti-info-circle"></i> Waiting on Patient Decision first.
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

// ── 7. PATIENT CHECK-IN (live status, deep-link only) ──
function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, router, active, num }) {
  if (!paymentDone) {
    return (
      <Section num={num} color="var(--g400)" title="Patient Check-In" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Complete Payment first.</div>
      </Section>
    );
  }

  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;
  const done = !!checkinCompletedAt;

  if (otSchedule) {
    if (done) {
      status = 'Checked in';
      color = 'var(--green)';
      action = { label: 'View in Patient Check-In', onClick: () => router.push(`/patient-checkin?otScheduleId=${otSchedule.id}`) };
    } else {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- not yet checked in`;
      color = 'var(--blue)';
      action = { label: 'Open in Patient Check-In', onClick: () => router.push(`/patient-checkin?otScheduleId=${otSchedule.id}`) };
    }
  }

  return (
    <Section num={num} color={color} title="Patient Check-In" done={done} defaultOpen={!!otSchedule && !done} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, and pre-op checklist all happen in the Patient Check-In module -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── 8. INTRAOPERATIVE MANAGEMENT (live status, deep-links only -- OT
// Intraop and Recovery remain their own solid clinical workflows;
// Recovery/Post-Op are a natural continuation of this same chain, so
// their status is shown here too rather than yet another section) ──
function IntraopManagementSection({ otSchedule, checkinCompletedAt, recoveryEpisode, router, active, num }) {
  let status = 'Waiting on Patient Check-In';
  let color = 'var(--g400)';
  let action = null;
  const locked = !checkinCompletedAt;

  if (otSchedule && checkinCompletedAt) {
    if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in Intraoperative Management', onClick: () => router.push(`/ot-intraop?otScheduleId=${otSchedule.id}`) };
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
    } else {
      status = 'Checked in -- ready for OT';
      color = 'var(--blue)';
      action = { label: 'Open in Intraoperative Management', onClick: () => router.push(`/ot-intraop?otScheduleId=${otSchedule.id}`) };
    }
  }

  return (
    <Section num={num} color={color} title="Intraoperative Management" done={!!recoveryEpisode?.discharge_date} defaultOpen={!!checkinCompletedAt} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      {locked ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> Complete Patient Check-In first.</div>
      ) : (
        <>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            The surgery itself and discharge happen in the Intraoperative Management / Recovery modules -- that clinical documentation stays where it is. This just shows where the case currently stands.
          </div>
          {action && (
            <button className="btn btn-sm btn-primary" onClick={action.onClick}>
              <i className="ti ti-arrow-right"></i> {action.label}
            </button>
          )}
        </>
      )}
    </Section>
  );
}

// ── 9. NOTES / FOLLOW-UP LOG ──────────────────────────────────────
function NotesSection({ caseId, notes, onAction }) {
  const [text, setText] = useState('');
  return (
    <Section num={10} color="var(--g500)" title="Notes &amp; Follow-up Calls" done={false}>
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
VEDA_EOF_3

echo "Files written. No DB migration needed for this change."
echo "Deploy script done."
