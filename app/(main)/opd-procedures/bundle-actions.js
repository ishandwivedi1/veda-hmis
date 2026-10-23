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

// ── One request per click (speed-up, 23 Oct 2026) ──
// Each runs one allow-listed save (each already a callable server action)
// and, when it succeeded, returns the refreshed panel in the SAME response.
import * as A from './actions';
const RX_SAVES = ['addPostProcedureMedicine', 'removePostProcedureMedicine', 'addPostProcedureTaperedMedicine', 'removePostProcedureTaperGroup'];
const JOURNEY_SAVES = ['setOpdProcedureDecision', 'scheduleOpdProcedure', 'checkInOpdProcedure', 'completeOpdProcedure', 'updateCompletedProcedureNotes', 'cancelOpdProcedure'];

async function runAllowed(list, name, args) {
  if (!list.includes(name) || typeof A[name] !== 'function') return { error: 'Unknown action.' };
  return (await A[name](...(Array.isArray(args) ? args : []))) || {};
}

// Post-procedure medicines panel: save + refreshed prescriptions/catalog.
export async function opdRxSaveAndReload(name, args, procedureId) {
  const result = await runAllowed(RX_SAVES, name, args);
  if (result.error) return result;
  return { ...result, bundle: await getPostProcedureRxBundle(procedureId) };
}

// Patient journey actions: save + refreshed patient and journey.
export async function opdJourneySaveAndReload(name, args, patientId) {
  const result = await runAllowed(JOURNEY_SAVES, name, args);
  if (result.error) return result;
  return { ...result, bundle: await getOpdPatientJourneyBundle(patientId) };
}
