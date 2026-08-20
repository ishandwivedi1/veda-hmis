'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { registerPatient, registerAndCreateVisit, checkDuplicateMobile } from '../actions';
import { linkPatientToAppointment } from '@/app/(main)/appointments/actions';

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

function RegisteredWithVisitModal({ patient, visit, onClose }) {
  const router = useRouter();
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div style={{ background: '#fff', borderRadius: 12, padding: 22, maxWidth: 420, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <span style={{ width: 36, height: 36, borderRadius: '50%', background: '#dcfce7', color: 'var(--green)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 20 }}></i>
          </span>
          <div>
            <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--g800)' }}>Patient Registered &amp; Visit Created</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>{patient.first_name} {patient.last_name} -- UHID: {patient.uhid}</div>
          </div>
        </div>
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 18, lineHeight: 1.5 }}>
          Visit {visit.visit_number ? <strong>{visit.visit_number}</strong> : 'has'} been created for today. Create the invoice now, or come back to it later from the Billing Dashboard.
        </div>
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" className="btn btn-sm" onClick={onClose}>Return to Dashboard</button>
          <button type="button" className="btn btn-sm btn-primary" onClick={() => router.push(`/billing/new?visitId=${visit.id}`)}>
            <i className="ti ti-receipt"></i> Create Invoice
          </button>
        </div>
      </div>
    </div>
  );
}

export default function RegistrationForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const returnTo = searchParams.get('returnTo'); // 'appointment' | 'visit' | null
  const appointmentId = searchParams.get('appointmentId');

  const [values, setValues] = useState({
    firstName: searchParams.get('prefillFirstName') || '',
    lastName: searchParams.get('prefillLastName') || '',
    gender: '', dateOfBirth: '', age: '', bloodGroup: '',
    mobile: searchParams.get('prefillMobile') || '', alternateMobile: '',
    address: '', city: '', state: 'Uttarakhand', pinCode: '',
    idType: '', idNumber: '', insuranceScheme: '', insuranceNumber: '',
    referralSource: '', preferredLanguage: 'Hindi', remarks: '',
  });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [duplicates, setDuplicates] = useState([]);
  const [registeredVisitInfo, setRegisteredVisitInfo] = useState(null);
  const debounceRef = useRef(null);

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
    if (!values.firstName || !values.gender || !values.mobile) {
      setError('First name, gender, and mobile are required.');
      return false;
    }
    if (!values.age) {
      setError('Age is required.');
      return false;
    }
    if (values.mobile.length !== 10) {
      setError('Mobile number must be 10 digits.');
      return false;
    }
    return true;
  }

  async function handleRegisterOnly() {
    setError('');
    if (!validate()) return;
    setLoading(true);
    const result = await registerPatient(values);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push(`/front-office-dashboard?registered=${result.patient.uhid}`);
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
    setRegisteredVisitInfo({ patient: result.patient, visit: result.visit });
  }

  async function handleRegisterAndLinkAppointment() {
    setError('');
    if (!validate()) return;
    setLoading(true);
    const result = await registerPatient(values);
    if (result.error) { setLoading(false); setError(result.error); return; }
    const linkResult = await linkPatientToAppointment(appointmentId, result.patient.id);
    setLoading(false);
    if (linkResult.error) { setError(`Patient registered (UHID: ${result.patient.uhid}), but linking to the appointment failed: ${linkResult.error}`); return; }
    router.push('/front-office-dashboard?linked=1');
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-head">
          <div className="card-title"><i className="ti ti-user-plus" style={{ color: 'var(--blue)' }}></i> Register New Patient</div>
          <span style={{ fontSize: 11, color: 'var(--g400)' }}>UHID auto-generated on save</span>
        </div>

        {error && <div className="msg-err">{error}</div>}

        {returnTo === 'appointment' && (
          <div className="msg-info">
            <i className="ti ti-calendar-event"></i> Completing registration for a booked appointment -- once saved, this patient will be linked back to their appointment automatically.
          </div>
        )}
        {returnTo === 'visit' && (
          <div className="msg-info">
            <i className="ti ti-door-enter"></i> Registering this patient will also create their visit for today automatically.
          </div>
        )}

        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '14px 0 8px' }}>Personal Information</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">First name *</label><input className="fi" value={values.firstName} onChange={update('firstName')} onBlur={formatOnBlur('firstName')} /></div>
          <div><label className="flbl">Last name</label><input className="fi" value={values.lastName} onChange={update('lastName')} onBlur={formatOnBlur('lastName')} /></div>
          <div><label className="flbl">Gender *</label>
            <select className="fi" value={values.gender} onChange={update('gender')}>
              <option value="">-- Select --</option>
              <option value="M">Male</option><option value="F">Female</option><option value="O">Other</option>
            </select>
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div><label className="flbl">Date of birth</label><input type="date" className="fi" value={values.dateOfBirth} onChange={update('dateOfBirth')} /></div>
          <div><label className="flbl">Age *</label><input type="number" className="fi" value={values.age} onChange={update('age')} /></div>
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

        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
          {returnTo === 'appointment' && (
            <button className="btn btn-primary" onClick={handleRegisterAndLinkAppointment} disabled={loading}>
              <i className="ti ti-calendar-event"></i> {loading ? 'Working...' : 'Register & Link to Appointment'}
            </button>
          )}
          <button className={returnTo === 'visit' ? 'btn btn-primary' : 'btn btn-green'} onClick={handleRegisterAndVisit} disabled={loading}>
            <i className="ti ti-file-plus"></i> {loading ? 'Working...' : 'Register & Create Visit'}
          </button>
          <button className={returnTo ? 'btn' : 'btn btn-primary'} onClick={handleRegisterOnly} disabled={loading}>
            <i className="ti ti-user-check"></i> {loading ? 'Working...' : 'Register Patient Only'}
          </button>
          <button className="btn" onClick={() => router.push('/front-office-dashboard')}>Cancel</button>
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

      {registeredVisitInfo && (
        <RegisteredWithVisitModal
          patient={registeredVisitInfo.patient}
          visit={registeredVisitInfo.visit}
          onClose={() => router.push('/front-office-dashboard?visitCreated=1')}
        />
      )}
    </div>
  );
}

