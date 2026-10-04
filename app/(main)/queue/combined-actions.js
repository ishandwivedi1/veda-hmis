'use server';

// Patient Flow's ONE request (refreshed every 15s): the board and the
// call-next queues together, run in parallel on the server, instead of
// two requests per refresh. Both functions are unchanged.

import { getPatientFlow, getQueues } from './actions';

export async function getPatientFlowBundle() {
  const [flow, queues] = await Promise.all([getPatientFlow(), getQueues()]);
  return { flow, queues };
}
