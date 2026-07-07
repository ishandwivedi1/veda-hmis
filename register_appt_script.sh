mkdir -p app/appointments

cat > app/appointments/actions.js << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function searchPatientsForBooking(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);

  if (error) return [];
  return data;
}

export async function getDoctors() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name, designation')
    .ilike('designation', '%ophthalmologist%')
    .eq('status', 'Active');

  if (error) return [];
  return data;
}

export async function linkPatientToAppointment(appointmentId, patientId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('appointments')
    .update({ patient_id: patientId, patient_name_temp: null, mobile_temp: null })
    .eq('id', appointmentId);

  if (error) return { error: error.message };
  return { success: true };
}

export async function createAppointment(values) {
  const supabase = await createClient();

  const payload = {
    patient_id: values.patientId || null,
    patient_name_temp: values.patientId ? null : values.patientName,
    mobile_temp: values.patientId ? null : values.mobile,
    doctor_id: values.doctorId || null,
    appointment_date: values.date,
    appointment_time: values.time,
    visit_type: values.visitType,
    remarks: values.remarks || null,
  };

  const { data, error } = await supabase
    .from('appointments')
    .insert(payload)
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }

  return { appointment: data };
}

EOF

cat > app/appointments/register-button.js << 'EOF'
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

EOF

cat > app/appointments/page.js << 'EOF'
import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';
import CheckInButton from './check-in-button';
import RegisterUnregisteredButton from './register-button';

export default async function AppointmentsPage({ searchParams }) {
  const params = await searchParams;
  const justBooked = params?.booked;
  const dateFilter = params?.date || new Date().toISOString().slice(0, 10);

  const supabase = await createClient();
  const { data: appointments, error } = await supabase
    .from('appointments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('appointment_date', dateFilter)
    .order('appointment_time', { ascending: true });

  return (
    <div style={{ maxWidth: 900, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div style={{ fontSize: 18, fontWeight: 700 }}>Appointments</div>
          <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Book Appointment
          </Link>
        </div>

        <form method="GET" action="/appointments" style={{ display: 'flex', gap: 8, marginBottom: 16, alignItems: 'center' }}>
          <label className="flbl" style={{ marginBottom: 0 }}>
            Date:
          </label>
          <input type="date" name="date" defaultValue={dateFilter} className="fi" style={{ width: 180 }} />
          <button type="submit" className="btn">
            View
          </button>
        </form>

        {justBooked && (
          <div
            style={{
              background: 'var(--green-lt)',
              color: 'var(--green)',
              padding: '10px 14px',
              borderRadius: 8,
              fontSize: 13,
              marginBottom: 16,
            }}
          >
            Appointment booked successfully.
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>Time</th>
              <th style={{ padding: '8px 6px' }}>Patient</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Type</th>
              <th style={{ padding: '8px 6px' }}>Doctor</th>
              <th style={{ padding: '8px 6px' }}>Status</th>
              <th style={{ padding: '8px 6px' }}>Actions</th>
            </tr>
          </thead>
          <tbody>
            {(appointments || []).map((a) => {
              const isRegistered = !!a.patients;
              const name = isRegistered
                ? `${a.patients.first_name} ${a.patients.last_name}`
                : a.patient_name_temp;
              const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
              return (
                <tr key={a.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 6px' }}>{a.appointment_time?.slice(0, 5)}</td>
                  <td style={{ padding: '8px 6px' }}>{name}</td>
                  <td style={{ padding: '8px 6px' }}>{mobile}</td>
                  <td style={{ padding: '8px 6px' }}>{a.visit_type}</td>
                  <td style={{ padding: '8px 6px' }}>{a.profiles?.full_name || '--'}</td>
                  <td style={{ padding: '8px 6px' }}>{a.status}</td>
                  <td style={{ padding: '8px 6px', position: 'relative' }}>
                    {a.status === 'Booked' && isRegistered && <CheckInButton appointmentId={a.id} />}
                    {a.status === 'Booked' && !isRegistered && (
                      <RegisterUnregisteredButton appointmentId={a.id} tempName={a.patient_name_temp} tempMobile={a.mobile_temp} />
                    )}
                  </td>
                </tr>
              );
            })}
            {(!appointments || appointments.length === 0) && (
              <tr>
                <td colSpan={7} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  No appointments for this date.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

echo "Register-unregistered-appointment feature added."
