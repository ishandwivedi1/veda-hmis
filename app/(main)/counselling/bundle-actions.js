'use server';

// Counselling list bundle (speed-up, 23 Oct 2026): active cases + history
// in ONE request (was 2, on open and after every update). Same functions.
// NOTE: counselling/actions.js itself must never be moved or deleted --
// this file only reads from it.

import { getCounsellingCases, getCounsellingHistory } from './actions';

export async function getCounsellingListsBundle() {
  return Promise.all([getCounsellingCases(), getCounsellingHistory()]);
}
