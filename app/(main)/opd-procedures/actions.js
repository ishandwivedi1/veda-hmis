'use server';

import { createClient } from '@/lib/supabase-server';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

// ── CASE LISTS ──
// A plan_procedures row only enters this workflow once it's either had
// a decision recorded, or is still 'Planned' with a date genuinely in
// the future (someone coming back another day). Same-day instant
// procedures (status 'Planned'/'Done', no decision, date <= today) are
// the pre-existing Consultation/Action Tracker path and are
// deliberately left out of every bucket below -- this module never
// touches them.
async function getWorkflowCasesWithContext() {
  const supabase = await createClient();
  const today = todayIst();

  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters(id, visit_id, visits(patient_id, patients(id, first_name, last_name, uhid, mobile)))')
    .neq('status', 'Cancelled')
    .neq('status', 'Done')
    .order('created_at', { ascending: false });

  if (error) return [];

  const eligible = (data || []).filter((p) => {
    if (!p.encounters?.visits?.patients) return false;
    if (p.decision) return true;
    if (['Scheduled', 'Checked In', 'Completed'].includes(p.status)) return true;
    return p.status === 'Planned' && p.scheduled_date > today;
  });

  const patientIds = [...new Set(eligible.map((p) => p.encounters.visits.patient_id).filter(Boolean))];
  const ledgerRows = patientIds.length > 0
    ? await supabase.from('patient_ledger').select('patient_id, amount').in('patient_id', patientIds).then((r) => r.data || [])
    : [];
  const balances = {};
  ledgerRows.forEach((r) => { balances[r.patient_id] = (balances[r.patient_id] || 0) + Number(r.amount); });

  return eligible.map((p) => ({
    ...p,
    patient: p.encounters.visits.patients,
    advanceBalance: balances[p.encounters.visits.patient_id] || 0,
  }));
}

export async function getOpdProcedureLists() {
  const cases = await getWorkflowCasesWithContext();
  const today = todayIst();

  const awaitingDecision = cases
    .filter((c) => !c.decision && c.status === 'Planned')
    .sort((a, b) => new Date(a.scheduled_date) - new Date(b.scheduled_date));

  const scheduled = cases
    .filter((c) => c.decision === 'Accepted' && ['Planned', 'Scheduled'].includes(c.status))
    .sort((a, b) => new Date(a.scheduled_date) - new Date(b.scheduled_date));

  const checkedIn = cases.filter((c) => c.status === 'Checked In');

  const completedToday = cases.filter((c) => c.status === 'Completed' && c.completed_at && c.completed_at.slice(0, 10) === today);

  const followUp = cases.filter((c) => c.decision && c.decision !== 'Accepted' && c.decision !== 'Declined' && c.status === 'Planned');

  return { awaitingDecision, scheduled, checkedIn, completedToday, followUp };
}

// ── PATIENT-CENTRIC LOOKUPS ──
// Every OPD Procedure ever planned for this patient, newest first --
// including legacy same-day 'Done' ones, since this view is meant to
// be the complete picture for one patient, not just the workflow
// queue. Single-patient ledger balance attached once, used by whichever
// procedure is currently at the Scheduled stage.
export async function getPatientOpdProcedureJourney(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters!inner(id, visit_id, visits!inner(patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .order('created_at', { ascending: false });
  if (error) return [];

  const [{ data: ledgerRows }, { data: catalog }] = await Promise.all([
    supabase.from('patient_ledger').select('amount').eq('patient_id', patientId),
    supabase.from('master_services').select('name, rate, gst_pct').eq('dept', 'OPD Procedure').eq('status', 'Active'),
  ]);
  const advanceBalance = (ledgerRows || []).reduce((sum, r) => sum + Number(r.amount), 0);

  return (data || []).map((p) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === p.name.toLowerCase());
    return { ...p, advanceBalance, rate: match?.rate ?? null };
  });
}

// Quick "who's relevant today" shortcuts for the landing page, so staff
// who don't have a name handy yet aren't forced to search blind. Grouped
// by patient rather than by stage -- still patient-first, just scoped
// to today's activity. One row per patient (a patient with two
// procedures active today collapses to one entry with both listed).
export async function getTodayOpdProcedurePatients() {
  const supabase = await createClient();
  const today = todayIst();

  const { data, error } = await supabase
    .from('plan_procedures')
    .select('id, name, eye, status, scheduled_date, checked_in_at, completed_at, encounters!inner(visits!inner(patient_id, patients(id, first_name, last_name, uhid, mobile)))')
    .or(`scheduled_date.eq.${today},checked_in_at.gte.${today}T00:00:00,completed_at.gte.${today}T00:00:00`)
    .neq('status', 'Cancelled');
  if (error) return [];

  const byPatient = {};
  (data || []).forEach((p) => {
    const patient = p.encounters?.visits?.patients;
    if (!patient) return;
    if (!byPatient[patient.id]) byPatient[patient.id] = { patient, items: [] };
    byPatient[patient.id].items.push({ name: p.name, eye: p.eye, status: p.status });
  });
  return Object.values(byPatient);
}


