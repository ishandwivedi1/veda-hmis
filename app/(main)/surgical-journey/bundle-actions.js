'use server';

// Surgical Workflow case list in ONE request: cases + today's arrivals in
// parallel on the server (was 2 requests). Functions are unchanged.

import { getSurgicalCaseLists, getSurgicalTrackArrivalsToday } from './actions';

export async function getSurgicalCasesBundle() {
  return Promise.all([getSurgicalCaseLists(), getSurgicalTrackArrivalsToday()]);
}
