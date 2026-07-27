#!/bin/bash
set -e
echo "Applying: visit type badges on Doctor Dashboard + date-gated post-op review opening + view-only record access"

cat > "app/(main)/doctor-dashboard/actions.js" << 'PYEOF_3834424860257889930'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getDoctorDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: active }, { data: intermediate }, { data: completed }, { data: optometryWaiting }, { data: todaysVisits }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(id, first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .in('status', ['Waiting', 'Ready for Review', 'In Consultation'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      // .in() only matches exact values -- a patient sent out for more
      // than one thing at once gets a compound status like "Awaiting
      // Investigation & Biometry" (see doctorSendOut), so this needs to
      // catch any status containing one of these rather than an exact
      // match.
      .or('status.ilike.%Dilation%,status.ilike.%Investigation%,status.ilike.%Biometry%')
      .gte('issued_at', today)
      .order('sent_out_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(id, first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Optometry')
      .in('status', ['Waiting', 'Calling'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase.from('visits').select('visit_type').gte('created_at', today),
  ]);

  const visitTypeCounts = {};
  (todaysVisits || []).forEach((v) => {
    visitTypeCounts[v.visit_type] = (visitTypeCounts[v.visit_type] || 0) + 1;
  });

  return {
    active: active || [], intermediate: intermediate || [], completed: completed || [], optometryWaiting: optometryWaiting || [],
    visitTypeCounts, totalVisitsToday: todaysVisits?.length || 0,
  };
}

// ── HISTORY: every completed consultation, not just today's ──
export async function getDoctorHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, visit_type, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('department', 'Doctor')
    .eq('status', 'Done')
    .order('completed_at', { ascending: false })
    .limit(200);
  if (error) return [];
  return (data || []).filter((e) => e.visits?.patients);
}


PYEOF_3834424860257889930

cat > "app/(main)/doctor-dashboard/page.js" << 'PYEOF_6123478320360535237'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDoctorDashboardData, getDoctorHistory } from './actions';
import { doctorCallNext, doctorCallSpecific, doctorMarkReady, doctorCallDirect } from '@/app/(main)/queue/actions';
import PostOpWorkspace from '@/app/(main)/ot-postop/workspace';
import { getOpenPostOpEpisodeForPatient } from '@/app/(main)/ot-postop/actions';
import BiometryWorkspace from '@/app/(main)/biometry/[id]/workspace';
import { getBiometryApprovalsToday } from '@/app/(main)/biometry/actions';
import { WorkspaceTab as MedicalFitnessWorkspace } from '@/app/(main)/medical-fitness/page';
import { getMedicalFitnessToday } from '@/app/(main)/medical-fitness/actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

