'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

const TABS = [
  { href: '/optical/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/optical/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/optical/advance', label: 'Advance', icon: 'ti-piggy-bank' },
  { href: '/optical/credit-note', label: 'Credit Note', icon: 'ti-file-minus' },
  { href: '/optical/refund', label: 'Refund', icon: 'ti-receipt-refund' },
  { href: '/optical/payments', label: 'Optical Payments', icon: 'ti-list-details' },
  { href: '/optical/history', label: 'Bills History', icon: 'ti-history' },
];
// Book Spectacles, Finalize Order, and New Bill are deliberately not
// tabs here -- three "start something new" entry points sitting in
// the top bar alongside seven other tabs made it unclear which button
// actually started a fresh transaction versus managed an existing
// one. They live as Quick Actions on the Dashboard instead (see
// optical-dashboard-tab.js), which is also the only page any of them
// need to link back to when done.

export default function OpticalTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true); // assume open until checked, to avoid a flash of warning on every load

  useEffect(() => { isTodayOpen().then(setDayOpen); }, []);

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today's cash day hasn't been opened -- creating bills or collecting payments/advances is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
        </div>
      )}
      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <Link key={t.href} href={t.href} className={pathname === t.href ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
            <i className={`ti ${t.icon}`}></i> {t.label}
          </Link>
        ))}
      </div>
    </div>
  );
}
