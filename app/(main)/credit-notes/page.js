import { Suspense } from 'react';
import CreditNotesScreen from './credit-notes-screen';

// Credit Notes (Zoho-style): list, split view, apply to invoices, void.
export default function CreditNotesPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <CreditNotesScreen />
    </Suspense>
  );
}
