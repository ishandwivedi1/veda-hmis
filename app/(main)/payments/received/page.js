import { Suspense } from 'react';
import PaymentsTabs from '../payments-tabs';
import PaymentsReceived from './payments-received';

export default function PaymentsReceivedPage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <PaymentsReceived />
      </Suspense>
    </div>
  );
}
