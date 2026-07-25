'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostOpEpisodeDetail, rescheduleFollowup, saveFollowupNotes, markFollowupStatus,
  addRecoveryComplication, closeEpisode,
} from './actions';

const MILESTONES = [
  { key: 'recovery', label: 'Recovery', icon: 'ti-bed' },
  { key: 'discharge', label: 'Discharge', icon: 'ti-door-exit' },
  { key: 'day1', label: 'Day 1 Review', icon: 'ti-calendar' },
  { key: 'week1', label: 'Week 1 Review', icon: 'ti-calendar' },
  { key: 'month1', label: 'Month 1 Review', icon: 'ti-calendar' },
  { key: 'closure', label: 'Episode Closure', icon: 'ti-circle-check' },
];


export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [editingFollowupId, setEditingFollowupId] = useState(null);
  const [editDate, setEditDate] = useState('');
  const [editNotes, setEditNotes] = useState('');
  const [saving, setSaving] = useState(false);

  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [showClose, setShowClose] = useState(false);
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const refresh = useCallback(async () => {
    setData(await getPostOpEpisodeDetail(episodeId));
  }, [episodeId]);

  useEffect(() => { refresh(); }, [episodeId, refresh]);

  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
  if (data.error) return <div className="msg-err">{data.error}</div>;

  const { episode, sc, followups, complications } = data;
  const patient = sc?.patients;
  const isClosed = !!episode.closure_status;

  const milestoneStatus = (key) => {
    if (key === 'recovery') return 'done';
    if (key === 'discharge') return episode.discharge_date ? 'done' : 'pending';
    if (key === 'closure') return episode.closure_status ? 'done' : 'pending';
    const labelMap = { day1: 'Post-op Day 1', week1: 'Post-op Week 1', month1: 'Post-op Month 1' };
    const f = followups.find((fu) => fu.visit_label === labelMap[key]);
    if (!f) return 'pending';
    return f.status === 'Completed' ? 'done' : 'scheduled';
  };

  function startEdit(f) {
    setError('');
    setEditingFollowupId(f.id);
    setEditDate(f.scheduled_date);
    setEditNotes(f.notes || '');
  }

  async function handleSaveFollowup(f) {
    setError('');
    setSaving(true);
    let result = { success: true };
    if (editDate !== f.scheduled_date) {
      result = await rescheduleFollowup(f.id, editDate, editNotes);
    } else if (editNotes !== (f.notes || '')) {
      result = await saveFollowupNotes(f.id, editNotes);
    }
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEditingFollowupId(null);
    refresh();
  }

  async function handleMarkStatus(f, status) {
    await markFollowupStatus(f.id, status);
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addRecoveryComplication(episodeId, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    refresh();
  }

  async function handleCloseEpisode() {
    setError('');
    if (!closureOutcome) { setError('VAL-POST-005: Overall clinical outcome is required.'); return; }
    setSaving(true);
    const result = await closeEpisode(episodeId, { status: closureStatus, outcome: closureOutcome, remarks: closureRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowClose(false);
    setOk('Episode closed.');
    onUpdate();
    refresh();
  }

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28d9)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 38, height: 38, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 16, fontWeight: 700, flexShrink: 0 }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>{patient?.uhid} -- {sc?.procedure_name} {sc?.eye} -- {sc?.profiles?.full_name}</div>
        </div>
        <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{isClosed ? 'Closed' : 'Post-op'}</span>
        <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}><i className="ti ti-arrow-left"></i> Dashboard</button>
      </div>

      {error && <div className="msg-err">{error}</div>}
      {ok && <div className="msg-ok">{ok}</div>}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list" style={{ color: 'var(--purple)' }}></i> Surgical Episode Dashboard</div>
        {MILESTONES.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : status === 'scheduled' ? 'var(--blue)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : status === 'scheduled' ? 'var(--blue-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : status === 'scheduled' ? 'ti-calendar' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--amber)' }}></i> Follow-up Schedule</div>
        {followups.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No follow-ups scheduled yet.</div>}
        {followups.map((f) => (
          <div key={f.id} style={{ padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 10, marginBottom: 8 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 6 }}>
              <div style={{ fontWeight: 700, fontSize: 13 }}>{f.visit_label}</div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <span className={`badge ${f.status === 'Completed' ? 'b-green' : f.status === 'Due' ? 'b-red' : 'b-blue'}`} style={{ fontSize: 10 }}>{f.status}</span>
                {f.rescheduled_count > 0 && <span style={{ fontSize: 10, color: 'var(--amber)' }}>Rescheduled {f.rescheduled_count}x</span>}
                {!isClosed && f.status !== 'Completed' && (
                  <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={() => handleMarkStatus(f, 'Completed')}>Mark Completed</button>
                )}
              </div>
            </div>

            {editingFollowupId !== f.id ? (
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-end', marginTop: 6 }}>
                <div>
                  <div style={{ fontSize: 12, color: 'var(--g500)' }}>{new Date(f.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</div>
                  {f.notes && <div style={{ fontSize: 11.5, color: 'var(--g600)', marginTop: 3 }}><i className="ti ti-notes"></i> {f.notes}</div>}
                </div>
                {!isClosed && (
                  <button className="btn btn-sm" onClick={() => startEdit(f)}><i className="ti ti-calendar-time"></i> Reschedule / Notes</button>
                )}
              </div>
            ) : (
              <div style={{ marginTop: 8, padding: 8, background: 'var(--amber-lt)', borderRadius: 8 }}>
                <div style={{ display: 'grid', gridTemplateColumns: '1fr', gap: 6, marginBottom: 6 }}>
                  <input type="date" className="fi fi-sm" value={editDate} onChange={(e) => setEditDate(e.target.value)} />
                  <textarea className="fi fi-sm" rows={2} value={editNotes} onChange={(e) => setEditNotes(e.target.value)} placeholder="Notes for this visit..." />
                </div>
                <div style={{ display: 'flex', gap: 6 }}>
                  <button className="btn btn-sm btn-primary" onClick={() => handleSaveFollowup(f)} disabled={saving}>Save</button>
                  <button className="btn btn-sm" onClick={() => setEditingFollowupId(null)}>Cancel</button>
                </div>
              </div>
            )}
          </div>
        ))}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Post-operative Complications <span style={{ fontWeight: 400, fontSize: 11, color: 'var(--g400)' }}>(separate from intraop)</span></div>
        {!isClosed && (
          <>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complName} onChange={(e) => setComplName(e.target.value)} placeholder="Complication (e.g. Raised IOP, CME)..." />
              <select className="fi fi-sm" value={complSeverity} onChange={(e) => setComplSeverity(e.target.value)}><option>Mild</option><option>Moderate</option><option>Severe</option></select>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <input className="fi fi-sm" value={complManagement} onChange={(e) => setComplManagement(e.target.value)} placeholder="Management..." />
              <input className="fi fi-sm" value={complOutcome} onChange={(e) => setComplOutcome(e.target.value)} placeholder="Outcome..." />
            </div>
            <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleAddComplication}><i className="ti ti-plus"></i> Add complication</button>
          </>
        )}
        <div style={{ marginTop: 8 }}>
          {complications.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No post-operative complications recorded.</div>}
          {complications.map((c) => (
            <div key={c.id} style={{ padding: '8px 10px', borderRadius: 8, background: c.severity === 'Severe' ? 'var(--red-lt)' : 'var(--amber-lt)', marginBottom: 6, fontSize: 12 }}>
              <strong>{c.name}</strong> <span className={`badge ${c.severity === 'Severe' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{c.severity}</span>
              <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 3 }}>{c.management ? `Management: ${c.management}` : <span style={{ color: 'var(--red)' }}>Management pending -- required before episode can close</span>}</div>
              {c.outcome && <div style={{ fontSize: 11, color: 'var(--g600)' }}>Outcome: {c.outcome}</div>}
            </div>
          ))}
        </div>
      </div>

      {!isClosed && !showClose && (
        <div className="card" style={{ textAlign: 'center', marginBottom: 0 }}>
          <button className="btn btn-primary" onClick={() => setShowClose(true)}><i className="ti ti-circle-check"></i> Close Surgical Episode</button>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 6 }}>Only the Ophthalmologist should close an episode. Overall outcome must be documented.</div>
        </div>
      )}

      {showClose && (
        <div className="card" style={{ marginBottom: 0 }}>
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-circle-check" style={{ color: 'var(--purple)' }}></i> Close Surgical Episode</div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Episode closure status</label>
            <select className="fi" value={closureStatus} onChange={(e) => setClosureStatus(e.target.value)}>
              <option>Successfully Completed</option><option>Completed with Residual Condition</option><option>Requires Ongoing Follow-up</option><option>Transferred to Long-term Care</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Overall clinical outcome *</label>
            <select className="fi" value={closureOutcome} onChange={(e) => setClosureOutcome(e.target.value)}>
              <option value="">-- Select --</option>
              <option>Excellent Visual Outcome</option><option>Expected Recovery</option><option>Delayed Recovery</option><option>Complication Managed</option><option>Additional Surgery Required</option>
            </select>
          </div>
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Closure remarks</label>
            <textarea className="fi" rows={2} value={closureRemarks} onChange={(e) => setClosureRemarks(e.target.value)} placeholder="Final remarks..." />
          </div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn btn-primary" style={{ background: 'var(--purple)', borderColor: 'transparent' }} onClick={handleCloseEpisode} disabled={saving}>{saving ? 'Closing...' : 'Close Episode'}</button>
            <button className="btn" onClick={() => setShowClose(false)}>Cancel</button>
          </div>
        </div>
      )}

      {isClosed && (
        <div className="msg-ok">
          <i className="ti ti-circle-check"></i>
          <span><strong>Episode Closed</strong> -- {episode.closure_status}. Outcome: {episode.closure_outcome}. {episode.closure_remarks}</span>
        </div>
      )}
    </div>
  );
}

