import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import InvoiceDetailsTab from './invoice-details-tab';

export default function InvoiceDetailsPage() {
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoiceDetailsTab />
      </Suspense>
    </div>
  );
}

