'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/billing', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/billing/new', label: 'New Invoice', icon: 'ti-file-plus' },
  { href: '/billing/package', label: 'Package Billing', icon: 'ti-package' },
  { href: '/billing/details', label: 'Invoice Details', icon: 'ti-search' },
  { href: '/billing/cancel', label: 'Cancellation', icon: 'ti-x-circle' },
  { href: '/billing/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function BillingTabs() {
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

