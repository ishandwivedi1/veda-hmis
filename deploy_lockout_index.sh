#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# The DB changes (index + lockout columns) are ALREADY LIVE on both
# production and training -- applied and functionally verified
# directly. This just pushes the application code and saves the
# migration file into git history.

cd ~/veda-hmis 2>/dev/null || true

mkdir -p "supabase/migrations"
cat > "supabase/migrations/032_index_and_lockout.sql" << 'FILEEOF_supabase_migrations_032_index_and_lockout_sql'
-- Speed: visits.created_at had no index despite being filtered by
-- date range on nearly every dashboard (Patient Flow polls this every
-- 15s, plus Pharmacy Dashboard, Cash Management, Daily Report). Not
-- yet visible at current data volume, but a sequential scan on every
-- one of those reads only gets worse as visit history grows.
CREATE INDEX IF NOT EXISTS "idx_visits_created_at" ON "public"."visits" USING "btree" ("created_at");

-- Safety: brute-force login lockout. profiles.status already had a
-- 'Locked' value in its CHECK constraint but nothing in the app ever
-- set it -- there was no limit on password guesses at all. Tracked
-- separately from `status` (which stays for deliberate Active/
-- Inactive account management) so a temporary auto-lockout can expire
-- on its own without an admin needing to manually reactivate someone
-- who just mistyped their password five times.
ALTER TABLE "public"."profiles" ADD COLUMN IF NOT EXISTS "failed_login_attempts" integer NOT NULL DEFAULT 0;
ALTER TABLE "public"."profiles" ADD COLUMN IF NOT EXISTS "locked_until" timestamp with time zone;
FILEEOF_supabase_migrations_032_index_and_lockout_sql

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
}

export async function recordLoginSuccess(usernameOrEmail) {
  const trimmed = (usernameOrEmail || '').trim();
  if (!trimmed) return;

  const admin = createAdminClient();
  await admin.from('profiles').update({ failed_login_attempts: 0, locked_until: null }).ilike('username', trimmed);
}

FILEEOF_app__main__users_actions_js

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
      const lockCheck = await checkLoginAllowed(username);
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
        // Fire-and-forget -- must never block showing the error itself,
        // and the person doesn't need to wait on this write to see
        // "invalid credentials" the same way they always have.
        recordLoginFailure(username);
        setError(signInError.message);
        return;
      }

      recordLoginSuccess(username);

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
    } catch {
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


echo "Files written."

git add -A
git commit -m "Add login lockout (5 failed attempts = 15min lockout), bump min password to 8 chars, add visits.created_at index"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
