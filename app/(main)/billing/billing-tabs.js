'use client';

// Billing header (2 Oct 2026: the tab bar is gone -- Billing is one
// Zoho-style Invoices screen at /billing). Every billing page still
// renders this component, so it now shows only a slim "day not opened"
// bar (with Open Day right here) and, on New Invoice / Reports, a
// "<- Invoices" link back to the list. Name kept so imports don't change.

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen, getSuggestedOpeningBalance } from '@/lib/rpc-reads/cash-management__actions'; // parallel reads (tools/parallel-reads)
import { openDay } from '@/app/(main)/cash-management/actions';

const TITLES = {
  '/billing/new': 'New Invoice',
  '/billing/reports': 'Billing Reports',
};

export default function BillingTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true); // assume open until checked, to avoid a flash on every load
  const [isPopup, setIsPopup] = useState(false);
  const [opening, setOpening] = useState('');
  const [suggestedFrom, setSuggestedFrom] = useState(null);
  const [busy, setBusy] = useState(false);
  const [openErr, setOpenErr] = useState('');

  useEffect(() => {
    isTodayOpen().then((open) => {
      setDayOpen(open);
      if (!open) getSuggestedOpeningBalance().then((s) => { if (s) { setOpening(String(s.amount)); setSuggestedFrom(s.date); } }).catch(() => {});
    }).catch(() => {});
    setIsPopup(new URLSearchParams(window.location.search).get('popup') === '1');
  }, []);

  async function handleOpenDay() {
    if (busy) return;
    setBusy(true); setOpenErr('');
    const res = await openDay(Number(opening) || 0, 'Opened from Billing');
    setBusy(false);
    if (res?.error) { setOpenErr(res.error); return; }
    setDayOpen(true);
  }

  const title = isPopup ? null : TITLES[pathname];

  return (
    <div>
      {!dayOpen && (
        <div style={{ marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8, flexWrap: 'wrap', padding: '6px 10px', borderRadius: 8, background: 'var(--amber-lt, #fff7e6)', border: '1px solid #fcd34d', fontSize: 12.5 }}>
          <span style={{ color: '#92400e', fontWeight: 600 }}><i className="ti ti-lock"></i> Today isn&apos;t open -- collecting money (incl. package advances) is blocked.</span>
          <span style={{ color: 'var(--g600)' }}>Opening cash ₹</span>
          <input className="fi fi-sm" type="number" min="0" style={{ width: 100 }} value={opening} onChange={(e) => setOpening(e.target.value)}
            title={suggestedFrom ? `Carried forward from ${suggestedFrom}` : 'Cash in the drawer now'} />
          <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={handleOpenDay}>{busy ? 'Opening...' : 'Open Day'}</button>
          {openErr && <span style={{ color: 'var(--red)' }}>{openErr}</span>}
        </div>
      )}
      {title && (
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
          <Link href="/billing" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-arrow-left"></i> Invoices</Link>
          <span style={{ fontSize: 20, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>{title}</span>
        </div>
      )}
    </div>
  );
}
