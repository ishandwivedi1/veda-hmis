'use server';

// Server actions for editing / deleting payments (Billing Phase 3).
// New file on purpose -- payments/actions.js is shared by many screens and is
// left untouched. All real checks happen in Postgres (edit_payment /
// delete_payment -> assert_billing_edit_allowed); what's computed here only
// decides what the screen shows.

import { createClient } from '@/lib/supabase-server';
import { buildPaymentHistory, paymentEditFlags } from '@/lib/paymentHistory';

const istDate = (d) => new Date(d).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

export async function getPaymentEditContext(paymentId) {
  const supabase = await createClient();
  // One database call for the payment, its day, permissions, credits and
  // history (ui_payment_detail, migration 046) instead of ~5 in a row.
  const { data: base, error } = await supabase.rpc('ui_payment_detail', { p_payment_id: paymentId });
  if (error) return { error: error.message };
  if (!base) return { error: 'Payment not found.' };
  const payment = base.payment;

  // Invoices this payment could pay: ones it already pays + the patient's
  // unpaid ones. "room" = what's left after everyone else's payments.
  let invoices = [];
  if (payment.payment_type === 'invoice_payment') {
    const currentIds = (payment.payment_allocations || []).map((a) => a.invoice_id);
    const { data: candidates } = await supabase.from('invoices')
      .select('id, invoice_number, net, paid, status, created_at, payment_allocations(payment_id, amount), payment_refunds(amount, cancelled_at)')
      .eq('patient_id', payment.patient_id)
      .neq('status', 'Cancelled')
      .or(`status.in.(Pending,Partial)${currentIds.length ? `,id.in.(${currentIds.join(',')})` : ''}`)
      .order('created_at', { ascending: false })
      .limit(50);
    invoices = (candidates || [])
      .filter((i) => Number(i.net) > 0 || currentIds.includes(i.id))
      .map((i) => {
        const others = (i.payment_allocations || []).filter((a) => a.payment_id !== paymentId).reduce((s, a) => s + Number(a.amount), 0)
          - (i.payment_refunds || []).filter((r) => !r.cancelled_at).reduce((s, r) => s + Number(r.amount), 0);
        const current = (payment.payment_allocations || []).find((a) => a.invoice_id === i.id);
        return {
          id: i.id, invoice_number: i.invoice_number, net: Number(i.net), date: istDate(i.created_at),
          room: r2(Number(i.net) - others), current: current ? Number(current.amount) : 0,
        };
      })
      .filter((i) => i.room > 0 || i.current > 0);
  }

  return {
    payment,
    paymentDate: base.paymentDate,
    today: base.today,
    invoices,
    patientCredit: r2(base.patientCredit),
    paymentCredit: r2(base.paymentCredit),
    history: buildPaymentHistory(base.audit, base.edits),
    ...paymentEditFlags(base),
  };
}

export async function savePaymentEdit({ paymentId, amount, date, modes, reference, remarks, allocations, reason, expectedAmount }) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('edit_payment', {
    p_payment_id: paymentId,
    p_amount: amount,
    p_date: date || null,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
    p_allocations: allocations || [],
    p_reason: reason,
    p_expected_amount: expectedAmount,
  });
  if (error) return { error: error.message };
  return { ok: true, payment: data };
}

export async function removePayment(paymentId, reason, expectedAmount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('delete_payment', {
    p_payment_id: paymentId,
    p_reason: reason,
    p_expected_amount: expectedAmount,
  });
  if (error) return { error: error.message };
  return { ok: true, result: data };
}

async function namesFor(supabase, ids) {
  const uniq = [...new Set(ids.filter(Boolean))];
  if (!uniq.length) return {};
  const { data } = await supabase.from('profiles').select('id, full_name').in('id', uniq);
  return Object.fromEntries((data || []).map((p) => [p.id, p.full_name]));
}

// Change history for one payment: new audit entries + older clerical edits
// (payment_edits rows written before the new edit existed).
export async function getPaymentHistory(paymentId) {
  const supabase = await createClient();
  const [{ data: audit }, { data: older }] = await Promise.all([
    supabase.from('billing_audit_log').select('id, action, reason, before_data, after_data, changed_by, changed_at')
      .eq('entity_type', 'payment').eq('entity_id', paymentId).order('changed_at', { ascending: false }),
    supabase.from('payment_edits').select('*').eq('payment_id', paymentId).order('edited_at', { ascending: false }),
  ]);
  const auditTimes = new Set((audit || []).map((a) => a.changed_at?.slice(0, 19)));
  const names = await namesFor(supabase, [...(audit || []).map((a) => a.changed_by), ...(older || []).map((o) => o.edited_by)]);
  return [
    ...(audit || []).map((a) => ({ id: a.id, at: a.changed_at, by: names[a.changed_by] || 'Unknown', action: a.action, reason: a.reason, before: a.before_data, after: a.after_data })),
    // skip the payment_edits row the new edit also writes (same moment)
    ...(older || []).filter((o) => !auditTimes.has(o.edited_at?.slice(0, 19))).map((o) => ({
      id: o.id, at: o.edited_at, by: names[o.edited_by] || 'Unknown', action: 'older_edit', reason: o.reason,
      older: { oldAmount: o.old_amount, newAmount: o.new_amount, oldModes: o.old_modes, newModes: o.new_modes },
    })),
  ].sort((a, b) => new Date(b.at) - new Date(a.at));
}

// Receipts that were deleted (and credit applications removed), newest first.
export async function getDeletedPayments() {
  const supabase = await createClient();
  const { data } = await supabase.from('billing_audit_log')
    .select('id, entity_ref, action, reason, before_data, changed_by, changed_at')
    .eq('entity_type', 'payment').in('action', ['payment_deleted', 'credit_application_removed'])
    .order('changed_at', { ascending: false }).limit(200);
  const rows = data || [];
  const names = await namesFor(supabase, rows.map((r) => r.changed_by));
  const patientIds = [...new Set(rows.map((r) => r.before_data?.patient_id).filter(Boolean))];
  let patients = {};
  if (patientIds.length) {
    const { data: ps } = await supabase.from('patients').select('id, first_name, salutation, last_name, uhid').in('id', patientIds);
    patients = Object.fromEntries((ps || []).map((p) => [p.id, p]));
  }
  return rows.map((r) => ({ ...r, by: names[r.changed_by] || 'Unknown', patient: patients[r.before_data?.patient_id] || null }));
}
