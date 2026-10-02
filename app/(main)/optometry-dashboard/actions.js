'use server';

import { createClient } from '@/lib/supabase-server';

// Optometry Dashboard -- queues for today (IST) in ONE database call
// (ui_optometry_dashboard, migration 048). Completed rows carry
// doctorStatus + locked: readings stay editable until the doctor opens
// (or finishes) the consultation.
export async function getOptometryDashboardData() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optometry_dashboard');
  if (error || !data) return { active: [], completed: [] };
  return { active: data.active || [], completed: data.completed || [] };
}

// Call Next / Call in ONE request and ONE database call: the status
// change, its journey event and the refreshed dashboard come back together
// (optometry_queue_action, migration 048). The Queue page keeps using its
// own actions in queue/actions.js -- untouched.
export async function runOptometryQueueAction(action, id = null) {
  if (action !== 'call_next' && action !== 'call') return { error: 'Unknown action.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('optometry_queue_action', { p_action: action, p_id: id });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { dashboard: { active: data?.dashboard?.active || [], completed: data?.dashboard?.completed || [] } };
}
