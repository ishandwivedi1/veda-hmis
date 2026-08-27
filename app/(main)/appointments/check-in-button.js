'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { checkInAppointment } from '../visits/actions';

export default function CheckInButton({ appointmentId }) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');
  const router = useRouter();

  async function handleClick() {
    setLoading(true);
    setError('');
    const result = await checkInAppointment(appointmentId);
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    // Same redirect as the walk-in flow -- a Surgery/Surgery
    // Evaluation/Investigation Only appointment lands directly on the
    // patient's Surgical Journey case, not a generic dashboard.
    if (result.surgicalCaseId) {
      router.push(`/surgical-journey/${result.surgicalCaseId}`);
      return;
    }

    // OPD Procedure Only skips the doctor queue entirely and lands on
    // the patient's OPD Procedures workspace instead.
    if (result.visit?.visit_type === 'OPD Procedure Only' && result.visit?.patient_id) {
      router.push(`/opd-procedures/${result.visit.patient_id}`);
      return;
    }

    router.push('/front-office-dashboard?visitCreated=1');
  }

  return (
    <div>
      <button className="btn btn-primary" style={{ padding: '4px 10px', fontSize: 12 }} onClick={handleClick} disabled={loading}>
        {loading ? '...' : 'Check In'}
      </button>
      {error && <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 4 }}>{error}</div>}
    </div>
  );
}

