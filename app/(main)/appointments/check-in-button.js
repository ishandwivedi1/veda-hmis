'use client';

import { useState } from 'react';
import { checkInAndOpenNext } from './check-in-actions';

export default function CheckInButton({ appointmentId }) {
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState('');

  // ONE request: the check-in and the next screen come back together
  // (see check-in-actions.js) -- Surgery / Surgery Evaluation /
  // Investigation Only land on the patient's Surgical Journey case, OPD
  // Procedure Only on the OPD Procedures workspace, anything else back on
  // the Front Office Dashboard, same as before. The button stays disabled
  // until the next screen opens, so a second click can't check in twice.
  async function handleClick() {
    setLoading(true);
    setError('');
    const result = await checkInAndOpenNext(appointmentId);
    if (result?.error) {
      setLoading(false);
      setError(result.error);
    }
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
