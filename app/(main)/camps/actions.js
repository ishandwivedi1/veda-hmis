'use server';

import { createClient } from '@/lib/supabase-server';
import { registerPatient } from '@/app/(main)/patients/actions';
import { sendWhatsAppTemplate } from '@/lib/whatsapp';

// ── CAMP EVENTS ──
export async function listCampEvents() {
  const supabase = await createClient();
  const { data: camps, error } = await supabase
    .from('camp_events')
    .select('*')
    .order('camp_date', { ascending: false });
  if (error) return { error: error.message };

  // Screening + conversion counts per camp -- the actual ROI numbers
  // this module exists to answer ("how many of the 60 people we saw
  // actually became patients").
  const { data: screenings } = await supabase.from('camp_screenings').select('camp_event_id, patient_id');
  const counts = {};
  (screenings || []).forEach((s) => {
    if (!counts[s.camp_event_id]) counts[s.camp_event_id] = { total: 0, converted: 0 };
    counts[s.camp_event_id].total += 1;
    if (s.patient_id) counts[s.camp_event_id].converted += 1;
  });

  return {
    rows: (camps || []).map((c) => ({
      ...c,
      screenedCount: counts[c.id]?.total || 0,
      convertedCount: counts[c.id]?.converted || 0,
    })),
  };
}

export async function getCampEvent(campEventId) {
  const supabase = await createClient();
  const { data: camp, error } = await supabase.from('camp_events').select('*').eq('id', campEventId).single();
  if (error) return { error: error.message };
  return { camp };
}

