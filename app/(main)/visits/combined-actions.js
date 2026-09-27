'use server';

// Combined server calls for Book Visit (speed-up, 27 Sep 2026).
// Next.js runs a page's server actions one at a time, so this wraps the
// SAME existing actions (no query or rule changes) and runs them in
// parallel on the server -- one round trip instead of up to four.

import { getDoctors } from '@/app/(main)/appointments/actions';
import { getSurgeryTypeOptions, getPatientById, getLastVisitInfo } from './actions';

export async function getBookVisitBootstrap(prefillPatientId) {
  const [doctors, surgeryTypes, patient, lastVisitInfo] = await Promise.all([
    getDoctors(),
    getSurgeryTypeOptions(),
    prefillPatientId ? getPatientById(prefillPatientId) : null,
    prefillPatientId ? getLastVisitInfo(prefillPatientId) : null,
  ]);
  return { doctors, surgeryTypes, patient, lastVisitInfo };
}
