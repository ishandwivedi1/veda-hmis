'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { updatePatient, resendRegistrationWhatsApp } from '../../actions';

function calcAge(dob) {
  if (!dob) return '';
  const birth = new Date(dob);
  const now = new Date();
  let age = now.getFullYear() - birth.getFullYear();
  const m = now.getMonth() - birth.getMonth();
  if (m < 0 || (m === 0 && now.getDate() < birth.getDate())) age--;
  return age >= 0 ? String(age) : '';
}

function toTitleCase(str) {
  return str
    .trim()
    .toLowerCase()
    .replace(/(^|[\s-'])\S/g, (c) => c.toUpperCase());
}

export default function EditForm({ patient }) {
  const router = useRouter();

  const [values, setValues] = useState({
    firstName: patient.first_name || '',
    lastName: patient.last_name || '',
    gender: patient.gender || '',
    dateOfBirth: patient.date_of_birth || '',
    age: patient.age != null ? String(patient.age) : '',
    bloodGroup: patient.blood_group || '',
    mobile: patient.mobile || '',
    alternateMobile: patient.alternate_mobile || '',
    address: patient.address || '',
    city: patient.city || '',
    state: patient.state || 'Uttarakhand',
    pinCode: patient.pin_code || '',
    idType: patient.id_type || '',
    idNumber: patient.id_number || '',
    insuranceScheme: patient.insurance_scheme || '',
    insuranceNumber: patient.insurance_number || '',
    referralSource: patient.referral_source || '',
    preferredLanguage: patient.preferred_language || 'Hindi',
    remarks: patient.remarks || '',
  });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [waStatus, setWaStatus] = useState(''); // '', 'sending', 'sent', 'error'
  const [waError, setWaError] = useState('');

  async function handleResendWhatsApp() {
    setWaStatus('sending');
    setWaError('');
    const result = await resendRegistrationWhatsApp(patient.id);
    if (result.error) {
      setWaStatus('error');
      setWaError(result.error);
      return;
    }
    setWaStatus('sent');
  }

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

  async function handleSave() {
    setError('');
    if (!validate()) return;
    setLoading(true);
    const result = await updatePatient(patient.id, values);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/patients');
  }

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div className="card">
        <div className="card-head">
          <div className="card-title">
            <i className="ti ti-user-edit" style={{ color: 'var(--blue)' }}></i> Edit Patient
          </div>
          <span style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 13 }}>{patient.uhid}</span>
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

        <div style={{ display: 'flex', gap: 8, alignItems: 'center', flexWrap: 'wrap' }}>
          <button className="btn btn-primary" onClick={handleSave} disabled={loading}>
            <i className="ti ti-device-floppy"></i> {loading ? 'Saving...' : 'Save Changes'}
          </button>
          <button className="btn" onClick={() => router.push('/patients')} disabled={loading}>Cancel</button>
          <button className="btn" onClick={handleResendWhatsApp} disabled={waStatus === 'sending'}>
            <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i>
            {waStatus === 'sending' ? 'Sending...' : 'Resend WhatsApp Confirmation'}
          </button>
          {waStatus === 'sent' && (
            <span style={{ fontSize: 12, color: 'var(--green)' }}>
              <i className="ti ti-circle-check"></i> Sent
            </span>
          )}
          {waStatus === 'error' && (
            <span style={{ fontSize: 12, color: 'var(--red)' }}>
              <i className="ti ti-alert-circle"></i> {waError}
            </span>
          )}
        </div>
      </div>
    </div>
  );
}
