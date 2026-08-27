import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { Suspense } from 'react';
import { createClient } from '@/lib/supabase-server';
import { getDoctorOptionsForVisit } from './actions';
import VisitActions from './visit-actions';
import SortSelect from '@/app/components/SortSelect';
import { VISIT_TYPE_COLOR } from '@/lib/visit-types';

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
    case 'patient_az': return list.sort((a, b) => `${formatPatientName(a.patients)}`.localeCompare(`${formatPatientName(b.patients)}`));
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
    .select('*, patients(first_name, salutation, last_name, uhid, mobile), profiles!doctor_id(full_name)')
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
                  <div style={{ fontWeight: 600 }}>{formatPatientName(v.patients)}</div>
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


