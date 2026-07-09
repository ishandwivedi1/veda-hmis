mkdir -p 'app/(main)/visits/new' 'app/(main)/appointments/new' 'app/(main)/patients'

cat > 'app/(main)/visits/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

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

  const { data, error } = await supabase.rpc('create_walk_in_visit', {
    p_patient_id: values.patientId,
    p_doctor_id: values.doctorId || null,
    p_visit_type: values.visitType,
    p_referral_source: values.referralSource || null,
    p_priority: values.priority || 'Routine',
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

EOF

cat > 'app/(main)/visits/new/page.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit } from '@/app/(main)/visits/actions';
import { registerPatient } from '@/app/(main)/patients/actions';

export default function NewVisitPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);

  const [showQuickReg, setShowQuickReg] = useState(false);
  const [qrFirstName, setQrFirstName] = useState('');
  const [qrLastName, setQrLastName] = useState('');
  const [qrGender, setQrGender] = useState('');
  const [qrAge, setQrAge] = useState('');
  const [qrMobile, setQrMobile] = useState('');
  const [qrError, setQrError] = useState('');
  const [qrLoading, setQrLoading] = useState(false);

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');

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
    setSearched(true);
  }

  async function handleQuickRegister(e) {
    e.preventDefault();
    setQrError('');

    if (!qrFirstName || !qrLastName || !qrGender || !qrMobile) {
      setQrError('First name, last name, gender, and mobile are required.');
      return;
    }
    if (qrMobile.length !== 10) {
      setQrError('Mobile number must be 10 digits.');
      return;
    }

    setQrLoading(true);
    const result = await registerPatient({
      firstName: qrFirstName,
      lastName: qrLastName,
      age: qrAge,
      gender: qrGender,
      mobile: qrMobile,
    });
    setQrLoading(false);

    if (result.error) {
      setQrError(result.error);
      return;
    }

    // Registered -- select them immediately and continue, no navigating away.
    setSelectedPatient(result.patient);
    setShowQuickReg(false);
    setSearched(false);
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
      referralSource,
      priority,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/visits?created=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Create Walk-in Visit
        </div>
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
                    onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }}
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
                {searched && searchResults.length === 0 && !showQuickReg && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={() => setShowQuickReg(true)}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Quick-register this patient
                    </button>{' '}
                    without leaving this page.
                  </div>
                )}
                {showQuickReg && (
                  <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginTop: 8 }}>
                    <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Quick Register</div>
                    {qrError && <div className="msg-err" style={{ marginBottom: 8 }}>{qrError}</div>}
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                      <input className="fi" placeholder="First name *" value={qrFirstName} onChange={(e) => setQrFirstName(e.target.value)} />
                      <input className="fi" placeholder="Last name *" value={qrLastName} onChange={(e) => setQrLastName(e.target.value)} />
                    </div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                      <select className="fi" value={qrGender} onChange={(e) => setQrGender(e.target.value)}>
                        <option value="">Gender *</option>
                        <option value="M">Male</option>
                        <option value="F">Female</option>
                        <option value="O">Other</option>
                      </select>
                      <input type="number" className="fi" placeholder="Age" value={qrAge} onChange={(e) => setQrAge(e.target.value)} />
                    </div>
                    <input className="fi" placeholder="Mobile *" value={qrMobile} onChange={(e) => setQrMobile(e.target.value)} maxLength={10} style={{ marginBottom: 8 }} />
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button type="button" className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleQuickRegister} disabled={qrLoading}>
                        {qrLoading ? 'Registering...' : 'Register & Continue'}
                      </button>
                      <button type="button" className="btn" style={{ fontSize: 12 }} onClick={() => setShowQuickReg(false)}>
                        Cancel
                      </button>
                    </div>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => setVisitType(e.target.value)}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Procedure</option>
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

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Referral source</label>
              <select className="fi" value={referralSource} onChange={(e) => setReferralSource(e.target.value)}>
                <option>Walk-in</option>
                <option>Doctor referral</option>
                <option>Camp / outreach</option>
                <option>Previous patient</option>
              </select>
            </div>
            <div>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option>
                <option>Urgent</option>
                <option>Emergency</option>
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

cat > 'app/(main)/appointments/new/page.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors, createAppointment } from '@/app/(main)/appointments/actions';

