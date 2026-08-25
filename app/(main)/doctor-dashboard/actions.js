'use server';

import { createClient } from '@/lib/supabase-server';
import { SURGICAL_TRACK_VISIT_TYPES } from '@/lib/visit-types';

// Doctor Dashboard is OPD-only -- a patient here purely for biometry/
// investigation or specifically for surgical assessment belongs on
// the Surgeon Dashboard instead (see doctor-dashboard-surgery/actions.js
// getSurgeryEvaluationQueue, the complementary filter). Department
// stays 'Doctor' for both -- same token, same underlying queue_entries
// row, same consultation window -- this is purely which dashboard
// surfaces it, done as a post-fetch filter rather than a new queue
// department so none of the dozen other places that already key off
// department = 'Doctor' (investigation routing, patient timeline,
// workflow monitor, etc.) need to change or even know this split
// exists.
function excludeSurgicalTrack(entries) {
  return (entries || []).filter((e) => !SURGICAL_TRACK_VISIT_TYPES.includes(e.visits?.visit_type));
}

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
    active: excludeSurgicalTrack(active), intermediate: excludeSurgicalTrack(intermediate),
    completed: excludeSurgicalTrack(completed), optometryWaiting: optometryWaiting || [],
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
  return excludeSurgicalTrack(data).filter((e) => e.visits?.patients);
}


