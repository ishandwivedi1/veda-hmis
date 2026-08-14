// Shared server-side authorization helpers -- 'use server' files import
// this directly (it is not itself a server action, just a plain async
// helper function).
//
// isCurrentUserAdmin() answers "is the signed-in staff member an
// Administrator?" for gating anything Administrator-only in the app
// layer (audit logs, etc). This is a UX/defense-in-depth check, not the
// real security boundary -- the actual boundary is enforced by Postgres
// RLS policies on the underlying tables (e.g. audit log tables only
// allow SELECT to Administrators). Even if this check were skipped or
// bypassed, a non-admin's query would still come back empty at the
// database level.

import { createClient } from '@/lib/supabase-server';

export async function isCurrentUserAdmin(existingClient) {
  const supabase = existingClient || await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return false;
  const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
  return me?.designation === 'Administrator';
}
