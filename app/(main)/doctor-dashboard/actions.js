'use server';

import { createClient } from '@/lib/supabase-server';

export async function getDoctorDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: active }, { data: intermediate }, { data: completed }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .in('status', ['Waiting', 'Ready for Review', 'In Consultation'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
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
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
  ]);

  return { active: active || [], intermediate: intermediate || [], completed: completed || [] };
}


