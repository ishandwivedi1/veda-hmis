import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';
import { VISIT_TYPE_COLOR } from '@/lib/visit-types';

const STATUS_BADGE = { Booked: 'b-amber', 'Checked-in': 'b-green', Cancelled: 'b-red', 'No-show': 'b-gray' };

export default async function AppointmentsPage({ searchParams }) {
  const params = await searchParams;
  const justBooked = params?.booked;
  const dateFilter = params?.date || new Date().toISOString().slice(0, 10);

  const supabase = await createClient();
  const { data: appointments, error } = await supabase
    .from('appointments')
    .select('*, patients(first_name, salutation, last_name, uhid, mobile), profiles(full_name)')
    .eq('appointment_date', dateFilter)
    .order('appointment_time', { ascending: true });

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Appointments
          <span className="badge b-gray">{appointments?.length ?? 0}</span>
        </div>
        <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Book Appointment
        </Link>
      </div>

      <form method="GET" action="/appointments" style={{ display: 'flex', gap: 8, marginBottom: 16, alignItems: 'center' }}>
        <label className="flbl" style={{ marginBottom: 0 }}>Date:</label>
        <input type="date" name="date" defaultValue={dateFilter} className="fi" style={{ width: 180 }} />
        <button type="submit" className="btn"><i className="ti ti-filter"></i> View</button>
      </form>

      {justBooked && <div className="msg-success"><i className="ti ti-circle-check"></i> Appointment booked successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Time</th>
            <th>Patient</th>
            <th>Mobile</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(appointments || []).map((a) => {
            const isRegistered = !!a.patients;
            const name = isRegistered ? `${formatPatientName(a.patients)}` : a.patient_name_temp;
            const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
            return (
              <tr key={a.id}>
                <td style={{ fontWeight: 600 }}>{a.appointment_time?.slice(0, 5)}</td>
                <td>{name}</td>
                <td>{mobile}</td>
                <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[a.visit_type] || '--g100'})`, color: '#fff' }}>{a.visit_type}</span></td>
                <td>{a.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[a.status] || 'b-gray'}`}>{a.status}</span></td>
                <td style={{ position: 'relative' }}>
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
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                No appointments for this date.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

