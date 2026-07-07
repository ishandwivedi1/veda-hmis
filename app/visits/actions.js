'use server';

import { createClient } from '../../lib/supabase-server';

export async function checkInAppointment(appointmentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('check_in_appointment', {
    p_appointment_id: appointmentId,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

export async function createWalkInVisit(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('create_walk_in_visit', {
    p_patient_id: values.patientId,
    p_doctor_id: values.doctorId || null,
    p_visit_type: values.visitType,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

