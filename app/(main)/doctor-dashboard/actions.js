'use server';

import { createClient } from '@/lib/supabase-server';

const EMPTY_DASHBOARD = {
  active: [], intermediate: [], completed: [], optometryWaiting: [],
  visitTypeCounts: {}, totalVisitsToday: 0, proceduresDueToday: [],
};

// Everything the Doctor Dashboard shows -- queues, visit-type counts and
// OPD procedures due today -- in ONE database call (ui_doctor_dashboard,
// migration 047). Same row shape as before (queue entry + visits +
// patients); Post-operative Review entries also carry postop_episode_id
// so opening one needs no extra lookup. "Today" is the IST day.
export async function getDoctorDashboardData() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_doctor_dashboard');
  if (error || !data) return { ...EMPTY_DASHBOARD, error: error?.message || null };
  return { ...EMPTY_DASHBOARD, ...data };
}

// The four Doctor Dashboard queue buttons (Call Next / Call / Mark Ready /
// Call Directly) in ONE request and ONE database call: the change, its
// journey event, and the refreshed dashboard all come back together
// (doctor_queue_action, migration 047). The Queue page keeps using its own
// actions in queue/actions.js -- untouched.
const QUEUE_ACTIONS = new Set(['call_next', 'call', 'mark_ready', 'call_direct']);
export async function runDoctorQueueAction(action, id = null) {
  if (!QUEUE_ACTIONS.has(action)) return { error: 'Unknown action.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('doctor_queue_action', { p_action: action, p_id: id });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { dashboard: { ...EMPTY_DASHBOARD, ...(data?.dashboard || {}) } };
}

// ── OPD PROCEDURES DUE TODAY ──
// Patients whose OPD Procedure was scheduled (by the doctor, in a past
// consultation) for TODAY specifically, rather than performed same-
// sitting -- otherwise there was no way to know who's expected back in
// for one until they walked in and someone remembered. Purely
// informational: front desk still registers a fresh visit for the
// patient as normal; this just tells staff who to expect.
export async function getProceduresDueToday() {
  const supabase = await createClient();
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data, error } = await supabase
    .from('plan_procedures')
    .select('id, name, eye, notes, scheduled_date, encounters(visit_id, visits(patients(id, first_name, salutation, last_name, uhid, mobile)))')
    .eq('status', 'Planned')
    .eq('scheduled_date', todayIst)
    .order('created_at');
  if (error) return [];
  return (data || []).filter((p) => p.encounters?.visits?.patients);
}


export async function getDoctorHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, visit_type, patients(id, first_name, salutation, last_name, uhid, age, gender))')
    .eq('department', 'Doctor')
    .eq('status', 'Done')
    .order('completed_at', { ascending: false })
    .limit(200);
  if (error) return [];
  return (data || []).filter((e) => e.visits?.patients);
}


