// Builds a payment's change history from ui_payment_detail()'s `audit`
// (billing_audit_log) and `edits` (payment_edits) arrays -- same output
// as the older getPaymentHistory(): newest first, and older clerical
// edits that the new edit flow also wrote at the same moment are skipped.
export function buildPaymentHistory(audit = [], edits = []) {
  const auditTimes = new Set(audit.map((a) => String(a.at || '').slice(0, 19)));
  return [
    ...audit.map((a) => ({ id: a.id, at: a.at, by: a.by || 'Unknown', action: a.action, reason: a.reason, before: a.before, after: a.after })),
    ...edits
      .filter((o) => !auditTimes.has(String(o.at || '').slice(0, 19)))
      .map((o) => ({
        id: o.id, at: o.at, by: o.by || 'Unknown', action: 'older_edit', reason: o.reason,
        older: { oldAmount: o.old_amount, newAmount: o.new_amount, oldModes: o.old_modes, newModes: o.new_modes },
      })),
  ].sort((a, b) => new Date(b.at) - new Date(a.at));
}

// Edit / delete availability for a payment -- the same rules the screen
// always showed (the database enforces them again on save).
export function paymentEditFlags(base) {
  const p = base.payment;
  const perms = base.perms || {};
  const closed = !!base.dayClosed;
  const editable = ['invoice_payment', 'advance'].includes(p.payment_type);
  const deletable = ['invoice_payment', 'advance', 'advance_adjustment'].includes(p.payment_type);

  let editBlock = null;
  if (!editable) editBlock = p.payment_type === 'advance_adjustment'
    ? 'This is an application of existing credit, not money received. It can only be removed (the credit goes back to the patient).'
    : 'Credit notes and refunds are cancelled from their own screens, not edited here.';
  else if (closed) editBlock = 'This payment is from a closed day. An Administrator must reopen that day in Cash Management first.';
  else if (base.hasRefund) editBlock = 'This payment has a refund recorded against it. Cancel that refund first (Payments > Refund).';
  else if (!perms['payment.edit']) editBlock = 'You do not have permission to edit payments.';
  // (Zoho-style, Oct 2026: any date can be edited -- no "today only" rule.)

  let deleteBlock = null;
  if (!deletable) deleteBlock = 'Credit notes and refunds are cancelled from their own screens.';
  else if (closed) deleteBlock = 'This payment is from a closed day.';
  else if (base.hasRefund) deleteBlock = 'Cancel the refund on this payment first.';
  else if (!perms['payment.delete']) deleteBlock = 'You do not have permission to delete payments.';

  return {
    canEdit: !editBlock,
    editBlock,
    canDelete: !deleteBlock,
    deleteBlock,
    canChangeDate: !!perms['payment.edit'] || !!base.isAdmin, // anyone who can edit can change the date
  };
}