export async function createCampEvent(values) {
  if (!values.name?.trim()) return { error: 'Camp name is required.' };
  if (!values.campDate) return { error: 'Camp date is required.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data, error } = await supabase
    .from('camp_events')
    .insert({
      name: values.name.trim(),
      location: values.location?.trim() || null,
      camp_date: values.campDate,
      conducted_by: values.conductedBy?.trim() || null,
      notes: values.notes?.trim() || null,
      created_by: user?.id || null,
    })
    .select('*')
    .single();
  if (error) return { error: error.message };
  return { camp: data };
}

export async function updateCampEvent(campEventId, values) {
  if (!values.name?.trim()) return { error: 'Camp name is required.' };
  if (!values.campDate) return { error: 'Camp date is required.' };
  const supabase = await createClient();
  const { error } = await supabase
    .from('camp_events')
    .update({
      name: values.name.trim(),
      location: values.location?.trim() || null,
      camp_date: values.campDate,
      conducted_by: values.conductedBy?.trim() || null,
      notes: values.notes?.trim() || null,
    })
    .eq('id', campEventId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SCREENINGS (the roster within one camp) ──
export async function listScreenings(campEventId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('camp_screenings')
    .select('*, patients:patient_id(id, uhid, first_name, last_name)')
    .eq('camp_event_id', campEventId)
    .order('created_at', { ascending: true });
  if (error) return { error: error.message };
  return { rows: data || [] };
}

// Cheap, fast on-site entry -- a handful of fields, meant to take
// under a minute per person. Anything more detailed happens later,
// only for the subset who actually convert to real patients.
export async function addScreening(campEventId, values) {
  if (!values.fullName?.trim()) return { error: 'Name is required.' };
  if (!values.phone?.trim()) return { error: 'Phone number is required.' };
  const supabase = await createClient();
  const { data: { user } } = await supabase.auth.getUser();
  const { data, error } = await supabase
    .from('camp_screenings')
    .insert({
      camp_event_id: campEventId,
      full_name: values.fullName.trim(),
      phone: values.phone.trim(),
      age: values.age ? parseInt(values.age, 10) : null,
      gender: values.gender || null,
      va_od: values.vaOd?.trim() || null,
      va_os: values.vaOs?.trim() || null,
      finding: values.finding?.trim() || null,
      referral_recommended: !!values.referralRecommended,
      whatsapp_consent: !!values.whatsappConsent,
      created_by: user?.id || null,
    })
    .select('*')
    .single();
  if (error) return { error: error.message };
  return { screening: data };
}

export async function updateScreening(screeningId, values) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('camp_screenings')
    .update({
      full_name: values.fullName?.trim(),
      phone: values.phone?.trim(),
      age: values.age ? parseInt(values.age, 10) : null,
      gender: values.gender || null,
      va_od: values.vaOd?.trim() || null,
      va_os: values.vaOs?.trim() || null,
      finding: values.finding?.trim() || null,
      referral_recommended: !!values.referralRecommended,
      whatsapp_consent: !!values.whatsappConsent,
    })
    .eq('id', screeningId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function deleteScreening(screeningId) {
  const supabase = await createClient();
  const { error } = await supabase.from('camp_screenings').delete().eq('id', screeningId);
  if (error) return { error: error.message };
  return { success: true };
}

// Same duplicate check used at real registration -- surfaced here so
// staff can link to an existing patient instead of creating a
// duplicate record for someone who's already in the system.
export async function checkExistingPatientByPhone(phone) {
  if (!phone || phone.length < 10) return [];
  const supabase = await createClient();
  const { data } = await supabase.from('patients').select('id, uhid, first_name, last_name, mobile, age, gender').eq('mobile', phone.trim());
  return data || [];
}

// Links a screening to a patient who already exists (found via phone
// match) -- no new registration, just the connection.
export async function linkScreeningToPatient(screeningId, patientId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('camp_screenings')
    .update({ patient_id: patientId, converted_at: new Date().toISOString() })
    .eq('id', screeningId);
  if (error) return { error: error.message };
  return { success: true };
}

// Converts a screening into a real patient registration. Runs the
// exact same registerPatient() used at the front desk (UHID
// generation, WhatsApp registration confirmation, everything) --
// values here are pre-filled from the screening but fully editable,
// since camp intake never captures full registration detail.
export async function convertScreeningToPatient(screeningId, values) {
  const regResult = await registerPatient(values);
  if (regResult.error) return regResult;

  const supabase = await createClient();
  const { error } = await supabase
    .from('camp_screenings')
    .update({ patient_id: regResult.patient.id, converted_at: new Date().toISOString() })
    .eq('id', screeningId);
  if (error) {
    // Registration itself succeeded -- don't lose that fact even if
    // the link-back write failed for some reason.
    return { patient: regResult.patient, linkError: error.message };
  }
  return { patient: regResult.patient };
}

// ── WHATSAPP FOLLOW-UP ──
// Uses a dedicated 'camp_screening' template -- separate from the
// registration/appointment/receipt templates already in lib/whatsapp.js
// since this is a business-initiated outreach message with its own
// copy. Meta requires every template to be pre-approved in WhatsApp
// Business Manager before it can actually send; until that approval
// exists, this call will fail cleanly (same error-handling path as
// every other template in lib/whatsapp.js) rather than break anything.
export async function sendCampScreeningWhatsApp(screeningId) {
  const supabase = await createClient();
  const { data: screening, error } = await supabase
    .from('camp_screenings')
    .select('*, camp_events:camp_event_id(name)')
    .eq('id', screeningId)
    .single();
  if (error) return { error: error.message };
  if (!screening.whatsapp_consent) return { error: 'This person did not consent to be contacted on WhatsApp.' };

  const recommendation = screening.referral_recommended
    ? 'Our screening suggests you should visit us for a detailed eye checkup.'
    : 'Your screening did not show any major concerns, but we recommend a routine eye checkup once a year.';

  const result = await sendWhatsAppTemplate({
    to: screening.phone,
    templateName: 'camp_screening',
    bodyParams: [
      { type: 'text', text: screening.full_name || '' },
      { type: 'text', text: screening.camp_events?.name || '' },
      { type: 'text', text: recommendation },
    ],
    meta: { patientId: screening.patient_id || null, module: 'camps' },
  });

  if (result.success) {
    await supabase.from('camp_screenings').update({ whatsapp_sent_at: new Date().toISOString() }).eq('id', screeningId);
  }
  return result;
}

// Sends to everyone in a camp who consented and hasn't been messaged
// yet. Sequential, not Promise.all -- keeps this gentle on the
// WhatsApp API's rate limits for a 50-60 person batch, and one
// person's failure doesn't affect the timing of the others.
export async function bulkSendCampScreeningWhatsApp(campEventId) {
  const supabase = await createClient();
  const { data: screenings, error } = await supabase
    .from('camp_screenings')
    .select('id')
    .eq('camp_event_id', campEventId)
    .eq('whatsapp_consent', true)
    .is('whatsapp_sent_at', null);
  if (error) return { error: error.message };

  let sent = 0;
  let failed = 0;
  const errors = [];
  for (const s of screenings || []) {
    const result = await sendCampScreeningWhatsApp(s.id);
    if (result.success) sent += 1;
    else { failed += 1; errors.push(result.error); }
  }
  return { sent, failed, errors };
}
