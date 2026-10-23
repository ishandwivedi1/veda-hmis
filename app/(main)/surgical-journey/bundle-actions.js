'use server';

// Surgical Workflow case list in ONE request: cases + today's arrivals in
// parallel on the server (was 2 requests). Functions are unchanged.

import { getSurgicalCaseLists, getSurgicalTrackArrivalsToday, getDischargedTodaySurgicalCases, getCompletedSurgicalCases } from './actions';
import { getOTListBundle } from '../ot-schedule/bundle-actions';

export async function getSurgicalCasesBundle() {
  return Promise.all([getSurgicalCaseLists(), getSurgicalTrackArrivalsToday()]);
}

// Whole Surgical Journey screen on open in ONE request (was 4): case
// lists + arrivals, discharged today, history, and today's OT list.
export async function getSurgicalJourneyPageBundle() {
  return Promise.all([
    getSurgicalCasesBundle(),
    getDischargedTodaySurgicalCases(),
    getCompletedSurgicalCases(),
    getOTListBundle(),
  ]);
}
