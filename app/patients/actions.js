'use server';

import { createClient } from '../../lib/supabase-server';

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
  });

  if (error) {
    return { error: error.message };
  }

  return { patient: data };
}

