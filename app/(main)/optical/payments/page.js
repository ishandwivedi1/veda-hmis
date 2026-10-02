import { Suspense } from 'react';
import OpticalPaymentsScreen from './optical-payments-screen';

// Optical Payments = Zoho-style receipts screen (Oct 2026), like hospital
// Payments: list + receipt pane with Edit / Delete / Refund / Print.
// One request per load and per click.
export default function OpticalPaymentsPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <OpticalPaymentsScreen />
    </Suspense>
  );
}
