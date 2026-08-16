#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/query-only change -- no DB migration needed.
#
# Same fix as OT Intraop's Dashboard/History split, applied to Recovery:
# a patient discharged TODAY now stays on the Recovery Dashboard (in a
# new "Discharged Today" section, separate from "Patients in Recovery")
# instead of immediately disappearing into History. It only moves to
# History once the day rolls over.
#
# getRecoveryCaseList() now returns not-yet-discharged episodes PLUS
# episodes discharged today. getRecoveryHistory() now excludes today,
# so there's no duplication between Dashboard and History on the same
# day.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/actions.js" << 'FILEEOF_ot_recovery_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { DISCHARGE_ITEMS } from './constants';
import { getDrugs } from '../master-data/actions';

// Same Pharmacy drug list used in Financial Masters -- so post-op
// medication is picked from the real catalog, not free text. Label
// leads with Name (brand), not Salt Composition (generic) -- this is
// what ends up stored as the medication name and printed on the
// Discharge Summary.
export async function getDrugOptions() {
  const all = await getDrugs();
  return all
    .filter((d) => d.status === 'Active' && d.brand)
    .map((d) => ({ id: d.id, label: `${d.brand}${d.strength ? ` ${d.strength}` : ''}${d.generic ? ` (${d.generic})` : ''}` }));
}

// Called from OT Intraop's "Hand Over to Recovery" -- creates the
// episode the moment a patient actually arrives here, same
// lazy-create-on-handoff pattern used for biometry/medical fitness.
// visit_id is optional -- a surgical case registered directly (e.g. OT
// Schedule's "Register Surgery Directly", for a patient whose surgery
// was decided outside today's Doctor -> Counselling pipeline) may not
// have one. Recovery still needs to work for that patient; it just
// can't show the pre-approved biometry/IOL plan (there isn't one to
// show -- biometry was skipped for exactly this kind of case anyway).
export async function ensureRecoveryEpisode(otScheduleId, surgicalCaseId, visitId, scheduledDate) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('recovery_episodes').select('id').eq('ot_schedule_id', otScheduleId).maybeSingle();
  if (existing) return existing.id;
  const { data: created, error } = await supabase.from('recovery_episodes').insert({
    ot_schedule_id: otScheduleId, surgical_case_id: surgicalCaseId, visit_id: visitId || null,
    admission_date: scheduledDate, surgery_date: scheduledDate,
  }).select('id').single();
  if (error) {
    console.error('ensureRecoveryEpisode failed:', error.message, { otScheduleId, surgicalCaseId, visitId });
    return null;
  }
  return created.id;
}

