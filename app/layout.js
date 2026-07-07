import './globals.css';

export const metadata = {
  title: 'VEDA HMIS',
  description: 'Veda Eye Hospital -- Hospital Management System',
};

export default function RootLayout({ children }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}

