import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
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

