'use server';

import { after } from 'next/server';
import { redirect } from 'next/navigation';
import { formatPatientName } from '@/lib/patientName';
import { createClient } from '@/lib/supabase-server';
import { getCurrentUserId } from '@/lib/authUser';
import { createWalkInVisit } from '@/app/(main)/visits/actions';
import { linkPatientToAppointment } from '@/app/(main)/appointments/actions';
import { sendRegistrationWhatsApp, sendReviewRequestWhatsApp } from '@/lib/whatsapp';

export async function registerPatient(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('register_patient', {
    p_first_name: values.firstName,
    p_last_name: values.lastName,
    p_age: values.age ? parseInt(values.age, 10) : null,
    p_gender: values.gender,
    p_mobile: values.mobile,
    p_address: values.address || null,
    p_blood_group: values.bloodGroup || null,
    p_date_of_birth: values.dateOfBirth || null,
    p_alternate_mobile: values.alternateMobile || null,
    p_city: values.city || null,
    p_state: values.state || null,
    p_pin_code: values.pinCode || null,
    p_id_type: values.idType || null,
    p_id_number: values.idNumber || null,
    p_insurance_scheme: values.insuranceScheme || null,
    p_insurance_number: values.insuranceNumber || null,
    p_referral_source: values.referralSource || null,
    p_preferred_language: values.preferredLanguage || null,
    p_remarks: values.remarks || null,
    p_salutation: values.salutation || null,
  });

  if (error) {
    // Logged as a separate, independent write -- persists regardless
    // of the RPC's own transaction rolling back. Gives every failed
    // attempt a record on file, so any future UHID gap (the advisory
    // lock in register_patient prevents most, but not literally every
    // possible failure mode, e.g. a mid-transaction server crash) has
    // an explanation instead of being a mystery.
    try {
      const user = { id: await getCurrentUserId(supabase) }; // local check, no Auth round trip
      await supabase.from('registration_attempt_log').insert({
        error_message: error.message,
        input_first_name: values.firstName || null,
        input_last_name: values.lastName || null,
        input_mobile: values.mobile || null,
        attempted_by: user?.id || null,
      });
    } catch (logErr) {
      console.error('Failed to log registration attempt:', logErr.message);
    }
    return { error: error.message };
  }

  // Deferred: the WhatsApp registration confirmation never blocks or
  // fails registration. Previously this was awaited inline (comment said
  // "fire-and-forget" but it wasn't) -- after() makes that true, so
  // registration returns immediately and the message sends afterward.
  const user = { id: await getCurrentUserId(supabase) }; // local check, no Auth round trip
  const triggeredBy = user?.id || null;
  after(async () => {
    try {
      await sendRegistrationWhatsApp({
        name: `${formatPatientName(data)}`.trim(),
        patientUhid: data.uhid,
        patientDbId: data.id,
        mobile: data.mobile,
        meta: { triggeredBy },
      });
    } catch (waErr) {
      console.error('WhatsApp registration send failed:', waErr.message);
    }
  });

  return { patient: data };
}

