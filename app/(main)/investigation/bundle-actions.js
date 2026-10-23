'use server';

// Investigation queue bundle (speed-up, 23 Oct 2026): queue + today's
// investigations in ONE request (was 2, one after another). Same functions.

import { getInvestigationQueue, getTodaysInvestigations } from './actions';

export async function getInvestigationQueueBundle() {
  return Promise.all([getInvestigationQueue(), getTodaysInvestigations()]);
}
