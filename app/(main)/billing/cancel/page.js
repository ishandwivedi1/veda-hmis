import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import InvoiceModificationTab from './invoice-modification-tab';

export default async function InvoiceModificationPage({ searchParams }) {
  const params = await searchParams;
  // Same fix as New Invoice / Collect Payment: a fresh key forces a
  // clean remount each visit, so a previously selected invoice doesn't
  // stick around in this component's local state.
  const remountKey = `${params?.visitId || 'none'}-${Date.now()}`;

  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoiceModificationTab key={remountKey} />
      </Suspense>
    </div>
  );
}


