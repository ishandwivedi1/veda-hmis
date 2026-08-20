'use client';

import { useRouter } from 'next/navigation';

// Shared by any flow that just created a visit and wants to offer an
// immediate path to billing instead of silently redirecting -- used by
// Patient Registration's "Register & Create Visit" and the Visits
// module's "Create Walk-in Visit" form. Deliberately generic: callers
// pass their own title/subtitle since "Patient Registered & Visit
// Created" and "Visit Created" read differently even though the visit
// itself and the two actions available are identical.
export default function VisitCreatedModal({ title, subtitle, visit, onClose }) {
  const router = useRouter();
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div style={{ background: '#fff', borderRadius: 12, padding: 22, maxWidth: 420, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <span style={{ width: 36, height: 36, borderRadius: '50%', background: '#dcfce7', color: 'var(--green)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 20 }}></i>
          </span>
          <div>
            <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--g800)' }}>{title}</div>
            {subtitle && <div style={{ fontSize: 12, color: 'var(--g500)' }}>{subtitle}</div>}
          </div>
        </div>
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 18, lineHeight: 1.5 }}>
          Visit {visit.visit_number ? <strong>{visit.visit_number}</strong> : 'has'} been created for today.
          {visit.doctor_name && <> Assigned to <strong>{visit.doctor_name}</strong>.</>}
          {' '}Create the invoice now, or come back to it later from the Billing Dashboard.
        </div>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" className="btn btn-sm" onClick={onClose}>Return to Dashboard</button>
          <button type="button" className="btn btn-sm btn-primary" onClick={() => router.push(`/billing/new?visitId=${visit.id}`)}>
            <i className="ti ti-receipt"></i> Create Invoice
          </button>
        </div>
      </div>
    </div>
  );
}
