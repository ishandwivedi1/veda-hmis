'use server';

import { createClient } from '@/lib/supabase-server';
import { formatPatientName } from '@/lib/patientName';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';
import { searchPatientsForInvoice } from '@/app/(main)/billing/actions';
import { getApprovers } from '@/app/(main)/payments/actions';

export { searchPatientsForInvoice, getApprovers };

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

function validateModes(modes, amount) {
  const clean = (modes || []).map((m) => ({ mode: m.mode, amount: Number(m.amount) || 0 })).filter((m) => m.amount > 0);
  const sum = clean.reduce((s, m) => s + m.amount, 0);
  if (clean.length === 0) return { error: 'Select at least one payment mode.' };
  if (Math.abs(sum - Number(amount)) > 0.01) return { error: `Payment mode split (\u20b9${sum}) must add up to the amount (\u20b9${amount}).` };
  return { modes: clean };
}

// Search across BOTH real patients and existing walk-in optical
// customers in one box -- callers tag results with `type` so the UI
// can show which is which without a second lookup.
export async function searchOpticalCustomers(q) {
  if (!q || q.trim().length < 2) return [];
  const supabase = await createClient();
  const query = q.trim();
  const [{ data: patients }, { data: customers }] = await Promise.all([
    supabase.from('patients').select('id, uhid, first_name, salutation, last_name, mobile')
      .or(`uhid.ilike.%${query}%,mobile.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`).limit(8),
    supabase.from('optical_customers').select('id, name, mobile')
      .or(`mobile.ilike.%${query}%,name.ilike.%${query}%`).limit(8),
  ]);
  const patientResults = (patients || []).map((p) => ({ type: 'patient', id: p.id, name: formatPatientName(p), uhid: p.uhid, mobile: p.mobile }));
  const customerResults = (customers || []).map((c) => ({ type: 'optical_customer', id: c.id, name: c.name, mobile: c.mobile }));
  return [...patientResults, ...customerResults];
}

// ---------- New Invoice ----------

export async function createOpticalSale({ patientId, opticalCustomerId, customerName, customerMobile, items, discount, notes }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  const cleanItems = (items || [])
    .map((i) => ({ description: (i.description || '').trim(), qty: Number(i.qty) || 1, unit_price: Number(i.unit_price) || 0 }))
    .filter((i) => i.description && i.unit_price >= 0);
  if (cleanItems.length === 0) return { error: 'Add at least one item with a description and price.' };
  if (!patientId && !opticalCustomerId && (!customerName || !customerName.trim())) return { error: 'Select a patient or existing customer, or enter a walk-in name.' };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_optical_sale', {
    p_patient_id: patientId || null,
    p_optical_customer_id: opticalCustomerId || null,
    p_customer_name: customerName || null,
    p_customer_mobile: customerMobile || null,
    p_items: cleanItems,
    p_discount: Number(discount) || 0,
    p_notes: notes || null,
  });
  if (error) return { error: error.message };
  return { success: true, sale: data };
}

export async function getRecentOpticalItemNames() {
  const supabase = await createClient();
  const { data } = await supabase.from('optical_sale_items').select('description').order('created_at', { ascending: false }).limit(300);
  if (!data) return [];
  const counts = {};
  data.forEach((r) => { counts[r.description] = (counts[r.description] || 0) + 1; });
  return Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 20).map(([name]) => name);
}

// ---------- Sale lookup (shared by Collect / History / Print) ----------

function shapeSale(s) {
  return {
    ...s,
    displayName: s.patients ? formatPatientName(s.patients) : (s.optical_customers?.name || s.customer_name),
    displayMobile: s.patients?.mobile || s.optical_customers?.mobile || s.customer_mobile,
    outstanding: Math.max(0, Number(s.net) - Number(s.paid)),
  };
}

const SALE_SELECT = 'id, sale_number, sale_date, patient_id, optical_customer_id, customer_name, customer_mobile, gross, discount, net, paid, status, notes, created_at, cancelled_at, cancellation_reason, patients(id, uhid, salutation, first_name, last_name, mobile, age, gender), optical_customers(id, name, mobile)';

