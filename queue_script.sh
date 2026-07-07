mkdir -p app/queue app/dashboard app/visits

cat > app/visits/actions.js << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

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

cat > app/queue/actions.js << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

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

cat > app/queue/page.js << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getQueues,
  optometryCallNext,
  optometryCallSpecific,
  optometryComplete,
  doctorCallNext,
  doctorCallSpecific,
  doctorComplete,
  doctorSendOut,
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
                <button className="btn btn-primary" style={{ padding: '4px 10px', fontSize: 12 }} onClick={() => runAction(optometryComplete, e.id)}>
                  Complete Exam
                </button>
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
              <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
                <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => runAction(doctorComplete, doctorInConsultation.id)}>
                  Complete Visit
                </button>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => runAction(doctorSendOut, doctorInConsultation.id, 'dilate')}>
                  Send for Dilation
                </button>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => runAction(doctorSendOut, doctorInConsultation.id, 'investigate')}>
                  Send for Investigation
                </button>
              </div>
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

cat > app/dashboard/page.js << 'EOF'
import { createClient } from '../../lib/supabase-server';
import SignOutButton from './sign-out-button';
import Link from 'next/link';

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

  return (
    <div style={{ maxWidth: 640, margin: '60px auto', padding: '0 20px' }}>
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
            <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA HMIS</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Real login, real database -- Phase 1 proof of concept
            </div>
          </div>
          <SignOutButton />
        </div>

        <div
          style={{
            background: 'var(--green-lt)',
            color: 'var(--green)',
            padding: '10px 14px',
            borderRadius: 8,
            fontSize: 13,
            marginBottom: 20,
          }}
        >
          You are genuinely logged in via Supabase Auth, and this page just
          read your staff profile from the real <code>profiles</code> table.
        </div>

        <div style={{ fontSize: 13, lineHeight: 1.8 }}>
          <div>
            <strong>Name:</strong> {profile?.full_name || '(not set yet)'}
          </div>
          <div>
            <strong>Designation:</strong> {profile?.designation || '(not set yet)'}
          </div>
          <div>
            <strong>Department:</strong> {profile?.department || '(not set yet)'}
          </div>
          <div>
            <strong>Status:</strong> {profile?.status}
          </div>
          <div>
            <strong>Email:</strong> {user.email}
          </div>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 20, paddingTop: 20, borderTop: '1px solid var(--g200)' }}>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
          </Link>
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            View All Patients
          </Link>
          <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Book Appointment
          </Link>
          <Link href="/appointments" className="btn" style={{ textDecoration: 'none' }}>
            View Appointments
          </Link>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
          <Link href="/visits" className="btn" style={{ textDecoration: 'none' }}>
            View Open Visits
          </Link>
          <Link href="/queue" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            Queue Management
          </Link>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Queue Management module created."