function TokenBadge({ token, color }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: color || 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

function VisitTypeBadge({ type }) {
  if (!type) return null;
  return (
    <span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})20`, color: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, marginLeft: 6, fontSize: 10 }}>
      {type}
    </span>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--blue)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ active, intermediate, completed, optometryWaiting, biometryApprovals, medicalFitnessToday, visitTypeCounts, totalVisitsToday, error, onRunAction, onOpen, onOpenBiometry, onOpenMedicalFitness }) {
  const inConsultation = active.find((e) => e.status === 'In Consultation');
  const waitingCount = active.filter((e) => e.status === 'Waiting' || e.status === 'Ready for Review').length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Consultation</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{inConsultation ? 1 : 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>With doctor now</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting for Doctor</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>In doctor queue</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Intermediate</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{intermediate.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Dilation / Investigation</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Completed Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{completed.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Encounters closed</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue<span className="badge b-gray">{active.length}</span></div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => onRunAction(doctorCallNext)} disabled={!!inConsultation}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {inConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={inConsultation.token} color="var(--blue)" />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(inConsultation)}</span>
                <VisitTypeBadge type={inConsultation.visits?.visit_type} />
              </div>
              <div style={{ marginBottom: 8 }}>
                <span className={`badge ${waitBadgeClass(elapsedMin(inConsultation.called_at || inConsultation.issued_at))}`}>
                  <i className="ti ti-clock"></i> In consultation {elapsedMin(inConsultation.called_at || inConsultation.issued_at)}m
                </span>
              </div>
              <button className="btn btn-primary btn-sm" onClick={() => onOpen(inConsultation)}>
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </button>
            </div>
          )}

          {active.filter((e) => e.id !== inConsultation?.id).map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} color={e.status === 'Ready for Review' ? 'var(--green)' : 'var(--amber)'} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                  <VisitTypeBadge type={e.visits?.visit_type} />
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Ready for Review' ? 'b-green' : 'b-amber'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}><i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallSpecific, e.id)} disabled={!!inConsultation}>Call</button>
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* INTERMEDIATE QUEUE -- side by side with Doctor Queue, not
            buried further down, since it's just as time-sensitive
            (patients sent out for Dilation/Investigation/Biometry who
            need to be pulled back in). */}
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> Intermediate Queue<span className="badge b-gray">{intermediate.length}</span></div>
          </div>
          {intermediate.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.status} -- {elapsedMin(e.sent_out_at)}m</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorMarkReady, e.id)}>Mark Ready</button>
            </div>
          ))}
          {intermediate.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              No one in Dilation, Investigation, or Biometry.
            </div>
          )}
        </div>
      </div>

      {/* Everything else -- side by side in pairs rather than one long
          vertical stack. */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* VISIT TYPE BREAKDOWN -- same widget as Front Office Dashboard */}
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
          </div>
          {Object.keys(visitTypeCounts || {}).length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
          )}
          {Object.entries(visitTypeCounts || {}).map(([type, count]) => (
            <div key={type} style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
              </div>
              <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                <div style={{
                  width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                  height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                }}></div>
              </div>
            </div>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Waiting in Optometry<span className="badge b-gray">{optometryWaiting.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Pull a patient straight into consultation without waiting for their optometry workup -- useful for quick reviews or referrals.
          </div>
          {optometryWaiting.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <VisitTypeBadge type={e.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.issued_at)}m waiting in Optometry</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallDirect, e.id)} disabled={!!inConsultation}>
                <i className="ti ti-arrow-right"></i> Call Directly
              </button>
            </div>
          ))}
          {optometryWaiting.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No one currently waiting in Optometry.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry Approvals<span className="badge b-gray">{biometryApprovals.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's visits only. Only a doctor can approve.</div>
          {biometryApprovals.map((b) => (
            <div key={b.id} onClick={() => onOpenBiometry(b.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {b.visits?.patients?.first_name} {b.visits?.patients?.last_name}
                <span className="badge b-indigo" style={{ marginLeft: 6, fontSize: 10 }}>{b.surgical_eye}</span>
                <VisitTypeBadge type={b.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{b.visits?.patients?.uhid}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-shield-check"></i> Approve</button>
            </div>
          ))}
          {biometryApprovals.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing awaiting approval today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness<span className="badge b-gray">{medicalFitnessToday.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's referrals only.</div>
          {medicalFitnessToday.map((r) => (
            <div key={r.id} onClick={() => onOpenMedicalFitness(r.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {r.visits?.patients?.first_name} {r.visits?.patients?.last_name}
                <VisitTypeBadge type={r.visits?.visit_type} />
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Review</button>
            </div>
          ))}
          {medicalFitnessToday.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today<span className="badge b-green">{completed.length}</span></div>
          </div>
          {completed.slice(0, 8).map((e) => (
            <div
              key={e.id}
              onClick={() => onOpen(e)}
              style={{ display: 'block', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span><span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span> {patientName(e)}<VisitTypeBadge type={e.visits?.visit_type} /></span>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                {e.completed_at ? new Date(e.completed_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' }) : '--'}
              </div>
            </div>
          ))}
          {completed.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing completed yet today.</div>}
        </div>
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.visits?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Consultation History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Token</th><th>Patient</th><th>Visit Type</th><th>Completed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e)} style={{ cursor: 'pointer' }}>
                <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{e.token}</td>
                <td>
                  <strong>{patientName(e)}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 11 }}>{e.visits?.visit_type || '--'}</td>
                <td style={{ fontSize: 11 }}>{e.completed_at ? new Date(e.completed_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={5} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed consultations found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorDashboardPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [postOpEpisodeId, setPostOpEpisodeId] = useState(null);
  const [biometryId, setBiometryId] = useState(null);
  const [medFitnessId, setMedFitnessId] = useState(null);
  const [active, setActive] = useState([]);
  const [intermediate, setIntermediate] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [optometryWaiting, setOptometryWaiting] = useState([]);
  const [biometryApprovals, setBiometryApprovals] = useState([]);
  const [medicalFitnessToday, setMedicalFitnessToday] = useState([]);
  const [visitTypeCounts, setVisitTypeCounts] = useState({});
  const [totalVisitsToday, setTotalVisitsToday] = useState(0);
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const result = await getDoctorDashboardData();
    setActive(result.active);
    setIntermediate(result.intermediate);
    setCompleted(result.completed);
    setOptometryWaiting(result.optometryWaiting);
    setVisitTypeCounts(result.visitTypeCounts);
    setTotalVisitsToday(result.totalVisitsToday);
    setBiometryApprovals(await getBiometryApprovalsToday());
    setMedicalFitnessToday(await getMedicalFitnessToday());
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistory(await getDoctorHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => {
    refresh();
    refreshHistory();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh, refreshHistory]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  async function openConsultation(entry) {
    if (entry.visits?.visit_type === 'Post-operative Review') {
      const episodeId = await getOpenPostOpEpisodeForPatient(entry.visits.patients.id);
      if (!episodeId) {
        setError('This is marked as a Post-operative Review visit, but no open post-op episode was found for this patient.');
        return;
      }
      setPostOpEpisodeId(episodeId);
      setBiometryId(null); setMedFitnessId(null);
      setActiveTab('workspace');
      return;
    }
    // Opens in its own window, which closes itself once the doctor
    // finishes this sitting (Save Draft / Send for Dilation / Send for
    // Investigation / Complete Encounter) -- see finishAndClose() in
    // consultation-form.js. Reuses the same window name so repeated
    // "Call" clicks don't spawn a pile of windows. Polls for the window
    // closing so the dashboard refreshes immediately rather than
    // waiting on the 15s interval.
    const win = window.open(`/consultation/${entry.id}`, 'doctor-consultation-window');
    if (win) {
      const poll = setInterval(() => {
        if (win.closed) { clearInterval(poll); refresh(); }
      }, 800);
    }
  }

  function openBiometry(id) {
    setPostOpEpisodeId(null); setMedFitnessId(null);
    setBiometryId(id);
    setActiveTab('workspace');
  }

  function openMedicalFitness(id) {
    setPostOpEpisodeId(null); setBiometryId(null);
    setMedFitnessId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh(); refreshHistory();
    setPostOpEpisodeId(null);
    setBiometryId(null);
    setMedFitnessId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      {activeTab !== 'workspace' && (
        <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-text" label="Workspace" disabled={!postOpEpisodeId && !biometryId && !medFitnessId} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
      )}

      {activeTab === 'dashboard' && (
        <DashboardTab
          active={active} intermediate={intermediate} completed={completed} optometryWaiting={optometryWaiting}
          biometryApprovals={biometryApprovals} medicalFitnessToday={medicalFitnessToday}
          visitTypeCounts={visitTypeCounts} totalVisitsToday={totalVisitsToday}
          error={error} onRunAction={runAction} onOpen={openConsultation}
          onOpenBiometry={openBiometry} onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'workspace' && postOpEpisodeId && (
        <PostOpWorkspace episodeId={postOpEpisodeId} onBack={handleBack} onUpdate={() => {}} />
      )}
      {activeTab === 'workspace' && biometryId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <BiometryWorkspace recordId={biometryId} />
        </div>
      )}
      {activeTab === 'workspace' && medFitnessId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <MedicalFitnessWorkspace referralId={medFitnessId} onDone={handleBack} />
        </div>
      )}
      {activeTab === 'workspace' && !postOpEpisodeId && !biometryId && !medFitnessId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard or History.</div>
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openConsultation} />}
    </div>
  );
}

PYEOF_6123478320360535237

cat > "app/(main)/biometry/actions.js" << 'PYEOF_8770865463362024843'
'use server';

import { createClient } from '@/lib/supabase-server';

const MEAS_FIELDS = ['axl', 'k1', 'k2', 'acd', 'lt', 'wtw'];
const REQUIRED_FIELDS = ['axl', 'k1', 'k2', 'acd'];

// ── QUEUE ──
// Reads biometry_records directly (not queue_entries.status), same
// architecture as the Investigation Queue. This is deliberate: if it
// depended on queue_entries.status, sending a patient for both an
// investigation and Biometry in the same consultation would risk one
// overwriting the other and the patient silently vanishing from this
// screen. Reading the record itself means it always shows up here
// regardless of whatever else the patient's front-desk status says.
export async function getBiometryQueue() {
  const supabase = await createClient();

  const { data: records, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, doctor_id, patients(first_name, last_name, uhid))')
    .in('status', ['Awaiting Biometry', 'Measured', 'Calculated'])
    .order('created_at', { ascending: true });

  if (error) return { rows: [], stats: { awaiting: 0, measured: 0, calculated: 0, approvedToday: 0 } };

  const rows = (records || [])
    .filter((r) => r.visits)
    .map((r) => ({
      recordId: r.id,
      visitId: r.visit_id,
      encounterId: r.encounter_id,
      doctorId: r.visits?.doctor_id,
      patient: r.visits?.patients,
      status: r.status,
      procedureName: r.procedure_name,
      surgicalEye: r.surgical_eye,
    }));

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
// ── Used by the Doctor Dashboard's Biometry Approvals widget --
// records ready for surgeon sign-off, mapped to today's visits only. ──
export async function getBiometryApprovalsToday() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data, error } = await supabase
    .from('biometry_records')
    .select('id, surgical_eye, status, visits(id, visit_type, created_at, patients(first_name, last_name, uhid))')
    .eq('status', 'Calculated')
    .gte('visits.created_at', today);
  if (error) return [];
  // The visits filter above can't be applied as a proper join filter via
  // PostgREST here, so double-check in JS that the visit really is today's.
  return (data || []).filter((r) => r.visits && r.visits.created_at?.slice(0, 10) === today);
}

export async function approveIolPlan(id, plan) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: approverProfile } = await supabase.from('profiles').select('designation').eq('id', userData?.user?.id).maybeSingle();
  const isDoctor = approverProfile?.designation === 'Doctor';
  if (!isDoctor) return { error: 'Only a doctor can approve a biometry / IOL plan.' };

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

// ── FRONT OFFICE BILLING QUEUE ──
// Every biometry lands here the moment Counselling sends the patient
// for it (the stub row is created right then), regardless of how far
// the actual measurement/calculation/approval workflow has gotten --
// same "bill upfront, don't wait for completion" principle used for
// investigations and prescriptions.
export async function getPendingBiometryBilling() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('biometry_records')
    .select('*, visits(id, visit_number, patients(id, first_name, last_name, uhid))')
    .in('billing_status', ['Pending', 'Deferred'])
    .order('created_at', { ascending: true });

  if (error) return [];

  return (data || [])
    .filter((r) => r.visit_id && r.visits)
    .map((r) => ({ visitId: r.visit_id, visitNumber: r.visits.visit_number, patient: r.visits.patients, items: [r] }));
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

PYEOF_8770865463362024843

cat > "app/(main)/medical-fitness/actions.js" << 'PYEOF_3830460738616602642'
'use server';

import { createClient } from '@/lib/supabase-server';

// ── DASHBOARD: every referral (all statuses), so the dashboard can show
// stats across Pending/Cleared/Not Fit -- filtering to a specific stage
// happens client-side, same pattern as Counselling's own dashboard. ──
// ── HISTORY: completed referrals (Cleared / Not Fit) ──
export async function getMedicalFitnessHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .in('status', ['Cleared', 'Not Fit'])
    .order('cleared_at', { ascending: false });

  if (error) return [];

  const doctorIds = [...new Set((data || []).map((r) => r.cleared_by).filter(Boolean))];
  let doctorMap = {};
  if (doctorIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', doctorIds);
    (profiles || []).forEach((p) => { doctorMap[p.id] = p.full_name; });
  }

  return (data || [])
    .filter((r) => r.visits)
    .map((r) => ({ ...r, clearedByName: doctorMap[r.cleared_by] || '--' }));
}

// ── QUEUE (TAB 1): patients referred by Counselling, awaiting doctor
// review. Reads medical_fitness_referrals directly (same architecture
// as the Biometry Queue) rather than the front-desk queue_entries
// system. ──
export async function getMedicalFitnessQueue() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, visit_type, patients(first_name, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .eq('status', 'Pending Review')
    .order('referred_at', { ascending: true });

  if (error) return [];
  return (data || []).filter((r) => r.visits);
}

// ── Used by the Doctor Dashboard's Medical Fitness widget -- pending
// referrals mapped to today's visits only. ──
export async function getMedicalFitnessToday() {
  const rows = await getMedicalFitnessQueue();
  const today = new Date().toISOString().slice(0, 10);
  return rows.filter((r) => r.referred_at?.slice(0, 10) === today);
}

// ── WORKSPACE: full clinical picture + ability to order investigations ──
export async function getMedicalFitnessDetail(referralId) {
  const supabase = await createClient();
  const { data: referral, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(id, first_name, last_name, uhid, age, gender)), surgical_cases(procedure_name, eye, priority, decision)')
    .eq('id', referralId)
    .single();

  if (error) return { error: error.message };

  const patientId = referral.visits.patients.id;

  const [{ data: currentDiagnoses }, { data: investigations }, { data: diagnosisHistoryRaw }, { data: referredByProfile }, { data: clearedByProfile }] = await Promise.all([
    referral.encounter_id
      ? supabase.from('diagnoses').select('*').eq('encounter_id', referral.encounter_id).order('created_at')
      : Promise.resolve({ data: [] }),
    referral.encounter_id
      ? supabase.from('investigation_orders').select('*').eq('encounter_id', referral.encounter_id).order('created_at', { ascending: false })
      : Promise.resolve({ data: [] }),
    // Longitudinal (cross-visit) diagnosis history, same pattern as Consultation.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    referral.referred_by
      ? supabase.from('profiles').select('full_name').eq('id', referral.referred_by).maybeSingle()
      : Promise.resolve({ data: null }),
    referral.cleared_by
      ? supabase.from('profiles').select('full_name').eq('id', referral.cleared_by).maybeSingle()
      : Promise.resolve({ data: null }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== referral.encounter_id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  return {
    referral,
    currentDiagnoses: currentDiagnoses || [],
    investigations: investigations || [],
    diagnosisHistory,
    referredByName: referredByProfile?.full_name || '--',
    clearedByName: clearedByProfile?.full_name || null,
  };
}

// Same master list Consultation/Counselling's investigation pickers use.
export async function getInvestigationMasterOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  return data || [];
}

export async function orderFitnessInvestigation(referralId, encounterId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Select or enter an investigation.' };
  if (!encounterId) return { error: 'This referral has no linked clinical encounter to attach the investigation to.' };

  const { data: userData } = await supabase.auth.getUser();
  // Claim the referral for whichever doctor is the first to open and
  // act on it, without overwriting if someone already has.
  await supabase.from('medical_fitness_referrals').update({ reviewing_doctor_id: userData?.user?.id || null }).eq('id', referralId).is('reviewing_doctor_id', null);

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId, name: values.name, eye: values.eye || 'N/A', priority: values.priority || 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeFitnessInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function clearFitness(referralId, notes) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: referral } = await supabase.from('medical_fitness_referrals').select('surgical_case_id').eq('id', referralId).single();
  if (!referral) return { error: 'Referral not found.' };

  const { error } = await supabase.from('medical_fitness_referrals').update({
    status: 'Cleared', fitness_notes: notes?.trim() || null,
    cleared_by: userData?.user?.id || null, cleared_at: new Date().toISOString(),
    reviewing_doctor_id: userData?.user?.id || null,
  }).eq('id', referralId);
  if (error) return { error: error.message };

  // The one thing Counselling's readiness checklist has always checked --
  // now set by the doctor's actual clearance instead of a self-service tick.
  await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', referral.surgical_case_id);
  return { success: true };
}

export async function markNotFit(referralId, notes) {
  const supabase = await createClient();
  if (!notes || !notes.trim()) return { error: 'Notes are required when marking a patient not fit -- Counselling needs to know why.' };
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('medical_fitness_referrals').update({
    status: 'Not Fit', fitness_notes: notes.trim(),
    cleared_by: userData?.user?.id || null, cleared_at: new Date().toISOString(),
    reviewing_doctor_id: userData?.user?.id || null,
  }).eq('id', referralId);
  if (error) return { error: error.message };
  return { success: true };
}

PYEOF_3830460738616602642

cat > "app/(main)/ot-postop/workspace.js" << 'PYEOF_9137924173934182600'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostOpEpisodeDetail, rescheduleFollowup, saveFollowupNotes, markFollowupStatus,
  addRecoveryComplication, closeEpisode, openFollowupReview, addFollowup, removeFollowup,
} from './actions';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';

const MILESTONES_START = [
  { key: 'recovery', label: 'Recovery', icon: 'ti-bed' },
  { key: 'discharge', label: 'Discharge', icon: 'ti-door-exit' },
];
const MILESTONES_END = [
  { key: 'closure', label: 'Episode Closure', icon: 'ti-circle-check' },
];


export default function Workspace({ episodeId, readOnly, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [editingFollowupId, setEditingFollowupId] = useState(null);
  const [editDate, setEditDate] = useState('');
  const [notesEditingId, setNotesEditingId] = useState(null);
  const [notesDraft, setNotesDraft] = useState('');
  const [attachmentsByFollowup, setAttachmentsByFollowup] = useState({});
  const [uploadingFollowupId, setUploadingFollowupId] = useState(null);
  const [saving, setSaving] = useState(false);

  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [showClose, setShowClose] = useState(false);
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const [openingReview, setOpeningReview] = useState(null);

  const [showAddFollowup, setShowAddFollowup] = useState(false);
  const [newFollowupLabel, setNewFollowupLabel] = useState('');
  const [newFollowupDate, setNewFollowupDate] = useState('');
  const [addingFollowup, setAddingFollowup] = useState(false);
  const [removingFollowupId, setRemovingFollowupId] = useState(null);

  const refresh = useCallback(async () => {
    const result = await getPostOpEpisodeDetail(episodeId);
    setData(result);
    if (!result.error && result.followups?.length > 0) {
      const entries = await Promise.all(result.followups.map(async (f) => [f.id, await getAttachments('postop_followup', f.id)]));
      setAttachmentsByFollowup(Object.fromEntries(entries));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); }, [episodeId, refresh]);

  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
  if (data.error) return <div className="msg-err">{data.error}</div>;


  const { episode, sc, followups, complications } = data;
  const patient = sc?.patients;
  const isClosed = !!episode.closure_status;
  const todayStr = new Date().toISOString().slice(0, 10);

  const milestoneStatus = (key) => {
    if (key === 'recovery') return 'done';
    if (key === 'discharge') return episode.discharge_date ? 'done' : 'pending';
    if (key === 'closure') return episode.closure_status ? 'done' : 'pending';
    return 'pending';
  };

  function startEdit(f) {
    setError('');
    setEditingFollowupId(f.id);
    setEditDate(f.scheduled_date);
  }

  function startNotesEdit(f) {
    setError('');
    setNotesEditingId(f.id);
    setNotesDraft(f.notes || '');
  }

  async function handleSaveNotesOnly(f) {
    setError('');
    setSaving(true);
    const result = await saveFollowupNotes(f.id, notesDraft);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setNotesEditingId(null);
    refresh();
  }

  async function handleUploadFollowupFile(followupId, file) {
    if (!file) return;
    setUploadingFollowupId(followupId);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', 'postop_followup');
    formData.append('entityId', followupId);
    const result = await uploadAttachment(formData);
    setUploadingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleRemoveFollowupFile(file) {
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  async function handleSaveFollowup(f) {
    setError('');
    if (!editDate || editDate === f.scheduled_date) { setEditingFollowupId(null); return; }
    setSaving(true);
    const result = await rescheduleFollowup(f.id, editDate, f.notes || '');
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEditingFollowupId(null);
    refresh();
  }

  async function handleMarkStatus(f, status) {
    setError('');
    const result = await markFollowupStatus(f.id, status);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addRecoveryComplication(episodeId, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    refresh();
  }

  async function handleOpenReview(f) {
    setError('');
    setOpeningReview(f.id);
    const result = await openFollowupReview(f.id);
    setOpeningReview(null);
    if (result.error) { setError(result.error); return; }
    // Opens in its own window (closes itself once the doctor finishes --
    // see finishAndClose() in consultation-form.js) -- poll for it
    // closing so the follow-up list refreshes without waiting on a timer.
    const win = window.open(`/consultation/${result.queueEntryId}`, 'postop-review-window');
    if (win) {
      const poll = setInterval(() => {
        if (win.closed) { clearInterval(poll); refresh(); }
      }, 800);
    }
  }

  async function handleAddFollowup() {
    setError('');
    if (!newFollowupLabel.trim()) { setError('A label for the review is required.'); return; }
    if (!newFollowupDate) { setError('A date is required.'); return; }
    setAddingFollowup(true);
    const result = await addFollowup(episodeId, newFollowupLabel, newFollowupDate);
    setAddingFollowup(false);
    if (result.error) { setError(result.error); return; }
    setNewFollowupLabel(''); setNewFollowupDate(''); setShowAddFollowup(false);
    refresh();
  }

  async function handleRemoveFollowup(followupId) {
    setError('');
    setRemovingFollowupId(followupId);
    const result = await removeFollowup(followupId);
    setRemovingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleCloseEpisode() {
    setError('');
    if (!closureOutcome) { setError('VAL-POST-005: Overall clinical outcome is required.'); return; }
    setSaving(true);
    const result = await closeEpisode(episodeId, { status: closureStatus, outcome: closureOutcome, remarks: closureRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowClose(false);
    setOk('Episode closed.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient?.uhid} -- {sc?.procedure_name} {sc?.eye} -- {sc?.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Closed' : 'Post-op'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {ok && <div className="msg-ok">{ok}</div>}

      {readOnly && !isClosed && (
        <div className="msg-info" style={{ marginBottom: 14 }}>
          <i className="ti ti-eye"></i> Read-only view -- this patient doesn't have a visit today. You can still view any past review records below. Open them from "Turned Up Today" on the Dashboard once they've checked in to start a new review.
        </div>
      )}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Surgical Episode Dashboard</div>

        {MILESTONES_START.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}

        {followups.length === 0 && (
          <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No follow-ups scheduled yet.</div>
        )}
        {followups.map((f) => {
          const color = f.status === 'Completed' ? 'var(--green)' : f.status === 'Due' ? 'var(--red)' : 'var(--blue)';
          const bg = f.status === 'Completed' ? 'var(--green-lt)' : f.status === 'Due' ? 'var(--red-lt)' : 'var(--blue-lt)';
          const icon = f.status === 'Completed' ? 'ti-check' : 'ti-calendar';
          return (
            <div key={f.id} style={{ padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 12, marginBottom: 8, background: bg }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color, flexShrink: 0 }}><i className={`ti ${icon}`}></i></div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 13 }}>{f.visit_label}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {new Date(f.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                    {f.scheduled_date > todayStr && f.status !== 'Completed' && <span style={{ color: 'var(--blue)', marginLeft: 6 }}>-- upcoming</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  {f.rescheduled_count > 0 && <span style={{ fontSize: 10, color: 'var(--amber)' }}>Rescheduled {f.rescheduled_count}x</span>}
                  <span className="badge" style={{ background: `${color}20`, color }}>{f.status}</span>
                </div>
              </div>

              {f.notes && notesEditingId !== f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: '8px 10px', background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}><i className="ti ti-notes"></i> Notes</div>
                  <div style={{ fontSize: 12.5, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{f.notes}</div>
                </div>
              )}

              {notesEditingId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <textarea className="fi fi-sm" rows={3} value={notesDraft} onChange={(e) => setNotesDraft(e.target.value)} placeholder="Notes for this visit..." style={{ marginBottom: 6 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveNotesOnly(f)} disabled={saving}>Save Notes</button>
                    <button className="btn btn-sm" onClick={() => setNotesEditingId(null)}>Cancel</button>
                  </div>
                </div>
              )}

              {/* Optional attachment -- any file relevant to this visit */}
              <div style={{ marginTop: 8, marginLeft: 42 }}>
                {(attachmentsByFollowup[f.id] || []).map((file) => (
                  <div key={file.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11.5, padding: '4px 0' }}>
                    <i className="ti ti-paperclip" style={{ color: 'var(--g500)' }}></i>
                    {file.url ? <a href={file.url} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--blue)' }}>{file.file_name}</a> : <span>{file.file_name}</span>}
                    {!isClosed && !readOnly && <button onClick={() => handleRemoveFollowupFile(file)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 11 }}>Remove</button>}
                  </div>
                ))}
                {!isClosed && !readOnly && (
                  <label className="btn btn-sm" style={{ cursor: 'pointer', marginTop: 4, display: 'inline-flex' }}>
                    {uploadingFollowupId === f.id ? 'Uploading...' : <><i className="ti ti-upload"></i> Attach file (optional)</>}
                    <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadFollowupFile(f.id, e.target.files?.[0])} disabled={uploadingFollowupId === f.id} />
                  </label>
                )}
              </div>

              {!isClosed && editingFollowupId !== f.id && (readOnly ? !!f.visit_id : true) && (
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 42 }}>
                  {readOnly ? (
                    <button className="btn btn-sm" onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                      <i className="ti ti-eye"></i> {openingReview === f.id ? 'Opening...' : 'View Record'}
                    </button>
                  ) : f.scheduled_date === todayStr ? (
                    <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                      <i className="ti ti-clipboard-text"></i> {openingReview === f.id ? 'Opening...' : f.visit_id ? 'Open Review' : 'Start Review'}
                    </button>
                  ) : (
                    <button
                      className="btn btn-sm"
                      disabled
                      style={{ opacity: 0.5, cursor: 'not-allowed' }}
                      title="This review can only be opened on its scheduled date -- reschedule it to today first"
                    >
                      <i className="ti ti-calendar-time"></i> {f.scheduled_date > todayStr ? 'Not due yet' : 'Reschedule to open'}
                    </button>
                  )}
                  {!readOnly && (
                    <>
                      <button className="btn btn-sm" onClick={() => startEdit(f)}><i className="ti ti-calendar-time"></i> Reschedule</button>
                      {notesEditingId !== f.id && (
                        <button className="btn btn-sm" onClick={() => startNotesEdit(f)}><i className="ti ti-edit"></i> {f.notes ? 'Edit Notes' : 'Add Notes'}</button>
                      )}
                      {f.status !== 'Completed' && (
                        <button
                          className="btn btn-sm"
                          style={{ background: 'var(--green)', color: '#fff', border: 'none', opacity: f.scheduled_date > todayStr ? 0.5 : 1, cursor: f.scheduled_date > todayStr ? 'not-allowed' : 'pointer' }}
                          onClick={() => handleMarkStatus(f, 'Completed')}
                          disabled={f.scheduled_date > todayStr}
                          title={f.scheduled_date > todayStr ? "This visit hasn't happened yet" : ''}
                        >
                          Mark Completed
                        </button>
                      )}
                      <button
                        className="btn btn-sm"
                        style={{ color: 'var(--red)' }}
                        onClick={() => handleRemoveFollowup(f.id)}
                        disabled={removingFollowupId === f.id}
                        title={f.visit_id ? 'A review that already has a visit recorded cannot be removed' : 'Remove this review'}
                      >
                        <i className="ti ti-trash"></i> {removingFollowupId === f.id ? 'Removing...' : 'Remove'}
                      </button>
                    </>
                  )}
                </div>
              )}

              {!readOnly && editingFollowupId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8 }}>
                  <div style={{ marginBottom: 6 }}>
                    <label className="flbl">New date</label>
                    <input type="date" className="fi fi-sm" value={editDate} onChange={(e) => setEditDate(e.target.value)} />
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveFollowup(f)} disabled={saving}>Save</button>
                    <button className="btn btn-sm" onClick={() => setEditingFollowupId(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          );
        })}

        {!isClosed && !readOnly && (
          showAddFollowup ? (
            <div style={{ padding: '10px 12px', border: '1px dashed var(--g300)', borderRadius: 12, marginBottom: 8 }}>
              <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={newFollowupLabel} onChange={(e) => setNewFollowupLabel(e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 150 }} value={newFollowupDate} onChange={(e) => setNewFollowupDate(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={handleAddFollowup} disabled={addingFollowup}>{addingFollowup ? 'Adding...' : 'Add Review'}</button>
                <button className="btn btn-sm" onClick={() => { setShowAddFollowup(false); setNewFollowupLabel(''); setNewFollowupDate(''); }}>Cancel</button>
              </div>
            </div>
          ) : (
            <button className="btn btn-sm" style={{ marginBottom: 8 }} onClick={() => setShowAddFollowup(true)}><i className="ti ti-plus"></i> Add Review</button>
          )
        )}

        {MILESTONES_END.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Post-operative Complications <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(separate from intraop)</span></div>
        {!isClosed && !readOnly && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication (e.g. Raised IOP, CME)..." />
              <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management..." />
              <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome..." />
            </div>
            <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
          </>
        )}
        <div style={{ marginTop: 8 }}>
          {complications.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No post-operative complications recorded.</div>}
          {complications.map((c) => (
            <div key={c.id} style={{ padding: '8px 10px', borderRadius: 8, background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)', marginBottom: 6, fontSize: 12 }}>
              <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>{c.management ? `Management: ${c.management}` : <span style={{ color: 'var(--red)' }}>Management pending -- required before episode can close</span>}</div>
              {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
            </div>
          ))}
        </div>
      </div>

      {!isClosed && !readOnly && !showClose && (
        <div className="card" style={{ textAlign: 'center', marginBottom: 0 }}>
          <button className="btn btn-primary" onClick={() => setShowClose(true)}><i className="ti ti-circle-check"></i> Close Surgical Episode</button>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 6 }}>Only the Ophthalmologist should close an episode. Overall outcome must be documented.</div>
        </div>
      )}

      {showClose && !readOnly && (
        <div className="card" style={{ marginBottom: 0 }}>
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-circle-check" style={{ color: 'var(--purple)' }}></i> Close Surgical Episode</div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Episode closure status</label>
            <select className="fi" value={closureStatus} onChange={(e) => setClosureStatus(e.target.value)}>
              <option>Successfully Completed</option><option>Completed with Residual Condition</option><option>Requires Ongoing Follow-up</option><option>Transferred to Long-term Care</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Overall clinical outcome *</label>
            <select className="fi" value={closureOutcome} onChange={(e) => setClosureOutcome(e.target.value)}>
              <option value="">-- Select --</option>
              <option>Excellent Visual Outcome</option><option>Expected Recovery</option><option>Delayed Recovery</option><option>Complication Managed</option><option>Additional Surgery Required</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Closure remarks</label>
            <textarea className="fi" rows={2} value={closureRemarks} onChange={(e) => setClosureRemarks(e.target.value)} placeholder="Final remarks..." />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleCloseEpisode} disabled={saving}>{saving ? 'Closing...' : 'Close Episode'}</button>
            <button className="btn" onClick={() => setShowClose(false)}>Cancel</button>
          </div>
        </div>
      )}

      {isClosed && (
        <div className="msg-ok">
          <i className="ti ti-circle-check"></i>
          <span><strong>Episode Closed</strong> -- {episode.closure_status}. Outcome: {episode.closure_outcome}. {episode.closure_remarks}</span>
        </div>
      )}
    </div>
  );
}

PYEOF_9137924173934182600

echo "Files written. Run: npm run build"
