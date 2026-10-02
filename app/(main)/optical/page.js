import { Suspense } from 'react';
import OpticalBillsScreen from './bills/optical-bills-screen';

// Optical Bills = Zoho-style Bills screen (Oct 2026), like hospital Billing:
// summary, bills list and a bill pane with Edit / Record Payment / Apply
// Advance / Print / Cancel. The screen loads everything in ONE request;
// every click is one request. The sidebar also has Optical Dashboard
// (Book New Order / Finalize Existing Order) and Optical Payments.
export default function OpticalPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <OpticalBillsScreen />
    </Suspense>
  );
}
