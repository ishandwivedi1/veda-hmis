'use server';

// IOL Approval queue's ONE request (refreshed every 15s): pending and
// approved-today together, run in parallel on the server, instead of two
// requests per refresh. Both functions are unchanged.

import { getPendingIolApprovals, getApprovedToday } from './actions';

export async function getIolApprovalQueueBundle() {
  const [pending, approvedToday] = await Promise.all([getPendingIolApprovals(), getApprovedToday()]);
  return { pending, approvedToday };
}
