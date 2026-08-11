 #!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# The database side (login_history table, lockout columns, RLS) is
# ALREADY confirmed live on both projects -- untouched by the earlier
# rollback, since Vercel rollbacks only affect application code, not
# the database. This script re-pushes the application code, which
# WAS rolled back along with everything else from today.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "app/(main)/users"
cat > "app/(main)/users/actions.js" << 'FILEEOF_app__main__users_actions_js'
'use server';

import { createClient } from '@/lib/supabase-server';
import { createAdminClient } from '@/lib/supabase-admin';
import { headers } from 'next/headers';

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
  if (values.password.length < 8) {
    return { error: 'Password must be at least 8 characters.' };
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

  if (!newPassword || newPassword.length < 8) {
    return { error: 'New password must be at least 8 characters.' };
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

// ── LOGIN LOCKOUT ──
// Brute-force protection: 5 failed attempts locks the account out for
// 15 minutes. All three of these run pre-authentication (checked
// before, and recorded right after, the actual signInWithPassword
// call the login page makes directly against Supabase Auth) -- so
// they use the admin client throughout rather than the RLS-bound one,
// since there's no session to attach to yet on a failed attempt, and
// avoiding any dependency on session-cookie timing on a fresh success
// keeps this simple and reliable either way.
const MAX_FAILED_ATTEMPTS = 5;
const LOCKOUT_MINUTES = 15;

export async function checkLoginAllowed(usernameOrEmail) {
  const trimmed = (usernameOrEmail || '').trim();
  if (!trimmed) return { allowed: true };

  const admin = createAdminClient();
  const { data } = await admin.from('profiles').select('locked_until').ilike('username', trimmed).maybeSingle();
  if (!data?.locked_until) return { allowed: true };

  const remainingMs = new Date(data.locked_until).getTime() - Date.now();
  if (remainingMs <= 0) return { allowed: true };

  const minutes = Math.max(1, Math.ceil(remainingMs / 60000));
  return { allowed: false, error: `Too many failed attempts. Try again in ${minutes} minute${minutes === 1 ? '' : 's'}.` };
}

export async function recordLoginFailure(usernameOrEmail) {
  // Wrapped entirely -- this is called (and awaited) right in the
  // middle of the real login flow, so a bug here must never surface
  // as a fake "login failed" for someone whose password was actually
  // correct, or hide the real "invalid credentials" message for
  // someone whose password was wrong.
  try {
    const trimmed = (usernameOrEmail || '').trim();
    if (!trimmed) return;

    const admin = createAdminClient();
    const { data } = await admin.from('profiles').select('id, failed_login_attempts').ilike('username', trimmed).maybeSingle();
    if (!data) return; // Unknown username -- nothing to track, and this stays silent so it can't be used to enumerate valid usernames.

    const attempts = (data.failed_login_attempts || 0) + 1;
    if (attempts >= MAX_FAILED_ATTEMPTS) {
      await admin.from('profiles').update({
        failed_login_attempts: 0,
        locked_until: new Date(Date.now() + LOCKOUT_MINUTES * 60000).toISOString(),
      }).eq('id', data.id);
    } else {
      await admin.from('profiles').update({ failed_login_attempts: attempts }).eq('id', data.id);
    }
  } catch (err) {
    console.error('recordLoginFailure failed:', err.message);
  }
}

export async function recordLoginSuccess(usernameOrEmail) {
  // Same reasoning as recordLoginFailure above -- wrapped entirely so
  // this background bookkeeping can never break an otherwise-
  // successful sign-in.
  try {
    const trimmed = (usernameOrEmail || '').trim();
    if (!trimmed) return;

    const admin = createAdminClient();
    const { data: profile } = await admin.from('profiles').select('id').ilike('username', trimmed).maybeSingle();

    await admin.from('profiles').update({ failed_login_attempts: 0, locked_until: null }).ilike('username', trimmed);

  // Best-effort -- a failed history write should never block someone
  // from actually getting into the app they just successfully signed
  // into. Location comes from Vercel's own geo headers (populated
  // automatically per-request, no external API), so it's approximate
  // and reflects the edge location that served the request -- exact
  // in most cases, off by a city or region on a VPN/mobile network.
  if (profile) {
    try {
      const h = await headers();
      const ip = h.get('x-forwarded-for')?.split(',')[0]?.trim() || h.get('x-real-ip') || null;
      const city = h.get('x-vercel-ip-city') ? decodeURIComponent(h.get('x-vercel-ip-city')) : null;
      const region = h.get('x-vercel-ip-country-region') || null;
      const country = h.get('x-vercel-ip-country') || null;
      const userAgent = h.get('user-agent') || null;

      await admin.from('login_history').insert({
        profile_id: profile.id,
        ip_address: ip,
        city,
        region,
        country,
        user_agent: userAgent,
      });
    } catch (err) {
      console.error('login_history insert failed:', err.message);
    }
  }
  } catch (err) {
    console.error('recordLoginSuccess failed:', err.message);
  }
}

// ── LOGIN HISTORY (Administrator only) ──
export async function getLoginHistory(limit = 200) {
  const gate = await requireAdministrator();
  if (!gate.ok) return [];

  const supabase = await createClient();
  const { data } = await supabase
    .from('login_history')
    .select('*, profiles(full_name, designation, username)')
    .order('logged_in_at', { ascending: false })
    .limit(limit);
  return data || [];
}

FILEEOF_app__main__users_actions_js

mkdir -p "app/(main)/users"
cat > "app/(main)/users/page.js" << 'FILEEOF_app__main__users_page_js'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getUsers, createUser, toggleUserStatus, resetUserPassword, updateUserProfile, updateStaffIdentity, getMyDesignation, getLoginHistory } from './actions';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

// Rough, presentation-only parse -- not meant to be exhaustive, just
// enough for an admin scanning the list to tell "phone" from
// "desktop browser" at a glance without reading a raw UA string.
function parseDevice(ua) {
  if (!ua) return 'Unknown device';
  const browser = /Edg\//.test(ua) ? 'Edge' : /Chrome\//.test(ua) ? 'Chrome' : /Firefox\//.test(ua) ? 'Firefox' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' : /Windows/.test(ua) ? 'Windows' : /Mac OS/.test(ua) ? 'Mac' : /Linux/.test(ua) ? 'Linux' : '';
  return os ? `${browser} on ${os}` : browser;
}

function LoginHistoryTable() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    getLoginHistory().then((data) => { setRows(data); setLoading(false); });
  }, []);

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>;

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-history" style={{ color: 'var(--blue)' }}></i> Login History
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span>
      </div>
      <div style={{ fontSize: 11, color: 'var(--g400)', marginBottom: 10 }}>
        Location is approximate (IP-based) -- a VPN or mobile network will show that network's location, not necessarily the person's actual location.
      </div>
      <table className="tbl">
        <thead><tr><th>Staff</th><th>When</th><th>Location</th><th>IP Address</th><th>Device</th></tr></thead>
        <tbody>
          {rows.map((r) => (
            <tr key={r.id}>
              <td>
                <strong>{r.profiles?.full_name || 'Unknown'}</strong>
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>{r.profiles?.designation}</div>
              </td>
              <td style={{ fontSize: 12 }}>
                {new Date(r.logged_in_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
              </td>
              <td style={{ fontSize: 12 }}>
                {[r.city, r.region, r.country].filter(Boolean).join(', ') || '--'}
              </td>
              <td style={{ fontSize: 12, fontFamily: 'monospace' }}>{r.ip_address || '--'}</td>
              <td style={{ fontSize: 12 }}>{parseDevice(r.user_agent)}</td>
            </tr>
          ))}
          {rows.length === 0 && (
            <tr><td colSpan={5} style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>No logins recorded yet.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

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
  const [tab, setTab] = useState('accounts');

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
    <div>
      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        <button className={tab === 'accounts' ? 'btn btn-primary' : 'btn'} onClick={() => setTab('accounts')}>
          <i className="ti ti-users-group"></i> Staff Accounts
        </button>
        <button className={tab === 'history' ? 'btn btn-primary' : 'btn'} onClick={() => setTab('history')}>
          <i className="ti ti-history"></i> Login History
        </button>
      </div>

      {tab === 'history' && <LoginHistoryTable />}

      {tab === 'accounts' && (
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
          <input className="fi" type="password" placeholder="Temporary password (min 8 chars)" value={form.password} onChange={update('password')} style={{ marginBottom: 8 }} />
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
      )}
    </div>
  );
}

FILEEOF_app__main__users_page_js

mkdir -p "app/login"
cat > "app/login/page.js" << 'FILEEOF_app_login_page_js'
'use client';

import { useState, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';
import { resolveLoginEmail, getMyDesignation, checkLoginAllowed, recordLoginFailure, recordLoginSuccess } from '@/app/(main)/users/actions';

export default function LoginPage() {
  return (
    <Suspense fallback={null}>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const searchParams = useSearchParams();
  const idleLogout = searchParams.get('reason') === 'idle';
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    try {
      let lockCheck = { allowed: true };
      try {
        lockCheck = await checkLoginAllowed(username);
      } catch (err) {
        console.error('checkLoginAllowed failed:', err);
        // Never block login over this check failing -- treat as allowed.
      }
      if (!lockCheck.allowed) {
        setError(lockCheck.error);
        return;
      }

      const resolved = await resolveLoginEmail(username);
      if (resolved.error) {
        setError(resolved.error);
        return;
      }

      const { error: signInError } = await supabase.auth.signInWithPassword({
        email: resolved.email,
        password,
      });

      if (signInError) {
        // Awaited -- a fire-and-forget call here would race against
        // showing the error and risk the request never actually
        // completing if the person immediately tries again.
        await recordLoginFailure(username);
        setError(signInError.message);
        return;
      }

      // Must be awaited: the hard navigation via window.location.href
      // a few lines below causes the browser to cancel any still-
      // in-flight request, including this one if it isn't finished
      // yet. An unawaited call here silently never completed --
      // which is exactly why Login History was staying empty despite
      // real logins happening.
      await recordLoginSuccess(username);

      // Set immediately, not left to the first client-side heartbeat
      // (up to 60s away) -- the middleware idle check runs on the very
      // next page load, and without this, a stale last_active_at from
      // days ago (or null, for a first-ever login) would immediately
      // look "idle" and bounce someone right after they just signed in.
      try {
        const { data: { user } } = await supabase.auth.getUser();
        if (user) await supabase.from('profiles').update({ last_active_at: new Date().toISOString() }).eq('id', user.id);
      } catch {
        // Non-critical -- the client-side heartbeat will catch up shortly.
      }

      // Doctors land on their own dashboard; everyone else (Front
      // Office, Optometry, Billing, Admin, etc.) lands on Front Office
      // Dashboard. Wrapped defensively -- the session cookie
      // signInWithPassword just set can take a beat to propagate to a
      // server action call, so this lookup failing must never block
      // login itself. Falls back to Front Office Dashboard, which is
      // safe to land on for any role.
      let destination = '/front-office-dashboard';
      try {
        const designation = await getMyDesignation();
        if (designation === 'Doctor') destination = '/doctor-dashboard';
      } catch {
        // fall through to the safe default above
      }

      // A hard navigation here (not router.push) is deliberate -- right
      // after signInWithPassword, a client-side route change can outrun
      // the new session cookie actually being recognized by middleware,
      // which was bouncing straight back to /login and needing a second
      // click to actually get in. A full navigation guarantees the
      // browser's next request carries the fresh session correctly.
      window.location.href = destination;
    } catch (err) {
      console.error('Login handleSubmit failed:', err);
      setError('Something went wrong signing in. Please try again.');
    } finally {
      setLoading(false);
    }
  }

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div className="card" style={{ width: 380 }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'var(--blue-dk)' }}>
            VEDA HMIS
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>
            Veda Eye Hospital -- Staff Login
          </div>
        </div>

        {idleLogout && !error && (
          <div className="msg-info" style={{ marginBottom: 12 }}>
            <i className="ti ti-clock"></i> You were signed out after 30 minutes of inactivity.
          </div>
        )}
        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 14 }}>
            <label className="flbl">Username</label>
            <input
              type="text"
              className="fi"
              value={username}
              onChange={(e) => setUsername(e.target.value)}
              required
              autoFocus
            />
          </div>
          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Password</label>
            <input
              type="password"
              className="fi"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          <button
            type="submit"
            className="btn btn-primary"
            style={{ width: '100%' }}
            disabled={loading}
          >
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
          <Link
            href="/forgot-password"
            style={{ fontSize: 12, color: 'var(--g500)', display: 'block', textAlign: 'center', marginTop: 12 }}
          >
            Forgot password?
          </Link>
        </form>
      </div>
    </div>
  );
}

FILEEOF_app_login_page_js

mkdir -p "app/dashboard"
cat > "app/dashboard/page.js" << 'FILEEOF_app_dashboard_page_js'
import { redirect } from 'next/navigation';
import { getMyDesignation } from '@/app/(main)/users/actions';

// Not a route this app normally links to -- exists purely because
// something (a stale bookmark, an old cached client-side router
// state from before this app's routing was finalized, etc.) keeps
// reaching for /dashboard specifically and 404ing here. Cheaper and
// safer to just make it work than to fully track down the exact
// client-side mechanism sending it here.
export default async function DashboardRedirect() {
  const designation = await getMyDesignation();
  redirect(designation === 'Doctor' ? '/doctor-dashboard' : '/front-office-dashboard');
}
FILEEOF_app_dashboard_page_js


echo "Files written."

git add -A
git commit -m "Re-deploy login lockout + Login History (Administrator only) + dashboard safety-net redirect, after emergency rollback reverted the code"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
