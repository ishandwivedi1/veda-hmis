mkdir -p app/login app/dashboard app/patients/new lib

cat > package.json << 'EOF'
{
  "name": "veda-hmis",
  "version": "0.1.0",
  "private": true,
  "scripts": {
    "dev": "next dev",
    "build": "next build",
    "start": "next start"
  },
  "dependencies": {
    "next": "^16.2.10",
    "react": "^18.3.1",
    "react-dom": "^18.3.1",
    "@supabase/supabase-js": "^2.45.0",
    "@supabase/ssr": "^0.4.0"
  }
}

EOF

cat > next.config.js << 'EOF'
/** @type {import('next').NextConfig} */
const nextConfig = {
  experimental: {
    serverActions: {
      // GitHub Codespaces forwards your port through a proxy URL like
      // https://<name>-3000.app.github.dev -- Next.js's Server Actions
      // check the request's origin against the server's host, and this
      // wildcard tells it to trust Codespaces' forwarding domains.
      allowedOrigins: ['*.app.github.dev', '*.github.dev', 'localhost:3000'],
    },
  },
};

module.exports = nextConfig;

EOF

cat > .gitignore << 'EOF'
node_modules/
.next/
.vercel
*.log

EOF

cat > .env.local << 'EOF'
NEXT_PUBLIC_SUPABASE_URL=https://zcayavskkbcvkhjdjknu.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InpjYXlhdnNra2JjdmtoamRqa251Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODMzNTIzMDIsImV4cCI6MjA5ODkyODMwMn0.aySQw6GvOqHbnffETF0HhFDMvJmg9EyVRSy19ACqD2Y

EOF

cat > middleware.js << 'EOF'
import { createServerClient } from '@supabase/ssr';
import { NextResponse } from 'next/server';

export async function middleware(request) {
  let response = NextResponse.next({
    request: { headers: request.headers },
  });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        get(name) {
          return request.cookies.get(name)?.value;
        },
        set(name, value, options) {
          response.cookies.set({ name, value, ...options });
        },
        remove(name, options) {
          response.cookies.set({ name, value: '', ...options });
        },
      },
    }
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isLoginPage = request.nextUrl.pathname.startsWith('/login');

  // Not logged in and trying to reach a protected page -> send to login
  if (!user && !isLoginPage) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  // Already logged in and looking at the login page -> send to dashboard
  if (user && isLoginPage) {
    return NextResponse.redirect(new URL('/dashboard', request.url));
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};

EOF

cat > lib/supabase-browser.js << 'EOF'
import { createBrowserClient } from '@supabase/ssr';

export function createClient() {
  return createBrowserClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY
  );
}

EOF

cat > lib/supabase-server.js << 'EOF'
import { createServerClient } from '@supabase/ssr';
import { cookies } from 'next/headers';

export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        get(name) {
          return cookieStore.get(name)?.value;
        },
        set(name, value, options) {
          try {
            cookieStore.set({ name, value, ...options });
          } catch (error) {
            // Called from a Server Component -- safe to ignore because
            // middleware.js refreshes the session on every request.
          }
        },
        remove(name, options) {
          try {
            cookieStore.set({ name, value: '', ...options });
          } catch (error) {
            // Same as above -- safe to ignore.
          }
        },
      },
    }
  );
}

EOF

cat > app/layout.js << 'EOF'
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

EOF

cat > app/globals.css << 'EOF'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --blue: #1d4ed8;
  --blue-lt: #dbeafe;
  --blue-dk: #1e3a8a;
  --green: #15803d;
  --green-lt: #dcfce7;
  --red: #b91c1c;
  --red-lt: #fee2e2;
  --g50: #f9fafb;
  --g100: #f3f4f6;
  --g200: #e5e7eb;
  --g400: #9ca3af;
  --g500: #6b7280;
  --g600: #4b5563;
  --g800: #1f2937;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
}

.card {
  background: #fff;
  border: 1px solid var(--g200);
  border-radius: 12px;
  padding: 24px;
}

.btn {
  padding: 10px 16px;
  border-radius: 8px;
  font-size: 14px;
  font-weight: 600;
  cursor: pointer;
  border: 1px solid var(--g200);
  background: #fff;
  color: var(--g600);
  font-family: inherit;
}

.btn-primary {
  background: var(--blue);
  color: #fff;
  border-color: transparent;
}

.btn-primary:hover {
  background: var(--blue-dk);
}

.btn:disabled {
  opacity: 0.5;
  cursor: not-allowed;
}