export default function NewAppointmentPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [notRegistered, setNotRegistered] = useState(false);
  const [patientName, setPatientName] = useState('');
  const [mobile, setMobile] = useState('');

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [date, setDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [time, setTime] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [remarks, setRemarks] = useState('');

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

    if (!selectedPatient && !notRegistered) {
      setError('Search and select a patient, or check "Not registered yet" for a phone booking.');
      return;
    }
    if (notRegistered && (!patientName.trim() || !mobile.trim())) {
      setError('Name and mobile are required for a phone booking.');
      return;
    }
    if (!date || !time) {
      setError('Date and time are required.');
      return;
    }

    setLoading(true);
    const result = await createAppointment({
      patientId: selectedPatient?.id,
      patientName: notRegistered ? patientName : undefined,
      mobile: notRegistered ? mobile : undefined,
      doctorId: doctorId || null,
      date,
      time,
      visitType,
      remarks,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/appointments?booked=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 20 }}>
          <i className="ti ti-calendar-plus" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Book Appointment
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          {/* Patient selection */}
          {!notRegistered && (
            <div style={{ marginBottom: 12 }}>
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
                </>
              )}
            </div>
          )}

          <div style={{ marginBottom: 16 }}>
            <label style={{ fontSize: 12, display: 'flex', alignItems: 'center', gap: 6 }}>
              <input
                type="checkbox"
                checked={notRegistered}
                onChange={(e) => {
                  setNotRegistered(e.target.checked);
                  setSelectedPatient(null);
                }}
              />
              Not registered yet -- book by phone (name + mobile only)
            </label>
          </div>

          {notRegistered && (
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div>
                <label className="flbl">Patient name *</label>
                <input className="fi" value={patientName} onChange={(e) => setPatientName(e.target.value)} />
              </div>
              <div>
                <label className="flbl">Mobile *</label>
                <input className="fi" value={mobile} onChange={(e) => setMobile(e.target.value)} maxLength={10} />
              </div>
            </div>
          )}

          {/* Appointment details */}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Date *</label>
              <input type="date" className="fi" value={date} onChange={(e) => setDate(e.target.value)} required />
            </div>
            <div>
              <label className="flbl">Time *</label>
              <input type="time" className="fi" value={time} onChange={(e) => setTime(e.target.value)} required />
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => setVisitType(e.target.value)}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Procedure</option>
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

          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Remarks</label>
            <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} />
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Booking...' : 'Book Appointment'}
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

cat > 'app/(main)/patients/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

const GENDER_BADGE = { M: 'b-blue', F: 'b-purple', O: 'b-gray' };
const GENDER_LABEL = { M: 'Male', F: 'Female', O: 'Other' };

export default async function PatientsPage({ searchParams }) {
  const params = await searchParams;
  const justRegistered = params?.registered;
  const q = params?.q || '';

  const supabase = await createClient();
  let query = supabase.from('patients').select('*').order('created_at', { ascending: false });

  if (q) {
    query = query.or(
      `uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`
    );
  }

  const { data: patients, error } = await query;

  // Richer search results, matching M20's "Find Patient" screen -- shows
  // each patient's last visit date and whether they currently have an
  // open (active) visit, computed in one batched query rather than one
  // query per row.
  const patientIds = (patients || []).map((p) => p.id);
  let visitInfo = {};
  if (patientIds.length > 0) {
    const { data: visits } = await supabase
      .from('visits')
      .select('patient_id, status, created_at')
      .in('patient_id', patientIds)
      .order('created_at', { ascending: false });

    (visits || []).forEach((v) => {
      if (!visitInfo[v.patient_id]) {
        visitInfo[v.patient_id] = { lastVisit: v.created_at, hasActive: false };
      }
      if (v.status === 'Open') {
        visitInfo[v.patient_id].hasActive = true;
      }
    });
  }

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-users" style={{ color: 'var(--blue)' }}></i> Patients
          <span className="badge b-gray">{patients?.length ?? 0}</span>
        </div>
        <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Register New Patient
        </Link>
      </div>

      <form method="GET" action="/patients" style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
        <input
          type="text"
          name="q"
          defaultValue={q}
          placeholder="Search by name, UHID, or mobile..."
          className="fi"
          style={{ flex: 1 }}
        />
        <button type="submit" className="btn btn-primary"><i className="ti ti-search"></i> Search</button>
        {q && (
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            Clear
          </Link>
        )}
      </form>

      {justRegistered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{justRegistered}</strong>
        </div>
      )}

      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>UHID</th>
            <th>Name</th>
            <th>Age</th>
            <th>Gender</th>
            <th>Mobile</th>
            <th>Blood Group</th>
            <th>Last Visit</th>
            <th>Active Visit</th>
          </tr>
        </thead>
        <tbody>
          {(patients || []).map((p) => {
            const info = visitInfo[p.id];
            return (
              <tr key={p.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
                <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
                <td>{p.age || '--'}</td>
                <td><span className={`badge ${GENDER_BADGE[p.gender] || 'b-gray'}`}>{GENDER_LABEL[p.gender] || p.gender}</span></td>
                <td>{p.mobile}</td>
                <td>{p.blood_group ? <span className="badge b-red">{p.blood_group}</span> : '--'}</td>
                <td style={{ color: 'var(--g500)' }}>{info ? new Date(info.lastVisit).toLocaleDateString('en-IN') : 'Never'}</td>
                <td>{info?.hasActive ? <span className="badge b-green">Active</span> : <span className="badge b-gray">None</span>}</td>
              </tr>
            );
          })}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

EOF

echo "M20 visit-creation parity applied (visit types, referral/priority, richer search)."
