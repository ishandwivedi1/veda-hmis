#!/bin/bash
set -e

echo 'Applying: ensure Surgery visit type + Type of Surgery sub-dropdown are fully wired (safety re-push)...'

mkdir -p 'app/(main)/visits/new'

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
    p_surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
  });

  if (error) {
    return { error: error.message };
  }
  return { visit: data };
}

export async function getSurgeryTypeOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('id, name').eq('status', 'Active').order('name');
  return data || [];
}

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Surgery'];

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
    surgery_type: values.visitType === 'Surgery' ? (values.surgeryType || null) : null,
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

cat > 'app/(main)/visits/new/page.js' << 'VISITS_NEW_PAGE_EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchPatientsForBooking, getDoctors } from '@/app/(main)/appointments/actions';
import { createWalkInVisit, getSurgeryTypeOptions } from '@/app/(main)/visits/actions';

export default function NewVisitPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [searched, setSearched] = useState(false);

  const [doctors, setDoctors] = useState([]);
  const [doctorId, setDoctorId] = useState('');
  const [visitType, setVisitType] = useState('New Consultation');
  const [referralSource, setReferralSource] = useState('Walk-in');
  const [priority, setPriority] = useState('Routine');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [surgeryType, setSurgeryType] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getDoctors().then(setDoctors);
    getSurgeryTypeOptions().then(setSurgeryTypes);
  }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForBooking(searchQuery.trim());
    setSearchResults(results);
    setSearched(true);
  }

  function goToFullRegistration() {
    const isMobile = /^\d{6,}$/.test(searchQuery.trim());
    const params = new URLSearchParams({
      returnTo: 'visit',
      prefillFirstName: isMobile ? '' : searchQuery.trim().split(' ')[0] || '',
      prefillLastName: isMobile ? '' : searchQuery.trim().split(' ').slice(1).join(' ') || '',
      prefillMobile: isMobile ? searchQuery.trim() : '',
    });
    router.push(`/patients/new?${params.toString()}`);
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
  }

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');

    if (!selectedPatient) {
      setError('Search and select a registered patient.');
      return;
    }
    if (visitType === 'Surgery' && !surgeryType) {
      setError('Select the type of surgery.');
      return;
    }

    setLoading(true);
    const result = await createWalkInVisit({
      patientId: selectedPatient.id,
      doctorId: doctorId || null,
      visitType,
      referralSource,
      priority,
      surgeryType,
    });
    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/front-office-dashboard?visitCreated=1');
  }

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-door-enter" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Create Walk-in Visit
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 20 }}>
          For patients arriving without a prior appointment.
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <div style={{ marginBottom: 16 }}>
            <label className="flbl">Find patient (name, UHID, or mobile) *</label>
            {selectedPatient ? (
              <div
                style={{
                  display: 'flex',
                  justifyContent: 'space-between',
                  alignItems: 'center',
                  background: 'var(--blue-lt)',
                  padding: '8px 12px',
                  borderRadius: 8,
                }}
              >
                <span>
                  <strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong>
                  {' -- '}
                  {selectedPatient.uhid}
                </span>
                <button
                  type="button"
                  className="btn"
                  style={{ padding: '4px 10px' }}
                  onClick={() => setSelectedPatient(null)}
                >
                  Change
                </button>
              </div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input
                    className="fi"
                    value={searchQuery}
                    onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }}
                    placeholder="Type to search..."
                  />
                  <button type="button" className="btn" onClick={handleSearch}>
                    Search
                  </button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 6 }}>
                    {searchResults.map((p) => (
                      <div
                        key={p.id}
                        onClick={() => pickPatient(p)}
                        style={{
                          padding: '8px 12px',
                          cursor: 'pointer',
                          borderBottom: '1px solid var(--g100)',
                          fontSize: 13,
                        }}
                      >
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                      </div>
                    ))}
                  </div>
                )}
                {searched && searchResults.length === 0 && (
                  <div style={{ fontSize: 12, marginTop: 8 }}>
                    No match for &quot;{searchQuery || 'that search'}&quot;.{' '}
                    <button
                      type="button"
                      onClick={goToFullRegistration}
                      style={{ color: 'var(--blue)', background: 'none', border: 'none', padding: 0, cursor: 'pointer', textDecoration: 'underline', fontSize: 12 }}
                    >
                      Register this patient
                    </button>
                  </div>
                )}
              </>
            )}
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: visitType === 'Surgery' ? '1fr 1fr 1fr' : '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Visit type</label>
              <select className="fi" value={visitType} onChange={(e) => { setVisitType(e.target.value); if (e.target.value !== 'Surgery') setSurgeryType(''); }}>
                <option>New Consultation</option>
                <option>Follow-up</option>
                <option>Investigation Only</option>
                <option>Post-operative Review</option>
                <option>Emergency</option>
                <option>Surgery</option>
              </select>
            </div>
            {visitType === 'Surgery' && (
              <div>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
            <div>
              <label className="flbl">Doctor</label>
              <select className="fi" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
                <option value="">-- Any / Not decided --</option>
                {doctors.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 20 }}>
            <div>
              <label className="flbl">Referral source</label>
              <select className="fi" value={referralSource} onChange={(e) => setReferralSource(e.target.value)}>
                <option>Walk-in</option>
                <option>Doctor referral</option>
                <option>Camp / outreach</option>
                <option>Previous patient</option>
              </select>
            </div>
            <div>
              <label className="flbl">Priority</label>
              <select className="fi" value={priority} onChange={(e) => setPriority(e.target.value)}>
                <option>Routine</option>
                <option>Urgent</option>
                <option>Emergency</option>
              </select>
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Creating...' : 'Create Visit'}
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


VISITS_NEW_PAGE_EOF

cat > 'app/(main)/visits/visit-actions.js' << 'VISIT_ACTIONS_COMPONENT_EOF'
'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { updateVisit, cancelVisit, getSurgeryTypeOptions } from './actions';

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Post-operative Review', 'Emergency', 'Surgery'];

export default function VisitActions({ visit, doctors }) {
  const [mode, setMode] = useState(null); // 'edit' | 'cancel' | null
  const [doctorId, setDoctorId] = useState(visit.doctor_id || '');
  const [visitType, setVisitType] = useState(visit.visit_type || 'New Consultation');
  const [priority, setPriority] = useState(visit.priority || 'Routine');
  const [surgeryType, setSurgeryType] = useState(visit.surgery_type || '');
  const [surgeryTypes, setSurgeryTypes] = useState([]);
  const [cancelReason, setCancelReason] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  function openEdit() {
    setError('');
    setDoctorId(visit.doctor_id || '');
    setVisitType(visit.visit_type || 'New Consultation');
    setPriority(visit.priority || 'Routine');
    setSurgeryType(visit.surgery_type || '');
    if (surgeryTypes.length === 0) getSurgeryTypeOptions().then(setSurgeryTypes);
    setMode('edit');
  }

  async function handleSaveEdit() {
    setError('');
    if (visitType === 'Surgery' && !surgeryType) { setError('Select the type of surgery.'); return; }
    setSaving(true);
    const result = await updateVisit(visit.id, { doctorId, visitType, priority, surgeryType });
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
            {visitType === 'Surgery' && (
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Type of surgery</label>
                <select className="fi" value={surgeryType} onChange={(e) => setSurgeryType(e.target.value)}>
                  <option value="">-- Select --</option>
                  {surgeryTypes.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                </select>
              </div>
            )}
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
  'Surgery': '--teal',
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
    .select('*, patients(first_name, last_name, uhid, mobile), profiles!doctor_id(full_name)')
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


VISITS_PAGE_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/visits"'
echo '  git commit -m "Ensure Surgery visit type and Type of Surgery sub-dropdown are fully wired"'
echo '  git push'
