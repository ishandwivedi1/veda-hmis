'use client';

import { useState, useEffect } from 'react';
import { openPopup } from '@/lib/popup';
import { getPatientTimeline } from '@/app/(main)/patient-timeline/actions';

const VISIT_OUTCOMES = [
  'Continue Follow-up', 'Surgery Advised', 'Proceed to Pre-operative Consultation',
  'Surgery Planned', 'Referred', 'Admitted', 'Discharged',
];

function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function visionStr(v) {
  if (!v) return '--';
  return `RE ${v.re || '--'} / LE ${v.le || '--'}`;
}

function iopStr(iop) {
  if (!iop) return '--';
  return `RE ${iop.re ?? '--'} / LE ${iop.le ?? '--'} mmHg`;
}

// ── Patient Snapshot (top panel, always visible for a Follow-up encounter) ──
export function PatientSnapshotBar({ snapshot }) {
  if (!snapshot) return null;
  if (snapshot.noCompletedPriorVisit) {
    return (
      <div className="card" style={{ marginBottom: 16, background: 'var(--amber-lt)', border: '1px solid #fcd34d' }}>
        <div style={{ fontSize: 12, color: 'var(--amber)' }}>
          <i className="ti ti-info-circle"></i> This patient has prior visits, but none were ever finalized -- no completed clinical record to summarize yet.
        </div>
      </div>
    );
  }
  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--blue-lt)', border: '1px solid #93c5fd' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Patient Snapshot -- Follow-up Visit
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10 }}>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Diagnosis</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentDiagnoses.length > 0 ? snapshot.currentDiagnoses.map((d) => d.name).join(', ') : 'None on record'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Surgery Status</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.surgicalStatus ? `${snapshot.surgicalStatus.procedure_name} -- ${snapshot.surgicalStatus.status}` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Current Medications</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{snapshot.currentMedications.length > 0 ? `${snapshot.currentMedications.length} active` : 'None'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Drug Allergies</div>
          <div style={{ fontSize: 12.5, fontWeight: 600, color: snapshot.allergy ? 'var(--red)' : 'inherit' }}>{snapshot.allergy || 'None recorded'}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Visit</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{fmtDate(snapshot.lastVisitDate)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last Vision</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{visionStr(snapshot.lastVision)}</div>
        </div>
        <div>
          <div style={{ fontSize: 10, color: 'var(--g500)', textTransform: 'uppercase' }}>Last IOP</div>
          <div style={{ fontSize: 12.5, fontWeight: 600 }}>{iopStr(snapshot.lastIop)}</div>
        </div>
      </div>
    </div>
  );
}

