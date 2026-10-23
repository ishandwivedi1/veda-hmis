'use server';

// Today's OT list in ONE request: scheduled + OT history run in parallel
// on the server (was 2 requests). Used by OT Schedule and Surgical
// Workflow. Functions are unchanged.

import { getScheduledOT, getOTHistory, getSurgeonsForDirectSurgery, getPackagesForDirectSurgery } from './actions';
import { getSurgeries } from '../master-data/actions';

export async function getOTListBundle() {
  return Promise.all([getScheduledOT(), getOTHistory()]);
}

// "Register surgery directly" form lists in ONE request (was 3).
export async function getDirectSurgeryFormBundle() {
  return Promise.all([getSurgeries(), getSurgeonsForDirectSurgery(), getPackagesForDirectSurgery()]);
}
