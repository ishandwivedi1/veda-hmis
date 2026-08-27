'use server';

import { createClient } from '@/lib/supabase-server';

export async function getDoctorDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: active }, { data: intermediate }, { data: completed }, { data: optometryWaiting }, { data: todaysVisits }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(id, first_name, salutation, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .in('status', ['Waiting', 'Ready for Review', 'In Consultation'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(first_name, salutation, last_name, uhid, age, gender))')
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
      .select('*, visits(id, visit_type, patients(id, first_name, salutation, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, visit_type, patients(first_name, salutation, last_name, uhid, age, gender))')
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


