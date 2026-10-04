'use server';

// Surgeon Dashboard's ONE request (refreshed every 15s). It used to send
// 8 separate requests per refresh -- 8 server calls every 15 seconds for
// every open dashboard. The same 8 reads now run in parallel on the
// server inside a single request; each function is unchanged.

import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardDischargedToday } from './actions';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { getPostOpTurnedUpToday } from '@/app/(main)/ot-postop/actions';
import { getSurgicalCaseLists, getSurgicalEvaluationArrivalsToday } from '@/app/(main)/surgical-journey/actions';
import { getMedicalFitnessQueue } from '@/app/(main)/medical-fitness/actions';

export async function getSurgeryDashboardBundle() {
  return Promise.all([
    getSurgeryDashboardScheduled(),
    getSurgeryDashboardActive(),
    getSurgeryDashboardDischargedToday(),
    getPendingIolApprovals(),
    getPostOpTurnedUpToday(),
    getSurgicalCaseLists(),
    getMedicalFitnessQueue(),
    getSurgicalEvaluationArrivalsToday(),
  ]);
}
