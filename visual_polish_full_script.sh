# Remove old flat page locations -- they've moved into app/(main)/
rm -rf app/patients app/appointments app/visits app/queue app/pharmacy app/optometry app/consultation app/billing app/dashboard

mkdir -p 'app/(main)/appointments/new' 'app/(main)/billing/[visitId]' 'app/(main)/consultation/[id]' 'app/(main)/dashboard' 'app/(main)/optometry/[id]' 'app/(main)/patients/new' 'app/(main)/pharmacy' 'app/(main)/queue' 'app/(main)/visits/new' app/components

cat > 'app/(main)/layout.js' << 'EOF'
import AppShell from '../components/AppShell';

export default function MainLayout({ children }) {
  return <AppShell>{children}</AppShell>;
}

EOF

cat > 'app/(main)/patients/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

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
          <div style={{ fontSize: 18, fontWeight: 700 }}>Patients</div>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
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
          <button type="submit" className="btn btn-primary">
            Search
          </button>
          {q && (
            <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
              Clear
            </Link>
          )}
        </form>

        {justRegistered && (
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
            Registered successfully -- UHID: <strong>{justRegistered}</strong>
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>UHID</th>
              <th style={{ padding: '8px 6px' }}>Name</th>
              <th style={{ padding: '8px 6px' }}>Age / Gender</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Blood Group</th>
              <th style={{ padding: '8px 6px' }}>Registered</th>
            </tr>
          </thead>
          <tbody>
            {(patients || []).map((p) => (
              <tr key={p.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '8px 6px', fontFamily: 'monospace' }}>{p.uhid}</td>
                <td style={{ padding: '8px 6px' }}>
                  {p.first_name} {p.last_name}
                </td>
                <td style={{ padding: '8px 6px' }}>
                  {p.age || '--'} {p.gender}
                </td>
                <td style={{ padding: '8px 6px' }}>{p.mobile}</td>
                <td style={{ padding: '8px 6px' }}>{p.blood_group || '--'}</td>
                <td style={{ padding: '8px 6px', color: 'var(--g500)' }}>
                  {new Date(p.created_at).toLocaleDateString('en-IN')}
                </td>
              </tr>
            ))}
            {(!patients || patients.length === 0) && (
              <tr>
                <td colSpan={6} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
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

cat > 'app/(main)/patients/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

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
  });

  if (error) {
    return { error: error.message };
  }

  return { patient: data };
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
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
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

cat > 'app/(main)/queue/page.js' << 'EOF'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  optometryCallNext,
  optometryCallSpecific,
  doctorCallNext,
  doctorCallSpecific,
  doctorMarkReady,
} from './actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

