'use server';

import { createClient } from '@/lib/supabase-server';

// Shared by every server action that's restricted to Administrators
// (payment backdating, payment amount correction, User Management).
// Checked server-side always -- callable directly, so hiding a button
// in the UI is never sufficient on its own.
export async function requireAdministrator() {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return { ok: false, error: 'Not signed in.' };
  const { data: me } = await supabase.from('profiles').select('id, full_name, designation').eq('id', userData.user.id).maybeSingle();
  if (me?.designation !== 'Administrator') {
    return { ok: false, error: 'Only an Administrator can do this.' };
  }
  return { ok: true, adminId: me.id, adminName: me.full_name };
}
