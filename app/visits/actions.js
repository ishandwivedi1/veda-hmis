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

  const { data, error } = await supabase
    .from('visits')
    .insert({
      patient_id: values.patientId,
      doctor_id: values.doctorId || null,
      visit_type: values.visitType,
      status: 'Open',
    })
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

