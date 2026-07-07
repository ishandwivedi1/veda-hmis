'use server';

import { createClient } from '../../lib/supabase-server';

export async function searchPatientsForBooking(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);

  if (error) return [];
  return data;
}

export async function getDoctors() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name, designation')
    .ilike('designation', '%ophthalmologist%')
    .eq('status', 'Active');

  if (error) return [];
  return data;
}

export async function linkPatientToAppointment(appointmentId, patientId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('appointments')
    .update({ patient_id: patientId, patient_name_temp: null, mobile_temp: null })
    .eq('id', appointmentId);

  if (error) return { error: error.message };
  return { success: true };
}

export async function createAppointment(values) {
  const supabase = await createClient();

  const payload = {
    patient_id: values.patientId || null,
    patient_name_temp: values.patientId ? null : values.patientName,
    mobile_temp: values.patientId ? null : values.mobile,
    doctor_id: values.doctorId || null,
    appointment_date: values.date,
    appointment_time: values.time,
    visit_type: values.visitType,
    remarks: values.remarks || null,
  };

  const { data, error } = await supabase
    .from('appointments')
    .insert(payload)
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }

  return { appointment: data };
}