// Resend the registration WhatsApp confirmation for an existing patient --
// used by the "Resend WhatsApp confirmation" button on the edit page, e.g.
// if the automatic send failed or the mobile number was corrected since.
export async function resendRegistrationWhatsApp(patientId) {
  if (!patientId) return { error: 'Missing patient id.' };

  const supabase = await createClient();
  const { data: patient, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, salutation, last_name, mobile')
    .eq('id', patientId)
    .single();

  if (error) return { error: error.message };
  if (!patient.mobile) return { error: 'This patient has no mobile number on file.' };

  const user = { id: await getCurrentUserId(supabase) }; // local check, no Auth round trip
  const whatsapp = await sendRegistrationWhatsApp({
    name: `${formatPatientName(patient)}`.trim(),
    patientUhid: patient.uhid,
    patientDbId: patient.id,
    mobile: patient.mobile,
    meta: { triggeredBy: user?.id || null },
  });

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

// Edit an existing patient's demographic/contact record. UHID is
// immutable and never touched here -- only the fields collected at
// registration can be corrected later.
export async function updatePatient(patientId, values) {
  if (!patientId) return { error: 'Missing patient id.' };

  const supabase = await createClient();

  if (values.mobile && !/^\d{10}$/.test(values.mobile)) {
    return { error: 'Mobile number must be 10 digits.' };
  }

  const { data, error } = await supabase
    .from('patients')
    .update({
      first_name: values.firstName,
      last_name: values.lastName,
      age: values.age ? parseInt(values.age, 10) : null,
      gender: values.gender,
      mobile: values.mobile,
      address: values.address || null,
      blood_group: values.bloodGroup || null,
      date_of_birth: values.dateOfBirth || null,
      alternate_mobile: values.alternateMobile || null,
      city: values.city || null,
      state: values.state || null,
      pin_code: values.pinCode || null,
      id_type: values.idType || null,
      id_number: values.idNumber || null,
      insurance_scheme: values.insuranceScheme || null,
      insurance_number: values.insuranceNumber || null,
      referral_source: values.referralSource || null,
      preferred_language: values.preferredLanguage || null,
      remarks: values.remarks || null,
      salutation: values.salutation || null,
    })
    .eq('id', patientId)
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }

  return { patient: data };
}

// Real-time duplicate check as the receptionist types a mobile number --
// matches M04's "Duplicate check" panel.
export async function checkDuplicateMobile(mobile) {
  if (!mobile || mobile.length < 10) return [];
  const supabase = await createClient();
  const { data } = await supabase.from('patients').select('id, uhid, first_name, salutation, last_name, mobile, age, gender').eq('mobile', mobile);
  return data || [];
}

// Same check as a parallel read (/api/rpc): a server action makes every
// other click on the page wait until it finishes (Next.js runs a page's
// server actions one at a time), so typing the mobile and pressing
// Register straight away used to queue Register behind this check.
export async function getDuplicatesByMobile(mobile) {
  return checkDuplicateMobile(mobile);
}

// Register a patient and immediately open a visit for them in one step --
// matches M04's "Register & create visit" button.
// Same default-doctor rule as createWalkInVisit (visits/actions.js).
async function getDefaultVisitDoctor() {
  try {
    const supabase = await createClient();
    const { data } = await supabase.from('profiles').select('id, full_name')
      .eq('designation', 'Doctor').eq('status', 'Active').ilike('full_name', '%nisha bachkheti%')
      .limit(1).maybeSingle();
    return data || null;
  } catch {
    return null;
  }
}

export async function registerAndCreateVisit(values) {
  // The default doctor (same one createWalkInVisit falls back to) is looked
  // up WHILE the patient is being registered, and its name is reused for
  // the popup -- was 2 extra queries one after another.
  const [regResult, defaultDoctor] = await Promise.all([registerPatient(values), getDefaultVisitDoctor()]);
  if (regResult.error) return regResult;

  const visitResult = await createWalkInVisit({
    patientId: regResult.patient.id,
    doctorId: defaultDoctor?.id || null,
    visitType: 'New Consultation',
  });

  if (visitResult.error) {
    // Registration succeeded even though the visit failed -- return both
    // pieces of information so the UI can be honest about what happened.
    return { patient: regResult.patient, visitError: visitResult.error };
  }

  // Attach the assigned doctor's name so the success popup can show it
  // -- createWalkInVisit now defaults this to Dr. Nisha Bachkheti when
  // none is given (previously this call passed doctorId: null with no
  // fallback, which left the OPD Case Sheet's doctor name blank at
  // print time). Surfacing it here means front-desk sees it was
  // actually assigned, right in the same popup, instead of only
  // discovering it later on a printout.
  let doctorName = null;
  if (visitResult.visit?.doctor_id) {
    if (defaultDoctor && visitResult.visit.doctor_id === defaultDoctor.id) {
      doctorName = defaultDoctor.full_name || null;
    } else {
      const supabase = await createClient();
      const { data: doctor } = await supabase.from('profiles').select('full_name').eq('id', visitResult.visit.doctor_id).maybeSingle();
      doctorName = doctor?.full_name || null;
    }
  }

  return { patient: regResult.patient, visit: { ...visitResult.visit, doctor_name: doctorName } };
}

// Register a patient and open an "In House Camp" visit in one step --
// used by the Patient Registration page's "Register and Create Inhouse
// Camp Visit" button, for an on-site camp held at the hospital itself
// (distinct from the outreach camps module in app/(main)/camps, which
// runs off-site and only converts to a real patient afterward). This
// visit type carries no consultation charge -- create_walk_in_visit
// routes it through the normal Optometry queue like any other OPD
// visit (only Surgery/Investigation Only/Surgery Evaluation/OPD
// Procedure Only get special routing there), so the patient is still
// seen by the doctor, just without a fee attached to the visit.
export async function registerAndCreateInhouseCampVisit(values) {
  const regResult = await registerPatient(values);
  if (regResult.error) return regResult;

  const visitResult = await createWalkInVisit({
    patientId: regResult.patient.id,
    doctorId: null,
    visitType: 'In House Camp',
    referralSource: 'In House Camp',
  });

  if (visitResult.error) {
    return { patient: regResult.patient, visitError: visitResult.error };
  }

  return { patient: regResult.patient, visit: visitResult.visit };
}

// Patient-level equivalent of sendReviewRequestForVisit in
// visits/actions.js -- manual, entirely staff-initiated, not tied to
// any specific visit. Lives here (not visits/actions.js) since it's
// meant to be sent from a patient's own record (Clinical Timeline),
// e.g. for a patient staff remembers was especially happy, days or
// weeks after whichever visit prompted it.
export async function sendReviewRequestForPatient(patientId) {
  if (!patientId) return { error: 'Missing patient id.' };

  const supabase = await createClient();
  const { data: patient, error } = await supabase
    .from('patients')
    .select('id, first_name, mobile')
    .eq('id', patientId)
    .single();

  if (error) return { error: error.message };
  if (!patient) return { error: 'Patient not found.' };
  if (!patient.mobile) return { error: 'Patient has no mobile number on file.' };

  const user = { id: await getCurrentUserId(supabase) }; // local check, no Auth round trip
  const whatsapp = await sendReviewRequestWhatsApp({
    firstName: patient.first_name,
    mobile: patient.mobile,
    patientId: patient.id,
    meta: { module: 'patient-review-request', triggeredBy: user?.id || null },
  });

  if (!whatsapp.success) return { error: whatsapp.error || 'Failed to send WhatsApp message.' };
  if (whatsapp.logError) return { success: true, warning: `Message sent, but audit logging failed: ${whatsapp.logError}` };
  return { success: true };
}

// ── One-request buttons for the Registration and Edit Patient screens ──
// Each does the same work as before and then sends back the next screen in
// the SAME response via redirect(), instead of the screen waiting for the
// save and then making another request to open the next page. On an error
// they return { error } exactly like the functions they wrap.

// "Register" -> Front Office Dashboard ("Registered successfully -- UHID").
export async function registerAndOpenDashboard(values) {
  const result = await registerPatient(values);
  if (result.error) return result;
  redirect(`/front-office-dashboard?registered=${encodeURIComponent(result.patient.uhid)}`);
}

// Registering someone who had booked an appointment without being
// registered: register + link to the appointment in ONE request (was two
// requests one after the other, then a third to open the dashboard).
export async function registerLinkAppointmentAndOpenDashboard(values, appointmentId) {
  const result = await registerPatient(values);
  if (result.error) return result;
  const linkResult = await linkPatientToAppointment(appointmentId, result.patient.id);
  if (linkResult.error) {
    return { error: `Patient registered (UHID: ${result.patient.uhid}), but linking to the appointment failed: ${linkResult.error}` };
  }
  redirect('/front-office-dashboard?linked=1');
}

// "Register and Create Inhouse Camp Visit" -> straight back to a blank
// registration form for the next person (same as before).
export async function registerInhouseCampAndNext(values) {
  const result = await registerAndCreateInhouseCampVisit(values);
  if (result.error) return result;
  if (result.visitError) {
    return { error: `Patient registered (UHID: ${result.patient.uhid}), but creating the camp visit failed: ${result.visitError}` };
  }
  redirect(`/patients/new?campRegistered=${encodeURIComponent(result.patient.uhid)}`);
}

// Edit Patient "Save" -> back to the Patients list.
export async function updatePatientAndOpenList(patientId, values) {
  const result = await updatePatient(patientId, values);
  if (result.error) return result;
  redirect('/patients');
}
