import { Suspense } from 'react';
import PaymentsTabs from '../payments-tabs';
import AdvanceTab from './advance-tab';

export default function AdvancePage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
        <AdvanceTab />
      </Suspense>
    </div>
  );
}

