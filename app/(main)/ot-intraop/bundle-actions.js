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
