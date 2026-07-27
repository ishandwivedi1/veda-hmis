'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function PaymentsTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true); // assume open until checked, to avoid a flash of warning on every load

  useEffect(() => { isTodayOpen().then(setDayOpen); }, []);

  return (
    <div>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today's cash day hasn't been opened -- collecting or refunding payments is blocked until it is.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
        </div>
      )}
      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
        {TABS.map((t) => (
          <Link
            key={t.href}
            href={t.href}
            className={pathname === t.href ? 'btn btn-primary' : 'btn'}
            style={{ textDecoration: 'none' }}
          >
            <i className={`ti ${t.icon}`}></i> {t.label}
          </Link>
        ))}
      </div>
    </div>
  );
}

