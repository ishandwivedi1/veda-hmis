'use client';

import { useState } from 'react';
import { useRouter } from 'next/navigation';
import { updateVisit, cancelVisit, getSurgeryTypeOptions, resendVisitWhatsApp } from './actions';

const VISIT_TYPES = ['New Consultation', 'Follow-up', 'Investigation Only', 'Surgery Evaluation', 'OPD Procedure Only', 'Post-operative Review', 'Emergency', 'Surgery'];

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
  const [waStatus, setWaStatus] = useState(''); // '', 'sending', 'sent', 'warning', 'error'
  const [waMsg, setWaMsg] = useState('');
  const router = useRouter();

  async function handleResendWhatsApp() {
    setWaStatus('sending');
    setWaMsg('');
    const result = await resendVisitWhatsApp(visit.id);
    if (result.error) { setWaStatus('error'); setWaMsg(result.error); return; }
    if (result.warning) { setWaStatus('warning'); setWaMsg(result.warning); return; }
    setWaStatus('sent');
  }

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

  const waButton = (
    <>
      <button className="btn btn-sm" title="Resend WhatsApp confirmation" onClick={handleResendWhatsApp} disabled={waStatus === 'sending'}>
        <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i>
      </button>
      {waStatus === 'sent' && <span style={{ fontSize: 10, color: 'var(--green)' }}><i className="ti ti-circle-check"></i></span>}
      {waStatus === 'warning' && <span style={{ fontSize: 10, color: 'var(--amber)' }} title={waMsg}><i className="ti ti-alert-triangle"></i></span>}
      {waStatus === 'error' && <span style={{ fontSize: 10, color: 'var(--red)' }} title={waMsg}><i className="ti ti-alert-circle"></i></span>}
    </>
  );

  if (visit.status !== 'Open') {
    return (
      <>
        {waButton}
        {visit.status === 'Cancelled' && visit.cancellation_reason ? (
          <span style={{ fontSize: 10, color: 'var(--red)' }} title={visit.cancellation_reason}>
            <i className="ti ti-info-circle"></i> {visit.cancellation_reason.length > 24 ? `${visit.cancellation_reason.slice(0, 24)}...` : visit.cancellation_reason}
          </span>
        ) : null}
      </>
    );
  }

  return (
    <>
      {waButton}
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

