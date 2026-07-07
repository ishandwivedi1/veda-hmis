mkdir -p app/visits/new app/appointments app/dashboard

cat > app/visits/actions.js << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function checkInAppointment(appointmentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('check_in_appointment', {
    p_appointment_id: appointmentId,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

export async function createWalkInVisit(values) {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('visits')
    .insert({
      patient_id: values.patientId,
      doctor_id: values.doctorId || null,
      visit_type: values.visitType,
      status: 'Open',
    })
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

EOF

cat > app/visits/new/page.js << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '../../appointments/actions';
import { createWalkInVisit } from '../actions';

export default function NewVisitPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
  }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient) {
      setError('Search and select a registered patient.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/visits?created=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>Create Walk-in Visit</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          For patients arriving without a prior appointment.
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {selectedPatient ? (
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--blue-lt)',
                  padding: '8px 12px',
                  borderRadius: 8,
                }}
              >
                <span>
                  <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
                  {' -- '}
                  {selectedPatient.uhid}
                </span>
                <button
                  type="button"
                  className="btn"
                  style={{ padding: '4px 10px' }}
                  onClick={() => setSelectedPatient(null)}
                >
                  Change
                </button>
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    className="fi"
                    value={searchQuery}
                    onChange={(e) => setSearchQuery(e.target.value)}
                    placeholder="Type to search..."
                  />
                  <button type="button" className="btn" onClick={handleSearch}>
                    Search
                  </button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                    {searchResults.map((p) => (
                      <div
                        key={p.id}
                        onClick={() => pickPatient(p)}
                        style={{
                          padding: '8px 12px',
                          cursor: 'pointer',
                          borderBottom: '1px solid var(--g100)',
                          fontSize: 13,
                        }}
                      >
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                      </div>
                    ))}
                  </div>
                )}
                {searchResults.length === 0 && searchQuery === '' && (
                  <div style={{ fontSize: 12, color: 'var(--g400)', marginTop: 6 }}>
                    Not registered yet?{' '}
                    <a href="/patients/new" style={{ color: 'var(--blue)' }}>
                      Register the patient first
                    </a>
                    , then come back here.
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => setVisitType(e.target.value)}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
              </select>
            </div>
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Creating...' : 'Create Visit'}
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

EOF

cat > app/visits/page.js << 'EOF'
import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;

  const supabase = await createClient();
  const { data: visits, error } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('status', 'Open')
    .order('created_at', { ascending: false });

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
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>Open Visits</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Patients currently in the hospital, visit not yet closed.
            </div>
          </div>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
        </div>

        {justCreated && (
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
            Visit created successfully.
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>Patient</th>
              <th style={{ padding: '8px 6px' }}>UHID</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Type</th>
              <th style={{ padding: '8px 6px' }}>Doctor</th>
              <th style={{ padding: '8px 6px' }}>Since</th>
            </tr>
          </thead>
          <tbody>
            {(visits || []).map((v) => (
              <tr key={v.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '8px 6px' }}>
                  {v.patients?.first_name} {v.patients?.last_name}
                </td>
                <td style={{ padding: '8px 6px', fontFamily: 'monospace' }}>{v.patients?.uhid}</td>
                <td style={{ padding: '8px 6px' }}>{v.patients?.mobile}</td>
                <td style={{ padding: '8px 6px' }}>{v.visit_type}</td>
                <td style={{ padding: '8px 6px' }}>{v.profiles?.full_name || '--'}</td>
                <td style={{ padding: '8px 6px', color: 'var(--g500)' }}>
                  {new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}
                </td>
              </tr>
            ))}
            {(!visits || visits.length === 0) && (
              <tr>
                <td colSpan={6} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  No open visits right now.
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

cat > app/appointments/check-in-button.js << 'EOF'
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

    router.push('/visits?created=1');
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

EOF

cat > app/appointments/page.js << 'EOF'
import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';
import CheckInButton from './check-in-button';

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
                  <td style={{ padding: '8px 6px' }}>
                    {name}
                    {!isRegistered && (
                      <span
                        style={{
                          marginLeft: 6,
                          fontSize: 10,
                          background: 'var(--red-lt)',
                          color: 'var(--red)',
                          padding: '1px 6px',
                          borderRadius: 8,
                        }}
                      >
                        Not registered
                      </span>
                    )}
                  </td>
                  <td style={{ padding: '8px 6px' }}>{mobile}</td>
                  <td style={{ padding: '8px 6px' }}>{a.visit_type}</td>
                  <td style={{ padding: '8px 6px' }}>{a.profiles?.full_name || '--'}</td>
                  <td style={{ padding: '8px 6px' }}>{a.status}</td>
                  <td style={{ padding: '8px 6px' }}>
                    {a.status === 'Booked' && isRegistered && <CheckInButton appointmentId={a.id} />}
                    {a.status === 'Booked' && !isRegistered && (
                      <span style={{ fontSize: 11, color: 'var(--g400)' }}>Register patient first</span>
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

cat > app/dashboard/page.js << 'EOF'
import { createClient } from '../../lib/supabase-server';
import SignOutButton from './sign-out-button';
import Link from 'next/link';

export default async function DashboardPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();

  return (
    <div style={{ maxWidth: 640, margin: '60px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA HMIS</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Real login, real database -- Phase 1 proof of concept
            </div>
          </div>
          <SignOutButton />
        </div>

        <div
          style={{
            background: 'var(--green-lt)',
            color: 'var(--green)',
            padding: '10px 14px',
            borderRadius: 8,
            fontSize: 13,
            marginBottom: 20,
          }}
        >
          You are genuinely logged in via Supabase Auth, and this page just
          read your staff profile from the real <code>profiles</code> table.
        </div>

        <div style={{ fontSize: 13, lineHeight: 1.8 }}>
          <div>
            <strong>Name:</strong> {profile?.full_name || '(not set yet)'}
          </div>
          <div>
            <strong>Designation:</strong> {profile?.designation || '(not set yet)'}
          </div>
          <div>
            <strong>Department:</strong> {profile?.department || '(not set yet)'}
          </div>
          <div>
            <strong>Status:</strong> {profile?.status}
          </div>
          <div>
            <strong>Email:</strong> {user.email}
          </div>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 20, paddingTop: 20, borderTop: '1px solid var(--g200)' }}>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
          </Link>
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            View All Patients
          </Link>
          <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Book Appointment
          </Link>
          <Link href="/appointments" className="btn" style={{ textDecoration: 'none' }}>
            View Appointments
          </Link>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
          <Link href="/visits" className="btn" style={{ textDecoration: 'none' }}>
            View Open Visits
          </Link>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Check-in and Visits module created."
