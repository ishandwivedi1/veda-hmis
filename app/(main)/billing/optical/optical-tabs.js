'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/billing/optical/new', label: 'New Bill', icon: 'ti-file-plus' },
  { href: '/billing/optical/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/billing/optical/advance', label: 'Advance', icon: 'ti-piggy-bank' },
  { href: '/billing/optical/history', label: 'History', icon: 'ti-history' },
];

export default function OpticalTabs() {
  const pathname = usePathname();
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Link key={t.href} href={t.href} className={pathname === t.href ? 'btn btn-sm btn-primary' : 'btn btn-sm'} style={{ textDecoration: 'none' }}>
          <i className={`ti ${t.icon}`}></i> {t.label}
        </Link>
      ))}
    </div>
  );
}
