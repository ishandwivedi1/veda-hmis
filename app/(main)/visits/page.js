import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

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
    <div className="card">
      <div className="card-head">
        <div>
          <div className="card-title"><i className="ti ti-door-enter" style={{ color: 'var(--green)' }}></i> Open Visits <span className="badge b-gray">{visits?.length ?? 0}</span></div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>Patients currently in the hospital, visit not yet closed.</div>
        </div>
        <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Walk-in Visit
        </Link>
      </div>

      {justCreated && <div className="msg-success"><i className="ti ti-circle-check"></i> Visit created successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Patient</th>
            <th>UHID</th>
            <th>Mobile</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Since</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(visits || []).map((v) => (
            <tr key={v.id}>
              <td style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</td>
              <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{v.patients?.uhid}</td>
              <td>{v.patients?.mobile}</td>
              <td><span className="badge b-blue">{v.visit_type}</span></td>
              <td>{v.profiles?.full_name || '--'}</td>
              <td style={{ color: 'var(--g500)' }}>
                {new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}
              </td>
              <td>
                <Link href={`/billing/${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  <i className="ti ti-receipt"></i> Bill
                </Link>
              </td>
            </tr>
          ))}
          {(!visits || visits.length === 0) && (
            <tr>
              <td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                No open visits right now.
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

