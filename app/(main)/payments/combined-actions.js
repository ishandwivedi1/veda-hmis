'use server';

// Combined server calls for Collect Payment (speed-up, 27 Sep 2026).
// Next.js runs a page's server actions one at a time, so these wrap the
// SAME existing actions (no query or rule changes) and run them in
// parallel on the server -- one round trip instead of several.

import { getAllUnpaidInvoices, getPatientById, getOutstandingInvoices, getAdvanceBalance } from './actions';

// A patient's outstanding invoices and advance balance, together.
export async function getPatientPaymentContext(patientId) {
  const [invoices, advanceBalance] = await Promise.all([
    getOutstandingInvoices(patientId),
    getAdvanceBalance(patientId),
  ]);
  return { invoices, advanceBalance };
}

// Everything Collect Payment needs on open: the recent unpaid list and,
// when arriving from "Finalize invoice", that patient's details too.
export async function getCollectPaymentBootstrap(patientId) {
  const [unpaid, patientResult, ctx] = await Promise.all([
    getAllUnpaidInvoices(),
    patientId ? getPatientById(patientId) : null,
    patientId ? getPatientPaymentContext(patientId) : null,
  ]);
  return { unpaid, patientResult, ctx };
}

// ── Tab openers (speed-up, 23 Oct 2026): each tab opens in ONE request ──
import { getApprovers, getRefundRegister, getTodaysVisits, getCreditNoteRegister, getCurrentBalancesByPatient, getLedgerHistory } from './actions';
import { getMyDesignation } from '../users/actions';

// Refund tab: approvers, refund register, today's visits, my designation (was 4).
export async function getRefundTabBundle() {
  return Promise.all([getApprovers(), getRefundRegister(), getTodaysVisits(), getMyDesignation()]);
}

// Credit Note tab: approvers, credit note register, today's visits (was 3).
export async function getCreditNoteTabBundle() {
  return Promise.all([getApprovers(), getCreditNoteRegister(), getTodaysVisits()]);
}

// Advance tab sidebar: balances + ledger history (was 2, one after another).
export async function getAdvanceSidebarBundle() {
  return Promise.all([getCurrentBalancesByPatient(), getLedgerHistory()]);
}

// Advance tab on open: sidebar + today's visits (was 3).
export async function getAdvanceTabBundle() {
  return Promise.all([getAdvanceSidebarBundle(), getTodaysVisits()]);
}
