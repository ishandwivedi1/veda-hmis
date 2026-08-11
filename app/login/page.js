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

