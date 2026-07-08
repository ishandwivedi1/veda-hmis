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
      </head>
      <body>{children}</body>
    </html>
  );
}

