'use server';

// One-request saves for the Payments screen (/payments).
//
// Before: Edit -> Save, Delete and the closed-day mode correction were one
// request for the change and then 2 more right after it (reload the payment,
// reload the list). Now each one does the change and sends back the
// refreshed payment (`detail`, one DB call via ui_payment_detail) and, when
// the caller passes `refresh.list` (the screen's current filters), the
// refreshed list + summary + day bar (`screen`) in the SAME response. The
// changes themselves go through the same Postgres functions as before
// (edit_payment, delete_payment, correct_closed_day_payment_modes).

import { savePaymentEdit, removePayment } from './payment-edit-actions';
import { getReceivedPaymentDetail, getPaymentsScreenData, correctClosedDayModes } from './received-actions';

async function refreshFor(paymentId, refresh, { deleted = false } = {}) {
  const [detail, screen] = await Promise.all([
    deleted ? Promise.resolve(null) : getReceivedPaymentDetail(paymentId),
    refresh?.list ? getPaymentsScreenData(refresh.list) : Promise.resolve(null),
  ]);
  return { detail, screen };
}

export async function savePaymentEditAndRefresh(args, refresh) {
  const res = await savePaymentEdit(args);
  if (res.error) return res;
  return { ...res, refresh: await refreshFor(args.paymentId, refresh) };
}

export async function removePaymentAndRefresh(paymentId, reason, expectedAmount, refresh) {
  const res = await removePayment(paymentId, reason, expectedAmount);
  if (res.error) return res;
  return { ...res, refresh: await refreshFor(paymentId, refresh, { deleted: true }) };
}

export async function correctClosedDayModesAndRefresh(args, refresh) {
  const res = await correctClosedDayModes(args);
  if (res.error) return res;
  return { ...res, refresh: await refreshFor(args.paymentId, refresh) };
}
