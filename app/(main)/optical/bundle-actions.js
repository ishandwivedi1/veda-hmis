'use server';

// Optical tab openers (speed-up, 23 Oct 2026): each opens in ONE request.
// Same functions, run in parallel on the server.

import { getOpticalRefundRegister, getOpticalCreditNoteRegister } from './actions';
import { getApprovers } from '../payments/actions';
import { getMyDesignation } from '../users/actions';

// Optical Refund tab: approvers, refund register, my designation (was 3).
export async function getOpticalRefundTabBundle() {
  return Promise.all([getApprovers(), getOpticalRefundRegister(), getMyDesignation()]);
}

// Optical Credit Note tab: approvers + credit note register (was 2).
export async function getOpticalCreditNoteTabBundle() {
  return Promise.all([getApprovers(), getOpticalCreditNoteRegister()]);
}
