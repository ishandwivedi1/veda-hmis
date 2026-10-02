import { Suspense } from 'react';
import CreditNoteTab from './credit-note-tab';
import PaymentsTabs from '../payments-tabs';

export default function CreditNotePage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <CreditNoteTab />
      </Suspense>
    </div>
  );
}

