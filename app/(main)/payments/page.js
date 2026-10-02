import { Suspense } from 'react';
import PaymentsReceived from './received/payments-received';

// Payments is one Zoho-style screen (2 Oct 2026): today's summary strip,
// the payments list, and a split view to open, edit, print or WhatsApp a
// receipt. "+ New" opens Record Payment / Advance / Apply Advance / Refund
// / Credit Note; "..." has Reports, Patient Ledger and Deleted Receipts.
// (The old dashboard and tab bar were retired.)
// The day bar comes from the screen's own single load request (no
// separate header request on this page).
export default function PaymentsPage() {
  return (
    <div>
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <PaymentsReceived />
      </Suspense>
    </div>
  );
}
