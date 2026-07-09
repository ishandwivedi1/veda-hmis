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

