'use server';

import { createClient } from '@/lib/supabase-server';

// Shared by every payment-collection action that supports backdating
// (Optical payment/advance, hospital Payments payment/advance). Kept
// as one module so the rule is enforced identically everywhere rather
// than reimplemented per-module -- Administrator only, a mandatory
// reason, and the target day must not currently be closed (an
// Administrator has to explicitly Reopen it first via Cash Management
// -- see cash-management/actions.js reopenDay), since a closed day's
// reconciliation is a frozen, signed-off snapshot that must never
// silently drift out from under it.

async function requireAdministrator() {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return { ok: false, error: 'Not signed in.' };
  const { data: me } = await supabase.from('profiles').select('id, full_name, designation').eq('id', userData.user.id).maybeSingle();
  if (me?.designation !== 'Administrator') {
    return { ok: false, error: 'Only an Administrator can enter a backdated payment.' };
  }
  return { ok: true, adminId: me.id, adminName: me.full_name };
}

// Called by a collection action BEFORE it invokes its RPC. Returns
// either { collectedAt: null } (no backdating requested -- proceed
// exactly as before) or { collectedAt, adminId } to pass through as
// the RPC's p_collected_at, or { error } to return to the caller
// unchanged. The RPC itself also re-checks the target day isn't closed
// (belt-and-suspenders against a day closing in the moment between
// this check and the insert), but this is what produces the specific,
// actionable "reopen it first" message.
export async function resolveBackdatedCollection({ backdateTo, reason }) {
  if (!backdateTo) return { collectedAt: null };

  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  if (!reason || !reason.trim()) {
    return { error: 'A reason is required for a backdated entry.' };
  }

  const collectedAt = new Date(backdateTo);
  if (Number.isNaN(collectedAt.getTime())) {
    return { error: 'Invalid backdated date/time.' };
  }
  if (collectedAt.getTime() > Date.now()) {
    return { error: "A backdated entry can't be dated in the future." };
  }

  const targetDate = collectedAt.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const supabase = await createClient();
  const { data: closing } = await supabase.from('day_closings').select('id').eq('closing_date', targetDate).maybeSingle();
  if (closing) {
    return { error: `${targetDate} is already closed. Reopen it from Cash Management (Reconciliation & Close Day tab) before adding a backdated entry.` };
  }

  return { collectedAt: collectedAt.toISOString(), adminId: gate.adminId };
}

// Called by the collection action AFTER its RPC succeeds, only when
// collectedAt was actually backdated. entryId/amount come from the
// RPC's own return value, so this always logs what was truly written,
// not what was requested.
export async function logBackdatedEntry({ module, entryTable, entryId, backdatedTo, reason, adminId, amount }) {
  const supabase = await createClient();
  await supabase.from('backdated_entry_log').insert({
    module, entry_table: entryTable, entry_id: entryId, backdated_to: backdatedTo, reason, admin_id: adminId, amount,
  });
}
