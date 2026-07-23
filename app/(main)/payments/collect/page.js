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


