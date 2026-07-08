mkdir -p 'app/(main)/visits/new' 'app/(main)/patients/new' 'app/(main)/appointments/new' 'app/(main)/optometry/[id]' 'app/(main)/consultation/[id]' 'app/(main)/billing/[visitId]' 'app/(main)/pharmacy'

cat > 'app/(main)/visits/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

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
    <div className="card">
      <div className="card-head">
        <div>
          <div className="card-title"><i className="ti ti-door-enter" style={{ color: 'var(--green)' }}></i> Open Visits <span className="badge b-gray">{visits?.length ?? 0}</span></div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>Patients currently in the hospital, visit not yet closed.</div>
        </div>
        <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Walk-in Visit
        </Link>
      </div>

      {justCreated && <div className="msg-success"><i className="ti ti-circle-check"></i> Visit created successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Patient</th>
            <th>UHID</th>
            <th>Mobile</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Since</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(visits || []).map((v) => (
            <tr key={v.id}>
              <td style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</td>
              <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{v.patients?.uhid}</td>
              <td>{v.patients?.mobile}</td>
              <td><span className="badge b-blue">{v.visit_type}</span></td>
              <td>{v.profiles?.full_name || '--'}</td>
              <td style={{ color: 'var(--g500)' }}>
                {new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}
              </td>
              <td>
                <Link href={`/billing/${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  <i className="ti ti-receipt"></i> Bill
                </Link>
              </td>
            </tr>
          ))}
          {(!visits || visits.length === 0) && (
            <tr>
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                No open visits right now.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

EOF

cat > 'app/(main)/patients/new/page.js' << 'EOF'
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

cat > 'app/(main)/optometry/[id]/optometry-form.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getQueueEntryForOptometry, saveFindingsAndComplete } from '@/app/(main)/optometry/actions';

export default function OptometryForm({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [loadError, setLoadError] = useState('');

  const [reVa, setReVa] = useState('');
  const [leVa, setLeVa] = useState('');
  const [reIop, setReIop] = useState('');
  const [leIop, setLeIop] = useState('');
  const [reSph, setReSph] = useState('');
  const [leSph, setLeSph] = useState('');
  const [reCyl, setReCyl] = useState('');
  const [leCyl, setLeCyl] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getQueueEntryForOptometry(queueEntryId).then((result) => {
      if (result.error) {
        setLoadError(result.error);
      } else {
        setEntry(result.entry);
      }
    });
  }, [queueEntryId]);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const result = await saveFindingsAndComplete(queueEntryId, entry.visits.id, {
      reVa, leVa, reIop, leIop, reSph, leSph, reCyl, leCyl,
    });

    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/queue');
  }

  if (loadError) {
    return (
      <div style={{ maxWidth: 560, margin: '0 auto' }}>
        <div className="msg-err">{loadError}</div>
      </div>
    );
  }

  if (!entry) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = entry.visits?.patients;

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)', marginRight: 6 }}></i>
          Optometry -- {entry.token}
        </div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 20 }}>
          {patient?.first_name} {patient?.last_name} -- {patient?.uhid} -- {patient?.age} {patient?.gender}
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            Visual Acuity
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
            <div>
              <label className="flbl">RE VA</label>
              <input className="fi" value={reVa} onChange={(e) => setReVa(e.target.value)} placeholder="e.g. 6/9" />
            </div>
            <div>
              <label className="flbl">LE VA</label>
              <input className="fi" value={leVa} onChange={(e) => setLeVa(e.target.value)} placeholder="e.g. 6/12" />
            </div>
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            IOP (mmHg)
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
            <div>
              <label className="flbl">RE IOP</label>
              <input type="number" className="fi" value={reIop} onChange={(e) => setReIop(e.target.value)} />
            </div>
            <div>
              <label className="flbl">LE IOP</label>
              <input type="number" className="fi" value={leIop} onChange={(e) => setLeIop(e.target.value)} />
            </div>
          </div>

          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
            Refraction
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8, marginBottom: 20 }}>
            <div>
              <label className="flbl">RE Sph</label>
              <input className="fi" value={reSph} onChange={(e) => setReSph(e.target.value)} placeholder="-2.00" />
            </div>
            <div>
              <label className="flbl">RE Cyl</label>
              <input className="fi" value={reCyl} onChange={(e) => setReCyl(e.target.value)} placeholder="-0.50" />
            </div>
            <div>
              <label className="flbl">LE Sph</label>
              <input className="fi" value={leSph} onChange={(e) => setLeSph(e.target.value)} placeholder="-1.50" />
            </div>
            <div>
              <label className="flbl">LE Cyl</label>
              <input className="fi" value={leCyl} onChange={(e) => setLeCyl(e.target.value)} placeholder="-0.25" />
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Saving...' : 'Save & Complete -- Send to Doctor'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/queue')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/consultation/[id]/consultation-form.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
} from '@/app/(main)/consultation/actions';

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId)
      : await sendForInvestigationFromConsultation(queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const f = data.findings;

  return (
    <div style={{ maxWidth: 700, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Consultation -- {data.entry.token}</div>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.age} {patient.gender}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {f && (
        <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
          <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>Optometry Findings</div>
          <div style={{ fontSize: 12, color: 'var(--g600)' }}>
            VA: RE {f.re_va || '--'} / LE {f.le_va || '--'} &nbsp;&nbsp;
            IOP: RE {f.re_iop || '--'} / LE {f.le_iop || '--'} &nbsp;&nbsp;
            Sph: RE {f.re_sph || '--'} / LE {f.le_sph || '--'} &nbsp;&nbsp;
            Cyl: RE {f.re_cyl || '--'} / LE {f.le_cyl || '--'}
          </div>
        </div>
      )}

      {/* DIAGNOSIS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Diagnosis</div>
        {data.diagnoses.map((d) => (
          <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeDiagnosis(d.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
            <option value="primary">Primary</option>
            <option value="secondary">Secondary</option>
            <option value="associated">Associated</option>
            <option value="systemic">Systemic</option>
          </select>
          <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option>
            <option value="OS">OS</option>
            <option value="OU">OU</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
        </div>
      </div>

      {/* PRESCRIPTION */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Prescription</div>
        {data.prescriptions.map((r) => (
          <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap' }}>
          <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
          <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
          </select>
          <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
          </select>
          <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
            <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
          </select>
          <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
            <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
        </div>
      </div>

      {/* INVESTIGATIONS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Investigations</div>
        {data.investigations.map((i) => (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
          </select>
          <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
            <option>Routine</option><option>Urgent</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
        </div>
      </div>

      {/* ACTIONS */}
      <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
          {loading ? 'Working...' : 'Complete Visit'}
        </button>
        <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
          Send for Dilation
        </button>
        <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
          Send for Investigation
        </button>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/billing/[visitId]/billing-form.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvoiceForVisit, getServiceCatalog, addLineItem, removeLineItem, recordPayment } from '@/app/(main)/billing/actions';

export default function BillingForm({ visitId }) {
  const [data, setData] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');

  const [selectedService, setSelectedService] = useState('');
  const [qty, setQty] = useState(1);
  const [paymentAmount, setPaymentAmount] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvoiceForVisit(visitId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [visitId]);

  useEffect(() => {
    refresh();
    getServiceCatalog().then(setCatalog);
  }, [refresh]);

  async function handleAddLineItem() {
    setError('');
    if (!selectedService) { setError('Select a service.'); return; }
    const result = await addLineItem(data.invoice.id, selectedService, parseInt(qty, 10) || 1);
    if (result.error) { setError(result.error); return; }
    setSelectedService('');
    setQty(1);
    refresh();
  }

  async function handleRemoveLineItem(id) {
    await removeLineItem(id);
    refresh();
  }

  async function handleRecordPayment() {
    setError('');
    const amt = parseFloat(paymentAmount);
    if (!amt || amt <= 0) { setError('Enter a valid payment amount.'); return; }
    setLoading(true);
    const result = await recordPayment(data.invoice.id, amt);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setPaymentAmount('');
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.visit.patients;
  const inv = data.invoice;
  const balanceDue = inv.net - inv.paid;

  return (
    <div style={{ maxWidth: 700, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Billing</div>
            <div style={{ fontSize: 13, color: 'var(--g500)' }}>
              {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.mobile}
            </div>
          </div>
          <span
            style={{
              fontSize: 12,
              fontWeight: 700,
              padding: '4px 10px',
              borderRadius: 12,
              background: inv.status === 'Paid' ? 'var(--green-lt)' : inv.status === 'Partial' ? '#fef3c7' : 'var(--red-lt)',
              color: inv.status === 'Paid' ? 'var(--green)' : inv.status === 'Partial' ? '#b45309' : 'var(--red)',
            }}
          >
            {inv.status}
          </span>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Line Items</div>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '6px' }}>Service</th>
              <th style={{ padding: '6px' }}>Qty</th>
              <th style={{ padding: '6px' }}>Rate</th>
              <th style={{ padding: '6px' }}>GST%</th>
              <th style={{ padding: '6px' }}>Net</th>
              <th style={{ padding: '6px' }}></th>
            </tr>
          </thead>
          <tbody>
            {data.lineItems.map((li) => (
              <tr key={li.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '6px' }}>{li.service_name}</td>
                <td style={{ padding: '6px' }}>{li.qty}</td>
                <td style={{ padding: '6px' }}>Rs.{li.rate}</td>
                <td style={{ padding: '6px' }}>{li.gst_pct}%</td>
                <td style={{ padding: '6px' }}>Rs.{li.net}</td>
                <td style={{ padding: '6px' }}>
                  <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLineItem(li.id)}>
                    Remove
                  </button>
                </td>
              </tr>
            ))}
            {data.lineItems.length === 0 && (
              <tr>
                <td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet.</td>
              </tr>
            )}
          </tbody>
        </table>

        <div style={{ display: 'flex', gap: 6, marginTop: 12 }}>
          <select className="fi" value={selectedService} onChange={(e) => setSelectedService(e.target.value)} style={{ flex: 2 }}>
            <option value="">-- Select service to add --</option>
            {catalog.map((s) => (
              <option key={s.code} value={s.code}>
                {s.name} -- Rs.{s.rate} ({s.gst_pct}% GST)
              </option>
            ))}
          </select>
          <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} style={{ width: 70 }} min={1} />
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddLineItem}>
            Add
          </button>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span>Gross</span><span>Rs.{inv.gross}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span>GST</span><span>Rs.{inv.gst}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}>
            <span>Net Total</span><span>Rs.{inv.net}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}>
            <span>Paid</span><span>Rs.{inv.paid}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, color: balanceDue > 0 ? 'var(--red)' : 'var(--green)' }}>
            <span>Balance Due</span><span>Rs.{balanceDue}</span>
          </div>
        </div>
      </div>

      {balanceDue > 0 && (
        <div className="card">
          <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Collect Payment</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <input
              type="number"
              className="fi"
              placeholder={`Up to Rs.${balanceDue}`}
              value={paymentAmount}
              onChange={(e) => setPaymentAmount(e.target.value)}
            />
            <button className="btn btn-primary" onClick={handleRecordPayment} disabled={loading}>
              {loading ? 'Recording...' : 'Record Payment'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/pharmacy/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingPrescriptions, dispensePrescription, dispenseAllForVisit } from './actions';

export default function PharmacyPage() {
  const [groups, setGroups] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const data = await getPendingPrescriptions();
    setGroups(data);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function handleDispenseOne(id) {
    setError('');
    const result = await dispensePrescription(id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleDispenseAll(items) {
    setError('');
    const result = await dispenseAllForVisit(items.map((i) => i.id));
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  return (
    <div style={{ maxWidth: 800, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}><i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy -- Pending Dispensing</div>
      {error && <div className="msg-err">{error}</div>}

      {groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>
              {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
            </div>
            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => handleDispenseAll(g.items)}>
              Dispense All ({g.items.length})
            </button>
          </div>
          {g.items.map((rx) => (
            <div
              key={rx.id}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                padding: '8px 0',
                borderBottom: '1px solid var(--g100)',
                fontSize: 13,
              }}
            >
              <span>
                <strong>{rx.drug_name}</strong> -- {rx.dosage} {rx.frequency} x {rx.duration} -- {rx.eye}
              </span>
              <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleDispenseOne(rx.id)}>
                Dispense
              </button>
            </div>
          ))}
        </div>
      ))}

      {groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

EOF

echo "Visual polish pass 3 (Visits, forms, Optometry, Consultation, Billing, Pharmacy) applied."
