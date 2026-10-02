'use server';

// Reads for the single Zoho-style Invoices screen (/billing). New file on
// purpose: billing/actions.js is shared by many screens and stays as is.
// Nothing here writes -- editing still goes through InvoiceEditPanel
// (edit_invoice / void_invoice) and setManualSurgeryDetails.

import { createClient } from '@/lib/supabase-server';

const IST_OFFSET_MIN = 330;
function istTodayBoundsUTC() {
  const now = new Date();
  const ist = new Date(now.getTime() + IST_OFFSET_MIN * 60000);
  const y = ist.getUTCFullYear(); const m = ist.getUTCMonth(); const d = ist.getUTCDate();
  const start = new Date(Date.UTC(y, m, d) - IST_OFFSET_MIN * 60000);
  const end = new Date(start.getTime() + 24 * 3600 * 1000);
  return { start: start.toISOString(), end: end.toISOString() };
}

// Summary strip: what's owed overall, and today's billing.
export async function getInvoicesSummary() {
  const supabase = await createClient();
  const { start, end } = istTodayBoundsUTC();
  const [{ data: open }, { data: today }] = await Promise.all([
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
    supabase.from('invoices').select('net, paid, status').gte('created_at', start).lt('created_at', end).neq('status', 'Cancelled'),
  ]);
  const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
  const outstanding = r2((open || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0));
  const todayBilled = r2((today || []).reduce((s, i) => s + Number(i.net), 0));
  const todayDue = r2((today || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0));
  return {
    outstanding,
    outstandingCount: (open || []).length,
    todayBilled,
    todayCount: (today || []).length,
    todayDue,
  };
}

// Everything the invoice detail pane needs in one call.
export async function getInvoicePanel(invoiceId) {
  const supabase = await createClient();
  const [{ data: invoice, error }, { data: lineItems }, { data: allocs }, { data: refunds }] = await Promise.all([
    supabase.from('invoices')
      .select('*, patients(id, first_name, salutation, last_name, uhid, mobile), visits(id, visit_number, visit_type, created_at)')
      .eq('id', invoiceId).single(),
    supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id'),
    supabase.from('payment_allocations')
      .select('amount, payments(id, receipt_number, collected_at, payment_type, payment_modes(mode, amount))')
      .eq('invoice_id', invoiceId),
    supabase.from('payment_refunds').select('id, amount, refunded_at, cancelled_at, refund_mode').eq('invoice_id', invoiceId),
  ]);
  if (error) return { error: error.message };

  let surgeonName = null;
  if (invoice.manual_surgeon_id) {
    const { data: doc } = await supabase.from('profiles').select('full_name').eq('id', invoice.manual_surgeon_id).maybeSingle();
    surgeonName = doc?.full_name || null;
  }

  const payments = (allocs || [])
    .filter((a) => a.payments)
    .map((a) => ({
      id: a.payments.id,
      receipt_number: a.payments.receipt_number,
      collected_at: a.payments.collected_at,
      payment_type: a.payments.payment_type,
      applied: Number(a.amount),
      modes: (a.payments.payment_modes || []).map((m) => m.mode).filter((v, i, arr) => arr.indexOf(v) === i).join(' + '),
    }))
    .sort((a, b) => new Date(a.collected_at) - new Date(b.collected_at));

  return {
    invoice,
    lineItems: lineItems || [],
    payments,
    refunds: (refunds || []).filter((r) => !r.cancelled_at),
    surgeonName,
  };
}
