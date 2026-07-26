#!/bin/bash
set -e

echo "== Fix sticky header jankiness + Pre-op Required field =="
echo "   1. Back button now lives inside the frozen header itself, so it"
echo "      no longer scrolls separately before the header locks in place"
echo "   2. Added Pre-op Required (None/Biometry/Medical Fitness/Both) to"
echo "      Mark for Surgery -- carried forward to Counselling, which now"
echo "      respects it the same way it already respects biometry_required"
echo "   (bundles the context-sidebar/facelift work too, in case not applied yet)"

echo "-- Writing app/(main)/consultation/[id]/follow-up-panel.js --"
mkdir -p "$(dirname "app/(main)/consultation/[id]/follow-up-panel.js")"
cat > "app/(main)/consultation/[id]/follow-up-panel.js" << 'JSEOF_71480991'
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
  return new Date(d).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' });
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
            <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Started</span><span>{new Date(encounter.started_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}</span></div>
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
                <div style={{ color: 'var(--teal)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</div>
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

JSEOF_71480991

echo "-- Writing app/(main)/consultation/[id]/consultation-form.js --"
mkdir -p "$(dirname "app/(main)/consultation/[id]/consultation-form.js")"
cat > "app/(main)/consultation/[id]/consultation-form.js" << 'JSEOF_68892697'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  updateDiagnosisNotes,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
  sendForBiometryFromConsultation,
  adviseBiometry,
  updateBiometryInstructions,
  removeBiometryRecord,
  completeWorkflowRequest,
  addOpticalAdvice,
  removeOpticalAdvice,
  addProcedure,
  removeProcedure,
  addReferral,
  removeReferral,
  addCounsellingItem,
  removeCounsellingItem,
  completePlanItem,
  saveFollowup,
  savePatientInstructions,
  saveDraft,
  getFollowUpContext,
  saveVisitOutcome,
  carryForwardDiagnosis,
} from '@/app/(main)/consultation/actions';
import { openPopup } from '@/lib/popup';
import { markForSurgery, updateSurgicalCase } from '@/app/(main)/counselling/actions';
import { getDiagnosesMaster, getDrugs, getServices, getProcedures, getSurgeries } from '@/app/(main)/master-data/actions';
import ExaminationTab from './examination-tab';
import HistoryTab from './history-tab';
import OptometryTab from './optometry-tab';
import { matchInvestigationType, summarizeResultData } from '@/app/(main)/investigation/investigation-types';
import { PatientSnapshotBar, CarryForwardDiagnoses, VisitOutcomeSelector, NewInvestigationsSinceLastVisit, ContextSidebar } from './follow-up-panel';

const WF_ITEMS = {
  Biometry: { icon: 'ti-ruler-measure', color: '#818cf8' },
  'Medical Fitness': { icon: 'ti-heart-rate-monitor', color: '#c4b5fd' },
  Counselling: { icon: 'ti-messages', color: '#fcd34d' },
};

const INV_STATUS_BADGE = { Ordered: 'b-gray', 'In Progress': 'b-blue', Completed: 'b-teal', Available: 'b-purple', Cancelled: 'b-red' };

function DiagnosisRow({ d, index, encounterId, onRemove }) {
  const [notes, setNotes] = useState(d.notes || '');
  const [saved, setSaved] = useState(true);

  async function handleBlur() {
    if (notes === (d.notes || '')) return;
    await updateDiagnosisNotes(d.id, notes);
    setSaved(true);
  }

  return (
    <div style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
        <span>
          <span style={{ color: 'var(--g400)', fontWeight: 700, marginRight: 4 }}>{index + 1}.</span>
          <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
        </span>
        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={onRemove}>Remove</button>
      </div>
      <input
        className="fi fi-sm"
        style={{ marginTop: 5, marginLeft: 18, width: 'calc(100% - 18px)' }}
        placeholder="Doctor notes for this diagnosis (optional)"
        value={notes}
        onChange={(e) => { setNotes(e.target.value); setSaved(false); }}
        onBlur={handleBlur}
      />
      {!saved && <div style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 18, marginTop: 2 }}>Unsaved -- click away to save</div>}
    </div>
  );
}

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={onClick}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// Section group divider for Diagnosis & Plan -- numbered circle badge,
// same visual language as the numbered sections in Optometry Assessment,
// so the two clinical screens feel consistent.
function GroupHeader({ num, color, title }) {
  return (
    <div style={{ display: 'flex', alignItems: 'center', gap: 10, margin: '4px 0 12px' }}>
      <span style={{ width: 24, height: 24, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 12, fontWeight: 700, flexShrink: 0 }}>{num}</span>
      <span style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)' }}>{title}</span>
      <div style={{ flex: 1, height: 1, background: 'var(--g200)' }}></div>
    </div>
  );
}

