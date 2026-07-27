#!/bin/bash
set -e
echo "Applying: Post-op Turned Up Today widget + read-only pending-review list"

cat > "app/(main)/ot-postop/actions.js" << 'PYEOF_4341267772134837539'
'use server';

import { createClient } from '@/lib/supabase-server';

// Used by Doctor Dashboard: a Post-operative Review visit routes here
// instead of the normal Consultation form -- find the patient's most
// recent still-open episode (discharged, not yet closed).
export async function getOpenPostOpEpisodeForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('recovery_episodes')
    .select('id, surgical_case_id')
    .is('closure_status', null)
    .not('discharge_date', 'is', null)
    .order('created_at', { ascending: false });
  if (!data || data.length === 0) return null;

  const caseIds = data.map((e) => e.surgical_case_id);
  const { data: cases } = await supabase.from('surgical_cases').select('id, patient_id').in('id', caseIds).eq('patient_id', patientId);
  if (!cases || cases.length === 0) return null;

  const match = data.find((e) => cases.some((c) => c.id === e.surgical_case_id));
  return match?.id || null;
}

// ── DASHBOARD: discharged episodes not yet closed ──
export async function getPostOpCaseList() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('discharge_date', 'is', null)
    .is('closure_status', null)
    .order('discharge_date', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── DASHBOARD (Turned Up Today): same open-episode pool as above, but
//    narrowed to patients who actually have an Open visit today -- i.e.
//    they've genuinely checked in for their review, not just due for
//    one. This is the only list that should open in an editable
//    workspace; the general "pending reviews" list above is read-only
//    since nothing there confirms the patient is actually present. ──
export async function getPostOpTurnedUpToday() {
  const supabase = await createClient();
  const { data: ids, error: idsError } = await supabase.rpc('get_postop_checked_in_today');
  if (idsError || !ids || ids.length === 0) return [];

  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .in('id', ids.map((r) => r.episode_id))
    .order('discharge_date', { ascending: true });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── HISTORY: closed episodes ──
export async function getPostOpHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid), profiles:surgeon_id(full_name))')
    .not('closure_status', 'is', null)
    .order('closed_at', { ascending: false });
  if (error) return [];
  return (data || []).filter((e) => e.surgical_cases);
}

// ── FULL EPISODE DETAIL (post-op focus: milestones, followups, complications) ──
export async function getPostOpEpisodeDetail(episodeId) {
  const supabase = await createClient();
  const { data: episode, error } = await supabase
    .from('recovery_episodes')
    .select('*, surgical_cases(procedure_name, eye, patients:patient_id(id, first_name, last_name, uhid, age, gender), profiles:surgeon_id(full_name))')
    .eq('id', episodeId)
    .single();
  if (error) return { error: error.message };

  const [{ data: followups }, { data: complications }] = await Promise.all([
    supabase.from('recovery_followups').select('*').eq('recovery_episode_id', episodeId).order('scheduled_date'),
    supabase.from('recovery_complications').select('*').eq('recovery_episode_id', episodeId).order('occurred_at'),
  ]);

  return { episode, sc: episode.surgical_cases, followups: followups || [], complications: complications || [] };
}

