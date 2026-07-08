'use server';

import { createClient } from '@/lib/supabase-server';

export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  data.forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: io.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').update({ status: 'In Progress' }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, notes) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_notes: notes || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

