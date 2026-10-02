import { Suspense } from 'react';
// Header: title + back to Optical Dashboard (no requests of its own).
// Orders awaiting delivery are fetched while the page renders on the
// server, so opening Finalize is ONE request (the page itself).
import { OpticalHeader } from '../optical-ui';
import { getOpenOpticalOrders } from '../actions';
import FinalizeOrderTab from './finalize-order-tab';

export const dynamic = 'force-dynamic';

export default async function FinalizeOrderPage() {
  const orders = await getOpenOpticalOrders().catch(() => []);
  return (
    <div>
      <OpticalHeader title="Finalize Existing Order" back />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <FinalizeOrderTab initialOrders={orders} />
      </Suspense>
    </div>
  );
}
