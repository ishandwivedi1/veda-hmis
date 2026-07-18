'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getInvestigationDetail, startInvestigation, saveInvestigationDraft,
  completeInvestigation, verifyInvestigation, markUnableToPerform,
} from '../actions';

// Maps a doctor's free-text investigation name to the closest workspace
// template -- same heuristic as the prototype's matchInvestigationType,
// with External Report as the generic fallback for anything unrecognised
// (e.g. external lab reports, blood work).
function matchInvestigationType(name) {
  const n = (name || '').toLowerCase();
  if (n.includes('oct')) {
    return {
      type: 'OCT', icon: 'ti-eye',
      fields: [
        { lbl: 'Central Macular Thickness (OD)', id: 'cmt-re', placeholder: 'e.g. 245 um' },
        { lbl: 'RNFL Thickness', id: 'rnfl', placeholder: 'e.g. Average 85 um' },
        { lbl: 'Signal Strength', id: 'signal', placeholder: 'e.g. 8/10' },
        { lbl: 'GCC', id: 'gcc', placeholder: 'Optional' },
      ],
      note: 'Clinical interpretation reserved for Ophthalmologist. Enter measurements only.',
      verifyItems: ['Scan quality acceptable', 'Central macula imaged', 'Both eyes captured if bilateral', 'Signal strength >= 6'],
    };
  }
  if (n.includes('visual field') || n.includes(' vf') || n.includes('perimetry')) {
    return {
      type: 'Visual Field', icon: 'ti-activity',
      fields: [
        { lbl: 'Test strategy', id: 'vf-strategy', placeholder: 'e.g. SITA Standard 24-2' },
        { lbl: 'MD (RE)', id: 'md-re', placeholder: 'e.g. -6.2 dB' },
        { lbl: 'PSD (RE)', id: 'psd-re', placeholder: 'e.g. 5.1 dB' },
        { lbl: 'MD (LE)', id: 'md-le', placeholder: 'e.g. -4.1 dB' },
        { lbl: 'PSD (LE)', id: 'psd-le', placeholder: 'e.g. 3.8 dB' },
        { lbl: 'VFI (%)', id: 'vfi', placeholder: 'e.g. 72%' },
        { lbl: 'Reliability indices', id: 'vf-rel', placeholder: 'FP<5%, FN<5%, FL<20%' },
      ],
      note: 'PDF report or device output should be uploaded once document upload is available.',
      verifyItems: ['Test completed bilaterally', 'Reliability indices acceptable', 'Patient cooperation noted'],
    };
  }
  if (n.includes('fundus')) {
    return {
      type: 'Fundus Photography', icon: 'ti-camera',
      fields: [
        { lbl: 'Image quality', id: 'img-qual', placeholder: 'Good / Fair / Poor' },
        { lbl: 'Field coverage', id: 'img-field', placeholder: 'e.g. Macula-centred, Disc-centred' },
        { lbl: 'Photography notes', id: 'photo-notes', placeholder: 'e.g. Media clear, good view...' },
      ],
      note: null,
      verifyItems: ['Images captured for required fields', 'Image quality acceptable', 'Linked to correct eye and encounter'],
    };
  }
  return {
    type: 'External Report', icon: 'ti-file-import',
    fields: [
      { lbl: 'Document type', id: 'doc-type', placeholder: 'e.g. Blood sugar report, ECG' },
      { lbl: 'Issuing lab/hospital', id: 'doc-source', placeholder: 'e.g. Pathology Lab, Haridwar' },
      { lbl: 'Report date', id: 'doc-date', placeholder: 'DD/MM/YYYY' },
      { lbl: 'Summary findings', id: 'doc-summary', placeholder: 'e.g. FBS 112 mg/dL, ECG normal sinus rhythm' },
    ],
    note: null,
    verifyItems: ['Document details recorded', 'Source and date documented', 'Linked to Clinical Encounter'],
  };
}

const STATUS_STEPS = ['Ordered', 'In Progress', 'Completed', 'Verified', 'Available'];
function statusIdx(status) {
  if (status === 'Available') return 4;
  const i = STATUS_STEPS.indexOf(status);
  return i === -1 ? 0 : i;
}

