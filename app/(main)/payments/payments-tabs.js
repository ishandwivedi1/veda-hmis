'use client';

// Payments header (2 Oct 2026: the tab bar is gone -- Payments is one
// Zoho-style screen at /payments; Record Payment, Advance, Apply Advance,
// Refund, Credit Note, Reports and Ledger open from its "+ New" / "..."
// menus). Every payments page still renders this component, so it now
// shows just the "day not opened" warning and, on the form pages, a
// "<- Payments" link back to the list. Name kept so existing pages and
// imports don't change.

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen, getSuggestedOpeningBalance } from '@/lib/rpc-reads/cash-management__actions'; // parallel reads (tools/parallel-reads)
import { openDay } from '@/app/(main)/cash-management/actions';

const TITLES = {
  '/payments/collect': 'Record Payment',
  '/payments/advance': 'Advance',
  '/payments/adjustments': 'Apply Advance',
  '/payments/refund': 'Refund',
  '/payments/credit-note': 'Credit Note',
  '/payments/reports': 'Payment Reports',
  '/payments/ledger': 'Patient Ledger',
};

export default function PaymentsTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true); // assume open until checked, to avoid a flash of warning on every load

  // Opened as a popup from another screen (e.g. Collect Payment with
  // ?popup=1): no "back to Payments" link there.
  const [isPopup, setIsPopup] = useState(false);

  // Slim "day not opened" bar with Open Day right here (same open_day as
  // Cash Management), instead of a big banner sending people elsewhere.
  const [opening, setOpening] = useState('');
  const [suggestedFrom, setSuggestedFrom] = useState(null);
  const [busy, setBusy] = useState(false);
  const [openErr, setOpenErr] = useState('');

  async function handleOpenDay() {
    if (busy) return;
    setBusy(true); setOpenErr('');
    const res = await openDay(Number(opening) || 0, 'Opened from Payments');
    setBusy(false);
    if (res?.error) { setOpenErr(res.error); return; }
    setDayOpen(true);
  }

  useEffect(() => {
    isTodayOpen().then((open) => {
      setDayOpen(open);
      if (!open) getSuggestedOpeningBalance().then((s) => { if (s) { setOpening(String(s.amount)); setSuggestedFrom(s.date); } }).catch(() => {});
    }).catch(() => {});
    setIsPopup(new URLSearchParams(window.location.search).get('popup') === '1');
  }, []);

  const title = isPopup ? null : TITLES[pathname];

  return (
    <div>
      {!dayOpen && (
        <div style={{ marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', padding: '6px 10px', borderRadius: 8, background: 'var(--amber-lt, #fff7e6)', border: '1px solid #fcd34d', fontSize: 12.5 }}>
          <span style={{ color: '#92400e', fontWeight: 600 }}><i className="ti ti-lock"></i> Today isn&apos;t open -- payments are blocked.</span>
          <span style={{ color: 'var(--g600)' }}>Opening cash ₹</span>
          <input className="fi fi-sm" type="number" min="0" style={{ width: 100 }} value={opening} onChange={(e) => setOpening(e.target.value)}
            title={suggestedFrom ? `Carried forward from ${suggestedFrom}` : 'Cash in the drawer now'} />
          <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={handleOpenDay}>{busy ? 'Opening...' : 'Open Day'}</button>
          {openErr && <span style={{ color: 'var(--red)' }}>{openErr}</span>}
        </div>
      )}
      {title && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
          <Link href="/payments" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-arrow-left"></i> Payments</Link>
          <span style={{ fontSize: 20, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>{title}</span>
        </div>
      )}
    </div>
  );
}
