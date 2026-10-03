'use server';

// Daily Cash Management -- one request per click (Oct 2026 audit).
//
// Before: opening the page rendered everything on the server and then the
// browser fetched it ALL again (~15 requests in 4 waves: refresh(),
// approvers, petty cash, Cash Counter). Every save was the save plus a
// reload of 2-11 more requests (Open Day / Close Day / Reopen / Edit
// opening balance each re-ran the whole page's ~11 reads).
//
// Now: the page arrives with everything (getCashScreen, run on the
// server); every save below does its work and sends back the refreshed
// screen in the SAME response. The business actions themselves are the
// existing ones in ./actions -- unchanged rules, unchanged DB functions.

import {
  getTodayCollectionSummary, getRevenueByDepartmentToday, getDayClosingHistory, getDayOpening,
  getUnclosedPastDays, getSuggestedOpeningBalance, getCloseDayReadiness, getReconciliationLockStatus,
  getCashCounterForDate, getCashCounterHistory, getDayClosedAt, getExpenseCategoriesActive,
  getExpensesForDate, getPettyCashTotal, getReconciliationData, getDailyReport,
  openDay, updateOpeningBalance, saveReconciliation, lockReconciliation, unlockReconciliation,
  recordClosingCash, confirmCashCounter, unlockCashCounter, closeDay, reopenDay, addExpense, deleteExpense,
} from './actions';
import { getApprovers } from '@/app/(main)/payments/actions';
import { getOpenQueueEntriesToday, bulkForceCloseQueueEntries } from '@/app/(main)/queue/actions';
import { addExpenseCategory } from '@/app/(main)/master-data/actions';
import { uploadAttachment } from '@/lib/attachments';

const todayIST = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

// Everything the Cash Management page shows, gathered in parallel on the
// server (only the reconciliation rows wait for the day's collections).
export async function getCashScreen() {
  const today = todayIST();
  const [
    summary, revenueByDept, history, opening, openQueueEntries, unclosedPastDays, suggestedOpening,
    approvers, reconLock, counter, counterHistory, closedAt, expenseCategories, todayExpenses, pettyCashTotal,
  ] = await Promise.all([
    getTodayCollectionSummary(),
    getRevenueByDepartmentToday(),
    getDayClosingHistory(),
    getDayOpening(),
    getOpenQueueEntriesToday(),
    getUnclosedPastDays(),
    getSuggestedOpeningBalance(),
    getApprovers(),
    getReconciliationLockStatus(),
    getCashCounterForDate(),
    getCashCounterHistory(2),
    getDayClosedAt(today).catch(() => null),
    getExpenseCategoriesActive(),
    getExpensesForDate(today),
    getPettyCashTotal(today),
  ]);
  const readiness = await getCloseDayReadiness(undefined, summary);
  return {
    summary, revenueByDept, history, opening, openQueueEntries, unclosedPastDays, suggestedOpening, approvers,
    readiness, reconRows: readiness.reconciliation, closedToday: readiness.alreadyClosed, reconLock,
    counter, counterHistory, cashCounterConfirmed: counter?.amountHandedOver != null,
    todayClosingInfo: readiness.alreadyClosed ? { closing: closedAt } : null,
    expenseCategories, todayExpenses, pettyCashTotal,
  };
}

async function withScreen(resultPromise) {
  const r = await resultPromise;
  if (r?.error) return { error: r.error };
  return { ...r, screen: await getCashScreen() };
}

// ── Today ──────────────────────────────────────────────────────────────
export async function openDayAndRefresh(balance, remarks) { return withScreen(openDay(balance, remarks)); }
export async function updateOpeningAndRefresh(balance) { return withScreen(updateOpeningBalance(balance)); }
export async function saveReconAndRefresh(mode, expected, actual, reason, approvedBy) {
  return withScreen(saveReconciliation(mode, expected, actual, reason, approvedBy));
}
export async function lockReconAndRefresh() { return withScreen(lockReconciliation()); }
export async function unlockReconAndRefresh() { return withScreen(unlockReconciliation()); }
export async function recordClosingAndRefresh(amount) { return withScreen(recordClosingCash(amount)); }
export async function confirmCounterAndRefresh() { return withScreen(confirmCashCounter()); }
export async function unlockCounterAndRefresh() { return withScreen(unlockCashCounter()); }
export async function bulkForceCloseAndRefresh(ids, reason) { return withScreen(bulkForceCloseQueueEntries(ids, reason)); }
export async function reopenDayAndRefresh(date, reason) { return withScreen(reopenDay(date, reason)); }
export async function deleteExpenseAndRefresh(id, expenseDate) { return withScreen(deleteExpense(id, expenseDate)); }
export async function addCategoryAndRefresh(name) { return withScreen(addExpenseCategory({ name })); }

// Close Day -> refreshed screen + today's Daily Report, one request.
export async function closeDayAndRefresh(notes) {
  const r = await closeDay(notes);
  if (r?.error) return { error: r.error };
  const [screen, report] = await Promise.all([getCashScreen(), getDailyReport(todayIST()).catch(() => null)]);
  return { ...r, screen, report };
}

// Add Expense (+ the bill attachment, if any) -> one request.
export async function addExpenseAndRefresh(formData) {
  const backdateTo = formData.get('backdateTo') || null;
  const r = await addExpense(
    formData.get('categoryId'), parseFloat(formData.get('amount')), formData.get('remarks') || '', '',
    backdateTo, formData.get('backdateReason') || '',
  );
  if (r?.error) return { error: r.error };
  let uploadError = null;
  const file = formData.get('file');
  if (file && typeof file !== 'string' && file.size > 0 && r.expense) {
    const fd = new FormData();
    fd.append('file', file);
    fd.append('entityType', 'petty_cash_expense');
    fd.append('entityId', r.expense.id);
    const up = await uploadAttachment(fd);
    if (up?.error) uploadError = up.error;
  }
  return { ...r, uploadError, screen: await getCashScreen() };
}

// ── Close a past day ───────────────────────────────────────────────────
export async function getPastDayClosing(date) {
  const summary = await getTodayCollectionSummary(date);
  const [reconRows, counter, lock] = await Promise.all([
    getReconciliationData(date, summary),
    getCashCounterForDate(date),
    getReconciliationLockStatus(date),
  ]);
  return { date, summary, reconRows, counter, lock };
}

async function withPast(date, resultPromise) {
  const r = await resultPromise;
  if (r?.error) return { error: r.error };
  return { ...r, past: await getPastDayClosing(date) };
}

export async function savePastReconAndRefresh(date, mode, expected, actual, reason, approvedBy) {
  return withPast(date, saveReconciliation(mode, expected, actual, reason, approvedBy, date));
}
export async function lockPastReconAndRefresh(date) { return withPast(date, lockReconciliation(date)); }
export async function unlockPastReconAndRefresh(date) { return withPast(date, unlockReconciliation(date)); }
export async function recordPastClosingAndRefresh(date, amount) { return withPast(date, recordClosingCash(amount, date)); }
export async function confirmPastCounterAndRefresh(date) { return withPast(date, confirmCashCounter(date)); }
export async function unlockPastCounterAndRefresh(date) { return withPast(date, unlockCashCounter(date)); }
export async function closePastDayAndRefresh(date, notes) { return withScreen(closeDay(notes, date)); }
