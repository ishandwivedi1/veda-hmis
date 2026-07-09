mkdir -p 'app/(main)/patients/new'

cat > 'app/(main)/patients/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { createWalkInVisit } from '@/app/(main)/visits/actions';

export async function registerPatient(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('register_patient', {
    p_first_name: values.firstName,
    p_last_name: values.lastName,
    p_age: values.age ? parseInt(values.age, 10) : null,
    p_gender: values.gender,
    p_mobile: values.mobile,
    p_address: values.address || null,
    p_blood_group: values.bloodGroup || null,
    p_date_of_birth: values.dateOfBirth || null,
    p_alternate_mobile: values.alternateMobile || null,
    p_city: values.city || null,
    p_state: values.state || null,
    p_pin_code: values.pinCode || null,
    p_id_type: values.idType || null,
    p_id_number: values.idNumber || null,
    p_insurance_scheme: values.insuranceScheme || null,
    p_insurance_number: values.insuranceNumber || null,
    p_referral_source: values.referralSource || null,
    p_preferred_language: values.preferredLanguage || null,
    p_remarks: values.remarks || null,
  });

  if (error) {
    return { error: error.message };
  }

  return { patient: data };
}

// Real-time duplicate check as the receptionist types a mobile number --
// matches M04's "Duplicate check" panel.
export async function checkDuplicateMobile(mobile) {
  if (!mobile || mobile.length < 10) return [];
  const supabase = await createClient();
  const { data } = await supabase.from('patients').select('id, uhid, first_name, last_name, mobile, age, gender').eq('mobile', mobile);
  return data || [];
}

// Register a patient and immediately open a visit for them in one step --
// matches M04's "Register & create visit" button.
export async function registerAndCreateVisit(values) {
  const regResult = await registerPatient(values);
  if (regResult.error) return regResult;

  const visitResult = await createWalkInVisit({
    patientId: regResult.patient.id,
    doctorId: null,
    visitType: 'New Consultation',
  });

  if (visitResult.error) {
    // Registration succeeded even though the visit failed -- return both
    // pieces of information so the UI can be honest about what happened.
    return { patient: regResult.patient, visitError: visitResult.error };
  }

  return { patient: regResult.patient, visit: visitResult.visit };
}

EOF

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
          <div><label className="flbl">First name *</label><input className="fi" value={values.firstName} onChange={update('firstName')} /></div>
          <div><label className="flbl">Last name *</label><input className="fi" value={values.lastName} onChange={update('lastName')} /></div>
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
          <div><label className="flbl">City</label><input className="fi" value={values.city} onChange={update('city')} /></div>
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

echo "Extended patient registration (M04 parity) applied."
