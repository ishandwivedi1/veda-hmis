'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/pharmacy', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/pharmacy/inventory', label: 'Inventory', icon: 'ti-boxes' },
  { href: '/pharmacy/history', label: 'History', icon: 'ti-history' },
];

export default function PharmacyTabs() {
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
