#!/bin/bash
set -e
echo "Applying: fix missing Suspense boundaries around useSearchParams (build error fix)"

cat > "app/(main)/payments/advance/page.js" << 'PYEOF_7391015873277478932'
import { Suspense } from 'react';
import PaymentsTabs from '../payments-tabs';
import AdvanceTab from './advance-tab';

export default function AdvancePage() {
  return (
    <div>
      <PaymentsTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
        <AdvanceTab />
      </Suspense>
    </div>
  );
}

PYEOF_7391015873277478932

cat > "app/(main)/patients/page.js" << 'PYEOF_1400068400677343182'
import Link from 'next/link';
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
    case 'name_az': return list.sort((a, b) => `${a.first_name} ${a.last_name}`.localeCompare(`${b.first_name} ${b.last_name}`));
    case 'name_za': return list.sort((a, b) => `${b.first_name} ${b.last_name}`.localeCompare(`${a.first_name} ${a.last_name}`));
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
                <td style={{ fontWeight: 600 }}>{p.first_name} {p.last_name}</td>
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

PYEOF_1400068400677343182

cat > "app/(main)/visits/page.js" << 'PYEOF_126384185406576713'
import Link from 'next/link';
import { Suspense } from 'react';
import { createClient } from '@/lib/supabase-server';
import { getDoctorOptionsForVisit } from './actions';
import VisitActions from './visit-actions';
import SortSelect from '@/app/components/SortSelect';

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Surgery': '--teal',
};

const BILLING_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', '--': 'b-gray' };

const SORT_OPTIONS = [
  { value: 'newest', label: 'Newest first' },
  { value: 'oldest', label: 'Oldest first' },
  { value: 'patient_az', label: 'Patient (A-Z)' },
  { value: 'visit_number', label: 'Visit ID' },
  { value: 'status', label: 'Status' },
];

function sortVisits(visits, sort) {
  const list = [...visits];
  switch (sort) {
    case 'oldest': return list.sort((a, b) => new Date(a.created_at) - new Date(b.created_at));
    case 'patient_az': return list.sort((a, b) => `${a.patients?.first_name} ${a.patients?.last_name}`.localeCompare(`${b.patients?.first_name} ${b.patients?.last_name}`));
    case 'visit_number': return list.sort((a, b) => (a.visit_number || '').localeCompare(b.visit_number || ''));
    case 'status': return list.sort((a, b) => (a.status || '').localeCompare(b.status || ''));
    default: return list.sort((a, b) => new Date(b.created_at) - new Date(a.created_at)); // newest
  }
}

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;
  const tab = params?.tab === 'all' ? 'all' : 'today';
  const sort = params?.sort || 'newest';

  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  let query = supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles!doctor_id(full_name)')
    .order('created_at', { ascending: false });

  if (tab === 'today') {
    query = query.gte('created_at', today);
  } else {
    query = query.limit(100); // most recent 100 -- avoids loading the entire visit history at once
  }

  const { data: rawVisits, error } = await query;
  const visits = sortVisits(rawVisits || [], sort);
  const doctors = await getDoctorOptionsForVisit();

  const visitIds = (visits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, status').in('visit_id', visitIds);
    (invoices || []).forEach((inv) => { billingByVisit[inv.visit_id] = inv.status; });
  }

  return (
    <div className="card">
      <div className="card-head">
        <div>
          <div className="card-title"><i className="ti ti-door-enter" style={{ color: 'var(--green)' }}></i> Visits <span className="badge b-gray">{visits?.length ?? 0}</span></div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>{tab === 'today' ? "Today's visits, all statuses." : 'Most recent 100 visits, all time.'}</div>
        </div>
        <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Walk-in Visit
        </Link>
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16, alignItems: 'center', flexWrap: 'wrap' }}>
        <Link href={`/visits?tab=today&sort=${sort}`} className={tab === 'today' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          Today&apos;s Visits
        </Link>
        <Link href={`/visits?tab=all&sort=${sort}`} className={tab === 'all' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          All Visits
        </Link>
        <div style={{ marginLeft: 'auto' }}>
          <Suspense fallback={<div style={{ width: 140 }} />}>
            <SortSelect options={SORT_OPTIONS} defaultValue="newest" />
          </Suspense>
        </div>
      </div>

      {justCreated && <div className="msg-success"><i className="ti ti-circle-check"></i> Visit created successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Visit ID</th>
            <th>{tab === 'today' ? 'Time' : 'Date'}</th>
            <th>Patient</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Status</th>
            <th>Billing</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(visits || []).map((v) => {
            const billStatus = billingByVisit[v.id] || '--';
            return (
              <tr key={v.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                <td style={{ color: 'var(--g500)' }}>
                  {tab === 'today'
                    ? new Date(v.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })
                    : new Date(v.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                </td>
                <td>
                  <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                </td>
                <td>
                  <span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span>
                  {v.surgery_type && <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>{v.surgery_type}</div>}
                </td>
                <td>{v.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : v.status === 'Cancelled' ? 'b-red' : 'b-gray'}`}>{v.status}</span></td>
                <td><span className={`badge ${BILLING_BADGE[billStatus]}`}>{billStatus}</span></td>
                <td>
                  <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
                    {v.status === 'Open' && (
                      <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> Bill
                      </Link>
                    )}
                    <VisitActions visit={v} doctors={doctors} />
                  </div>
                </td>
              </tr>
            );
          })}
          {(!visits || visits.length === 0) && (
            <tr>
              <td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {tab === 'today' ? 'No visits yet today.' : 'No visits found.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}


PYEOF_126384185406576713

echo "Files written. Run: npm run build"
