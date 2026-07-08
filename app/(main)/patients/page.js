import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

const GENDER_BADGE = { M: 'b-blue', F: 'b-purple', O: 'b-gray' };
const GENDER_LABEL = { M: 'Male', F: 'Female', O: 'Other' };

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
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-users" style={{ color: 'var(--blue)' }}></i> Patients
          <span className="badge b-gray">{patients?.length ?? 0}</span>
        </div>
        <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Register New Patient
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
        <button type="submit" className="btn btn-primary"><i className="ti ti-search"></i> Search</button>
        {q && (
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            Clear
          </Link>
        )}
      </form>

      {justRegistered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{justRegistered}</strong>
        </div>
      )}

      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>UHID</th>
            <th>Name</th>
            <th>Age</th>
            <th>Gender</th>
            <th>Mobile</th>
            <th>Blood Group</th>
            <th>Registered</th>
          </tr>
        </thead>
        <tbody>
          {(patients || []).map((p) => (
            <tr key={p.id}>
              <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
              <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
              <td>{p.age || '--'}</td>
              <td><span className={`badge ${GENDER_BADGE[p.gender] || 'b-gray'}`}>{GENDER_LABEL[p.gender] || p.gender}</span></td>
              <td>{p.mobile}</td>
              <td>{p.blood_group ? <span className="badge b-red">{p.blood_group}</span> : '--'}</td>
              <td style={{ color: 'var(--g500)' }}>{new Date(p.created_at).toLocaleDateString('en-IN')}</td>
            </tr>
          ))}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

