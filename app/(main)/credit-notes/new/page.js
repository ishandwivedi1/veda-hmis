import { Suspense } from 'react';
import Link from 'next/link';
import NewCreditNote from './new-credit-note';

export default async function NewCreditNotePage({ searchParams }) {
  const params = (await searchParams) || {};
  const key = `${params.patientId || 'none'}-${params.invoiceId || 'none'}`;
  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14 }}>
        <Link href="/credit-notes" className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-arrow-left"></i> Credit Notes</Link>
        <span style={{ fontSize: 20, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>New Credit Note</span>
      </div>
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <NewCreditNote key={key} />
      </Suspense>
    </div>
  );
}
