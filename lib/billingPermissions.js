// Server-side helper (not a server action) -- import from 'use server'
// files. Returns which billing edit rights the signed-in user has, e.g.
// { 'invoice.edit': true, 'invoice.void': false, ... }.
//
// This only decides what the UI shows. The real boundary is in Postgres:
// every edit/void/delete function calls assert_billing_edit_allowed()
// before changing anything, so a hidden button being bypassed changes
// nothing.

import { createClient } from '@/lib/supabase-server';
import { BILLING_PERMISSION_KEYS } from '@/lib/billingPermissionDefs';

export async function getMyBillingPermissions(existingClient) {
  const none = Object.fromEntries(BILLING_PERMISSION_KEYS.map((k) => [k, false]));
  const supabase = existingClient || await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return none;

  const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
  if (!me?.designation) return none;
  if (me.designation === 'Administrator') {
    return Object.fromEntries(BILLING_PERMISSION_KEYS.map((k) => [k, true]));
  }

  const { data: rows } = await supabase
    .from('billing_permissions')
    .select('permission, allowed')
    .eq('designation', me.designation);

  const result = { ...none };
  for (const r of rows || []) {
    if (r.permission in result) result[r.permission] = !!r.allowed;
  }
  return result;
}
