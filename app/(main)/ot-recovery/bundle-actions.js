'use server';

// Recovery & Discharge list screen bundles.

import { getRecoveryCaseList, getRecoveryHistory, getRecoveryEpisodeDetail, getDrugOptions, getMedDosageOptions } from './actions';

// Whole list screen in ONE request (was 2), refreshed the same way
// after every action. Functions are unchanged.
export async function getRecoveryPageBundle() {
  return Promise.all([getRecoveryCaseList(), getRecoveryHistory()]);
}

// Recovery workspace on open in ONE request (was 3): the episode, drug
// options and dosage options together.
export async function getRecoveryWorkspaceBundle(episodeId) {
  return Promise.all([getRecoveryEpisodeDetail(episodeId), getDrugOptions(), getMedDosageOptions()]);
}
