'use server';

// One request per click for the doctor's Consultation screen (speed-up,
// 23 Oct 2026).
//
// Before: every save on the screen was two requests in a row -- the save
// itself, then a separate getConsultationData() to redraw the screen.
// Next.js runs a page's server actions one at a time, so the doctor waited
// for both. These wrappers run the SAME existing save (no query or rule
// changes) and hand back the refreshed consultation in the same response.
//
// Only the screen's own save actions are accepted (allow-list below) --
// each of them is already a callable server action in its own right, so
// this grants nothing new.

import * as consult from './actions';
import { markForSurgery, updateSurgicalCase, setDecision, addCaseProcedure, removeCaseProcedure } from '../counselling/actions';
import { markFollowupStatus, addFollowup, closeEpisode } from '../ot-postop/actions';

const SAVES = {
  addDiagnosis: consult.addDiagnosis,
  removeDiagnosis: consult.removeDiagnosis,
  carryForwardDiagnosis: consult.carryForwardDiagnosis,
  addPrescription: consult.addPrescription,
  addTaperedPrescription: consult.addTaperedPrescription,
  removePrescription: consult.removePrescription,
  removeTaperGroup: consult.removeTaperGroup,
  addInvestigation: consult.addInvestigation,
  removeInvestigation: consult.removeInvestigation,
  addOpticalAdvice: consult.addOpticalAdvice,
  removeOpticalAdvice: consult.removeOpticalAdvice,
  addProcedure: consult.addProcedure,
  removeProcedure: consult.removeProcedure,
  addReferral: consult.addReferral,
  removeReferral: consult.removeReferral,
  saveFollowup: consult.saveFollowup,
  completePlanItem: consult.completePlanItem,
  completeWorkflowRequest: consult.completeWorkflowRequest,
  saveExamination: consult.saveExamination,
  updateSurgicalCase,
  setDecision,
  addCaseProcedure,
  removeCaseProcedure,
};

// Runs one save, then -- only if it succeeded -- returns the redrawn
// consultation as `data`. A save that failed or needs the doctor to
// confirm something (e.g. biometry re-order) returns exactly as before,
// with no reload, matching the old screen behaviour.
export async function consultationSave(name, args, queueEntryId) {
  const fn = Object.prototype.hasOwnProperty.call(SAVES, name) ? SAVES[name] : null;
  if (!fn) return { error: 'Unknown action.' };
  const result = (await fn(...(Array.isArray(args) ? args : []))) || {};
  if (result.error || result.needsConfirmation) return result;
  const data = await consult.getConsultationData(queueEntryId);
  return { ...result, data };
}

// "Mark for IPD Procedure" with additional procedures staged before Save.
// Was 2 + N requests (mark, one per extra procedure, then reload); now one.
// Extra procedures are still added one by one, in order, so a failure
// partway through leaves a predictable, reportable set.
export async function markForSurgeryAndReload(queueEntryId, markArgs, pendingProcedures) {
  const result = (await markForSurgery(...(Array.isArray(markArgs) ? markArgs : []))) || {};
  if (result.error) return result;
  const failedProcedures = [];
  for (const p of pendingProcedures || []) {
    const addResult = await addCaseProcedure(result.caseId, p.name, p.eye, p.notes);
    if (addResult?.error) failedProcedures.push(`${p.name} (${addResult.error})`);
  }
  const data = await consult.getConsultationData(queueEntryId);
  return { ...result, failedProcedures, data };
}

// Post-op Review "Finish" buttons. Was 3 requests one after another; now
// one. Same steps in the same order, stopping at the first error:
//   1. mark this follow-up Completed
//   2. 'schedule' -> add the next review   |  'close' -> close the episode
//   3. complete the consultation
export async function finishPostopReview(kind, { followupId, episodeId, encounterId, queueEntryId, nextLabel, nextDate, closure }) {
  let result = (await markFollowupStatus(followupId, 'Completed')) || {};
  if (result.error) return result;
  if (kind === 'schedule') result = (await addFollowup(episodeId, nextLabel, nextDate)) || {};
  else if (kind === 'close') result = (await closeEpisode(episodeId, closure)) || {};
  else return { error: 'Unknown finish type.' };
  if (result.error) return result;
  return (await consult.completeConsultation(encounterId, queueEntryId)) || {};
}
