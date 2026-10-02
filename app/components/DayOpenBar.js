'use client';

// Slim "today isn't open" bar with Open Day inline. Fed by the screen's
// own single load request (ui_day_status), so it makes no request of its
// own -- only pressing Open Day calls the server (open_day).

import { useState, useEffect } from 'react';
import { openDay } from '@/app/(main)/cash-management/actions';

export default function DayOpenBar({ status, note = 'payments are blocked', source = 'Payments' }) {
  const [open, setOpen] = useState(true);
  const [opening, setOpening] = useState('');
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState('');

  useEffect(() => {
    if (!status) return;
    setOpen(!!status.open);
    if (!status.open && status.suggested) setOpening(String(Number(status.suggested.amount) || 0));
  }, [status]);

  if (!status || open) return null;

  async function handleOpen() {
    if (busy) return;
    setBusy(true); setErr('');
    const res = await openDay(Number(opening) || 0, `Opened from ${source}`);
    setBusy(false);
    if (res?.error) { setErr(res.error); return; }
    setOpen(true);
  }

  return (
    <div style={{ marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', padding: '6px 10px', borderRadius: 8, background: 'var(--amber-lt, #fff7e6)', border: '1px solid #fcd34d', fontSize: 12.5 }}>
      <span style={{ color: '#92400e', fontWeight: 600 }}><i className="ti ti-lock"></i> Today isn&apos;t open -- {note}.</span>
      <span style={{ color: 'var(--g600)' }}>Opening cash ₹</span>
      <input className="fi fi-sm" type="number" min="0" style={{ width: 100 }} value={opening} onChange={(e) => setOpening(e.target.value)}
        title={status.suggested?.date ? `Carried forward from ${status.suggested.date}` : 'Cash in the drawer now'} />
      <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={handleOpen}>{busy ? 'Opening...' : 'Open Day'}</button>
      {err && <span style={{ color: 'var(--red)' }}>{err}</span>}
    </div>
  );
}
