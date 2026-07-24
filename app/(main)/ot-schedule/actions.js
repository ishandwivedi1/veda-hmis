'use server';

import { createClient } from '@/lib/supabase-server';

// ── SESSIONS (master data) ──
export async function getOTSessions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_ot_sessions').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}

// ── READY FOR SCHEDULING QUEUE ──
// Reads directly off surgical_cases.status -- the exact same "Ready for
// Scheduling" status Counselling's markReadyForScheduling already sets
// once package/decision/biometry/fitness are all satisfied. Nothing
// re-derived here; OT just consumes the result.
export async function getReadyQueue() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(id, first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(id, full_name)')
    .eq('status', 'Ready for Scheduling')
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });
  if (error) return [];
  return data || [];
}

// ── DASHBOARD ──
export async function getOTDashboard() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: sessions }, { data: todayBookings }, readyCount] = await Promise.all([
    supabase.from('master_ot_sessions').select('*').eq('status', 'Active').order('display_order'),
    supabase.from('ot_schedule').select('*, surgical_cases(procedure_name, eye, priority)').eq('scheduled_date', today).neq('status', 'Cancelled'),
    supabase.from('surgical_cases').select('id', { count: 'exact', head: true }).eq('status', 'Ready for Scheduling').then((r) => r.count || 0),
  ]);

  const bookingsBySession = {};
  (todayBookings || []).forEach((b) => {
    if (!b.session_id) return;
    (bookingsBySession[b.session_id] = bookingsBySession[b.session_id] || []).push(b);
  });

  const sessionSummary = (sessions || []).map((s) => {
    const bookings = bookingsBySession[s.id] || [];
    return {
      ...s,
      planned: bookings.length,
      completed: bookings.filter((b) => b.status === 'Completed').length,
      cancelled: 0, // cancelled bookings are excluded from todayBookings by design
    };
  });

  const totalCapacity = sessionSummary.reduce((s, x) => s + x.capacity, 0);
  const totalPlanned = sessionSummary.reduce((s, x) => s + x.planned, 0);

  const alerts = await getOTAlerts();

  return {
    readyCount,
    scheduledToday: (todayBookings || []).length,
    capacityPct: totalCapacity > 0 ? Math.round((totalPlanned / totalCapacity) * 100) : 0,
    alertsCount: alerts.length,
    sessions: sessionSummary,
  };
}

// ── WORKSPACE: full detail for scheduling a specific case ──
export async function getSchedulingWorkspaceData(caseId) {
  const supabase = await createClient();
  const { data: sc, error } = await supabase
    .from('surgical_cases')
    .select('*, patients:patient_id(id, first_name, last_name, uhid, age, gender, mobile), profiles:surgeon_id(id, full_name)')
    .eq('id', caseId)
    .single();
  if (error) return { error: error.message };

  // Approved IOL Plan -- read-only here, owned by the Biometry module.
  const { data: biometry } = await supabase
    .from('biometry_records')
    .select('*, master_iol_catalog(brand, model, manufacturer)')
    .eq('visit_id', sc.visit_id)
    .eq('status', 'Approved')
    .order('approved_at', { ascending: false });

  // Any existing (non-cancelled) booking for this case -- workspace
  // shows it pre-filled instead of a blank scheduling form.
  const { data: existingBooking } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name, start_time, end_time, default_room, capacity)')
    .eq('surgical_case_id', caseId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  return { case: sc, biometryPlans: biometry || [], existingBooking: existingBooking || null };
}

// ── CAPACITY CHECK ──
export async function getSessionCapacity(date, sessionId, excludeBookingId) {
  const supabase = await createClient();
  let query = supabase.from('ot_schedule').select('id', { count: 'exact', head: true })
    .eq('scheduled_date', date).eq('session_id', sessionId).neq('status', 'Cancelled');
  if (excludeBookingId) query = query.neq('id', excludeBookingId);
  const { count } = await query;
  return count || 0;
}

