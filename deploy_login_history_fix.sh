#!/bin/bash
set -e

# Run this from your veda-hmis repo root in Codespaces.
# Bug fix only -- no DB changes needed.

cd ~/veda-hmis 2>/dev/null || true

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


echo "File written."

git add -A
git commit -m "Fix login history race condition: await recordLoginSuccess/Failure before the hard navigation cancels the in-flight request"
git push

echo "Pushed. Vercel will redeploy portal.vedaeyehospital.com and training.vedaeyehospital.com automatically."
