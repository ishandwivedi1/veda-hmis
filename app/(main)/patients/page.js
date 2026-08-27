import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { Suspense } from 'react';
import { createClient } from '@/lib/supabase-server';
import SortSelect from '@/app/components/SortSelect';

const GENDER_BADGE = { M: 'b-blue', F: 'b-purple', O: 'b-gray' };
const GENDER_LABEL = { M: 'Male', F: 'Female', O: 'Other' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest registered' },
  { value: 'oldest', label: 'Oldest registered' },
  { value: 'name_az', label: 'Name (A-Z)' },
  { value: 'name_za', label: 'Name (Z-A)' },
  { value: 'uhid', label: 'UHID' },
];

function sortPatients(patients, sort) {
  const list = [...patients];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    case 'name_az': return list.sort((a, b) => `${formatPatientName(a)}`.localeCompare(`${formatPatientName(b)}`));
    case 'name_za': return list.sort((a, b) => `${formatPatientName(b)}`.localeCompare(`${formatPatientName(a)}`));
    case 'uhid': return list.sort((a, b) => (a.uhid || '').localeCompare(b.uhid || ''));
    default: return list.sort((a, b) => new Date(b.created_at) - new Date(a.created_at)); // newest
  }
}

export default async function PatientsPage({ searchParams }) {
  const params = await searchParams;
  const justRegistered = params?.registered;
  const q = params?.q || '';
  const sort = params?.sort || 'newest';

  const supabase = await createClient();
  let query = supabase.from('patients').select('*').order('created_at', { ascending: false });

  if (q) {
    query = query.or(
      `uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`
    );
  }

  const { data: rawPatients, error } = await query;
  const patients = sortPatients(rawPatients || [], sort);

  // Richer search results, matching M20's "Find Patient" screen -- shows
  // each patient's last visit date and whether they currently have an
  // open (active) visit, computed in one batched query rather than one
  // query per row.
  const patientIds = (patients || []).map((p) => p.id);
  let visitInfo = {};
  if (patientIds.length > 0) {
    const { data: visits } = await supabase
      .from('visits')
      .select('patient_id, status, created_at')
      .in('patient_id', patientIds)
      .order('created_at', { ascending: false });

    (visits || []).forEach((v) => {
      if (!visitInfo[v.patient_id]) {
        visitInfo[v.patient_id] = { lastVisit: v.created_at, hasActive: false };
      }
      if (v.status === 'Open') {
        visitInfo[v.patient_id].hasActive = true;
      }
    });
  }

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
        <input type="hidden" name="sort" value={sort} />
        <button type="submit" className="btn btn-primary"><i className="ti ti-search"></i> Search</button>
        {q && (
          <Link href={`/patients?sort=${sort}`} className="btn" style={{ textDecoration: 'none' }}>
            Clear
          </Link>
        )}
        <Suspense fallback={<div style={{ width: 140 }} />}>
          <SortSelect options={SORT_OPTIONS} defaultValue="newest" />
        </Suspense>
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
            <th>Last Visit</th>
            <th>Active Visit</th>
            <th>Actions</th>
          </tr>
        </thead>
        <tbody>
          {(patients || []).map((p) => {
            const info = visitInfo[p.id];
            return (
              <tr key={p.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)' }}>{p.uhid}</td>
                <td style={{ fontWeight: 600 }}>{formatPatientName(p)}</td>
                <td>{p.age || '--'}</td>
                <td><span className={`badge ${GENDER_BADGE[p.gender] || 'b-gray'}`}>{GENDER_LABEL[p.gender] || p.gender}</span></td>
                <td>{p.mobile}</td>
                <td>{p.blood_group ? <span className="badge b-red">{p.blood_group}</span> : '--'}</td>
                <td style={{ color: 'var(--g500)' }}>{info ? new Date(info.lastVisit).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' }) : 'Never'}</td>
                <td>{info?.hasActive ? <span className="badge b-green">Active</span> : <span className="badge b-gray">None</span>}</td>
                <td>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <Link
                      href={`/patients/${p.id}/edit`}
                      className="btn"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-edit"></i> Edit
                    </Link>
                    <Link
                      href={`/visits/new?patientId=${p.id}`}
                      className="btn btn-primary"
                      style={{ textDecoration: 'none', padding: '4px 10px', fontSize: 12 }}
                    >
                      <i className="ti ti-door-enter"></i> Create Visit
                    </Link>
                  </div>
                </td>
              </tr>
            );
          })}
          {(!patients || patients.length === 0) && (
            <tr>
              <td colSpan={9} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {q ? `No patients found matching "${q}".` : 'No patients registered yet.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

