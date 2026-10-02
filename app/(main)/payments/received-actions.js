'use server';

// Payments Received (Zoho-style list + detail). New file on purpose:
// payments/actions.js and payment-edit-actions.js are shared by many
// screens and stay untouched. Everything that changes money still goes
// through Postgres functions (edit_payment / delete_payment via the shared
// PaymentEditPanel, and correct_closed_day_payment_modes below).

import { createClient } from '@/lib/supabase-server';
import { getPaymentEditContext, getPaymentHistory } from './payment-edit-actions';

// Everything the detail pane needs in one round trip.
export async function getReceivedPaymentDetail(paymentId) {
  const supabase = await createClient();
  const [ctx, history, { data: userData }] = await Promise.all([
    getPaymentEditContext(paymentId),
    getPaymentHistory(paymentId),
    supabase.auth.getUser(),
  ]);
  if (ctx?.error) return { error: ctx.error };

  const p = ctx.payment;
  const [{ data: me }, { data: closed }, { data: counter }, { data: collector }, { data: refunds }] = await Promise.all([
    supabase.from('profiles').select('designation').eq('id', userData?.user?.id || '00000000-0000-0000-0000-000000000000').maybeSingle(),
    supabase.from('day_closings').select('closing_date, closed_at').eq('closing_date', ctx.paymentDate).maybeSingle(),
    supabase.from('cash_counter').select('amount_handed_over').eq('counter_date', ctx.paymentDate).maybeSingle(),
    p.collected_by
      ? supabase.from('profiles').select('full_name').eq('id', p.collected_by).maybeSingle()
      : Promise.resolve({ data: null }),
    supabase.from('payment_refunds').select('id').eq('payment_id', paymentId).is('cancelled_at', null),
  ]);

  const isAdmin = me?.designation === 'Administrator';
  const dayClosed = !!closed;
  const hasRefund = (refunds || []).length > 0;
  const canCorrectClosedDay = dayClosed && isAdmin && !hasRefund && ['invoice_payment', 'advance'].includes(p.payment_type);

  return {
    ...ctx,
    history,
    isAdmin,
    dayClosed,
    canCorrectClosedDay,
    cashHandedOver: counter?.amount_handed_over ?? null,
    collectedBy: collector?.full_name || null,
  };
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
