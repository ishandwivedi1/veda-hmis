'use server';

// Camp screen in ONE request: camp + screenings in parallel on the server
// (was 2 requests). Functions are unchanged.

import { getCampEvent, listScreenings } from './actions';

export async function getCampBundle(campEventId) {
  return Promise.all([getCampEvent(campEventId), listScreenings(campEventId)]);
}
