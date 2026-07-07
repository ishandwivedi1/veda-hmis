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