function StatusTimeline({ status }) {
  const currentIdx = statusIdx(status);
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 0, flexWrap: 'wrap' }}>
      {STATUS_STEPS.map((s, i) => {
        const cls = i < currentIdx ? 'done' : i === currentIdx ? 'active' : 'pending';
        const bg = cls === 'done' ? 'var(--green)' : cls === 'active' ? 'var(--teal)' : '#fff';
        const border = cls === 'pending' ? 'var(--g200)' : (cls === 'done' ? 'var(--green)' : 'var(--teal)');
        const color = cls === 'pending' ? 'var(--g300)' : '#fff';
        return (
          <div key={s} style={{ display: 'flex', alignItems: 'center', flex: i < STATUS_STEPS.length - 1 ? 1 : 'none' }}>
            <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 3, minWidth: 80 }}>
              <div style={{ width: 28, height: 28, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, border: `2px solid ${border}`, background: bg, color, boxShadow: cls === 'active' ? '0 0 0 4px var(--teal-lt)' : 'none' }}>
                <i className={`ti ${cls === 'done' ? 'ti-check' : cls === 'active' ? 'ti-loader' : 'ti-circle'}`} style={{ fontSize: 11 }}></i>
              </div>
              <div style={{ fontSize: 10, color: 'var(--g400)', textAlign: 'center' }}>{s}</div>
            </div>
            {i < STATUS_STEPS.length - 1 && <div style={{ flex: 1, height: 2, background: i < currentIdx ? 'var(--green)' : 'var(--g200)', minWidth: 20 }}></div>}
          </div>
        );
      })}
    </div>
  );
}

