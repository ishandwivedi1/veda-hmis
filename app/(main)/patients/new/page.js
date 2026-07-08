'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient } from '@/app/(main)/patients/actions';

export default function NewPatientPage() {
  const [values, setValues] = useState({
    firstName: '',
    lastName: '',
    age: '',
    gender: '',
    mobile: '',
    address: '',
    bloodGroup: '',
  });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  function update(field) {
    return (e) => setValues((v) => ({ ...v, [field]: e.target.value }));
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!values.firstName || !values.lastName || !values.gender || !values.mobile) {
      setError('First name, last name, gender, and mobile are required.');
      return;
    }
    if (values.mobile.length !== 10) {
      setError('Mobile number must be 10 digits.');
      return;
    }

    setLoading(true);
    const result = await registerPatient(values);
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push(`/patients?registered=${result.patient.uhid}`);
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-user-plus" style={{ color: 'var(--blue)', marginRight: 6 }}></i>
          Register New Patient
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          UHID is generated automatically on save.
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">First name *</label>
              <input className="fi" value={values.firstName} onChange={update('firstName')} required />
            </div>
            <div>
              <label className="flbl">Last name *</label>
              <input className="fi" value={values.lastName} onChange={update('lastName')} required />
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Age</label>
              <input type="number" className="fi" value={values.age} onChange={update('age')} />
            </div>
            <div>
              <label className="flbl">Gender *</label>
              <select className="fi" value={values.gender} onChange={update('gender')} required>
                <option value="">-- Select --</option>
                <option value="M">Male</option>
                <option value="F">Female</option>
                <option value="O">Other</option>
              </select>
            </div>
          </div>

          <div style={{ marginBottom: 12 }}>
            <label className="flbl">Mobile *</label>
            <input className="fi" value={values.mobile} onChange={update('mobile')} maxLength={10} required />
          </div>

          <div style={{ marginBottom: 12 }}>
            <label className="flbl">Address</label>
            <input className="fi" value={values.address} onChange={update('address')} />
          </div>

          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Blood group</label>
            <select className="fi" value={values.bloodGroup} onChange={update('bloodGroup')}>
              <option value="">-- Unknown --</option>
              <option>A+</option><option>A-</option>
              <option>B+</option><option>B-</option>
              <option>AB+</option><option>AB-</option>
              <option>O+</option><option>O-</option>
            </select>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Registering...' : 'Register Patient'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

