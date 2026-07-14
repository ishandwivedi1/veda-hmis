'use server';

import { createClient } from '@/lib/supabase-server';

export async function getWorkflowMonitorData() {
  const supabase = await createClient();

  const { data: encounters } = await supabase
    .from('encounters')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid)), profiles!encounters_doctor_id_fkey(full_name)')
    .eq('status', 'In Consultation')
    .order('started_at', { ascending: true });

  const rows = encounters || [];
  const encounterIds = rows.map((e) => e.id);
  const visitIds = rows.map((e) => e.visits?.id).filter(Boolean);

  let queueEntryByVisit = {};
  if (visitIds.length > 0) {
    const { data: qe } = await supabase
      .from('queue_entries')
      .select('id, visit_id, status')
      .eq('department', 'Doctor')
      .in('visit_id', visitIds);
    (qe || []).forEach((q) => { queueEntryByVisit[q.visit_id] = q; });
  }

  // "Transitions" -- count of state-changing audit entries for this
  // encounter (sent for dilation/investigation, workflow requested or
  // cancelled). A genuine count from the persisted audit log, not a
  // simulated counter.
  let transitionCountByEncounter = {};
  if (encounterIds.length > 0) {
    const { data: logs } = await supabase
      .from('encounter_audit_log')
      .select('encounter_id, message')
      .in('encounter_id', encounterIds);
    (logs || []).forEach((l) => {
      if (/^(Sent for|Workflow requested|Workflow request cancelled)/.test(l.message)) {
        transitionCountByEncounter[l.encounter_id] = (transitionCountByEncounter[l.encounter_id] || 0) + 1;
      }
    });
  }

  return rows.map((e) => ({
    ...e,
    queueStatus: queueEntryByVisit[e.visits?.id]?.status || '--',
    queueEntryId: queueEntryByVisit[e.visits?.id]?.id || null,
    transitions: transitionCountByEncounter[e.id] || 0,
  }));
}

