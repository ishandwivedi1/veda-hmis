'use server';

// Server actions for the "Billing Permissions" tab in User Management.
// Kept in their own file so the existing users/actions.js is untouched.

import { createClient } from '@/lib/supabase-server';
import { requireAdministrator } from '@/lib/adminGuard';
import { BILLING_PERMISSION_KEYS } from '@/lib/billingPermissionDefs';

export async function getBillingPermissionMatrix() {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  const supabase = await createClient();
  const [{ data: rows, error }, { data: history }] = await Promise.all([
    supabase.from('billing_permissions').select('designation, permission, allowed, updated_at'),
    supabase
      .from('billing_audit_log')
      .select('id, entity_ref, action, changed_at, changed_by')
      .eq('entity_type', 'permission')
      .order('changed_at', { ascending: false })
      .limit(20),
  ]);
  if (error) return { error: error.message };

  const ids = [...new Set((history || []).map((h) => h.changed_by).filter(Boolean))];
  let names = {};
  if (ids.length) {
    const { data: people } = await supabase.from('profiles').select('id, full_name').in('id', ids);
    names = Object.fromEntries((people || []).map((p) => [p.id, p.full_name]));
  }

  const matrix = {};
  for (const r of rows || []) {
    matrix[r.designation] = matrix[r.designation] || {};
    matrix[r.designation][r.permission] = !!r.allowed;
  }

  return {
    matrix,
    history: (history || []).map((h) => ({ ...h, changed_by_name: names[h.changed_by] || 'Unknown' })),
  };
}

export async function setBillingPermission(designation, permission, allowed) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };
  if (!BILLING_PERMISSION_KEYS.includes(permission)) return { error: 'Unknown permission.' };
  if (!designation || designation === 'Administrator') {
    return { error: 'Administrators always have every billing permission.' };
  }

  const supabase = await createClient();
  const { error } = await supabase.rpc('set_billing_permission', {
    p_designation: designation,
    p_permission: permission,
    p_allowed: !!allowed,
  });
  if (error) return { error: error.message };
  return { ok: true };
}
