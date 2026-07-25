#!/bin/bash
set -e

echo 'Applying: fix stale patient/invoice data in Collect Payment, Invoice Modification, Invoice Details...'

mkdir -p 'app/(main)/payments/collect' 'app/(main)/billing/cancel' 'app/(main)/billing/details'

cat > 'app/(main)/payments/collect/page.js' << 'COLLECT_PAGE_EOF'
import { Suspense } from 'react';
import PaymentsTabs from '../payments-tabs';
import CollectPaymentTab from './collect-payment-tab';

export default async function CollectPaymentPage({ searchParams }) {
  const params = await searchParams;
  // Same fix as New Invoice: without a fresh key, React reuses the same
  // CollectPaymentTab instance across visits to this route, so a
  // previously selected patient (e.g. from a prior payment collection)
  // stays in local state and shows up pre-filled the next time someone
  // opens Collect Payment, even for a completely unrelated patient.
  const remountKey = `${params?.patientId || 'none'}-${params?.invoiceId || 'none'}-${Date.now()}`;

  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <CollectPaymentTab key={remountKey} />
      </Suspense>
    </div>
  );
}


COLLECT_PAGE_EOF

cat > 'app/(main)/billing/cancel/page.js' << 'CANCEL_PAGE_EOF'
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


CANCEL_PAGE_EOF

cat > 'app/(main)/billing/details/page.js' << 'DETAILS_PAGE_EOF'
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


DETAILS_PAGE_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/payments/collect/page.js" "app/(main)/billing/cancel/page.js" "app/(main)/billing/details/page.js"'
echo '  git commit -m "Fix stale patient/invoice state persisting across Collect Payment, Invoice Modification, Invoice Details"'
echo '  git push'
