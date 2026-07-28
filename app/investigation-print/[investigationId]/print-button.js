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
        background: '#1d4ed8',
        color: '#fff',
      }}
    >
      Print / Save as PDF
    </button>
  );
}
