#!/bin/bash
set -e

echo 'Applying: Medical Fitness dashboard redesign + Visit Timeline tab...'

mkdir -p 'app/(main)/medical-fitness/[id]'

cat > 'app/(main)/medical-fitness/actions.js' << 'MF_ACTIONS_EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

// ── DASHBOARD: every referral (all statuses), so the dashboard can show
// stats across Pending/Cleared/Not Fit -- filtering to a specific stage
// happens client-side, same pattern as Counselling's own dashboard. ──
export async function getMedicalFitnessQueue() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('medical_fitness_referrals')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid)), surgical_cases(procedure_name, eye, priority)')
    .order('referred_at', { ascending: true });

  if (error) return [];
  return (data || []).filter((r) => r.visits);
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

  const [{ data: currentDiagnoses }, { data: investigations }, { data: diagnosisHistoryRaw }, { data: referredByProfile }] = await Promise.all([
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

MF_ACTIONS_EOF

cat > 'app/(main)/medical-fitness/page.js' << 'MF_PAGE_EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getMedicalFitnessQueue } from './actions';

const STATUS_BADGE = { 'Pending Review': 'b-amber', Cleared: 'b-green', 'Not Fit': 'b-red' };

function KpiCard({ label, value, sub, color, active, onClick }) {
  return (
    <button
      onClick={onClick}
      className="card"
      style={{ borderLeft: `3px solid ${color}`, marginBottom: 0, textAlign: 'left', cursor: 'pointer', background: active ? 'var(--g50)' : '#fff', fontFamily: 'inherit' }}
    >
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </button>
  );
}

function daysWaiting(referral) {
  const ms = new Date() - new Date(referral.referred_at);
  return Math.floor(ms / (1000 * 60 * 60 * 24));
}

export default function MedicalFitnessDashboardPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [statusFilter, setStatusFilter] = useState('Pending Review');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');
  const router = useRouter();

  useEffect(() => {
    getMedicalFitnessQueue().then((r) => { setRows(r); setLoading(false); });
  }, []);

  const todayStart = new Date();
  todayStart.setHours(0, 0, 0, 0);

  const counts = {
    'Pending Review': rows.filter((r) => r.status === 'Pending Review').length,
    Cleared: rows.filter((r) => r.status === 'Cleared').length,
    'Not Fit': rows.filter((r) => r.status === 'Not Fit').length,
  };
  const clearedToday = rows.filter((r) => r.status === 'Cleared' && r.cleared_at && new Date(r.cleared_at) >= todayStart).length;

  let filtered = statusFilter ? rows.filter((r) => r.status === statusFilter) : rows;
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
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
        <KpiCard label="Pending Review" value={counts['Pending Review']} sub="Awaiting doctor" color="var(--amber)" active={statusFilter === 'Pending Review'} onClick={() => setStatusFilter('Pending Review')} />
        <KpiCard label="Cleared today" value={clearedToday} sub="Cleared for surgery" color="var(--green)" active={false} onClick={() => setStatusFilter('Cleared')} />
        <KpiCard label="Not Fit" value={counts['Not Fit']} sub="Needs re-referral" color="var(--red)" active={statusFilter === 'Not Fit'} onClick={() => setStatusFilter('Not Fit')} />
        <KpiCard label="All referrals" value={rows.length} sub="Every status" color="var(--indigo)" active={!statusFilter} onClick={() => setStatusFilter('')} />
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness Queue</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
            <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
              <option value="oldest">Oldest first</option>
              <option value="newest">Newest first</option>
              <option value="priority">Priority</option>
            </select>
          </div>
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
          <button className={`btn btn-sm ${!statusFilter ? 'btn-primary' : ''}`} onClick={() => setStatusFilter('')}>All ({rows.length})</button>
          {Object.entries(counts).map(([status, count]) => (
            <button key={status} className={`btn btn-sm ${statusFilter === status ? 'btn-primary' : ''}`} onClick={() => setStatusFilter(status)}>
              {status} ({count})
            </button>
          ))}
        </div>

        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

        {!loading && filtered.map((r) => {
          const dw = daysWaiting(r);
          return (
            <div
              key={r.id}
              onClick={() => router.push(`/medical-fitness/${r.id}`)}
              style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}
            >
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {r.visits?.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{r.visits?.patients?.first_name} {r.visits?.patients?.last_name}</span>
                <span className={`badge ${STATUS_BADGE[r.status] || 'b-gray'}`} style={{ marginLeft: 8, fontSize: 10 }}>{r.status}</span>
                {r.surgical_cases?.priority && r.surgical_cases.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{r.surgical_cases.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name} ({r.surgical_cases?.eye})
                </div>
              </div>
              {r.status === 'Pending Review' && (
                <div style={{ textAlign: 'right', fontSize: 10, color: dw > 3 ? 'var(--red)' : dw > 1 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                  {dw === 0 ? 'Today' : `${dw}d waiting`}
                </div>
              )}
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}

        {!loading && filtered.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {rows.length === 0 ? 'No referrals yet. Counsellors refer patients from Counselling once package is confirmed and accepted.' : 'No referrals match this filter.'}
          </div>
        )}
      </div>
    </div>
  );
}

MF_PAGE_EOF

cat > 'app/(main)/medical-fitness/[id]/workspace.js' << 'MF_WORKSPACE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getMedicalFitnessDetail, getInvestigationMasterOptions,
  orderFitnessInvestigation, removeFitnessInvestigation,
  clearFitness, markNotFit,
} from '../actions';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };
const TIMELINE_TYPE_COLOR = { Visit: 'var(--blue)', Diagnosis: 'var(--red)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--amber)' };
const TIMELINE_TYPE_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{
        flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none',
        background: active ? '#fff' : 'transparent', color: active ? 'var(--amber)' : 'var(--g500)',
        cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none',
      }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function MedicalFitnessWorkspace({ referralId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [activeTab, setActiveTab] = useState('summary');

  const [invOptions, setInvOptions] = useState([]);
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('N/A');
  const [invPriority, setInvPriority] = useState('Routine');
  const [ordering, setOrdering] = useState(false);

  const [timeline, setTimeline] = useState(null);
  const [timelineLoading, setTimelineLoading] = useState(false);

  const [decisionNotes, setDecisionNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getMedicalFitnessDetail(referralId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
  }, [referralId]);

  useEffect(() => {
    refresh();
    getInvestigationMasterOptions().then(setInvOptions);
  }, [refresh]);

  useEffect(() => {
    if (activeTab === 'timeline' && !timeline && data) {
      setTimelineLoading(true);
      getPatientTimeline(data.referral.visits.patients.id).then((t) => { setTimeline(t); setTimelineLoading(false); });
    }
  }, [activeTab, timeline, data]);

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
    router.push('/medical-fitness');
  }

  async function handleMarkNotFit() {
    setError('');
    if (!decisionNotes.trim()) { setError('Notes are required when marking not fit.'); return; }
    setSaving(true);
    const result = await markNotFit(referralId, decisionNotes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    router.push('/medical-fitness');
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const { referral, currentDiagnoses, investigations, diagnosisHistory, referredByName } = data;
  const patient = referral.visits.patients;
  const sc = referral.surgical_cases;
  const isPending = referral.status === 'Pending Review';

  return (
    <div style={{ maxWidth: 1100, margin: '0 auto' }}>
      <div style={{ background: 'linear-gradient(135deg,#b45309,#d97706)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 16, display: 'flex', alignItems: 'center', gap: 12 }}>
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
          <div style={{ fontSize: 10, opacity: .8 }}>By {referredByName} -- {new Date(referral.referred_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })}</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {referral.status !== 'Pending Review' && (
        <div className={`msg-${referral.status === 'Cleared' ? 'ok' : 'err'}`} style={{ marginBottom: 12 }}>
          <i className={`ti ${referral.status === 'Cleared' ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i>
          <span><strong>{referral.status}</strong>{referral.fitness_notes ? ` -- ${referral.fitness_notes}` : ''}</span>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.4fr 1fr', gap: 14 }}>
        <div>
          <div style={{ display: 'flex', gap: 2, marginBottom: 12, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            <TabButton active={activeTab === 'summary'} onClick={() => setActiveTab('summary')} icon="ti-report-medical" label="Clinical Summary" />
            <TabButton active={activeTab === 'timeline'} onClick={() => setActiveTab('timeline')} icon="ti-timeline" label="Visit Timeline" />
            <TabButton active={activeTab === 'investigations'} onClick={() => setActiveTab('investigations')} icon="ti-flask" label={`Investigations${investigations.length > 0 ? ` (${investigations.length})` : ''}`} />
          </div>

          {activeTab === 'summary' && (
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
                      <span style={{ color: 'var(--g400)', fontSize: 10.5 }}>{new Date(d.encounterDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      {' -- '}<strong>{d.name}</strong> -- {d.eye}
                    </div>
                  ))}
                  {diagnosisHistory.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior diagnoses on record.</div>}
                </div>
              </div>
            </>
          )}

          {activeTab === 'timeline' && (
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
                          <div style={{ fontSize: 10, color: 'var(--g400)', marginBottom: 2 }}>{new Date(ev.date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</div>
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

          {activeTab === 'investigations' && (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>

              {investigations.map((i) => {
                const type = matchInvestigationType(i.name);
                const hasResults = i.status === 'Available';
                return (
                  <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 12.5 }}>
                      <span><strong>{i.name}</strong> -- {i.eye}</span>
                      <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                        <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                        {hasResults && (
                          <a href={`/investigation/${i.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ padding: '2px 6px', fontSize: 10, textDecoration: 'none' }}>
                            <i className="ti ti-eye"></i> View
                          </a>
                        )}
                        {i.status === 'Ordered' && isPending && (
                          <button className="btn" style={{ padding: '2px 6px', fontSize: 10 }} onClick={() => handleRemoveInvestigation(i.id)}>Remove</button>
                        )}
                      </div>
                    </div>
                    {hasResults && (
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

MF_WORKSPACE_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/medical-fitness"'
echo '  git commit -m "Medical Fitness: dashboard/queue redesign + Visit Timeline tab with read-only consultation access"'
echo '  git push'
