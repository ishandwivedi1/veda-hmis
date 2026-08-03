#!/bin/bash
set -e
echo "Applying: Patient Edit + Create Visit changes"

mkdir -p "app/(main)/patients/[id]/edit"

cat > "app/(main)/patients/actions.js" << 'PYEOF_5856791760627541929'
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

// Edit an existing patient's demographic/contact record. UHID is
// immutable and never touched here -- only the fields collected at
// registration can be corrected later.
export async function updatePatient(patientId, values) {
  if (!patientId) return { error: 'Missing patient id.' };

  const supabase = await createClient();

  if (values.mobile && !/^\d{10}$/.test(values.mobile)) {
    return { error: 'Mobile number must be 10 digits.' };
  }

  const { data, error } = await supabase
    .from('patients')
    .update({
      first_name: values.firstName,
      last_name: values.lastName,
      age: values.age ? parseInt(values.age, 10) : null,
      gender: values.gender,
      mobile: values.mobile,
      address: values.address || null,
      blood_group: values.bloodGroup || null,
      date_of_birth: values.dateOfBirth || null,
      alternate_mobile: values.alternateMobile || null,
      city: values.city || null,
      state: values.state || null,
      pin_code: values.pinCode || null,
      id_type: values.idType || null,
      id_number: values.idNumber || null,
      insurance_scheme: values.insuranceScheme || null,
      insurance_number: values.insuranceNumber || null,
      referral_source: values.referralSource || null,
      preferred_language: values.preferredLanguage || null,
      remarks: values.remarks || null,
    })
    .eq('id', patientId)
    .select()
    .single();

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

PYEOF_5856791760627541929

cat > "app/(main)/patients/page.js" << 'PYEOF_93504043574462197'
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
            <th>Actions</th>
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
                <td>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <Link
                      href={`/patients/${p.id}/edit`}
                      className="btn"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-edit"></i> Edit
                    </Link>
                    <Link
                      href={`/visits/new?patientId=${p.id}`}
                      className="btn btn-primary"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-door-enter"></i> Create Visit
                    </Link>
                  </div>
                </td>
              </tr>
            );
          })}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

PYEOF_93504043574462197

cat > "app/(main)/patients/[id]/edit/page.js" << 'PYEOF_5704344860216924161'
import { notFound } from 'next/navigation';
import { createClient } from '@/lib/supabase-server';
import EditForm from './edit-form';

export default async function EditPatientPage({ params }) {
  const { id } = await params;
  const supabase = await createClient();
  const { data: patient } = await supabase.from('patients').select('*').eq('id', id).single();

  if (!patient) notFound();

  return <EditForm patient={patient} />;
}
PYEOF_5704344860216924161

cat > "app/(main)/patients/[id]/edit/edit-form.js" << 'PYEOF_5895558624174115525'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { updatePatient } from '../../actions';

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

        <div style={{ display: 'flex', gap: 8 }}>
          <button className="btn btn-primary" onClick={handleSave} disabled={loading}>
            <i className="ti ti-device-floppy"></i> {loading ? 'Saving...' : 'Save Changes'}
          </button>
          <button className="btn" onClick={() => router.push('/patients')} disabled={loading}>Cancel</button>
        </div>
      </div>
    </div>
  );
}
PYEOF_5895558624174115525

cat > "app/(main)/visits/actions.js" << 'PYEOF_4053610264566279768'
'use server';

import { createClient } from '@/lib/supabase-server';

// Fetches a single patient for pre-filling the New Visit form when
// arriving via a "Create Visit" link from the Patients list, so the
// front desk doesn't have to search for someone they already had open.
export async function getPatientById(patientId) {
  if (!patientId) return null;
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  return data || null;
}

export async function getDoctorOptionsForVisit() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name')
    .or('designation.ilike.%ophthalmologist%,designation.ilike.%doctor%')
    .eq('status', 'Active')
    .order('full_name');
  return data || [];
}

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
    p_surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

export async function getSurgeryTypeOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name');
  return data || [];
}

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Surgery'];

