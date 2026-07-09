'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit } from '@/app/(main)/visits/actions';
import { registerPatient } from '@/app/(main)/patients/actions';

function toTitleCase(str) {
  return str.trim().toLowerCase().replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

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
                      <input className="fi" placeholder="First name *" value={qrFirstName} onChange={(e) => setQrFirstName(e.target.value)} onBlur={() => setQrFirstName((v) => toTitleCase(v))} />
                      <input className="fi" placeholder="Last name *" value={qrLastName} onChange={(e) => setQrLastName(e.target.value)} onBlur={() => setQrLastName((v) => toTitleCase(v))} />
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