export default function ConsultationForm({ queueEntryId, hideHistoryTracker = false, onBack, backLabel = 'Dashboard' }) {
  const [data, setData] = useState(null);
  const [followUpContext, setFollowUpContext] = useState(null);
  const [visitOutcome, setVisitOutcome] = useState('');
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryPreOp, setSurgeryPreOp] = useState('Both');
  const [editingSurgicalCaseId, setEditingSurgicalCaseId] = useState(null);
  const [editSurgeryProcedure, setEditSurgeryProcedure] = useState('');
  const [editSurgeryEye, setEditSurgeryEye] = useState('OU');
  const [editSurgeryPreOp, setEditSurgeryPreOp] = useState('Both');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState(hideHistoryTracker ? 'optometry' : 'history');
  const [unlocked, setUnlocked] = useState(false);
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');
  const [bioEye, setBioEye] = useState('');
  const [bioInstructions, setBioInstructions] = useState('');
  const [editingBioId, setEditingBioId] = useState(null);
  const [editBioInstructions, setEditBioInstructions] = useState('');

  // Management Plan expansion forms
  const [optText, setOptText] = useState('');
  const [procName, setProcName] = useState('');
  const [procEye, setProcEye] = useState('OD');
  const [refDest, setRefDest] = useState('');
  const [refReason, setRefReason] = useState('');
  const [counselTopic, setCounselTopic] = useState('');
  const [fuAfter, setFuAfter] = useState('1 week');
  const [fuType, setFuType] = useState('Routine');
  const [fuClinic, setFuClinic] = useState('General');
  const [fuInstructions, setFuInstructions] = useState('');
  const [fuSaved, setFuSaved] = useState(false);
  const [patientInstructions, setPatientInstructions] = useState('');
  const [instructionsSaved, setInstructionsSaved] = useState(false);

  // Master Data options for the Diagnosis/Prescription/Investigation
  // dropdowns -- fetched once on mount, not re-fetched on every add/remove.
  const [diagnosisOptions, setDiagnosisOptions] = useState([]);
  const [drugOptions, setDrugOptions] = useState([]);
  const [investigationOptions, setInvestigationOptions] = useState([]);
  const [procedureOptions, setProcedureOptions] = useState([]);
  const [surgeryOptions, setSurgeryOptions] = useState([]);

  useEffect(() => {
    (async () => {
      const [dx, dr, sv, pr, sg] = await Promise.all([getDiagnosesMaster(), getDrugs(), getServices(), getProcedures(), getSurgeries()]);
      setDiagnosisOptions(dx.filter((d) => d.status === 'Active'));
      setDrugOptions(dr.filter((d) => d.status === 'Active'));
      // Biometry stays in Financial Masters for billing purposes only --
      // excluded here since clinical biometry has its own dedicated
      // workflow, now triggered from Counselling (M22) rather than here.
      // Substring match, not exact -- the catalog entry is named
      // "Biometry (Procedure Charge)", not literally "Biometry".
      setInvestigationOptions(sv.filter((s) => s.status === 'Active' && s.dept === 'Investigation' && !s.name.toLowerCase().includes('biometry')));
      setProcedureOptions(pr.filter((p) => p.status === 'Active'));
      setSurgeryOptions(sg.filter((s) => s.status === 'Active'));
    })();
  }, []);

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  useEffect(() => {
    if (!data) return;
    setPatientInstructions(data.encounter.patient_instructions || '');
    setVisitOutcome(data.encounter.visit_outcome || '');
    if (data.isFollowUp && !followUpContext) {
      getFollowUpContext(data.entry.visits.patients.id, data.entry.visits.id, data.encounter.id).then(setFollowUpContext);
    }
    if (data.followup) {
      setFuAfter(data.followup.after_period);
      setFuType(data.followup.visit_type);
      setFuClinic(data.followup.clinic);
      setFuInstructions(data.followup.instructions || '');
      setFuSaved(true);
    }
    if (data.biometryRecords && data.biometryRecords.length > 0) {
      const first = data.biometryRecords[0];
      setBioEye(data.biometryRecords.length === 2 ? 'Both' : (first.surgical_eye || ''));
      setBioInstructions(first.doctor_instructions || '');
    }
  }, [data]);

  async function handleAdviseBiometry() {
    setError('');
    if (!bioEye) { setError('Select which eye Biometry is required for.'); return; }
    const result = await adviseBiometry(data.entry.visits.id, data.encounter.id, bioEye, bioInstructions);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  function startEditBioInstructions(record) {
    setEditingBioId(record.id);
    setEditBioInstructions(record.doctor_instructions || '');
  }

  async function saveBioInstructions(id) {
    await updateBiometryInstructions(id, editBioInstructions);
    setEditingBioId(null);
    refresh();
  }

  async function handleRemoveBiometry(id) {
    setError('');
    const result = await removeBiometryRecord(id, data.encounter.id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleVisitOutcomeChange(outcome) {
    setVisitOutcome(outcome);
    await saveVisitOutcome(data.encounter.id, outcome);
  }

  async function handleCarryForward(priorDiagnosis) {
    setError('');
    const result = await carryForwardDiagnosis(data.encounter.id, priorDiagnosis);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleAddOptical() {
    setError('');
    if (!optText.trim()) { setError('Optical advice text is required.'); return; }
    const result = await addOpticalAdvice(data.encounter.id, optText);
    if (result.error) { setError(result.error); return; }
    setOptText('');
    refresh();
  }

  async function handleAddProcedure() {
    setError('');
    if (!procName) { setError('Select a procedure.'); return; }
    const result = await addProcedure(data.encounter.id, procName, procEye);
    if (result.error) { setError(result.error); return; }
    setProcName('');
    refresh();
  }

  async function handleAddReferral() {
    setError('');
    if (!refDest) { setError('Referral destination is required.'); return; }
    const result = await addReferral(data.encounter.id, refDest, refReason);
    if (result.error) { setError(result.error); return; }
    setRefDest('');
    setRefReason('');
    refresh();
  }

  async function handleAddCounsel() {
    setError('');
    if (!counselTopic.trim()) { setError('Counselling topic is required.'); return; }
    const result = await addCounsellingItem(data.encounter.id, counselTopic);
    if (result.error) { setError(result.error); return; }
    setCounselTopic('');
    refresh();
  }

  async function handleSaveFollowup() {
    setError('');
    const result = await saveFollowup(data.encounter.id, { after: fuAfter, type: fuType, clinic: fuClinic, instructions: fuInstructions });
    if (result.error) { setError(result.error); return; }
    setFuSaved(true);
    refresh();
  }

  async function handleSaveInstructions() {
    setError('');
    const result = await savePatientInstructions(data.encounter.id, patientInstructions);
    if (result.error) { setError(result.error); return; }
    setInstructionsSaved(true);
    setTimeout(() => setInstructionsSaved(false), 2000);
  }

  async function handleCompletePlanItem(table, id) {
    await completePlanItem(table, id, data.encounter.id);
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye, surgeryPreOp);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
    refresh();
  }

  function startEditSurgicalCase(sc) {
    setError('');
    setEditingSurgicalCaseId(sc.id);
    setEditSurgeryProcedure(sc.procedure_name);
    setEditSurgeryEye(sc.eye);
    setEditSurgeryPreOp(sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None');
  }

  async function handleUpdateSurgicalCase() {
    setError('');
    if (!editSurgeryProcedure) { setError('Select a surgery.'); return; }
    setSurgeryLoading(true);
    const result = await updateSurgicalCase(editingSurgicalCaseId, editSurgeryProcedure, editSurgeryEye, editSurgeryPreOp);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setEditingSurgicalCaseId(null);
    refresh();
  }

  async function handleSendOut(kind) {
    setError('');
    if (kind === 'biometry' && !bioEye) { setError('Select which eye Biometry is required for before sending.'); return; }
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId, data.encounter.id)
      : kind === 'biometry'
      ? await sendForBiometryFromConsultation(queueEntryId, data.encounter.id, bioEye, bioInstructions)
      : await sendForInvestigationFromConsultation(queueEntryId, data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    // Biometry stays on the page -- a doctor may still need to add
    // diagnoses, order investigations, etc. in the same sitting. Dilation
    // and Investigation keep the existing "done with this patient for
    // now" behavior since that wasn't something you flagged.
    if (kind === 'biometry') { refresh(); return; }
    router.push('/queue');
  }

  async function handleSaveDraft() {
    setError('');
    setLoading(true);
    const result = await saveDraft(data.encounter.id);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleCompleteWorkflow(id) {
    await completeWorkflowRequest(id, data.encounter.id);
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const activeWorkflows = data.workflowRequests.filter((w) => w.status === 'Requested');
  const openInvestigations = data.investigations.filter((i) => i.status !== 'Available' && i.status !== 'Cancelled');
  const pendingRx = data.prescriptions.filter((r) => r.status !== 'Dispensed');

  // ── ACTION TRACKER: every downstream action generated this
  // encounter, in one checklist -- prescriptions, investigations,
  // workflow requests.
  const trackerRows = [
    ...data.prescriptions.map((r) => ({ label: `${r.drug_name} (${r.eye})`, dept: 'Pharmacy', status: r.status, icon: 'ti-pill', color: 'var(--purple)' })),
    ...data.investigations.map((i) => ({ label: `${i.name} (${i.eye})`, dept: 'Investigation', status: i.status, icon: 'ti-flask', color: 'var(--teal)' })),
    ...data.workflowRequests.map((w) => ({
      label: w.kind, dept: w.kind === 'Counselling' ? 'Counsellor' : w.kind === 'Medical Fitness' ? 'Pre-op Fitness' : 'Biometry', status: w.status, icon: WF_ITEMS[w.kind]?.icon || 'ti-clipboard', color: 'var(--amber)', wfId: w.id, resolvable: w.status === 'Requested',
    })),
    ...data.opticalAdvice.map((o) => ({ label: o.advice, dept: 'Optical', status: o.status, icon: 'ti-glasses', color: 'var(--indigo)', planTable: 'plan_optical_advice', planId: o.id, resolvable: o.status === 'Planned' })),
    ...data.procedures.map((p) => ({ label: `${p.name} (${p.eye || '--'})`, dept: 'Procedure', status: p.status, icon: 'ti-tool', color: 'var(--blue)', planTable: 'plan_procedures', planId: p.id, resolvable: p.status === 'Planned' })),
    ...data.referrals.map((r) => ({ label: r.destination, dept: 'Referral', status: r.status, icon: 'ti-arrow-right-circle', color: 'var(--amber)', planTable: 'plan_referrals', planId: r.id, resolvable: r.status === 'Planned' })),
    ...data.counsellingItems.map((c) => ({ label: c.topic, dept: 'Counsellor', status: c.status, icon: 'ti-messages', color: 'var(--teal)', planTable: 'plan_counselling_items', planId: c.id, resolvable: c.status === 'Pending' })),
  ];

  const isReadOnly = data.isLocked && !unlocked;
  // Already routed to the technician if the current queue status
  // mentions Biometry (including compound statuses like "Awaiting
  // Investigation & Biometry" -- see doctorSendOut).
  const bioSent = data.entry?.status?.includes('Biometry') || false;

  return (
    <div style={{ maxWidth: 1440, margin: '0 auto' }}>
      {/* STICKY HEADER + TABS -- frozen at the top of the scroll area so
          the patient's identity and which tab you're on never scroll out
          of view, no matter how long the tab's content gets. */}
      <div style={{ position: 'sticky', top: 0, zIndex: 20, background: 'var(--g50)', paddingBottom: 10, marginBottom: 6 }}>
        {onBack && (
          <button className="btn btn-sm" style={{ marginBottom: 10 }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> {backLabel}
          </button>
        )}
        <div style={{
          background: 'linear-gradient(135deg, var(--blue-dk), var(--blue))', borderRadius: 'var(--r-lg)',
          padding: '14px 20px', color: '#fff', boxShadow: 'var(--shadow-md)', marginBottom: 12,
          display: 'flex', alignItems: 'center', gap: 16,
        }}>
          <div style={{
            width: 44, height: 44, borderRadius: '50%', background: 'rgba(255,255,255,.18)',
            display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 18, fontWeight: 800, flexShrink: 0,
            fontFamily: 'var(--font-display-stack)',
          }}>
            {patient.first_name?.charAt(0)?.toUpperCase()}
          </div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'var(--font-display-stack)', display: 'flex', alignItems: 'center', gap: 10 }}>
              {patient.first_name} {patient.last_name}
              {data.isFollowUp && <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontSize: 10.5 }}>Follow-up Visit</span>}
            </div>
            <div style={{ fontSize: 12, opacity: .85, marginTop: 2 }}>
              {patient.age}{patient.gender?.charAt(0)} -- {patient.uhid} -- Token {data.entry.token}
            </div>
          </div>
          <div style={{ textAlign: 'center', background: 'rgba(255,255,255,.16)', borderRadius: 10, padding: '6px 16px', flexShrink: 0 }}>
            <div style={{ fontSize: 9.5, opacity: .8, textTransform: 'uppercase', letterSpacing: '.5px' }}>Duration</div>
            <div style={{ fontSize: 18, fontWeight: 800, fontFamily: 'monospace' }}>{elapsedMin(data.encounter.started_at)}m</div>
          </div>
        </div>

        {/* TABS */}
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
          {!hideHistoryTracker && <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-message" label="History" />}
          <TabButton active={activeTab === 'optometry'} onClick={() => setActiveTab('optometry')} icon="ti-eye-check" label="Optometry" />
          <TabButton active={activeTab === 'exam'} onClick={() => setActiveTab('exam')} icon="ti-microscope" label="Examination" />
          <TabButton active={activeTab === 'plan'} onClick={() => setActiveTab('plan')} icon="ti-clipboard-text" label="Diagnosis & Plan" />
          {!hideHistoryTracker && <TabButton active={activeTab === 'tracker'} onClick={() => setActiveTab('tracker')} icon="ti-chart-line" label="Action Tracker" />}
        </div>
      </div>

      {data.isFollowUp && followUpContext && (
        <PatientSnapshotBar snapshot={followUpContext.snapshot} />
      )}

      {data.isLocked && (
        <div
          className="msg-info"
          style={{
            display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10,
            background: unlocked ? 'var(--amber-lt)' : 'var(--g100)', color: unlocked ? 'var(--amber)' : 'var(--g600)',
            padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16,
          }}
        >
          <span>
            <i className={`ti ${unlocked ? 'ti-lock-open' : 'ti-lock'}`}></i>{' '}
            {unlocked
              ? 'Editing a completed consultation -- changes save immediately.'
              : 'This consultation is completed. Viewing read-only for reference.'}
          </span>
          <button className="btn btn-sm" onClick={() => setUnlocked((v) => !v)}>
            {unlocked ? 'Lock' : 'Unlock to Edit'}
          </button>
        </div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '260px 1fr', gap: 20, alignItems: 'start' }}>
        {/* CONTEXT SIDEBAR -- patient history (previous visit, timeline,
            investigations) plus this encounter's own status/tasks/audit
            log, all in one place so the main column has full width. */}
        <div>
          <ContextSidebar
            patientId={patient.id}
            previousVisitSummary={data.isFollowUp && followUpContext ? followUpContext.snapshot.previousVisitSummary : null}
            encounter={data.encounter}
            auditLog={data.auditLog}
            openInvestigations={openInvestigations}
            activeWorkflows={activeWorkflows}
            pendingRx={pendingRx}
            wfItems={WF_ITEMS}
          />
        </div>

        {/* MAIN COLUMN -- tab content only; the tab bar itself now lives
            in the sticky header above so it freezes along with the
            patient identity bar. */}
        <div>
          {/* Tab content and the actions bar below are wrapped in a native
              <fieldset disabled> when the encounter is locked -- this
              cascades to every nested input/select/button in HistoryTab,
              OptometryTab, and ExaminationTab automatically, without
              needing to touch those files. The tab buttons above stay
              outside it so a locked record can still be browsed. */}
          <fieldset disabled={isReadOnly} style={{ border: 'none', margin: 0, padding: 0 }}>

          {activeTab === 'history' && (
            <HistoryTab
              encounter={data.encounter}
              findings={data.findings}
              onSaved={refresh}
            />
          )}

          {activeTab === 'optometry' && (
            <OptometryTab
              findings={data.findings}
              iopReadings={data.iopReadings}
              visitId={data.entry.visits.id}
              encounterId={data.encounter.id}
              onSaved={refresh}
            />
          )}

          {activeTab === 'exam' && (
            <ExaminationTab examination={data.examination} encounterId={data.encounter.id} onSaved={refresh} />
          )}

          {activeTab === 'plan' && (
            <>
              <GroupHeader num={1} color="var(--purple)" title="Investigations" />

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-flask" style={{ color: 'var(--teal)' }}></i> Investigations</div>
                {data.isFollowUp && followUpContext && (
                  <NewInvestigationsSinceLastVisit
                    investigations={followUpContext.newInvestigations}
                    matchInvestigationType={matchInvestigationType}
                    summarizeResultData={summarizeResultData}
                  />
                )}
                {data.investigations.map((i) => {
                  const type = matchInvestigationType(i.name);
                  const hasResults = i.status === 'Available';
                  return (
                    <div key={i.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
                      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', fontSize: 13 }}>
                        <span>
                          <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
                        </span>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 6 }}>
                          <span className={`badge ${INV_STATUS_BADGE[i.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{i.status}</span>
                          {hasResults && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => openPopup(`/investigation/${i.id}?mode=view`, `inv-${i.id}`)}>
                              <i className="ti ti-eye"></i> View findings
                            </button>
                          )}
                          {i.status === 'Ordered' && (
                            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id, data.encounter.id); refresh(); }}>Remove</button>
                          )}
                        </div>
                      </div>
                      {hasResults && (
                        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 3 }}>{summarizeResultData(type, i.result_data)}</div>
                      )}
                      {i.status === 'Cancelled' && i.unable_reason && (
                        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 3 }}><i className="ti ti-alert-triangle"></i> Unable to perform -- {i.unable_reason}</div>
                      )}
                    </div>
                  );
                })}
                {data.investigations.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No investigations ordered yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setInvName(e.target.value); }}>
                  <option value="">-- Pick from Investigations master (or type below) --</option>
                  {investigationOptions.map((s) => <option key={s.id} value={s.name}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                  </select>
                  <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
                    <option>Routine</option><option>Urgent</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
                </div>
              </div>

              <GroupHeader num={2} color="var(--indigo)" title="Biometry" />
              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry</div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
                  Device measurements, IOL power calculation, and surgeon approval -- its own dedicated workflow, separate from lab investigations.
                </div>

                {bioSent ? (
                  <>
                    <div style={{ marginBottom: 6 }}>
                      <span className="badge b-green"><i className="ti ti-check"></i> Sent for Biometry</span>
                    </div>
                    {data.biometryRecords.map((r) => (
                      <div key={r.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
                          <span className={`badge ${r.status === 'Approved' ? 'b-green' : r.status === 'Calculated' ? 'b-purple' : r.status === 'Measured' ? 'b-blue' : 'b-amber'}`}>
                            {r.status}
                          </span>
                          <span className="badge b-indigo">{r.surgical_eye}</span>
                          <a href={`/biometry/${r.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 12, textDecoration: 'none' }}>
                            <i className="ti ti-external-link"></i> Open Biometry
                          </a>
                          {editingBioId !== r.id && (
                            <button className="btn" style={{ fontSize: 11 }} onClick={() => startEditBioInstructions(r)}>
                              <i className="ti ti-edit"></i> {r.doctor_instructions ? 'Edit instructions' : 'Add instructions'}
                            </button>
                          )}
                          {r.billing_status !== 'Billed' ? (
                            <button className="btn" style={{ fontSize: 11, color: 'var(--red)' }} onClick={() => handleRemoveBiometry(r.id)}>
                              <i className="ti ti-trash"></i> Remove
                            </button>
                          ) : (
                            <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                          )}
                        </div>
                        {editingBioId === r.id ? (
                          <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                            <input className="fi" style={{ flex: 1 }} placeholder="Instructions for technician" value={editBioInstructions} onChange={(e) => setEditBioInstructions(e.target.value)} />
                            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => saveBioInstructions(r.id)}>Save</button>
                            <button className="btn" style={{ fontSize: 12 }} onClick={() => setEditingBioId(null)}>Cancel</button>
                          </div>
                        ) : r.doctor_instructions && (
                          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 4 }}><i className="ti ti-notes"></i> {r.doctor_instructions}</div>
                        )}
                      </div>
                    ))}
                  </>
                ) : (
                  <>
                    {data.biometryRecords.length > 0 && (
                      <div style={{ marginBottom: 10 }}>
                        {data.biometryRecords.map((r) => (
                          <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 4, flexWrap: 'wrap' }}>
                            <span className="badge b-indigo"><i className="ti ti-check"></i> Advised -- {r.surgical_eye}</span>
                            {r.billing_status !== 'Billed' ? (
                              <button className="btn" style={{ fontSize: 10 }} onClick={() => handleRemoveBiometry(r.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i> Remove
                              </button>
                            ) : (
                              <span style={{ fontSize: 10, color: 'var(--g400)' }}>Billed -- cannot remove here</span>
                            )}
                          </div>
                        ))}
                        <span style={{ fontSize: 11, color: 'var(--g500)' }}>Adjust below if needed, then use &quot;Send for Biometry&quot; at the bottom.</span>
                      </div>
                    )}
                    <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'flex-end' }}>
                      <div>
                        <label className="flbl">Eye required</label>
                        <select className="fi" style={{ width: 100 }} value={bioEye} onChange={(e) => setBioEye(e.target.value)}>
                          <option value="">Select</option>
                          <option value="RE">RE</option>
                          <option value="LE">LE</option>
                          <option value="Both">Both Eyes</option>
                        </select>
                      </div>
                      <div style={{ flex: 1, minWidth: 200 }}>
                        <label className="flbl">Instructions for technician (optional)</label>
                        <input className="fi" placeholder="e.g. prior RK surgery, use formula X" value={bioInstructions} onChange={(e) => setBioInstructions(e.target.value)} />
                      </div>
                      <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAdviseBiometry}>
                        {data.biometryRecords.length > 0 ? 'Update' : 'Add'}
                      </button>
                    </div>
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>
                      Adding here records the advice -- use &quot;Send for Biometry&quot; below when you&apos;re ready to actually route the patient.
                    </div>
                  </>
                )}
              </div>

              <GroupHeader num={3} color="var(--teal)" title="Diagnosis" />

              {data.diagnosisHistory.length > 0 && (
                <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
                    <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Diagnosis History <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prior visits, read-only)</span>
                  </div>
                  {data.diagnosisHistory.map((h) => (
                    <div key={h.id} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}>
                      <span style={{ color: 'var(--g400)', fontSize: 11, width: 90 }}>{new Date(h.encounterDate).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</span>
                      <span style={{ flex: 1, fontWeight: 600 }}>{h.name} <span style={{ fontSize: 10, color: 'var(--g400)' }}>({h.eye})</span></span>
                      <span className={`badge ${h.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 10 }}>{h.status}</span>
                    </div>
                  ))}
                </div>
              )}

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Diagnosis</div>
                {data.isFollowUp && followUpContext && !isReadOnly && (
                  <CarryForwardDiagnoses
                    priorDiagnoses={followUpContext.snapshot.currentDiagnoses}
                    alreadyAdded={data.diagnoses}
                    onCarryForward={handleCarryForward}
                  />
                )}
                {data.diagnoses.map((d, idx) => (
                  <DiagnosisRow key={d.id} d={d} index={idx} encounterId={data.encounter.id} onRemove={async () => { await removeDiagnosis(d.id, data.encounter.id); refresh(); }} />
                ))}
                {data.diagnoses.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No diagnosis added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setDxName(e.target.value); }}>
                  <option value="">-- Pick from Diagnoses master (or type below) --</option>
                  {diagnosisOptions.map((d) => <option key={d.id} value={d.name}>{d.name}{d.category ? ` (${d.category})` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                  <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
                  <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
                    <option value="primary">Primary</option>
                    <option value="secondary">Secondary</option>
                    <option value="associated">Associated</option>
                    <option value="systemic">Systemic</option>
                  </select>
                  <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="OD">OD</option>
                    <option value="OS">OS</option>
                    <option value="OU">OU</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
                </div>
              </div>

              <GroupHeader num={4} color="var(--blue)" title="Treatment" />

              <div className="card" style={{ marginBottom: 12 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-pill" style={{ color: 'var(--purple)' }}></i> Prescription</div>
                {data.isFollowUp && followUpContext && followUpContext.snapshot.currentMedications.length > 0 && !isReadOnly && (
                  <div style={{ background: 'var(--amber-lt)', borderRadius: 8, padding: 10, marginBottom: 10 }}>
                    <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--amber)', marginBottom: 6 }}><i className="ti ti-arrow-back-up"></i> Continue from last visit</div>
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
                      {followUpContext.snapshot.currentMedications
                        .filter((m) => !data.prescriptions.some((r) => r.drug_name === m.drug_name && r.eye === m.eye))
                        .map((m) => (
                          <button
                            key={m.id}
                            className="btn btn-sm"
                            onClick={async () => {
                              await addPrescription(data.encounter.id, { drugName: m.drug_name, dosage: m.dosage, frequency: m.frequency, duration: m.duration, eye: m.eye });
                              refresh();
                            }}
                          >
                            <i className="ti ti-plus"></i> {m.drug_name} ({m.eye})
                          </button>
                        ))}
                    </div>
                  </div>
                )}
                {data.prescriptions.map((r) => (
                  <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <span>
                      <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
                    </span>
                    <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id, data.encounter.id); refresh(); }}>Remove</button>
                  </div>
                ))}
                {data.prescriptions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No prescriptions added yet.</div>}
                <select className="fi" style={{ marginTop: 10 }} value="" onChange={(e) => { if (e.target.value) setRxDrug(e.target.value); }}>
                  <option value="">-- Pick from Pharmacy master (or type below) --</option>
                  {drugOptions.map((d) => <option key={d.id} value={d.generic}>{d.generic}{d.brand ? ` (${d.brand})` : ''}{d.strength ? ` -- ${d.strength}` : ''}</option>)}
                </select>
                <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap' }}>
                  <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
                  <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
                  </select>
                  <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
                    <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
                  </select>
                  <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
                    <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
                  </select>
                  <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
                </div>
              </div>

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-glasses" style={{ color: 'var(--indigo)' }}></i> Optical Advice</div>
                  {data.opticalAdvice.map((o) => (
                    <div key={o.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{o.advice}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeOpticalAdvice(o.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                    {['Distance spectacles', 'Near spectacles', 'Progressive lenses', 'Contact lenses', 'Low vision aid'].map((q) => (
                      <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setOptText(q)}>{q}</span>
                    ))}
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <input className="fi fi-sm" placeholder="Optical recommendation..." value={optText} onChange={(e) => setOptText(e.target.value)} style={{ flex: 1 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--indigo)', color: '#fff', border: 'none' }} onClick={handleAddOptical}>Add</button>
                  </div>
                </div>

                <div className="card">
                  <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-tool" style={{ color: 'var(--blue)' }}></i> Procedures</div>
                  {data.procedures.map((p) => (
                    <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                      <span>{p.name} -- {p.eye}</span>
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeProcedure(p.id, data.encounter.id); refresh(); }}>Remove</button>
                    </div>
                  ))}
                  <div style={{ display: 'flex', gap: 6 }}>
                    <select className="fi fi-sm" value={procName} onChange={(e) => setProcName(e.target.value)} style={{ flex: 1 }}>
                      <option value="">-- Select procedure --</option>
                      {procedureOptions.map((p) => <option key={p.id} value={p.name}>{p.name}</option>)}
                    </select>
                    <select className="fi fi-sm" value={procEye} onChange={(e) => setProcEye(e.target.value)} style={{ width: 70 }}>
                      <option>OD</option><option>OS</option><option>OU</option>
                    </select>
                    <button className="btn btn-sm btn-primary" onClick={handleAddProcedure}>Add</button>
                  </div>
                </div>
              </div>

              <div className="card" style={{ marginBottom: 20 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-scalpel" style={{ color: 'var(--red)' }}></i> Surgery</div>

                {data.surgicalCases.length > 0 ? (
                  <div>
                    {data.surgicalCases.map((sc) => (
                      <div key={sc.id}>
                        {editingSurgicalCaseId === sc.id ? (
                          <div style={{ padding: '8px 0' }}>
                            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                              <select className="fi" value={editSurgeryProcedure} onChange={(e) => setEditSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                                <option value="">-- Select surgery --</option>
                                {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                              </select>
                              <select className="fi" value={editSurgeryEye} onChange={(e) => setEditSurgeryEye(e.target.value)} style={{ width: 80 }}>
                                <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                              </select>
                            </div>
                            <div style={{ marginBottom: 8 }}>
                              <label className="flbl">Pre-op Required</label>
                              <select className="fi" value={editSurgeryPreOp} onChange={(e) => setEditSurgeryPreOp(e.target.value)}>
                                <option value="None">None</option>
                                <option value="Biometry">Biometry</option>
                                <option value="Medical Fitness">Medical Fitness</option>
                                <option value="Both">Both</option>
                              </select>
                            </div>
                            <div style={{ display: 'flex', gap: 6 }}>
                              <button className="btn btn-primary btn-sm" onClick={handleUpdateSurgicalCase} disabled={surgeryLoading}>
                                {surgeryLoading ? 'Saving...' : 'Save'}
                              </button>
                              <button className="btn btn-sm" onClick={() => setEditingSurgicalCaseId(null)}>Cancel</button>
                            </div>
                          </div>
                        ) : (
                          <div style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 0', fontSize: 13 }}>
                            <i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i>
                            <span style={{ flex: 1 }}>
                              <strong>{sc.procedure_name}</strong> -- {sc.eye}
                              <span style={{ marginLeft: 8, fontSize: 10.5, color: 'var(--g500)' }}>
                                Pre-op: {sc.biometry_required !== false && sc.fitness_required !== false ? 'Both' : sc.biometry_required !== false ? 'Biometry' : sc.fitness_required !== false ? 'Medical Fitness' : 'None'}
                              </span>
                            </span>
                            <span className="badge b-blue" style={{ fontSize: 10 }}>{sc.status}</span>
                            {sc.status === 'Pending Workup' && (
                              <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => startEditSurgicalCase(sc)}>
                                <i className="ti ti-edit"></i> Edit
                              </button>
                            )}
                          </div>
                        )}
                      </div>
                    ))}
                    <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>One surgical case per visit -- already marked for this visit.</div>
                  </div>
                ) : !showSurgery ? (
                  <button className="btn" onClick={() => setShowSurgery(true)}>
                    <i className="ti ti-scalpel"></i> Mark for Surgery
                  </button>
                ) : (
                  <div>
                    <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
                      <select className="fi" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }}>
                        <option value="">-- Select surgery --</option>
                        {surgeryOptions.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
                      </select>
                      <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                        <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
                      </select>
                    </div>
                    <div style={{ marginBottom: 8 }}>
                      <label className="flbl">Pre-op Required</label>
                      <select className="fi" value={surgeryPreOp} onChange={(e) => setSurgeryPreOp(e.target.value)}>
                        <option value="None">None</option>
                        <option value="Biometry">Biometry</option>
                        <option value="Medical Fitness">Medical Fitness</option>
                        <option value="Both">Both</option>
                      </select>
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                        {surgeryLoading ? 'Saving...' : 'Save'}
                      </button>
                      <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
                    </div>
                  </div>
                )}
              </div>

              <GroupHeader num={5} color="var(--amber)" title="Patient Management" />

              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                <div>
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Patient Instructions</div>
                    <textarea className="fi fi-sm" rows={2} value={patientInstructions} onChange={(e) => setPatientInstructions(e.target.value)} placeholder="Instructions, precautions, diet, activity restrictions..." style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" onClick={handleSaveInstructions}>Save</button>
                    {instructionsSaved && <span style={{ fontSize: 11, color: 'var(--green)', marginLeft: 8 }}><i className="ti ti-check"></i> Saved</span>}
                  </div>

                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-messages" style={{ color: 'var(--teal)' }}></i> Counselling Topics</div>
                    {data.counsellingItems.map((c) => (
                      <div key={c.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{c.topic}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeCounsellingItem(c.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, margin: '8px 0' }}>
                      {['Cataract counselling', 'Premium IOL discussion', 'Financial counselling', 'Consent education'].map((q) => (
                        <span key={q} className="badge b-gray" style={{ cursor: 'pointer' }} onClick={() => setCounselTopic(q)}>{q}</span>
                      ))}
                    </div>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi fi-sm" placeholder="Counselling topic..." value={counselTopic} onChange={(e) => setCounselTopic(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleAddCounsel}>Add</button>
                    </div>
                  </div>
                </div>

                <div>
                  <div className="card" style={{ marginBottom: 16 }}>
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrow-right-circle" style={{ color: 'var(--amber)' }}></i> Referral</div>
                    {data.referrals.map((r) => (
                      <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                        <span>{r.destination}{r.reason ? ` -- ${r.reason}` : ''}</span>
                        <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeReferral(r.id, data.encounter.id); refresh(); }}>Remove</button>
                      </div>
                    ))}
                    <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                      <select className="fi fi-sm" value={refDest} onChange={(e) => setRefDest(e.target.value)} style={{ flex: 1 }}>
                        <option value="">-- Destination --</option>
                        <option>Retina Specialist</option><option>Glaucoma Specialist</option><option>Cornea Specialist</option><option>Physician</option><option>Anaesthetist</option><option>Other Hospital</option>
                      </select>
                      <input className="fi fi-sm" placeholder="Reason" value={refReason} onChange={(e) => setRefReason(e.target.value)} style={{ flex: 1 }} />
                      <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }} onClick={handleAddReferral}>Add</button>
                    </div>
                  </div>

                  <div className="card">
                    <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calendar-plus" style={{ color: 'var(--green)' }}></i> Follow-up</div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 6, marginBottom: 8 }}>
                      <select className="fi fi-sm" value={fuAfter} onChange={(e) => setFuAfter(e.target.value)}>
                        <option>1 week</option><option>2 weeks</option><option>1 month</option><option>3 months</option><option>6 months</option><option>1 year</option><option>SOS</option>
                      </select>
                      <select className="fi fi-sm" value={fuType} onChange={(e) => setFuType(e.target.value)}>
                        <option>Routine</option><option>Post-operative</option><option>Urgent</option>
                      </select>
                      <select className="fi fi-sm" value={fuClinic} onChange={(e) => setFuClinic(e.target.value)}>
                        <option>General</option><option>Cataract</option><option>Glaucoma</option><option>Retina</option>
                      </select>
                    </div>
                    <input className="fi fi-sm" placeholder="Special instructions..." value={fuInstructions} onChange={(e) => setFuInstructions(e.target.value)} style={{ marginBottom: 8 }} />
                    <button className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleSaveFollowup}>Save Follow-up</button>
                    {fuSaved && (
                      <div style={{ marginTop: 8, padding: '6px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                        Follow-up: {fuAfter} -- {fuType} -- {fuClinic}
                      </div>
                    )}
                  </div>
                </div>
              </div>
            </>
          )}

          {activeTab === 'tracker' && (
            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-line" style={{ color: 'var(--blue)' }}></i> Actions Generated This Encounter</div>
              {trackerRows.length === 0 && (
                <div style={{ textAlign: 'center', padding: 24, color: 'var(--g400)', fontSize: 13 }}>Add items to Diagnosis &amp; Plan to see actions here.</div>
              )}
              {trackerRows.map((a, i) => (
                <div key={i} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 4px', borderBottom: '1px solid var(--g100)' }}>
                  <i className={`ti ${a.icon}`} style={{ color: a.color, fontSize: 15 }}></i>
                  <div style={{ flex: 1 }}>
                    <div style={{ fontSize: 12, fontWeight: 600 }}>{a.label}</div>
                    <div style={{ fontSize: 10, color: 'var(--g400)' }}>{a.dept}</div>
                  </div>
                  <span className={`badge ${a.status === 'Done' || a.status === 'Completed' || a.status === 'Dispensed' || a.status === 'Verified' ? 'b-green' : a.status === 'Cancelled' ? 'b-gray' : 'b-amber'}`}>{a.status}</span>
                  {a.resolvable && a.wfId && (
                    <button className="btn btn-sm" onClick={() => handleCompleteWorkflow(a.wfId)}>Mark Done</button>
                  )}
                  {a.resolvable && a.planTable && (
                    <button className="btn btn-sm" onClick={() => handleCompletePlanItem(a.planTable, a.planId)}>Mark Done</button>
                  )}
                </div>
              ))}
            </div>
          )}

          {data.isFollowUp && (
            <VisitOutcomeSelector value={visitOutcome} onChange={handleVisitOutcomeChange} disabled={isReadOnly} />
          )}

          {/* ACTIONS */}
          <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginTop: 16 }}>
            <button className="btn" onClick={handleSaveDraft} disabled={loading}>
              <i className="ti ti-device-floppy"></i> Save Draft
            </button>
            <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
              {loading ? 'Working...' : 'Complete Visit'}
            </button>
            <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
              Send for Dilation
            </button>
            <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
              Send for Investigation
            </button>
            {!bioSent && (
              <button className="btn" onClick={() => handleSendOut('biometry')} disabled={loading}>
                <i className="ti ti-ruler-measure"></i> Send for Biometry
              </button>
            )}
            <a href={`/visit-summary-print/${data.encounter.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ marginLeft: 'auto' }}>
              <i className="ti ti-printer"></i> Print Visit Summary
            </a>
          </div>
          </fieldset>
        </div>
      </div>
    </div>
  );
}
JSEOF_68892697

echo "-- Writing app/(main)/consultation/actions.js --"
mkdir -p "$(dirname "app/(main)/consultation/actions.js")"
cat > "app/(main)/consultation/actions.js" << 'JSEOF_91646988'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';

async function addAudit(supabase, encounterId, message, userId) {
  await supabase.from('encounter_audit_log').insert({ encounter_id: encounterId, message, created_by: userId || null });
}

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let encounter;
  if (entry.status === 'Done') {
    // Most recent encounter for this visit, any status -- not combining
    // .limit() with .maybeSingle() here, since that pairing isn't used
    // anywhere else in this codebase (getOrCreateBiometryRecord uses the
    // same array + length check instead for exactly this kind of lookup).
    const { data: encounters, error: encListError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .order('started_at', { ascending: false })
      .limit(1);
    if (encListError) return { error: encListError.message };
    encounter = encounters && encounters.length > 0 ? encounters[0] : null;
  } else {
    const { data: activeEncounter, error: encActiveError } = await supabase
      .from('encounters')
      .select('*')
      .eq('visit_id', visitId)
      .eq('status', 'In Consultation')
      .maybeSingle();
    if (encActiveError) return { error: encActiveError.message };
    encounter = activeEncounter;
  }

  const { data: userData } = await supabase.auth.getUser();

  if (!encounter) {
    // For a completed (Done) queue entry there's nothing to auto-create --
    // if no encounter exists, the visit genuinely has no clinical record.
    // Auto-creating only makes sense for an active/new consultation.
    if (entry.status === 'Done') {
      return { error: 'No clinical record found for this completed visit.' };
    }
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
    await addAudit(supabase, encounter.id, 'Encounter started', userData?.user?.id);
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const patientId = entry.visits.patients.id;

  const [
    { data: diagnoses }, { data: prescriptions }, { data: investigations }, { data: workflowRequests }, { data: auditLog },
    { data: opticalAdvice }, { data: procedures }, { data: referrals }, { data: counsellingItems }, { data: followup },
    { data: diagnosisHistoryRaw }, { data: biometryRecords }, { data: surgicalCases },
  ] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('workflow_requests').select('*').eq('visit_id', visitId).order('requested_at', { ascending: false }),
    supabase.from('encounter_audit_log').select('*').eq('encounter_id', encounter.id).order('created_at', { ascending: false }),
    supabase.from('plan_optical_advice').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_procedures').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_referrals').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_counselling_items').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('plan_followups').select('*').eq('encounter_id', encounter.id).maybeSingle(),
    // Longitudinal (cross-visit) diagnosis history: every diagnosis this
    // patient has, across all their encounters, via visits -> encounters.
    supabase
      .from('visits')
      .select('id, encounters(id, started_at, status, diagnoses(id, name, category, eye, status, created_at))')
      .eq('patient_id', patientId),
    // Biometry gets its own dedicated section in Diagnosis & Plan (not
    // folded into Investigations) -- same reasoning as its own
    // Financial Masters department: it's structurally its own thing.
    supabase.from('biometry_records').select('id, status, surgical_eye, doctor_instructions, billing_status').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
    // So "Mark for Surgery" can show what's already been marked instead
    // of silently reverting to a blank button after saving. Scoped by
    // visit_id (one visit, one surgical case), not just this encounter,
    // since a visit can span more than one encounter.
    supabase.from('surgical_cases').select('id, procedure_name, eye, status, priority, biometry_required, fitness_required').eq('visit_id', visitId).neq('status', 'Cancelled').order('created_at', { ascending: false }),
  ]);

  const diagnosisHistory = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .flatMap((e) => (e.diagnoses || []).map((d) => ({ ...d, encounterDate: e.started_at })))
    .sort((a, b) => new Date(b.created_at) - new Date(a.created_at));

  // Follow-up Template: same consultation engine, just extra context --
  // a patient is a "follow-up" the moment they have any prior encounter
  // at all, on a different visit, regardless of whether that encounter
  // was ever formally completed (an abandoned/in-progress note still
  // means this isn't their first time being seen).
  const priorEncounters = (diagnosisHistoryRaw || [])
    .flatMap((v) => v.encounters || [])
    .filter((e) => e.id !== encounter.id)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorCompletedEncounters = priorEncounters.filter((e) => e.status === 'Completed');
  const isFollowUp = priorEncounters.length > 0;

  if (isFollowUp && encounter.encounter_type !== 'Follow-up') {
    await supabase.from('encounters').update({ encounter_type: 'Follow-up' }).eq('id', encounter.id);
    encounter.encounter_type = 'Follow-up';
  }

  return {
    entry, findings, iopReadings, encounter, examination,
    diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [],
    workflowRequests: workflowRequests || [], auditLog: auditLog || [],
    opticalAdvice: opticalAdvice || [], procedures: procedures || [], referrals: referrals || [],
    counsellingItems: counsellingItems || [], followup: followup || null, diagnosisHistory,
    biometryRecords: biometryRecords || [],
    surgicalCases: surgicalCases || [],
    isLocked: encounter.status === 'Completed',
    isFollowUp, priorEncounterId: priorCompletedEncounters[0]?.id || null,
  };
}

