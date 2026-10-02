'use server';

// Reads for the single Zoho-style Invoices screen (/billing). New file on
// purpose: billing/actions.js is shared by many screens and stays as is.
// Nothing here writes -- editing still goes through InvoiceEditPanel
// (edit_invoice / void_invoice) and setManualSurgeryDetails.

import { createClient } from '@/lib/supabase-server';
import { searchInvoices, getInvoicesForVisit, getTodaysVisitsWithBillingStatus, getPendingPackageBilling, getPendingProcedureBilling } from './actions';
import { getPendingInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingPrescriptionsForFrontOffice } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling } from '@/app/(main)/biometry/actions';

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

// Everything the invoice detail pane needs -- ONE database call
// (ui_invoice_panel, migration 046): invoice, lines, payments applied,
// refunds, surgeon, and the patient's credits (advance + open credit
// notes), so the pane never makes follow-up requests.
export async function getInvoicePanel(invoiceId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_invoice_panel', { p_invoice_id: invoiceId });
  if (error) return { error: error.message };
  if (!data) return { error: 'Invoice not found.' };
  return {
    invoice: data.invoice,
    lineItems: data.lineItems || [],
    payments: (data.payments || []).map((p) => ({ ...p, applied: Number(p.applied), modes: p.modes || '' })),
    refunds: data.refunds || [],
    surgeonName: data.surgeonName || null,
    advanceBalance: Math.round((Number(data.advanceBalance) || 0) * 100) / 100,
    openCreditNotes: (data.openCreditNotes || []).map((c) => ({ ...c, balance: Number(c.balance) })),
  };
}

// The Invoices screen's ONE request. `full` (first load, and after any
// change) also brings the day status, summary strip and every "To bill"
// work list; a search/filter change brings just the list. All parts run
// in parallel on the server.
export async function getBillingScreenData({ query = '', dept = '', dateFrom = '', dateTo = '', visitId = null, full = true } = {}) {
  const supabase = await createClient();
  const listPromise = visitId
    ? getInvoicesForVisit(visitId).then((r) => r?.invoices || [])
    : searchInvoices(query, dept, dateFrom, dateTo);
  if (!full) return { invoices: await listPromise };

  const [invoices, day, summary, todays, surgeryDue, inv, proc, rx, bio] = await Promise.all([
    listPromise,
    supabase.rpc('ui_day_status').then((r) => r.data || null),
    getInvoicesSummary(),
    getTodaysVisitsWithBillingStatus(),
    getPendingPackageBilling(),
    getPendingInvestigationBilling({ includeBilled: true }),
    getPendingProcedureBilling({ includeBilled: true }),
    getPendingPrescriptionsForFrontOffice({ includeBilled: true }),
    getPendingBiometryBilling({ includeBilled: true }),
  ]);
  return {
    invoices,
    day,
    summary,
    todaysVisits: todays?.visits || [],
    billingByVisit: todays?.billingByVisit || {},
    fullyPaidUnbilled: surgeryDue || [],
    pending: { inv, proc, rx, bio },
  };
}
