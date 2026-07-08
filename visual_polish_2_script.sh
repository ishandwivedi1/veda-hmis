mkdir -p app/components 'app/(main)/patients' 'app/(main)/appointments' 'app/(main)/queue'

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

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Open Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

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
            <div className="top-title">{pageTitle}</div>
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

cat > 'app/(main)/patients/page.js' << 'EOF'
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
            <th>Registered</th>
          </tr>
        </thead>
        <tbody>
          {(patients || []).map((p) => (
            <tr key={p.id}>
              <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
              <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
              <td>{p.age || '--'}</td>
              <td><span className={`badge ${GENDER_BADGE[p.gender] || 'b-gray'}`}>{GENDER_LABEL[p.gender] || p.gender}</span></td>
              <td>{p.mobile}</td>
              <td>{p.blood_group ? <span className="badge b-red">{p.blood_group}</span> : '--'}</td>
              <td style={{ color: 'var(--g500)' }}>{new Date(p.created_at).toLocaleDateString('en-IN')}</td>
            </tr>
          ))}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

EOF

cat > 'app/(main)/appointments/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';

const STATUS_BADGE = { Booked: 'b-amber', 'Checked-in': 'b-green', Cancelled: 'b-red', 'No-show': 'b-gray' };

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
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> Appointments
          <span className="badge b-gray">{appointments?.length ?? 0}</span>
        </div>
        <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Book Appointment
        </Link>
      </div>

      <form method="GET" action="/appointments" style={{ display: 'flex', gap: 8, marginBottom: 16, alignItems: 'center' }}>
        <label className="flbl" style={{ marginBottom: 0 }}>Date:</label>
        <input type="date" name="date" defaultValue={dateFilter} className="fi" style={{ width: 180 }} />
        <button type="submit" className="btn"><i className="ti ti-filter"></i> View</button>
      </form>

      {justBooked && <div className="msg-success"><i className="ti ti-circle-check"></i> Appointment booked successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Time</th>
            <th>Patient</th>
            <th>Mobile</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Status</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(appointments || []).map((a) => {
            const isRegistered = !!a.patients;
            const name = isRegistered ? `${a.patients.first_name} ${a.patients.last_name}` : a.patient_name_temp;
            const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
            return (
              <tr key={a.id}>
                <td style={{ fontWeight: 600 }}>{a.appointment_time?.slice(0, 5)}</td>
                <td>{name}</td>
                <td>{mobile}</td>
                <td>{a.visit_type}</td>
                <td>{a.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[a.status] || 'b-gray'}`}>{a.status}</span></td>
                <td style={{ position: 'relative' }}>
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
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                No appointments for this date.
              </td>
            </tr>
          )}
        </tbody>
      </table>
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

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function TokenBadge({ token }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
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
    if (result?.error) setError(result.error);
    refresh();
  }

  const doctorInConsultation = doctor.find((d) => d.status === 'In Consultation');

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* OPTOMETRY */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
              <span className="badge b-gray">{optometry.length}</span>
            </div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>
          {optometry.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Calling' ? 'b-blue' : 'b-gray'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}>
                    <i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m
                  </span>
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn btn-sm" onClick={() => runAction(optometryCallSpecific, e.id)}>Call</button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  Enter Findings
                </Link>
              )}
            </div>
          ))}
          {optometry.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* DOCTOR */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue
              <span className="badge b-gray">{doctor.length}</span>
            </div>
          </div>
          <button
            className="btn btn-primary"
            style={{ width: '100%', marginBottom: 12 }}
            onClick={() => runAction(doctorCallNext)}
            disabled={!!doctorInConsultation}
          >
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {doctorInConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={doctorInConsultation.token} />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(doctorInConsultation)}</span>
              </div>
              <Link
                href={`/consultation/${doctorInConsultation.id}`}
                className="btn btn-primary btn-sm"
                style={{ textDecoration: 'none' }}
              >
                <i className="ti ti-clipboard-text"></i> Open Consultation
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
                    display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                    padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                    opacity: notAvailable ? 0.55 : 1,
                  }}
                >
                  <div>
                    <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                      <TokenBadge token={e.token} />
                      <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                    </div>
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                      <span className={`badge ${notAvailable ? 'b-amber' : 'b-gray'}`}>{e.status}</span>
                      <span className={`badge ${waitBadgeClass(elapsedMin(since))}`}>
                        <i className="ti ti-clock"></i> {elapsedMin(since)}m
                      </span>
                    </div>
                  </div>
                  {(e.status === 'Waiting' || e.status === 'Ready for Review') && (
                    <button className="btn btn-sm" onClick={() => runAction(doctorCallSpecific, e.id)} disabled={!!doctorInConsultation}>
                      Call
                    </button>
                  )}
                  {notAvailable && (
                    <button className="btn btn-sm" onClick={() => runAction(doctorMarkReady, e.id)}>Mark Ready</button>
                  )}
                </div>
              );
            })}
          {doctor.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

EOF

echo "Visual polish pass 2 (Patients, Appointments, Queue, title fix) applied."
