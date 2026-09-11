import CashManagementClient from './cash-management-client';
import {
  getTodayCollectionSummary,
  getRevenueByDepartmentToday,
  getDayClosingHistory,
  getDayOpening,
  getSuggestedOpeningBalance,
  getUnclosedPastDays,
  getCloseDayReadiness,
  getReconciliationLockStatus,
  getCashCounterForDate,
  getDayClosedAt,
} from './actions';
import { getApprovers } from '@/app/(main)/payments/actions';
import { getOpenQueueEntriesToday } from '@/app/(main)/queue/actions';

// Server Component wrapper -- fetches the exact same data
// CashManagementClient's own refresh() fetches, but BEFORE the page is
// ever sent to the browser, and passes it down as initialData so the
// client component's useState calls can start from real numbers
// instead of empty/zero literals. Previously this whole page was
// 'use client' from the top, so every visit rendered the landing view
// (today's collection totals, the open/closed status banner) at zero
// first, then swapped in real numbers ~7-8 seconds later once
// refresh()'s ~11 Server Action round trips finished on the client --
// the classic client-fetch waterfall, and exactly the same category of
// fix already applied to the Billing Dashboard (a plain Server
// Component page.js + a client component for the interactive parts).
// refresh() itself is unchanged and still re-runs after mount, so this
// doesn't touch any business logic -- it only changes where the FIRST
// paint's numbers come from.
export default async function CashManagementPage() {
  const [
    summaryData, revenueByDeptData, historyData,
    openingData, openQueueData, unclosedPastDaysData, suggestedOpeningData,
    approversData,
  ] = await Promise.all([
    getTodayCollectionSummary(),
    getRevenueByDepartmentToday(),
    getDayClosingHistory(),
    getDayOpening(),
    getOpenQueueEntriesToday(),
    getUnclosedPastDays(),
    getSuggestedOpeningBalance(),
    getApprovers(),
  ]);
  const readinessData = await getCloseDayReadiness(undefined, summaryData);
  const isClosed = readinessData.alreadyClosed;
  const [lockStatus, counterStatus] = await Promise.all([getReconciliationLockStatus(), getCashCounterForDate()]);

  let todayClosingInfo = null;
  if (isClosed) {
    const todayStr = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
    todayClosingInfo = { closing: await getDayClosedAt(todayStr) };
  }

  const initialData = {
    summary: summaryData,
    revenueByDept: revenueByDeptData,
    reconRows: readinessData.reconciliation,
    readiness: readinessData,
    history: historyData,
    approvers: approversData,
    closedToday: isClosed,
    reconLock: lockStatus,
    cashCounterConfirmed: counterStatus.amountHandedOver != null,
    opening: openingData,
    suggestedOpening: suggestedOpeningData,
    openQueueEntries: openQueueData,
    unclosedPastDays: unclosedPastDaysData,
    todayClosingInfo,
  };

  return <CashManagementClient initialData={initialData} />;
}