export default function QueuePage() {
  const [optometry, setOptometry] = useState([]);
  const [doctor, setDoctor] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const { optometry, doctor } = await getQueues();
    setOptometry(optometry);
    setDoctor(doctor);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) {
      setError(result.error);
    }
    refresh();
  }

  const doctorInConsultation = doctor.find((d) => d.status === 'In Consultation');

  return (
    <div style={{ maxWidth: 1100, margin: '40px auto', padding: '0 20px' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}>Queue Management</div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* OPTOMETRY */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>Optometry Queue</div>
            <span style={{ fontSize: 12, color: 'var(--g500)' }}>{optometry.length}</span>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            Call Next
          </button>
          {optometry.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                padding: '10px 0',
                borderBottom: '1px solid var(--g100)',
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ fontWeight: 700, fontSize: 13 }}>
                  {e.token} -- {patientName(e)}
                </div>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                  {e.status} -- waiting {elapsedMin(e.issued_at)} min
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => runAction(optometryCallSpecific, e.id)}>
                  Call
                </button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary" style={{ padding: '4px 10px', fontSize: 12, textDecoration: 'none' }}>
                  Enter Findings
                </Link>
              )}
            </div>
          ))}
          {optometry.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 20 }}>Empty</div>
          )}
        </div>

        {/* DOCTOR */}
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>Doctor Queue</div>
            <span style={{ fontSize: 12, color: 'var(--g500)' }}>{doctor.length}</span>
          </div>
          <button
            className="btn btn-primary"
            style={{ width: '100%', marginBottom: 12 }}
            onClick={() => runAction(doctorCallNext)}
            disabled={!!doctorInConsultation}
          >
            Call Next
          </button>

          {doctorInConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>
                {doctorInConsultation.token} -- {patientName(doctorInConsultation)}
              </div>
              <Link
                href={`/consultation/${doctorInConsultation.id}`}
                className="btn btn-primary"
                style={{ fontSize: 12, marginTop: 8, textDecoration: 'none', display: 'inline-block' }}
              >
                Open Consultation
              </Link>
            </div>
          )}

          {doctor
            .filter((e) => e.id !== doctorInConsultation?.id)
            .map((e) => {
              const notAvailable = e.status === 'Awaiting Dilation' || e.status === 'Awaiting Investigation';
              const since = notAvailable ? e.sent_out_at : e.issued_at;
              return (
                <div
                  key={e.id}
                  style={{
                    display: 'flex',
                    justifyContent: 'space-between',
                    alignItems: 'center',
                    padding: '10px 0',
                    borderBottom: '1px solid var(--g100)',
                    opacity: notAvailable ? 0.6 : 1,
                  }}
                >
                  <div>
                    <div style={{ fontWeight: 700, fontSize: 13 }}>
                      {e.token} -- {patientName(e)}
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                      {e.status} -- {elapsedMin(since)} min
                    </div>
                  </div>
                  {(e.status === 'Waiting' || e.status === 'Ready for Review') && (
                    <button
                      className="btn"
                      style={{ padding: '4px 10px', fontSize: 12 }}
                      onClick={() => runAction(doctorCallSpecific, e.id)}
                      disabled={!!doctorInConsultation}
                    >
                      Call
                    </button>
                  )}
                  {notAvailable && (
                    <button className="btn" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => runAction(doctorMarkReady, e.id)}>
                      Mark Ready
                    </button>
                  )}
                </div>
              );
            })}
          {doctor.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 20 }}>Empty</div>
          )}
        </div>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/queue/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

function tokenNum(token) {
  return parseInt(token.split('-')[1], 10);
}

export async function getQueues() {
  const supabase = await createClient();

  const { data: entries, error } = await supabase
    .from('queue_entries')
    .select('*, visits(patients(first_name, last_name, uhid))')
    .neq('status', 'Done')
    .order('issued_at', { ascending: true });

  if (error) return { optometry: [], doctor: [] };

  const optometry = entries.filter((e) => e.department === 'Optometry');
  const doctor = entries.filter((e) => e.department === 'Doctor').sort((a, b) => tokenNum(a.token) - tokenNum(b.token));

  return { optometry, doctor };
}

// ── OPTOMETRY ──
export async function optometryCallNext() {
  const supabase = await createClient();
  const { data: waiting } = await supabase
    .from('queue_entries')
    .select('*')
    .eq('department', 'Optometry')
    .eq('status', 'Waiting');

  if (!waiting || waiting.length === 0) return { error: 'No one waiting in Optometry.' };

  const next = waiting.sort((a, b) => tokenNum(a.token) - tokenNum(b.token))[0];
  return optometryCallSpecific(next.id);
}

export async function optometryCallSpecific(id) {
  const supabase = await createClient();

  // Only one patient can be "Calling" at a time -- calling someone new
  // resets whoever was previously being called back to Waiting.
  await supabase
    .from('queue_entries')
    .update({ status: 'Waiting' })
    .eq('department', 'Optometry')
    .eq('status', 'Calling');

  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Calling', called_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

export async function optometryComplete(id) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('optometry_complete', { p_queue_entry_id: id });
  if (error) return { error: error.message };
  return { success: true };
}

// ── DOCTOR ──
export async function doctorCallNext() {
  const supabase = await createClient();
  const { data: available } = await supabase
    .from('queue_entries')
    .select('*')
    .eq('department', 'Doctor')
    .in('status', ['Waiting', 'Ready for Review']);

  if (!available || available.length === 0) return { error: 'No one available to call.' };

  const next = available.sort((a, b) => tokenNum(a.token) - tokenNum(b.token))[0];
  return doctorCallSpecific(next.id);
}

export async function doctorCallSpecific(id) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'In Consultation', called_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

export async function doctorComplete(id) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Done', completed_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

