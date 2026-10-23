'use server';

// Biometry bundles (speed-up, 23 Oct 2026): same functions, run in
// parallel on the server, so each screen loads in ONE request.

import { getBiometryQueue, getBiometryCompletedToday, getBiometryDetail } from './actions';
import { getActiveIolCatalog } from '../master-data/actions';

// Biometry queue + completed today (was 2 requests one after another).
export async function getBiometryQueueBundle() {
  return Promise.all([getBiometryQueue(), getBiometryCompletedToday()]);
}

// Biometry record workspace on open: record + IOL catalog (was 2).
export async function getBiometryWorkspaceBundle(recordId) {
  return Promise.all([getBiometryDetail(recordId), getActiveIolCatalog()]);
}

