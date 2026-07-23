import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import NewInvoiceTab from './new-invoice-tab';

export default async function NewInvoicePage({ searchParams }) {
  const params = await searchParams;
  // A fresh key on every render forces React to fully remount (not
  // just re-render) NewInvoiceTab each time this page is navigated to.
  // "New Invoice" is meant to always start clean -- any context that
  // should carry over comes explicitly through visitId/invOrderIds in
  // the URL, not through leftover component state from whatever was
  // being billed last. Without this, React reuses the same instance
  // across visits to this route and a previous patient/line items can
  // silently carry over into what looks like an independent invoice.
  const remountKey = `${params?.visitId || 'none'}-${params?.invOrderIds || 'none'}-${Date.now()}`;

  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <NewInvoiceTab key={remountKey} />
      </Suspense>
    </div>
  );
}


