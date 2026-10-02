import { Suspense } from 'react';
import RefundTab from './refund-tab';
import PaymentsTabs from '../payments-tabs';

export default function RefundPage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <RefundTab />
      </Suspense>
    </div>
  );
}

