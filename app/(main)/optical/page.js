import { Suspense } from 'react';
import OpticalBillsScreen from './bills/optical-bills-screen';

// Optical Shop = Zoho-style Bills screen (Oct 2026), like hospital Billing:
// summary, bookings awaiting delivery, bills list and a bill pane with
// Edit / Record Payment / Apply Advance / Credit Note / Print / Cancel.
// The screen loads everything in ONE request; every click is one request.
// Payments has its own screen (/optical/payments); "+ New" opens Book
// Spectacles, Finalize Order, New Bill, Advance, Credit Note, Refund.
export default function OpticalPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <OpticalBillsScreen />
    </Suspense>
  );
}