// ── FOLLOW-UP TEMPLATE CONTEXT ──
// Everything the Follow-up template needs beyond what getConsultationData
// already returns: the visit timeline, patient snapshot, and a summary
// of the immediately preceding visit. Only called when isFollowUp is true.
export async function getFollowUpContext(patientId, currentVisitId, currentEncounterId) {
  const supabase = await createClient();

  const { data: visitsRaw } = await supabase
    .from('visits')
    .select('id, visit_number, encounters(id, started_at, completed_at, chief_complaint, status)')
    .eq('patient_id', patientId);

  const allPriorEncounters = (visitsRaw || [])
    .flatMap((v) => (v.encounters || []).map((e) => ({ ...e, visitId: v.id, visitNumber: v.visit_number })))
    .filter((e) => e.id !== currentEncounterId)
    .sort((a, b) => new Date(b.started_at) - new Date(a.started_at));
  const priorEncounters = allPriorEncounters.filter((e) => e.status === 'Completed');

  // Map each prior visit back to its Doctor queue entry, so the
  // timeline can open it read-only -- same lookup pattern Patient
  // Timeline already uses.
  const priorVisitIds = [...new Set(allPriorEncounters.map((e) => e.visitId))];
  let queueEntryByVisit = {};
  if (priorVisitIds.length > 0) {
    const { data: entries } = await supabase.from('queue_entries').select('id, visit_id').in('visit_id', priorVisitIds).eq('department', 'Doctor');
    (entries || []).forEach((e) => { queueEntryByVisit[e.visit_id] = e.id; });
  }

  // Timeline shows every prior visit, including ones that were never
  // finalized -- still useful context, just labeled as such.
  const timeline = allPriorEncounters.slice(0, 15).map((e) => ({
    encounterId: e.id, date: e.started_at, chiefComplaint: e.chief_complaint,
    status: e.status, queueEntryId: queueEntryByVisit[e.visitId] || null,
  }));

  const lastEncounter = priorEncounters[0] || null;
  let snapshot = {
    lastVisitDate: lastEncounter?.started_at || null,
    currentDiagnoses: [], currentMedications: [], allergy: null,
    lastVision: null, lastIop: null, surgicalStatus: null,
    previousVisitSummary: null,
    noCompletedPriorVisit: !lastEncounter,
  };
  let newInvestigations = [];

  if (lastEncounter) {
    // Investigations ordered (anywhere -- Counselling, a walk-in
    // Investigation visit, etc.) since the last consultation, with
    // results ready -- these are easy to miss since they don't
    // necessarily belong to *this* encounter's own Investigations list.
    const allEncounterIds = (visitsRaw || []).flatMap((v) => (v.encounters || []).map((e) => e.id));
    if (allEncounterIds.length > 0) {
      const { data: recentInv } = await supabase
        .from('investigation_orders')
        .select('*')
        .in('encounter_id', allEncounterIds)
        .neq('encounter_id', currentEncounterId)
        .eq('status', 'Available')
        .gt('created_at', lastEncounter.started_at)
        .order('created_at', { ascending: false });
      newInvestigations = recentInv || [];
    }
    const [{ data: fullEncounter }, { data: diagnoses }, { data: medications }, { data: assessment }, { data: advice }, { data: fu }] = await Promise.all([
      supabase.from('encounters').select('hx_drug_allergy').eq('id', lastEncounter.id).maybeSingle(),
      supabase.from('diagnoses').select('*').eq('encounter_id', lastEncounter.id).eq('status', 'Active').order('created_at'),
      supabase.from('prescriptions').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('optometry_assessments').select('*').eq('visit_id', lastEncounter.visitId).eq('status', 'Completed').maybeSingle(),
      supabase.from('plan_optical_advice').select('*').eq('encounter_id', lastEncounter.id).order('created_at'),
      supabase.from('plan_followups').select('*').eq('encounter_id', lastEncounter.id).maybeSingle(),
    ]);

    let lastIop = null;
    if (assessment) {
      const { data: iopReadings } = await supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: false }).limit(1);
      lastIop = iopReadings?.[0] || null;
    }

    const { data: recentSurgicalCase } = await supabase
      .from('surgical_cases').select('procedure_name, eye, status')
      .eq('patient_id', patientId).neq('status', 'Cancelled')
      .order('created_at', { ascending: false }).limit(1).maybeSingle();

    snapshot = {
      lastVisitDate: lastEncounter.started_at,
      currentDiagnoses: diagnoses || [],
      currentMedications: medications || [],
      allergy: fullEncounter?.hx_drug_allergy || null,
      lastVision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
      lastIop,
      surgicalStatus: recentSurgicalCase || null,
      previousVisitSummary: {
        date: lastEncounter.started_at,
        diagnoses: diagnoses || [],
        medications: medications || [],
        advice: advice || [],
        followupPlan: fu || null,
        vision: assessment ? { re: assessment.re_dist_glasses || assessment.re_dist_unaided, le: assessment.le_dist_glasses || assessment.le_dist_unaided } : null,
        iop: lastIop,
      },
    };
  }

  return { timeline, snapshot, newInvestigations };
}

// ── VISIT OUTCOME ──
export async function saveVisitOutcome(encounterId, outcome) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ visit_outcome: outcome }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── CARRY FORWARD a prior diagnosis into the current encounter ──
export async function carryForwardDiagnosis(encounterId, diagnosis) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId, name: diagnosis.name, category: diagnosis.category, eye: diagnosis.eye, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}
export async function saveExamination(examinationId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Examination saved', userData?.user?.id);
  return { success: true };
}

// ── STRUCTURED HISTORY (Section 11.9) ──
// Batched save, same pattern as Examination -- not per-keystroke.
export async function saveHistory(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({
      chief_complaint: fields.chiefComplaint,
      chief_complaint_chips: fields.chiefComplaintChips,
      hx_duration: fields.hxDuration,
      hx_laterality: fields.hxLaterality,
      hx_hopi: fields.hxHopi,
      ocular_history: fields.ocularHistory,
      medical_history: fields.medicalHistory,
      family_history: fields.familyHistory,
      hx_drug_allergy: fields.hxDrugAllergy,
    })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'History saved', userData?.user?.id);
  return { success: true };
}

// ── DOCTOR EDITS OPTOMETRY FINDINGS DIRECTLY (in-place override) ──
// The doctor edits the optometrist's own assessment record. Every
// changed field is written to that assessment's audit log (the same
// log the optometrist sees in Optometry History) as a before/after
// entry, so the optometrist can see exactly what was changed and by
// whom -- without a separate shadow record.
const OPTOM_FIELD_LABELS = {
  va_scale: 'VA Scale',
  re_dist_unaided: 'RE Dist Unaided', re_dist_glasses: 'RE Dist Glasses', re_dist_ph: 'RE Dist Pinhole', re_near_unaided: 'RE Near Unaided',
  le_dist_unaided: 'LE Dist Unaided', le_dist_glasses: 'LE Dist Glasses', le_dist_ph: 'LE Dist Pinhole', le_near_unaided: 'LE Near Unaided',
  ref_pd: 'PD', ref_vd: 'VD',
  ref_obj_re_sph: 'RE Obj Sph', ref_obj_re_cyl: 'RE Obj Cyl', ref_obj_re_axis: 'RE Obj Axis',
  ref_obj_le_sph: 'LE Obj Sph', ref_obj_le_cyl: 'LE Obj Cyl', ref_obj_le_axis: 'LE Obj Axis',
  ref_subj_re_sph: 'RE Subj Sph', ref_subj_re_cyl: 'RE Subj Cyl', ref_subj_re_axis: 'RE Subj Axis',
  ref_subj_le_sph: 'LE Subj Sph', ref_subj_le_cyl: 'LE Subj Cyl', ref_subj_le_axis: 'LE Subj Axis',
  ref_final_re_sph: 'RE Final Sph', ref_final_re_cyl: 'RE Final Cyl', ref_final_re_axis: 'RE Final Axis', ref_final_re_add: 'RE Final Add',
  ref_final_le_sph: 'LE Final Sph', ref_final_le_cyl: 'LE Final Cyl', ref_final_le_axis: 'LE Final Axis', ref_final_le_add: 'LE Final Add',
  iop_method: 'IOP Method', iop_time: 'IOP Time',
  add_k1: 'Keratometry K1', add_k2: 'Keratometry K2', add_axial_length: 'Axial Length', add_pachymetry: 'Pachymetry',
  add_white_to_white: 'White-to-White', add_schirmer: 'Schirmer', add_color_vision: 'Color Vision',
  add_ocular_motility: 'Ocular Motility', add_syringing: 'Syringing',
  observation_chips: 'Observation Tags', observations_text: 'Observations',
};