export async function findOpticalSaleByNumber(saleNumber) {
  if (!saleNumber || !saleNumber.trim()) return { error: 'Enter a bill number.' };
  const supabase = await createClient();
  const { data, error } = await supabase.from('optical_sales').select(SALE_SELECT).ilike('sale_number', `%${saleNumber.trim()}%`).order('created_at', { ascending: false }).limit(10);
  if (error) return { error: error.message };
  return { sales: (data || []).map(shapeSale) };
}

export async function getOpticalSalesForCustomer({ patientId, opticalCustomerId }) {
  const supabase = await createClient();
  let q = supabase.from('optical_sales').select(SALE_SELECT).order('created_at', { ascending: false });
  if (patientId) q = q.eq('patient_id', patientId);
  else if (opticalCustomerId) q = q.eq('optical_customer_id', opticalCustomerId);
  else return { sales: [] };
  const { data, error } = await q;
  if (error) return { error: error.message };
  return { sales: (data || []).map(shapeSale) };
}

export async function getOpticalSaleDetail(saleId) {
  const supabase = await createClient();
  const { data: sale, error } = await supabase.from('optical_sales').select(SALE_SELECT).eq('id', saleId).maybeSingle();
  if (error || !sale) return { error: error?.message || 'Sale not found' };
  const [{ data: items }, { data: payments }] = await Promise.all([
    supabase.from('optical_sale_items').select('*').eq('sale_id', saleId).order('created_at', { ascending: true }),
    supabase.from('optical_payments').select('*, optical_payment_modes(*)').eq('sale_id', saleId).order('collected_at', { ascending: true }),
  ]);
  return { sale: shapeSale(sale), items: items || [], payments: payments || [] };
}

// Browsable default list for the Collect Payment tab's sidebar -- every
// bill still owed money, newest first, so staff can pick one without
// needing to search by number or customer first.
export async function getOutstandingOpticalBills() {
  const supabase = await createClient();
  const { data, error } = await supabase.from('optical_sales').select(SALE_SELECT)
    .in('status', ['Pending', 'Partial']).order('created_at', { ascending: false }).limit(100);
  if (error) return { error: error.message, sales: [] };
  return { sales: (data || []).map(shapeSale) };
}

// Browsable list for the Advance tab's sidebar -- recent advances
// collected (not sale payments or adjustments), newest first, so staff
// can see what's been collected and jump straight to a customer.
export async function getRecentOpticalAdvances() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('optical_payments')
    .select('id, receipt_number, total_amount, collected_at, patient_id, optical_customer_id, patients(id, uhid, salutation, first_name, last_name, mobile), optical_customers(id, name, mobile)')
    .eq('payment_type', 'advance')
    .order('collected_at', { ascending: false })
    .limit(50);
  if (error) return { error: error.message, advances: [] };
  const advances = (data || []).map((p) => ({
    id: p.id,
    receiptNumber: p.receipt_number,
    amount: p.total_amount,
    collectedAt: p.collected_at,
    customer: p.patients
      ? { type: 'patient', id: p.patients.id, name: formatPatientName(p.patients), uhid: p.patients.uhid, mobile: p.patients.mobile }
      : { type: 'optical_customer', id: p.optical_customers.id, name: p.optical_customers.name, mobile: p.optical_customers.mobile },
  }));
  return { advances };
}

export async function getOpticalSalesForDate(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data, error } = await supabase.from('optical_sales').select(SALE_SELECT).eq('sale_date', targetDate).order('created_at', { ascending: false });
  if (error) return { error: error.message, sales: [] };
  return { sales: (data || []).map(shapeSale) };
}

// History tab: broader filterable search (date range + status), on
// top of the narrower by-number / by-customer lookups above.
export async function searchOpticalSaleHistory({ fromDate, toDate, status, query }) {
  const supabase = await createClient();
  let q = supabase.from('optical_sales').select(SALE_SELECT).order('created_at', { ascending: false }).limit(200);
  if (fromDate) q = q.gte('sale_date', fromDate);
  if (toDate) q = q.lte('sale_date', toDate);
  if (status) q = q.eq('status', status);
  if (query && query.trim()) q = q.or(`sale_number.ilike.%${query.trim()}%,customer_name.ilike.%${query.trim()}%,customer_mobile.ilike.%${query.trim()}%`);
  const { data, error } = await q;
  if (error) return { error: error.message, sales: [] };
  return { sales: (data || []).map(shapeSale) };
}

// ---------- Collect Payment ----------

