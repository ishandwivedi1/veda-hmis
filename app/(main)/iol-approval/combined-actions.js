'use server';

// IOL Approval queue's ONE request (refreshed every 15s): pending and
// approved-today together, run in parallel on the server, instead of two
// requests per refresh. Both functions are unchanged.

import { getPendingIolApprovals, getApprovedToday, getIolApprovalDetail } from './actions';
import { getActiveIolCatalog } from '../master-data/actions';

export async function getIolApprovalQueueBundle() {
  const [pending, approvedToday] = await Promise.all([getPendingIolApprovals(), getApprovedToday()]);
  return { pending, approvedToday };
}

// IOL approval detail on open: the case + active IOL catalog in ONE
// request (was 2). Both functions are unchanged.
export async function getIolApprovalDetailBundle(caseId) {
  return Promise.all([getIolApprovalDetail(caseId), getActiveIolCatalog()]);
}
