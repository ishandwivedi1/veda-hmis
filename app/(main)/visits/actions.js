'use server';

import { after } from 'next/server';
import { formatPatientName } from '@/lib/patientName';
import { createClient } from '@/lib/supabase-server';
import { sendVisitConfirmationWhatsApp, formatVisitDateIST } from '@/lib/whatsapp';

// Fetches a single patient for pre-filling the New Visit form when
// arriving via a "Create Visit" link from the Patients list, so the
// front desk doesn't have to search for someone they already had open.
export async function getPatientById(patientId) {
  if (!patientId) return null;
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, salutation, last_name, mobile')
    .eq('id', patientId)
    .single();
  return data || null;
}

// Surfaces the patient's last visit automatically once selected on the
// New Visit form, so front desk can bill correctly without having to
// go look it up -- in particular, the OPD Case Sheet for a New
// Consultation now prints a 15-day free follow-up window (see
// buildOpdCaseSheetContext's isNewConsultation flag), so front desk
// needs to see at a glance whether today's Follow-up falls inside that
// window (no consultation charge) or outside it (charge applies).
export async function getLastVisitInfo(patientId) {
  if (!patientId) return null;
  const supabase = await createClient();

  const { data: lastVisit } = await supabase
    .from('visits')
    .select('visit_type, created_at')
    .eq('patient_id', patientId)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (!lastVisit) return { hasPriorVisit: false };

  // The free follow-up window is always anchored to the most recent
  // New Consultation, even if the last visit shown above was itself a
  // Follow-up already inside that window (so a second Follow-up still
  // reads correctly rather than resetting the clock).
  const { data: lastConsultation } = await supabase
    .from('visits')
    .select('created_at')
    .eq('patient_id', patientId)
    .eq('visit_type', 'New Consultation')
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let freeFollowUpUntil = null;
  let withinFreeWindow = false;
  if (lastConsultation) {
    const windowEnd = new Date(lastConsultation.created_at);
    windowEnd.setDate(windowEnd.getDate() + 15);
    freeFollowUpUntil = windowEnd.toISOString();
    withinFreeWindow = new Date() <= windowEnd;
  }

  return {
    hasPriorVisit: true,
    lastVisitType: lastVisit.visit_type,
    lastVisitDate: lastVisit.created_at,
    freeFollowUpUntil,
    withinFreeWindow,
  };
}

export async function getDoctorOptionsForVisit() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name')
    .eq('designation', 'Doctor')
    .eq('status', 'Active')
    .order('full_name');
  return data || [];
}

// Core send logic -- always synchronous, always returns a real result.
// Used directly by resendVisitWhatsApp (manual button, needs real
// success/error feedback) and wrapped by deferVisitWhatsApp below for
// the automatic triggers (visit creation), which must never block.
async function sendVisitWhatsAppCore(visit, triggeredBy) {
  const supabase = await createClient();
  const { data: patient } = await supabase
    .from('patients')
    .select('id, first_name, salutation, last_name, mobile')
    .eq('id', visit.patient_id)
    .single();

  if (!patient || !patient.mobile) return { success: false, error: 'Patient has no mobile number on file.' };

  return sendVisitConfirmationWhatsApp({
    name: `${formatPatientName(patient)}`.trim(),
    visitNumber: visit.visit_number,
    visitDate: formatVisitDateIST(visit.created_at),
    mobile: patient.mobile,
    patientDbId: patient.id,
    visitDbId: visit.id,
    meta: { module: 'visit', triggeredBy: triggeredBy || null },
  });
}

// Deferred wrapper for createWalkInVisit / checkInAppointment -- schedules
// the send to run after the response via after(), so visit creation
// returns immediately and is never blocked or failed by the WhatsApp send.
function deferVisitWhatsApp(visit, triggeredBy) {
  after(async () => {
    try {
      await sendVisitWhatsAppCore(visit, triggeredBy);
    } catch (waErr) {
      console.error('WhatsApp visit confirmation send failed:', waErr.message);
    }
  });
}

// Finds the surgical case a front-desk redirect should land on -- the
// open case booked for today's OT if there is one, otherwise just the
// patient's (only) open case. Shared by Surgery, Surgery Evaluation,
// and Investigation Only redirects below -- all three need "which
// case is this" resolved the same way, and Surgery Evaluation/
// Investigation Only are guaranteed by the RPC's own eligibility
// check to always have one.
async function getRelevantSurgicalCaseId(supabase, patientId) {
  const todayIst = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const { data: cases } = await supabase.from('surgical_cases').select('id').eq('patient_id', patientId).neq('status', 'Cancelled');
  const caseIds = (cases || []).map((c) => c.id);
  if (caseIds.length === 0) return { caseId: null, otScheduleId: null, surgeryNotScheduled: true };

  const { data: match } = await supabase
    .from('ot_schedule')
    .select('id, surgical_case_id')
    .in('surgical_case_id', caseIds)
    .eq('scheduled_date', todayIst)
    .in('status', ['Scheduled', 'In Progress'])
    .limit(1);
  if (match && match.length > 0) return { caseId: match[0].surgical_case_id, otScheduleId: match[0].id, surgeryNotScheduled: false };

  // No booking for today specifically -- still redirect to their
  // (only) open case so front desk sees the real state (not yet
  // booked, awaiting confirmation, etc.) directly on Surgical
  // Journey, rather than a dead end.
  return { caseId: caseIds[0], otScheduleId: null, surgeryNotScheduled: true };
}

