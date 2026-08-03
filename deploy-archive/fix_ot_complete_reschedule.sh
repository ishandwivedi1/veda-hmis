#!/bin/bash
set -e

echo 'Applying: remove manual Mark Completed; add Reschedule to Daily OT List...'

mkdir -p 'app/(main)/ot-schedule'

cat > 'app/(main)/ot-schedule/workspace-tab.js' << 'OT_WORKSPACE_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getSchedulingWorkspaceData, getOTSessions, getSessionCapacity, getSurgeonOptions,
  scheduleSurgery, rescheduleSurgery, cancelSurgery,
} from './actions';

const PRIORITY_BADGE = { Emergency: 'b-red', Urgent: 'b-amber', Routine: 'b-gray' };

export default function WorkspaceTab({ caseId, onDone, onUpdate }) {
  const [data, setData] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [surgeons, setSurgeons] = useState([]);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessionId, setSessionId] = useState('');
  const [surgeonId, setSurgeonId] = useState('');
  const [room, setRoom] = useState('');
  const [sequenceNumber, setSequenceNumber] = useState('');
  const [duration, setDuration] = useState(30);
  const [capacityInfo, setCapacityInfo] = useState(null);
  const [saving, setSaving] = useState(false);

  const [showReschedule, setShowReschedule] = useState(false);
  const [reschDate, setReschDate] = useState('');
  const [reschSessionId, setReschSessionId] = useState('');
  const [reschReason, setReschReason] = useState('');

  const [showCancel, setShowCancel] = useState(false);
  const [cancelReason, setCancelReason] = useState('Patient Declined');
  const [cancelRemarks, setCancelRemarks] = useState('');

  const refresh = useCallback(async () => {
    const result = await getSchedulingWorkspaceData(caseId);
    if (result.error) { setLoadError(result.error); return; }
    setData(result);
    if (result.case?.surgeon_id) setSurgeonId(result.case.surgeon_id);
  }, [caseId]);

  useEffect(() => {
    setData(null); setLoadError(''); setError(''); setOk(''); setSurgeonId('');
    refresh();
    getOTSessions().then(setSessions);
    getSurgeonOptions().then(setSurgeons);
  }, [caseId, refresh]);

  useEffect(() => {
    if (!sessionId || !date) { setCapacityInfo(null); return; }
    getSessionCapacity(date, sessionId).then((count) => {
      const session = sessions.find((s) => s.id === sessionId);
      setCapacityInfo({ count, capacity: session?.capacity || 0 });
    });
  }, [date, sessionId, sessions]);

  useEffect(() => {
    if (sessions.length > 0 && !sessionId) {
      setSessionId(sessions[0].id);
      setRoom(sessions[0].default_room || '');
    }
  }, [sessions, sessionId]);

  async function handleSchedule() {
    setError(''); setOk('');
    if (!surgeonId) { setError('Assign a surgeon before scheduling.'); return; }
    setSaving(true);
    const result = await scheduleSurgery(caseId, {
      date, sessionId, surgeonId, room, sequenceNumber: sequenceNumber ? parseInt(sequenceNumber, 10) : null, duration,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Surgery scheduled. Case moved to the Daily OT List for this date.');
    refresh();
    onUpdate();
  }

  async function handleReschedule() {
    setError('');
    if (!reschReason.trim()) { setError('A reschedule reason is required.'); return; }
    setSaving(true);
    const result = await rescheduleSurgery(data.existingBooking.id, { date: reschDate, sessionId: reschSessionId, reason: reschReason });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowReschedule(false);
    setOk('Rescheduled -- same booking preserved, history logged.');
    refresh();
    onUpdate();
  }

  async function handleCancel() {
    setError('');
    setSaving(true);
    const result = await cancelSurgery(data.existingBooking.id, caseId, { reason: cancelReason, remarks: cancelRemarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setShowCancel(false);
    onDone();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;

  const { case: sc, biometryPlans, existingBooking } = data;
  const patient = sc.patients;

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#0e7490,#0891b2)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0)}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 14, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name} -- {patient?.age} {patient?.gender}</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{patient?.uhid} -- {patient?.mobile} -- {sc.profiles?.full_name || 'No surgeon assigned'}</div>
        </div>
        <span className={`badge ${PRIORITY_BADGE[sc.priority] || 'b-gray'}`} style={{ fontSize: 11 }}>{sc.priority}</span>
      </div>

      {ok && <div className="msg-ok"><i className="ti ti-circle-check"></i><span>{ok}</span></div>}
      {error && <div className="msg-err"><i className="ti ti-x-circle"></i><span>{error}</span></div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-clipboard-list" style={{ color: 'var(--blue)' }}></i> Approved Surgical Plan (read-only)</div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Procedure</span><strong>{sc.procedure_name}</strong></div>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Eye</span><span className="badge b-blue" style={{ fontSize: 10 }}>{sc.eye}</span></div>
            {sc.master_packages && (
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ color: 'var(--g500)' }}><i className="ti ti-package"></i> Package</span>
                <strong style={{ color: 'var(--green)' }}>{sc.master_packages.name} -- Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</strong>
              </div>
            )}
            {biometryPlans.length === 0 && (
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>No approved IOL plan on record (non-IOL procedure, or Biometry not yet approved).</div>
            )}
            {biometryPlans.map((p) => (
              <div key={p.id} style={{ marginTop: 8, padding: 8, background: 'var(--g50)', borderRadius: 8 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--indigo)', marginBottom: 4 }}>{p.surgical_eye} -- Approved IOL Plan</div>
                <div style={{ fontSize: 11.5, fontFamily: 'monospace' }}>{p.final_iol_power} D -- {p.selected_formula} -- {p.final_iol_category}</div>
                {p.master_iol_catalog && <div style={{ fontSize: 11, color: 'var(--g500)' }}>{p.master_iol_catalog.brand} {p.master_iol_catalog.model}</div>}
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Changes to IOL plan require the Biometry module -- read-only here.</div>
          </div>

          <div className="card" style={{ marginBottom: 0 }}>
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-tool" style={{ color: 'var(--purple)' }}></i> Resource Check</div>
            <div className="rd-item done" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, marginBottom: 4, fontSize: 12, background: 'var(--green-lt)', color: 'var(--green)' }}>
              <i className="ti ti-circle-check"></i> Surgeon -- {sc.profiles?.full_name || 'Not assigned'}
            </div>
            <div className="rd-item" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, marginBottom: 4, fontSize: 12, background: biometryPlans.length > 0 || sc.eye === 'N/A' ? 'var(--green-lt)' : 'var(--amber-lt)', color: biometryPlans.length > 0 || sc.eye === 'N/A' ? 'var(--green)' : 'var(--amber)' }}>
              <i className={`ti ${biometryPlans.length > 0 ? 'ti-circle-check' : 'ti-alert-triangle'}`}></i> Approved IOL -- {biometryPlans.length > 0 ? `${biometryPlans.length} eye(s) ready` : 'None on record'}
            </div>
            <div className="rd-item done" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, fontSize: 12, background: 'var(--green-lt)', color: 'var(--green)' }}>
              <i className="ti ti-circle-check"></i> Medical Fitness -- Cleared
            </div>
          </div>
        </div>

        <div>
          {!existingBooking ? (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-calendar-event" style={{ color: 'var(--cyan)' }}></i> Schedule Surgery</div>
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Assign Surgeon</label>
                <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
                  <option value="">-- Select surgeon --</option>
                  {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}{s.code ? ` (${s.code})` : ''}</option>)}
                </select>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div><label className="flbl">Surgery Date</label><input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} /></div>
                <div>
                  <label className="flbl">Session</label>
                  <select className="fi fi-sm" value={sessionId} onChange={(e) => { setSessionId(e.target.value); const s = sessions.find((x) => x.id === e.target.value); setRoom(s?.default_room || ''); }}>
                    {sessions.map((s) => <option key={s.id} value={s.id}>{s.name} ({s.start_time?.slice(0, 5)}-{s.end_time?.slice(0, 5)})</option>)}
                  </select>
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div><label className="flbl">OT Room</label><input className="fi fi-sm" value={room} onChange={(e) => setRoom(e.target.value)} /></div>
                <div><label className="flbl">Sequence #</label><input type="number" min="1" className="fi fi-sm" value={sequenceNumber} onChange={(e) => setSequenceNumber(e.target.value)} placeholder="Auto if blank" /></div>
              </div>
              <div style={{ marginBottom: 8 }}>
                <label className="flbl">Expected Duration</label>
                <select className="fi fi-sm" value={duration} onChange={(e) => setDuration(parseInt(e.target.value, 10))}>
                  <option value={20}>20 min</option><option value={30}>30 min</option><option value={45}>45 min</option><option value={60}>60 min</option>
                </select>
              </div>
              {capacityInfo && (
                <div className={`msg-${capacityInfo.count >= capacityInfo.capacity ? 'warn' : 'info'}`} style={{ fontSize: 11, marginBottom: 8 }}>
                  <i className="ti ti-info-circle"></i>
                  {capacityInfo.count}/{capacityInfo.capacity} cases planned for this session
                  {capacityInfo.count >= capacityInfo.capacity && ' -- at capacity, scheduling will still go through but double-check with the OT coordinator.'}
                </div>
              )}
              <button className="btn btn-primary" style={{ width: '100%' }} onClick={handleSchedule} disabled={saving}>
                <i className="ti ti-calendar-check"></i> {saving ? 'Scheduling...' : 'Schedule Surgery'}
              </button>
            </div>
          ) : (
            <div className="card" style={{ marginBottom: 0 }}>
              <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-calendar-event" style={{ color: 'var(--cyan)' }}></i> Scheduled</div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Date</span><strong>{new Date(existingBooking.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Session</span><strong>{existingBooking.master_ot_sessions?.name}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Room</span><strong>{existingBooking.room || '--'}</strong></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>Status</span><span className="badge b-blue">{existingBooking.status}</span></div>
              {existingBooking.reschedule_count > 0 && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 6 }}>Rescheduled {existingBooking.reschedule_count}x</div>}

              <div style={{ display: 'flex', gap: 6, marginTop: 12, flexWrap: 'wrap' }}>
                {existingBooking.status === 'Scheduled' && (
                  <>
                    <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => { setReschDate(existingBooking.scheduled_date); setReschSessionId(existingBooking.session_id); setShowReschedule(true); }}>
                      <i className="ti ti-calendar-time"></i> Reschedule
                    </button>
                    <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={() => setShowCancel(true)}>
                      <i className="ti ti-x"></i> Cancel
                    </button>
                  </>
                )}
              </div>

              {showReschedule && (
                <div style={{ marginTop: 12, padding: 10, background: 'var(--amber-lt)', borderRadius: 8 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Reschedule</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                    <input type="date" className="fi fi-sm" value={reschDate} onChange={(e) => setReschDate(e.target.value)} />
                    <select className="fi fi-sm" value={reschSessionId} onChange={(e) => setReschSessionId(e.target.value)}>
                      {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                    </select>
                  </div>
                  <select className="fi fi-sm" value={reschReason} onChange={(e) => setReschReason(e.target.value)} style={{ marginBottom: 8 }}>
                    <option value="">-- Reason --</option>
                    <option>Patient Request</option><option>Surgeon Unavailable</option><option>Medical Issue</option>
                    <option>Equipment Failure</option><option>Emergency Case</option><option>Public Holiday</option>
                  </select>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={handleReschedule} disabled={saving}>Confirm</button>
                    <button className="btn btn-sm" onClick={() => setShowReschedule(false)}>Cancel</button>
                  </div>
                </div>
              )}

              {showCancel && (
                <div style={{ marginTop: 12, padding: 10, background: 'var(--red-lt)', borderRadius: 8 }}>
                  <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Cancel Surgery</div>
                  <select className="fi fi-sm" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} style={{ marginBottom: 8 }}>
                    <option>Patient Declined</option><option>Medical Contraindication</option><option>No-show</option>
                    <option>OT Breakdown</option><option>Lens Unavailable</option><option>Clinical Reassessment Required</option>
                  </select>
                  <textarea className="fi fi-sm" rows={2} placeholder="Remarks (optional)" value={cancelRemarks} onChange={(e) => setCancelRemarks(e.target.value)} style={{ marginBottom: 8 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', border: 'none' }} onClick={handleCancel} disabled={saving}>Confirm Cancellation</button>
                    <button className="btn btn-sm" onClick={() => setShowCancel(false)}>Close</button>
                  </div>
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

OT_WORKSPACE_EOF

cat > 'app/(main)/ot-schedule/daily-list-tab.js' << 'OT_DAILY_EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDailyOTList, getOTSessions, rescheduleSurgery } from './actions';

export default function DailyListTab() {
  const [date, setDate] = useState(new Date().toISOString().slice(0, 10));
  const [sessions, setSessions] = useState([]);
  const [sessionFilter, setSessionFilter] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const [reschedulingId, setReschedulingId] = useState(null);
  const [reschDate, setReschDate] = useState('');
  const [reschSessionId, setReschSessionId] = useState('');
  const [reschReason, setReschReason] = useState('');
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => { getOTSessions().then(setSessions); }, []);

  const refresh = useCallback(() => {
    setLoading(true);
    getDailyOTList(date, sessionFilter || undefined).then((r) => { setRows(r); setLoading(false); });
  }, [date, sessionFilter]);

  useEffect(() => { refresh(); }, [refresh]);

  function startReschedule(r) {
    setError('');
    setReschedulingId(r.id);
    setReschDate(r.scheduled_date);
    setReschSessionId(r.session_id);
    setReschReason('');
  }

  async function confirmReschedule() {
    setError('');
    if (!reschReason.trim()) { setError('A reschedule reason is required.'); return; }
    setSaving(true);
    const result = await rescheduleSurgery(reschedulingId, { date: reschDate, sessionId: reschSessionId, reason: reschReason });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setReschedulingId(null);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-list-details" style={{ color: 'var(--cyan)' }}></i> Daily OT List</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <input type="date" className="fi fi-sm" value={date} onChange={(e) => setDate(e.target.value)} style={{ width: 150 }} />
          <select className="fi fi-sm" value={sessionFilter} onChange={(e) => setSessionFilter(e.target.value)} style={{ width: 140 }}>
            <option value="">All sessions</option>
            {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
          </select>
          <button className="btn btn-sm" onClick={() => window.print()}><i className="ti ti-printer"></i> Print</button>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && rows.map((r, i) => (
        <div key={r.id} style={{ borderBottom: '1px solid var(--g100)' }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 12px' }}>
            <div style={{ width: 24, height: 24, borderRadius: '50%', background: 'var(--cyan)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
              {r.sequence_number || i + 1}
            </div>
            <div style={{ flex: 1 }}>
              <div style={{ fontSize: 13, fontWeight: 700 }}>
                {r.surgical_cases?.patients?.first_name} {r.surgical_cases?.patients?.last_name}
                <span className="badge b-cyan" style={{ marginLeft: 6, fontSize: 10 }}>{r.master_ot_sessions?.name}</span>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {r.surgical_cases?.procedure_name} -- {r.surgical_cases?.eye} -- {r.profiles?.full_name || 'No surgeon'}
              </div>
              {r.surgical_cases?.master_packages && (
                <div style={{ fontSize: 11, color: 'var(--green)', marginTop: 1 }}>
                  <i className="ti ti-package"></i> {r.surgical_cases.master_packages.name}
                </div>
              )}
              {r.iolPlans.length > 0 && (
                <div style={{ fontSize: 11, color: 'var(--g600)', marginTop: 1, fontFamily: 'monospace' }}>
                  IOL: {r.iolPlans.map((p) => `${p.surgical_eye} ${p.final_iol_power}D`).join(', ')}
                </div>
              )}
              {r.reschedule_count > 0 && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 1 }}>Rescheduled {r.reschedule_count}x</div>}
            </div>
            <span className={`badge ${r.status === 'Completed' ? 'b-green' : 'b-blue'}`} style={{ fontSize: 10 }}>{r.status}</span>
            {r.status === 'Scheduled' && (
              <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={() => startReschedule(r)}>
                <i className="ti ti-calendar-time"></i> Reschedule
              </button>
            )}
          </div>

          {reschedulingId === r.id && (
            <div style={{ margin: '0 12px 10px', padding: 10, background: 'var(--amber-lt)', borderRadius: 8 }}>
              {error && <div className="msg-err" style={{ fontSize: 11, marginBottom: 6 }}>{error}</div>}
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <input type="date" className="fi fi-sm" value={reschDate} onChange={(e) => setReschDate(e.target.value)} />
                <select className="fi fi-sm" value={reschSessionId} onChange={(e) => setReschSessionId(e.target.value)}>
                  {sessions.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                </select>
              </div>
              <select className="fi fi-sm" value={reschReason} onChange={(e) => setReschReason(e.target.value)} style={{ marginBottom: 8, width: '100%' }}>
                <option value="">-- Reason --</option>
                <option>Patient Request</option><option>Surgeon Unavailable</option><option>Medical Issue</option>
                <option>Equipment Failure</option><option>Emergency Case</option><option>Public Holiday</option>
              </select>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={confirmReschedule} disabled={saving}>{saving ? 'Saving...' : 'Confirm'}</button>
                <button className="btn btn-sm" onClick={() => setReschedulingId(null)}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      ))}

      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>No surgeries scheduled for this date{sessionFilter ? '/session' : ''}.</div>
      )}
    </div>
  );
}


OT_DAILY_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/(main)/ot-schedule/workspace-tab.js" "app/(main)/ot-schedule/daily-list-tab.js"'
echo '  git commit -m "OT Scheduling: remove manual Mark Completed, add Reschedule to Daily OT List"'
echo '  git push'
