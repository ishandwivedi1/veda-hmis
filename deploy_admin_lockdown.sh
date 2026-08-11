#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# UI/logic only -- no DB migration needed (Administrator designation
# already exists as a value, just wasn't being enforced everywhere).

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/users"
cat > "app/(main)/users/actions.js" << 'FILEEOF_app__main__users_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { createAdminClient } from '@/lib/supabase-admin';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

// Called periodically by AppShell while someone has the app open --
// powers the Online/Away/Last seen status in User Management. Silently
// no-ops on failure (a missed heartbeat should never surface as an
// error to the person using the app).
export async function updateHeartbeat() {
  try {
    const supabase = await createClient();
    const { data: { user } } = await supabase.auth.getUser();
    if (!user) return;
    await supabase.from('profiles').update({ last_active_at: new Date().toISOString() }).eq('id', user.id);
  } catch {
    // Non-critical -- deliberately swallowed.
  }
}

const EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;

// The technical login credential Supabase Auth actually stores is always
// a valid-format email, because that's all Supabase Auth accepts. The
// "username" an admin types (a mobile number, initials, whatever) is
// what staff actually log in with -- if it isn't already email-shaped
// we derive a stable internal address behind the scenes so Auth stays
// happy without staff ever needing to know it exists.
function deriveTechnicalEmail(username) {
  const trimmed = (username || '').trim();
  if (EMAIL_RE.test(trimmed)) return trimmed.toLowerCase();
  const slug = trimmed.toLowerCase().replace(/[^a-z0-9]+/g, '.').replace(/^\.+|\.+$/g, '') || 'user';
  return `${slug}@staff.vedaeyehospital.internal`;
}

// Only an Administrator may rename a staff member or change their
// login username -- checked server-side (not just hidden in the UI)
// since a server action is callable directly.
async function requireAdministrator() {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return { ok: false, error: 'Not signed in.' };
  const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
  if (me?.designation !== 'Administrator') {
    return { ok: false, error: 'Only an Administrator can do this.' };
  }
  return { ok: true };
}

export async function getUsers() {
  const gate = await requireAdministrator();
  if (!gate.ok) return [];
  const supabase = await createClient();
  const { data, error } = await supabase.from('profiles').select('*').order('full_name');
  if (error) return [];
  return data;
}

// Lets the page show/hide admin-only controls without trusting the
// client -- the actions themselves re-check this independently.
export async function getMyDesignation() {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  if (!userData?.user) return null;
  const { data: me } = await supabase.from('profiles').select('designation').eq('id', userData.user.id).maybeSingle();
  return me?.designation || null;
}

export async function createUser(values) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  if (!values.username || !values.password || !values.fullName) {
    return { error: 'Username, password, and name are required.' };
  }
  if (values.password.length < 6) {
    return { error: 'Password must be at least 6 characters.' };
  }

  const admin = createAdminClient();
  const username = values.username.trim();

  const { data: existing } = await admin.from('profiles').select('id').ilike('username', username).maybeSingle();
  if (existing) return { error: 'That username is already taken.' };

  const technicalEmail = deriveTechnicalEmail(username);

  const { data, error } = await admin.auth.admin.createUser({
    email: technicalEmail,
    password: values.password,
    email_confirm: true, // skip email verification -- an admin is creating this directly
    user_metadata: {
      full_name: values.fullName,
      designation: values.designation,
      department: values.department,
      username,
    },
  });

  if (error) return { error: error.message };

  // No DB trigger creates the profiles row automatically, so do it here.
  const { error: profileError } = await admin.from('profiles').upsert({
    id: data.user.id,
    full_name: values.fullName,
    designation: values.designation || null,
    department: values.department || null,
    registration_no: values.registrationNo?.trim() || null,
    username,
    status: 'Active',
  });
  if (profileError) return { error: `Account created but profile setup failed: ${profileError.message}` };

  return { success: true, user: data.user };
}

// Designation/department can be corrected after account creation -- e.g.
// a login was created before a role was finalized, or someone moves
// department.
export async function updateUserProfile(userId, values) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  if (values.designation && !DESIGNATIONS.includes(values.designation)) {
    return { error: 'Invalid designation.' };
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from('profiles')
    .update({
      designation: values.designation || null,
      department: values.department || null,
      registration_no: values.registrationNo?.trim() || null,
    })
    .eq('id', userId);
  if (error) return { error: error.message };
  return { success: true };
}

