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

