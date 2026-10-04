'use server';

// Master lists a screen needs on open, in ONE request (run in parallel on
// the server) instead of one request per list. Functions are unchanged.

import { getDiagnosesMaster, getDrugs, getServices, getSurgeries, getDosageOptions, getActivePatientInstructionTemplates } from './actions';

// Doctor consultation form: was 6 requests on every open.
export async function getConsultationMastersBundle() {
  return Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getSurgeries(), getDosageOptions(), getActivePatientInstructionTemplates()]);
}

// Post-op review form: was 2 requests on every open.
export async function getPostopReviewMastersBundle() {
  return Promise.all([getDrugs(), getDosageOptions()]);
}
