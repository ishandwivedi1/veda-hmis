#!/usr/bin/env bash
# Fixes 'Send for Biometry' in Counselling (M22): the previous version
# tried to UPDATE the patient's existing queue entry, but that entry is
# always 'Done' by the time a case reaches Counselling (doctor closes it
# on completing consultation) -- hence the 'No active queue entry found'
# error every time. This now calls send_case_to_department_queue() (see
# migration_027_send_to_queue.sql -- RUN THAT FIRST) which issues a fresh
# queue token instead. Also renames the button from Dilation back to
# Biometry per your last message -- Dilation is still available as
# sendForDilation() in actions.js if you want a button for it later.
set -euo pipefail

if [ ! -d "app/(main)/counselling" ]; then
  echo "ERROR: app/(main)/counselling not found -- run fix_counselling_module.sh first."
  exit 1
fi

echo "==> Writing updated actions.js and page.js..."
cat > "app/(main)/counselling/actions.js" << 'VEDA_EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

// This file replaces the old "Surgical Coordination" module's actions file.
// The following exports
// are used by OTHER modules and MUST keep the same name + signature:
//   getSurgicalCases, getSurgeons, scheduleOT, getOTSchedule, completeOT
//     -- imported by app/(main)/ot-schedule/page.js
//   markForSurgery
//     -- imported by app/(main)/consultation/[id]/consultation-form.js
// Everything else below is new/rebuilt for the Counselling workflow.

// ── Sending a patient to an ancillary service (Biometry, Dilation, ...)
//    from Counselling. Once a doctor completes a consultation, ALL of
//    that visit's queue_entries get marked 'Done' -- so by the time a
//    case reaches Counselling (even same-day), there's nothing left to
//    "update". send_case_to_department_queue() (see migration 027)
//    issues a FRESH queue token against the patient's still-open visit
//    (found via ist_date(), so it's IST-correct rather than doing UTC
//    date math here) and flips it straight to the target status.
async function sendCaseToQueueStatus(caseId, queueStatus, auditMessage) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: queueStatus,
    p_audit_message: auditMessage,
    p_user_id: userData?.user?.id || null,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForBiometry(caseId) {
  return sendCaseToQueueStatus(caseId, 'Awaiting Biometry', 'Sent for Biometry (from Counselling)');
}

export async function sendForDilation(caseId) {
  return sendCaseToQueueStatus(caseId, 'Awaiting Dilation', 'Sent for Dilation (from Counselling)');
}

// ── Case creation (called from Consultation when doctor recommends surgery) ──
export async function markForSurgery(patientId, encounterId, procedureName, eye) {
  const supabase = await createClient();

  // Pull surgeon + visit + priority through so the case doesn't start
  // with everything null -- encounters already carries doctor_id.
  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: procedureName,
    eye,
    priority,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Cases list (used by OT Scheduling -- keep shape unchanged) ──
export async function getSurgicalCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients(first_name, last_name, uhid), master_packages(name, price)')
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

// ── Cases list for the Counselling workspace (richer -- surgeon, decision, IOL type) ──
export async function getCounsellingCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, fitness_cleared, investigations_complete,
      package_id, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

// ── Packages, filtered by the IOL type advised at Biometry ──
// iol_category/origin live on master_packages (Master Data, M29). A package
// with iol_category = NULL is not IOL-specific (e.g. Glaucoma surgery) and
// is shown regardless of what was advised. Filtered in JS rather than a
// PostgREST .or() filter to avoid escaping issues with values like
// "Monofocal Toric" that contain a space.
export async function getPackagesForCase(iolCategory) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return (data || []).filter((p) => !p.iol_category || p.iol_category === iolCategory);
}

