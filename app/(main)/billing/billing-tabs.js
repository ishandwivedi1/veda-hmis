'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { isTodayOpen } from '@/app/(main)/cash-management/actions';

const TABS = [
  { href: '/billing', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/billing/new', label: 'New Invoice', icon: 'ti-file-plus' },
  { href: '/billing/details', label: 'Invoice Details', icon: 'ti-search' },
  { href: '/billing/cancel', label: 'Invoice Modification', icon: 'ti-edit' },
  { href: '/billing/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function BillingTabs() {
  const pathname = usePathname();
  const [dayOpen, setDayOpen] = useState(true);

  useEffect(() => { isTodayOpen().then(setDayOpen); }, []);

  // Returns a Fragment, not a wrapping <div> -- position: sticky only
  // stays "stuck" for as long as its immediate parent's box is still in
  // view. A wrapping div here would be barely taller than the tab bar
  // itself, so the tabs would appear to stick for a moment then scroll
  // away immediately. As a Fragment, the sticky div becomes a direct
  // sibling of the page's own content below it, giving it the full
  // page height to actually remain stuck through.
  return (
    <>
      {!dayOpen && (
        <div className="msg-err" style={{ marginBottom: 12, display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 }}>
          <span><i className="ti ti-lock"></i> Today's cash day hasn't been opened -- Package Billing advance collection will be blocked until it is. Plain invoicing without an advance still works.</span>
          <Link href="/cash-management" className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}>Open Day in Cash Management</Link>
        </div>
      )}
      <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap', position: 'sticky', top: 0, zIndex: 8, background: '#fff', padding: '8px 0' }}>
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
    </>
  );
}


