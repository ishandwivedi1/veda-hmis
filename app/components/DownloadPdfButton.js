'use client';

// Uses the browser's own Print dialog (Save as PDF) rather than a
// server-rendered PDF -- instant, no serverless/Chromium cost, and the
// app chrome (sidebar/topbar) is already hidden globally in print via
// globals.css, so this works cleanly on any page that drops it in.
export default function DownloadPdfButton({ label = 'Download PDF' }) {
  return (
    <button className="btn no-print" onClick={() => window.print()}>
      <i className="ti ti-printer"></i> {label}
    </button>
  );
}
