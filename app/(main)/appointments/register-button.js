'use client';

import { useRouter } from 'next/navigation';

export default function RegisterUnregisteredButton({ appointmentId, tempName, tempMobile }) {
  const router = useRouter();

  function handleClick() {
    const params = new URLSearchParams({
      returnTo: 'appointment',
      appointmentId,
      prefillFirstName: tempName?.split(' ')[0] || '',
      prefillLastName: tempName?.split(' ').slice(1).join(' ') || '',
      prefillMobile: tempMobile || '',
    });
    router.push(`/patients/new?${params.toString()}`);
  }

  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
      <span className="badge b-red">Not registered</span>
      <button className="btn btn-primary btn-sm" onClick={handleClick}>
        Register
      </button>
    </div>
  );
}

