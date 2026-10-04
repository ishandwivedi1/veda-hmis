'use server';

// Today's OT list in ONE request: scheduled + OT history run in parallel
// on the server (was 2 requests). Used by OT Schedule and Surgical
// Workflow. Functions are unchanged.

import { getScheduledOT, getOTHistory } from './actions';

export async function getOTListBundle() {
  return Promise.all([getScheduledOT(), getOTHistory()]);
}