export async function checkInAppointment(appointmentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('check_in_appointment', {
    p_appointment_id: appointmentId,
  });

  if (error) {
    return { error: error.message };
  }

  const { data: { user } } = await supabase.auth.getUser();
  deferVisitWhatsApp(data, user?.id);

  let surgicalCaseId = null;
  if (['Surgery', 'Surgery Evaluation', 'Investigation Only'].includes(data?.visit_type) && data?.patient_id) {
    const result = await getRelevantSurgicalCaseId(supabase, data.patient_id);
    surgicalCaseId = result.caseId;
  }

  return { visit: data, surgicalCaseId };
}

export async function createWalkInVisit(values) {
  const supabase = await createClient();

  // A visit with no doctor assigned leaves the OPD Case Sheet's doctor
  // name/reg-no blank at print time (visits.doctor_id is read directly).
  // /visits/new's own form already resolves this default client-side
  // before calling here, but Register & Create Visit (the Patient
  // Registration page's one-click shortcut) was passing doctorId: null
  // outright -- so the same default lives here too, server-side, to
  // cover every caller uniformly rather than requiring each new caller
  // to duplicate the same client-side lookup.
  let doctorId = values.doctorId || null;
  if (!doctorId) {
    const { data: defaultDoctor } = await supabase
      .from('profiles')
      .select('id')
      .eq('designation', 'Doctor')
      .eq('status', 'Active')
      .ilike('full_name', '%nisha bachkheti%')
      .limit(1)
      .maybeSingle();
    doctorId = defaultDoctor?.id || null;
  }

  const { data, error } = await supabase.rpc('create_walk_in_visit', {
    p_patient_id: values.patientId,
    p_doctor_id: doctorId,
    p_visit_type: values.visitType,
    p_referral_source: values.referralSource || null,
    p_priority: values.priority || 'Routine',
    p_surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  });

  if (error) {
    return { error: error.message };
  }

  const { data: { user } } = await supabase.auth.getUser();
  deferVisitWhatsApp(data, user?.id);

  // create_walk_in_visit's Surgery branch only ATTACHES this visit to an
  // OT case that was already scheduled for today -- it can't create one.
  // If nothing matches (patient's surgery was arranged before HMIS
  // existed, an external referral, staff skipped Counselling, etc.),
  // that attach step silently touches zero rows and the visit still
  // gets created successfully, leaving the patient invisible in OT
  // Schedule with no indication anything went wrong. Surface that here
  // instead of letting it be discovered later in OT. Surgery Evaluation
  // and Investigation Only are guaranteed by the RPC's own eligibility
  // check to always have an open case, so this always resolves for them.
  let surgeryNotScheduled = false;
  let otScheduleId = null;
  let surgicalCaseId = null;
  if (['Surgery', 'Surgery Evaluation', 'Investigation Only'].includes(values.visitType) && data?.patient_id) {
    const result = await getRelevantSurgicalCaseId(supabase, data.patient_id);
    surgeryNotScheduled = result.surgeryNotScheduled;
    otScheduleId = result.otScheduleId;
    surgicalCaseId = result.caseId;
  }

  return { visit: data, surgeryNotScheduled, otScheduleId, surgicalCaseId };
}

export async function getSurgeryTypeOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name');
  return data || [];
}

// Resend the visit confirmation WhatsApp message -- used by a manual
// "Resend WhatsApp confirmation" control, e.g. if the automatic send
// failed or the patient's mobile number was corrected since.
export async function resendVisitWhatsApp(visitId) {
  if (!visitId) return { error: 'Missing visit id.' };

  const supabase = await createClient();
  const { data: visit, error } = await supabase
    .from('visits')
    .select('id, visit_number, patient_id, created_at')
    .eq('id', visitId)
    .single();

  if (error) return { error: error.message };
  if (!visit) return { error: 'Visit not found.' };

  const { data: { user } } = await supabase.auth.getUser();
  const whatsapp = await sendVisitWhatsAppCore(visit, user?.id);

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Surgery Evaluation', 'OPD Procedure Only', 'Post-operative Review', 'Emergency', 'Surgery'];

// Doctor / visit type / priority can be corrected after check-in --
// front desk mistakes happen. Scoped to Open visits only; a closed or
// cancelled visit is a historical record and shouldn't be edited.
export async function updateVisit(visitId, values) {
  const supabase = await createClient();

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is ${visit.status} and can no longer be edited.` };
  if (values.visitType && !VISIT_TYPES.includes(values.visitType)) return { error: 'Invalid visit type.' };

  const { error } = await supabase.from('visits').update({
    doctor_id: values.doctorId || null,
    visit_type: values.visitType,
    priority: values.priority || 'Routine',
    surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  }).eq('id', visitId);
  if (error) return { error: error.message };
  return { success: true };
}

// Cancelling a visit is permanent and needs a reason on record -- also
// pulls the patient out of whatever queue they're still sitting in
// (Optometry/Doctor), since there's nothing left for them to wait for.
// Blocked if the visit already has money collected against it, since
// that needs to go through Invoice Modification instead of silently
// orphaning a paid invoice.
export async function cancelVisit(visitId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is already ${visit.status}.` };

  const { data: invoices } = await supabase.from('invoices').select('id, status, paid').eq('visit_id', visitId);
  const hasPayment = (invoices || []).some((inv) => Number(inv.paid) > 0);
  if (hasPayment) {
    return { error: 'This visit already has payment collected against it -- cancel or modify the invoice first, via Invoice Modification.' };
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('visits').update({
    status: 'Cancelled',
    cancellation_reason: reason.trim(),
    cancelled_by: userData?.user?.id || null,
    cancelled_at: new Date().toISOString(),
  }).eq('id', visitId);
  if (error) return { error: error.message };

  await supabase
    .from('queue_entries')
    .update({ status: 'Cancelled' })
    .eq('visit_id', visitId)
    .not('status', 'in', '("Done","Cancelled")');

  return { success: true };
}
