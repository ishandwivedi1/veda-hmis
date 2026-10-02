import { Suspense } from 'react';
import InvoicesScreen from './invoices/invoices-screen';

// Billing is one Zoho-style Invoices screen. The page itself fetches
// nothing (no server-side waiting before it shows); the screen loads
// everything -- day status, summary, To-bill lists, invoices -- in ONE
// request (getBillingScreenData).
export default function BillingPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <InvoicesScreen />
    </Suspense>
  );
}