export async function doctorSendOut(id, kind) {
  const supabase = await createClient();
  const status = kind === 'dilate' ? 'Awaiting Dilation' : 'Awaiting Investigation';
  const { error } = await supabase
    .from('queue_entries')
    .update({ status, sent_out_at: new Date().toISOString() })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

export async function doctorMarkReady(id) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('queue_entries')
    .update({ status: 'Ready for Review' })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/(main)/billing/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getInvoiceForVisit(visitId) {
  const supabase = await createClient();

  const { data: visit, error: visitError } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();

  if (visitError) return { error: visitError.message };

  const { data: invoice, error: invError } = await supabase.rpc('get_or_create_invoice_for_visit', {
    p_visit_id: visitId,
  });

  if (invError) return { error: invError.message };

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoice.id)
    .order('id');

  return { visit, invoice, lineItems: lineItems || [] };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function addLineItem(invoiceId, serviceCode, qty) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeLineItem(lineItemId) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId });
  if (error) return { error: error.message };
  return { success: true };
}

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/(main)/billing/[visitId]/page.js' << 'EOF'
import BillingForm from './billing-form';

export default async function BillingPage({ params }) {
  const { visitId } = await params;
  return <BillingForm visitId={visitId} />;
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
    return <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.visit.patients;
  const inv = data.invoice;
  const balanceDue = inv.net - inv.paid;

  return (
    <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>Billing</div>
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

cat > 'app/(main)/consultation/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_findings')
    .select('*')
    .eq('visit_id', visitId)
    .order('recorded_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  let { data: encounter } = await supabase
    .from('encounters')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'In Consultation')
    .maybeSingle();

  if (!encounter) {
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
  }

  const [{ data: diagnoses }, { data: prescriptions }, { data: investigations }] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
  ]);

  return { entry, findings, encounter, diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [] };
}

// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function removeDiagnosis(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removePrescription(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId) {
  return doctorSendOut(queueEntryId, 'dilate');
}

export async function sendForInvestigationFromConsultation(queueEntryId) {
  return doctorSendOut(queueEntryId, 'investigate');
}

EOF

cat > 'app/(main)/consultation/[id]/page.js' << 'EOF'
import ConsultationForm from './consultation-form';

export default async function ConsultationPage({ params }) {
  const { id } = await params;
  return <ConsultationForm queueEntryId={id} />;
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
    return <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const f = data.findings;

  return (
    <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>Consultation -- {data.entry.token}</div>
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

cat > 'app/(main)/appointments/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';

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
                  <td style={{ padding: '8px 6px' }}>{name}</td>
                  <td style={{ padding: '8px 6px' }}>{mobile}</td>
                  <td style={{ padding: '8px 6px' }}>{a.visit_type}</td>
                  <td style={{ padding: '8px 6px' }}>{a.profiles?.full_name || '--'}</td>
                  <td style={{ padding: '8px 6px' }}>{a.status}</td>
                  <td style={{ padding: '8px 6px', position: 'relative' }}>
                    {a.status === 'Booked' && isRegistered && <CheckInButton appointmentId={a.id} />}
                    {a.status === 'Booked' && !isRegistered && (
                      <RegisterUnregisteredButton appointmentId={a.id} tempName={a.patient_name_temp} tempMobile={a.mobile_temp} />
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

cat > 'app/(main)/appointments/check-in-button.js' << 'EOF'
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

cat > 'app/(main)/appointments/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function searchPatientsForBooking(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);

  if (error) return [];
  return data;
}

export async function getDoctors() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('profiles')
    .select('id, full_name, designation')
    .ilike('designation', '%ophthalmologist%')
    .eq('status', 'Active');

  if (error) return [];
  return data;
}

export async function linkPatientToAppointment(appointmentId, patientId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('appointments')
    .update({ patient_id: patientId, patient_name_temp: null, mobile_temp: null })
    .eq('id', appointmentId);

  if (error) return { error: error.message };
  return { success: true };
}

export async function createAppointment(values) {
  const supabase = await createClient();

  const payload = {
    patient_id: values.patientId || null,
    patient_name_temp: values.patientId ? null : values.patientName,
    mobile_temp: values.patientId ? null : values.mobile,
    doctor_id: values.doctorId || null,
    appointment_date: values.date,
    appointment_time: values.time,
    visit_type: values.visitType,
    remarks: values.remarks || null,
  };

  const { data, error } = await supabase
    .from('appointments')
    .insert(payload)
    .select()
    .single();

  if (error) {
    return { error: error.message };
  }

  return { appointment: data };
}

EOF

cat > 'app/(main)/appointments/register-button.js' << 'EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient } from '../patients/actions';
import { linkPatientToAppointment } from './actions';

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
        <input className="fi" placeholder="First name *" value={firstName} onChange={(e) => setFirstName(e.target.value)} />
        <input className="fi" placeholder="Last name *" value={lastName} onChange={(e) => setLastName(e.target.value)} />
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
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 20 }}>Book Appointment</div>

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
    <div style={{ maxWidth: 800, margin: '40px auto', padding: '0 20px' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}>Pharmacy -- Pending Dispensing</div>
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

cat > 'app/(main)/pharmacy/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getPendingPrescriptions() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .eq('status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  // Group flat prescription rows by visit, since a pharmacist hands over
  // everything for one patient's visit together, not drug by drug.
  const groups = {};
  data.forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: rx.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

export async function dispensePrescription(id) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
  if (error) return { error: error.message };
  return { success: true };
}

