'use client';

import { useEffect } from 'react';

// Catches any unexpected crash in a page under the main app layout and
// shows a recoverable screen instead of leaving staff on a dead one.
// Without this file, Next.js has nothing to catch a render-time error
// with -- the page just stops responding and the only way out is
// closing and reopening the app. The sidebar/nav (rendered by
// app/(main)/layout.js, one level up) stays up regardless, since a
// segment's error.js only replaces that segment's content, not its
// own parent layout -- so there's always a way out even if "Try
// Again" doesn't fix it.
export default function MainError({ error, reset }) {
  useEffect(() => {
    // eslint-disable-next-line no-console
    console.error('Unhandled error caught by app/(main)/error.js:', error);
  }, [error]);

  return (
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '70vh', padding: 20 }}>
      <div className="card" style={{ maxWidth: 440, textAlign: 'center', padding: 32 }}>
        <div style={{ fontSize: 34, color: 'var(--red)', marginBottom: 10 }}>
          <i className="ti ti-alert-triangle"></i>
        </div>
        <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 6 }}>Something went wrong</div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 22, lineHeight: 1.5 }}>
          This page hit an unexpected error. It's usually a one-off -- try again first.
          If it keeps happening, please let the office know what you were doing when it occurred.
        </div>
        <div style={{ display: 'flex', gap: 10, justifyContent: 'center' }}>
          <button className="btn btn-primary" onClick={() => reset()}>
            <i className="ti ti-refresh"></i> Try Again
          </button>
          <a className="btn" href="/">
            <i className="ti ti-home"></i> Go to Dashboard
          </a>
        </div>
      </div>
    </div>
  );
}
