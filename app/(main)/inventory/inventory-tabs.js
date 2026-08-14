'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/inventory', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/inventory/stock', label: 'Stock', icon: 'ti-boxes' },
  { href: '/inventory/material-input', label: 'Material Input', icon: 'ti-truck-delivery' },
];

export default function InventoryTabs() {
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
