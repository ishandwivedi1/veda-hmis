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

import { createClient } from '@/lib/supabase-server';
import { collectOpticalPayment, applyOpticalAdvanceAdjustment, cancelOpticalSale } from './actions';

// ── Reads ─────────────────────────────────────────────────────────────

// `saleId` (deep link, e.g. /optical?saleId=...): that bill's pane comes
// back in the SAME response, so opening a linked bill is one request.
export async function getOpticalBillsScreen({ query = '', status = '', from = '', to = '', full = true, saleId = null } = {}) {
  const supabase = await createClient();
  const [{ data, error }, panel] = await Promise.all([
    supabase.rpc('ui_optical_bills', {
      p_query: query || null, p_status: status || null, p_from: from || null, p_to: to || null, p_full: !!full,
    }),
    saleId ? getOpticalBillPanel(saleId) : Promise.resolve(undefined),
  ]);
  if (error) return { error: error.message, bills: [], ...(panel !== undefined ? { panel } : {}) };
  return { ...(data || { bills: [] }), ...(panel !== undefined ? { panel } : {}) };
}

export async function getOpticalBillPanel(saleId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optical_bill_panel', { p_sale_id: saleId });
  if (error) return { error: error.message };
  if (!data) return { error: 'Bill not found.' };
  return data;
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

export async function getOpticalReceiptPanel(paymentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_optical_payment_detail', { p_payment_id: paymentId });
  if (error) return { error: error.message };
  if (!data) return { error: 'Receipt not found.' };
  return data;
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
