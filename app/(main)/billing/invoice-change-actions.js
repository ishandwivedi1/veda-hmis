'use server';

// One-request saves for the Invoices screen (/billing).
//
// Before: every save on an open invoice was one request for the change and
// then 2-3 more right after it (reload the invoice, reload the whole list,
// reload the history). Applying several credits was one request PER credit,
// one after another, then the same reloads.
//
// Now each save does the change and sends back everything the screen needs
// to redraw in the SAME response:
//   panel   -- the invoice pane (ui_invoice_panel, one DB call)
//   screen  -- the list + summary + day bar + To-bill lists (only when the
//              caller passes `refresh.list`, the screen's current filters)
//   history -- the change history (only when it's open on screen)
// The reloads run in parallel on the server. The changes themselves go
// through the same functions as before (edit_invoice, void_invoice,
// apply credit note / advance, surgery details).

import { createClient } from '@/lib/supabase-server';
import { getInvoicePanel, getBillingScreenData } from './invoices-screen-actions';
import { getInvoiceHistory } from './invoice-edit-actions';
import { setManualSurgeryDetails } from './actions';
import { applyAdjustment } from '@/app/(main)/payments/actions';
import { applyCreditNote } from '@/app/(main)/credit-notes/actions';

async function refreshFor(invoiceId, refresh) {
  const [panel, screen, history] = await Promise.all([
    getInvoicePanel(invoiceId),
    refresh?.list ? getBillingScreenData({ ...refresh.list, full: true }) : Promise.resolve(null),
    refresh?.history ? getInvoiceHistory(invoiceId) : Promise.resolve(null),
  ]);
  return { panel, screen, history };
}

// Edit -> Save (edit_invoice checks everything again in Postgres).
export async function saveInvoiceEditAndRefresh(invoiceId, changes, reason, expectedNet, refresh) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('edit_invoice', {
    p_invoice_id: invoiceId,
    p_changes: changes,
    p_reason: reason,
    p_expected_net: expectedNet,
  });
  if (error) return { error: error.message };
  return { ok: true, invoice: data, refresh: await refreshFor(invoiceId, refresh) };
}

// Cancel / Void (void_invoice checks everything again in Postgres).
export async function voidInvoiceAndRefresh(invoiceId, reason, expectedNet, refresh) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('void_invoice', {
    p_invoice_id: invoiceId,
    p_reason: reason,
    p_expected_net: expectedNet,
  });
  if (error) return { error: error.message };
  return { ok: true, invoice: data, refresh: await refreshFor(invoiceId, refresh) };
}

// "Apply credits": every chosen credit (credit notes and/or advance credit)
// in ONE request -- applied one after another on the server, exactly as the
// screen used to do it, then one refresh. If one fails, the ones before it
// stay applied (same as before) and the screen is refreshed to show that.
export async function applyCreditsAndRefresh(invoiceId, patientId, rows, refresh) {
  for (const r of rows || []) {
    const res = r.cn
      ? await applyCreditNote(r.id, invoiceId, r.amount)
      : await applyAdjustment(patientId, invoiceId, r.amount);
    if (res?.error) return { error: `${r.label}: ${res.error}`, refresh: await refreshFor(invoiceId, refresh) };
  }
  return { ok: true, refresh: await refreshFor(invoiceId, refresh) };
}

// Surgery Billing Details -> Save.
export async function saveSurgeryDetailsAndRefresh(invoiceId, surgeryName, surgeryEye, surgeonId, refresh) {
  const res = await setManualSurgeryDetails(invoiceId, surgeryName, surgeryEye, surgeonId);
  if (res?.error) return { error: res.error };
  return { ok: true, refresh: await refreshFor(invoiceId, refresh) };
}
