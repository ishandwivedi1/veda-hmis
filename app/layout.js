import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
};

// Without this, phones render the page at a virtual desktop width
// (~980px) and shrink the whole thing to fit -- every phone visitor
// was seeing tiny, pinch-to-zoom-required text and a layout that
// never actually triggered the app's own mobile CSS, since the
// browser never reported a narrow enough width for those rules to
// match in the first place.
export const viewport = {
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <head>
        <link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/@tabler/icons-webfont@3.5.0/dist/tabler-icons.min.css" />
        {/* Sora carries the brand voice (sidebar, headings, titles) --
            a geometric grotesque with a bit of warmth, used sparingly.
            Inter handles everything dense (tables, forms, badges)
            since this UI runs at 11-14px constantly. Loaded via link
            tag (not next/font) so it doesn't depend on build-time
            network access -- same pattern as the Tabler icons above. */}
        <link rel="preconnect" href="https://fonts.googleapis.com" />
        <link rel="preconnect" href="https://fonts.gstatic.com" crossOrigin="anonymous" />
        <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=Sora:wght@600;700;800&display=swap" />
      </head>
      <body>{children}</body>
    </html>
  );
}

