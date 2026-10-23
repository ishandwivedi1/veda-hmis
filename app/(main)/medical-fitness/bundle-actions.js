'use server';

// Medical Fitness bundles (speed-up, 23 Oct 2026). Same functions, run in
// parallel on the server, so each screen opens in ONE request.

import { getMedicalFitnessQueue, getMedicalFitnessClearedToday, getMedicalFitnessHistory, getMedicalFitnessDetail, getInvestigationMasterOptions, getCurrentDoctorProfile } from './actions';

// Queue + Cleared Today + History (was 3 requests, on open and after each decision).
export async function getMedicalFitnessListsBundle() {
  return Promise.all([getMedicalFitnessQueue(), getMedicalFitnessClearedToday(), getMedicalFitnessHistory()]);
}

// Referral workspace: detail + investigation options + doctor profile (was 3).
export async function getMedicalFitnessWorkspaceBundle(referralId) {
  return Promise.all([getMedicalFitnessDetail(referralId), getInvestigationMasterOptions(), getCurrentDoctorProfile()]);
}