export async function updateOptometryFindings(assessmentId, encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: current, error: fetchError } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('id', assessmentId)
    .single();
  if (fetchError) return { error: fetchError.message };

  const changes = [];
  const updatePayload = {};
  Object.keys(OPTOM_FIELD_LABELS).forEach((key) => {
    if (fields[key] === undefined) return;
    const oldVal = current[key];
    const newVal = fields[key];
    const oldStr = Array.isArray(oldVal) ? oldVal.join(', ') : (oldVal ?? '');
    const newStr = Array.isArray(newVal) ? newVal.join(', ') : (newVal ?? '');
    if (oldStr === newStr) return;
    updatePayload[key] = newVal;
    changes.push({ label: OPTOM_FIELD_LABELS[key], oldStr: oldStr || '--', newStr: newStr || '--' });
  });

  if (changes.length === 0) return { success: true, changedCount: 0 };

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({ ...updatePayload, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);
  if (updateError) return { error: updateError.message };

  for (const c of changes) {
    await supabase.from('optometry_audit_log').insert({
      assessment_id: assessmentId,
      message: `Doctor override -- ${c.label}: "${c.oldStr}" -> "${c.newStr}"`,
      created_by: doctorId,
    });
  }

  if (encounterId) {
    await addAudit(supabase, encounterId, `Optometry findings overridden -- ${changes.length} field(s) changed`, doctorId);
  }

  return { success: true, changedCount: changes.length };
}

// Lets the doctor start an optometry assessment directly when the
// patient never went through Optometry -- same table, just created and
// initially owned from the consultation side instead of the queue.
export async function createOptometryAssessmentForVisit(visitId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const doctorId = userData?.user?.id || null;

  const { data: assessment, error } = await supabase
    .from('optometry_assessments')
    .insert({ visit_id: visitId, recorded_by: doctorId, completed_by: doctorId, status: 'Completed', completed_at: new Date().toISOString() })
    .select()
    .single();
  if (error) return { error: error.message };

  await supabase.from('optometry_audit_log').insert({ assessment_id: assessment.id, message: 'Assessment started by Doctor -- no prior Optometry visit', created_by: doctorId });
  if (encounterId) await addAudit(supabase, encounterId, 'Optometry assessment created directly by doctor', doctorId);

  return { assessment };
}


// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Diagnosis added: ${values.name} (${values.eye}, ${values.category})`, userData?.user?.id);
  return { success: true };
}

export async function removeDiagnosis(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Diagnosis removed', userData?.user?.id);
  return { success: true };
}

export async function updateDiagnosisNotes(id, notes) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').update({ notes: notes?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Prescription added: ${values.drugName} (${values.eye})`, userData?.user?.id);
  return { success: true };
}

export async function removePrescription(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Prescription removed', userData?.user?.id);
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Investigation ordered: ${values.name} (${values.eye}, ${values.priority})`, userData?.user?.id);
  return { success: true };
}

export async function removeInvestigation(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Investigation removed', userData?.user?.id);
  return { success: true };
}

// ── WORKFLOW REQUESTS (Biometry / Medical Fitness / Counselling) ──
// Independent, non-exclusive toggles -- a visit can have more than one
// open at a time, unlike Dilation/Investigation which move the queue
// entry itself. Toggling an already-open request cancels it.
export async function toggleWorkflowRequest(visitId, encounterId, kind) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: existing } = await supabase
    .from('workflow_requests')
    .select('*')
    .eq('visit_id', visitId)
    .eq('kind', kind)
    .eq('status', 'Requested')
    .maybeSingle();

  if (existing) {
    const { error } = await supabase
      .from('workflow_requests')
      .update({ status: 'Cancelled', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
      .eq('id', existing.id);
    if (error) return { error: error.message };
    await addAudit(supabase, encounterId, `Workflow request cancelled: ${kind}`, userData?.user?.id);
    return { success: true, active: false };
  }

  const { error } = await supabase.from('workflow_requests').insert({
    visit_id: visitId, encounter_id: encounterId, kind, requested_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Workflow requested: ${kind}`, userData?.user?.id);
  return { success: true, active: true };
}

// Mark a workflow request (Biometry/Fitness/Counselling) as done --
// used by whichever staff member actually completes it (e.g. the
// counsellor marking a Counselling request resolved).
export async function completeWorkflowRequest(id, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('workflow_requests')
    .update({ status: 'Completed', resolved_at: new Date().toISOString(), resolved_by: userData?.user?.id || null })
    .eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Workflow request marked complete', userData?.user?.id);
  return { success: true };
}

// ── MANAGEMENT PLAN EXPANSION (Ch.14) ──
export async function addOpticalAdvice(encounterId, advice) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_optical_advice').insert({ encounter_id: encounterId, advice, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Optical advice added: ${advice}`, userData?.user?.id);
  return { success: true };
}

export async function removeOpticalAdvice(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_optical_advice').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Optical advice removed', null);
  return { success: true };
}

export async function addProcedure(encounterId, name, eye) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_procedures').insert({ encounter_id: encounterId, name, eye, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Procedure planned: ${name} (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function removeProcedure(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_procedures').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Procedure removed', null);
  return { success: true };
}

export async function addReferral(encounterId, destination, reason) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_referrals').insert({ encounter_id: encounterId, destination, reason, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Referral added: ${destination}`, userData?.user?.id);
  return { success: true };
}

export async function removeReferral(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_referrals').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Referral removed', null);
  return { success: true };
}

