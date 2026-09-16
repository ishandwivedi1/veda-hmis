import { Suspense } from 'react';
import OpticalTabs from '../optical-tabs';
import FinalizeOrderTab from './finalize-order-tab';

export default function FinalizeOrderPage() {
  return (
    <div>
      <OpticalTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <FinalizeOrderTab />
      </Suspense>
    </div>
  );
}