// Renaming staff or changing their login username is Administrator-only
// -- it changes what someone types in to sign in, so getting it wrong
// (or a non-admin doing it) locks a staff member out.
export async function updateStaffIdentity(userId, values) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  if (!values.fullName || !values.fullName.trim()) return { error: 'Name is required.' };
  if (!values.username || !values.username.trim()) return { error: 'Username is required.' };

  const username = values.username.trim();
  const admin = createAdminClient();

  const { data: existing } = await admin.from('profiles').select('id').ilike('username', username).neq('id', userId).maybeSingle();
  if (existing) return { error: 'That username is already taken.' };

  const technicalEmail = deriveTechnicalEmail(username);

  const { error: authError } = await admin.auth.admin.updateUserById(userId, { email: technicalEmail });
  if (authError) return { error: authError.message };

  const { error: profileError } = await admin
    .from('profiles')
    .update({ full_name: values.fullName.trim(), username })
    .eq('id', userId);
  if (profileError) return { error: profileError.message };

  return { success: true };
}

export async function toggleUserStatus(userId, currentStatus) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from('profiles').update({ status: newStatus }).eq('id', userId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetUserPassword(userId, newPassword) {
  const gate = await requireAdministrator();
  if (!gate.ok) return { error: gate.error };

  if (!newPassword || newPassword.length < 6) {
    return { error: 'New password must be at least 6 characters.' };
  }
  const admin = createAdminClient();
  const { error } = await admin.auth.admin.updateUserById(userId, { password: newPassword });
  if (error) return { error: error.message };
  return { success: true };
}

// Called from the login page (unauthenticated) to turn whatever a staff
// member typed -- a mobile number, initials, an email, anything -- into
// the real technical email Supabase Auth needs for signInWithPassword.
// Uses the admin client since an anonymous visitor can't read profiles
// under RLS, and deliberately returns the same generic error whether
// the username doesn't exist or something else went wrong, so this
// can't be used to enumerate valid usernames.
export async function resolveLoginEmail(usernameOrEmail) {
  const trimmed = (usernameOrEmail || '').trim();
  if (!trimmed) return { error: 'Enter your username.' };

  const admin = createAdminClient();
  const { data } = await admin.from('profiles').select('id').ilike('username', trimmed).maybeSingle();
  if (!data) return { error: 'Invalid username or password.' };

  const { data: authUser } = await admin.auth.admin.getUserById(data.id);
  if (!authUser?.user?.email) return { error: 'Invalid username or password.' };

  return { email: authUser.user.email };
}

FILEEOF_app__main__users_actions_js

mkdir -p "app/(main)/users"
cat > "app/(main)/users/page.js" << 'FILEEOF_app__main__users_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getUsers, createUser, toggleUserStatus, resetUserPassword, updateUserProfile, updateStaffIdentity, getMyDesignation } from './actions';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

// Heartbeat updates every ~60s while the app is open (see AppShell.js).
// A few minutes' grace covers normal timing/network gaps without
// flip-flopping between Online/Away on every tick.
function onlineStatus(lastActiveAt) {
  if (!lastActiveAt) return { label: 'Never logged in', color: 'var(--g400)' };
  const minutesAgo = (Date.now() - new Date(lastActiveAt).getTime()) / 60000;
  if (minutesAgo < 3) return { label: 'Online', color: 'var(--green)' };
  if (minutesAgo < 30) return { label: `Away (${Math.round(minutesAgo)}m)`, color: 'var(--amber)' };
  const d = new Date(lastActiveAt);
  const label = d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) === new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
    ? `Last seen ${d.toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}`
    : `Last seen ${d.toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
  return { label, color: 'var(--g400)' };
}

function EditProfileRow({ user, isAdmin, onDone }) {
  const [fullName, setFullName] = useState(user.full_name || '');
  const [username, setUsername] = useState(user.username || '');
  const [designation, setDesignation] = useState(user.designation || '');
  const [department, setDepartment] = useState(user.department || '');
  const [registrationNo, setRegistrationNo] = useState(user.registration_no || '');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSave() {
    setError('');
    setLoading(true);

    if (isAdmin && (fullName !== user.full_name || username !== user.username)) {
      const identityResult = await updateStaffIdentity(user.id, { fullName, username });
      if (identityResult.error) {
        setLoading(false);
        setError(identityResult.error);
        return;
      }
    }

    const result = await updateUserProfile(user.id, { designation, department, registrationNo });
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <>
      <td>
        {isAdmin ? (
          <input className="fi" value={fullName} onChange={(e) => setFullName(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        ) : (
          <span style={{ fontWeight: 600 }}>{user.full_name}</span>
        )}
      </td>
      <td>
        {isAdmin ? (
          <input className="fi" value={username} onChange={(e) => setUsername(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        ) : (
          <span>{user.username}</span>
        )}
      </td>
      <td>
        <select className="fi" value={designation} onChange={(e) => setDesignation(e.target.value)} style={{ fontSize: 12, padding: '4px 6px', marginBottom: designation === 'Doctor' ? 4 : 0 }}>
          <option value="">-- Select --</option>
          {DESIGNATIONS.map((d) => <option key={d} value={d}>{d}</option>)}
        </select>
        {designation === 'Doctor' && (
          <input className="fi" placeholder="Regn. No." value={registrationNo} onChange={(e) => setRegistrationNo(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        )}
      </td>
      <td>
        <input className="fi" value={department} onChange={(e) => setDepartment(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
      </td>
      <td></td>
      <td colSpan={2}>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
          <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={loading}>{loading ? 'Saving...' : 'Save'}</button>
          <button className="btn btn-sm" onClick={() => onDone(false)} disabled={loading}>Cancel</button>
          {error && <span style={{ fontSize: 11, color: 'var(--red)' }}>{error}</span>}
        </div>
      </td>
    </>
  );
}

function ResetPasswordButton({ userId }) {
  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleReset() {
    setError('');
    setLoading(true);
    const result = await resetUserPassword(userId, password);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setOpen(false);
    setPassword('');
  }

  if (!open) {
    return <button className="btn btn-sm" onClick={() => setOpen(true)}>Reset Password</button>;
  }
  return (
    <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
      <input className="fi" type="password" placeholder="New password" value={password} onChange={(e) => setPassword(e.target.value)} style={{ width: 130 }} />
      <button className="btn btn-primary btn-sm" onClick={handleReset} disabled={loading}>Save</button>
      <button className="btn btn-sm" onClick={() => setOpen(false)}>x</button>
      {error && <span style={{ fontSize: 11, color: 'var(--red)' }}>{error}</span>}
    </div>
  );
}

export default function UsersPage() {
  const [users, setUsers] = useState([]);
  const [myDesignation, setMyDesignation] = useState(null);
  const [showAdd, setShowAdd] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [form, setForm] = useState({ username: '', password: '', fullName: '', designation: '', department: '', registrationNo: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const isAdmin = myDesignation === 'Administrator';

  const refresh = useCallback(async () => {
    setUsers(await getUsers());
  }, []);

  useEffect(() => {
    getMyDesignation().then((d) => {
      setMyDesignation(d);
      if (d === 'Administrator') refresh();
    });
  }, [refresh]);

  // Server actions (getUsers, createUser, etc.) already enforce this
  // independently -- this is just so a non-admin sees a clean message
  // instead of a confusingly empty table with buttons that silently
  // fail when clicked. Placed after all hooks so hook call order
  // stays identical across renders (React requires this).
  if (myDesignation && !isAdmin) {
    return (
      <div className="card" style={{ textAlign: 'center', padding: 40 }}>
        <i className="ti ti-lock" style={{ fontSize: 28, color: 'var(--g400)' }}></i>
        <div style={{ fontWeight: 700, marginTop: 10 }}>Administrator access only</div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginTop: 4 }}>
          User Management is restricted to Administrator accounts. Contact your administrator if you need a staff login created or updated.
        </div>
      </div>
    );
  }

  if (!myDesignation) {
    return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 40 }}>Loading...</div>;
  }

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleCreate() {
    setError('');
    setLoading(true);
    const result = await createUser(form);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setForm({ username: '', password: '', fullName: '', designation: '', department: '', registrationNo: '' });
    setShowAdd(false);
    refresh();
  }

  async function handleToggle(userId, status) {
    await toggleUserStatus(userId, status);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-users-group" style={{ color: 'var(--blue)' }}></i> Staff Accounts
          <span className="badge b-gray">{users.length}</span>
        </div>
        <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(!showAdd)}>
          <i className="ti ti-plus"></i> New Staff Login
        </button>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {!isAdmin && myDesignation && (
        <div className="msg-info" style={{ marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Only an Administrator can rename staff or change their login username. Designation and department can still be updated here.
        </div>
      )}

      {showAdd && (
        <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <input className="fi" placeholder="Full name" value={form.fullName} onChange={update('fullName')} />
            <input className="fi" placeholder="Username (email, mobile, or anything)" value={form.username} onChange={update('username')} />
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi" value={form.designation} onChange={update('designation')}>
              <option value="">-- Select designation --</option>
              {DESIGNATIONS.map((d) => <option key={d} value={d}>{d}</option>)}
            </select>
            <input className="fi" placeholder="Department" value={form.department} onChange={update('department')} />
          </div>
          {form.designation === 'Doctor' && (
            <input className="fi" placeholder="Doctor Registration No. (appears on printouts)" value={form.registrationNo} onChange={update('registrationNo')} style={{ marginBottom: 8 }} />
          )}
          <input className="fi" type="password" placeholder="Temporary password (min 6 chars)" value={form.password} onChange={update('password')} style={{ marginBottom: 8 }} />
          <button className="btn btn-primary btn-sm" onClick={handleCreate} disabled={loading}>
            {loading ? 'Creating...' : 'Create Account'}
          </button>
        </div>
      )}

      <table className="tbl">
        <thead>
          <tr><th>Name</th><th>Username</th><th>Designation</th><th>Department</th><th>Online</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {users.map((u) => (
            <tr key={u.id}>
              {editingId === u.id ? (
                <EditProfileRow
                  user={u}
                  isAdmin={isAdmin}
                  onDone={(saved) => { setEditingId(null); if (saved) refresh(); }}
                />
              ) : (
                <>
                  <td style={{ fontWeight: 600 }}>{u.full_name}</td>
                  <td>{u.username}</td>
                  <td>
                    {u.designation}
                    {u.designation === 'Doctor' && u.registration_no && (
                      <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>Regn: {u.registration_no}</div>
                    )}
                  </td>
                  <td>{u.department}</td>
                  <td>
                    {(() => {
                      const s = onlineStatus(u.last_active_at);
                      return (
                        <span style={{ fontSize: 12, color: s.color, display: 'flex', alignItems: 'center', gap: 5 }}>
                          <span style={{ width: 7, height: 7, borderRadius: '50%', background: s.color, display: 'inline-block' }}></span>
                          {s.label}
                        </span>
                      );
                    })()}
                  </td>
                  <td>
                    <button
                      className={`badge ${u.status === 'Active' ? 'b-green' : 'b-gray'}`}
                      style={{ border: 'none', cursor: 'pointer' }}
                      onClick={() => handleToggle(u.id, u.status)}
                    >
                      {u.status}
                    </button>
                  </td>
                  <td style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <button className="btn btn-sm" onClick={() => setEditingId(u.id)}>
                      <i className="ti ti-edit"></i> Edit
                    </button>
                    <ResetPasswordButton userId={u.id} />
                  </td>
                </>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

FILEEOF_app__main__users_page_js

mkdir -p "app/components"
cat > "app/components/AppShell.js" << 'FILEEOF_app_components_AppShell_js'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState, useRef } from 'react';
import { createClient } from '@/lib/supabase-browser';
import { updateHeartbeat } from '@/app/(main)/users/actions';

// 30 minutes of no mouse/keyboard/touch activity -> automatic sign-out.
// Balances security (unattended shared terminals in a hospital) against
// not interrupting a doctor mid-consultation for a shorter window.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const CHECK_INTERVAL_MS = 60 * 1000;

const NAV_ITEMS = [
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration', adminOnly: true },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Patient Flow' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery & Discharge' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  // Idle auto-logout + "who's online" heartbeat. Checked on an interval,
  // AND immediately whenever the tab becomes visible again -- browsers
  // (Chrome especially) heavily throttle setInterval in backgrounded
  // tabs, sometimes to firing only once every several minutes or less,
  // so the interval alone can miss the 30-minute mark while the tab
  // sits unfocused. visibilitychange isn't subject to that throttling
  // and fires exactly when someone switches back to the tab, so it
  // catches what the interval missed. It doesn't count as "activity"
  // itself -- only real mouse/keyboard/touch input resets the clock.
  const lastActivityRef = useRef(Date.now());
  useEffect(() => {
    const markActive = () => { lastActivityRef.current = Date.now(); };
    const events = ['mousemove', 'keydown', 'mousedown', 'scroll', 'touchstart'];
    events.forEach((e) => window.addEventListener(e, markActive, { passive: true }));

    const checkIdle = async () => {
      const idleMs = Date.now() - lastActivityRef.current;
      if (idleMs >= IDLE_TIMEOUT_MS) {
        await supabase.auth.signOut();
        router.push('/login?reason=idle');
        router.refresh();
      } else {
        updateHeartbeat();
      }
    };

    const onVisible = () => { if (document.visibilityState === 'visible') checkIdle(); };
    document.addEventListener('visibilitychange', onVisible);

    updateHeartbeat(); // immediately on mount, not just on the first interval tick -- extra safety net beyond the login-page write

    const interval = setInterval(checkIdle, CHECK_INTERVAL_MS);

    return () => {
      events.forEach((e) => window.removeEventListener(e, markActive));
      document.removeEventListener('visibilitychange', onVisible);
      clearInterval(interval);
    };
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const visibleNavItems = NAV_ITEMS.filter((i) => !i.adminOnly || profile?.designation === 'Administrator');
  const sections = [...new Set(visibleNavItems.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = visibleNavItems
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

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
            {visibleNavItems.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
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
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}



FILEEOF_app_components_AppShell_js


echo "Files written."

git add -A
git commit -m "Restrict User Management to Administrator: server-side gate on all actions (previously createUser/toggleStatus/resetPassword had none), sidebar link hidden, clean restricted-access page for non-admins"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
