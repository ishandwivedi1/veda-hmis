'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/ledger', label: 'Ledger', icon: 'ti-book' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/cancel', label: 'Refund / Modification', icon: 'ti-receipt-refund' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function PaymentsTabs() {
  const pathname = usePathname();
  return (
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
  );
}


