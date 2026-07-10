import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import NewInvoiceTab from './new-invoice-tab';

export default function NewInvoicePage() {
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <NewInvoiceTab />
      </Suspense>
    </div>
  );
}