export async function setOpdProcedureDecision(id, decision, reason) {
  if (!DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: row } = await supabase.from('plan_procedures').select('decision, decision_locked, encounter_id, name').eq('id', id).single();
  if (!row) return { error: 'Procedure not found.' };

  if (row.decision_locked && decision !== row.decision) {
    if (!reason || !reason.trim()) return { error: 'A reason is required to change a locked decision.' };
  }

  const update = {
    decision,
    decision_reason: reason || null,
    decision_locked: decision === 'Accepted',
  };
  if (decision === 'Accepted' && row.decision !== 'Accepted') {
    update.decision_accepted_at = new Date().toISOString();
  }

  const { error } = await supabase.from('plan_procedures').update(update).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure decision (${row.name}): ${decision}${reason ? ` -- ${reason}` : ''}`, userData?.user?.id);
  return { success: true };
}

// ── SCHEDULING ──
// Allowed while the case is still 'Planned' (first booking) or already
// 'Scheduled' (moving the date before check-in). Locked once checked in.
export async function scheduleOpdProcedure(id, date, time) {
  if (!date) return { error: 'A date is required.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: row } = await supabase.from('plan_procedures').select('status, decision, encounter_id, name').eq('id', id).single();
  if (!row) return { error: 'Procedure not found.' };
  if (row.decision !== 'Accepted') return { error: 'Patient decision must be Accepted before scheduling.' };
  if (!['Planned', 'Scheduled'].includes(row.status)) return { error: `Cannot schedule a case in "${row.status}" status.` };

  const { error } = await supabase.from('plan_procedures').update({ scheduled_date: date, scheduled_time: time || null, status: 'Scheduled' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure (${row.name}) scheduled for ${date}${time ? ` ${time}` : ''}`, userData?.user?.id);
  return { success: true };
}

// ── CHECK-IN ──
// Gated the same way surgery is: same scheduled day, and a live
// advance balance actually paid (patient_ledger), not a static flag.
export async function checkInOpdProcedure(id) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: row } = await supabase
    .from('plan_procedures')
    .select('status, scheduled_date, encounter_id, name, encounters(visits(patient_id))')
    .eq('id', id)
    .single();
  if (!row) return { error: 'Procedure not found.' };
  if (row.status !== 'Scheduled') return { error: `Cannot check in a case in "${row.status}" status.` };

  const today = todayIst();
  if (row.scheduled_date !== today) {
    return { error: row.scheduled_date > today ? `This procedure is scheduled for ${row.scheduled_date}, which hasn't arrived yet.` : `This procedure was scheduled for ${row.scheduled_date} and was never checked in that day -- reschedule it first.` };
  }

  const patientId = row.encounters?.visits?.patient_id;
  const { data: ledgerRows } = await supabase.from('patient_ledger').select('amount').eq('patient_id', patientId);
  const balance = (ledgerRows || []).reduce((sum, r) => sum + Number(r.amount), 0);
  if (balance <= 0) return { error: 'No advance payment on file for this patient yet. Collect the advance before check-in.' };

  const { error } = await supabase.from('plan_procedures').update({ checked_in_at: new Date().toISOString(), status: 'Checked In' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure (${row.name}) checked in`, userData?.user?.id);
  return { success: true };
}

// ── COMPLETION ──
export async function completeOpdProcedure(id, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: row } = await supabase.from('plan_procedures').select('status, encounter_id, name').eq('id', id).single();
  if (!row) return { error: 'Procedure not found.' };
  if (row.status !== 'Checked In') return { error: `Cannot complete a case in "${row.status}" status.` };

  const { error } = await supabase.from('plan_procedures').update({
    procedure_performed: fields.procedurePerformed || null,
    findings: fields.findings || null,
    post_procedure_instructions: fields.instructions || null,
    completed_at: new Date().toISOString(),
    status: 'Completed',
  }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure (${row.name}) completed`, userData?.user?.id);
  return { success: true };
}

// ── CANCEL ──
export async function cancelOpdProcedure(id, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: row } = await supabase.from('plan_procedures').select('encounter_id, name').eq('id', id).single();
  if (!row) return { error: 'Procedure not found.' };

  const { error } = await supabase.from('plan_procedures').update({ status: 'Cancelled' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure (${row.name}) cancelled${reason ? ` -- ${reason}` : ''}`, userData?.user?.id);
  return { success: true };
}

// ── COMBINED OPD PROCEDURE + OT CALENDAR ──
// Purely a read-side merge for the shared view -- doesn't touch
// ot_schedule or the Surgical Workflow tables at all.
export async function getCombinedSchedule() {
  const supabase = await createClient();
  const today = todayIst();

  const [otResult, procResult] = await Promise.all([
    supabase
      .from('ot_schedule')
      .select('id, scheduled_date, scheduled_time, status, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid))')
      .in('status', ['Scheduled', 'In Progress'])
      .gte('scheduled_date', today)
      .order('scheduled_date', { ascending: true }),
    supabase
      .from('plan_procedures')
      .select('id, name, eye, scheduled_date, scheduled_time, status, encounters(visits(patients(first_name, last_name, uhid)))')
      .in('status', ['Scheduled', 'Checked In'])
      .gte('scheduled_date', today)
      .order('scheduled_date', { ascending: true }),
  ]);

  const surgeries = (otResult.data || []).map((r) => ({
    kind: 'Surgery',
    id: r.id,
    date: r.scheduled_date,
    time: r.scheduled_time,
    status: r.status,
    name: r.surgical_cases?.procedure_name,
    eye: r.surgical_cases?.eye,
    patient: r.surgical_cases?.patients,
  }));

  const procedures = (procResult.data || []).map((r) => ({
    kind: 'Procedure',
    id: r.id,
    date: r.scheduled_date,
    time: r.scheduled_time,
    status: r.status,
    name: r.name,
    eye: r.eye,
    patient: r.encounters?.visits?.patients,
  }));

  return [...surgeries, ...procedures]
    .filter((e) => e.patient)
    .sort((a, b) => (a.date + (a.time || '')).localeCompare(b.date + (b.time || '')));
}
