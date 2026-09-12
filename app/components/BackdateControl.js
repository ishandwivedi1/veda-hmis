'use client';

import { useState, useEffect } from 'react';
import { getMyDesignation } from '@/app/(main)/users/actions';

// Dropped into any payment/advance collection form that supports
// admin-only backdating (see lib/backdating.js for the server-side
// rules this pairs with -- Administrator only, mandatory reason,
// target day must not already be closed). Renders nothing at all for
// a non-Administrator; the server re-checks regardless, this is purely
// so the option isn't even visible to staff who can't use it.
//
// `value` is { backdateTo, backdateReason } -- backdateTo is a
// datetime-local string (or '' when off), backdateReason is free text.
// Parent form passes both straight through to the collect action as
// extra params; when backdateTo is empty the action behaves exactly
// as it always did.
export default function BackdateControl({ value, onChange }) {
  const [isAdmin, setIsAdmin] = useState(false);
  const [enabled, setEnabled] = useState(!!value?.backdateTo);

  useEffect(() => { getMyDesignation().then((d) => setIsAdmin(d === 'Administrator')); }, []);

  if (!isAdmin) return null;

  // Datetime-local's max is today's actual local moment, in the same
  // 'YYYY-MM-DDTHH:mm' shape the input itself uses -- keeps the picker
  // from even offering a future date, on top of the server's own check.
  const nowLocal = new Date(Date.now() - new Date().getTimezoneOffset() * 60000).toISOString().slice(0, 16);

  return (
    <div style={{ marginTop: 10, padding: '8px 12px', border: '1px dashed var(--g300)', borderRadius: 8 }}>
      <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, fontWeight: 600, cursor: 'pointer' }}>
        <input
          type="checkbox"
          checked={enabled}
          onChange={(e) => {
            setEnabled(e.target.checked);
            if (!e.target.checked) onChange({ backdateTo: '', backdateReason: '' });
          }}
        />
        <i className="ti ti-clock-back" style={{ color: 'var(--amber)' }}></i> Backdate this entry (Administrator only)
      </label>
      {enabled && (
        <div style={{ display: 'flex', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
          <input
            type="datetime-local"
            className="fi fi-sm"
            style={{ maxWidth: 210 }}
            max={nowLocal}
            value={value?.backdateTo || ''}
            onChange={(e) => onChange({ ...value, backdateTo: e.target.value })}
          />
          <input
            className="fi fi-sm"
            style={{ flex: 1, minWidth: 200 }}
            placeholder="Reason for backdating (required)"
            value={value?.backdateReason || ''}
            onChange={(e) => onChange({ ...value, backdateReason: e.target.value })}
          />
        </div>
      )}
    </div>
  );
}