// ── Package selection (BR-SCC-002: only after Biometry & IOL advice) ──
export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('biometry_done').eq('id', caseId).single();
  if (!sc?.biometry_done) {
    return { error: 'BR-SCC-002: Biometry & IOL type advice must be complete before selecting a package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function changePackage(caseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ package_id: null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Patient decision ──
const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

export async function setDecision(caseId, decision, reason) {
  if (!DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ decision, decision_reason: reason || null }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Counselling notes log ──
export async function getCaseNotes(caseId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_case_notes')
    .select('id, note, created_at, profiles:created_by ( id, full_name )')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function addCaseNote(caseId, note) {
  if (!note || !note.trim()) return { error: 'Note cannot be empty.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: note.trim(),
    created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Patient education topics (populated by the doctor's plan, M17/M19) ──
export async function getCounsellingItems(encounterId) {
  if (!encounterId) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_counselling_items')
    .select('id, topic, status')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: true });
  if (error) return [];
  return data;
}

export async function toggleCounsellingItem(itemId, done) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').update({ status: done ? 'Done' : 'Pending' }).eq('id', itemId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Post-decision checklist (BR-SCC-004: only after package + Accepted) ──
async function requirePostDecision(supabase, caseId) {
  const { data: sc } = await supabase.from('surgical_cases').select('package_id, decision').eq('id', caseId).single();
  if (!(sc?.package_id && sc.decision === 'Accepted')) {
    return 'BR-SCC-004: Package must be confirmed and the patient decision must be Accepted first.';
  }
  return null;
}

export async function markInvestigationsComplete(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ investigations_complete: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFitnessCleared(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Ready for Scheduling ──
// NOTE: this intentionally does NOT require consent_taken. Per BR-SCC-005,
// consent is taken day-of-surgery (day-care model), not a pre-scheduling
// gate here -- that belongs to the Intraoperative module (M25). This is a
// behavior change from the previous version of this function, which did
// require consent_taken.
export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  if (!sc.biometry_done) return { error: 'VAL-SCC-002: Biometry & IOL type advice must be complete.' };
  if (!sc.package_id) return { error: 'VAL-SCC-002: Select a package first.' };
  if (sc.decision !== 'Accepted') return { error: 'VAL-SCC-002: Patient decision must be Accepted.' };
  if (!sc.investigations_complete) return { error: 'VAL-SCC-002: Investigations must be complete.' };
  if (!sc.fitness_cleared) return { error: 'VAL-SCC-002: Medical fitness must be cleared.' };

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function referBackToDoctor(caseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ status: 'Pending Workup' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Surgeons (used by OT Scheduling -- keep shape unchanged) ──
export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').ilike('designation', '%ophthalmologist%').eq('status', 'Active');
  return data || [];
}

// ── OT Scheduling (used by app/(main)/ot-schedule/page.js -- keep unchanged) ──
export async function scheduleOT(caseId, surgeonId, date, time, notes) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: surgeonId || null, scheduled_date: date, scheduled_time: time || null, notes,
  });
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles(full_name)')
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data;
}

export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}
VEDA_EOF
echo "  wrote app/(main)/counselling/actions.js"

cat > "app/(main)/counselling/page.js" << 'VEDA_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getCounsellingCases, getPackagesForCase, selectPackage, changePackage,
  setDecision, getCaseNotes, addCaseNote, getCounsellingItems, toggleCounsellingItem,
  markInvestigationsComplete, markFitnessCleared, markReadyForScheduling, referBackToDoctor,
  sendForBiometry,
} from './actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function readiness(sc) {
  const items = [
    { key: 'surgeryRec', label: 'Surgery Recommended', done: true },
    { key: 'biometry', label: 'Biometry & IOL Type Advised (M23)', done: sc.biometry_done },
    { key: 'investigations', label: 'Investigations complete', done: sc.investigations_complete },
    { key: 'fitness', label: 'Medical Fitness', done: sc.fitness_cleared },
    { key: 'advance', label: 'Advance Payment', done: !!sc.advance_payment_id },
  ];
  const done = items.filter((i) => i.done).length;
  return { items, pct: Math.round((done / items.length) * 100) };
}

function PackagePicker({ sc, onUpdate }) {
  const [packages, setPackages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!sc.biometry_done) { setLoading(false); return; }
    getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoading(false); });
  }, [sc.biometry_done, sc.iol_category]);

  if (!sc.biometry_done) {
    return (
      <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 12.5, background: 'var(--g50)', borderRadius: 'var(--r)' }}>
        <i className="ti ti-lock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }}></i>
        Complete Biometry &amp; IOL type advice (M23) before presenting packages.
      </div>
    );
  }

  if (sc.master_packages) {
    return (
      <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{sc.master_packages.name}</div>
          <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 14 }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</div>
        </div>
        <button
          className="btn btn-sm"
          style={{ marginTop: 8 }}
          onClick={async () => { await changePackage(sc.id); onUpdate(); }}
        >
          Change package
        </button>
      </div>
    );
  }

  if (loading) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
        Showing packages for IOL type: <strong>{sc.iol_category}</strong> (from Master Data)
      </div>
      {packages.length === 0 && (
        <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)' }}>
          No packages found for IOL type "{sc.iol_category}" in Master Data. Add one under Financial Masters &gt; Packages.
        </div>
      )}
      {packages.map((p) => (
        <button
          key={p.id}
          onClick={async () => {
            setError('');
            const result = await selectPackage(sc.id, p.id);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
          style={{ display: 'block', width: '100%', textAlign: 'left', border: '1.5px solid var(--g200)', borderRadius: 'var(--r)', padding: 12, marginBottom: 8, background: '#fff', cursor: 'pointer', fontFamily: 'inherit' }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
              {p.name}
              {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{p.origin}</span>}
            </div>
            <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(p.price).toLocaleString('en-IN')}</div>
          </div>
          {p.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{p.includes}</div>}
        </button>
      ))}
    </div>
  );
}

