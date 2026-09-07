import { Suspense } from 'react';
import OpticalTabs from '../optical-tabs';
import CollectOpticalPaymentTab from './collect-optical-payment-tab';

export default function CollectOpticalPaymentPage() {
  return (
    <div>
      <OpticalTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <CollectOpticalPaymentTab />
      </Suspense>
    </div>
  );
}
