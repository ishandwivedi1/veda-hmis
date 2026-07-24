'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

export default function MedicalFitnessTabs({ workspaceId }) {
  const pathname = usePathname();
  const onWorkspace = /^\/medical-fitness\/[^/]+$/.test(pathname) && pathname !== '/medical-fitness/history';

  const tabs = [
    { key: 'queue', href: '/medical-fitness', label: 'Queue (Pending Review)', icon: 'ti-list-numbers', active: pathname === '/medical-fitness' },
    { key: 'workspace', href: workspaceId ? `/medical-fitness/${workspaceId}` : null, label: 'Workspace', icon: 'ti-user-square', active: onWorkspace },
    { key: 'history', href: '/medical-fitness/history', label: 'History', icon: 'ti-history', active: pathname === '/medical-fitness/history' },
  ];

  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {tabs.map((t) =>
        t.href ? (
          <Link key={t.key} href={t.href} className={t.active ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
            <i className={`ti ${t.icon}`}></i> {t.label}
          </Link>
        ) : (
          <span key={t.key} className="btn" style={{ opacity: 0.4, cursor: 'not-allowed' }} title="Open a patient from Queue or History first">
            <i className={`ti ${t.icon}`}></i> {t.label}
          </span>
        )
      )}
    </div>
  );
}

