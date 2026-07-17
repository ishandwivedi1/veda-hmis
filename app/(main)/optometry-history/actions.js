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
  const visitIds = [...new Set((assessments || []).map((a) => a.visit_id).filter(Boolean))];

  // Full IOP reading history per assessment (not just the latest value --
  // the detail view needs the whole trend; the summary row still only
  // shows the latest).
  let readingsByAssessment = {};
  if (ids.length > 0) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .in('assessment_id', ids)
      .order('recorded_at', { ascending: true });

    (readings || []).forEach((r) => {
      if (!readingsByAssessment[r.assessment_id]) readingsByAssessment[r.assessment_id] = { RE: [], LE: [] };
      readingsByAssessment[r.assessment_id][r.eye].push(r);
    });
  }

  // Doctor corrections (CDP-004): doctor_repeat_findings never overwrites
  // optometry_assessments -- it's a separate, timestamped table keyed by
  // encounter_id. Walk visit -> encounter -> findings to attach any
  // doctor-recorded values for the same visit.
  let findingsByVisit = {};
  if (visitIds.length > 0) {
    const { data: encounters } = await supabase
      .from('encounters')
      .select('id, visit_id')
      .in('visit_id', visitIds);

    const encounterToVisit = {};
    (encounters || []).forEach((e) => { encounterToVisit[e.id] = e.visit_id; });
    const encounterIds = Object.keys(encounterToVisit);

    if (encounterIds.length > 0) {
      const { data: findings } = await supabase
        .from('doctor_repeat_findings')
        .select('*')
        .in('encounter_id', encounterIds)
        .order('recorded_at', { ascending: false });

      const recordedByIds = [...new Set((findings || []).map((f) => f.recorded_by).filter(Boolean))];
      let profileMap = {};
      if (recordedByIds.length > 0) {
        const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', recordedByIds);
        (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
      }

      (findings || []).forEach((f) => {
        const visitId = encounterToVisit[f.encounter_id];
        if (!visitId) return;
        if (!findingsByVisit[visitId]) findingsByVisit[visitId] = [];
        findingsByVisit[visitId].push({ ...f, recorded_by_name: profileMap[f.recorded_by] || '--' });
      });
    }
  }

  const rows = (assessments || []).map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    const lastRe = readings.RE.length ? readings.RE[readings.RE.length - 1].value : null;
    const lastLe = readings.LE.length ? readings.LE[readings.LE.length - 1].value : null;
    const doctorFindings = findingsByVisit[a.visit_id] || [];

    return {
      ...a,
      iopRe: lastRe,
      iopLe: lastLe,
      iopReadings: readings,
      doctorFindings,
      hasDoctorCorrection: doctorFindings.length > 0,
    };
  });

  return { rows };
}

// Full assessment detail for the read-only "open full sheet" viewer --
// fetched by assessment id directly (not queue entry id, since a
// history view has no live queue entry to key off).
export async function getAssessmentDetail(assessmentId) {
  const supabase = await createClient();

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid, age, gender)),
      recorded_by_profile:profiles!optometry_assessments_recorded_by_fkey(full_name),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .eq('id', assessmentId)
    .single();

  if (error) return { error: error.message };

  const [{ data: iopReadings }, { data: auditLog }] = await Promise.all([
    supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessmentId).order('recorded_at', { ascending: true }),
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessmentId).order('created_at', { ascending: false }),
  ]);

  // Doctor corrections (CDP-004): doctor_repeat_findings never overwrites
  // this assessment -- it's a separate, timestamped table keyed by
  // encounter_id. Pull every finding recorded against any encounter for
  // this visit.
  let doctorFindings = [];
  if (assessment.visit_id) {
    const { data: encounters } = await supabase.from('encounters').select('id').eq('visit_id', assessment.visit_id);
    const encounterIds = (encounters || []).map((e) => e.id);

    if (encounterIds.length > 0) {
      const { data: findings } = await supabase
        .from('doctor_repeat_findings')
        .select('*')
        .in('encounter_id', encounterIds)
        .order('recorded_at', { ascending: false });

      const recordedByIds = [...new Set((findings || []).map((f) => f.recorded_by).filter(Boolean))];
      let profileMap = {};
      if (recordedByIds.length > 0) {
        const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', recordedByIds);
        (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
      }
      doctorFindings = (findings || []).map((f) => ({ ...f, recorded_by_name: profileMap[f.recorded_by] || '--' }));
    }
  }

  return { assessment, iopReadings: iopReadings || [], auditLog: auditLog || [], doctorFindings };
}