export async function collectOpticalPayment({ saleId, amount, modes, reference, remarks }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };
  const { error: modeError, modes: cleanModes } = validateModes(modes, amt);
  if (modeError) return { error: modeError };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_optical_payment', {
    p_sale_id: saleId, p_amount: amt, p_modes: cleanModes, p_reference: reference || null, p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { success: true, payment: data };
}

// ---------- Advance ----------

export async function getOpticalAdvanceBalance({ patientId, opticalCustomerId }) {
  if (!patientId && !opticalCustomerId) return 0;
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_optical_advance_balance', { p_patient_id: patientId || null, p_optical_customer_id: opticalCustomerId || null });
  if (error) return 0;
  return Number(data) || 0;
}

export async function createWalkInOpticalCustomer(name, mobile) {
  if (!name || !name.trim()) return { error: 'Enter a name.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('find_or_create_optical_customer', { p_name: name, p_mobile: mobile || null });
  if (error) return { error: error.message };
  return { success: true, customer: data };
}

export async function collectOpticalAdvance({ patientId, opticalCustomerId, amount, modes, reference, remarks }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  if (!patientId && !opticalCustomerId) return { error: 'Select a patient or customer.' };
  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };
  const { error: modeError, modes: cleanModes } = validateModes(modes, amt);
  if (modeError) return { error: modeError };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_optical_advance', {
    p_patient_id: patientId || null, p_optical_customer_id: opticalCustomerId || null,
    p_amount: amt, p_modes: cleanModes, p_reference: reference || null, p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { success: true, payment: data };
}

export async function applyOpticalAdvanceAdjustment({ patientId, opticalCustomerId, saleId, amount }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_optical_advance_adjustment', {
    p_patient_id: patientId || null, p_optical_customer_id: opticalCustomerId || null, p_sale_id: saleId, p_amount: amt,
  });
  if (error) return { error: error.message };
  return { success: true, sale: data };
}

// ---------- Cancel ----------

export async function cancelOpticalSale(saleId, reason) {
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('cancel_optical_sale', { p_sale_id: saleId, p_reason: reason.trim() });
  if (error) return { error: error.message };
  return { success: true, sale: data };
}

// ---------- Credit Note ----------
// Writes off part or all of a bill's OUTSTANDING balance -- no cash
// moves. Use when a bill's remaining balance is being waived, not when
// money already collected needs to go back (that's a Refund).

export async function createOpticalCreditNote({ saleId, amount, reason, approvedBy, remarks }) {
  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid credit amount.' };
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  if (!approvedBy) return { error: 'Select an approver.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_optical_credit_note', {
    p_sale_id: saleId, p_amount: amt, p_reason: reason.trim(), p_approved_by: approvedBy, p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { success: true, creditNote: data };
}

export async function getOpticalCreditNoteRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('optical_credit_notes')
    .select('*, optical_sales(sale_number), patients(salutation, first_name, last_name), optical_customers(name), profiles!optical_credit_notes_approved_by_fkey(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  return (data || []).map((cn) => ({ ...cn, customerName: cn.patients ? formatPatientName(cn.patients) : cn.optical_customers?.name }));
}

// ---------- Refund ----------
// Cash actually goes back to the customer -- either from an unused
// advance balance, or against a specific bill payment already
// collected. Both require the cash day to be open (real cash moves).

export async function getOpticalPaymentsForCustomer({ patientId, opticalCustomerId }) {
  const supabase = await createClient();
  let q = supabase
    .from('optical_payments')
    .select('id, total_amount, collected_at, sale_id, optical_sales(sale_number)')
    .eq('payment_type', 'sale_payment')
    .order('collected_at', { ascending: false });
  if (patientId) q = q.eq('patient_id', patientId);
  else if (opticalCustomerId) q = q.eq('optical_customer_id', opticalCustomerId);
  else return [];
  const { data: payments } = await q;
  const rows = payments || [];
  if (rows.length === 0) return [];

  const { data: refunds } = await supabase
    .from('optical_payment_refunds')
    .select('payment_id, amount')
    .in('payment_id', rows.map((p) => p.id));
  const refundedByPayment = {};
  (refunds || []).forEach((r) => { refundedByPayment[r.payment_id] = (refundedByPayment[r.payment_id] || 0) + Number(r.amount); });

  return rows.map((p) => {
    const alreadyRefunded = refundedByPayment[p.id] || 0;
    return { ...p, alreadyRefunded, refundable: Number(p.total_amount) - alreadyRefunded };
  });
}

export async function refundOpticalAdvance({ patientId, opticalCustomerId, amount, reason, refundMode, approvedBy }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  if (!approvedBy) return { error: 'Select an approver.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('refund_optical_advance', {
    p_patient_id: patientId || null, p_optical_customer_id: opticalCustomerId || null,
    p_amount: amt, p_reason: reason.trim(), p_refund_mode: refundMode || null, p_approved_by: approvedBy,
  });
  if (error) return { error: error.message };
  return { success: true, refund: data };
}

export async function refundOpticalPayment({ paymentId, amount, reason, refundMode, approvedBy }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  const amt = Number(amount);
  if (!amt || amt <= 0) return { error: 'Enter a valid amount.' };
  if (!reason || !reason.trim()) return { error: 'A reason is required.' };
  if (!approvedBy) return { error: 'Select an approver.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('refund_optical_payment', {
    p_payment_id: paymentId, p_amount: amt, p_reason: reason.trim(), p_refund_mode: refundMode || null, p_approved_by: approvedBy,
  });
  if (error) return { error: error.message };
  return { success: true, refund: data };
}