// ── ADD / REMOVE a review from the schedule -- requirements can change
//    after discharge (e.g. an unplanned complication needs an extra
//    check, or a review turns out unnecessary). Removal is blocked once
//    a review has an actual clinical visit tied to it (encounter already
//    started), so a real record never gets silently orphaned. ──
export async function addFollowup(episodeId, visitLabel, scheduledDate) {
  const supabase = await createClient();
  if (!visitLabel?.trim()) return { error: 'A label for the review is required.' };
  if (!scheduledDate) return { error: 'A date is required.' };
  const { error } = await supabase.from('recovery_followups').insert({
    recovery_episode_id: episodeId, visit_label: visitLabel.trim(), scheduled_date: scheduledDate,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeFollowup(followupId) {
  const supabase = await createClient();
  const { data: followup } = await supabase.from('recovery_followups').select('visit_id, status').eq('id', followupId).single();
  if (followup?.visit_id) {
    return { error: 'This review already has a visit recorded against it and cannot be removed -- reschedule it instead if it needs to move.' };
  }
  const { error } = await supabase.from('recovery_followups').delete().eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── RESCHEDULE / NOTES on a follow-up visit ──
export async function rescheduleFollowup(followupId, newDate, notes) {
  const supabase = await createClient();
  if (!newDate) return { error: 'A new date is required.' };
  const { data: existing } = await supabase.from('recovery_followups').select('rescheduled_count').eq('id', followupId).single();
  const { error } = await supabase.from('recovery_followups').update({
    scheduled_date: newDate, notes: notes?.trim() || null,
    rescheduled_count: (existing?.rescheduled_count || 0) + 1,
  }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// For adding/editing notes without necessarily changing the date.
export async function saveFollowupNotes(followupId, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('recovery_followups').update({ notes: notes?.trim() || null }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFollowupStatus(followupId, status) {
  const supabase = await createClient();

  if (status === 'Completed') {
    const { data: followup } = await supabase.from('recovery_followups').select('scheduled_date').eq('id', followupId).single();
    const today = new Date().toISOString().slice(0, 10);
    if (followup && followup.scheduled_date > today) {
      return { error: `This visit is scheduled for ${followup.scheduled_date}, which hasn't happened yet -- it can't be marked Completed in advance.` };
    }
  }

  const { error } = await supabase.from('recovery_followups').update({ status }).eq('id', followupId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PATIENT REVIEW -- reuses the real Consultation screen ──
// Post-op patients now queue through Optometry like anyone else
// (refraction/clinical recording may be needed post-surgery too), with
// the exception of the surgery-day visit itself. Clicking "Start Review"
// here is the doctor's "Call Directly" override -- same mechanism as the
// "Waiting in Optometry" list on Doctor Dashboard: it completes the
// patient's Optometry entry (issuing them a Doctor token) if they
// haven't been seen yet, or just reuses the Doctor entry if Optometry
// already finished. get_or_create_postop_review_visit() reuses the
// patient's visit for today if one already exists (front desk check-in,
// or an earlier follow-up already opened today) instead of failing on
// the one-visit-per-day rule. The resulting queueEntryId is handed
// straight to <ConsultationForm queueEntryId hideHistoryTracker /> --
// the exact same screen as a normal consultation, just without History
// and Action Tracker. Reopening the same follow-up later reuses the same
// visit instead of creating a new one each time.
export async function openFollowupReview(followupId) {
  const supabase = await createClient();
  const { data: followup, error } = await supabase
    .from('recovery_followups')
    .select('*, recovery_episodes(surgical_case_id, surgical_cases(patient_id, surgeon_id))')
    .eq('id', followupId)
    .single();
  if (error) return { error: error.message };

  let visitId = followup.visit_id;

  if (!visitId) {
    const sc = followup.recovery_episodes?.surgical_cases;
    if (!sc) return { error: 'Could not find the surgical case for this follow-up.' };

    const { data: visit, error: visitError } = await supabase.rpc('get_or_create_postop_review_visit', {
      p_patient_id: sc.patient_id,
      p_doctor_id: sc.surgeon_id,
    });
    if (visitError) return { error: visitError.message };
    visitId = visit.id;

    const { error: linkError } = await supabase.from('recovery_followups').update({ visit_id: visitId }).eq('id', followupId);
    if (linkError) return { error: linkError.message };
  }

  // Already routed to Doctor (either Optometry finished normally, or
  // this follow-up's review was already opened before)?
  let { data: queueEntry } = await supabase
    .from('queue_entries')
    .select('id')
    .eq('visit_id', visitId)
    .eq('department', 'Doctor')
    .order('issued_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!queueEntry) {
    // Still waiting in Optometry -- pull them straight in, same as
    // "Call Directly" on Doctor Dashboard.
    const { data: optEntry } = await supabase
      .from('queue_entries')
      .select('id')
      .eq('visit_id', visitId)
      .eq('department', 'Optometry')
      .order('issued_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (optEntry) {
      const { error: rpcError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: optEntry.id });
      if (rpcError) return { error: rpcError.message };
      const { data: routedEntry } = await supabase
        .from('queue_entries')
        .select('id')
        .eq('visit_id', visitId)
        .eq('department', 'Doctor')
        .order('issued_at', { ascending: false })
        .limit(1)
        .maybeSingle();
      queueEntry = routedEntry;
    }
  }

  if (!queueEntry) {
    const { data: newEntry, error: tokenError } = await supabase.rpc('issue_queue_token', { p_visit_id: visitId, p_department: 'Doctor' });
    if (tokenError) return { error: tokenError.message };
    queueEntry = newEntry;
  }

  return { queueEntryId: queueEntry.id };
}

// ── POST-OP COMPLICATIONS ──
export async function addRecoveryComplication(episodeId, values) {
  const supabase = await createClient();
  if (!values.name?.trim()) return { error: 'Complication name is required.' };
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_complications').insert({
    recovery_episode_id: episodeId, name: values.name.trim(), severity: values.severity,
    management: values.management?.trim() || null, outcome: values.outcome?.trim() || null,
    added_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── CLOSE EPISODE ──
export async function closeEpisode(episodeId, values) {
  const supabase = await createClient();
  if (!values.outcome) return { error: 'VAL-POST-005: Overall clinical outcome is required.' };

  const { data: complications } = await supabase.from('recovery_complications').select('management').eq('recovery_episode_id', episodeId);
  const unmanaged = (complications || []).filter((c) => !c.management);
  if (unmanaged.length > 0) return { error: 'VAL-POST-004: Unmanaged complications exist -- episode cannot close.' };

  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('recovery_episodes').update({
    closure_status: values.status, closure_outcome: values.outcome, closure_remarks: values.remarks || null,
    closed_by: userData?.user?.id || null, closed_at: new Date().toISOString(),
  }).eq('id', episodeId);
  if (error) return { error: error.message };
  return { success: true };
}

PYEOF_4341267772134837539

cat > "app/(main)/ot-postop/page.js" << 'PYEOF_1593075443080446380'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPostOpCaseList, getPostOpTurnedUpToday, getPostOpHistory } from './actions';
import Workspace from './workspace';

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--purple)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function daysWaiting(dischargeDate) {
  if (!dischargeDate) return 0;
  return Math.floor((new Date() - new Date(`${dischargeDate}T00:00:00`)) / (1000 * 60 * 60 * 24));
}

function PatientRow({ c, onClick, accentColor, rightLabel, actionLabel, actionIcon }) {
  const sc = c.surgical_cases;
  const patient = sc.patients;
  return (
    <div onClick={onClick} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }}>
      <div style={{ width: 34, height: 34, borderRadius: '50%', background: accentColor, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
        {patient?.first_name?.charAt(0)}
      </div>
      <div style={{ flex: 1 }}>
        <span style={{ fontWeight: 700, fontSize: 13 }}>{patient?.first_name} {patient?.last_name}</span>
        <span className="badge b-purple" style={{ marginLeft: 8, fontSize: 10 }}>Post-op</span>
        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
          {patient?.uhid} -- {sc.procedure_name} -- {sc.eye} -- {sc.profiles?.full_name || 'No surgeon'}
        </div>
      </div>
      <div style={{ fontSize: 10, color: 'var(--g400)', width: 90, textAlign: 'right' }}>{rightLabel}</div>
      <button className="btn btn-sm btn-primary" style={accentColor === 'var(--green)' ? { background: 'var(--green)', borderColor: 'transparent' } : undefined}>
        <i className={`ti ${actionIcon}`}></i> {actionLabel}
      </button>
    </div>
  );
}

function TurnedUpTodayTab({ cases, loading, onOpen }) {
  return (
    <div className="card" style={{ marginBottom: 16, border: '1.5px solid var(--green)' }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-user-check" style={{ color: 'var(--green)' }}></i> Turned Up Today for Review
        <span className="badge b-green" style={{ marginLeft: 8 }}>{cases.length}</span>
      </div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Only patients with an actual visit today -- opens in the full workspace so you can start the review.
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
      {!loading && cases.map((c) => (
        <PatientRow
          key={c.id}
          c={c}
          onClick={() => onOpen(c.id, false)}
          accentColor="var(--green)"
          rightLabel="Checked in today"
          actionLabel="Start Review"
          actionIcon="ti-clipboard-text"
        />
      ))}
      {!loading && cases.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20, fontSize: 12.5 }}>No post-op patients have checked in yet today.</div>
      )}
    </div>
  );
}

function DashboardTab({ cases, loading, onOpen }) {
  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(1, 1fr)', gap: 10, marginBottom: 14, maxWidth: 260 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 4 }}>Open post-op episodes</div>
          <div style={{ fontSize: 20, fontWeight: 700 }}>{cases.length}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 2 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Patients Pending Review (Not Yet Checked In)</div>
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
          Read-only -- opens for viewing only. Use "Turned Up Today" above to actually start a review.
        </div>
        {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}
        {!loading && cases.map((c) => (
          <PatientRow
            key={c.id}
            c={c}
            onClick={() => onOpen(c.id, true)}
            accentColor="var(--purple)"
            rightLabel={`${daysWaiting(c.discharge_date)}d since discharge`}
            actionLabel="View"
            actionIcon="ti-eye"
          />
        ))}
        {!loading && cases.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No open post-op episodes.</div>
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
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Closed Episodes</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Status</th><th>Outcome</th><th>Closed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e.id, true)} style={{ cursor: 'pointer' }}>
                <td><strong>{e.surgical_cases?.patients?.first_name} {e.surgical_cases?.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.surgical_cases?.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{e.surgical_cases?.procedure_name} ({e.surgical_cases?.eye})</td>
                <td><span className="badge b-purple" style={{ fontSize: 10 }}>{e.closure_status}</span></td>
                <td style={{ fontSize: 12 }}>{e.closure_outcome}</td>
                <td style={{ fontSize: 11 }}>{e.closed_at ? new Date(e.closed_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={6} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No closed episodes yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function PostOpPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [workspaceReadOnly, setWorkspaceReadOnly] = useState(false);
  const [cases, setCases] = useState([]);
  const [turnedUpToday, setTurnedUpToday] = useState([]);
  const [history, setHistory] = useState([]);
  const [loadingCases, setLoadingCases] = useState(true);
  const [loadingTurnedUp, setLoadingTurnedUp] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);

  const refreshCases = useCallback(async () => { setCases(await getPostOpCaseList()); setLoadingCases(false); }, []);
  const refreshTurnedUp = useCallback(async () => { setTurnedUpToday(await getPostOpTurnedUpToday()); setLoadingTurnedUp(false); }, []);
  const refreshHistory = useCallback(async () => { setHistory(await getPostOpHistory()); setLoadingHistory(false); }, []);

  useEffect(() => { refreshCases(); refreshTurnedUp(); refreshHistory(); }, [refreshCases, refreshTurnedUp, refreshHistory]);

  function openCase(id, readOnly) {
    setSelectedId(id);
    setWorkspaceReadOnly(!!readOnly);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
  }

  function handleBack() {
    refreshCases(); refreshTurnedUp(); refreshHistory();
    setSelectedId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 400 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-list" label="Workspace" disabled={!selectedId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && (
        <>
          <TurnedUpTodayTab cases={turnedUpToday} loading={loadingTurnedUp} onOpen={openCase} />
          <DashboardTab cases={cases} loading={loadingCases} onOpen={openCase} />
        </>
      )}
      {activeTab === 'workspace' && selectedId && (
        <Workspace episodeId={selectedId} readOnly={workspaceReadOnly} onBack={handleBack} onUpdate={handleUpdate} />
      )}
      {activeTab === 'workspace' && !selectedId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard.</div>
      )}
      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}
PYEOF_1593075443080446380

cat > "app/(main)/ot-postop/workspace.js" << 'PYEOF_6040051926194884482'
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
          <i className="ti ti-eye"></i> Read-only view -- this patient doesn't have a visit today. Open them from "Turned Up Today" on the Dashboard once they've checked in to start a review.
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

              {!isClosed && !readOnly && editingFollowupId !== f.id && (
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 42 }}>
                  <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                    <i className="ti ti-clipboard-text"></i> {openingReview === f.id ? 'Opening...' : f.visit_id ? 'Open Review' : 'Start Review'}
                  </button>
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
                </div>
              )}

              {editingFollowupId === f.id && (
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

PYEOF_6040051926194884482

echo "Files written. Run: npm run build"
