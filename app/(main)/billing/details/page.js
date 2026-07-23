import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import InvoiceDetailsTab from './invoice-details-tab';

export default async function InvoiceDetailsPage({ searchParams }) {
  const params = await searchParams;
  const remountKey = `${params?.q || 'none'}-${Date.now()}`;

  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoiceDetailsTab key={remountKey} />
      </Suspense>
    </div>
  );
}


