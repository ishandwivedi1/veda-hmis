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

// Same classification Surgical Journey uses: whether an advance has
// actually been paid, not what stage the decision/scheduling is at --
// a patient can say yes and even take a date, then never show up with
// the money, so advance payment is the real confirmation signal.
// Completed cases move to their own section once done (today) rather
// than staying in Active Cases indefinitely.
export async function getOpdProcedureLists() {
  const cases = await getWorkflowCasesWithContext();
  const today = todayIst();

  const eligible = cases.filter((c) => c.decision !== 'Declined' && c.status !== 'Completed');
  const active = eligible.filter((c) => c.advanceBalance > 0);
  const awaitingConfirmation = eligible
    .filter((c) => c.advanceBalance <= 0)
    .sort((a, b) => new Date(a.created_at) - new Date(b.created_at));

  const completedToday = cases.filter((c) => c.status === 'Completed' && c.completed_at && c.completed_at.slice(0, 10) === today);

  return { active, awaitingConfirmation, completedToday };
}

// ── PATIENT-CENTRIC LOOKUPS ──
// Every OPD Procedure ever planned for this patient, newest first --
// including legacy same-day 'Done' ones, since this view is meant to
// be the complete picture for one patient, not just the workflow
// queue. Single-patient ledger balance attached once, used by whichever
// procedure is currently at the Scheduled stage.
export async function getPatientOpdProcedureJourney(patientId) {
  const supabase = await createClient();
  const today = todayIst();
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters!inner(id, visit_id, visits!inner(patient_id))')
    .eq('encounters.visits.patient_id', patientId)
    .order('created_at', { ascending: false });
  if (error) return [];

  const [{ data: ledgerRows }, { data: catalog }, { data: activeVisitRow }] = await Promise.all([
    supabase.from('patient_ledger').select('amount').eq('patient_id', patientId),
    supabase.from('master_services').select('name, rate, gst_pct').eq('dept', 'OPD Procedure').eq('status', 'Active'),
    supabase.from('visits').select('id').eq('patient_id', patientId).eq('status', 'Open').gte('created_at', `${today}T00:00:00`).limit(1).maybeSingle(),
  ]);
  const advanceBalance = (ledgerRows || []).reduce((sum, r) => sum + Number(r.amount), 0);
  const hasActiveVisitToday = !!activeVisitRow;

  return (data || []).map((p) => {
    const match = (catalog || []).find((s) => s.name.toLowerCase() === p.name.toLowerCase());
    return { ...p, advanceBalance, hasActiveVisitToday, rate: match?.rate ?? null };
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

// ── CALENDAR PICKER SUPPORT ──
// Day-level counts for one calendar month, so the date picker can show
// how busy a day already is -- same idea as OT Schedule's month
// summary, but far lighter: no sessions/rooms/capacity, since OPD
// Procedures don't book against theatre capacity.
export async function getOpdProcedureMonthSummary(year, month) {
  const supabase = await createClient();
  const start = `${year}-${String(month + 1).padStart(2, '0')}-01`;
  const endDate = new Date(year, month + 1, 0).getDate();
  const end = `${year}-${String(month + 1).padStart(2, '0')}-${String(endDate).padStart(2, '0')}`;

  const { data, error } = await supabase
    .from('plan_procedures')
    .select('scheduled_date')
    .in('status', ['Scheduled', 'Checked In'])
    .gte('scheduled_date', start)
    .lte('scheduled_date', end);
  if (error) return {};

  const byDate = {};
  (data || []).forEach((r) => { byDate[r.scheduled_date] = (byDate[r.scheduled_date] || 0) + 1; });
  return byDate;
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

  // Same-day arrival needs to be real, not just "the date matches" --
  // the patient must actually be registered at the front desk today
  // (an Open visit), the same way OT check-in implicitly requires a
  // Surgery-type visit to exist. Front desk registers this via the
  // "OPD Procedure Only" visit type, which skips the doctor queue and
  // sends them straight here.
  const { data: activeVisit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .eq('status', 'Open')
    .gte('created_at', `${today}T00:00:00`)
    .limit(1)
    .maybeSingle();
  if (!activeVisit) return { error: "This patient doesn't have an active visit today. Register them at the front desk (OPD Procedure Only) before checking in." };

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

// ── HISTORY ──
// Every completed/cancelled/declined OPD Procedure, newest first, for
// the landing page's History view -- same idea as Surgical Journey's
// "Completed / History" tab. Capped at 300 so this stays fast; older
// records are still reachable by searching the patient directly.
export async function getOpdProcedureHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('*, encounters!inner(visit_id, visits!inner(patient_id, patients(id, first_name, last_name, uhid)))')
    .in('status', ['Completed', 'Done', 'Cancelled'])
    .order('created_at', { ascending: false })
    .limit(300);
  if (error) return [];
  return (data || []).filter((p) => p.encounters?.visits?.patients).map((p) => ({ ...p, patient: p.encounters.visits.patients }));
}

// ── POST-PROCEDURE MEDICINES ──
// Mirrors Consultation's simple (non-tapering) prescription writer --
// same drug catalog, dosage/frequency/duration/eye fields, same
// prescriptions table -- so it prints through the exact same Medicine
// Prescription template. The one wrinkle: prescriptions.encounter_id
// is required, but an "OPD Procedure Only" visit deliberately never
// creates an encounter (it skips the doctor queue). So the first
// medicine added lazily creates a light 'OPD Procedure' encounter
// against whichever visit is active today, cached on the procedure row
// so every later medicine (and the print button) reuses the same one.
async function ensurePostProcedureEncounter(supabase, procedureId) {
  const { data: proc } = await supabase
    .from('plan_procedures')
    .select('post_procedure_encounter_id, encounter_id, encounters(visit_id, visits(patient_id))')
    .eq('id', procedureId)
    .single();
  if (!proc) return null;
  if (proc.post_procedure_encounter_id) return proc.post_procedure_encounter_id;

  const patientId = proc.encounters?.visits?.patient_id;
  const today = todayIst();
  const { data: todaysVisit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .eq('status', 'Open')
    .gte('created_at', `${today}T00:00:00`)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  // Falls back to the original consultation's visit if there's no
  // active visit today (shouldn't normally happen once check-in has
  // already required one, but keeps this from hard-failing).
  const visitId = todaysVisit?.id || proc.encounters?.visit_id;
  if (!visitId) return null;

  const { data: newEncounter, error } = await supabase
    .from('encounters')
    .insert({ visit_id: visitId, encounter_type: 'OPD Procedure', status: 'Completed' })
    .select('id')
    .single();
  if (error || !newEncounter) return null;

  await supabase.from('plan_procedures').update({ post_procedure_encounter_id: newEncounter.id }).eq('id', procedureId);
  return newEncounter.id;
}

export async function getPostProcedurePrescriptions(procedureId) {
  const supabase = await createClient();
  const { data: proc } = await supabase.from('plan_procedures').select('post_procedure_encounter_id').eq('id', procedureId).single();
  if (!proc?.post_procedure_encounter_id) return { visitId: null, prescriptions: [] };

  const [{ data: encounter }, { data: prescriptions }] = await Promise.all([
    supabase.from('encounters').select('visit_id').eq('id', proc.post_procedure_encounter_id).single(),
    supabase.from('prescriptions').select('*').eq('encounter_id', proc.post_procedure_encounter_id).order('created_at'),
  ]);
  return { visitId: encounter?.visit_id || null, prescriptions: prescriptions || [] };
}

export async function getDrugCatalogForOpdProcedures() {
  const supabase = await createClient();
  const [{ data: drugs }, { data: dosages }] = await Promise.all([
    supabase.from('master_drugs').select('*, master_drug_types(id, name, is_ocular)').eq('status', 'Active').order('generic'),
    supabase.from('master_dosage_options').select('*').eq('status', 'Active').order('display_order'),
  ]);
  return { drugs: drugs || [], dosages: dosages || [] };
}

export async function addPostProcedureMedicine(procedureId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const encounterId = await ensurePostProcedureEncounter(supabase, procedureId);
  if (!encounterId) return { error: 'Could not find an active visit to attach this prescription to.' };

  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };

  const { data: proc } = await supabase.from('plan_procedures').select('encounter_id').eq('id', procedureId).single();
  if (proc?.encounter_id) await addAudit(supabase, proc.encounter_id, `Post-procedure medicine added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePostProcedureMedicine(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── EDIT (same-day only) ──
// Lets staff fix a typo or add something missed in the post-procedure
// notes without reopening the whole workflow -- restricted to the same
// day it was completed, matching the app's general caution around
// editing settled records (e.g. payments' same-day edit window).
export async function updateCompletedProcedureNotes(id, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const today = todayIst();

  const { data: row } = await supabase.from('plan_procedures').select('status, completed_at, encounter_id, name').eq('id', id).single();
  if (!row) return { error: 'Procedure not found.' };
  if (row.status !== 'Completed') return { error: 'Only a completed procedure\'s notes can be edited here.' };
  if (!row.completed_at || row.completed_at.slice(0, 10) !== today) return { error: 'Only today\'s completed record can be edited here -- for older records, use the Audit Log instead.' };

  const { error } = await supabase.from('plan_procedures').update({
    procedure_performed: fields.procedurePerformed || null,
    findings: fields.findings || null,
    post_procedure_instructions: fields.instructions || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, row.encounter_id, `OPD Procedure (${row.name}) post-procedure notes edited`, userData?.user?.id);
  return { success: true };
}
