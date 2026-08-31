'use client';

// Last-resort catch-all: only fires if the crash happens in the root
// layout itself (very rare -- app/(main)/error.js catches everything
// under the main app shell already). Next.js requires this file to
// render its own <html>/<body> since it replaces the root layout
// entirely when it fires. Kept plain/inline-styled on purpose --
// globals.css may not be safely available if the root layout is what
// broke.
export default function GlobalError({ error, reset }) {
  return (
    <html lang="en">
      <body style={{ fontFamily: 'system-ui, sans-serif', display: 'flex', alignItems: 'center', justifyContent: 'center', minHeight: '100vh', margin: 0, background: '#f7f7f8' }}>
        <div style={{ maxWidth: 420, textAlign: 'center', padding: 32, background: '#fff', borderRadius: 12, boxShadow: '0 1px 4px rgba(0,0,0,.08)' }}>
          <div style={{ fontSize: 16, fontWeight: 700, marginBottom: 6, color: '#b3261e' }}>Something went wrong</div>
          <div style={{ fontSize: 13, color: '#6b7280', marginBottom: 20, lineHeight: 1.5 }}>
            The app hit an unexpected error while loading. Try again first -- if it persists, please let the office know.
          </div>
          <div style={{ display: 'flex', gap: 10, justifyContent: 'center' }}>
            <button
              onClick={() => reset()}
              style={{ padding: '9px 16px', borderRadius: 8, border: 'none', background: '#1e4e8c', color: '#fff', fontWeight: 600, cursor: 'pointer' }}
            >
              Try Again
            </button>
            <a
              href="/"
              style={{ padding: '9px 16px', borderRadius: 8, border: '1px solid #d1d5db', color: '#111827', fontWeight: 600, textDecoration: 'none' }}
            >
              Go to Dashboard
            </a>
          </div>
        </div>
      </body>
    </html>
  );
}
