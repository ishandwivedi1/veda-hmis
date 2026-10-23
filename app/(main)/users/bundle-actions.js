'use server';

// User Management on open in ONE request (was 2, one after another):
// my designation, plus the user list only for an Administrator (getUsers
// enforces that itself as well).

import { getMyDesignation, getUsers } from './actions';

export async function getUsersPageBundle() {
  const designation = await getMyDesignation();
  const users = designation === 'Administrator' ? await getUsers() : null;
  return { designation, users };
}