export async function dispenseAllForVisit(prescriptionIds) {
  const supabase = await createClient();
  for (const id of prescriptionIds) {
    const { error } = await supabase.rpc('dispense_prescription_and_bill', { p_prescription_id: id });
    if (error) return { error: error.message };
  }
  return { success: true };
}

EOF

cat > 'app/(main)/dashboard/page.js' << 'EOF'
import { createClient } from '@/lib/supabase-server';

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

  const today = new Date().toISOString().slice(0, 10);

  const [{ count: patientCount }, { count: apptCount }, { count: visitCount }, { count: rxCount }] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
  ]);

  return (
    <div>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>Dashboard</div>
      <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 20 }}>
        Welcome back, {profile?.full_name || user.email}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Patients</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{patientCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{apptCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Open Visits</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{visitCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Pending Prescriptions</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{rxCount ?? 0}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-user-circle" style={{ color: 'var(--blue)' }}></i> Your Profile
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Name:</strong> {profile?.full_name || '(not set yet)'}</div>
          <div><strong>Designation:</strong> {profile?.designation || '(not set yet)'}</div>
          <div><strong>Department:</strong> {profile?.department || '(not set yet)'}</div>
          <div><strong>Status:</strong> <span className="badge b-green">{profile?.status}</span></div>
          <div><strong>Email:</strong> {user.email}</div>
        </div>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/optometry/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getQueueEntryForOptometry(queueEntryId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (error) return { error: error.message };
  return { entry: data };
}

export async function saveFindingsAndComplete(queueEntryId, visitId, findings) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error: findingsError } = await supabase.from('optometry_findings').insert({
    visit_id: visitId,
    re_va: findings.reVa || null,
    le_va: findings.leVa || null,
    re_iop: findings.reIop ? parseFloat(findings.reIop) : null,
    le_iop: findings.leIop ? parseFloat(findings.leIop) : null,
    re_sph: findings.reSph || null,
    le_sph: findings.leSph || null,
    re_cyl: findings.reCyl || null,
    le_cyl: findings.leCyl || null,
    recorded_by: userData?.user?.id || null,
  });

  if (findingsError) {
    return { error: findingsError.message };
  }

  const { error: completeError } = await supabase.rpc('optometry_complete', {
    p_queue_entry_id: queueEntryId,
  });

  if (completeError) {
    return { error: completeError.message };
  }

  return { success: true };
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
      <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
        <div className="msg-err">{loadError}</div>
      </div>
    );
  }

  if (!entry) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = entry.visits?.patients;

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
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

cat > 'app/(main)/optometry/[id]/page.js' << 'EOF'
import OptometryForm from './optometry-form';

export default async function OptometryEntryPage({ params }) {
  const { id } = await params;
  return <OptometryForm queueEntryId={id} />;
}

EOF

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
              <th style={{ padding: '8px 6px' }}></th>
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
                <td style={{ padding: '8px 6px' }}>
                  <Link href={`/billing/${v.id}`} className="btn btn-primary" style={{ padding: '3px 10px', fontSize: 11, textDecoration: 'none' }}>
                    Bill
                  </Link>
                </td>
              </tr>
            ))}
            {(!visits || visits.length === 0) && (
              <tr>
                <td colSpan={7} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
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

cat > 'app/layout.js' << 'EOF'
import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.5.0/dist/tabler-icons.min.css" />
      </head>
      <body>{children}</body>
    </html>
  );
}