export async function addCounsellingItem(encounterId, topic) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('plan_counselling_items').insert({ encounter_id: encounterId, topic, created_by: userData?.user?.id || null });
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Counselling topic added: ${topic}`, userData?.user?.id);
  return { success: true };
}

export async function removeCounsellingItem(id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Counselling topic removed', null);
  return { success: true };
}

// Any plan item (optical/procedure/referral/counselling) marked done --
// used from the Action Tracker tab.
export async function completePlanItem(table, id, encounterId) {
  const supabase = await createClient();
  const { error } = await supabase.from(table).update({ status: 'Done' }).eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Plan item marked done', null);
  return { success: true };
}

// Follow-up is one record per encounter -- upsert by encounter_id.
export async function saveFollowup(encounterId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase
    .from('plan_followups')
    .upsert(
      { encounter_id: encounterId, after_period: fields.after, visit_type: fields.type, clinic: fields.clinic, instructions: fields.instructions, created_by: userData?.user?.id || null },
      { onConflict: 'encounter_id' }
    );
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, `Follow-up scheduled: ${fields.after} -- ${fields.type}`, userData?.user?.id);
  return { success: true };
}

export async function savePatientInstructions(encounterId, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('encounters').update({ patient_instructions: instructions }).eq('id', encounterId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Encounter completed', userData?.user?.id);

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'dilate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Dilation', userData?.user?.id);
  return result;
}

export async function sendForInvestigationFromConsultation(queueEntryId, encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'investigate');
  if (!result.error) await addAudit(supabase, encounterId, 'Sent for Investigation', userData?.user?.id);
  return result;
}

// Shared by both the "Add" button (advises Biometry without moving the
// patient anywhere yet) and "Send for Biometry" (which also routes the
// queue) -- creates the record if none exists yet for that eye, or
// updates instructions on the existing one rather than duplicating it.
// Matched per-eye (not just per-visit) since "Both Eyes" needs two
// independent records -- the Biometry workspace itself is built around
// one eye per record (separate measurements/IOL calc/approval each),
// so bilateral cases genuinely need two rows, not one row meaning both.
async function ensureBiometryRecordForEye(supabase, visitId, encounterId, eye, instructions) {
  const { data: existing } = await supabase
    .from('biometry_records')
    .select('id')
    .eq('visit_id', visitId)
    .eq('surgical_eye', eye)
    .neq('status', 'Cancelled')
    .order('created_at', { ascending: false })
    .limit(1);

  if (!existing || existing.length === 0) {
    const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();
    const { data: created } = await supabase.from('biometry_records').insert({
      visit_id: visitId, encounter_id: encounterId || null, surgeon_id: visit?.doctor_id || null,
      surgical_eye: eye, doctor_instructions: instructions?.trim() || null,
    }).select('id').single();
    return created?.id;
  }

  await supabase.from('biometry_records').update({
    doctor_instructions: instructions?.trim() || null,
  }).eq('id', existing[0].id);
  return existing[0].id;
}

// "Both" fans out into one record per eye; RE/LE is just the one.
async function ensureBiometryRecords(supabase, visitId, encounterId, eye, instructions) {
  const eyes = eye === 'Both' ? ['RE', 'LE'] : [eye];
  const ids = [];
  for (const e of eyes) ids.push(await ensureBiometryRecordForEye(supabase, visitId, encounterId, e, instructions));
  return ids;
}

// The "Add" step -- advises Biometry is needed (records eye + optional
// instructions) without moving the patient's queue position at all.
// Mirrors exactly how Investigations work: "Add" saves the order,
// "Send for Investigation" is a separate, later action that routes the
// patient. Shows up immediately in the Investigation Queue's merged
// Biometry view either way, since that doesn't depend on queue status.
export async function adviseBiometry(visitId, encounterId, eye, instructions) {
  const supabase = await createClient();
  if (!eye) return { error: 'Select which eye Biometry is required for.' };
  const { data: userData } = await supabase.auth.getUser();
  await ensureBiometryRecords(supabase, visitId, encounterId, eye, instructions);
  await addAudit(supabase, encounterId, `Biometry advised (${eye})`, userData?.user?.id);
  return { success: true };
}

export async function sendForBiometryFromConsultation(queueEntryId, encounterId, eye, instructions) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const result = await doctorSendOut(queueEntryId, 'biometry');
  if (result.error) return result;
  await addAudit(supabase, encounterId, `Sent for Biometry (${eye})`, userData?.user?.id);

  const { data: entry } = await supabase.from('queue_entries').select('visit_id').eq('id', queueEntryId).single();
  if (entry?.visit_id) await ensureBiometryRecords(supabase, entry.visit_id, encounterId, eye, instructions);

  return result;
}

// For updating instructions on a biometry record that's already been
// sent -- eye is fixed once a record exists (changing it would mean a
// different physical record, not editing this one), but instructions
// can still be corrected/added at any point before the technician
// finishes.
// Doctor can remove a mistakenly-added/sent biometry request (wrong
// eye, duplicate, etc.) -- but only while it's still unbilled. Once
// Front Office has billed it, removing the record here would leave an
// invoice line with nothing behind it, so that has to go through
// billing's own modification flow instead.
export async function removeBiometryRecord(id, encounterId) {
  const supabase = await createClient();
  const { data: record } = await supabase.from('biometry_records').select('billing_status').eq('id', id).maybeSingle();
  if (!record) return { error: 'Record not found.' };
  if (record.billing_status === 'Billed') {
    return { error: 'This has already been billed and cannot be removed here -- use Billing to modify the invoice first.' };
  }
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('biometry_records').delete().eq('id', id);
  if (error) return { error: error.message };
  await addAudit(supabase, encounterId, 'Biometry request removed', userData?.user?.id);
  return { success: true };
}

export async function updateBiometryInstructions(id, instructions) {
  const supabase = await createClient();
  const { error } = await supabase.from('biometry_records').update({ doctor_instructions: instructions?.trim() || null }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function saveDraft(encounterId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  await addAudit(supabase, encounterId, 'Consultation saved as draft', userData?.user?.id);
  return { success: true };
}

JSEOF_91646988

echo "-- Writing app/(main)/counselling/actions.js --"
mkdir -p "$(dirname "app/(main)/counselling/actions.js")"
cat > "app/(main)/counselling/actions.js" << 'JSEOF_17266223'
'use server';

import { createClient } from '@/lib/supabase-server';

// This file replaces the old "Surgical Coordination" module's actions file.
// OT Scheduling (formerly its own module at app/(main)/ot-schedule) has been
// merged into Counselling: booking a slot is now the last step of the
// counselling workspace (see bookOTSlot/getOTAvailability below), and the
// OT Calendar (getOTSchedule/completeOT) is now the 3rd tab of this page
// instead of a standalone route.
// The following exports are used by OTHER modules and MUST keep the same
// name + signature:
//   markForSurgery, updateSurgicalCase
//     -- imported by app/(main)/consultation/[id]/consultation-form.js
// Everything else below is used only within the Counselling module.

// ── Sending a patient to an ancillary service (Biometry, Dilation, ...)
//    from Counselling. Once a doctor completes a consultation, ALL of
//    that visit's queue_entries get marked 'Done' -- so by the time a
//    case reaches Counselling (even same-day), there's nothing left to
//    "update". send_case_to_department_queue() (see migration 027)
//    issues a FRESH queue token against the patient's still-open visit
//    (found via ist_date(), so it's IST-correct rather than doing UTC
//    date math here) and flips it straight to the target status.
async function sendCaseToQueueStatus(caseId, queueStatus, auditMessage) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: queueStatus,
    p_audit_message: auditMessage,
    p_user_id: userData?.user?.id || null,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForBiometry(caseId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: sc } = await supabase.from('surgical_cases').select('id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: queueEntry, error } = await supabase.rpc('send_case_to_department_queue', {
    p_case_id: caseId,
    p_queue_status: 'Awaiting Biometry',
    p_audit_message: 'Sent for Biometry (from Counselling)',
    p_user_id: userData?.user?.id || null,
  });
  if (error) return { error: error.message };

  // Also create the biometry_records stub right away (mirrors
  // getOrCreateBiometryRecord in the Biometry module) so the Counselling
  // dashboard reflects "Awaiting Biometry" immediately instead of only
  // after the technician opens the queue entry -- and so the technician
  // finds it already there rather than creating a fresh one.
  const visitId = queueEntry?.visit_id;
  if (visitId) {
    const { data: existing } = await supabase
      .from('biometry_records')
      .select('id')
      .eq('visit_id', visitId)
      .neq('status', 'Cancelled')
      .order('created_at', { ascending: false })
      .limit(1);

    if (!existing || existing.length === 0) {
      const { data: visit } = await supabase.from('visits').select('doctor_id').eq('id', visitId).maybeSingle();
      await supabase.from('biometry_records').insert({ visit_id: visitId, encounter_id: sc.encounter_id || null, surgeon_id: visit?.doctor_id || null });
    }
  }

  return { success: true };
}

// For surgeries where biometry genuinely doesn't apply (retina,
// glaucoma, oculoplasty...) -- a reason is required so there's an
// audit trail for why this case skipped a normally-required step.
export async function skipBiometry(caseId, reason) {
  const supabase = await createClient();
  if (!reason || !reason.trim()) return { error: 'A reason is required to skip Biometry.' };
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: false, biometry_skip_reason: reason.trim() })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Undo a skip -- puts Biometry back as a required step for this case.
export async function unskipBiometry(caseId) {
  const supabase = await createClient();
  const { error } = await supabase
    .from('surgical_cases')
    .update({ biometry_required: true, biometry_skip_reason: null })
    .eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function sendForDilation(caseId) {
  return sendCaseToQueueStatus(caseId, 'Awaiting Dilation', 'Sent for Dilation (from Counselling)');
}

// ── Case creation (called from Consultation when doctor recommends surgery) ──
// Doctor can correct the procedure/eye on a case they marked for
// surgery, as long as Counselling hasn't already started working with
// it -- once package/decision work is underway, changes should go
// through Counselling instead to avoid corrupting what's already locked.
export async function updateSurgicalCase(caseId, procedureName, eye, preOpRequired) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('status').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };
  if (sc.status !== 'Pending Workup') {
    return { error: `This case has already moved to "${sc.status}" -- further changes should go through Counselling.` };
  }
  const update = { procedure_name: procedureName, eye };
  if (preOpRequired !== undefined) {
    update.biometry_required = preOpRequired === 'Biometry' || preOpRequired === 'Both';
    update.fitness_required = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';
  }
  const { error } = await supabase.from('surgical_cases').update(update).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markForSurgery(patientId, encounterId, procedureName, eye, preOpRequired) {
  const supabase = await createClient();

  // Pull surgeon + visit + priority through so the case doesn't start
  // with everything null -- encounters already carries doctor_id.
  const { data: encounter } = await supabase
    .from('encounters')
    .select('id, visit_id, doctor_id')
    .eq('id', encounterId)
    .single();

  // BR: one visit, one surgical case -- checked against visit_id (not
  // just this encounter), since a visit can span more than one
  // encounter (e.g. consultation reopened) and the case should still
  // only be created once.
  if (encounter?.visit_id) {
    const { data: existing } = await supabase
      .from('surgical_cases')
      .select('id, procedure_name, eye')
      .eq('visit_id', encounter.visit_id)
      .neq('status', 'Cancelled')
      .limit(1);
    if (existing && existing.length > 0) {
      return { error: `This visit already has a surgical case marked (${existing[0].procedure_name} -- ${existing[0].eye}). Only one is allowed per visit.` };
    }
  }

  let priority = 'Routine';
  if (encounter?.visit_id) {
    const { data: visit } = await supabase.from('visits').select('priority').eq('id', encounter.visit_id).single();
    if (visit?.priority) priority = visit.priority;
  }

  // Doctor's call on what pre-op workup this case actually needs --
  // carried forward to Counselling, which reads biometry_required /
  // fitness_required the same way for both (see readiness() and
  // markReadyForScheduling).
  const biometryRequired = preOpRequired === 'Biometry' || preOpRequired === 'Both';
  const fitnessRequired = preOpRequired === 'Medical Fitness' || preOpRequired === 'Both';

  const { error } = await supabase.from('surgical_cases').insert({
    patient_id: patientId,
    encounter_id: encounterId,
    visit_id: encounter?.visit_id || null,
    surgeon_id: encounter?.doctor_id || null,
    procedure_name: procedureName,
    eye,
    priority,
    biometry_required: biometryRequired,
    fitness_required: fitnessRequired,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Cases list for the Counselling workspace (richer -- surgeon, decision, IOL type) ──
export async function getCounsellingCases() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .in('status', ['Pending Workup', 'Ready for Scheduling'])
    .order('created_at', { ascending: false });
  if (error) return [];

  // surgical_cases and biometry_records are siblings linked only by
  // encounter_id (no direct FK Supabase can auto-embed), so this is a
  // separate batch query rather than a nested select. Used to tell
  // "Surgery Advised" (nobody has sent for biometry yet) apart from
  // "Awaiting Biometry" (sent, technician hasn't finished it) on the
  // dashboard -- both are biometry_done = false, but they're different
  // stages for the counsellor.
  const encounterIds = [...new Set((data || []).map((c) => c.encounter_id).filter(Boolean))];
  let biometryByEncounter = {};
  if (encounterIds.length > 0) {
    const { data: records } = await supabase
      .from('biometry_records')
      .select('id, encounter_id, status')
      .in('encounter_id', encounterIds);
    (records || []).forEach((r) => { biometryByEncounter[r.encounter_id] = r; });
  }

  // Same batching pattern for the medical fitness referral -- one per
  // case at most (re-referring resets the same row rather than piling
  // up history), so a simple map by surgical_case_id is enough.
  const caseIds = (data || []).map((c) => c.id);
  let fitnessByCase = {};
  if (caseIds.length > 0) {
    const { data: referrals } = await supabase
      .from('medical_fitness_referrals')
      .select('id, surgical_case_id, status, referred_at, fitness_notes')
      .in('surgical_case_id', caseIds);
    (referrals || []).forEach((r) => { fitnessByCase[r.surgical_case_id] = r; });
  }

  return (data || []).map((c) => ({
    ...c,
    biometry_record: biometryByEncounter[c.encounter_id] || null,
    fitness_referral: fitnessByCase[c.id] || null,
  }));
}

// ── History -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled). Read-only lookup, same underlying data shape
//    as getCounsellingCases minus the biometry/fitness batching, which
//    only matters for cases still in active workup. ──
export async function getCounsellingHistory() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_cases')
    .select(`
      id, patient_id, encounter_id, procedure_name, eye, priority, status,
      iol_category, decision, decision_reason,
      biometry_done, biometry_required, biometry_skip_reason,
      fitness_cleared, fitness_required, investigations_complete,
      package_id, package_locked, decision_locked, surgeon_id, advance_payment_id, created_at,
      patients:patient_id ( id, first_name, last_name, uhid, age, gender ),
      profiles:surgeon_id ( id, full_name ),
      master_packages:package_id ( id, name, price )
    `)
    .not('status', 'in', '("Pending Workup","Ready for Scheduling")')
    .order('created_at', { ascending: false })
    .limit(300);
  if (error) return [];
  return data || [];
}

// ── Packages, filtered by the IOL type advised at Biometry ──
// iol_category/origin live on master_packages (Master Data, M29). A package
// with iol_category = NULL is not IOL-specific (e.g. Glaucoma surgery) and
// is shown regardless of what was advised. Filtered in JS rather than a
// PostgREST .or() filter to avoid escaping issues with values like
// "Monofocal Toric" that contain a space.
export async function getPackagesForCase(iolCategory) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('master_packages')
    .select('id, code, name, price, includes, iol_category, origin')
    .eq('status', 'Active')
    .order('name');
  if (error) return [];
  return (data || []).filter((p) => !p.iol_category || p.iol_category === iolCategory);
}

// ── Package selection (BR-SCC-002: only after Biometry & IOL advice) ──
export async function selectPackage(caseId, packageId) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('biometry_done, biometry_required').eq('id', caseId).single();
  if (!sc?.biometry_done && sc?.biometry_required !== false) {
    return { error: 'BR-SCC-002: Biometry & IOL type advice must be complete before selecting a package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: packageId, package_locked: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Changing a package once it's locked needs a reason -- logged as a
// counselling note so there's an audit trail for why it changed.
export async function changePackage(caseId, reason) {
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('package_locked, master_packages:package_id(name)').eq('id', caseId).single();
  if (sc?.package_locked && (!reason || !reason.trim())) {
    return { error: 'A reason is required to change a locked package.' };
  }

  const { error } = await supabase.from('surgical_cases').update({ package_id: null, package_locked: false }).eq('id', caseId);
  if (error) return { error: error.message };

  if (sc?.package_locked && reason) {
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Package unlocked and changed${sc.master_packages?.name ? ` (was: ${sc.master_packages.name})` : ''} -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }
  return { success: true };
}

// ── Patient decision ──
const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

export async function setDecision(caseId, decision, reason) {
  if (!DECISIONS.includes(decision)) return { error: 'Invalid decision value.' };
  const supabase = await createClient();

  const { data: sc } = await supabase.from('surgical_cases').select('decision, decision_locked').eq('id', caseId).single();

  if (sc?.decision_locked && decision !== sc.decision) {
    if (!reason || !reason.trim()) {
      return { error: 'A reason is required to change a locked decision.' };
    }
    const { data: userData } = await supabase.auth.getUser();
    await supabase.from('surgical_case_notes').insert({
      surgical_case_id: caseId,
      note: `Decision unlocked and changed from "${sc.decision}" to "${decision}" -- Reason: ${reason.trim()}`,
      created_by: userData?.user?.id || null,
    });
  }

  const { error } = await supabase.from('surgical_cases').update({
    decision, decision_reason: reason || null,
    decision_locked: decision === 'Accepted',
  }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Counselling notes log ──
export async function getCaseNotes(caseId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('surgical_case_notes')
    .select('id, note, created_at, profiles:created_by ( id, full_name )')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false });
  if (error) return [];
  return data;
}

export async function addCaseNote(caseId, note) {
  if (!note || !note.trim()) return { error: 'Note cannot be empty.' };
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const { error } = await supabase.from('surgical_case_notes').insert({
    surgical_case_id: caseId,
    note: note.trim(),
    created_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Patient education topics (populated by the doctor's plan, M17/M19) ──
export async function getCounsellingItems(encounterId) {
  if (!encounterId) return [];
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('plan_counselling_items')
    .select('id, topic, status')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: true });
  if (error) return [];
  return data;
}

export async function toggleCounsellingItem(itemId, done) {
  const supabase = await createClient();
  const { error } = await supabase.from('plan_counselling_items').update({ status: done ? 'Done' : 'Pending' }).eq('id', itemId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Post-decision checklist (BR-SCC-004: only after package + Accepted) ──
async function requirePostDecision(supabase, caseId) {
  const { data: sc } = await supabase.from('surgical_cases').select('package_id, decision').eq('id', caseId).single();
  if (!(sc?.package_id && sc.decision === 'Accepted')) {
    return 'BR-SCC-004: Package must be confirmed and the patient decision must be Accepted first.';
  }
  return null;
}

// ── PRE-OP INVESTIGATIONS (usually blood work) ──
// Same master list Consultation's investigation picker uses (dept =
// Investigation in Financial Masters, Biometry excluded since that's
// its own dedicated step above) -- so an order placed here is the same
// kind of thing a doctor orders during a regular consultation, and
// lands in the same Investigation module queue for the lab to process.
export async function getInvestigationMasterOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('code, name').eq('status', 'Active').eq('dept', 'Investigation');
  // Substring match, not exact -- the catalog entry is named
  // "Biometry (Procedure Charge)", not literally "Biometry".
  return (data || []).filter((s) => !s.name.toLowerCase().includes('biometry'));
}

// Distinct standard panels (e.g. "Cataract" -> Blood, Sugar, HIV...)
// set up in Financial Masters against Investigation services, so
// Counselling can order a whole panel in one action instead of one
// investigation at a time.
export async function getInvestigationPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('investigation_package').eq('status', 'Active').eq('dept', 'Investigation').not('investigation_package', 'is', null);
  return [...new Set((data || []).map((s) => s.investigation_package).filter(Boolean))].sort();
}

export async function orderInvestigationPackage(caseId, encounterId, packageName) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!packageName) return { error: 'Select a package.' };

  const { data: services, error: svcError } = await supabase
    .from('master_services')
    .select('name')
    .eq('status', 'Active')
    .eq('dept', 'Investigation')
    .eq('investigation_package', packageName);
  if (svcError) return { error: svcError.message };
  if (!services || services.length === 0) return { error: 'No investigations found for this package.' };

  const { error } = await supabase.from('investigation_orders').insert(
    services.map((s) => ({ encounter_id: encounterId, name: s.name, eye: 'N/A', priority: 'Routine' }))
  );
  if (error) return { error: error.message };
  return { success: true, count: services.length };
}

export async function getCounsellingInvestigationOrders(encounterId) {
  const supabase = await createClient();
  if (!encounterId) return [];
  const { data } = await supabase
    .from('investigation_orders')
    .select('*')
    .eq('encounter_id', encounterId)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function orderCounsellingInvestigation(caseId, encounterId, values) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  if (!values.name?.trim()) return { error: 'Select or enter an investigation.' };

  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye || 'OU',
    priority: values.priority || 'Routine',
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeCounsellingInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markInvestigationsComplete(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ investigations_complete: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function markFitnessCleared(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };
  const { error } = await supabase.from('surgical_cases').update({ fitness_cleared: true }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// Medical fitness is no longer self-certified by the counsellor --
// it's referred to a doctor, who reviews clinical data, orders any
// investigations needed, and clears (or doesn't) via the Medical
// Fitness Dashboard/Workspace. This creates that referral, or -- if
// the case was previously marked Not Fit -- resets the same row back
// to Pending Review rather than creating a duplicate.
export async function referForMedicalFitness(caseId) {
  const supabase = await createClient();
  const gateError = await requirePostDecision(supabase, caseId);
  if (gateError) return { error: gateError };

  const { data: sc } = await supabase.from('surgical_cases').select('visit_id, encounter_id').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  const { data: userData } = await supabase.auth.getUser();
  const { data: existing } = await supabase
    .from('medical_fitness_referrals')
    .select('id, status')
    .eq('surgical_case_id', caseId)
    .order('created_at', { ascending: false })
    .limit(1);

  if (existing && existing.length > 0 && existing[0].status === 'Pending Review') {
    return { error: 'Already referred and awaiting doctor review.' };
  }

  if (existing && existing.length > 0 && existing[0].status === 'Not Fit') {
    const { error } = await supabase.from('medical_fitness_referrals').update({
      status: 'Pending Review', referred_by: userData?.user?.id || null, referred_at: new Date().toISOString(),
      reviewing_doctor_id: null, fitness_notes: null, cleared_by: null, cleared_at: null,
    }).eq('id', existing[0].id);
    if (error) return { error: error.message };
    return { success: true };
  }

  const { error } = await supabase.from('medical_fitness_referrals').insert({
    surgical_case_id: caseId, visit_id: sc.visit_id, encounter_id: sc.encounter_id, referred_by: userData?.user?.id || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── Ready for Scheduling ──
// NOTE: this intentionally does NOT require consent_taken. Per BR-SCC-005,
// consent is taken day-of-surgery (day-care model), not a pre-scheduling
// gate here -- that belongs to the Intraoperative module (M25). This is a
// behavior change from the previous version of this function, which did
// require consent_taken.
export async function markReadyForScheduling(caseId) {
  const supabase = await createClient();
  const { data: sc } = await supabase.from('surgical_cases').select('*').eq('id', caseId).single();
  if (!sc) return { error: 'Case not found.' };

  if (!sc.biometry_done && sc.biometry_required !== false) return { error: 'VAL-SCC-002: Biometry & IOL type advice must be complete.' };
  if (!sc.package_id) return { error: 'VAL-SCC-002: Select a package first.' };
  if (sc.decision !== 'Accepted') return { error: 'VAL-SCC-002: Patient decision must be Accepted.' };
  if (!sc.fitness_cleared && sc.fitness_required !== false) return { error: 'VAL-SCC-002: Medical fitness must be cleared.' };

  const { error } = await supabase.from('surgical_cases').update({ status: 'Ready for Scheduling' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

export async function referBackToDoctor(caseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('surgical_cases').update({ status: 'Pending Workup' }).eq('id', caseId);
  if (error) return { error: error.message };
  return { success: true };
}

// ── Surgeons ──
export async function getSurgeons() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name').ilike('designation', '%ophthalmologist%').eq('status', 'Active');
  return data || [];
}

// ── OT Booking -- last step of the Counselling workspace. Availability is
//    checked against master_ot_sessions.capacity (Financial Masters -- OT
//    Sessions), not free-form date/time like the old standalone OT
//    Scheduling module. Capacity check + insert happen atomically in the
//    book_ot_slot() DB function (see migration ot_booking_functions) so two
//    counsellors booking the same session at once can't both overbook it. ──
export async function getOTAvailability(date) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_ot_availability', { p_date: date });
  if (error) return [];
  return data || [];
}

export async function bookOTSlot(caseId, date, sessionId, surgeonId, notes) {
  const supabase = await createClient();
  if (!date) return { error: 'Date is required.' };
  if (!sessionId) return { error: 'Select an OT session.' };

  const { data, error } = await supabase.rpc('book_ot_slot', {
    p_case_id: caseId,
    p_date: date,
    p_session_id: sessionId,
    p_surgeon_id: surgeonId || null,
    p_notes: notes || null,
  });
  if (error) return { error: error.message };
  if (data?.error) return { error: data.error };
  return { success: true };
}

// ── OT Calendar -- now the 3rd tab of the Counselling module (was the
//    standalone /ot-schedule page). ──
export async function getOTSchedule() {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('ot_schedule')
    .select('*, surgical_cases(procedure_name, eye, patients(first_name, last_name, uhid)), profiles!ot_schedule_surgeon_id_fkey(full_name)')
    .neq('status', 'Cancelled')
    .order('scheduled_date', { ascending: true });
  if (error) return [];
  return data;
}

export async function completeOT(otScheduleId, surgicalCaseId) {
  const supabase = await createClient();

  const { error: otError } = await supabase.from('ot_schedule').update({ status: 'Completed' }).eq('id', otScheduleId);
  if (otError) return { error: otError.message };

  const { error: caseError } = await supabase.from('surgical_cases').update({ status: 'Completed' }).eq('id', surgicalCaseId);
  if (caseError) return { error: caseError.message };

  return { success: true };
}

JSEOF_17266223

echo "-- Writing app/(main)/counselling/page.js --"
mkdir -p "$(dirname "app/(main)/counselling/page.js")"
cat > "app/(main)/counselling/page.js" << 'JSEOF_6711322'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getCounsellingCases, getCounsellingHistory, getPackagesForCase, selectPackage, changePackage,
  setDecision, getCaseNotes, addCaseNote, getCounsellingItems, toggleCounsellingItem,
  markReadyForScheduling, referBackToDoctor,
  referForMedicalFitness,
  sendForBiometry, skipBiometry, unskipBiometry,
  getSurgeons, getOTAvailability, bookOTSlot, getOTSchedule, completeOT,
} from './actions';

// Biometry is satisfied either by actually being done, or by having
// been explicitly marked not required for this case (retina, glaucoma,
// oculoplasty...). Every gate that used to check biometry_done alone
// now goes through this.
function biometrySatisfied(sc) {
  return sc.biometry_done || sc.biometry_required === false;
}

function fitnessSatisfied(sc) {
  return sc.fitness_cleared || sc.fitness_required === false;
}

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

function readiness(sc) {
  const items = [
    { key: 'surgeryRec', label: 'Surgery Recommended', done: true },
    { key: 'biometry', label: sc.biometry_required === false ? 'Biometry & IOL Type Advised (M23) -- Skipped' : 'Biometry & IOL Type Advised (M23)', done: biometrySatisfied(sc) },
    { key: 'fitness', label: sc.fitness_required === false ? 'Medical Fitness -- Not Required' : 'Medical Fitness', done: fitnessSatisfied(sc) },
    { key: 'advance', label: 'Advance Payment', done: !!sc.advance_payment_id },
  ];
  const done = items.filter((i) => i.done).length;
  return { items, pct: Math.round((done / items.length) * 100) };
}

function PackagePicker({ sc, onUpdate }) {
  const [packages, setPackages] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState('');

  useEffect(() => {
    if (!biometrySatisfied(sc)) { setLoading(false); return; }
    getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoading(false); });
  }, [sc.biometry_done, sc.biometry_required, sc.iol_category]);

  if (!biometrySatisfied(sc)) {
    return (
      <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 12.5, background: 'var(--g50)', borderRadius: 'var(--r)' }}>
        <i className="ti ti-lock" style={{ fontSize: 20, display: 'block', marginBottom: 6 }}></i>
        Complete Biometry &amp; IOL type advice (M23) before presenting packages.
      </div>
    );
  }

  if (sc.master_packages) {
    return (
      <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 'var(--r)', padding: 12 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ fontWeight: 700, fontSize: 13 }}>{sc.master_packages.name}</div>
          <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 14 }}>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}</div>
        </div>
        {sc.package_locked && (
          <div style={{ fontSize: 10.5, color: 'var(--amber)', marginTop: 6 }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</div>
        )}
        {error && <div className="msg-err" style={{ marginTop: 8 }}>{error}</div>}
        <button
          className="btn btn-sm"
          style={{ marginTop: 8 }}
          onClick={async () => {
            setError('');
            let reason = null;
            if (sc.package_locked) {
              reason = window.prompt(`Package is locked (currently "${sc.master_packages.name}"). Enter a reason to change it:`);
              if (reason === null) return;
              if (!reason.trim()) { setError('A reason is required to change a locked package.'); return; }
            }
            const result = await changePackage(sc.id, reason);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
        >
          Change package
        </button>
      </div>
    );
  }

  if (loading) return <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
        Showing packages for IOL type: <strong>{sc.iol_category}</strong> (from Master Data)
      </div>
      {packages.length === 0 && (
        <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)' }}>
          No packages found for IOL type "{sc.iol_category}" in Master Data. Add one under Financial Masters &gt; Packages.
        </div>
      )}
      {packages.map((p) => (
        <button
          key={p.id}
          onClick={async () => {
            setError('');
            const result = await selectPackage(sc.id, p.id);
            if (result.error) { setError(result.error); return; }
            onUpdate();
          }}
          style={{ display: 'block', width: '100%', textAlign: 'left', border: '1.5px solid var(--g200)', borderRadius: 'var(--r)', padding: 12, marginBottom: 8, background: '#fff', cursor: 'pointer', fontFamily: 'inherit' }}
        >
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
              {p.name}
              {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{p.origin}</span>}
            </div>
            <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(p.price).toLocaleString('en-IN')}</div>
          </div>
          {p.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{p.includes}</div>}
        </button>
      ))}
    </div>
  );
}

function EducationPanel({ encounterId }) {
  const [items, setItems] = useState([]);

  const refresh = useCallback(() => {
    getCounsellingItems(encounterId).then(setItems);
  }, [encounterId]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-book" style={{ color: 'var(--teal)' }}></i> Patient education</div></div>
      {items.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No education topics logged from the doctor's plan.</div>}
      {items.map((item) => (
        <button
          key={item.id}
          onClick={async () => { await toggleCounsellingItem(item.id, item.status !== 'Done'); refresh(); }}
          style={{ display: 'flex', alignItems: 'center', gap: 8, width: '100%', textAlign: 'left', padding: '6px 4px', background: 'none', border: 'none', cursor: 'pointer', fontFamily: 'inherit', fontSize: 12.5 }}
        >
          <span style={{
            width: 16, height: 16, borderRadius: 4, border: '1.5px solid var(--g300)',
            background: item.status === 'Done' ? 'var(--teal)' : '#fff', borderColor: item.status === 'Done' ? 'var(--teal)' : 'var(--g300)',
            color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 10, flexShrink: 0,
          }}>
            {item.status === 'Done' ? '✓' : ''}
          </span>
          {item.topic}
        </button>
      ))}
    </div>
  );
}

function NotesPanel({ caseId }) {
  const [notes, setNotes] = useState([]);
  const [text, setText] = useState('');

  const refresh = useCallback(() => { getCaseNotes(caseId).then(setNotes); }, [caseId]);
  useEffect(() => { refresh(); }, [refresh]);

  async function handleSave() {
    if (!text.trim()) return;
    await addCaseNote(caseId, text);
    setText('');
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head"><div className="card-title"><i className="ti ti-notes" style={{ color: 'var(--g400)' }}></i> Counselling notes</div></div>
      <textarea className="fi" rows={3} value={text} onChange={(e) => setText(e.target.value)} placeholder="e.g. Patient wants surgery after 1 week..." />
      <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={handleSave}>Save note</button>
      <div style={{ marginTop: 10, display: 'flex', flexDirection: 'column', gap: 6 }}>
        {notes.map((n) => (
          <div key={n.id} style={{ fontSize: 11, background: 'var(--g50)', borderRadius: 'var(--r)', padding: '6px 8px' }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(n.created_at).toLocaleString('en-IN')} -- {n.profiles?.full_name || 'Staff'}: </span>
            {n.note}
          </div>
        ))}
      </div>
    </div>
  );
}

// Numbered, collapsible section -- same visual pattern as AsmtSection in
// Optometry History ([assessmentId]/assessment-viewer.js): numbered
// colored circle, title, chevron toggle.
function CounsellingSection({ num, color, title, badge, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {badge}
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

// ── Book Surgery Slot -- last step of Counselling, replaces the old
//    standalone OT Scheduling module. Picking a date loads that date's OT
//    sessions (Morning/Midday/Afternoon etc, from Financial Masters) with
//    live booked/remaining counts so the counsellor books strictly within
//    capacity. ──
function BookSurgerySlot({ sc, onUpdate }) {
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessions, setSessions] = useState([]);
  const [sessionId, setSessionId] = useState('');
  const [notes, setNotes] = useState('');
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [booking, setBooking] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  useEffect(() => {
    setSessionId('');
    setError('');
    if (!date) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(date).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [date]);

  async function handleBook() {
    setError('');
    if (!date) { setError('Pick a date.'); return; }
    if (!sessionId) { setError('Select an OT session.'); return; }
    setBooking(true);
    const result = await bookOTSlot(sc.id, date, sessionId, surgeonId, notes);
    setBooking(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 10 }}>
        <div>
          <label className="flbl">Surgeon</label>
          <select className="fi" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
            <option value="">-- Surgeon --</option>
            {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
          </select>
        </div>
        <div>
          <label className="flbl">Surgery Date</label>
          <input type="date" className="fi" value={date} min={new Date().toISOString().slice(0, 10)} onChange={(e) => setDate(e.target.value)} />
        </div>
      </div>

      {date && (
        <div style={{ marginBottom: 10 }}>
          <label className="flbl">OT Session</label>
          {loadingSessions ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Checking availability...</div>
          ) : sessions.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>
          ) : (
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                const selected = sessionId === s.session_id;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => setSessionId(s.session_id)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', minWidth: 160,
                      background: selected ? 'var(--purple)' : full ? 'var(--g100)' : '',
                      color: selected ? '#fff' : full ? 'var(--g400)' : '',
                      borderColor: selected ? 'transparent' : '',
                      cursor: full ? 'not-allowed' : 'pointer',
                    }}
                  >
                    <div style={{ fontWeight: 700 }}>{s.name}</div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}
                    </div>
                    <div style={{ fontSize: 10.5, opacity: .85 }}>
                      {full ? 'FULL' : `${s.remaining} of ${s.capacity} slots left`}
                    </div>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}

      <input className="fi" placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} style={{ marginBottom: 10 }} />

      <button className="btn btn-primary btn-sm" onClick={handleBook} disabled={booking || !date || !sessionId}>
        {booking ? 'Booking...' : 'Confirm Surgery Slot'}
      </button>
    </div>
  );
}

function CaseWorkspace({ sc, onUpdate }) {
  const [error, setError] = useState('');
  const [ancillaryMsg, setAncillaryMsg] = useState(null); // { type: 'error'|'success', text }
  const [sendingBiometry, setSendingBiometry] = useState(false);
  const [openSections, setOpenSections] = useState({ surgery: true, biometry: true, decision: true, fitness: true });
  const { items, pct } = readiness(sc);
  const stage2Unlocked = !!sc.package_id && sc.decision === 'Accepted';
  const [referringFitness, setReferringFitness] = useState(false);

  async function handleReferFitness() {
    setError('');
    setReferringFitness(true);
    const result = await referForMedicalFitness(sc.id);
    setReferringFitness(false);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleDecision(d) {
    setError('');
    let reason = null;
    if (sc.decision_locked && d !== sc.decision) {
      reason = window.prompt(`Decision is locked (currently "${sc.decision}"). Enter a reason to change it to "${d}":`);
      if (reason === null) return; // cancelled
      if (!reason.trim()) { setError('A reason is required to change a locked decision.'); return; }
    }
    const result = await setDecision(sc.id, d, reason);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleReady() {
    setError('');
    const result = await markReadyForScheduling(sc.id);
    if (result.error) { setError(result.error); return; }
    onUpdate();
  }

  async function handleSendForBiometry() {
    setAncillaryMsg(null);
    setSendingBiometry(true);
    const result = await sendForBiometry(sc.id);
    setSendingBiometry(false);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    setAncillaryMsg({ type: 'success', text: 'Sent -- patient will show as Awaiting Biometry in the Biometry queue.' });
    onUpdate();
  }

  async function handleSkipBiometry() {
    const reason = window.prompt('Why is Biometry not required for this case? (e.g. Retina surgery -- no IOL power needed)');
    if (reason === null) return;
    setAncillaryMsg(null);
    const result = await skipBiometry(sc.id, reason);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  async function handleUnskipBiometry() {
    setAncillaryMsg(null);
    const result = await unskipBiometry(sc.id);
    if (result.error) { setAncillaryMsg({ type: 'error', text: result.error }); return; }
    onUpdate();
  }

  const advancePaid = !!sc.advance_payment_id;
  const fitnessItem = items.find((i) => i.key === 'fitness');

  return (
    <div style={{ marginBottom: 16 }}>
      {/* PATIENT STRIP -- fixed at top of the workspace, same visual language as Optometry History */}
      <div style={{
        position: 'sticky', top: 0, zIndex: 5,
        background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '12px 16px', color: '#fff',
        marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14,
      }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {sc.patients?.first_name?.charAt(0) || '?'}
        </div>
        <div style={{ flex: 1 }}>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{sc.patients?.first_name} {sc.patients?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{sc.patients?.age} -- {sc.patients?.gender} -- {sc.patients?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.procedure_name} -- {sc.eye}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.priority}
            </span>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              {sc.profiles?.full_name || 'Unassigned surgeon'}
            </span>
          </div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>IOL Type Advised</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{sc.iol_category || (sc.biometry_required === false ? 'Not applicable' : 'Pending biometry')}</div>
          <span className={`badge ${sc.status === 'Ready for Scheduling' ? 'b-green' : 'b-amber'}`} style={{ marginTop: 4 }}>{sc.status}</span>
          <div style={{ fontSize: 10, opacity: .7, marginTop: 4 }}>{pct}% ready</div>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {/* 1. SURGERY ADVISED */}
      <CounsellingSection num={1} color="var(--g500)" title="Surgery Advised" open={openSections.surgery} onToggle={() => toggleSection('surgery')}
        badge={<span className="badge b-green"><i className="ti ti-check"></i> Done</span>}>
        <div style={{ fontSize: 12.5, color: 'var(--g600)' }}>
          <div><strong>{sc.procedure_name}</strong> -- {sc.eye} -- {sc.priority}</div>
          <div style={{ color: 'var(--g500)', marginTop: 4 }}>Surgeon: {sc.profiles?.full_name || 'Unassigned'}</div>
        </div>
      </CounsellingSection>

      {/* 2. BIOMETRY */}
      <CounsellingSection num={2} color="var(--blue)" title="Biometry" open={openSections.biometry} onToggle={() => toggleSection('biometry')}
        badge={
          sc.biometry_done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : sc.biometry_required === false
            ? <span className="badge b-purple">Not Required</span>
            : sc.biometry_record
            ? <span className="badge b-blue">Awaiting Technician</span>
            : <span className="badge b-amber">Not sent</span>
        }>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
          {sc.biometry_done ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Biometry Complete -- {sc.iol_category}</span>
          ) : sc.biometry_required === false ? (
            <>
              <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required -- {sc.biometry_skip_reason}</span>
              <button className="btn btn-sm" onClick={handleUnskipBiometry} style={{ fontSize: 11 }}>Undo -- make required again</button>
            </>
          ) : sc.biometry_record ? (
            <>
              <span className="badge b-blue"><i className="ti ti-clock"></i> Biometry Requested -- Awaiting Technician</span>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry} style={{ fontSize: 11 }}>
                {sendingBiometry ? 'Sending...' : 'Send again'}
              </button>
            </>
          ) : (
            <>
              <button className="btn btn-sm" onClick={handleSendForBiometry} disabled={sendingBiometry}>
                <i className="ti ti-ruler-measure"></i> {sendingBiometry ? 'Sending...' : 'Send for Biometry'}
              </button>
              <button className="btn btn-sm" onClick={handleSkipBiometry} style={{ fontSize: 11 }}>
                <i className="ti ti-player-skip-forward"></i> Not required for this surgery
              </button>
            </>
          )}
          {ancillaryMsg && (
            <span style={{ fontSize: 11.5, color: ancillaryMsg.type === 'error' ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>
              {ancillaryMsg.text}
            </span>
          )}
        </div>
      </CounsellingSection>

      {/* 3. PATIENT DECISION -- package + decision, with Advance Payment as a sub-point */}
      <CounsellingSection num={3} color="var(--purple)" title="Patient Decision" open={openSections.decision} onToggle={() => toggleSection('decision')}
        badge={
          sc.decision === 'Accepted'
            ? <span className="badge b-green"><i className="ti ti-check"></i> Accepted</span>
            : sc.decision
            ? <span className="badge b-amber">{sc.decision}</span>
            : <span className="badge b-gray">Pending</span>
        }>
        <div style={{ marginBottom: 16 }}>
          <label className="flbl">Package</label>
          <PackagePicker sc={sc} onUpdate={onUpdate} />
        </div>

        <div style={{ marginBottom: 16 }}>
          <label className="flbl">
            Decision {sc.decision_locked && <span style={{ color: 'var(--amber)', fontWeight: 400, textTransform: 'none' }}><i className="ti ti-lock"></i> Locked -- changing requires a reason</span>}
          </label>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
            {DECISIONS.map((d) => (
              <button
                key={d}
                onClick={() => handleDecision(d)}
                className="btn btn-sm"
                style={sc.decision === d ? {
                  background: d === 'Accepted' ? 'var(--green)' : d === 'Declined' ? 'var(--red)' : 'var(--purple)',
                  color: '#fff', borderColor: 'transparent',
                } : {}}
              >
                {d}
              </button>
            ))}
          </div>
        </div>

        {/* Sub-point: Advance Payment */}
        <div style={{ borderLeft: '3px solid var(--g200)', paddingLeft: 12, marginTop: 4 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 6 }}>
            3a. Advance Payment
          </div>
          {advancePaid ? (
            <span className="badge b-green"><i className="ti ti-check"></i> Advance Paid</span>
          ) : (
            <span className="badge b-amber">Not yet collected -- via Billing (M11)</span>
          )}
        </div>
      </CounsellingSection>

      {/* 4. MEDICAL FITNESS */}
      <CounsellingSection num={4} color="var(--amber)" title="Medical Fitness" open={openSections.fitness} onToggle={() => toggleSection('fitness')}
        badge={
          fitnessItem?.done && sc.fitness_required === false
            ? <span className="badge b-purple">Not Required</span>
            : fitnessItem?.done
            ? <span className="badge b-green"><i className="ti ti-check"></i> Done</span>
            : <span className="badge b-amber">Pending</span>
        }>
        {!stage2Unlocked ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Locked until package confirmed and decision is Accepted.</div>
        ) : sc.fitness_required === false && !sc.fitness_referral ? (
          <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case -- per doctor's advice at consultation</span>
        ) : (
          <>
            {!sc.fitness_referral && (
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
                  Refer this patient to a doctor to review clinical data, order any investigations needed, and clear for surgery.
                </div>
                <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                  <i className="ti ti-heart-rate-monitor"></i> {referringFitness ? 'Referring...' : 'Refer to Doctor'}
                </button>
              </div>
            )}
            {sc.fitness_referral?.status === 'Pending Review' && (
              <span className="badge b-amber"><i className="ti ti-clock"></i> Referred to doctor -- awaiting review ({new Date(sc.fitness_referral.referred_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })})</span>
            )}
            {sc.fitness_referral?.status === 'Cleared' && (
              <div>
                <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
              </div>
            )}
            {sc.fitness_referral?.status === 'Not Fit' && (
              <div>
                <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
                {sc.fitness_referral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{sc.fitness_referral.fitness_notes}</div>}
                <div style={{ marginTop: 8 }}>
                  <button className="btn btn-sm" onClick={handleReferFitness} disabled={referringFitness}>
                    <i className="ti ti-refresh"></i> {referringFitness ? 'Referring...' : 'Refer Again'}
                  </button>
                </div>
              </div>
            )}
          </>
        )}
      </CounsellingSection>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
        <EducationPanel encounterId={sc.encounter_id} />
        <NotesPanel caseId={sc.id} />
      </div>

      {/* BOOK SURGERY SLOT -- only once Ready for Scheduling */}
      {sc.status === 'Ready for Scheduling' && (
        <CounsellingSection num="OT" color="var(--indigo)" title="Book Surgery Slot" open onToggle={() => {}}
          badge={<span className="badge b-green"><i className="ti ti-check"></i> Ready</span>}>
          <BookSurgerySlot sc={sc} onUpdate={onUpdate} />
        </CounsellingSection>
      )}

      {sc.status === 'Scheduled' && (
        <div className="msg-success" style={{ marginBottom: 16 }}>
          <i className="ti ti-circle-check"></i> Surgery slot booked -- see the OT Calendar tab.
        </div>
      )}

      <div style={{ display: 'flex', gap: 8 }}>
        <button
          className="btn btn-sm"
          onClick={async () => { await referBackToDoctor(sc.id); onUpdate(); }}
        >
          Refer back to doctor
        </button>
        {sc.status === 'Pending Workup' && (
          <button className="btn btn-primary btn-sm" onClick={handleReady}>Ready for Scheduling (VAL-SCC-002)</button>
        )}
      </div>
    </div>
  );
}

// ── Pre-op counselling stage, derived from real columns (not stored --
//    surgical_cases.status stays limited to Pending Workup / Ready for
//    Scheduling / Scheduled / Completed / Cancelled, since OT Scheduling
//    relies on those exact values). This just groups cases for the
//    dashboard so the counsellor can see where each patient actually is. ──
const STAGES = [
  { key: 'surgery_advised',     label: 'Surgery Advised',                badge: 'b-gray'   },
  { key: 'awaiting_biometry',   label: 'Awaiting Biometry',              badge: 'b-blue'   },
  { key: 'awaiting_package',    label: 'Awaiting Package Presentation',  badge: 'b-teal'   },
  { key: 'awaiting_decision',   label: 'Waiting for Patient Decision',   badge: 'b-amber'  },
  { key: 'financial_constraint',label: 'Financial Constraint',           badge: 'b-red'    },
  { key: 'finalised',           label: 'Finalised -- Prep Pending',      badge: 'b-purple' },
  { key: 'ready',               label: 'Ready for Scheduling',           badge: 'b-green'  },
  { key: 'declined',            label: 'Declined',                       badge: 'b-gray'   },
];
const STAGE_MAP = Object.fromEntries(STAGES.map((s) => [s.key, s]));

function getStage(sc) {
  if (sc.status === 'Ready for Scheduling') return 'ready';
  if (!sc.biometry_done && sc.biometry_required !== false) return sc.biometry_record ? 'awaiting_biometry' : 'surgery_advised';
  if (!sc.package_id) return 'awaiting_package';
  if (sc.decision === 'Declined') return 'declined';
  if (sc.decision === 'Financial Constraint') return 'financial_constraint';
  if (sc.decision === 'Accepted') return 'finalised';
  return 'awaiting_decision'; // null, Wants Time to Decide, Discuss with Family, Second Opinion, Other
}

function daysWaiting(sc) {
  return Math.floor((Date.now() - new Date(sc.created_at).getTime()) / 86400000);
}

function KpiCard({ label, value, sub, color, active, onClick }) {
  return (
    <button
      onClick={onClick}
      className="card"
      style={{ borderLeft: `3px solid ${color}`, marginBottom: 0, textAlign: 'left', cursor: 'pointer', background: active ? 'var(--g50)' : '#fff', fontFamily: 'inherit' }}
    >
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </button>
  );
}

function CounsellingDashboard({ cases, onOpen }) {
  const [stageFilter, setStageFilter] = useState('');
  const [search, setSearch] = useState('');
  const [sortBy, setSortBy] = useState('oldest');

  const counts = STAGES.reduce((acc, s) => { acc[s.key] = 0; return acc; }, {});
  cases.forEach((sc) => { counts[getStage(sc)]++; });

  let rows = cases.map((sc) => ({ sc, stage: getStage(sc) }));
  if (stageFilter) rows = rows.filter((r) => r.stage === stageFilter);
  if (search.trim()) {
    const q = search.trim().toLowerCase();
    rows = rows.filter(({ sc }) =>
      `${sc.patients?.first_name} ${sc.patients?.last_name}`.toLowerCase().includes(q) ||
      (sc.patients?.uhid || '').toLowerCase().includes(q)
    );
  }
  rows.sort((a, b) => {
    if (sortBy === 'oldest') return new Date(a.sc.created_at) - new Date(b.sc.created_at);
    if (sortBy === 'newest') return new Date(b.sc.created_at) - new Date(a.sc.created_at);
    if (sortBy === 'priority') {
      const order = { Emergency: 0, Urgent: 1, Routine: 2 };
      return (order[a.sc.priority] ?? 9) - (order[b.sc.priority] ?? 9);
    }
    return 0;
  });

  return (
    <div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 12 }}>
        <KpiCard label="Active cases" value={cases.filter((sc) => sc.status !== 'Ready for Scheduling').length + counts.ready} sub="All pre-op stages" color="var(--indigo)" active={!stageFilter} onClick={() => setStageFilter('')} />
        <KpiCard label="Waiting on patient" value={counts.awaiting_decision + counts.financial_constraint} sub="Decision or finance pending" color="var(--amber)" active={stageFilter === 'awaiting_decision'} onClick={() => setStageFilter('awaiting_decision')} />
        <KpiCard label="Finalised -- prep pending" value={counts.finalised} sub="Accepted, tests/fitness pending" color="var(--purple)" active={stageFilter === 'finalised'} onClick={() => setStageFilter('finalised')} />
        <KpiCard label="Ready for scheduling" value={counts.ready} sub="Go to OT Scheduling" color="var(--green)" active={stageFilter === 'ready'} onClick={() => setStageFilter('ready')} />
      </div>

      <div className="card">
        <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
          <div className="card-title"><i className="ti ti-list-numbers" style={{ color: 'var(--indigo)' }}></i> Counselling Queue</div>
          <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
            <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 170 }} />
            <select className="fi fi-sm" value={sortBy} onChange={(e) => setSortBy(e.target.value)} style={{ width: 130 }}>
              <option value="oldest">Oldest first</option>
              <option value="newest">Newest first</option>
              <option value="priority">Priority</option>
            </select>
          </div>
        </div>

        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6, marginBottom: 12 }}>
          <button className={`btn btn-sm ${!stageFilter ? 'btn-primary' : ''}`} onClick={() => setStageFilter('')}>All ({cases.length})</button>
          {STAGES.map((s) => (
            <button key={s.key} className={`btn btn-sm ${stageFilter === s.key ? 'btn-primary' : ''}`} onClick={() => setStageFilter(s.key)}>
              {s.label} ({counts[s.key]})
            </button>
          ))}
        </div>

        {rows.map(({ sc, stage }) => {
          const dw = daysWaiting(sc);
          return (
            <div key={sc.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
              <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--purple)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
                {sc.patients?.first_name?.charAt(0) || '?'}
              </div>
              <div style={{ flex: 1, minWidth: 0 }}>
                <span style={{ fontWeight: 700, fontSize: 13 }}>{sc.patients?.first_name} {sc.patients?.last_name}</span>
                <span className={`badge ${STAGE_MAP[stage].badge}`} style={{ marginLeft: 8, fontSize: 10 }}>{STAGE_MAP[stage].label}</span>
                {sc.priority !== 'Routine' && <span className="badge b-red" style={{ marginLeft: 4, fontSize: 10 }}>{sc.priority}</span>}
                <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                  {sc.patients?.uhid} -- {sc.procedure_name} {sc.eye} -- {sc.iol_category || 'IOL type pending'} -- {sc.profiles?.full_name || 'Unassigned surgeon'}
                </div>
              </div>
              <div style={{ textAlign: 'right', fontSize: 10, color: dw > 7 ? 'var(--red)' : dw > 3 ? 'var(--amber)' : 'var(--g400)', fontWeight: 600, width: 70 }}>
                {dw === 0 ? 'Today' : `${dw}d waiting`}
              </div>
              <button className="btn btn-sm btn-primary" onClick={() => onOpen(sc.id)}>
                <i className="ti ti-arrow-right"></i> Open
              </button>
            </div>
          );
        })}

        {rows.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
            <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
            {cases.length === 0 ? 'No cases pending counselling. Mark a patient for surgery from their Consultation.' : 'No cases match this filter.'}
          </div>
        )}
      </div>
    </div>
  );
}

// ── OT Calendar tab -- the read-only schedule + Complete action that used
//    to be the whole of the standalone OT Scheduling page. Booking itself
//    now happens inline in each case's workspace (BookSurgerySlot above). ──
function OTCalendar() {
  const [schedule, setSchedule] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setSchedule(await getOTSchedule());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleComplete(otId, caseId) {
    await completeOT(otId, caseId);
    refresh();
  }

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading OT calendar...</div>;

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-calendar-event" style={{ color: 'var(--blue)' }}></i> OT Calendar
      </div>
      <table className="tbl">
        <thead>
          <tr><th>Date</th><th>Session</th><th>Room</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {schedule.map((s) => (
            <tr key={s.id}>
              <td>{new Date(s.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}</td>
              <td>{s.scheduled_time?.slice(0, 5) || '--'}</td>
              <td>{s.room || '--'}</td>
              <td>{s.surgical_cases?.patients?.first_name} {s.surgical_cases?.patients?.last_name}</td>
              <td>{s.surgical_cases?.procedure_name} -- {s.surgical_cases?.eye}</td>
              <td>{s.profiles?.full_name || '--'}</td>
              <td><span className={`badge ${s.status === 'Completed' ? 'b-green' : 'b-blue'}`}>{s.status}</span></td>
              <td>
                {s.status === 'Scheduled' && (
                  <button className="btn btn-sm" onClick={() => handleComplete(s.id, s.surgical_case_id)}>Complete</button>
                )}
              </td>
            </tr>
          ))}
          {schedule.length === 0 && (
            <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No surgeries scheduled.</td></tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

// ── History tab -- cases that have left the active Dashboard (Scheduled,
//    Completed, Cancelled, etc). Read-only lookup, same pattern as the
//    History tabs elsewhere in the app (Post-op, Investigation,
//    Optometry). Opens the same CaseWorkspace as an active case -- its
//    action buttons already only render for statuses that are still
//    actionable, so a past case naturally shows as read-only. ──
function HistoryTab({ cases, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? cases.filter((sc) => {
        const q = search.trim().toLowerCase();
        const p = sc.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : cases;

  const STATUS_BADGE = { Scheduled: 'b-blue', Completed: 'b-green', Cancelled: 'b-red' };

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Counselling History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Decision</th><th>Status</th><th>Date</th><th></th></tr></thead>
          <tbody>
            {filtered.map((sc) => (
              <tr key={sc.id} onClick={() => onOpen(sc.id)} style={{ cursor: 'pointer' }}>
                <td><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span></td>
                <td style={{ fontSize: 12 }}>{sc.procedure_name} ({sc.eye})</td>
                <td style={{ fontSize: 12 }}>{sc.profiles?.full_name || '--'}</td>
                <td style={{ fontSize: 12 }}>{sc.decision || '--'}</td>
                <td><span className={`badge ${STATUS_BADGE[sc.status] || 'b-gray'}`} style={{ fontSize: 10 }}>{sc.status}</span></td>
                <td style={{ fontSize: 11 }}>{sc.created_at ? new Date(sc.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No past cases yet.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      className={`snbtn ${active ? 'active' : ''}`}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

export default function CounsellingPage() {
  const [cases, setCases] = useState([]);
  const [historyCases, setHistoryCases] = useState([]);
  const [loading, setLoading] = useState(true);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(null);

  const refresh = useCallback(async () => {
    setCases(await getCounsellingCases());
    setLoading(false);
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistoryCases(await getCounsellingHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => { refresh(); refreshHistory(); }, [refresh, refreshHistory]);

  function openCase(id) {
    setSelectedCaseId(id);
    setActiveTab('workspace');
  }

  function handleUpdate() {
    refresh(); refreshHistory();
  }

  const selectedCase = cases.find((sc) => sc.id === selectedCaseId) || historyCases.find((sc) => sc.id === selectedCaseId) || null;

  if (loading) return <div style={{ padding: 20, color: 'var(--g400)', fontSize: 13 }}>Loading counselling cases...</div>;

  return (
    <div>
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 540 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-messages" label="Workspace" disabled={!selectedCase} />
        <TabButton active={activeTab === 'otcalendar'} onClick={() => setActiveTab('otcalendar')} icon="ti-calendar-event" label="OT Calendar" />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <CounsellingDashboard cases={cases} onOpen={openCase} />}

      {activeTab === 'workspace' && selectedCase && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => setActiveTab('dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Dashboard
          </button>
          <CaseWorkspace sc={selectedCase} onUpdate={handleUpdate} />
        </div>
      )}

      {activeTab === 'workspace' && !selectedCase && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Select a patient from the Dashboard tab.
        </div>
      )}

      {activeTab === 'otcalendar' && <OTCalendar />}

      {activeTab === 'history' && <HistoryTab cases={historyCases} loading={loadingHistory} onOpen={openCase} />}
    </div>
  );
}

JSEOF_6711322

echo "-- Writing app/(main)/doctor-dashboard/page.js --"
mkdir -p "$(dirname "app/(main)/doctor-dashboard/page.js")"
cat > "app/(main)/doctor-dashboard/page.js" << 'JSEOF_9804792'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getDoctorDashboardData, getDoctorHistory } from './actions';
import { doctorCallNext, doctorCallSpecific, doctorMarkReady, doctorCallDirect } from '@/app/(main)/queue/actions';
import ConsultationForm from '@/app/(main)/consultation/[id]/consultation-form';
import PostOpWorkspace from '@/app/(main)/ot-postop/workspace';
import { getOpenPostOpEpisodeForPatient } from '@/app/(main)/ot-postop/actions';
import BiometryWorkspace from '@/app/(main)/biometry/[id]/workspace';
import { getBiometryApprovalsToday } from '@/app/(main)/biometry/actions';
import { WorkspaceTab as MedicalFitnessWorkspace } from '@/app/(main)/medical-fitness/page';
import { getMedicalFitnessToday } from '@/app/(main)/medical-fitness/actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

function TokenBadge({ token, color }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: color || 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--blue)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function DashboardTab({ active, intermediate, completed, optometryWaiting, biometryApprovals, medicalFitnessToday, visitTypeCounts, totalVisitsToday, error, onRunAction, onOpen, onOpenBiometry, onOpenMedicalFitness }) {
  const inConsultation = active.find((e) => e.status === 'In Consultation');
  const waitingCount = active.filter((e) => e.status === 'Waiting' || e.status === 'Ready for Review').length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Consultation</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{inConsultation ? 1 : 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>With doctor now</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting for Doctor</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>In doctor queue</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Intermediate</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{intermediate.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Dilation / Investigation</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Completed Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{completed.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Encounters closed</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20, marginBottom: 20 }}>
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue<span className="badge b-gray">{active.length}</span></div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => onRunAction(doctorCallNext)} disabled={!!inConsultation}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {inConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={inConsultation.token} color="var(--blue)" />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(inConsultation)}</span>
              </div>
              <div style={{ marginBottom: 8 }}>
                <span className={`badge ${waitBadgeClass(elapsedMin(inConsultation.called_at || inConsultation.issued_at))}`}>
                  <i className="ti ti-clock"></i> In consultation {elapsedMin(inConsultation.called_at || inConsultation.issued_at)}m
                </span>
              </div>
              <button className="btn btn-primary btn-sm" onClick={() => onOpen(inConsultation)}>
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </button>
            </div>
          )}

          {active.filter((e) => e.id !== inConsultation?.id).map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} color={e.status === 'Ready for Review' ? 'var(--green)' : 'var(--amber)'} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                  {e.visits?.visit_type === 'Post-operative Review' && <span className="badge b-purple" style={{ marginLeft: 6, fontSize: 10 }}>Post-op Review</span>}
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Ready for Review' ? 'b-green' : 'b-amber'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}><i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallSpecific, e.id)} disabled={!!inConsultation}>Call</button>
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* INTERMEDIATE QUEUE -- side by side with Doctor Queue, not
            buried further down, since it's just as time-sensitive
            (patients sent out for Dilation/Investigation/Biometry who
            need to be pulled back in). */}
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> Intermediate Queue<span className="badge b-gray">{intermediate.length}</span></div>
          </div>
          {intermediate.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.status} -- {elapsedMin(e.sent_out_at)}m</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorMarkReady, e.id)}>Mark Ready</button>
            </div>
          ))}
          {intermediate.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              No one in Dilation, Investigation, or Biometry.
            </div>
          )}
        </div>
      </div>

      {/* Everything else -- side by side in pairs rather than one long
          vertical stack. */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* VISIT TYPE BREAKDOWN -- same widget as Front Office Dashboard */}
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
          </div>
          {Object.keys(visitTypeCounts || {}).length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
          )}
          {Object.entries(visitTypeCounts || {}).map(([type, count]) => (
            <div key={type} style={{ marginBottom: 8 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
              </div>
              <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                <div style={{
                  width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                  height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                }}></div>
              </div>
            </div>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-eye" style={{ color: 'var(--teal)' }}></i> Waiting in Optometry<span className="badge b-gray">{optometryWaiting.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>
            Pull a patient straight into consultation without waiting for their optometry workup -- useful for quick reviews or referrals.
          </div>
          {optometryWaiting.map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                {patientName(e)}
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.issued_at)}m waiting in Optometry</div>
              </div>
              <button className="btn btn-sm" onClick={() => onRunAction(doctorCallDirect, e.id)} disabled={!!inConsultation}>
                <i className="ti ti-arrow-right"></i> Call Directly
              </button>
            </div>
          ))}
          {optometryWaiting.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No one currently waiting in Optometry.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry Approvals<span className="badge b-gray">{biometryApprovals.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's visits only. Only a doctor can approve.</div>
          {biometryApprovals.map((b) => (
            <div key={b.id} onClick={() => onOpenBiometry(b.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {b.visits?.patients?.first_name} {b.visits?.patients?.last_name}
                <span className="badge b-indigo" style={{ marginLeft: 6, fontSize: 10 }}>{b.surgical_eye}</span>
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{b.visits?.patients?.uhid}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-shield-check"></i> Approve</button>
            </div>
          ))}
          {biometryApprovals.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing awaiting approval today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-heart-rate-monitor" style={{ color: 'var(--amber)' }}></i> Medical Fitness<span className="badge b-gray">{medicalFitnessToday.length}</span></div>
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Today's referrals only.</div>
          {medicalFitnessToday.map((r) => (
            <div key={r.id} onClick={() => onOpenMedicalFitness(r.id)} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}>
              <div>
                {r.visits?.patients?.first_name} {r.visits?.patients?.last_name}
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>{r.visits?.patients?.uhid} -- {r.surgical_cases?.procedure_name}</div>
              </div>
              <button className="btn btn-sm btn-primary"><i className="ti ti-arrow-right"></i> Review</button>
            </div>
          ))}
          {medicalFitnessToday.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending today.</div>}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today<span className="badge b-green">{completed.length}</span></div>
          </div>
          {completed.slice(0, 8).map((e) => (
            <div
              key={e.id}
              onClick={() => onOpen(e)}
              style={{ display: 'block', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12, cursor: 'pointer' }}
            >
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                <span><span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span> {patientName(e)}</span>
                <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
              </div>
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                {e.completed_at ? new Date(e.completed_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' }) : '--'}
              </div>
            </div>
          ))}
          {completed.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing completed yet today.</div>}
        </div>
      </div>
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = search.trim()
    ? rows.filter((e) => {
        const q = search.trim().toLowerCase();
        const p = e.visits?.patients;
        return `${p?.first_name} ${p?.last_name}`.toLowerCase().includes(q) || (p?.uhid || '').toLowerCase().includes(q);
      })
    : rows;

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--g500)' }}></i> Consultation History</div>
        <input className="fi fi-sm" placeholder="Search patient / UHID" value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 180 }} />
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && (
        <table className="tbl">
          <thead><tr><th>Token</th><th>Patient</th><th>Completed</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <tr key={e.id} onClick={() => onOpen(e)} style={{ cursor: 'pointer' }}>
                <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{e.token}</td>
                <td>
                  <strong>{patientName(e)}</strong>
                  <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{e.visits?.patients?.uhid}</span>
                </td>
                <td style={{ fontSize: 11 }}>{e.completed_at ? new Date(e.completed_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '--'}</td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
            {filtered.length === 0 && <tr><td colSpan={4} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed consultations found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorDashboardPage() {
  const [activeTab, setActiveTab] = useState('dashboard');
  const [selectedId, setSelectedId] = useState(null);
  const [postOpEpisodeId, setPostOpEpisodeId] = useState(null);
  const [biometryId, setBiometryId] = useState(null);
  const [medFitnessId, setMedFitnessId] = useState(null);
  const [active, setActive] = useState([]);
  const [intermediate, setIntermediate] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [optometryWaiting, setOptometryWaiting] = useState([]);
  const [biometryApprovals, setBiometryApprovals] = useState([]);
  const [medicalFitnessToday, setMedicalFitnessToday] = useState([]);
  const [visitTypeCounts, setVisitTypeCounts] = useState({});
  const [totalVisitsToday, setTotalVisitsToday] = useState(0);
  const [history, setHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const result = await getDoctorDashboardData();
    setActive(result.active);
    setIntermediate(result.intermediate);
    setCompleted(result.completed);
    setOptometryWaiting(result.optometryWaiting);
    setVisitTypeCounts(result.visitTypeCounts);
    setTotalVisitsToday(result.totalVisitsToday);
    setBiometryApprovals(await getBiometryApprovalsToday());
    setMedicalFitnessToday(await getMedicalFitnessToday());
  }, []);

  const refreshHistory = useCallback(async () => {
    setHistory(await getDoctorHistory());
    setLoadingHistory(false);
  }, []);

  useEffect(() => {
    refresh();
    refreshHistory();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh, refreshHistory]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  async function openConsultation(entry) {
    if (entry.visits?.visit_type === 'Post-operative Review') {
      const episodeId = await getOpenPostOpEpisodeForPatient(entry.visits.patients.id);
      if (!episodeId) {
        setError('This is marked as a Post-operative Review visit, but no open post-op episode was found for this patient.');
        return;
      }
      setPostOpEpisodeId(episodeId);
      setSelectedId(null); setBiometryId(null); setMedFitnessId(null);
      setActiveTab('workspace');
      return;
    }
    setPostOpEpisodeId(null); setBiometryId(null); setMedFitnessId(null);
    setSelectedId(entry.id);
    setActiveTab('workspace');
  }

  function openBiometry(id) {
    setSelectedId(null); setPostOpEpisodeId(null); setMedFitnessId(null);
    setBiometryId(id);
    setActiveTab('workspace');
  }

  function openMedicalFitness(id) {
    setSelectedId(null); setPostOpEpisodeId(null); setBiometryId(null);
    setMedFitnessId(id);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh(); refreshHistory();
    setSelectedId(null);
    setPostOpEpisodeId(null);
    setBiometryId(null);
    setMedFitnessId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      {activeTab !== 'workspace' && (
        <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-clipboard-text" label="Workspace" disabled={!selectedId && !postOpEpisodeId && !biometryId && !medFitnessId} />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
      )}

      {activeTab === 'dashboard' && (
        <DashboardTab
          active={active} intermediate={intermediate} completed={completed} optometryWaiting={optometryWaiting}
          biometryApprovals={biometryApprovals} medicalFitnessToday={medicalFitnessToday}
          visitTypeCounts={visitTypeCounts} totalVisitsToday={totalVisitsToday}
          error={error} onRunAction={runAction} onOpen={openConsultation}
          onOpenBiometry={openBiometry} onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'workspace' && postOpEpisodeId && (
        <PostOpWorkspace episodeId={postOpEpisodeId} onBack={handleBack} onUpdate={() => {}} />
      )}
      {activeTab === 'workspace' && biometryId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <BiometryWorkspace recordId={biometryId} />
        </div>
      )}
      {activeTab === 'workspace' && medFitnessId && (
        <div>
          <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={handleBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
          <MedicalFitnessWorkspace referralId={medFitnessId} onDone={handleBack} />
        </div>
      )}
      {activeTab === 'workspace' && selectedId && !postOpEpisodeId && !biometryId && !medFitnessId && (
        <ConsultationForm queueEntryId={selectedId} onBack={handleBack} />
      )}
      {activeTab === 'workspace' && !selectedId && !postOpEpisodeId && !biometryId && !medFitnessId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a patient from the Dashboard or History.</div>
      )}

      {activeTab === 'history' && <HistoryTab rows={history} loading={loadingHistory} onOpen={openConsultation} />}
    </div>
  );
}

JSEOF_9804792

echo "-- Writing app/(main)/ot-postop/workspace.js --"
mkdir -p "$(dirname "app/(main)/ot-postop/workspace.js")"
cat > "app/(main)/ot-postop/workspace.js" << 'JSEOF_63424856'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostOpEpisodeDetail, rescheduleFollowup, saveFollowupNotes, markFollowupStatus,
  addRecoveryComplication, closeEpisode, openFollowupReview, addFollowup, removeFollowup,
} from './actions';
import { uploadAttachment, getAttachments, deleteAttachment } from '@/lib/attachments';
import ConsultationForm from '@/app/(main)/consultation/[id]/consultation-form';

const MILESTONES_START = [
  { key: 'recovery', label: 'Recovery', icon: 'ti-bed' },
  { key: 'discharge', label: 'Discharge', icon: 'ti-door-exit' },
];
const MILESTONES_END = [
  { key: 'closure', label: 'Episode Closure', icon: 'ti-circle-check' },
];


export default function Workspace({ episodeId, onBack, onUpdate }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');

  const [editingFollowupId, setEditingFollowupId] = useState(null);
  const [editDate, setEditDate] = useState('');
  const [notesEditingId, setNotesEditingId] = useState(null);
  const [notesDraft, setNotesDraft] = useState('');
  const [attachmentsByFollowup, setAttachmentsByFollowup] = useState({});
  const [uploadingFollowupId, setUploadingFollowupId] = useState(null);
  const [saving, setSaving] = useState(false);

  const [complName, setComplName] = useState('');
  const [complSeverity, setComplSeverity] = useState('Mild');
  const [complManagement, setComplManagement] = useState('');
  const [complOutcome, setComplOutcome] = useState('');

  const [showClose, setShowClose] = useState(false);
  const [closureStatus, setClosureStatus] = useState('Successfully Completed');
  const [closureOutcome, setClosureOutcome] = useState('');
  const [closureRemarks, setClosureRemarks] = useState('');

  const [reviewingFollowup, setReviewingFollowup] = useState(null);
  const [reviewQueueEntryId, setReviewQueueEntryId] = useState(null);
  const [openingReview, setOpeningReview] = useState(null);

  const [showAddFollowup, setShowAddFollowup] = useState(false);
  const [newFollowupLabel, setNewFollowupLabel] = useState('');
  const [newFollowupDate, setNewFollowupDate] = useState('');
  const [addingFollowup, setAddingFollowup] = useState(false);
  const [removingFollowupId, setRemovingFollowupId] = useState(null);

  const refresh = useCallback(async () => {
    const result = await getPostOpEpisodeDetail(episodeId);
    setData(result);
    if (!result.error && result.followups?.length > 0) {
      const entries = await Promise.all(result.followups.map(async (f) => [f.id, await getAttachments('postop_followup', f.id)]));
      setAttachmentsByFollowup(Object.fromEntries(entries));
    }
  }, [episodeId]);

  useEffect(() => { refresh(); }, [episodeId, refresh]);

  if (!data) return <div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>;
  if (data.error) return <div className="msg-err">{data.error}</div>;

  if (reviewingFollowup && reviewQueueEntryId) {
    return (
      <ConsultationForm queueEntryId={reviewQueueEntryId} hideHistoryTracker onBack={handleBackFromReview} backLabel="Back to Post-op" />
    );
  }


  const { episode, sc, followups, complications } = data;
  const patient = sc?.patients;
  const isClosed = !!episode.closure_status;
  const todayStr = new Date().toISOString().slice(0, 10);

  const milestoneStatus = (key) => {
    if (key === 'recovery') return 'done';
    if (key === 'discharge') return episode.discharge_date ? 'done' : 'pending';
    if (key === 'closure') return episode.closure_status ? 'done' : 'pending';
    return 'pending';
  };

  function startEdit(f) {
    setError('');
    setEditingFollowupId(f.id);
    setEditDate(f.scheduled_date);
  }

  function startNotesEdit(f) {
    setError('');
    setNotesEditingId(f.id);
    setNotesDraft(f.notes || '');
  }

  async function handleSaveNotesOnly(f) {
    setError('');
    setSaving(true);
    const result = await saveFollowupNotes(f.id, notesDraft);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setNotesEditingId(null);
    refresh();
  }

  async function handleUploadFollowupFile(followupId, file) {
    if (!file) return;
    setUploadingFollowupId(followupId);
    const formData = new FormData();
    formData.append('file', file);
    formData.append('entityType', 'postop_followup');
    formData.append('entityId', followupId);
    const result = await uploadAttachment(formData);
    setUploadingFollowupId(null);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleRemoveFollowupFile(file) {
    await deleteAttachment(file.id, file.storage_path);
    refresh();
  }

  async function handleSaveFollowup(f) {
    setError('');
    if (!editDate || editDate === f.scheduled_date) { setEditingFollowupId(null); return; }
    setSaving(true);
    const result = await rescheduleFollowup(f.id, editDate, f.notes || '');
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setEditingFollowupId(null);
    refresh();
  }

  async function handleMarkStatus(f, status) {
    setError('');
    const result = await markFollowupStatus(f.id, status);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleAddComplication() {
    setError('');
    const result = await addRecoveryComplication(episodeId, { name: complName, severity: complSeverity, management: complManagement, outcome: complOutcome });
    if (result.error) { setError(result.error); return; }
    setComplName(''); setComplManagement(''); setComplOutcome('');
    refresh();
  }

  async function handleOpenReview(f) {
    setError('');
    setOpeningReview(f.id);
    const result = await openFollowupReview(f.id);
    setOpeningReview(null);
    if (result.error) { setError(result.error); return; }
    setReviewQueueEntryId(result.queueEntryId);
    setReviewingFollowup(f);
  }

  function handleBackFromReview() {
    setReviewingFollowup(null);
    setReviewQueueEntryId(null);
    refresh();
  }

  async function handleAddFollowup() {
    setError('');
    if (!newFollowupLabel.trim()) { setError('A label for the review is required.'); return; }
    if (!newFollowupDate) { setError('A date is required.'); return; }
    setAddingFollowup(true);
    const result = await addFollowup(episodeId, newFollowupLabel, newFollowupDate);
    setAddingFollowup(false);
    if (result.error) { setError(result.error); return; }
    setNewFollowupLabel(''); setNewFollowupDate(''); setShowAddFollowup(false);
    refresh();
  }

  async function handleRemoveFollowup(followupId) {
    setError('');
    setRemovingFollowupId(followupId);
    const result = await removeFollowup(followupId);
    setRemovingFollowupId(null);
    if (result.error) { setError(result.error); return; }
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

        {MILESTONES_START.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
          return (
            <div key={m.key} style={{ display: 'flex', alignItems: 'center', gap: 12, padding: '11px 12px', borderRadius: 12, marginBottom: 8, border: '1px solid var(--g200)', background: bg }}>
              <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color }}><i className={`ti ${icon}`}></i></div>
              <div style={{ flex: 1 }}><div style={{ fontWeight: 700, fontSize: 13 }}>{m.label}</div></div>
              <span className="badge" style={{ background: `${color}20`, color }}>{status.charAt(0).toUpperCase() + status.slice(1)}</span>
            </div>
          );
        })}

        {followups.length === 0 && (
          <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No follow-ups scheduled yet.</div>
        )}
        {followups.map((f) => {
          const color = f.status === 'Completed' ? 'var(--green)' : f.status === 'Due' ? 'var(--red)' : 'var(--blue)';
          const bg = f.status === 'Completed' ? 'var(--green-lt)' : f.status === 'Due' ? 'var(--red-lt)' : 'var(--blue-lt)';
          const icon = f.status === 'Completed' ? 'ti-check' : 'ti-calendar';
          return (
            <div key={f.id} style={{ padding: '10px 12px', border: '1px solid var(--g200)', borderRadius: 12, marginBottom: 8, background: bg }}>
              <div style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
                <div style={{ width: 30, height: 30, borderRadius: '50%', display: 'flex', alignItems: 'center', justifyContent: 'center', background: `${color}20`, color, flexShrink: 0 }}><i className={`ti ${icon}`}></i></div>
                <div style={{ flex: 1 }}>
                  <div style={{ fontWeight: 700, fontSize: 13 }}>{f.visit_label}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    {new Date(f.scheduled_date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                    {f.scheduled_date > todayStr && f.status !== 'Completed' && <span style={{ color: 'var(--blue)', marginLeft: 6 }}>-- upcoming</span>}
                  </div>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  {f.rescheduled_count > 0 && <span style={{ fontSize: 10, color: 'var(--amber)' }}>Rescheduled {f.rescheduled_count}x</span>}
                  <span className="badge" style={{ background: `${color}20`, color }}>{f.status}</span>
                </div>
              </div>

              {f.notes && notesEditingId !== f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: '8px 10px', background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 3 }}><i className="ti ti-notes"></i> Notes</div>
                  <div style={{ fontSize: 12.5, color: 'var(--g700)', whiteSpace: 'pre-wrap' }}>{f.notes}</div>
                </div>
              )}

              {notesEditingId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8, border: '1px solid var(--g200)' }}>
                  <textarea className="fi fi-sm" rows={3} value={notesDraft} onChange={(e) => setNotesDraft(e.target.value)} placeholder="Notes for this visit..." style={{ marginBottom: 6 }} />
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveNotesOnly(f)} disabled={saving}>Save Notes</button>
                    <button className="btn btn-sm" onClick={() => setNotesEditingId(null)}>Cancel</button>
                  </div>
                </div>
              )}

              {/* Optional attachment -- any file relevant to this visit */}
              <div style={{ marginTop: 8, marginLeft: 42 }}>
                {(attachmentsByFollowup[f.id] || []).map((file) => (
                  <div key={file.id} style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 11.5, padding: '4px 0' }}>
                    <i className="ti ti-paperclip" style={{ color: 'var(--g500)' }}></i>
                    {file.url ? <a href={file.url} target="_blank" rel="noopener noreferrer" style={{ color: 'var(--blue)' }}>{file.file_name}</a> : <span>{file.file_name}</span>}
                    {!isClosed && <button onClick={() => handleRemoveFollowupFile(file)} style={{ border: 'none', background: 'none', color: 'var(--red)', cursor: 'pointer', fontSize: 11 }}>Remove</button>}
                  </div>
                ))}
                {!isClosed && (
                  <label className="btn btn-sm" style={{ cursor: 'pointer', marginTop: 4, display: 'inline-flex' }}>
                    {uploadingFollowupId === f.id ? 'Uploading...' : <><i className="ti ti-upload"></i> Attach file (optional)</>}
                    <input type="file" accept=".pdf,.jpg,.jpeg,.png" style={{ display: 'none' }} onChange={(e) => handleUploadFollowupFile(f.id, e.target.files?.[0])} disabled={uploadingFollowupId === f.id} />
                  </label>
                )}
              </div>

              {!isClosed && editingFollowupId !== f.id && (
                <div style={{ display: 'flex', gap: 6, marginTop: 8, marginLeft: 42 }}>
                  <button className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => handleOpenReview(f)} disabled={openingReview === f.id}>
                    <i className="ti ti-clipboard-text"></i> {openingReview === f.id ? 'Opening...' : f.visit_id ? 'Open Review' : 'Start Review'}
                  </button>
                  <button className="btn btn-sm" onClick={() => startEdit(f)}><i className="ti ti-calendar-time"></i> Reschedule</button>
                  {notesEditingId !== f.id && (
                    <button className="btn btn-sm" onClick={() => startNotesEdit(f)}><i className="ti ti-edit"></i> {f.notes ? 'Edit Notes' : 'Add Notes'}</button>
                  )}
                  {f.status !== 'Completed' && (
                    <button
                      className="btn btn-sm"
                      style={{ background: 'var(--green)', color: '#fff', border: 'none', opacity: f.scheduled_date > todayStr ? 0.5 : 1, cursor: f.scheduled_date > todayStr ? 'not-allowed' : 'pointer' }}
                      onClick={() => handleMarkStatus(f, 'Completed')}
                      disabled={f.scheduled_date > todayStr}
                      title={f.scheduled_date > todayStr ? "This visit hasn't happened yet" : ''}
                    >
                      Mark Completed
                    </button>
                  )}
                  <button
                    className="btn btn-sm"
                    style={{ color: 'var(--red)' }}
                    onClick={() => handleRemoveFollowup(f.id)}
                    disabled={removingFollowupId === f.id}
                    title={f.visit_id ? 'A review that already has a visit recorded cannot be removed' : 'Remove this review'}
                  >
                    <i className="ti ti-trash"></i> {removingFollowupId === f.id ? 'Removing...' : 'Remove'}
                  </button>
                </div>
              )}

              {editingFollowupId === f.id && (
                <div style={{ marginTop: 8, marginLeft: 42, padding: 8, background: '#fff', borderRadius: 8 }}>
                  <div style={{ marginBottom: 6 }}>
                    <label className="flbl">New date</label>
                    <input type="date" className="fi fi-sm" value={editDate} onChange={(e) => setEditDate(e.target.value)} />
                  </div>
                  <div style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm btn-primary" onClick={() => handleSaveFollowup(f)} disabled={saving}>Save</button>
                    <button className="btn btn-sm" onClick={() => setEditingFollowupId(null)}>Cancel</button>
                  </div>
                </div>
              )}
            </div>
          );
        })}

        {!isClosed && (
          showAddFollowup ? (
            <div style={{ padding: '10px 12px', border: '1px dashed var(--g300)', borderRadius: 12, marginBottom: 8 }}>
              <div style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Review label (e.g. Post-op Week 2)" value={newFollowupLabel} onChange={(e) => setNewFollowupLabel(e.target.value)} />
                <input type="date" className="fi fi-sm" style={{ width: 150 }} value={newFollowupDate} onChange={(e) => setNewFollowupDate(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 6 }}>
                <button className="btn btn-sm btn-primary" onClick={handleAddFollowup} disabled={addingFollowup}>{addingFollowup ? 'Adding...' : 'Add Review'}</button>
                <button className="btn btn-sm" onClick={() => { setShowAddFollowup(false); setNewFollowupLabel(''); setNewFollowupDate(''); }}>Cancel</button>
              </div>
            </div>
          ) : (
            <button className="btn btn-sm" style={{ marginBottom: 8 }} onClick={() => setShowAddFollowup(true)}><i className="ti ti-plus"></i> Add Review</button>
          )
        )}

        {MILESTONES_END.map((m) => {
          const status = milestoneStatus(m.key);
          const color = status === 'done' ? 'var(--green)' : 'var(--amber)';
          const bg = status === 'done' ? 'var(--green-lt)' : 'var(--amber-lt)';
          const icon = status === 'done' ? 'ti-check' : 'ti-clock';
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

JSEOF_63424856

echo "-- Installing deps & building --"
npm install --no-audit --no-fund
npm run build

echo "== Done. DB migration (fitness_required column) already applied live. =="