.fi {
  width: 100%;
  padding: 10px 12px;
  border: 1.5px solid var(--g200);
  border-radius: 8px;
  font-size: 14px;
  font-family: inherit;
}

.fi:focus {
  outline: none;
  border-color: var(--blue);
}

.flbl {
  font-size: 12px;
  font-weight: 600;
  color: var(--g600);
  display: block;
  margin-bottom: 4px;
}

.msg-err {
  background: var(--red-lt);
  color: var(--red);
  padding: 10px 12px;
  border-radius: 8px;
  font-size: 13px;
  margin-bottom: 12px;
}

EOF

cat > app/page.js << 'EOF'
import { redirect } from 'next/navigation';

export default function Home() {
  redirect('/dashboard');
}

EOF

cat > app/login/page.js << 'EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { createClient } from '../../lib/supabase-browser';

export default function LoginPage() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();
  const supabase = createClient();

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const { error: signInError } = await supabase.auth.signInWithPassword({
      email,
      password,
    });

    setLoading(false);

    if (signInError) {
      setError(signInError.message);
      return;
    }

    router.push('/dashboard');
    router.refresh();
  }

  return (
    <div
      style={{
        minHeight: '100vh',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div className="card" style={{ width: 380 }}>
        <div style={{ textAlign: 'center', marginBottom: 24 }}>
          <div style={{ fontSize: 22, fontWeight: 800, color: 'var(--blue-dk)' }}>
            VEDA HMIS
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 2 }}>
            Veda Eye Hospital -- Staff Login
          </div>
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 14 }}>
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
          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Password</label>
            <input
              type="password"
              className="fi"
              value={password}
              onChange={(e) => setPassword(e.target.value)}
              required
            />
          </div>
          <button
            type="submit"
            className="btn btn-primary"
            style={{ width: '100%' }}
            disabled={loading}
          >
            {loading ? 'Signing in...' : 'Sign In'}
          </button>
        </form>
      </div>
    </div>
  );
}

EOF

cat > app/dashboard/sign-out-button.js << 'EOF'
'use client';

import { useRouter } from 'next/navigation';
import { createClient } from '../../lib/supabase-browser';

export default function SignOutButton() {
  const router = useRouter();
  const supabase = createClient();

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  return (
    <button className="btn" onClick={handleSignOut}>
      Sign out
    </button>
  );
}

EOF

cat > app/dashboard/page.js << 'EOF'
import { createClient } from '../../lib/supabase-server';
import SignOutButton from './sign-out-button';
import Link from 'next/link';

export default async function DashboardPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();

  return (
    <div style={{ maxWidth: 640, margin: '60px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA HMIS</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Real login, real database -- Phase 1 proof of concept
            </div>
          </div>
          <SignOutButton />
        </div>

        <div
          style={{
            background: 'var(--green-lt)',
            color: 'var(--green)',
            padding: '10px 14px',
            borderRadius: 8,
            fontSize: 13,
            marginBottom: 20,
          }}
        >
          You are genuinely logged in via Supabase Auth, and this page just
          read your staff profile from the real <code>profiles</code> table.
        </div>

        <div style={{ fontSize: 13, lineHeight: 1.8 }}>
          <div>
            <strong>Name:</strong> {profile?.full_name || '(not set yet)'}
          </div>
          <div>
            <strong>Designation:</strong> {profile?.designation || '(not set yet)'}
          </div>
          <div>
            <strong>Department:</strong> {profile?.department || '(not set yet)'}
          </div>
          <div>
            <strong>Status:</strong> {profile?.status}
          </div>
          <div>
            <strong>Email:</strong> {user.email}
          </div>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 20, paddingTop: 20, borderTop: '1px solid var(--g200)' }}>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
          </Link>
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            View All Patients
          </Link>
        </div>
      </div>
    </div>
  );
}

EOF

cat > app/patients/actions.js << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function registerPatient(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('register_patient', {
    p_first_name: values.firstName,
    p_last_name: values.lastName,
    p_age: values.age ? parseInt(values.age, 10) : null,
    p_gender: values.gender,
    p_mobile: values.mobile,
    p_address: values.address || null,
    p_blood_group: values.bloodGroup || null,
  });

  if (error) {
    return { error: error.message };
  }

  return { patient: data };
}

EOF

cat > app/patients/new/page.js << 'EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { registerPatient } from '../actions';

