'use server';

// Post-op list screen bundles.

import { getPostOpCaseList, getPostOpTurnedUpToday, getPostOpHistory, getPostOpEpisodeDetail } from './actions';
import { getAttachments } from '@/lib/attachments';

// Whole list screen in ONE request (was 3), refreshed the same way
// after every action. Functions are unchanged.
export async function getPostOpPageBundle() {
  return Promise.all([getPostOpCaseList(), getPostOpTurnedUpToday(), getPostOpHistory()]);
}

// Post-op workspace in ONE request: the episode plus every follow-up's
// attachments. Was 1 + one queued request per follow-up visit (attachment
// loads are server actions, which Next.js runs one at a time).
export async function getPostOpWorkspaceBundle(episodeId) {
  const detail = await getPostOpEpisodeDetail(episodeId);
  if (detail?.error || !(detail?.followups?.length > 0)) return { detail, attachmentsByFollowup: null };
  const entries = await Promise.all(detail.followups.map(async (f) => [f.id, await getAttachments('postop_followup', f.id)]));
  return { detail, attachmentsByFollowup: Object.fromEntries(entries) };
}

// ── One request per click in the Post-op workspace ──
// Runs one allow-listed save (each already a callable server action) and,
// when it succeeded, returns the refreshed episode + attachments in the
// SAME response instead of a second reload request.
import * as A from './actions';
const POSTOP_SAVES = ['saveFollowupNotes', 'rescheduleFollowup', 'markFollowupStatus', 'addRecoveryComplication', 'addFollowup', 'removeFollowup', 'closeEpisode'];
export async function postopSaveAndReload(name, args, episodeId) {
  if (!POSTOP_SAVES.includes(name) || typeof A[name] !== 'function') return { error: 'Unknown action.' };
  const result = (await A[name](...(Array.isArray(args) ? args : []))) || {};
  if (result.error) return result;
  return { ...result, bundle: await getPostOpWorkspaceBundle(episodeId) };
}
