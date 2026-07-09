mkdir -p 'app/(main)/patients/new' 'app/(main)/visits/new' 'app/(main)/appointments'

cat > 'app/(main)/patients/new/page.js' << 'EOF'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient, registerAndCreateVisit, checkDuplicateMobile } from '../actions';

function calcAge(dob) {
  if (!dob) return '';
  const birth = new Date(dob);
  const now = new Date();
  let age = now.getFullYear() - birth.getFullYear();
  const m = now.getMonth() - birth.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < birth.getDate())) age--;
  return age >= 0 ? String(age) : '';
}

// Matches the database's initcap() normalization -- applied live as the
// receptionist finishes typing a name, so what they see already matches
// what will be saved, rather than only fixing it after the fact.
function toTitleCase(str) {
  return str
    .trim()
    .toLowerCase()
    .replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

export default function NewPatientPage() {
  const [values, setValues] = useState({
    firstName: '', lastName: '', gender: '', dateOfBirth: '', age: '', bloodGroup: '',
    mobile: '', alternateMobile: '',
    address: '', city: '', state: 'Uttarakhand', pinCode: '',
    idType: '', idNumber: '', insuranceScheme: '', insuranceNumber: '',
    referralSource: '', preferredLanguage: 'Hindi', remarks: '',
  });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [duplicates, setDuplicates] = useState([]);
  const debounceRef = useRef(null);
  const router = useRouter();

  function update(field) {
    return (e) => {
      const val = e.target.value;
      setValues((v) => {
        const next = { ...v, [field]: val };
        if (field === 'dateOfBirth') next.age = calcAge(val);
        return next;
      });
    };
  }

  function formatOnBlur(field) {
    return () => setValues((v) => ({ ...v, [field]: toTitleCase(v[field]) }));
  }

  useEffect(() => {
    if (debounceRef.current) clearTimeout(debounceRef.current);
    if (values.mobile.length === 10) {
      debounceRef.current = setTimeout(async () => {
        const results = await checkDuplicateMobile(values.mobile);
        setDuplicates(results);
      }, 400);
    } else {
      setDuplicates([]);
    }
    return () => clearTimeout(debounceRef.current);
  }, [values.mobile]);

  function validate() {
    if (!values.firstName || !values.lastName || !values.gender || !values.mobile) {
      setError('First name, last name, gender, and mobile are required.');
      return false;
    }
    if (values.mobile.length !== 10) {
      setError('Mobile number must be 10 digits.');
      return false;
    }
    return true;
  }

  async function handleRegister() {
    setError('');
    if (!validate()) return;
    setLoading(true);
    const result = await registerPatient(values);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push(`/patients?registered=${result.patient.uhid}`);
  }

  async function handleRegisterAndVisit() {
    setError('');
    if (!validate()) return;
    setLoading(true);
    const result = await registerAndCreateVisit(values);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    if (result.visitError) {
      setError(`Patient registered (UHID: ${result.patient.uhid}), but creating the visit failed: ${result.visitError}`);
      return;
    }
    router.push('/visits?created=1');
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-head">
          <div className="card-title"><i className="ti ti-user-plus" style={{ color: 'var(--blue)' }}></i> Register New Patient</div>
          <span style={{ fontSize: 11, color: 'var(--g400)' }}>UHID auto-generated on save</span>
        </div>

        {error && <div className="msg-err">{error}</div>}

        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '14px 0 8px' }}>Personal Information</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">First name *</label><input className="fi" value={values.firstName} onChange={update('firstName')} onBlur={formatOnBlur('firstName')} /></div>
          <div><label className="flbl">Last name *</label><input className="fi" value={values.lastName} onChange={update('lastName')} onBlur={formatOnBlur('lastName')} /></div>
          <div><label className="flbl">Gender *</label>
            <select className="fi" value={values.gender} onChange={update('gender')}>
              <option value="">-- Select --</option>
              <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
            </select>
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Date of birth</label><input type="date" className="fi" value={values.dateOfBirth} onChange={update('dateOfBirth')} /></div>
          <div><label className="flbl">Age</label><input type="number" className="fi" value={values.age} onChange={update('age')} /></div>
          <div><label className="flbl">Blood group</label>
            <select className="fi" value={values.bloodGroup} onChange={update('bloodGroup')}>
              <option value="">-- Select --</option>
              <option>A+</option><option>A-</option><option>B+</option><option>B-</option>
              <option>AB+</option><option>AB-</option><option>O+</option><option>O-</option><option>Unknown</option>
            </select>
          </div>
        </div>

        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '14px 0 8px' }}>Contact Information</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Mobile number *</label><input className="fi" value={values.mobile} onChange={update('mobile')} maxLength={10} /></div>
          <div><label className="flbl">Alternate mobile</label><input className="fi" value={values.alternateMobile} onChange={update('alternateMobile')} maxLength={10} /></div>
        </div>
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">Address</label>
          <textarea className="fi" rows={2} value={values.address} onChange={update('address')} />
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">City</label><input className="fi" value={values.city} onChange={update('city')} onBlur={formatOnBlur('city')} /></div>
          <div><label className="flbl">State</label>
            <select className="fi" value={values.state} onChange={update('state')}>
              <option>Uttarakhand</option><option>Uttar Pradesh</option><option>Delhi</option>
              <option>Himachal Pradesh</option><option>Haryana</option><option>Other</option>
            </select>
          </div>
          <div><label className="flbl">PIN code</label><input className="fi" value={values.pinCode} onChange={update('pinCode')} maxLength={6} /></div>
        </div>

        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '14px 0 8px' }}>Identity &amp; Insurance</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">ID type</label>
            <select className="fi" value={values.idType} onChange={update('idType')}>
              <option value="">-- Select --</option>
              <option>Aadhaar</option><option>PAN</option><option>Passport</option><option>Voter ID</option><option>Driving Licence</option>
            </select>
          </div>
          <div><label className="flbl">ID number</label><input className="fi" value={values.idNumber} onChange={update('idNumber')} /></div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Insurance / scheme</label>
            <select className="fi" value={values.insuranceScheme} onChange={update('insuranceScheme')}>
              <option value="">-- None --</option>
              <option>PMJAY / Ayushman Bharat</option><option>ESI</option><option>CGHS</option><option>Private insurance</option>
            </select>
          </div>
          <div><label className="flbl">Policy / card number</label><input className="fi" value={values.insuranceNumber} onChange={update('insuranceNumber')} /></div>
        </div>

        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '14px 0 8px' }}>Additional</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Referral source</label>
            <select className="fi" value={values.referralSource} onChange={update('referralSource')}>
              <option value="">-- Select --</option>
              <option>Walk-in</option><option>Doctor referral</option><option>Camp / outreach</option>
              <option>Social media</option><option>Previous patient</option>
            </select>
          </div>
          <div><label className="flbl">Preferred language</label>
            <select className="fi" value={values.preferredLanguage} onChange={update('preferredLanguage')}>
              <option>Hindi</option><option>English</option><option>Garhwali</option><option>Punjabi</option>
            </select>
          </div>
        </div>
        <div style={{ marginBottom: 16 }}>
          <label className="flbl">Remarks</label>
          <textarea className="fi" rows={2} value={values.remarks} onChange={update('remarks')} />
        </div>

        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-primary" onClick={handleRegister} disabled={loading}>
            <i className="ti ti-user-check"></i> {loading ? 'Working...' : 'Register Patient'}
          </button>
          <button className="btn btn-green" onClick={handleRegisterAndVisit} disabled={loading}>
            <i className="ti ti-file-plus"></i> Register &amp; Create Visit
          </button>
          <button className="btn" onClick={() => router.push('/dashboard')}>Cancel</button>
        </div>
      </div>

      <div>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Duplicate Check
          </div>
          {values.mobile.length < 10 && (
            <div style={{ textAlign: 'center', padding: 16, color: 'var(--g400)', fontSize: 13 }}>
              <i className="ti ti-shield-check" style={{ fontSize: 26, display: 'block', marginBottom: 8, color: 'var(--g300)' }}></i>
              Enter mobile number to check for existing records
            </div>
          )}
          {values.mobile.length === 10 && duplicates.length === 0 && (
            <div className="msg-success" style={{ margin: 0 }}>
              <i className="ti ti-circle-check"></i> No matching records found.
            </div>
          )}
          {duplicates.map((d) => (
            <div key={d.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div style={{ fontWeight: 700 }}>{d.first_name} {d.last_name}</div>
              <div style={{ color: 'var(--g500)' }}>{d.uhid} -- {d.age} {d.gender} -- {d.mobile}</div>
            </div>
          ))}
        </div>
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

EOF

cat > 'app/(main)/appointments/register-button.js' << 'EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient } from '../patients/actions';
import { linkPatientToAppointment } from './actions';

function toTitleCase(str) {
  return str.trim().toLowerCase().replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

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
        <input className="fi" placeholder="First name *" value={firstName} onChange={(e) => setFirstName(e.target.value)} onBlur={() => setFirstName((v) => toTitleCase(v))} />
        <input className="fi" placeholder="Last name *" value={lastName} onChange={(e) => setLastName(e.target.value)} onBlur={() => setLastName((v) => toTitleCase(v))} />
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

echo "Live name-casing formatting added to all registration forms."
