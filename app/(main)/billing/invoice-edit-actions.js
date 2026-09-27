'use server';

// Server actions for editing an issued invoice (Billing Phase 2).
// New file on purpose -- billing/actions.js is shared by many screens and
// is left untouched. All real checks happen in Postgres (edit_invoice ->
// assert_billing_edit_allowed); what's computed here only decides what the
// screen shows.

import { createClient } from '@/lib/supabase-server';
import { getMyBillingPermissions } from '@/lib/billingPermissions';
import { getServiceCatalog } from './actions';

const istDate = (d) => new Date(d).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

export async function getInvoiceEditContext(invoiceId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const [{ data: invoice, error }, { data: lines }, perms, services, { data: packages }, { data: me }] = await Promise.all([
    supabase.from('invoices').select('id, status, net, paid, created_at, invoice_number, visits(visit_number, created_at)').eq('id', invoiceId).single(),
    supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id'),
    getMyBillingPermissions(supabase),
    getServiceCatalog(),
    supabase.from('master_packages').select('code'),
    supabase.from('profiles').select('designation').eq('id', userData?.user?.id || '00000000-0000-0000-0000-000000000000').maybeSingle(),
  ]);
  if (error) return { error: error.message };

  const invoiceDate = istDate(invoice.created_at);
  const today = istDate(new Date());
  // Everything that only needs the invoice, fetched in one parallel wave
  // (these used to run one after another).
  const lineIds = (lines || []).map((l) => l.id);
  const [{ data: closed }, { data: rxRows }, { data: allocs }, { data: invRefunds }, { data: cns }] = await Promise.all([
    supabase.from('day_closings').select('closing_date').eq('closing_date', invoiceDate).maybeSingle(),
    lineIds.length
      ? supabase.from('prescriptions').select('id, invoice_line_item_id').in('invoice_line_item_id', lineIds)
      : Promise.resolve({ data: [] }),
    supabase.from('payment_allocations').select('amount').eq('invoice_id', invoiceId),
    supabase.from('payment_refunds').select('id').eq('invoice_id', invoiceId).is('cancelled_at', null),
    supabase.from('credit_notes').select('id').eq('invoice_id', invoiceId),
  ]);

  let blockReason = null;
  if (invoice.status === 'Cancelled' || invoice.status === 'Void') blockReason = `This invoice is ${invoice.status.toLowerCase()}.`;
  else if (closed) blockReason = 'This invoice is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (!perms['invoice.edit']) blockReason = 'You do not have permission to edit invoices.';
  else if (invoiceDate < today && !perms['invoice.edit_past']) blockReason = 'You can only edit invoices dated today. Ask an Administrator.';

  // What removing a line will also do (shown to staff before they save),
  // and the one case that stays locked: a medicine whose stock was
  // actually deducted (mirrors invoice_line_lock_reason() in Postgres).
  const rxIds = (rxRows || []).map((r) => r.id);
  const { data: moves } = rxIds.length
    ? await supabase.from('inventory_movements').select('reference_id').in('reference_id', rxIds)
    : { data: [] };
  const rxWithStock = new Set((moves || []).map((m) => m.reference_id));

  const packageCodes = new Set((packages || []).map((p) => p.code));
  const lockReasons = {};
  const removeHints = {};
  for (const l of lines || []) {
    const rxForLine = (rxRows || []).filter((r) => r.invoice_line_item_id === l.id);
    if (rxForLine.some((r) => rxWithStock.has(r.id))) lockReasons[l.id] = 'Stock was deducted -- return it in Inventory first';
    else if (rxForLine.length) removeHints[l.id] = 'Prescription goes back to Pending in Pharmacy';
    else if (l.service_code && packageCodes.has(l.service_code)) removeHints[l.id] = 'Surgical case will show as not billed';
  }

  // Cancel / Void (mirrors void_invoice() in Postgres): an unpaid invoice
  // from today only needs edit rights; a paid or past-day one needs
  // "Void invoices".
  const appliedTotal = (allocs || []).reduce((s, a) => s + Number(a.amount), 0);
  const needsVoidPermission = (allocs || []).length > 0 || invoiceDate < today;
  let voidBlock = null;
  if (invoice.status === 'Cancelled' || invoice.status === 'Void') voidBlock = 'This invoice is already cancelled.';
  else if (closed) voidBlock = 'This invoice is from a closed day.';
  else if ((invRefunds || []).length) voidBlock = 'This invoice has a refund against it. Cancel the refund first (Payments > Refund).';
  else if ((cns || []).length) voidBlock = 'This invoice has a credit note against it, so it cannot be voided. Contact an Administrator.';
  else if (needsVoidPermission && !perms['invoice.void']) voidBlock = 'Voiding a paid or past-day invoice needs the "Void invoices" permission. Ask an Administrator.';
  else if (!needsVoidPermission && !perms['invoice.edit']) voidBlock = 'You do not have permission to cancel invoices.';

  return {
    canEdit: !blockReason,
    blockReason,
    lockReasons,
    removeHints,
    services: services || [],
    lines: lines || [],
    invoice,
    invoiceDate,
    today,
    // a visit's invoice can't be dated before the visit (change_invoice_date enforces it)
    visitDate: invoice.visits?.created_at ? istDate(invoice.visits.created_at) : null,
    visitNumber: invoice.visits?.visit_number || null,
    isAdmin: me?.designation === 'Administrator',
    canVoid: !voidBlock,
    voidBlock,
    appliedTotal,
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
