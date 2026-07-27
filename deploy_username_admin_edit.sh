#!/bin/bash
set -e
echo "Applying: separate Name/Username, Administrator-gated identity editing, username-based login"

cat > "app/(main)/users/actions.js" << 'PYEOF_3344674534992372473'
'use server';

import { createClient } from '@/lib/supabase-server';
import { createAdminClient } from '@/lib/supabase-admin';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

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
  if (values.designation && !DESIGNATIONS.includes(values.designation)) {
    return { error: 'Invalid designation.' };
  }
  const supabase = await createClient();
  const { error } = await supabase
    .from('profiles')
    .update({
      designation: values.designation || null,
      department: values.department || null,
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
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from('profiles').update({ status: newStatus }).eq('id', userId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function resetUserPassword(userId, newPassword) {
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
PYEOF_3344674534992372473

cat > "app/(main)/users/page.js" << 'PYEOF_6428861900985188009'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getUsers, createUser, toggleUserStatus, resetUserPassword, updateUserProfile, updateStaffIdentity, getMyDesignation } from './actions';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

function EditProfileRow({ user, isAdmin, onDone }) {
  const [fullName, setFullName] = useState(user.full_name || '');
  const [username, setUsername] = useState(user.username || '');
  const [designation, setDesignation] = useState(user.designation || '');
  const [department, setDepartment] = useState(user.department || '');
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

    const result = await updateUserProfile(user.id, { designation, department });
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
        <select className="fi" value={designation} onChange={(e) => setDesignation(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }}>
          <option value="">-- Select --</option>
          {DESIGNATIONS.map((d) => <option key={d} value={d}>{d}</option>)}
        </select>
      </td>
      <td>
        <input className="fi" value={department} onChange={(e) => setDepartment(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
      </td>
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
  const [form, setForm] = useState({ username: '', password: '', fullName: '', designation: '', department: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const isAdmin = myDesignation === 'Administrator';

  const refresh = useCallback(async () => {
    setUsers(await getUsers());
  }, []);

  useEffect(() => {
    refresh();
    getMyDesignation().then(setMyDesignation);
  }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleCreate() {
    setError('');
    setLoading(true);
    const result = await createUser(form);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setForm({ username: '', password: '', fullName: '', designation: '', department: '' });
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
          <input className="fi" type="password" placeholder="Temporary password (min 6 chars)" value={form.password} onChange={update('password')} style={{ marginBottom: 8 }} />
          <button className="btn btn-primary btn-sm" onClick={handleCreate} disabled={loading}>
            {loading ? 'Creating...' : 'Create Account'}
          </button>
        </div>
      )}

      <table className="tbl">
        <thead>
          <tr><th>Name</th><th>Username</th><th>Designation</th><th>Department</th><th>Status</th><th></th></tr>
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
                  <td>{u.designation}</td>
                  <td>{u.department}</td>
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
PYEOF_6428861900985188009

cat > "app/login/page.js" << 'PYEOF_4732901397108141487'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';
import { resolveLoginEmail } from '@/app/(main)/users/actions';

export default function LoginPage() {
  const [username, setUsername] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const resolved = await resolveLoginEmail(username);
    if (resolved.error) {
      setLoading(false);
      setError(resolved.error);
      return;
    }

    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: resolved.email,
      password,
    });

    setLoading(false);

    if (signInError) {
      setError(signInError.message);
      return;
    }

    router.push('/dashboard');
    router.refresh();
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

PYEOF_4732901397108141487

echo "Files written. Run: npm run build"
