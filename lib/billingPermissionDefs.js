// Plain constants (no server imports) so both client components and
// server code can share them. The keys must match the CHECK constraint on
// public.billing_permissions (supabase/migrations/036_billing_edit_foundation.sql).

export const BILLING_PERMISSIONS = [
  { key: 'invoice.edit',      group: 'Invoices', label: 'Edit invoices (today)',          help: 'Change items, quantity, discount on an invoice dated today.' },
  { key: 'invoice.edit_past', group: 'Invoices', label: 'Edit invoices (earlier days)',   help: 'Same as above for invoices from an earlier day that has not been closed.' },
  { key: 'invoice.void',      group: 'Invoices', label: 'Void invoices',                  help: 'Void an invoice. Any payment on it becomes patient credit.' },
  { key: 'payment.edit',      group: 'Payments', label: 'Edit payments (today)',          help: 'Change amount, mode, reference or the invoice a payment is applied to.' },
  { key: 'payment.edit_past', group: 'Payments', label: 'Edit payments (earlier days)',   help: 'Same as above for payments from an earlier day that has not been closed.' },
  { key: 'payment.delete',    group: 'Payments', label: 'Delete payments',                help: 'Delete a payment. It stays visible in history as Deleted.' },
];

export const BILLING_PERMISSION_KEYS = BILLING_PERMISSIONS.map((p) => p.key);
