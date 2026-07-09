'use client';

import { useState } from 'react';
import Link from 'next/link';
import { createClient } from '../../lib/supabase-browser';

export default function ForgotPasswordPage() {
  const [email, setEmail] = useState('');
  const [error, setError] = useState('');
  const [sent, setSent] = useState(false);
  const [loading, setLoading] = useState(false);
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const { error: resetError } = await supabase.auth.resetPasswordForEmail(email, {
      redirectTo: `${window.location.origin}/reset-password`,
    });

    setLoading(false);

    // Deliberately show the same success message whether or not the email
    // exists in the system -- confirming/denying an email's existence to
    // an unauthenticated visitor is an information leak worth avoiding.
    if (resetError) {
      setError(resetError.message);
      return;
    }
    setSent(true);
  }

  return (
    <div style={{ minHeight: '100vh', display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
      <div className="card" style={{ width: 380 }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'var(--blue-dk)' }}>VEDA HMIS</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>Reset your password</div>
        </div>

        {sent ? (
          <div>
            <div className="msg-success">
              <i className="ti ti-mail"></i> If an account exists for that email, a reset link has been sent. Check your inbox.
            </div>
            <Link href="/login" className="btn" style={{ width: '100%', textDecoration: 'none', justifyContent: 'center' }}>
              Back to login
            </Link>
          </div>
        ) : (
          <form onSubmit={handleSubmit}>
            {error && <div className="msg-err">{error}</div>}
            <div style={{ marginBottom: 20 }}>
              <label className="flbl">Email</label>
              <input
                type="email"
                className="fi"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
                autoFocus
              />
            </div>
            <button type="submit" className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} disabled={loading}>
              {loading ? 'Sending...' : 'Send Reset Link'}
            </button>
            <Link href="/login" style={{ fontSize: 12, color: 'var(--g500)', display: 'block', textAlign: 'center' }}>
              Back to login
            </Link>
          </form>
        )}
      </div>
    </div>
  );
}

