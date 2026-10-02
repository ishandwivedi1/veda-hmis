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
import { isTodayOpen } from '@/lib/rpc-reads/cash-management__actions'; // parallel reads (tools/parallel-reads)

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

  useEffect(() => {
    isTodayOpen().then(setDayOpen).catch(() => {});
    setIsPopup(new URLSearchParams(window.location.search).get('popup') === '1');
  }, []);

  const title = isPopup ? null : TITLES[pathname];

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today&apos;s cash day hasn&apos;t been opened -- collecting or refunding payments is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
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
