import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import InvoiceModificationTab from './invoice-modification-tab';

export default function InvoiceModificationPage() {
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoiceModificationTab />
      </Suspense>
    </div>
  );
}

