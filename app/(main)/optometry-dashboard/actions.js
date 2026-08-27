'use server';

import { createClient } from '@/lib/supabase-server';

export async function getOptometryDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: activeEntries }, { data: doneEntries }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, salutation, last_name, uhid, age, gender))')
      .eq('department', 'Optometry')
      .in('status', ['Waiting', 'Calling'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, salutation, last_name, uhid, age, gender))')
      .eq('department', 'Optometry')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
  ]);

  const done = doneEntries || [];
  const visitIds = done.map((e) => e.visits?.id).filter(Boolean);

  // Batch-fetch the Doctor queue status for every completed visit today, so
  // we can tell which posted readings are still editable vs. already locked
  // because the doctor has opened (or finished) the consultation.
  let doctorStatusByVisit = {};
  if (visitIds.length > 0) {
    const { data: doctorEntries } = await supabase
      .from('queue_entries')
      .select('visit_id, status')
      .eq('department', 'Doctor')
      .in('visit_id', visitIds);

    (doctorEntries || []).forEach((d) => {
      doctorStatusByVisit[d.visit_id] = d.status;
    });
  }

  const completed = done.map((e) => {
    const doctorStatus = doctorStatusByVisit[e.visits?.id] || null;
    const locked = doctorStatus === 'In Consultation' || doctorStatus === 'Done';
    return { ...e, doctorStatus, locked };
  });

  return { active: activeEntries || [], completed };
}