EOF

cat > 'app/globals.css' << 'SHELLEOF'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --blue: #1d4ed8; --blue-lt: #dbeafe; --blue-dk: #1e3a8a; --blue-mid: #3b82f6;
  --green: #15803d; --green-lt: #dcfce7;
  --red: #b91c1c; --red-lt: #fee2e2;
  --amber: #b45309; --amber-lt: #fef3c7;
  --purple: #7c3aed; --purple-lt: #ede9fe;
  --teal: #0f766e; --teal-lt: #ccfbf1;
  --g50: #f9fafb; --g100: #f3f4f6; --g200: #e5e7eb; --g300: #d1d5db;
  --g400: #9ca3af; --g500: #6b7280; --g600: #4b5563; --g700: #374151; --g800: #1f2937; --g900: #111827;
  --r: 8px; --r-lg: 12px;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
}

/* ── APP SHELL ── */
.app-layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: #fff; border-right: 1px solid var(--g200); display: flex; flex-direction: column; flex-shrink: 0; }
.sb-logo { display: flex; align-items: center; gap: 10px; padding: 18px 16px; border-bottom: 1px solid var(--g100); }
.sb-logo-icon { width: 34px; height: 34px; border-radius: 8px; background: var(--blue); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 17px; flex-shrink: 0; }
.sb-name { font-weight: 700; font-size: 13px; }
.sb-sub { font-size: 10px; color: var(--g400); }
.sb-sec { padding: 14px 16px 6px; font-size: 10px; font-weight: 700; color: var(--g400); text-transform: uppercase; letter-spacing: .4px; }
.sb-item { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-size: 13px; color: var(--g600); cursor: pointer; border-left: 3px solid transparent; text-decoration: none; }
.sb-item:hover { background: var(--g50); }
.sb-item.active { background: var(--blue-lt); color: var(--blue-dk); border-left-color: var(--blue); font-weight: 600; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; }
.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.topbar { background: #fff; border-bottom: 1px solid var(--g200); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; }
.top-title { font-size: 16px; font-weight: 700; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 1px; }
.content-area { flex: 1; overflow-y: auto; padding: 24px; }

/* ── CARDS ── */
.card { background: #fff; border: 1px solid var(--g200); border-radius: var(--r-lg); padding: 20px; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-size: 14px; font-weight: 700; display: flex; align-items: center; gap: 7px; }

/* ── BUTTONS ── */
.btn { padding: 9px 16px; border-radius: var(--r); font-size: 13px; font-weight: 600; cursor: pointer; border: 1px solid var(--g200); background: #fff; color: var(--g700); font-family: inherit; transition: all .12s; display: inline-flex; align-items: center; gap: 6px; }
.btn:hover { background: var(--g50); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; }
.btn-primary:hover { background: var(--blue-dk); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; }
.btn-sm { padding: 5px 10px; font-size: 11.5px; }

/* ── BADGES ── */
.badge { padding: 2px 10px; border-radius: 12px; font-size: 11px; font-weight: 700; display: inline-flex; align-items: center; gap: 4px; }
.b-blue { background: var(--blue-lt); color: var(--blue); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi { width: 100%; padding: 9px 12px; border: 1.5px solid var(--g200); border-radius: var(--r); font-size: 13px; font-family: inherit; background: #fff; }
.fi:focus { outline: none; border-color: var(--blue); }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }
.msg-err { background: var(--red-lt); color: var(--red); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-success { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 8px 10px; color: var(--g500); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .3px; border-bottom: 1.5px solid var(--g200); }
.tbl td { padding: 9px 10px; border-bottom: 1px solid var(--g100); }

SHELLEOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${pathname.startsWith(item.href) ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                {item.label}
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">VEDA HMIS</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}

EOF

cat > 'jsconfig.json' << 'EOF'
{
  "compilerOptions": {
    "baseUrl": ".",
    "paths": {
      "@/*": ["./*"]
    }
  }
}

EOF

echo "Full sidebar restructuring applied -- app now uses a persistent shell on every page."