export async function getOpticalRefundRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('optical_payment_refunds')
    .select('*, optical_sales(sale_number), patients(salutation, first_name, last_name), optical_customers(name), profiles!optical_payment_refunds_approved_by_fkey(full_name)')
    .order('refunded_at', { ascending: false })
    .limit(50);
  return (data || []).map((r) => ({ ...r, customerName: r.patients ? formatPatientName(r.patients) : r.optical_customers?.name }));
}

// ---------- Payments register (view + clerical edit) ----------
// "Payments" is a different view from "History": History lists BILLS
// (optical_sales); this lists actual money-movement events
// (optical_payments) -- sale payments, advances, refunds, credit
// notes -- which a bill-centric view can't show on its own. Mirrors
// the main Billing/Payments module's own Receipt register + clerical
// edit for exactly the same reason.

const PAYMENT_TYPE_LABELS = {
  sale_payment: 'Sale Payment',
  advance: 'Advance',
  advance_adjustment: 'Advance Applied',
  credit_note: 'Credit Note',
  refund: 'Refund',
};

export async function getOpticalPaymentsRegister({ fromDate, toDate, query }) {
  const supabase = await createClient();
  let q = supabase
    .from('optical_payments')
    .select('*, optical_payment_modes(mode, amount), optical_sales(sale_number), patients(salutation, first_name, last_name), optical_customers(name)')
    .order('collected_at', { ascending: false })
    .limit(200);
  if (fromDate) q = q.gte('collected_at', `${fromDate}T00:00:00+05:30`);
  if (toDate) q = q.lte('collected_at', `${toDate}T23:59:59+05:30`);
  if (query && query.trim()) q = q.or(`receipt_number.ilike.%${query.trim()}%,reference.ilike.%${query.trim()}%`);
  const { data, error } = await q;
  if (error) return { error: error.message, payments: [] };
  const payments = (data || []).map((p) => ({
    ...p,
    typeLabel: PAYMENT_TYPE_LABELS[p.payment_type] || p.payment_type,
    displayName: p.patients ? formatPatientName(p.patients) : (p.optical_customers?.name || '--'),
  }));
  return { payments };
}

export async function editOpticalPaymentClerical({ paymentId, modes, reference, remarks, reason, expectedModeCount }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  if (!reason || !reason.trim()) return { error: 'A reason is required to edit a payment.' };
  const clean = (modes || []).map((m) => ({ mode: m.mode, amount: Number(m.amount) || 0 })).filter((m) => m.amount > 0);
  if (clean.length === 0) return { error: 'At least one payment mode with an amount is required.' };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('edit_optical_payment_clerical', {
    p_payment_id: paymentId, p_modes: clean, p_reference: reference || null, p_remarks: remarks || null,
    p_reason: reason.trim(), p_expected_mode_count: typeof expectedModeCount === 'number' ? expectedModeCount : null,
  });
  if (error) return { error: error.message };
  return { success: true, payment: data };
}

export async function getOpticalPaymentEditHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('optical_payment_edits')
    .select('*, profiles(full_name)')
    .eq('payment_id', paymentId)
    .order('edited_at', { ascending: false });
  return data || [];
}
