#!/bin/bash
set -e
echo "Applying: fix login screen hanging after sign-in"

cat > "app/login/page.js" << 'PYEOF_3819109008534159820'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';
import { resolveLoginEmail, getMyDesignation } from '@/app/(main)/users/actions';

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

    try {
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
        setError(signInError.message);
        return;
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

      router.push(destination);
      router.refresh();
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

PYEOF_3819109008534159820

cat > "app/reset-password/page.js" << 'PYEOF_1855338735378447170'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '../../lib/supabase-browser';
import { getMyDesignation } from '@/app/(main)/users/actions';

export default function ResetPasswordPage() {
  const [password, setPassword] = useState('');
  const [confirmPassword, setConfirmPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (password.length < 6) {
      setError('Password must be at least 6 characters.');
      return;
    }
    if (password !== confirmPassword) {
      setError('Passwords do not match.');
      return;
    }

    setLoading(true);
    const { error: updateError } = await supabase.auth.updateUser({ password });
    setLoading(false);

    if (updateError) {
      setError(updateError.message);
      return;
    }

    let destination = '/front-office-dashboard';
    try {
      if (await getMyDesignation() === 'Doctor') destination = '/doctor-dashboard';
    } catch {
      // fall through to the safe default above
    }
    router.push(destination);
    router.refresh();
  }

  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div className="card" style={{ width: 380 }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'var(--blue-dk)' }}>VEDA HMIS</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Set a new password</div>
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 14 }}>
            <label className="flbl">New Password</label>
            <input
              type="password"
              className="fi"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
              autoFocus
            />
          </div>
          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Confirm New Password</label>
            <input
              type="password"
              className="fi"
              value={confirmPassword}
              onChange={(e) => setConfirmPassword(e.target.value)}
              required
            />
          </div>
          <button type="submit" className="btn btn-primary" style={{ width: '100%' }} disabled={loading}>
            {loading ? 'Saving...' : 'Set New Password'}
          </button>
        </form>
      </div>
    </div>
  );
}

PYEOF_1855338735378447170

echo "Files written. Run: npm run build"
