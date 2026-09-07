'use server';

import { createClient } from '@/lib/supabase-server';
import { formatPatientName } from '@/lib/patientName';
import { requireDayOpen } from '@/app/(main)/cash-management/actions';
import { searchPatientsForInvoice } from '@/app/(main)/billing/actions';

// Re-exported so the Optical Shop tab can reuse the exact same patient
// search the rest of Billing uses, instead of a second implementation
// that could drift from it (different matching rules, different columns).
export { searchPatientsForInvoice };

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// items: [{ description, qty, unit_price }, ...]
export async function createOpticalSale({ patientId, customerName, customerMobile, paymentMode, items, discount, notes }) {
  const dayOpenError = await requireDayOpen();
  if (dayOpenError) return dayOpenError;

  if (!patientId && (!customerName || !customerName.trim())) {
    return { error: 'Select a patient or enter a walk-in customer name.' };
  }
  const cleanItems = (items || [])
    .map((i) => ({ description: (i.description || '').trim(), qty: Number(i.qty) || 1, unit_price: Number(i.unit_price) || 0 }))
    .filter((i) => i.description && i.unit_price >= 0);
  if (cleanItems.length === 0) return { error: 'Add at least one item with a description and price.' };
  if (!paymentMode) return { error: 'Select a payment mode.' };

  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_optical_sale', {
    p_patient_id: patientId || null,
    p_customer_name: customerName || null,
    p_customer_mobile: customerMobile || null,
    p_payment_mode: paymentMode,
    p_items: cleanItems,
    p_discount: Number(discount) || 0,
    p_notes: notes || null,
  });
  if (error) return { error: error.message };
  return { success: true, sale: data };
}

export async function cancelOpticalSale(saleId, reason) {
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('cancel_optical_sale', { p_sale_id: saleId, p_reason: reason.trim() });
  if (error) return { error: error.message };
  return { success: true, sale: data };
}

// Recent-items quick-pick: distinct item descriptions billed recently,
// most-used first, so staff aren't retyping the same frame/lens names
// every time. No inventory linkage -- purely a typing shortcut.
export async function getRecentOpticalItemNames() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('optical_sale_items')
    .select('description')
    .order('created_at', { ascending: false })
    .limit(300);
  if (!data) return [];
  const counts = {};
  data.forEach((r) => { counts[r.description] = (counts[r.description] || 0) + 1; });
  return Object.entries(counts).sort((a, b) => b[1] - a[1]).slice(0, 20).map(([name]) => name);
}

export async function getOpticalSalesForDate(date) {
  const supabase = await createClient();
  const targetDate = date || todayIST();
  const { data, error } = await supabase
    .from('optical_sales')
    .select('id, sale_number, sale_date, patient_id, customer_name, customer_mobile, payment_mode, gross, discount, net, status, created_at, patients(id, salutation, first_name, last_name, mobile)')
    .eq('sale_date', targetDate)
    .order('created_at', { ascending: false });
  if (error) return { error: error.message, sales: [] };
  const sales = (data || []).map((s) => ({
    ...s,
    displayName: s.patients ? formatPatientName(s.patients) : s.customer_name,
    displayMobile: s.patients?.mobile || s.customer_mobile,
  }));
  return { sales };
}

export async function getOpticalSaleDetail(saleId) {
  const supabase = await createClient();
  const { data: sale, error } = await supabase
    .from('optical_sales')
    .select('*, patients(id, uhid, salutation, first_name, last_name, mobile, age, gender)')
    .eq('id', saleId)
    .maybeSingle();
  if (error || !sale) return { error: error?.message || 'Sale not found' };
  const { data: items } = await supabase
    .from('optical_sale_items')
    .select('*')
    .eq('sale_id', saleId)
    .order('created_at', { ascending: true });
  return { sale, items: items || [] };
}
