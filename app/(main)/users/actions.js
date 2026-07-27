'use server';

import { createClient } from '@/lib/supabase-server';
import { createAdminClient } from '@/lib/supabase-admin';

export async function getUsers() {
  const supabase = await createClient();
  const { data, error } = await supabase.from('profiles').select('*').order('full_name');
  if (error) return [];
  return data;
}

export async function createUser(values) {
  if (!values.email || !values.password || !values.fullName) {
    return { error: 'Email, password, and name are required.' };
  }
  if (values.password.length < 6) {
    return { error: 'Password must be at least 6 characters.' };
  }

  const admin = createAdminClient();

  const { data, error } = await admin.auth.admin.createUser({
    email: values.email,
    password: values.password,
    email_confirm: true, // skip email verification -- an admin is creating this directly
    user_metadata: {
      full_name: values.fullName,
      designation: values.designation,
      department: values.department,
    },
  });

  if (error) return { error: error.message };
  return { success: true, user: data.user };
}

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

// Designation/department can be corrected after account creation -- e.g.
// a login was created before a role was finalized, or someone moves
// department. Name changes and login/email changes stay out of scope
// here since they're tied to the auth identity.
export async function updateUserProfile(userId, values) {
  if (values.designation && !DESIGNATIONS.includes(values.designation)) {
    return { error: 'Invalid designation.' };
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from('profiles')
    .update({
      designation: values.designation || null,
      department: values.department || null,
    })
    .eq('id', userId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function toggleUserStatus(userId, currentStatus) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from('profiles').update({ status: newStatus }).eq('id', userId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetUserPassword(userId, newPassword) {
  if (!newPassword || newPassword.length < 6) {
    return { error: 'New password must be at least 6 characters.' };
  }
  const admin = createAdminClient();
  const { error } = await admin.auth.admin.updateUserById(userId, { password: newPassword });
  if (error) return { error: error.message };
  return { success: true };
}

