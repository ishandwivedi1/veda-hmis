'use client';

export default function PrintButton() {
  return (
    <button
      onClick={() => window.print()}
      style={{
        padding: '9px 16px',
        borderRadius: 8,
        fontSize: 13,
        fontWeight: 600,
        cursor: 'pointer',
        border: 'none',
        background: '#0f766e',
        color: '#fff',
      }}
    >
      Print / Save as PDF
    </button>
  );
}
