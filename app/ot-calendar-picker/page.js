'use client';

import { Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import OTCalendar from '@/app/(main)/ot-schedule/ot-calendar';

function PickerInner() {
  const searchParams = useSearchParams();
  const pickFor = searchParams.get('pickFor');
  const pickLabel = searchParams.get('pickLabel') || '';

  return (
    <div style={{ padding: 16, maxWidth: 420, margin: '0 auto' }}>
      <div style={{ fontSize: 15, fontWeight: 700, marginBottom: 12 }}>
        <i className="ti ti-calendar"></i> Pick a Surgery Date
      </div>
      <OTCalendar pickFor={pickFor} pickLabel={pickLabel} />
    </div>
  );
}

// Deliberately outside the (main) route group -- no sidebar/header
// chrome, same pattern as the print routes (investigation-print,
// biometry-print, etc). This keeps the popup window small and focused
// instead of squeezing a full app layout into a 460x680 window.
export default function OTCalendarPickerPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <PickerInner />
    </Suspense>
  );
}