function EducationPanel({ encounterId }) {
  const [items, setItems] = useState([]);

  const refresh = useCallback(() => {
    getCounsellingItems(encounterId).then(setItems);
  }, [encounterId]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-book" style={{ color: 'var(--teal)' }}></i> Patient education</div></div>
      {items.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No education topics logged from the doctor's plan.</div>}
      {items.map((item) => (
        <button
          key={item.id}
          onClick={async () => { await toggleCounsellingItem(item.id, item.status !== 'Done'); refresh(); }}
          style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', padding: '6px 4px', background: 'none', border: 'none', cursor: 'pointer', fontFamily: 'inherit', fontSize: 12.5 }}
        >
          <span style={{
            width: 16, height: 16, borderRadius: 4, border: '1.5px solid var(--g300)',
            background: item.status === 'Done' ? 'var(--teal)' : '#fff', borderColor: item.status === 'Done' ? 'var(--teal)' : 'var(--g300)',
            color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, flexShrink: 0,
          }}>
            {item.status === 'Done' ? '✓' : ''}
          </span>
          {item.topic}
        </button>
      ))}
    </div>
  );
}

function NotesPanel({ caseId }) {
  const [notes, setNotes] = useState([]);
  const [text, setText] = useState('');

  const refresh = useCallback(() => { getCaseNotes(caseId).then(setNotes); }, [caseId]);
  useEffect(() => { refresh(); }, [refresh]);

  async function handleSave() {
    if (!text.trim()) return;
    await addCaseNote(caseId, text);
    setText('');
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Counselling notes</div></div>
      <textarea className="fi" rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="e.g. Patient wants surgery after 1 week..." />
      <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSave}>Save note</button>
      <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
        {notes.map((n) => (
          <div key={n.id} style={{ fontSize: 11, background: 'var(--g50)', borderRadius: 'var(--r)', padding: '6px 8px' }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN')} -- {n.profiles?.full_name || 'Staff'}: </span>
            {n.note}
          </div>
        ))}
      </div>
    </div>
  );
}

function CaseWorkspace({ sc, onUpdate }) {
  const [error, setError] = useState('');
  const [ancillaryMsg, setAncillaryMsg] = useState(null); // { type: 'error'|'success', text }
  const [sendingBiometry, setSendingBiometry] = useState(false);
  const { items, pct } = readiness(sc);
  const stage2Unlocked = !!sc.package_id && sc.decision === 'Accepted';

  async function handleDecision(d) {
    setError('');
    const result = await setDecision(sc.id, d, null);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleSendForBiometry() {
    setAncillaryMsg(null);
    setSendingBiometry(true);
    const result = await sendForBiometry(sc.id);
    setSendingBiometry(false);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    setAncillaryMsg({ type: 'success', text: 'Sent -- patient will show as Awaiting Biometry in the Biometry queue.' });
    onUpdate();
  }

  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-head">
        <div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>
            {sc.patients?.first_name} {sc.patients?.last_name} -- {sc.patients?.uhid}
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>
            {sc.procedure_name} -- {sc.eye} -- {sc.priority} -- {sc.profiles?.full_name || 'Unassigned surgeon'}
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 10, color: 'var(--g400)' }}>IOL Type Advised</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc.iol_category || 'Pending biometry'}</div>
          <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`} style={{ marginTop: 4 }}>{sc.status}</span>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {/* Ancillary services -- same-day queue routing, independent of the checklist below */}
      <div style={{ marginBottom: 16, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry}>
          <i className="ti ti-ruler-measure"></i> {sendingBiometry ? 'Sending...' : 'Send for Biometry'}
        </button>
        {ancillaryMsg && (
          <span style={{ fontSize: 11.5, color: ancillaryMsg.type === 'error' ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>
            {ancillaryMsg.text}
          </span>
        )}
      </div>

      {/* Package selection */}
      <div style={{ marginBottom: 16 }}>
        <label className="flbl">Package (Step 2 -- Counselling decision)</label>
        <PackagePicker sc={sc} onUpdate={onUpdate} />
      </div>

      {/* Checklist */}
      <div style={{ marginBottom: 16 }}>
        <div className="card-head" style={{ marginBottom: 8 }}>
          <label className="flbl" style={{ marginBottom: 0 }}>Surgical Readiness Checklist</label>
          <span className="badge b-purple">{pct}%</span>
        </div>
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {items.map((item) => {
            const locked = (item.key === 'investigations' || item.key === 'fitness') && !stage2Unlocked;
            return (
              <div key={item.key} style={{
                display: 'flex', alignItems: 'center', gap: 8, padding: '7px 10px', borderRadius: 'var(--r)', fontSize: 12,
                background: item.done ? 'var(--green-lt)' : locked ? 'var(--g50)' : 'var(--amber-lt)',
                opacity: locked ? 0.65 : 1,
              }}>
                <span style={{
                  width: 18, height: 18, borderRadius: 999, display: 'flex', alignItems: 'center', justifyContent: 'center',
                  fontSize: 10, color: '#fff', background: item.done ? 'var(--green)' : 'var(--amber)', flexShrink: 0,
                }}>{item.done ? '✓' : '…'}</span>
                <span style={{ flex: 1, fontWeight: 600 }}>{item.label}</span>
                {item.key === 'investigations' && !item.done && !locked && (
                  <button className="btn btn-sm" onClick={async () => { setError(''); const r = await markInvestigationsComplete(sc.id); if (r.error) setError(r.error); else onUpdate(); }}>Mark done</button>
                )}
                {item.key === 'fitness' && !item.done && !locked && (
                  <button className="btn btn-sm" onClick={async () => { setError(''); const r = await markFitnessCleared(sc.id); if (r.error) setError(r.error); else onUpdate(); }}>Mark done</button>
                )}
                {locked && <span style={{ fontSize: 10, color: 'var(--g400)' }}>Locked</span>}
              </div>
            );
          })}
        </div>
      </div>

      {/* Decision */}
      <div style={{ marginBottom: 16 }}>
        <label className="flbl">Patient decision</label>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
          {DECISIONS.map((d) => (
            <button
              key={d}
              onClick={() => handleDecision(d)}
              className="btn btn-sm"
              style={sc.decision === d ? {
                background: d === 'Accepted' ? 'var(--green)' : d === 'Declined' ? 'var(--red)' : 'var(--purple)',
                color: '#fff', borderColor: 'transparent',
              } : {}}
            >
              {d}
            </button>
          ))}
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <EducationPanel encounterId={sc.encounter_id} />
        <NotesPanel caseId={sc.id} />
      </div>

      <div style={{ display: 'flex', gap: 8 }}>
        <button
          className="btn btn-sm"
          onClick={async () => { await referBackToDoctor(sc.id); onUpdate(); }}
        >
          Refer back to doctor
        </button>
        {sc.status === 'Pending Workup' && (
          <button className="btn btn-primary btn-sm" onClick={handleReady}>Ready for Scheduling (VAL-SCC-002)</button>
        )}
        {sc.status === 'Ready for Scheduling' && (
          <div className="msg-success" style={{ margin: 0 }}>
            <i className="ti ti-circle-check"></i> Ready -- go to OT Scheduling to book a date.
          </div>
        )}
      </div>
    </div>
  );
}

// ── Pre-op counselling stage, derived from real columns (not stored --
//    surgical_cases.status stays limited to Pending Workup / Ready for
//    Scheduling / Scheduled / Completed / Cancelled, since OT Scheduling
//    relies on those exact values). This just groups cases for the
//    dashboard so the counsellor can see where each patient actually is. ──
const STAGES = [
  { key: 'awaiting_biometry',   label: 'Awaiting Biometry',              badge: 'b-gray'   },
  { key: 'awaiting_package',    label: 'Awaiting Package Presentation',  badge: 'b-blue'   },
  { key: 'awaiting_decision',   label: 'Waiting for Patient Decision',   badge: 'b-amber'  },
  { key: 'financial_constraint',label: 'Financial Constraint',           badge: 'b-red'    },
  { key: 'finalised',           label: 'Finalised -- Prep Pending',      badge: 'b-purple' },
  { key: 'ready',               label: 'Ready for Scheduling',           badge: 'b-green'  },
  { key: 'declined',            label: 'Declined',                       badge: 'b-gray'   },
];
const STAGE_MAP = Object.fromEntries(STAGES.map((s) => [s.key, s]));

function getStage(sc) {
  if (sc.status === 'Ready for Scheduling') return 'ready';
  if (!sc.biometry_done) return 'awaiting_biometry';
  if (!sc.package_id) return 'awaiting_package';
  if (sc.decision === 'Declined') return 'declined';
  if (sc.decision === 'Financial Constraint') return 'financial_constraint';
  if (sc.decision === 'Accepted') return 'finalised';
  return 'awaiting_decision'; // null, Wants Time to Decide, Discuss with Family, Second Opinion, Other
}

function daysWaiting(sc) {
  return Math.floor((Date.now() - new Date(sc.created_at).getTime()) / 86400000);
}

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

function CounsellingDashboard({ cases, onOpen }) {
  const [stageFilter, setStageFilter] = useState('');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  const counts = STAGES.reduce((acc, s) => { acc[s.key] = 0; return acc; }, {});
  cases.forEach((sc) => { counts[getStage(sc)]++; });

  let rows = cases.map((sc) => ({ sc, stage: getStage(sc) }));
  if (stageFilter) rows = rows.filter((r) => r.stage === stageFilter);
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter(({ sc }) =>
      `${sc.patients?.first_name} ${sc.patients?.last_name}`.toLowerCase().includes(q) ||
      (sc.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  rows.sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.sc.created_at) - new Date(b.sc.created_at);
    if (sortBy === 'newest') return new Date(b.sc.created_at) - new Date(a.sc.created_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.sc.priority] ?? 9) - (order[b.sc.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
        <KpiCard label="Active cases" value={cases.filter((sc) => sc.status !== 'Ready for Scheduling').length + counts.ready} sub="All pre-op stages" color="var(--indigo)" active={!stageFilter} onClick={() => setStageFilter('')} />
        <KpiCard label="Waiting on patient" value={counts.awaiting_decision + counts.financial_constraint} sub="Decision or finance pending" color="var(--amber)" active={stageFilter === 'awaiting_decision'} onClick={() => setStageFilter('awaiting_decision')} />
        <KpiCard label="Finalised -- prep pending" value={counts.finalised} sub="Accepted, tests/fitness pending" color="var(--purple)" active={stageFilter === 'finalised'} onClick={() => setStageFilter('finalised')} />
        <KpiCard label="Ready for scheduling" value={counts.ready} sub="Go to OT Scheduling" color="var(--green)" active={stageFilter === 'ready'} onClick={() => setStageFilter('ready')} />
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Counselling Queue</div>
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
          <button className={`btn btn-sm ${!stageFilter ? 'btn-primary' : ''}`} onClick={() => setStageFilter('')}>All ({cases.length})</button>
          {STAGES.map((s) => (
            <button key={s.key} className={`btn btn-sm ${stageFilter === s.key ? 'btn-primary' : ''}`} onClick={() => setStageFilter(s.key)}>
              {s.label} ({counts[s.key]})
            </button>
          ))}
        </div>

        {rows.map(({ sc, stage }) => {
          const dw = daysWaiting(sc);
          return (
            <div key={sc.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--purple)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {sc.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</span>
                <span className={`badge ${STAGE_MAP[stage].badge}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_MAP[stage].label}</span>
                {sc.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{sc.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.iol_category || 'IOL type pending'} -- {sc.profiles?.full_name || 'Unassigned surgeon'}
                </div>
              </div>
              <div style={{ textAlign: 'right', fontSize: 10, color: dw > 7 ? 'var(--red)' : dw > 3 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                {dw === 0 ? 'Today' : `${dw}d waiting`}
              </div>
              <button className="btn btn-sm btn-primary" onClick={() => onOpen(sc.id)}>
                <i className="ti ti-arrow-right"></i> Open
              </button>
            </div>
          );
        })}

        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {cases.length === 0 ? 'No cases pending counselling. Mark a patient for surgery from their Consultation.' : 'No cases match this filter.'}
          </div>
        )}
      </div>
    </div>
  );
}

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