export default function InvestigationWorkspace({ orderId }) {
  const [order, setOrder] = useState(null);
  const [doctorName, setDoctorName] = useState('--');
  const [loadError, setLoadError] = useState('');
  const [fields, setFields] = useState({});
  const [remarks, setRemarks] = useState('');
  const [checklist, setChecklist] = useState({});
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getInvestigationDetail(orderId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setOrder(result.order);
      setDoctorName(result.doctorName);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    });
  }, [orderId]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!order) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = order.encounters?.visits?.patients;
  const visitNumber = order.encounters?.visits?.visit_number;
  const template = matchInvestigationType(order.name);

  function setField(id, value) {
    setFields((prev) => ({ ...prev, [id]: value }));
  }
  function toggleCheck(item) {
    setChecklist((prev) => ({ ...prev, [item]: !prev[item] }));
  }

  async function refresh() {
    const result = await getInvestigationDetail(orderId);
    if (!result.error) {
      setOrder(result.order);
      setFields(result.order.result_data || {});
      setRemarks(result.order.result_notes || '');
    }
  }

  async function handleStart() {
    setError(''); setSaving(true);
    const result = await startInvestigation(orderId);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleSaveDraft() {
    setError(''); setOkMsg(''); setSaving(true);
    const result = await saveInvestigationDraft(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in queue.');
  }

  async function handleComplete() {
    setError(''); setSaving(true);
    const result = await completeInvestigation(orderId, fields, remarks);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVerify() {
    setError('');
    const allChecked = template.verifyItems.every((item) => checklist[item]);
    if (!allChecked) {
      setError(`All verification items must be checked before verifying (${template.verifyItems.filter((i) => checklist[i]).length}/${template.verifyItems.length} checked).`);
      return;
    }
    setSaving(true);
    const result = await verifyInvestigation(orderId, checklist);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Investigation verified and released. Now available in Clinical Encounter.');
    refresh();
  }

  async function handleUnable() {
    const reason = window.prompt('Enter reason for unable to perform:');
    if (!reason) return;
    setError(''); setSaving(true);
    const result = await markUnableToPerform(orderId, reason);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  const isCancelled = order.status === 'Cancelled';
  const isAvailable = order.status === 'Available';
  const canEdit = !isCancelled && !isAvailable;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0f766e,#0d9488)', borderRadius: 12, padding: '10px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- Visit {visitNumber || '--'} -- Dr. {doctorName}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, opacity: .7 }}>Investigation</div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{order.name}</div>
          <span className={`badge ${order.status === 'Available' ? 'b-green' : order.status === 'Cancelled' ? 'b-red' : order.status === 'Completed' ? 'b-teal' : order.status === 'In Progress' ? 'b-blue' : 'b-amber'}`} style={{ fontSize: 10, marginTop: 3 }}>
            {order.status}
          </span>
        </div>
      </div>

      {!isCancelled && (
        <div className="card" style={{ padding: 12 }}>
          <StatusTimeline status={order.status} />
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      {isCancelled ? (
        <div className="card" style={{ background: 'var(--red-lt)', borderColor: '#fca5a5' }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--red)', marginBottom: 6 }}>
            <i className="ti ti-x-circle"></i> Unable to Perform
          </div>
          <div style={{ fontSize: 13, color: 'var(--red)' }}>{order.unable_reason}</div>
        </div>
      ) : (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
          <div>
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className={`ti ${template.icon}`} style={{ color: 'var(--teal)' }}></i> {order.name} workspace</div>
              {template.fields.map((f) => (
                <div key={f.id} style={{ marginBottom: 10 }}>
                  <label className="flbl">{f.lbl}</label>
                  <input className="fi fi-sm" placeholder={f.placeholder} value={fields[f.id] || ''} onChange={(e) => setField(f.id, e.target.value)} disabled={!canEdit} />
                </div>
              ))}
              {template.note && (
                <div style={{ marginTop: 8, padding: '8px 10px', background: 'var(--blue-lt)', borderRadius: 8, fontSize: 11, color: 'var(--blue)' }}>
                  <i className="ti ti-info-circle"></i> {template.note}
                </div>
              )}
            </div>
          </div>

          <div>
            <div className="card" style={{ marginBottom: 12 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Technician Remarks</div>
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 8 }}>
                <i className="ti ti-alert-triangle"></i> Factual observations only. Clinical interpretation is reserved for the Ophthalmologist.
              </div>
              <textarea className="fi fi-sm" rows={3} value={remarks} onChange={(e) => setRemarks(e.target.value)} disabled={!canEdit} placeholder="e.g. Poor fixation due to dense cataract. Scan quality: Good. Signal strength 7/10..." />
            </div>

            {(order.status === 'Completed') && (
              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Verification</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Verification confirms technical completeness -- not clinical interpretation.</div>
                {template.verifyItems.map((item) => (
                  <label key={item} style={{ display: 'flex', alignItems: 'center', gap: 7, fontSize: 12, cursor: 'pointer', marginBottom: 5 }}>
                    <input type="checkbox" checked={!!checklist[item]} onChange={() => toggleCheck(item)} style={{ accentColor: 'var(--green)', width: 14, height: 14 }} />
                    {item}
                  </label>
                ))}
              </div>
            )}

            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrows-right" style={{ color: 'var(--teal)' }}></i> Workflow Controls</div>
              <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
                {order.status === 'Ordered' && (
                  <button className="btn btn-sm" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleStart} disabled={saving}>
                    <i className="ti ti-play"></i> Start Investigation
                  </button>
                )}
                {order.status === 'In Progress' && (
                  <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleComplete} disabled={saving}>
                    <i className="ti ti-check"></i> Mark Complete
                  </button>
                )}
                {order.status === 'Completed' && (
                  <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={handleVerify} disabled={saving}>
                    <i className="ti ti-shield-check"></i> Verify &amp; Release
                  </button>
                )}
                {canEdit && (
                  <button className="btn btn-sm" onClick={handleSaveDraft} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> Save Draft
                  </button>
                )}
                {canEdit && (
                  <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleUnable} disabled={saving}>
                    <i className="ti ti-x-circle"></i> Unable to Perform
                  </button>
                )}
                <button className="btn btn-sm" onClick={() => router.push('/investigation')}>
                  <i className="ti ti-arrow-left"></i> Back to Queue
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
