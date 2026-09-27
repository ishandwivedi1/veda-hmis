'use server';

// Server actions for editing an issued invoice (Billing Phase 2).
// New file on purpose -- billing/actions.js is shared by many screens and
// is left untouched. All real checks happen in Postgres (edit_invoice ->
// assert_billing_edit_allowed); what's computed here only decides what the
// screen shows.

import { createClient } from '@/lib/supabase-server';
import { getMyBillingPermissions } from '@/lib/billingPermissions';

const istDate = (d) => new Date(d).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });

export async function getInvoiceEditContext(invoiceId) {
  const supabase = await createClient();
  const [{ data: invoice, error }, { data: lines }, perms, { data: services }, { data: packages }] = await Promise.all([
    supabase.from('invoices').select('id, status, net, paid, created_at, invoice_number').eq('id', invoiceId).single(),
    supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id'),
    getMyBillingPermissions(supabase),
    supabase.from('master_services').select('code, name, dept, rate, gst_pct').eq('status', 'Active').neq('dept', 'Pharmacy').order('name'),
    supabase.from('master_packages').select('code'),
  ]);
  if (error) return { error: error.message };

  const invoiceDate = istDate(invoice.created_at);
  const today = istDate(new Date());
  const { data: closed } = await supabase.from('day_closings').select('closing_date').eq('closing_date', invoiceDate).maybeSingle();

  let blockReason = null;
  if (invoice.status === 'Cancelled' || invoice.status === 'Void') blockReason = `This invoice is ${invoice.status.toLowerCase()}.`;
  else if (closed) blockReason = 'This invoice is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (!perms['invoice.edit']) blockReason = 'You do not have permission to edit invoices.';
  else if (invoiceDate < today && !perms['invoice.edit_past']) blockReason = 'You can only edit invoices dated today. Ask an Administrator.';

  const packageCodes = new Set((packages || []).map((p) => p.code));
  const lockReasons = {};
  for (const l of lines || []) {
    if (l.dept === 'Pharmacy') lockReasons[l.id] = 'Pharmacy item (stock) -- cannot be edited here';
    else if (l.service_code && packageCodes.has(l.service_code)) lockReasons[l.id] = 'Surgery package -- cannot be edited here';
  }

  return {
    canEdit: !blockReason,
    blockReason,
    lockReasons,
    services: services || [],
    lines: lines || [],
    invoice,
  };
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
    ...(legacy || []).map((l) => ({
      id: l.id, at: l.modified_at, by: names[l.modified_by] || 'Unknown', action: l.action,
      reason: l.reason, details: l.details,
    })),
  ].sort((a, b) => new Date(b.at) - new Date(a.at));

  return entries;
}
