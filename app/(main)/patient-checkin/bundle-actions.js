'use server';

// Check-in landing in ONE request: surgery match + patient in parallel on
// the server (was 2 requests). Functions are unchanged.

import { getSurgeryLandingForPatient } from '@/app/(main)/ot-intraop/actions';
import { getPatientById } from '@/app/(main)/visits/actions';
import { getOTCaseList, getCheckinHistory } from '@/app/(main)/ot-intraop/actions';

export async function getCheckinLandingBundle(patientId) {
  return Promise.all([getSurgeryLandingForPatient(patientId), getPatientById(patientId)]);
}

// Whole list screen in ONE request (was 2), refreshed the same way
// after every action. Functions are unchanged.
export async function getCheckinPageBundle() {
  return Promise.all([getOTCaseList(), getCheckinHistory()]);
}
