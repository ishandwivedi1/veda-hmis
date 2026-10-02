'use server';

// Optical Shop -- Zoho-style Bills & Payments screens (migration 052).
//
// Reads: every screen / pane is ONE database call (ui_optical_* functions).
// Saves: each does the change and sends back the refreshed pane and (when
// the caller passes `refresh.list`, the screen's current filters) the
// refreshed list in the SAME response -- one request per click, no reloads.
//
// Collecting a payment, applying advance and cancelling a bill reuse the
// existing optical actions (same day-open / backdating / validation rules).
// Editing and deleting go through the new optical_bill_edit /
// optical_payment_edit / optical_payment_delete (same rules as hospital
// billing: edit rights, any date, closed cash days locked, total can't go
// below what's paid, one reason per change).

import { redirect } from 'next/navigation';
import { createClient } from '@/lib/supabase-server';
import {
  collectOpticalPayment, collectOpticalAdvance, applyOpticalAdvanceAdjustment, cancelOpticalSale,
  createOpticalCreditNote, refundOpticalPayment, refundOpticalAdvance,
  getOpticalSalesForCustomer, getOpticalAdvanceBalance,
} from './actions';
import { getApprovers } from '@/app/(main)/payments/actions';

const todayIST = () => new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

// ── Reads ─────────────────────────────────────────────────────────────

// `saleId` (deep link, e.g. /optical?saleId=...): that bill's pane comes
// back in the SAME response, so opening a linked bill is one request.
export async function getOpticalBillsScreen({ query = '', status = '', from = '', to = '', full = true, saleId = null } = {}) {
  const supabase = await createClient();
  const [{ data, error }, panel, todayDue] = await Promise.all([
    supabase.rpc('ui_optical_bills', {
      p_query: query || null, p_status: status || null, p_from: from || null, p_to: to || null, p_full: !!full,
    }),
    saleId ? getOpticalBillPanel(saleId) : Promise.resolve(undefined),
    // "Still due from today" (as on hospital Invoices) -- same request.
    full
      ? supabase.from('optical_sales').select('net, paid').eq('sale_date', todayIST()).in('status', ['Pending', 'Partial'])
        .then(({ data: r }) => (r || []).reduce((t, x) => t + Math.max(0, Number(x.net) - Number(x.paid)), 0))
      : Promise.resolve(null),
  ]);
  if (error) return { error: error.message, bills: [], ...(panel !== undefined ? { panel } : {}) };
  const out = { ...(data || { bills: [] }), ...(panel !== undefined ? { panel } : {}) };
  if (out.summary && todayDue != null) out.summary = { ...out.summary, todayDue: Math.round(todayDue * 100) / 100 };
  return out;
}

// (approvers -- for Credit Note -- come in the same request)
export async function getOpticalBillPanel(saleId) {
  const supabase = await createClient();
  const [{ data, error }, approvers] = await Promise.all([
    supabase.rpc('ui_optical_bill_panel', { p_sale_id: saleId }),
    getApprovers().catch(() => []),
  ]);
  if (error) return { error: error.message };
  if (!data) return { error: 'Bill not found.' };
  return { ...data, approvers };
}

// `paymentId` (deep link): that receipt's pane comes back in the SAME
// response.
export async function getOpticalPaymentsScreen({ query = '', type = '', from = '', to = '', full = true, paymentId = null } = {}) {
  const supabase = await createClient();
  const [{ data, error }, detail] = await Promise.all([
    supabase.rpc('ui_optical_payments', {
      p_query: query || null, p_type: type || null, p_from: from || null, p_to: to || null, p_full: !!full,
    }),
    paymentId ? getOpticalReceiptPanel(paymentId) : Promise.resolve(undefined),
  ]);
  if (error) return { error: error.message, payments: [], ...(detail !== undefined ? { detail } : {}) };
  return { ...(data || { payments: [] }), ...(detail !== undefined ? { detail } : {}) };
}

// (approvers -- for Refund -- come in the same request)
export async function getOpticalReceiptPanel(paymentId) {
  const supabase = await createClient();
  const [{ data, error }, approvers] = await Promise.all([
    supabase.rpc('ui_optical_payment_detail', { p_payment_id: paymentId }),
    getApprovers().catch(() => []),
  ]);
  if (error) return { error: error.message };
  if (!data) return { error: 'Receipt not found.' };
  return { ...data, approvers };
}

// New Payment: a customer's unpaid bills + unused advance, ONE request.
export async function getOpticalNewPaymentContext(customer) {
  const ids = {
    patientId: customer?.type === 'patient' ? customer.id : null,
    opticalCustomerId: customer?.type === 'optical_customer' ? customer.id : null,
  };
  if (!ids.patientId && !ids.opticalCustomerId) return { bills: [], advanceBalance: 0 };
  const [salesRes, advanceBalance] = await Promise.all([getOpticalSalesForCustomer(ids), getOpticalAdvanceBalance(ids)]);
  const bills = (salesRes?.sales || []).filter((b) => b.status === 'Pending' || b.status === 'Partial')
    .map((b) => ({ id: b.id, sale_number: b.sale_number, sale_date: b.sale_date, net: b.net, paid: b.paid, status: b.status, due: b.outstanding }));
  return { bills, advanceBalance };
}

