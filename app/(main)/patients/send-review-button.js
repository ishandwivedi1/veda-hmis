'use client';

import { useState } from 'react';
import { sendReviewRequestForPatient } from './actions';

// Manual, entirely staff-initiated -- same as the per-visit button on
// the Visits list and the patient-level one on Clinical Timeline.
// Nothing triggers this automatically. A small client island since
// the Patients list itself is a Server Component.
export default function SendReviewButton({ patientId, mobile }) {
  const [status, setStatus] = useState(''); // '', 'sending', 'sent', 'warning', 'error'
  const [msg, setMsg] = useState('');

  async function handleClick() {
    setStatus('sending');
    setMsg('');
    const result = await sendReviewRequestForPatient(patientId);
    if (result.error) { setStatus('error'); setMsg(result.error); return; }
    if (result.warning) { setStatus('warning'); setMsg(result.warning); return; }
    setStatus('sent');
  }

  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4 }}>
      <button
        className="btn"
        style={{ padding: '4px 10px', fontSize: 12 }}
        title="Send Review Request"
        onClick={handleClick}
        disabled={status === 'sending' || !mobile}
      >
        <i className="ti ti-star" style={{ color: 'var(--amber)' }}></i>
      </button>
      {status === 'sent' && <span style={{ fontSize: 10, color: 'var(--green)' }}><i className="ti ti-circle-check"></i></span>}
      {status === 'warning' && <span style={{ fontSize: 10, color: 'var(--amber)' }} title={msg}><i className="ti ti-alert-triangle"></i></span>}
      {status === 'error' && <span style={{ fontSize: 10, color: 'var(--red)' }} title={msg}><i className="ti ti-alert-circle"></i></span>}
    </span>
  );
}
