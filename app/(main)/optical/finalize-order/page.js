import { Suspense } from 'react';
// Header: title + back to Optical Dashboard (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import FinalizeOrderTab from './finalize-order-tab';

export default function FinalizeOrderPage() {
  return (
    <div>
      <OpticalHeader title="Finalize Existing Order" back />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <FinalizeOrderTab />
      </Suspense>
    </div>
  );
}