// ── SCHEDULE ──
export async function scheduleSurgery(caseId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('status, surgeon_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Ready for Scheduling') return { error: 'BR-OTS-001: This case is not marked Ready for Scheduling.' };
  if (!values.date) return { error: 'Surgery date is required.' };
  if (!values.sessionId) return { error: 'Session is required.' };

  const { data: booking, error: otError } = await supabase.from('ot_schedule').insert({
    surgical_case_id: caseId, surgeon_id: sc.surgeon_id || null,
    scheduled_date: values.date, session_id: values.sessionId, room: values.room || null,
    sequence_number: values.sequenceNumber || null, expected_duration_minutes: values.duration || 30,
    notes: values.notes || null,
  }).select('id').single();
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Scheduled' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: booking.id, action: 'Scheduled',
    detail: `Scheduled for ${values.date}, session ${values.sessionId}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── RESCHEDULE (same booking preserved, per BR/Section 18.13) ──
export async function rescheduleSurgery(otScheduleId, values) {
  const supabase = await createClient();
  if (!values.reason) return { error: 'A reschedule reason is required.' };
  const { data: userData } = await supabase.auth.getUser();

  const { data: booking } = await supabase.from('ot_schedule').select('scheduled_date, session_id, reschedule_count').eq('id', otScheduleId).single();
  if (!booking) return { error: 'Booking not found.' };

  const { error } = await supabase.from('ot_schedule').update({
    scheduled_date: values.date, session_id: values.sessionId,
    reschedule_count: (booking.reschedule_count || 0) + 1,
  }).eq('id', otScheduleId);
  if (error) return { error: error.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Rescheduled',
    detail: `From ${booking.scheduled_date} -> ${values.date} -- Reason: ${values.reason}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

// ── CANCEL (booking cancelled, case goes back to the queue) ──
export async function cancelSurgery(otScheduleId, caseId, values) {
  const supabase = await createClient();
  if (!values.reason) return { error: 'A cancellation reason is required.' };
  const { data: userData } = await supabase.auth.getUser();

  const { error: otError } = await supabase.from('ot_schedule').update({
    status: 'Cancelled', cancellation_reason: values.reason, cancellation_remarks: values.remarks || null,
    cancelled_by: userData?.user?.id || null, cancelled_at: new Date().toISOString(),
  }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };

  await supabase.from('ot_schedule_audit_log').insert({
    ot_schedule_id: otScheduleId, action: 'Cancelled',
    detail: `Reason: ${values.reason}${values.remarks ? ` -- ${values.remarks}` : ''}`,
    changed_by: userData?.user?.id || null,
  });

  return { success: true };
}

export async function completeSurgery(otScheduleId, caseId) {
  const supabase = await createClient();
  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };
  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', caseId);
  if (caseError) return { error: caseError.message };
  return { success: true };
}

// ── DAILY OT LIST ──
export async function getDailyOTList(date, sessionId) {
  const supabase = await createClient();
  let query = supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, priority, visit_id, patients:patient_id(first_name, last_name, uhid)), profiles:surgeon_id(full_name)')
    .eq('scheduled_date', date)
    .neq('status', 'Cancelled')
    .order('sequence_number', { ascending: true, nullsFirst: false });
  if (sessionId) query = query.eq('session_id', sessionId);
  const { data, error } = await query;
  if (error) return [];

  // Pull the approved IOL plan for each row's visit so the printed/daily
  // list shows it inline, same as the prototype.
  const visitIds = [...new Set((data || []).map((b) => b.surgical_cases?.visit_id).filter(Boolean))];
  let iolByVisit = {};
  if (visitIds.length > 0) {
    const { data: plans } = await supabase.from('biometry_records').select('visit_id, final_iol_power, final_iol_category, surgical_eye').eq('status', 'Approved').in('visit_id', visitIds);
    (plans || []).forEach((p) => { (iolByVisit[p.visit_id] = iolByVisit[p.visit_id] || []).push(p); });
  }

  return (data || []).map((b) => ({ ...b, iolPlans: iolByVisit[b.surgical_cases?.visit_id] || [] }));
}

