// Plain constants (no server imports) so both client components and
// server code can share them. The keys must match the CHECK constraint on
// public.billing_permissions (supabase/migrations/036_billing_edit_foundation.sql).

// Zoho-style editing (migration 051, Oct 2026): one "Edit" right covers
// any date -- the separate "earlier days" rights were dropped. Closed cash
// days stay locked until an Administrator reopens them.
export const BILLING_PERMISSIONS = [
  { key: 'invoice.edit',      group: 'Invoices', label: 'Edit invoices',   help: 'Change anything on an invoice of any date -- date, items, price, quantity, discount. A paid invoice cannot drop below what has been paid. Closed cash days are locked.' },
  { key: 'invoice.void',      group: 'Invoices', label: 'Void invoices',   help: 'Cancel a paid or past-day invoice; money paid on it becomes patient credit. (Cancelling an unpaid invoice from today only needs "Edit invoices".)' },
  { key: 'payment.edit',      group: 'Payments', label: 'Edit payments',   help: 'Change amount, date, mode, reference or the invoice a payment is applied to, for any date. Closed cash days are locked.' },
  { key: 'payment.delete',    group: 'Payments', label: 'Delete payments', help: 'Delete a payment. It stays visible in history as Deleted.' },
];

export const BILLING_PERMISSION_KEYS = BILLING_PERMISSIONS.map((p) => p.key);
