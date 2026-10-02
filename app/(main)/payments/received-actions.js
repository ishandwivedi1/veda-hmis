'use server';

// Payments Received (Zoho-style list + detail). New file on purpose:
// payments/actions.js and payment-edit-actions.js are shared by many
// screens and stay untouched. Everything that changes money still goes
// through Postgres functions (edit_payment / delete_payment via the shared
// PaymentEditPanel, and correct_closed_day_payment_modes below).

import { createClient } from '@/lib/supabase-server';
import { buildPaymentHistory, paymentEditFlags } from '@/lib/paymentHistory';
import { searchReceipts } from './actions';
import { getTodayCollectionSummary } from '@/app/(main)/cash-management/actions';

const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

// Everything the detail pane needs: ONE database call (ui_payment_detail,
// migration 046) -- payment, day status, permissions, credits, cash
// handed over and history -- instead of ~6 calls one after another.
export async function getReceivedPaymentDetail(paymentId) {
  const supabase = await createClient();
  const { data: base, error } = await supabase.rpc('ui_payment_detail', { p_payment_id: paymentId });
  if (error) return { error: error.message };
  if (!base) return { error: 'Payment not found.' };

  const p = base.payment;
  const canCorrectClosedDay = !!base.dayClosed && !!base.isAdmin && !base.hasRefund && ['invoice_payment', 'advance'].includes(p.payment_type);

  return {
    payment: p,
    paymentDate: base.paymentDate,
    today: base.today,
    patientCredit: r2(base.patientCredit),
    paymentCredit: r2(base.paymentCredit),
    ...paymentEditFlags(base),
    history: buildPaymentHistory(base.audit, base.edits),
    isAdmin: !!base.isAdmin,
    dayClosed: !!base.dayClosed,
    canCorrectClosedDay,
    cashHandedOver: base.cashHandedOver ?? null,
    collectedBy: base.collectedBy || null,
  };
}

// The Payments screen's ONE request: day status, today's summary strip and
// the payments list, run in parallel on the server.
export async function getPaymentsScreenData({ query = '', mode = '', dateFrom = '', dateTo = '' } = {}) {
  const supabase = await createClient();
  const [day, summary, receipts] = await Promise.all([
    supabase.rpc('ui_day_status').then((r) => r.data || null),
    getTodayCollectionSummary(),
    searchReceipts(query, mode, dateFrom, dateTo),
  ]);
  return { day, summary, receipts };
}

// Closed day, Administrator only: re-split the modes (total unchanged).
// The database moves the same amounts between that day's reconciliation
// rows (Expected and Actual together), so no reopen/re-close is needed.
export async function correctClosedDayModes({ paymentId, modes, reference, remarks, reason, expectedAmount }) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('correct_closed_day_payment_modes', {
    p_payment_id: paymentId,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_reason: reason,
    p_expected_amount: expectedAmount,
  });
  if (error) return { error: error.message };
  return { ok: true, result: data };
}
