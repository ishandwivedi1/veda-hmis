'use server';

import { createClient } from '@/lib/supabase-server';

async function fetchAssessmentsWithIop(supabase, from, to, dateColumn) {
  const { data: assessments } = await supabase
    .from('optometry_assessments')
    .select(`
      *,
      visits(visit_number, patients(first_name, last_name, uhid)),
      completed_by_profile:profiles!optometry_assessments_completed_by_fkey(full_name)
    `)
    .gte(dateColumn, from)
    .lte(dateColumn, `${to}T23:59:59`);

  const rows = assessments || [];
  const ids = rows.map((a) => a.id);

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

  return rows.map((a) => {
    const readings = readingsByAssessment[a.id] || { RE: [], LE: [] };
    return {
      ...a,
      iopRe: readings.RE.length ? readings.RE[readings.RE.length - 1] : null,
      iopLe: readings.LE.length ? readings.LE[readings.LE.length - 1] : null,
    };
  });
}

function patientName(row) {
  const p = row.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export async function getOptometryReport(id, from, to) {
  const supabase = await createClient();

  if (id === 'register') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'created_at');
    rows.sort((a, b) => new Date(b.created_at) - new Date(a.created_at));
    return {
      title: 'Daily Assessment Register',
      headers: ['Date/Time', 'Patient', 'Visit', 'VA RE', 'VA LE', 'IOP RE', 'IOP LE', 'Status', 'By'],
      rows: rows.map((r) => ({
        cols: [
          new Date(r.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }),
          `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
          r.visits?.visit_number || '--',
          r.re_dist_unaided || '--',
          r.le_dist_unaided || '--',
          r.iopRe ?? '--',
          r.iopLe ?? '--',
          r.status,
          r.completed_by_profile?.full_name || '--',
        ],
      })),
      total: null,
    };
  }

  if (id === 'va_distribution') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const tally = {};
    rows.forEach((r) => {
      [r.re_dist_unaided, r.le_dist_unaided].forEach((v) => {
        if (!v) return;
        tally[v] = (tally[v] || 0) + 1;
      });
    });
    const sorted = Object.entries(tally).sort((a, b) => b[1] - a[1]);
    return {
      title: 'VA Distribution (Unaided, both eyes) -- Completed Assessments',
      headers: ['VA Value', 'Count'],
      rows: sorted.map(([val, count]) => ({ cols: [val, count] })),
      total: null,
    };
  }

  if (id === 'iop_surveillance') {
    const rows = await fetchAssessmentsWithIop(supabase, from, to, 'completed_at');
    const withReadings = rows.filter((r) => r.iopRe !== null || r.iopLe !== null);
    withReadings.sort((a, b) => Math.max(b.iopRe || 0, b.iopLe || 0) - Math.max(a.iopRe || 0, a.iopLe || 0));
    return {
      title: 'IOP Surveillance -- Completed Assessments',
      headers: ['Patient', 'Visit', 'IOP RE', 'IOP LE', 'Flag'],
      rows: withReadings.map((r) => {
        const high = (r.iopRe && r.iopRe > 21) || (r.iopLe && r.iopLe > 21);
        const warn = !high && ((r.iopRe && r.iopRe > 18) || (r.iopLe && r.iopLe > 18));
        return {
          cols: [
            `${patientName(r)} (${r.visits?.patients?.uhid || '--'})`,
            r.visits?.visit_number || '--',
            r.iopRe ?? '--',
            r.iopLe ?? '--',
            high ? 'ELEVATED' : warn ? 'Borderline' : 'Normal',
          ],
        };
      }),
      total: null,
    };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
}

