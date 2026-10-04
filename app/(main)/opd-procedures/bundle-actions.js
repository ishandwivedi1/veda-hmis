'use server';

// OPD Procedures workspace loads in ONE request each (were 2 each).
// Functions are unchanged.

import { getPatientOpdProcedureJourney, getPostProcedurePrescriptions, getDrugCatalogForOpdProcedures } from './actions';
import { getPatientById } from '@/app/(main)/visits/actions';

export async function getOpdPatientJourneyBundle(patientId) {
  return Promise.all([getPatientById(patientId), getPatientOpdProcedureJourney(patientId)]);
}

export async function getPostProcedureRxBundle(procedureId) {
  return Promise.all([getPostProcedurePrescriptions(procedureId), getDrugCatalogForOpdProcedures()]);
}