// Doctor / visit type / priority can be corrected after check-in --
// front desk mistakes happen. Scoped to Open visits only; a closed or
// cancelled visit is a historical record and shouldn't be edited.
export async function updateVisit(visitId, values) {
  const supabase = await createClient();

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is ${visit.status} and can no longer be edited.` };
  if (values.visitType && !VISIT_TYPES.includes(values.visitType)) return { error: 'Invalid visit type.' };

  const { error } = await supabase.from('visits').update({
    doctor_id: values.doctorId || null,
    visit_type: values.visitType,
    priority: values.priority || 'Routine',
    surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  }).eq('id', visitId);
  if (error) return { error: error.message };
  return { success: true };
}

// Cancelling a visit is permanent and needs a reason on record -- also
// pulls the patient out of whatever queue they're still sitting in
// (Optometry/Doctor), since there's nothing left for them to wait for.
// Blocked if the visit already has money collected against it, since
// that needs to go through Invoice Modification instead of silently
// orphaning a paid invoice.
export async function cancelVisit(visitId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is already ${visit.status}.` };

  const { data: invoices } = await supabase.from('invoices').select('id, status, paid').eq('visit_id', visitId);
  const hasPayment = (invoices || []).some((inv) => Number(inv.paid) > 0);
  if (hasPayment) {
    return { error: 'This visit already has payment collected against it -- cancel or modify the invoice first, via Invoice Modification.' };
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('visits').update({
    status: 'Cancelled',
    cancellation_reason: reason.trim(),
    cancelled_by: userData?.user?.id || null,
    cancelled_at: new Date().toISOString(),
  }).eq('id', visitId);
  if (error) return { error: error.message };

  await supabase
    .from('queue_entries')
    .update({ status: 'Cancelled' })
    .eq('visit_id', visitId)
    .not('status', 'in', '("Done","Cancelled")');

  return { success: true };
}


PYEOF_4053610264566279768

cat > "app/(main)/visits/new/page.js" << 'PYEOF_5960122725921704206'
'use client';

import { useState, useEffect, Suspense } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit, getSurgeryTypeOptions, getPatientById } from '@/app/(main)/visits/actions';

export default function NewVisitPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <NewVisitForm />
    </Suspense>
  );
}

function NewVisitForm() {
  const searchParams = useSearchParams();
  const prefillPatientId = searchParams.get('patientId');

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);
  const [prefillLoading, setPrefillLoading] = useState(!!prefillPatientId);
  const [prefillError, setPrefillError] = useState('');

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [surgeryType, setSurgeryType] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
    getSurgeryTypeOptions().then(setSurgeryTypes);
  }, []);

  useEffect(() => {
    if (!prefillPatientId) return;
    let cancelled = false;
    setPrefillLoading(true);
    getPatientById(prefillPatientId).then((patient) => {
      if (cancelled) return;
      setPrefillLoading(false);
      if (patient) {
        setSelectedPatient(patient);
      } else {
        setPrefillError('Could not load that patient -- search for them below instead.');
      }
    });
    return () => { cancelled = true; };
  }, [prefillPatientId]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
    setSearched(true);
  }

  function goToFullRegistration() {
    const isMobile = /^\d{6,}$/.test(searchQuery.trim());
    const params = new URLSearchParams({
      returnTo: 'visit',
      prefillFirstName: isMobile ? '' : searchQuery.trim().split(' ')[0] || '',
      prefillLastName: isMobile ? '' : searchQuery.trim().split(' ').slice(1).join(' ') || '',
      prefillMobile: isMobile ? searchQuery.trim() : '',
    });
    router.push(`/patients/new?${params.toString()}`);
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
    if (visitType === 'Surgery' && !surgeryType) {
      setError('Select the type of surgery.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
      referralSource,
      priority,
      surgeryType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/front-office-dashboard?visitCreated=1');
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
        {prefillError && <div className="msg-err">{prefillError}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {prefillLoading ? (
              <div style={{ padding: '8px 12px', color: 'var(--g500)', fontSize: 13 }}>
                <i className="ti ti-loader-2"></i> Loading patient...
              </div>
            ) : selectedPatient ? (
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
                {searched && searchResults.length === 0 && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={goToFullRegistration}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Register this patient
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: visitType === 'Surgery' ? '1fr 1fr 1fr' : '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => { setVisitType(e.target.value); if (e.target.value !== 'Surgery') setSurgeryType(''); }}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Surgery</option>
              </select>
            </div>
            {visitType === 'Surgery' && (
              <div>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
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


PYEOF_5960122725921704206

echo "Files written. Run: npm run build"
