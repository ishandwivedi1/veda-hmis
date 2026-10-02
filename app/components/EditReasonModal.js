'use client';

// "Reason for this change" popup shown when Save is pressed on an invoice
// or payment edit (Zoho-style editing: every field editable, the reason is
// recorded with the change in the audit history). Built on the shared
// ConfirmActionModal so it looks like every other confirm popup.

import { useState } from 'react';
import ConfirmActionModal from '@/app/components/ConfirmActionModal';

export default function EditReasonModal({ title = 'Reason for this change', summary, saving = false, error = '', onSave, onCancel }) {
  const [reason, setReason] = useState('');
  const [localError, setLocalError] = useState('');

  function handleSave() {
    if (!reason.trim()) { setLocalError('Please write a reason.'); return; }
    setLocalError('');
    onSave(reason.trim());
  }

  return (
    <ConfirmActionModal
      icon="ti-pencil"
      iconColor="var(--blue)"
      iconBg="var(--blue-lt)"
      title={title}
      description={summary || 'This reason is saved with the change in the history.'}
      confirmLabel="Save changes"
      workingLabel="Saving..."
      loading={saving}
      onConfirm={handleSave}
      onCancel={onCancel}
    >
      <textarea
        className="fi"
        rows={3}
        autoFocus
        value={reason}
        onChange={(e) => setReason(e.target.value)}
        placeholder="e.g. Wrong price entered / senior citizen discount / paid by UPI not cash"
        style={{ width: '100%', resize: 'vertical' }}
      />
      {(localError || error) && <div className="msg-err" style={{ marginTop: 8, marginBottom: 0 }}>{localError || error}</div>}
    </ConfirmActionModal>
  );
}
