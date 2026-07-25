#!/bin/bash
set -e

echo 'Applying: Edit and Cancel options for Front Office visits, with audit trail...'

mkdir -p 'app/(main)/visits'

cat > 'app/(main)/visits/actions.js' << 'VISITS_ACTIONS_EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getDoctorOptionsForVisit() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, full_name')
    .or('designation.ilike.%ophthalmologist%,designation.ilike.%doctor%')
    .eq('status', 'Active')
    .order('full_name');
  return data || [];
}

export async function checkInAppointment(appointmentId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('check_in_appointment', {
    p_appointment_id: appointmentId,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

export async function createWalkInVisit(values) {
  const supabase = await createClient();

  const { data, error } = await supabase.rpc('create_walk_in_visit', {
    p_patient_id: values.patientId,
    p_doctor_id: values.doctorId || null,
    p_visit_type: values.visitType,
    p_referral_source: values.referralSource || null,
    p_priority: values.priority || 'Routine',
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Procedure'];

// Doctor / visit type / priority can be corrected after check-in --
// front desk mistakes happen. Scoped to Open visits only; a closed or
// cancelled visit is a historical record and shouldn't be edited.
export async function updateVisit(visitId, values) {
  const supabase = await createClient();

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is ${visit.status} and can no longer be edited.` };
  if (values.visitType && !VISIT_TYPES.includes(values.visitType)) return { error: 'Invalid visit type.' };

  const { error } = await supabase.from('visits').update({
    doctor_id: values.doctorId || null,
    visit_type: values.visitType,
    priority: values.priority || 'Routine',
  }).eq('id', visitId);
  if (error) return { error: error.message };
  return { success: true };
}

// Cancelling a visit is permanent and needs a reason on record -- also
// pulls the patient out of whatever queue they're still sitting in
// (Optometry/Doctor), since there's nothing left for them to wait for.
// Blocked if the visit already has money collected against it, since
// that needs to go through Invoice Modification instead of silently
// orphaning a paid invoice.
export async function cancelVisit(visitId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A cancellation reason is required.' };

  const { data: visit } = await supabase.from('visits').select('status').eq('id', visitId).single();
  if (!visit) return { error: 'Visit not found.' };
  if (visit.status !== 'Open') return { error: `This visit is already ${visit.status}.` };

  const { data: invoices } = await supabase.from('invoices').select('id, status, paid').eq('visit_id', visitId);
  const hasPayment = (invoices || []).some((inv) => Number(inv.paid) > 0);
  if (hasPayment) {
    return { error: 'This visit already has payment collected against it -- cancel or modify the invoice first, via Invoice Modification.' };
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('visits').update({
    status: 'Cancelled',
    cancellation_reason: reason.trim(),
    cancelled_by: userData?.user?.id || null,
    cancelled_at: new Date().toISOString(),
  }).eq('id', visitId);
  if (error) return { error: error.message };

  await supabase
    .from('queue_entries')
    .update({ status: 'Cancelled' })
    .eq('visit_id', visitId)
    .not('status', 'in', '("Done","Cancelled")');

  return { success: true };
}


VISITS_ACTIONS_EOF

cat > 'app/(main)/visits/visit-actions.js' << 'VISIT_ACTIONS_COMPONENT_EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { updateVisit, cancelVisit } from './actions';

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Procedure'];

export default function VisitActions({ visit, doctors }) {
  const [mode, setMode] = useState(null); // 'edit' | 'cancel' | null
  const [doctorId, setDoctorId] = useState(visit.doctor_id || '');
  const [visitType, setVisitType] = useState(visit.visit_type || 'New Consultation');
  const [priority, setPriority] = useState(visit.priority || 'Routine');
  const [cancelReason, setCancelReason] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  function openEdit() {
    setError('');
    setDoctorId(visit.doctor_id || '');
    setVisitType(visit.visit_type || 'New Consultation');
    setPriority(visit.priority || 'Routine');
    setMode('edit');
  }

  async function handleSaveEdit() {
    setError('');
    setSaving(true);
    const result = await updateVisit(visit.id, { doctorId, visitType, priority });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setMode(null);
    router.refresh();
  }

  async function handleConfirmCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A cancellation reason is required.'); return; }
    setSaving(true);
    const result = await cancelVisit(visit.id, cancelReason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setMode(null);
    router.refresh();
  }

  if (visit.status !== 'Open') {
    return visit.status === 'Cancelled' && visit.cancellation_reason ? (
      <span style={{ fontSize: 10, color: 'var(--red)' }} title={visit.cancellation_reason}>
        <i className="ti ti-info-circle"></i> {visit.cancellation_reason.length > 24 ? `${visit.cancellation_reason.slice(0, 24)}...` : visit.cancellation_reason}
      </span>
    ) : null;
  }

  return (
    <>
      <button className="btn btn-sm" onClick={openEdit}><i className="ti ti-edit"></i></button>
      <button className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => { setError(''); setCancelReason(''); setMode('cancel'); }}><i className="ti ti-x"></i></button>

      {mode === 'edit' && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={() => setMode(null)}>
          <div className="card" style={{ width: 380, marginBottom: 0 }} onClick={(e) => e.stopPropagation()}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-edit"></i> Edit Visit</div>
            {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => setVisitType(e.target.value)}>
                {VISIT_TYPES.map((t) => <option key={t}>{t}</option>)}
              </select>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Not assigned --</option>
                {doctors.map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
              </select>
            </div>
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option><option>Urgent</option><option>Emergency</option>
              </select>
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={() => setMode(null)}>Cancel</button>
              <button className="btn btn-primary" onClick={handleSaveEdit} disabled={saving}>{saving ? 'Saving...' : 'Save'}</button>
            </div>
          </div>
        </div>
      )}

      {mode === 'cancel' && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={() => setMode(null)}>
          <div className="card" style={{ width: 380, marginBottom: 0 }} onClick={(e) => e.stopPropagation()}>
            <div className="card-title" style={{ marginBottom: 4, color: 'var(--red)' }}><i className="ti ti-alert-triangle"></i> Cancel Visit</div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
              This permanently cancels the visit and clears the patient from any active queue. A reason is required and stays on record.
            </div>
            {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Reason *</label>
              <textarea className="fi" rows={3} value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="e.g. Patient left without being seen, duplicate registration..." />
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button className="btn" onClick={() => setMode(null)}>Keep Visit</button>
              <button className="btn" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleConfirmCancel} disabled={saving}>
                {saving ? 'Cancelling...' : 'Confirm Cancellation'}
              </button>
            </div>
          </div>
        </div>
      )}
    </>
  );
}

VISIT_ACTIONS_COMPONENT_EOF

cat > 'app/(main)/visits/page.js' << 'VISITS_PAGE_EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import { getDoctorOptionsForVisit } from './actions';
import VisitActions from './visit-actions';

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

const BILLING_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', '--': 'b-gray' };

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;
  const tab = params?.tab === 'all' ? 'all' : 'today';

  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  let query = supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .order('created_at', { ascending: false });

  if (tab === 'today') {
    query = query.gte('created_at', today);
  } else {
    query = query.limit(100); // most recent 100 -- avoids loading the entire visit history at once
  }

  const { data: visits, error } = await query;
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

      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        <Link href="/visits?tab=today" className={tab === 'today' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          Today&apos;s Visits
        </Link>
        <Link href="/visits?tab=all" className={tab === 'all' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          All Visits
        </Link>
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
                    ? new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })
                    : new Date(v.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                </td>
                <td>
                  <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                </td>
                <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
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


VISITS_PAGE_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/visits/actions.js" "app/(main)/visits/visit-actions.js" "app/(main)/visits/page.js"'
echo '  git commit -m "Add Edit and Cancel options for Front Office visits, with reason recording and audit trail"'
echo '  git push'
