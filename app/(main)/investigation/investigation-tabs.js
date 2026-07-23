'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/investigation', label: 'Queue', icon: 'ti-list-numbers' },
  { href: '/investigation/history', label: 'History', icon: 'ti-history' },
  { href: '/investigation/comparison', label: 'Comparison', icon: 'ti-chart-bar-off' },
  { href: '/investigation/reports', label: 'Reports', icon: 'ti-chart-bar' },
];

export default function InvestigationTabs() {
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

