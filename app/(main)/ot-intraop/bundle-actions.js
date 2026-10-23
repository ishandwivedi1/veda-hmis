'use server';

// Intra-operative list screen bundles.

import { getOTCaseList, getOTIntraopHistory, getOTCaseDetail, getConsumableOptions } from './actions';
import { getActiveIolCatalog } from '../master-data/actions';

// Whole list screen in ONE request (was 2), refreshed the same way
// after every action. Functions are unchanged.
export async function getIntraopPageBundle() {
  return Promise.all([getOTCaseList(), getOTIntraopHistory()]);
}

// Intra-op / Check-in workspace on open in ONE request (was 3): the case,
// consumable options and the active IOL catalog together.
export async function getIntraopWorkspaceBundle(otScheduleId) {
  return Promise.all([getOTCaseDetail(otScheduleId), getConsumableOptions(), getActiveIolCatalog()]);
}

// ── One request per click in the Check-in / Intra-op workspace ──
// Runs one allow-listed save (each already a callable server action) and,
// when it succeeded, returns the refreshed case as `data` in the SAME
// response instead of the screen making a second request to reload.
// `reload: false` is used when the tab is about to close anyway.
import * as A from './actions';
const INTRAOP_SAVES = [
  'completeCheckin', 'recordAnaesthesia', 'saveCheckinIolVerification', 'saveIntraopDraft',
  'addConsumable', 'removeConsumable', 'addIntraopEvent', 'removeIntraopEvent',
  'completeSurgery', 'markPatientReported', 'unmarkPatientReported',
];
export async function intraopSaveAndReload(name, args, otScheduleId, reload = true) {
  if (!INTRAOP_SAVES.includes(name) || typeof A[name] !== 'function') return { error: 'Unknown action.' };
  const result = (await A[name](...(Array.isArray(args) ? args : []))) || {};
  const needsInput = Object.keys(result).some((k) => k.startsWith('needs'));
  if (!reload || result.error || needsInput) return result;
  return { ...result, data: await getOTCaseDetail(otScheduleId) };
}
