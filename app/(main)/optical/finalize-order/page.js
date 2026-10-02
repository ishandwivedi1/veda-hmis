import { Suspense } from 'react';
// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import FinalizeOrderTab from './finalize-order-tab';

export default function FinalizeOrderPage() {
  return (
    <div>
      <OpticalHeader title="Finalize Order" />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <FinalizeOrderTab />
      </Suspense>
    </div>
  );
}
