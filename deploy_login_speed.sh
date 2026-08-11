#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# Performance fix only -- no DB or key changes needed.

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

// Combines checkLoginAllowed + resolveLoginEmail into a single round
// trip -- the login page used to call these as two separate server
// actions back to back, each a full client-server round trip, when
// they're both just profile lookups on the same username and can
// share one request instead. Cuts real, felt latency off every login.
export async function precheckLogin(usernameOrEmail) {
  const trimmed = (usernameOrEmail || '').trim();
  if (!trimmed) return { error: 'Enter your username.' };

  const admin = createAdminClient();
  const { data } = await admin.from('profiles').select('id, locked_until').ilike('username', trimmed).maybeSingle();
  if (!data) return { error: 'Invalid username or password.' };

  if (data.locked_until) {
    const remainingMs = new Date(data.locked_until).getTime() - Date.now();
    if (remainingMs > 0) {
      const minutes = Math.max(1, Math.ceil(remainingMs / 60000));
      return { error: `Too many failed attempts. Try again in ${minutes} minute${minutes === 1 ? '' : 's'}.` };
    }
  }

  const { data: authUser } = await admin.auth.admin.getUserById(data.id);
  if (!authUser?.user?.email) return { error: 'Invalid username or password.' };

  return { email: authUser.user.email };
}

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

mkdir -p "app/login"
cat > "app/login/page.js" << 'FILEEOF_app_login_page_js'
'use client';

import { useState, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';
import { precheckLogin, getMyDesignation, recordLoginFailure, recordLoginSuccess } from '@/app/(main)/users/actions';

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
      // One round trip instead of two -- lockout check and email
      // resolution are both just profile lookups on the same
      // username, no reason to make them separate requests.
      const resolved = await precheckLogin(username);
      if (resolved.error) {
        setError(resolved.error);
        return;
      }

      const { data: signInData, error: signInError } = await supabase.auth.signInWithPassword({
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

      // signInWithPassword already returns the user object -- no need
      // for a separate getUser() call just to fetch the same id again.
      const user = signInData?.user;

      // These three don't depend on each other's results, so they run
      // concurrently instead of one-after-another -- the previous
      // sequential version was the main reason login felt slow.
      // recordLoginSuccess still MUST be awaited here (as part of this
      // group) since the hard navigation below cancels anything still
      // in flight -- an unawaited call was exactly why Login History
      // stayed empty despite real logins happening. Each is wrapped
      // defensively; none of them should be able to block getting in.
      const [, , designationOutcome] = await Promise.allSettled([
        recordLoginSuccess(username),
        // Set immediately, not left to the first client-side heartbeat
        // (up to 60s away) -- the middleware idle check runs on the
        // very next page load, and without this, a stale
        // last_active_at from days ago (or null, for a first-ever
        // login) would immediately look "idle" and bounce someone
        // right after they just signed in.
        user ? supabase.from('profiles').update({ last_active_at: new Date().toISOString() }).eq('id', user.id) : Promise.resolve(),
        // Doctors land on their own dashboard; everyone else (Front
        // Office, Optometry, Billing, Admin, etc.) lands on Front
        // Office Dashboard.
        getMyDesignation(),
      ]);

      let destination = '/front-office-dashboard';
      if (designationOutcome.status === 'fulfilled' && designationOutcome.value === 'Doctor') {
        destination = '/doctor-dashboard';
      }
      // A failed designation lookup falls through to the safe default
      // above -- the session cookie signInWithPassword just set can
      // take a beat to propagate to a server action call, so this
      // must never block login itself.

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


echo "Files written."

git add -A
git commit -m "Speed up login: combine lockout+email-resolve into one round trip, drop redundant getUser() call, parallelize the three independent post-login operations"
git push

echo "Pushed. Vercel will redeploy automatically."
