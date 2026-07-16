import { Suspense } from 'react';
import PaymentsTabs from '../payments-tabs';
import CollectPaymentTab from './collect-payment-tab';

export default function CollectPaymentPage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <CollectPaymentTab />
      </Suspense>
    </div>
  );
}

