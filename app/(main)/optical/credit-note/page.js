import { Suspense } from 'react';
// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import OpticalCreditNoteTab from './optical-credit-note-tab';

export default function OpticalCreditNotePage() {
  return (
    <div>
      <OpticalHeader title="Credit Note" />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <OpticalCreditNoteTab />
      </Suspense>
    </div>
  );
}