export async function getOpticalDeletedReceipts() {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optical_deleted_payments');
  if (error) return { error: error.message, rows: [] };
  return { rows: data || [] };
}

// ── Saves (one request each, refreshed data comes back with them) ─────

async function billRefresh(saleId, refresh) {
  const [panel, screen] = await Promise.all([
    getOpticalBillPanel(saleId),
    refresh?.list ? getOpticalBillsScreen({ ...refresh.list, full: true }) : Promise.resolve(null),
  ]);
  return { panel, screen };
}

async function receiptRefresh(paymentId, refresh, { deleted = false } = {}) {
  const [detail, screen] = await Promise.all([
    deleted ? Promise.resolve(null) : getOpticalReceiptPanel(paymentId),
    refresh?.list ? getOpticalPaymentsScreen({ ...refresh.list, full: true }) : Promise.resolve(null),
  ]);
  return { detail, screen };
}

// Edit -> Save (reason from the popup).
export async function saveOpticalBillEdit(saleId, changes, reason, expectedNet, refresh) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('optical_bill_edit', {
    p_sale_id: saleId, p_changes: changes, p_reason: reason, p_expected_net: expectedNet,
  });
  if (error) return { error: error.message };
  return { ok: true, refresh: await billRefresh(saleId, refresh) };
}

// Record Payment on a bill.
export async function recordOpticalBillPayment(saleId, { amount, modes, reference, remarks }, refresh) {
  const res = await collectOpticalPayment({ saleId, amount, modes, reference, remarks });
  if (res?.error) return { error: res.error };
  return { ok: true, receiptNumber: res.payment?.receipt_number, refresh: await billRefresh(saleId, refresh) };
}

// Apply the customer's advance credit to a bill.
export async function applyOpticalAdvanceToBill(sale, amount, refresh) {
  const res = await applyOpticalAdvanceAdjustment({
    patientId: sale.patient_id, opticalCustomerId: sale.optical_customer_id, saleId: sale.id, amount,
  });
  if (res?.error) return { error: res.error };
  return { ok: true, refresh: await billRefresh(sale.id, refresh) };
}

// Cancel a bill (only possible while nothing is paid on it).
export async function cancelOpticalBill(saleId, reason, refresh) {
  const res = await cancelOpticalSale(saleId, reason);
  if (res?.error) return { error: res.error };
  return { ok: true, refresh: await billRefresh(saleId, refresh) };
}

// Payment Edit -> Save (reason from the popup).
export async function saveOpticalPaymentEdit({ paymentId, amount, date, modes, reference, remarks, reason, expectedAmount }, refresh) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('optical_payment_edit', {
    p_payment_id: paymentId, p_amount: amount, p_date: date || null, p_modes: modes,
    p_reference: reference || null, p_remarks: remarks || null, p_reason: reason, p_expected_amount: expectedAmount,
  });
  if (error) return { error: error.message };
  return { ok: true, refresh: await receiptRefresh(paymentId, refresh) };
}

// Delete a receipt (copy kept under Deleted receipts).
export async function deleteOpticalPayment(paymentId, reason, expectedAmount, refresh) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('optical_payment_delete', {
    p_payment_id: paymentId, p_reason: reason, p_expected_amount: expectedAmount,
  });
  if (error) return { error: error.message };
  return { ok: true, result: data, refresh: await receiptRefresh(paymentId, refresh, { deleted: true }) };
}

// Credit Note on a bill (reduces what the customer owes) -- one request.
export async function createOpticalCreditNoteAndRefresh(saleId, { amount, reason, approvedBy, remarks }, refresh) {
  const res = await createOpticalCreditNote({ saleId, amount, reason, approvedBy, remarks });
  if (res?.error) return { error: res.error };
  return { ok: true, creditNote: res.creditNote, refresh: await billRefresh(saleId, refresh) };
}

// Refund on a receipt (like hospital Payments -> Refund) -- one request.
// A bill payment is refunded against that receipt; an advance receipt is
// refunded from the customer's unused advance.
export async function refundOpticalReceiptAndRefresh(payment, { amount, reason, refundMode, approvedBy }, refresh) {
  const res = payment.payment_type === 'advance'
    ? await refundOpticalAdvance({
      patientId: payment.patient_id, opticalCustomerId: payment.optical_customer_id, amount, reason, refundMode, approvedBy,
    })
    : await refundOpticalPayment({ paymentId: payment.id, amount, reason, refundMode, approvedBy });
  if (res?.error) return { error: res.error };
  return { ok: true, refund: res.refund, refresh: await receiptRefresh(payment.id, refresh) };
}

// New Payment -> Save: against the chosen bill, or (no bill) as advance.
// Redirects to the new receipt in the SAME response (one request).
export async function saveOpticalNewPayment({ customer, saleId, amount, modes, reference, remarks }) {
  let res;
  if (saleId) {
    res = await collectOpticalPayment({ saleId, amount, modes, reference, remarks });
  } else {
    res = await collectOpticalAdvance({
      patientId: customer?.type === 'patient' ? customer.id : null,
      opticalCustomerId: customer?.type === 'optical_customer' ? customer.id : null,
      amount, modes, reference, remarks,
    });
  }
  if (res?.error) return { error: res.error };
  redirect(`/optical/payments?paymentId=${res.payment.id}`);
}
