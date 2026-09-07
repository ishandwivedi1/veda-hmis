import { Suspense } from 'react';
import OpticalTabs from '../optical-tabs';
import OpticalCreditNoteTab from './optical-credit-note-tab';

export default function OpticalCreditNotePage() {
  return (
    <div>
      <OpticalTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <OpticalCreditNoteTab />
      </Suspense>
    </div>
  );
}
