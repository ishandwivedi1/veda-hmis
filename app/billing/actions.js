'use server';

import { createClient } from '../../lib/supabase-server';

export async function getInvoiceForVisit(visitId) {
  const supabase = await createClient();

  const { data: visit, error: visitError } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();

  if (visitError) return { error: visitError.message };

  const { data: invoice, error: invError } = await supabase.rpc('get_or_create_invoice_for_visit', {
    p_visit_id: visitId,
  });

  if (invError) return { error: invError.message };

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoice.id)
    .order('id');

  return { visit, invoice, lineItems: lineItems || [] };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function addLineItem(invoiceId, serviceCode, qty) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeLineItem(lineItemId) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId });
  if (error) return { error: error.message };
  return { success: true };
}

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}