// ── Previous visits, shown as an in-flow horizontal strip at the top of
// the workspace (not floating -- sits inside the consultation content,
// same as everything else). ──
export function PatientTimelineSidebar({ timeline }) {
  return (
    <div className="card" style={{ marginBottom: 16, borderLeft: '4px solid var(--indigo)' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--indigo)', textTransform: 'uppercase', marginBottom: 10, display: 'flex', alignItems: 'center', gap: 6 }}>
        <i className="ti ti-history"></i> Previous Visits
      </div>
      {timeline.length === 0 ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>No prior visits.</div>
      ) : (
        <div style={{ display: 'flex', gap: 10, overflowX: 'auto', paddingBottom: 4 }}>
          {timeline.map((t) => {
            const clickable = !!t.queueEntryId;
            return (
              <div
                key={t.encounterId}
                onClick={clickable ? () => window.open(`/consultation/${t.queueEntryId}`, '_blank', 'noopener,noreferrer') : undefined}
                style={{ minWidth: 160, flexShrink: 0, padding: '10px 12px', borderRadius: 10, border: '1.5px solid var(--indigo)', cursor: clickable ? 'pointer' : 'default', background: 'var(--indigo-lt)' }}
              >
                <div style={{ fontSize: 12, fontWeight: 800, color: 'var(--indigo)' }}>{fmtDate(t.date)}</div>
                <div style={{ fontSize: 11.5, color: 'var(--g700)', marginTop: 2 }}>{t.chiefComplaint || 'Consultation'}</div>
                {t.status !== 'Completed' && <div style={{ fontSize: 10, color: 'var(--amber)', marginTop: 4, fontWeight: 600 }}>Not finalized -- {t.status}</div>}
                {clickable && <div style={{ fontSize: 10.5, color: 'var(--indigo)', marginTop: 4, fontWeight: 700 }}><i className="ti ti-eye"></i> {t.status === 'Completed' ? 'View read-only' : 'Open'}</div>}
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ── Previous Visit Summary (read-only card) ──
export function PreviousVisitSummary({ summary }) {
  if (!summary) return null;
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-file-text" style={{ color: 'var(--g500)' }}></i> Previous Visit Summary -- {fmtDate(summary.date)}</div>
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, fontSize: 12.5 }}>
        <div><span style={{ color: 'var(--g500)' }}>Vision: </span>{visionStr(summary.vision)}</div>
        <div><span style={{ color: 'var(--g500)' }}>IOP: </span>{iopStr(summary.iop)}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Diagnosis: </span>{summary.diagnoses.length > 0 ? summary.diagnoses.map((d) => d.name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Medications: </span>{summary.medications.length > 0 ? summary.medications.map((m) => m.drug_name).join(', ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Advice: </span>{summary.advice.length > 0 ? summary.advice.map((a) => a.text || a.advice_text || a.note).filter(Boolean).join('; ') : '--'}</div>
        <div style={{ gridColumn: 'span 2' }}><span style={{ color: 'var(--g500)' }}>Follow-up Plan: </span>{summary.followupPlan?.instructions || summary.followupPlan?.notes || '--'}</div>
      </div>
    </div>
  );
}

// Same mapping as the standalone Patient Timeline module -- kept
// identical across both so an event type reads as the same color
// everywhere in the app, not just within this sidebar.
const EVENT_ICON = { Visit: 'ti-door-enter', Diagnosis: 'ti-clipboard-list', Investigation: 'ti-flask', Prescription: 'ti-pill', Surgery: 'ti-scalpel' };
const EVENT_COLOR = { Visit: 'var(--indigo)', Diagnosis: 'var(--blue)', Investigation: 'var(--teal)', Prescription: 'var(--purple)', Surgery: 'var(--red)' };

function EventTypeChip({ type }) {
  const color = EVENT_COLOR[type] || 'var(--g500)';
  return (
    <span style={{ display: 'inline-flex', alignItems: 'center', gap: 4, padding: '2px 7px', borderRadius: 999, background: `${color}1a`, color, fontSize: 9.5, fontWeight: 800, textTransform: 'uppercase', letterSpacing: '.3px' }}>
      <i className={`ti ${EVENT_ICON[type] || 'ti-point'}`} style={{ fontSize: 10 }}></i> {type}
    </span>
  );
}

function elapsedMin(iso) {
  return Math.max(0, Math.round((Date.now() - new Date(iso).getTime()) / 60000));
}

// ── Context sidebar -- lives alongside the workspace. Combines patient
//    history (previous visit, timeline, past investigations) with this
//    encounter's own status/tasks/audit log, all in one column so the
//    main workspace gets the full remaining width. ──
export function ContextSidebar({ patientId, previousVisitSummary, encounter, auditLog, openInvestigations, activeWorkflows, pendingRx, wfItems }) {
  const [showSummary, setShowSummary] = useState(false);
  const [events, setEvents] = useState(null);

  useEffect(() => {
    if (!patientId) return;
    let cancelled = false;
    getPatientTimeline(patientId).then((r) => { if (!cancelled) setEvents(r.events || []); });
    return () => { cancelled = true; };
  }, [patientId]);

  const investigations = (events || []).filter((e) => e.type === 'Investigation');

  return (
    <div>
      <button
        className="btn"
        style={{ width: '100%', justifyContent: 'center', marginBottom: 16 }}
        onClick={() => setShowSummary(true)}
        disabled={!previousVisitSummary}
        title={previousVisitSummary ? '' : 'No previous visit on record'}
      >
        <i className="ti ti-file-text"></i> Previous Visit Summary
      </button>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-timeline" style={{ color: 'var(--indigo)' }}></i> Patient Timeline</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && events.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No prior history.</div>}
        {events && events.length > 0 && (
          <div style={{ maxHeight: 300, overflowY: 'auto' }}>
            {events.slice(0, 25).map((e, idx) => {
              const clickable = (e.type === 'Visit' && !!e.queueEntryId) || (e.type === 'Investigation' && !!e.id);
              function handleClick() {
                if (e.type === 'Visit' && e.queueEntryId) window.open(`/consultation/${e.queueEntryId}`, '_blank', 'noopener,noreferrer');
                else if (e.type === 'Investigation' && e.id) openPopup(`/investigation/${e.id}?mode=view`, `inv-${e.id}`);
              }
              return (
                <div
                  key={idx}
                  onClick={clickable ? handleClick : undefined}
                  style={{ padding: '8px 4px', borderBottom: '1px solid var(--g100)', cursor: clickable ? 'pointer' : 'default', borderRadius: 6 }}
                  onMouseEnter={clickable ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
                  onMouseLeave={clickable ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
                >
                  <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                    <EventTypeChip type={e.type} />
                    <span style={{ marginLeft: 'auto', color: 'var(--g400)', fontSize: 10 }}>{fmtDate(e.date)}</span>
                    {clickable && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR[e.type], fontSize: 12 }}></i>}
                  </div>
                  <div style={{ fontSize: 11.5, fontWeight: 600, marginTop: 4 }}>{e.title}</div>
                  <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
                </div>
              );
            })}
          </div>
        )}
        <a href={patientId ? `/patient-timeline?patientId=${patientId}` : '/patient-timeline'} target="_blank" rel="noopener noreferrer" style={{ fontSize: 10.5, color: 'var(--blue)', display: 'inline-flex', alignItems: 'center', gap: 4, marginTop: 8 }}>
          <i className="ti ti-external-link"></i> Open full timeline
        </a>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Previous Investigations</div>
        {events === null && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Loading...</div>}
        {events && investigations.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>None on record.</div>}
        {investigations.slice(0, 15).map((e, idx) => (
          <div
            key={idx}
            onClick={e.id ? () => openPopup(`/investigation/${e.id}?mode=view`, `inv-${e.id}`) : undefined}
            style={{ padding: '7px 4px', borderBottom: '1px solid var(--g100)', cursor: e.id ? 'pointer' : 'default', borderRadius: 6 }}
            onMouseEnter={e.id ? (ev) => { ev.currentTarget.style.background = 'var(--g50)'; } : undefined}
            onMouseLeave={e.id ? (ev) => { ev.currentTarget.style.background = 'transparent'; } : undefined}
          >
            <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
              <span style={{ fontSize: 11.5, fontWeight: 600, flex: 1 }}>{e.title}</span>
              <span className="badge" style={{ background: `${EVENT_COLOR.Investigation}1a`, color: EVENT_COLOR.Investigation, fontSize: 9 }}>{e.status || '--'}</span>
              {e.id && <i className="ti ti-chevron-right" style={{ color: EVENT_COLOR.Investigation, fontSize: 12 }}></i>}
            </div>
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>{e.detail}</div>
            <div style={{ fontSize: 10, color: 'var(--g400)' }}>{fmtDate(e.date)}</div>
          </div>
        ))}
      </div>

      {encounter && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Encounter Status</div>
          <div style={{ fontSize: 11.5, color: 'var(--g600)', lineHeight: 1.9 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Status</span><span className="badge b-blue">{encounter.status}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(encounter.started_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</span></div>
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>In progress</span><span style={{ fontWeight: 700 }}>{elapsedMin(encounter.started_at)}m</span></div>
          </div>
        </div>
      )}

      {(openInvestigations || activeWorkflows || pendingRx) && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-list-checks" style={{ color: 'var(--amber)' }}></i> Outstanding Tasks</div>
          {(openInvestigations || []).length === 0 && (activeWorkflows || []).length === 0 && (pendingRx || []).length === 0 && (
            <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Nothing outstanding.</div>
          )}
          {(openInvestigations || []).map((i) => (
            <div key={i.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i><span style={{ flex: 1 }}>{i.name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{i.status}</span>
            </div>
          ))}
          {(activeWorkflows || []).map((w) => (
            <div key={w.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className={`ti ${wfItems?.[w.kind]?.icon || 'ti-clipboard'}`} style={{ color: 'var(--amber)' }}></i><span style={{ flex: 1 }}>{w.kind}</span><span className="badge b-amber" style={{ fontSize: 9 }}>Requested</span>
            </div>
          ))}
          {(pendingRx || []).map((r) => (
            <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 6, padding: '5px 0', fontSize: 11 }}>
              <i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i><span style={{ flex: 1 }}>{r.drug_name}</span><span className="badge b-amber" style={{ fontSize: 9 }}>{r.status}</span>
            </div>
          ))}
        </div>
      )}

      {auditLog && (
        <div className="card" style={{ marginTop: 16 }}>
          <div className="card-title" style={{ marginBottom: 10, fontSize: 12.5 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
          <div style={{ maxHeight: 240, overflowY: 'auto' }}>
            {auditLog.length === 0 && <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>No activity yet.</div>}
            {auditLog.map((a) => (
              <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
                <div>{a.message}</div>
              </div>
            ))}
          </div>
        </div>
      )}

      {showSummary && previousVisitSummary && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={() => setShowSummary(false)}>
          <div style={{ width: 480, maxHeight: '80vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <PreviousVisitSummary summary={previousVisitSummary} />
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setShowSummary(false)}>Close</button>
          </div>
        </div>
      )}
    </div>
  );
}

// ── Carry Forward: bring an unresolved diagnosis from the last visit
// into this one, without silently duplicating it -- doctor picks. ──
export function CarryForwardDiagnoses({ priorDiagnoses, alreadyAdded, onCarryForward }) {
  const available = priorDiagnoses.filter((pd) => !alreadyAdded.some((d) => d.name === pd.name && d.eye === pd.eye));
  if (available.length === 0) return null;
  return (
    <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Carry forward from last visit</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
        {available.map((pd) => (
          <button key={pd.id} className="btn btn-sm" onClick={() => onCarryForward(pd)}>
            <i className="ti ti-plus"></i> {pd.name} ({pd.eye})
          </button>
        ))}
      </div>
    </div>
  );
}

// ── New investigations since the last visit, with results ready ──
export function NewInvestigationsSinceLastVisit({ investigations, matchInvestigationType, summarizeResultData }) {
  if (!investigations || investigations.length === 0) return null;
  return (
    <div style={{ background: 'var(--teal-lt)', borderRadius: 8, padding: 10, marginBottom: 12 }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--teal)', marginBottom: 6 }}>
        <i className="ti ti-flask"></i> New since last visit -- {investigations.length} result{investigations.length > 1 ? 's' : ''} ready
      </div>
      {investigations.map((i) => {
        const type = matchInvestigationType(i.name);
        return (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', fontSize: 12.5 }}>
            <span><strong>{i.name}</strong> -- {i.eye} -- <span style={{ color: 'var(--g500)' }}>{summarizeResultData(type, i.result_data)}</span></span>
            <button className="btn btn-sm" onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
              <i className="ti ti-eye"></i> View
            </button>
          </div>
        );
      })}
    </div>
  );
}

// ── Visit Outcome selector ──
export function VisitOutcomeSelector({ value, onChange, disabled }) {
  return (
    <div className="card" style={{ marginBottom: 20 }}>
      <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-flag" style={{ color: 'var(--purple)' }}></i> Visit Outcome</div>
      <select className="fi" value={value || ''} onChange={(e) => onChange(e.target.value)} disabled={disabled}>
        <option value="">-- Select outcome --</option>
        {VISIT_OUTCOMES.map((o) => <option key={o} value={o}>{o}</option>)}
      </select>
    </div>
  );
}

