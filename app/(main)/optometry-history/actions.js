'use server';

import { createClient } from '@/lib/supabase-server';

export async function getOptometryHistory(filterStatus) {
  const supabase = await createClient();

  let query = supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      recorded_by_profile:profiles!optometry_assessments_recorded_by_fkey(full_name),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .order('created_at', { ascending: false });

  if (filterStatus) query = query.eq('status', filterStatus);

  const { data: assessments, error } = await query;
  if (error) return { error: error.message };

  const ids = (assessments || []).map((a) => a.id);
  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r.value);
    });
  }

  const rows = (assessments || []).map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    return {
      ...a,
      iopRe: readings.RE.length ? readings.RE[readings.RE.length - 1] : null,
      iopLe: readings.LE.length ? readings.LE[readings.LE.length - 1] : null,
    };
  });

  return { rows };
}

