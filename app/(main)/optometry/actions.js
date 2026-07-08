'use server';

import { createClient } from '@/lib/supabase-server';

export async function getQueueEntryForOptometry(queueEntryId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (error) return { error: error.message };
  return { entry: data };
}

export async function saveFindingsAndComplete(queueEntryId, visitId, findings) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error: findingsError } = await supabase.from('optometry_findings').insert({
    visit_id: visitId,
    re_va: findings.reVa || null,
    le_va: findings.leVa || null,
    re_iop: findings.reIop ? parseFloat(findings.reIop) : null,
    le_iop: findings.leIop ? parseFloat(findings.leIop) : null,
    re_sph: findings.reSph || null,
    le_sph: findings.leSph || null,
    re_cyl: findings.reCyl || null,
    le_cyl: findings.leCyl || null,
    recorded_by: userData?.user?.id || null,
  });

  if (findingsError) {
    return { error: findingsError.message };
  }

  const { error: completeError } = await supabase.rpc('optometry_complete', {
    p_queue_entry_id: queueEntryId,
  });

  if (completeError) {
    return { error: completeError.message };
  }

  return { success: true };
}