export default function NewPatientPage() {
  const [values, setValues] = useState({
    firstName: '',
    lastName: '',
    age: '',
    gender: '',
    mobile: '',
    address: '',
    bloodGroup: '',
  });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  function update(field) {
    return (e) => setValues((v) => ({ ...v, [field]: e.target.value }));
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!values.firstName || !values.lastName || !values.gender || !values.mobile) {
      setError('First name, last name, gender, and mobile are required.');
      return;
    }
    if (values.mobile.length !== 10) {
      setError('Mobile number must be 10 digits.');
      return;
    }

    setLoading(true);
    const result = await registerPatient(values);
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push(`/patients?registered=${result.patient.uhid}`);
  }

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          Register New Patient
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          UHID is generated automatically on save.
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">First name *</label>
              <input className="fi" value={values.firstName} onChange={update('firstName')} required />
            </div>
            <div>
              <label className="flbl">Last name *</label>
              <input className="fi" value={values.lastName} onChange={update('lastName')} required />
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Age</label>
              <input type="number" className="fi" value={values.age} onChange={update('age')} />
            </div>
            <div>
              <label className="flbl">Gender *</label>
              <select className="fi" value={values.gender} onChange={update('gender')} required>
                <option value="">-- Select --</option>
                <option value="M">Male</option>
                <option value="F">Female</option>
                <option value="O">Other</option>
              </select>
            </div>
          </div>

          <div style={{ marginBottom: 12 }}>
            <label className="flbl">Mobile *</label>
            <input className="fi" value={values.mobile} onChange={update('mobile')} maxLength={10} required />
          </div>

          <div style={{ marginBottom: 12 }}>
            <label className="flbl">Address</label>
            <input className="fi" value={values.address} onChange={update('address')} />
          </div>

          <div style={{ marginBottom: 20 }}>
            <label className="flbl">Blood group</label>
            <select className="fi" value={values.bloodGroup} onChange={update('bloodGroup')}>
              <option value="">-- Unknown --</option>
              <option>A+</option><option>A-</option>
              <option>B+</option><option>B-</option>
              <option>AB+</option><option>AB-</option>
              <option>O+</option><option>O-</option>
            </select>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Registering...' : 'Register Patient'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/dashboard')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

EOF

cat > app/patients/page.js << 'EOF'
import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';

export default async function PatientsPage({ searchParams }) {
  const params = await searchParams;
  const justRegistered = params?.registered;
  const q = params?.q || '';

  const supabase = await createClient();
  let query = supabase.from('patients').select('*').order('created_at', { ascending: false });

  if (q) {
    query = query.or(
      `uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`
    );
  }

  const { data: patients, error } = await query;

  return (
    <div style={{ maxWidth: 900, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div style={{ fontSize: 18, fontWeight: 700 }}>Patients</div>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
          </Link>
        </div>

        <form method="GET" action="/patients" style={{ display: 'flex', gap: 8, marginBottom: 16 }}>
          <input
            type="text"
            name="q"
            defaultValue={q}
            placeholder="Search by name, UHID, or mobile..."
            className="fi"
            style={{ flex: 1 }}
          />
          <button type="submit" className="btn btn-primary">
            Search
          </button>
          {q && (
            <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
              Clear
            </Link>
          )}
        </form>

        {justRegistered && (
          <div
            style={{
              background: 'var(--green-lt)',
              color: 'var(--green)',
              padding: '10px 14px',
              borderRadius: 8,
              fontSize: 13,
              marginBottom: 16,
            }}
          >
            Registered successfully -- UHID: <strong>{justRegistered}</strong>
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>UHID</th>
              <th style={{ padding: '8px 6px' }}>Name</th>
              <th style={{ padding: '8px 6px' }}>Age / Gender</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Blood Group</th>
              <th style={{ padding: '8px 6px' }}>Registered</th>
            </tr>
          </thead>
          <tbody>
            {(patients || []).map((p) => (
              <tr key={p.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '8px 6px', fontFamily: 'monospace' }}>{p.uhid}</td>
                <td style={{ padding: '8px 6px' }}>
                  {p.first_name} {p.last_name}
                </td>
                <td style={{ padding: '8px 6px' }}>
                  {p.age || '--'} {p.gender}
                </td>
                <td style={{ padding: '8px 6px' }}>{p.mobile}</td>
                <td style={{ padding: '8px 6px' }}>{p.blood_group || '--'}</td>
                <td style={{ padding: '8px 6px', color: 'var(--g500)' }}>
                  {new Date(p.created_at).toLocaleDateString('en-IN')}
                </td>
              </tr>
            ))}
            {(!patients || patients.length === 0) && (
              <tr>
                <td colSpan={6} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

echo "ALL FILES RECREATED SUCCESSFULLY."
