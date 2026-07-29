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

    // Doctors land on their own dashboard; everyone else (Front Office,
    // Optometry, Billing, Admin, etc.) lands on Front Office Dashboard,
    // which is the natural shared starting point for non-clinical roles.
    const designation = await getMyDesignation();
    router.push(designation === 'Doctor' ? '/doctor-dashboard' : '/front-office-dashboard');
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