// ── ALERTS ──
// Real, data-driven checks rather than the prototype's canned scenarios:
// scheduled cases where something readiness-related has changed since
// they were queued.
export async function getOTAlerts() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const { data: upcoming } = await supabase
    .from('ot_schedule')
    .select('id, scheduled_date, surgical_case_id, surgical_cases(procedure_name, eye, fitness_cleared, patients:patient_id(first_name, last_name))')
    .gte('scheduled_date', today)
    .neq('status', 'Cancelled')
    .neq('status', 'Completed');

  const alerts = [];
  (upcoming || []).forEach((b) => {
    const sc = b.surgical_cases;
    if (!sc) return;
    const name = `${sc.patients?.first_name || ''} ${sc.patients?.last_name || ''}`.trim();
    if (!sc.fitness_cleared) {
      alerts.push({ patient: name, issue: 'Medical fitness no longer cleared for this case', urgency: 'high', bookingId: b.id });
    }
  });

  return alerts;
}

// ── REPORTS ──
export async function getOTReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, master_ot_sessions(name), surgical_cases(procedure_name, eye, patients:patient_id(first_name, last_name, uhid)), profiles:surgeon_id(full_name)')
    .gte('scheduled_date', fromDate)
    .lte('scheduled_date', toDate)
    .order('scheduled_date', { ascending: false });
  if (error) return { title: 'Error', headers: [], rows: [] };

  if (reportId === 'daily') {
    return {
      title: 'OT Bookings',
      headers: ['Date', 'Session', 'Patient', 'Procedure', 'Surgeon', 'Status'],
      rows: (data || []).map((b) => ({
        cols: [b.scheduled_date, b.master_ot_sessions?.name || '--', `${b.surgical_cases?.patients?.first_name} ${b.surgical_cases?.patients?.last_name}`, `${b.surgical_cases?.procedure_name} (${b.surgical_cases?.eye})`, b.profiles?.full_name || '--', b.status],
      })),
    };
  }

  if (reportId === 'util') {
    const bySession = {};
    (data || []).filter((b) => b.status !== 'Cancelled').forEach((b) => {
      const name = b.master_ot_sessions?.name || 'Unassigned';
      bySession[name] = (bySession[name] || 0) + 1;
    });
    return {
      title: 'OT Utilization by Session',
      headers: ['Session', 'Bookings'],
      rows: Object.entries(bySession).map(([name, count]) => ({ cols: [name, count] })),
    };
  }

  if (reportId === 'cancel') {
    const cancelled = (data || []).filter((b) => b.status === 'Cancelled');
    return {
      title: 'Cancellations',
      headers: ['Date', 'Patient', 'Procedure', 'Reason', 'Remarks'],
      rows: cancelled.map((b) => ({
        cols: [b.scheduled_date, `${b.surgical_cases?.patients?.first_name} ${b.surgical_cases?.patients?.last_name}`, b.surgical_cases?.procedure_name, b.cancellation_reason || '--', b.cancellation_remarks || '--'],
      })),
    };
  }

  if (reportId === 'surgeon') {
    const bySurgeon = {};
    (data || []).filter((b) => b.status !== 'Cancelled').forEach((b) => {
      const name = b.profiles?.full_name || 'Unassigned';
      bySurgeon[name] = (bySurgeon[name] || 0) + 1;
    });
    return {
      title: 'Surgeon-wise Load',
      headers: ['Surgeon', 'Cases'],
      rows: Object.entries(bySurgeon).map(([name, count]) => ({ cols: [name, count] })),
    };
  }

  return { title: 'Unknown report', headers: [], rows: [] };
}