export default function CounsellingPage() {
  const [cases, setCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);

  const refresh = useCallback(async () => {
    setCases(await getCounsellingCases());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function openCase(id) {
    setSelectedCaseId(id);
    setActiveTab('workspace');
  }

  const selectedCase = cases.find((sc) => sc.id === selectedCaseId) || null;

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading counselling cases...</div>;

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 420 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-messages" label="Workspace" disabled={!selectedCase} />
      </div>

      {activeTab === 'dashboard' && <CounsellingDashboard cases={cases} onOpen={openCase} />}

      {activeTab === 'workspace' && selectedCase && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => setActiveTab('dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Dashboard
          </button>
          <CaseWorkspace sc={selectedCase} onUpdate={refresh} />
        </div>
      )}

      {activeTab === 'workspace' && !selectedCase && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Dashboard tab.
        </div>
      )}
    </div>
  );
}
VEDA_EOF
echo "  wrote app/(main)/counselling/page.js"

echo ""
echo "==> IMPORTANT: this only works if migration_027_send_to_queue.sql has"
echo "    already been run in Supabase SQL Editor -- it depends on the new"
echo "    send_case_to_department_queue() function."
echo ""
echo "==> Next steps:"
echo "  1. npm run build"
echo "  2. git add -A && git commit -m \"Counselling: fix Send for Biometry to issue a fresh queue token\" && git push"
