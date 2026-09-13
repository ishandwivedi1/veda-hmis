'use server';

import { createClient } from '@/lib/supabase-server';

// Read-only helper for the Invoice Modification UI: tells it up front
// whether the invoice currently open needs an Administrator + reason,
// so the reason field and warning banner can show BEFORE someone
// tries and gets rejected, rather than only after. This is a UX hint
// only -- the real gate is assert_invoice_editable() inside every
// invoice-editing RPC (add/remove line item, cancel, surgery details),
// which is authoritative and re-checked server-side regardless of
// what this returns.
export async function getInvoiceModifyStatus(invoiceId) {
  const supabase = await createClient();
  const { data: invoice } = await supabase.from('invoices').select('created_at').eq('id', invoiceId).maybeSingle();
  if (!invoice) return { requiresAdmin: false, businessDate: null };

  const businessDate = new Date(invoice.created_at).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
  const today = new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

  const { data: closedToday } = await supabase.from('day_closings').select('id').eq('closing_date', today).maybeSingle();

  if (businessDate === today && !closedToday) {
    return { requiresAdmin: false, businessDate };
  }

  const { data: closedTarget } = await supabase.from('day_closings').select('id').eq('closing_date', businessDate).maybeSingle();

  return {
    requiresAdmin: true,
    businessDate,
    dayClosed: !!closedTarget,
    reasonWhy: businessDate === today
      ? "Today's day has already been closed."
      : 'This invoice is from a previous day.',
  };
}
