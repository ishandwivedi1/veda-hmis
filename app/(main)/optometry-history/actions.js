'use server';

import { createClient } from '@/lib/supabase-server';
import { isCurrentUserAdmin } from '@/lib/authz';

// Assessment History in ONE database call (ui_optometry_history,
// migration 048): only the columns the History table shows, the latest
// IOP per eye, the "Doctor correction" flag and the assessment's
// Optometry queue entry -- so History's "View" reopens the real, current
// entry workspace (optometry-workspace.js) instead of a separate
// read-only viewer (see assessment-viewer.js's own comment on why that
// was retired). Before: 4 database steps one after another, every column.
export async function getOptometryHistory(filterStatus) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optometry_history', { p_status: filterStatus || null });
  if (error) return { error: error.message };
  return { rows: data || [] };
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
      visits(visit_number, patients(first_name, salutation, last_name, uhid, age, gender)),
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

  // Audit Log is Administrator-only (app-layer check here is a UX
  // convenience -- the real boundary is the RLS policy on
  // optometry_audit_log itself, which already blocks SELECT for
  // non-admins at the database level).
  const isAdmin = await isCurrentUserAdmin(supabase);
  const visibleAuditLog = isAdmin ? (auditLog || []) : [];

  // Resolve "created_by" profile names for audit entries (mostly useful
  // for "Doctor override" lines, so the optometrist can see who made
  // the change) without needing a DB-level foreign key embed.
  const createdByIds = [...new Set(visibleAuditLog.map((a) => a.created_by).filter(Boolean))];
  let profileMap = {};
  if (createdByIds.length > 0) {
    const { data: profiles } = await supabase.from('profiles').select('id, full_name').in('id', createdByIds);
    (profiles || []).forEach((p) => { profileMap[p.id] = p.full_name; });
  }
  const annotatedAuditLog = visibleAuditLog.map((a) => ({
    ...a,
    created_by_name: profileMap[a.created_by] || null,
    isDoctorOverride: (a.message || '').startsWith('Doctor override'),
  }));

  // The "N field(s) overridden" banner stays visible to everyone (it's
  // resolved via the same non-admin-safe RPC as the history list), even
  // though the detailed entries below it are Administrator-only.
  let overrideCount = annotatedAuditLog.filter((a) => a.isDoctorOverride).length;
  if (!isAdmin) {
    const { data: overrideRows } = await supabase.rpc('get_doctor_override_assessment_ids', { assessment_ids: [assessmentId] });
    overrideCount = (overrideRows || []).length > 0 ? 1 : 0;
  }

  return {
    assessment,
    iopReadings: iopReadings || [],
    auditLog: annotatedAuditLog,
    overrideCount,
    isAdmin,
  };
}
