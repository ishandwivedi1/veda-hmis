'use server';

// Optical Shop -- Book New Order / Finalize Existing Order, one request per
// click (Oct 2026 audit).
//
// Before: picking a customer fired 4 requests (bills, advance balance,
// prescription, recent items); Confirm Order, Collect Advance, Finalize
// and Cancel each did their save and THEN a second (or third) request to
// reload. Now each click is ONE request: the read below gathers everything
// in parallel on the server, and every save sends back the refreshed data
// in the same response. Business rules are unchanged -- the saves call the
// existing actions (same day-open / validation checks, same DB functions).

import {
  createOpticalOrder, collectOpticalAdvance, finalizeOpticalOrder, cancelOpticalOrder,
  getOpticalSalesForCustomer, getOpticalAdvanceBalance, getOpenOpticalOrders,
} from './actions';
import { getLatestGlassesPrescription } from '@/app/(main)/optometry/actions';

const idArgs = (c) => ({
  patientId: c?.patientId || null,
  opticalCustomerId: c?.patientId ? null : (c?.opticalCustomerId || null),
});

// Everything the Book screen shows for a customer, in ONE request:
// their bills, unused advance and (for a patient) latest glasses Rx.
export async function getOpticalBookingContext(customer, { withRx = true } = {}) {
  const ids = idArgs(customer);
  if (!ids.patientId && !ids.opticalCustomerId) return { sales: [], advanceBalance: 0, finalRx: null };
  const [salesRes, advanceBalance, finalRx] = await Promise.all([
    getOpticalSalesForCustomer(ids),
    getOpticalAdvanceBalance(ids),
    withRx && ids.patientId ? getLatestGlassesPrescription(ids.patientId).catch(() => null) : Promise.resolve(undefined),
  ]);
  return { sales: salesRes?.sales || [], advanceBalance, ...(finalRx !== undefined ? { finalRx } : {}) };
}

// Confirm Order -> order created + customer's bills / advance, one request.
export async function confirmOpticalOrderAndRefresh(payload) {
  const res = await createOpticalOrder(payload);
  if (res?.error) return { error: res.error };
  const order = res.order;
  const context = await getOpticalBookingContext(
    { patientId: order?.patient_id, opticalCustomerId: order?.optical_customer_id }, { withRx: false },
  );
  return { order, context };
}

// Collect Advance -> receipt + refreshed advance balance, one request.
export async function collectBookingAdvanceAndRefresh(payload) {
  const res = await collectOpticalAdvance(payload);
  if (res?.error) return { error: res.error };
  const context = await getOpticalBookingContext(
    { patientId: payload.patientId, opticalCustomerId: payload.opticalCustomerId }, { withRx: false },
  );
  return { payment: res.payment, context };
}

// Finalize Order -> bill created + refreshed "awaiting delivery" list.
export async function finalizeOpticalOrderAndRefresh(orderId, payload) {
  const res = await finalizeOpticalOrder(orderId, payload);
  if (res?.error) return { error: res.error };
  return { sale: res.sale, orders: await getOpenOpticalOrders() };
}

// Cancel Order -> refreshed "awaiting delivery" list.
export async function cancelOpticalOrderAndRefresh(orderId, reason) {
  const res = await cancelOpticalOrder(orderId, reason);
  if (res?.error) return { error: res.error };
  return { ok: true, orders: await getOpenOpticalOrders() };
}
