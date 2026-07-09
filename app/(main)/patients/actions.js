'use server';

import { createClient } from '@/lib/supabase-server';
import { createWalkInVisit } from '@/app/(main)/visits/actions';

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
  });

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
  const { data } = await supabase.from('patients').select('id, uhid, first_name, last_name, mobile, age, gender').eq('mobile', mobile);
  return data || [];
}

// Register a patient and immediately open a visit for them in one step --
// matches M04's "Register & create visit" button.
export async function registerAndCreateVisit(values) {
  const regResult = await registerPatient(values);
  if (regResult.error) return regResult;

  const visitResult = await createWalkInVisit({
    patientId: regResult.patient.id,
    doctorId: null,
    visitType: 'New Consultation',
  });

  if (visitResult.error) {
    // Registration succeeded even though the visit failed -- return both
    // pieces of information so the UI can be honest about what happened.
    return { patient: regResult.patient, visitError: visitResult.error };
  }

  return { patient: regResult.patient, visit: visitResult.visit };
}