// ── DASHBOARD: patients still in recovery, not yet discharged -- PLUS
// anyone discharged today. A discharge shouldn't make the patient
// vanish from the dashboard the instant it happens; it only moves to
// History once the day rolls over (same pattern as OT Intraop's
// Dashboard vs History split). ──
export async function getRecoveryCaseList() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .or(`discharge_date.is.null,discharge_date.eq.${todayIst}`)
    .order('created_at', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: discharged episodes from BEFORE today -- Recovery's part
// is done, Post Op takes over follow-up tracking and closure from here.
// Today's discharges stay on the Dashboard until the day rolls over. ──
export async function getRecoveryHistory() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .lt('discharge_date', todayIst)
    .order('discharge_date', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL ──
export async function getRecoveryEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, ot_schedule_id, surgical_cases(*, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const sc = episode.surgical_cases;

  const [{ data: intraop }, { data: biometry }, { data: meds }, { data: followups }, { data: complications }] = await Promise.all([
    supabase.from('ot_intraop_records').select('implant_power, implant_manufacturer, implant_model, surgical_outcome, outcome_remarks').eq('ot_schedule_id', episode.ot_schedule_id).maybeSingle(),
    // visit_id may be null for a directly-registered surgical case (no
    // biometry plan to show either way, since biometry was skipped for
    // that kind of case) -- skip the lookup entirely rather than
    // querying with a null value.
    episode.visit_id
      ? supabase.from('biometry_records').select('final_iol_power, final_iol_category, surgical_eye').eq('visit_id', episode.visit_id).eq('status', 'Approved')
      : Promise.resolve({ data: [] }),
    supabase.from('recovery_medications').select('*').eq('recovery_episode_id', episodeId).order('added_at'),
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return {
    episode, sc, intraop: intraop || null, biometryPlans: biometry || [],
    meds: meds || [], followups: followups || [], complications: complications || [],
  };
}

// ── RECOVERY ASSESSMENT / GENERAL SAVE ──
export async function saveRecoveryFields(episodeId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_episodes').update(values).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── MEDICATIONS ──
export async function addRecoveryMedication(episodeId, name, sig, reason) {
  const supabase = await createClient();
  if (!name?.trim() || !sig?.trim()) return { error: 'Medicine name and dose/frequency are required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_medications').insert({ recovery_episode_id: episodeId, name: name.trim(), sig: sig.trim(), reason: reason?.trim() || null, added_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeRecoveryMedication(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_medications').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── DISCHARGE ──
// The 4 suggested review dates (Day 1 / Week 1 / Month 1 / Final
// Refraction) are a starting point, not a rule -- different surgeries
// need different review schedules, so the doctor can edit labels/dates
// or remove any of them before confirming discharge. followupPlan is
// whatever's left in that editable list at the time of discharge.
export async function confirmDischarge(episodeId, checklist, dischargeNotes, dischargeInstructions, dischargeDate, followupPlan) {
  const supabase = await createClient();

  const mandatoryDone = DISCHARGE_ITEMS.filter((i) => i.mandatory).every((i) => checklist[i.key]);
  if (!mandatoryDone) return { error: 'VAL-POST-002: All mandatory discharge items must be checked.' };
  if (!dischargeDate) return { error: 'Discharge date is required.' };

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('recovery_episodes').update({
    discharge_date: dischargeDate, discharge_checklist: checklist,
    discharge_notes: dischargeNotes || null, discharge_instructions: dischargeInstructions || null,
    discharged_by: userData?.user?.id || null, discharged_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };

  const followups = (followupPlan || [])
    .filter((f) => f.visit_label?.trim() && f.scheduled_date)
    .map((f) => ({ recovery_episode_id: episodeId, visit_label: f.visit_label.trim(), scheduled_date: f.scheduled_date }));
  if (followups.length > 0) {
    await supabase.from('recovery_followups').insert(followups);
  }

  return { success: true };
}

// ── QUALITY INDICATORS (real, computed from actual data) ──
export async function getQualityIndicators() {
  const supabase = await createClient();
  const monthStart = new Date(); monthStart.setDate(1); monthStart.setHours(0, 0, 0, 0);

  const { data: closedThisMonth } = await supabase.from('recovery_episodes').select('id, closure_outcome, admission_date, discharge_date').gte('closed_at', monthStart.toISOString());
  const { data: complicationsThisMonth } = await supabase.from('recovery_complications').select('id, recovery_episode_id').gte('occurred_at', monthStart.toISOString());
  const { data: escalations } = await supabase.from('recovery_episodes').select('id').eq('escalation_required', true).gte('created_at', monthStart.toISOString());

  const total = closedThisMonth?.length || 0;
  const withComplications = new Set((complicationsThisMonth || []).map((c) => c.recovery_episode_id)).size;
  const sameDayDischarge = (closedThisMonth || []).filter((e) => e.admission_date && e.discharge_date && e.admission_date === e.discharge_date).length;

  return [
    { name: 'Episodes closed this month', value: String(total), sub: 'All procedures' },
    { name: 'Post-op complication rate', value: total > 0 ? `${((withComplications / total) * 100).toFixed(1)}%` : '--', sub: `${withComplications} of ${total} episodes` },
    { name: 'Same-day discharge rate', value: total > 0 ? `${((sameDayDischarge / total) * 100).toFixed(1)}%` : '--', sub: `${sameDayDischarge} of ${total} episodes` },
    { name: 'Escalations flagged', value: String(escalations?.length || 0), sub: 'This month' },
  ];
}

FILEEOF_ot_recovery_actions_js

mkdir -p "app/(main)/ot-recovery"
cat > "app/(main)/ot-recovery/page.js" << 'FILEEOF_ot_recovery_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getRecoveryCaseList, getRecoveryHistory } from './actions';
import Workspace from './workspace';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--teal)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  const inRecovery = cases.filter((c) => !c.discharge_date);
  const dischargedToday = cases.filter((c) => c.discharge_date);

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 10, marginBottom: 14, maxWidth: 420 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--teal)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>In recovery, not yet discharged</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{inRecovery.length}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Discharged today</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{dischargedToday.length}</div>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-bed" style={{ color: 'var(--teal)' }}></i> Patients in Recovery</div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && inRecovery.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--teal)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className="badge b-amber" style={{ marginLeft: 8, fontSize: 10 }}>Recovery</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
                </div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Open</button>
            </div>
          );
        })}
        {!loading && inRecovery.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No patients currently in recovery.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Discharged Today</div>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Moves to History tomorrow -- still open here today for reference or a correction.</div>
        {!loading && dischargedToday.map((c) => {
          const sc = c.surgical_cases;
          const patient = sc.patients;
          return (
            <div key={c.id} onClick={() => onOpen(c.id)} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {patient?.first_name?.charAt(0)}
              </div>
              <div style={{ flex: 1 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
                <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>Discharged</span>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
                </div>
              </div>
              <button className="btn btn-sm"><i className="ti ti-eye"></i> View</button>
            </div>
          );
        })}
        {!loading && dischargedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nobody discharged yet today.</div>
        )}
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.surgical_cases?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Discharged Patients</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Follow-up tracking and episode closure now happen in the Post Op module.
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Discharged</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e.id)} style={{ cursor: 'pointer' }}>
                <td><strong>{e.surgical_cases?.patients?.first_name} {e.surgical_cases?.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.surgical_cases?.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{e.surgical_cases?.procedure_name} ({e.surgical_cases?.eye})</td>
                <td style={{ fontSize: 11 }}>{e.discharge_date ? new Date(e.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={4} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No discharged patients found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function RecoveryPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [cases, setCases] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getRecoveryCaseList()); setLoadingCases(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getRecoveryHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshHistory(); }, [refreshCases, refreshHistory]);

  function openCase(id) {
    setSelectedId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-bed" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />}
      {activeTab === 'workspace' && selectedId && <Workspace episodeId={selectedId} onBack={handleBack} onUpdate={handleUpdate} />}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}

FILEEOF_ot_recovery_page_js

echo "Files written. Run: npm run build"
