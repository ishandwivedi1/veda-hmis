import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;

  const supabase = await createClient();
  const { data: visits, error } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('status', 'Open')
    .order('created_at', { ascending: false });

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
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>Open Visits</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Patients currently in the hospital, visit not yet closed.
            </div>
          </div>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
        </div>

        {justCreated && (
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
            Visit created successfully.
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>Patient</th>
              <th style={{ padding: '8px 6px' }}>UHID</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Type</th>
              <th style={{ padding: '8px 6px' }}>Doctor</th>
              <th style={{ padding: '8px 6px' }}>Since</th>
            </tr>
          </thead>
          <tbody>
            {(visits || []).map((v) => (
              <tr key={v.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '8px 6px' }}>
                  {v.patients?.first_name} {v.patients?.last_name}
                </td>
                <td style={{ padding: '8px 6px', fontFamily: 'monospace' }}>{v.patients?.uhid}</td>
                <td style={{ padding: '8px 6px' }}>{v.patients?.mobile}</td>
                <td style={{ padding: '8px 6px' }}>{v.visit_type}</td>
                <td style={{ padding: '8px 6px' }}>{v.profiles?.full_name || '--'}</td>
                <td style={{ padding: '8px 6px', color: 'var(--g500)' }}>
                  {new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}
                </td>
              </tr>
            ))}
            {(!visits || visits.length === 0) && (
              <tr>
                <td colSpan={6} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  No open visits right now.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

