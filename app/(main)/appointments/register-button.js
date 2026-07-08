'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient } from '../patients/actions';
import { linkPatientToAppointment } from './actions';

export default function RegisterUnregisteredButton({ appointmentId, tempName, tempMobile }) {
  const [open, setOpen] = useState(false);
  const [firstName, setFirstName] = useState(tempName?.split(' ')[0] || '');
  const [lastName, setLastName] = useState(tempName?.split(' ').slice(1).join(' ') || '');
  const [gender, setGender] = useState('');
  const [age, setAge] = useState('');
  const [mobile, setMobile] = useState(tempMobile || '');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  async function handleRegister() {
    setError('');
    if (!firstName || !lastName || !gender || !mobile) {
      setError('First name, last name, gender, and mobile are required.');
      return;
    }
    if (mobile.length !== 10) {
      setError('Mobile number must be 10 digits.');
      return;
    }

    setLoading(true);
    const regResult = await registerPatient({ firstName, lastName, age, gender, mobile });
    if (regResult.error) {
      setLoading(false);
      setError(regResult.error);
      return;
    }

    const linkResult = await linkPatientToAppointment(appointmentId, regResult.patient.id);
    setLoading(false);

    if (linkResult.error) {
      setError(linkResult.error);
      return;
    }

    router.refresh();
  }

  if (!open) {
    return (
      <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
        <span
          style={{
            fontSize: 10,
            background: 'var(--red-lt)',
            color: 'var(--red)',
            padding: '1px 6px',
            borderRadius: 8,
          }}
        >
          Not registered
        </span>
        <button className="btn btn-primary" style={{ padding: '3px 8px', fontSize: 11 }} onClick={() => setOpen(true)}>
          Register
        </button>
      </div>
    );
  }

  return (
    <div
      style={{
        position: 'absolute',
        background: '#fff',
        border: '1.5px solid var(--blue-lt)',
        borderRadius: 8,
        padding: 12,
        width: 280,
        zIndex: 10,
        boxShadow: '0 4px 16px rgba(0,0,0,0.12)',
      }}
    >
      <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Register Patient</div>
      {error && <div className="msg-err" style={{ marginBottom: 8, fontSize: 12 }}>{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
        <input className="fi" placeholder="First name *" value={firstName} onChange={(e) => setFirstName(e.target.value)} />
        <input className="fi" placeholder="Last name *" value={lastName} onChange={(e) => setLastName(e.target.value)} />
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 6, marginBottom: 6 }}>
        <select className="fi" value={gender} onChange={(e) => setGender(e.target.value)}>
          <option value="">Gender *</option>
          <option value="M">Male</option>
          <option value="F">Female</option>
          <option value="O">Other</option>
        </select>
        <input type="number" className="fi" placeholder="Age" value={age} onChange={(e) => setAge(e.target.value)} />
      </div>
      <input
        className="fi"
        placeholder="Mobile *"
        value={mobile}
        onChange={(e) => setMobile(e.target.value)}
        maxLength={10}
        style={{ marginBottom: 8 }}
      />
      <div style={{ display: 'flex', gap: 6 }}>
        <button className="btn btn-primary" style={{ fontSize: 11 }} onClick={handleRegister} disabled={loading}>
          {loading ? 'Registering...' : 'Register'}
        </button>
        <button className="btn" style={{ fontSize: 11 }} onClick={() => setOpen(false)}>
          Cancel
        </button>
      </div>
    </div>
  );
}

