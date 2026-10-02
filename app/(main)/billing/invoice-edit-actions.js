'use server';

// Server actions for editing an issued invoice (Billing Phase 2).
// New file on purpose -- billing/actions.js is shared by many screens and
// is left untouched. All real checks happen in Postgres (edit_invoice ->
// assert_billing_edit_allowed); what's computed here only decides what the
// screen shows.

import { createClient } from '@/lib/supabase-server';
import { getServiceCatalog } from './actions';

// Everything the Edit screen needs in ONE request: the invoice context in
// one database call (ui_invoice_edit_context, migration 051) alongside the
// price catalogue for "Add an item". Used to be 4 steps one after another.
// Zoho-style rules (migration 051): anyone with "Edit invoices" can edit
// any date; closed cash days stay locked; Postgres (edit_invoice) checks
// everything again on save.
export async function getInvoiceEditContext(invoiceId) {
  const supabase = await createClient();
  const [{ data: c, error }, services] = await Promise.all([
    supabase.rpc('ui_invoice_edit_context', { p_invoice_id: invoiceId }),
    getServiceCatalog(),
  ]);
  if (error) return { error: error.message };
  if (!c) return { error: 'Invoice not found.' };

  const invoice = c.invoice;
  const cancelled = invoice.status === 'Cancelled' || invoice.status === 'Void';

  let blockReason = null;
  if (cancelled) blockReason = `This invoice is ${invoice.status.toLowerCase()}.`;
  else if (c.dayClosed) blockReason = 'This invoice is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (!c.canEditRight) blockReason = 'You do not have permission to edit invoices.';

  // Cancel / Void (mirrors void_invoice() in Postgres): an unpaid invoice
  // from today only needs edit rights; a paid or past-day one needs
  // "Void invoices".
  const needsVoidPermission = c.hasAllocations || c.invoiceDate < c.today;
  let voidBlock = null;
  if (cancelled) voidBlock = 'This invoice is already cancelled.';
  else if (c.dayClosed) voidBlock = 'This invoice is from a closed day.';
  else if (c.hasRefund) voidBlock = 'This invoice has a refund against it. Cancel the refund first (Payments > Refund).';
  else if (c.hasCreditNote) voidBlock = 'This invoice has a credit note against it, so it cannot be voided. Contact an Administrator.';
  else if (needsVoidPermission && !c.canVoidRight) voidBlock = 'Voiding a paid or past-day invoice needs the "Void invoices" permission. Ask an Administrator.';
  else if (!needsVoidPermission && !c.canEditRight) voidBlock = 'You do not have permission to cancel invoices.';

  return {
    canEdit: !blockReason,
    blockReason,
    lockReasons: c.lockReasons || {},
    removeHints: c.removeHints || {},
    services: services || [],
    lines: c.lines || [],
    invoice,
    invoiceDate: c.invoiceDate,
    today: c.today,
    // a visit's invoice can't be dated before the visit (edit_invoice enforces it)
    visitDate: c.visitDate || null,
    visitNumber: c.visitNumber || null,
    isAdmin: !!c.isAdmin,
    canVoid: !voidBlock,
    voidBlock,
    appliedTotal: Number(c.appliedTotal) || 0,
  };
}

// Cancel / Void (void_invoice() in Postgres checks everything).
export async function saveInvoiceVoid(invoiceId, reason, expectedNet) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('void_invoice', {
    p_invoice_id: invoiceId,
    p_reason: reason,
    p_expected_net: expectedNet,
  });
  if (error) return { error: error.message };
  return { ok: true, invoice: data };
}

// Administrator only (enforced in change_invoice_date()).
export async function saveInvoiceDate(invoiceId, newDate, reason) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('change_invoice_date', {
    p_invoice_id: invoiceId,
    p_new_date: newDate,
    p_reason: reason,
  });
  if (error) return { error: error.message };
  return { ok: true, invoice: data };
}

export async function saveInvoiceEdit(invoiceId, changes, reason, expectedNet) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('edit_invoice', {
    p_invoice_id: invoiceId,
    p_changes: changes,
    p_reason: reason,
    p_expected_net: expectedNet,
  });
  if (error) return { error: error.message };
  return { ok: true, invoice: data };
}

// Edit history for one invoice: new-style edits (billing_audit_log, with
// full before/after) plus the older cancellation log (invoice_modifications).
export async function getInvoiceHistory(invoiceId) {
  const supabase = await createClient();
  const [{ data: audit }, { data: legacy }] = await Promise.all([
    supabase.from('billing_audit_log')
      .select('id, action, reason, before_data, after_data, changed_by, changed_at')
      .eq('entity_type', 'invoice').eq('entity_id', invoiceId)
      .order('changed_at', { ascending: false }),
    supabase.from('invoice_modifications')
      .select('id, action, reason, details, modified_by, modified_at')
      .eq('invoice_id', invoiceId)
      .order('modified_at', { ascending: false }),
  ]);

  const ids = [...new Set([...(audit || []).map((a) => a.changed_by), ...(legacy || []).map((l) => l.modified_by)].filter(Boolean))];
  let names = {};
  if (ids.length) {
    const { data: people } = await supabase.from('profiles').select('id, full_name').in('id', ids);
    names = Object.fromEntries((people || []).map((p) => [p.id, p.full_name]));
  }

  const entries = [
    ...(audit || []).map((a) => ({
      id: a.id, at: a.changed_at, by: names[a.changed_by] || 'Unknown', action: a.action,
      reason: a.reason, before: a.before_data, after: a.after_data,
    })),
    // older log; skip the row void_invoice() also writes at the same moment
    ...(legacy || [])
      .filter((l) => !(audit || []).some((a) => a.action === 'invoice_voided' && a.changed_at?.slice(0, 19) === l.modified_at?.slice(0, 19)))
      .map((l) => ({
        id: l.id, at: l.modified_at, by: names[l.modified_by] || 'Unknown', action: l.action,
        reason: l.reason, details: l.details,
      })),
  ].sort((a, b) => new Date(b.at) - new Date(a.at));

  return entries;
}
