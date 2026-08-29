'use client';

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import AttachmentUploader from '@/app/components/AttachmentUploader';
import ConfirmActionModal from '@/app/components/ConfirmActionModal';
import {
  getSurgicalCaseDetail,
  setIolOrderNotes, editSurgicalCaseDetails, setTreatmentInstructions,
  getInvestigationOptionsForCase, addInHouseInvestigationForCase, removeInHouseInvestigationForCase,
  addExternalTest, removeExternalTest,
  declineSurgicalCase,
} from '../actions';
import { getSurgeries } from '@/app/(main)/master-data/actions';
import {
  selectPackage, changePackage, updatePackageDiscount, getPackagesForCase,
  setDecision, markReadyForScheduling, bookOTSlot, getSurgeons,
  getCaseProcedures, selectProcedurePackage, changeProcedurePackage, updateProcedurePackageDiscount,
} from '@/app/(main)/counselling/actions';
import { rescheduleOTSlot } from '@/app/(main)/ot-schedule/actions';
import { openPopup, openTab } from '@/lib/popup';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

// "15 Aug 2026" style, for the biometry re-order confirmation message --
// same format Consultation's own version of this prompt uses.
function formatDateReadable(isoTimestamp) {
  if (!isoTimestamp) return 'an earlier visit';
  return new Intl.DateTimeFormat('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' }).format(new Date(isoTimestamp));
}

// ── HEADER (editable) ──────────────────────────────────────────────
function CaseHeader({ sc, patient, onAction, caseProcedures = [] }) {
  const [editing, setEditing] = useState(false);
  const [surgeries, setSurgeries] = useState([]);
  const [procedureName, setProcedureName] = useState(sc.procedure_name);
  const [eye, setEye] = useState(sc.eye || 'OD');
  const [reason, setReason] = useState('');
  const [instructions, setInstructions] = useState(sc.treatment_instructions || '');
  const [savingInstructions, setSavingInstructions] = useState(false);
  const progressed = sc.status !== 'Pending Workup';

  useEffect(() => { if (editing) getSurgeries().then(setSurgeries); }, [editing]);

  function startEdit() {
    setProcedureName(sc.procedure_name); setEye(sc.eye || 'OD'); setReason(''); setEditing(true);
  }

  async function handleSaveInstructions() {
    setSavingInstructions(true);
    await onAction(setTreatmentInstructions)(sc.id, instructions);
    setSavingInstructions(false);
  }

  return (
    <div className="card" style={{ marginBottom: 16, background: 'var(--indigo)', color: '#fff' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
        <div>
          <div style={{ fontSize: 17, fontWeight: 700 }}>{formatPatientName(patient)}</div>
          <div style={{ fontSize: 12, opacity: 0.85 }}>{patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile}</div>
          {sc.surgery_code && <div style={{ fontSize: 11, opacity: 0.75, marginTop: 2 }}><i className="ti ti-hash"></i> {sc.surgery_code}</div>}
        </div>
        {!editing ? (
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontWeight: 700, fontSize: 14 }}>
              {sc.procedure_name}
              <button
                className="btn btn-sm" style={{ marginLeft: 8, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff', padding: '2px 8px' }}
                onClick={startEdit} title="Edit procedure/eye"
              >
                <i className="ti ti-pencil"></i>
              </button>
            </div>
            <div style={{ fontSize: 12, opacity: 0.85 }}>{EYE_LABEL[sc.eye] || sc.eye}</div>
            {caseProcedures.length > 0 && (
              <div style={{ fontSize: 11, opacity: 0.85, marginTop: 3 }}>
                <i className="ti ti-plus"></i> {caseProcedures.map((p) => `${p.procedure_name} (${p.eye})`).join(', ')}
              </div>
            )}
            <div style={{ fontSize: 10.5, opacity: 0.7, marginTop: 2 }}>
              Advised: {new Date(sc.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
            </div>
          </div>
        ) : null}
      </div>

      {editing && (
        <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi fi-sm" value={procedureName} onChange={(e) => setProcedureName(e.target.value)}>
              <option value={sc.procedure_name}>{sc.procedure_name}</option>
              {surgeries.filter((s) => s.name !== sc.procedure_name).map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
            </select>
            <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
              <option value="OD">Right (OD)</option>
              <option value="OS">Left (OS)</option>
              <option value="OU">Both (OU)</option>
            </select>
          </div>
          {progressed && (
            <input
              className="fi fi-sm" style={{ marginBottom: 8 }}
              placeholder={`Reason for changing (required -- case has already moved to "${sc.status}")`}
              value={reason} onChange={(e) => setReason(e.target.value)}
            />
          )}
          <div style={{ display: 'flex', gap: 8 }}>
            <button
              className="btn btn-sm btn-primary"
              onClick={async () => {
                const r = await onAction(editSurgicalCaseDetails)(sc.id, procedureName, eye, reason);
                if (r?.error) return;
                setEditing(false);
              }}
            >
              Save
            </button>
            <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={() => setEditing(false)}>Cancel</button>
          </div>
        </div>
      )}

      {/* Further instructions -- tied to the treatment itself (what's
          being done, which eye), not the pre-op investigations note. */}
      <div style={{ marginTop: 12, background: 'rgba(255,255,255,.1)', borderRadius: 8, padding: 12 }}>
        <div style={{ fontSize: 10, fontWeight: 700, opacity: 0.75, textTransform: 'uppercase', marginBottom: 6 }}>Further Instructions</div>
        <div style={{ display: 'flex', gap: 8 }}>
          <input
            className="fi fi-sm" style={{ flex: 1 }}
            placeholder="Anything else about this treatment worth noting..."
            value={instructions} onChange={(e) => setInstructions(e.target.value)}
          />
          <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.3)', color: '#fff' }} onClick={handleSaveInstructions} disabled={savingInstructions}>
            {savingInstructions ? 'Saving...' : 'Save'}
          </button>
        </div>
      </div>
    </div>
  );
}

function Section({ num, color, title, done, children, defaultOpen, active }) {
  const [open, setOpen] = useState(!!defaultOpen || !!active);
  return (
    <div
      className="card"
      style={{
        marginBottom: 12,
        border: active ? `2px solid ${color}` : '1px solid var(--g200)',
        background: active ? `color-mix(in srgb, ${color} 10%, white)` : '#fff',
        boxShadow: active ? `0 0 0 3px color-mix(in srgb, ${color} 20%, transparent)` : 'none',
      }}
    >
      <div style={{ display: 'flex', alignItems: 'center', gap: 10, cursor: 'pointer' }} onClick={() => setOpen((v) => !v)}>
        <div style={{ width: 24, height: 24, borderRadius: '50%', background: done ? 'var(--green)' : color, color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
          {done ? <i className="ti ti-check"></i> : num}
        </div>
        <div style={{ fontWeight: 700, fontSize: 13, flex: 1 }}>
          {title}
          {active && <span className="badge" style={{ marginLeft: 8, background: color, color: '#fff', fontSize: 10 }}><i className="ti ti-arrow-right"></i> Next Step</span>}
        </div>
        <i className={`ti ${open ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ marginTop: 12, paddingLeft: 34 }}>{children}</div>}
    </div>
  );
}

export default function Workspace({ caseId }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getSurgicalCaseDetail(caseId);
    if (result.error) { setError(result.error); return; }
    setData(result);
  }, [caseId]);

  useEffect(() => { refresh(); }, [refresh]);

  // Advance collection, Patient Check-In, and Intraoperative Management
  // are all opened as real new tabs via openTab() (see the buttons
  // below) so window.opener survives -- each of those tabs signals
  // back here and closes itself once its own step is actually done,
  // same close-on-complete pattern as IOL Approval and Medical
  // Fitness. This single listener covers all three message types.
  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      const t = e.data?.type;
      if (t === 'advance-collected' && e.data.patientId === data?.case?.patients?.id) refresh();
      else if (t === 'checkin-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
      else if (t === 'intraop-updated' && e.data.otScheduleId === data?.otSchedule?.id) refresh();
      else if (t === 'recovery-updated' && e.data.episodeId === data?.recoveryEpisode?.id) refresh();
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [data?.case?.patients?.id, data?.otSchedule?.id, data?.recoveryEpisode?.id, refresh]);

  function flash(fn) {
    return async (...args) => {
      setError(''); setOk('');
      const result = await fn(...args);
      if (result?.error) { setError(result.error); return result; }
      setOk('Saved.');
      await refresh();
      setTimeout(() => setOk(''), 2000);
      return result;
    };
  }

  // Deliberately not routed through flash() -- a successful decline
  // closes this case out (moves it to History), so the right move is
  // navigating back to the list, not refreshing this now-closed
  // workspace in place.
  async function handleDecline(reason) {
    setError('');
    const result = await declineSurgicalCase(sc.id, reason);
    if (result?.error) { setError(result.error); return result; }
    router.push('/surgical-journey');
    return result;
  }

  if (error && !data) return <div className="msg-err">{error}</div>;
  if (!data) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = data.case;
  const patient = sc.patients;

  // Same signal IOL Approval's own pending-queue already uses to decide
  // whether a case needs it (getPendingIolApprovals: `.neq('biometry_required',
  // false)`) -- biometry_required is set false at Counselling for cases
  // that don't need an IOL power calculation, i.e. non-cataract surgery.
  // Reused here so the IOL Approval section (and its slot in the
  // numbering) simply doesn't exist for those cases, instead of showing
  // as a locked step that can never be completed.
  const isCataract = sc.biometry_required !== false;

  // Net payable for the Payment step = package list price minus
  // whatever discount was recorded at Package Selection, summed across
  // every procedure in the surgery (primary + additional -- each keeps
  // its own package/price, see PackageDecisionSection). Advance
  // balance is the patient's live held-advance total (M11), not the
  // old advance_payment_id flag, which nothing in the app ever
  // actually set.
  const netPackageAmount = (sc.master_packages ? Math.max(0, Number(sc.master_packages.price) - Number(sc.package_discount || 0)) : 0)
    + (data.caseProcedures || []).reduce((sum, p) => sum + (p.master_packages ? Math.max(0, Number(p.master_packages.price) - Number(p.package_discount || 0)) : 0), 0);
  const advanceBalance = Number(data.advanceBalance || 0);

  // Create Invoice deactivates once every procedure's package has been
  // billed -- a surgery with no additional procedures just checks the
  // primary case's own package_billed flag.
  const allPackagesBilled = !!sc.package_billed && (data.caseProcedures || []).every((p) => !p.master_packages || p.package_billed);

  // Drives the "Next Step" highlight -- the first not-yet-done stage in
  // the natural order gets the full-color treatment, everything else
  // stays normal. Reports and Notes aren't part of this sequence (they
  // don't have a natural "done" state -- reports trickle in whenever,
  // notes are an ongoing log), so they're excluded.
  const stepDone = {
    decision: sc.decision === 'Accepted',
    investigations: data.biometryRecords.length > 0,
    package: !!sc.package_id,
    // Vacuously done for non-cataract cases -- there's no IOL Approval
    // section for them at all (see isCataract above), so this must
    // never be the thing "currentStep" gets permanently stuck waiting
    // on. Same pattern as `fitness` below (sc.fitness_required === false).
    iolApproval: !isCataract || data.iolApproval?.status === 'Approved',
    iol: !!data.otSchedule,
    fitness: sc.fitness_cleared || sc.fitness_required === false || data.fitnessReferral?.status === 'Cleared',
    payment: netPackageAmount > 0 && advanceBalance >= netPackageAmount - 0.01,
    checkin: !!data.checkinCompletedAt,
    intraop: data.otSchedule?.status === 'Completed',
    recovery: !!data.recoveryEpisode?.discharge_date,
  };
  const currentStep = Object.keys(stepDone).find((k) => !stepDone[k]) || null;

  // Section numbers computed in order, skipping IOL Approval's slot
  // entirely for non-cataract cases -- e.g. cataract runs 1-10 (with
  // IOL Approval as 4, Surgery Date Booking as 5), non-cataract runs
  // 1-9 straight through (Surgery Date Booking as 4), instead of a
  // Surgery Date Booking numbered 5 with no section 4 above it.
  let stepNum = 3; // 1 Patient Decision, 2 Investigations, 3 Package
  const iolApprovalNum = isCataract ? ++stepNum : null;
  const bookingNum = ++stepNum;
  const fitnessNum = ++stepNum;
  const paymentNum = ++stepNum;
  const checkinNum = ++stepNum;
  const intraopNum = ++stepNum;
  const recoveryNum = ++stepNum;

  return (
    <div style={{ maxWidth: 760, margin: '0 auto' }}>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/surgical-journey')}>
        <i className="ti ti-arrow-left"></i> All Cases
      </button>

      <CaseHeader sc={sc} patient={patient} onAction={flash} caseProcedures={data.caseProcedures} />

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      {/* 1. PATIENT DECISION -- the very first step. Once the patient
          gives assent (Accepted), Investigations through Payment all
          unlock together -- no interdependency between them. Patient
          Check-In and beyond stay locked until Payment is complete. */}
      <DecisionSection sc={sc} onAction={flash} onDecline={handleDecline} active={currentStep === 'decision'} />

      {/* 2. INVESTIGATIONS */}
      <InvestigationsSection sc={sc} biometryRecords={data.biometryRecords} inHouseInvestigations={data.inHouseInvestigations} externalTests={data.externalTests} onAction={flash} refresh={refresh} active={currentStep === 'investigations'} />

      {/* 3. PACKAGE & IOL DECISION */}
      <PackageDecisionSection sc={sc} caseProcedures={data.caseProcedures} onAction={flash} active={currentStep === 'package'} />

      {/* IOL APPROVAL -- cataract cases only (biometry_required =
          false means this case never needed an IOL power calc, so
          there's nothing for the surgeon to approve here). Skipped
          entirely for other surgeries, not shown locked/disabled --
          the numbering below closes the gap automatically. */}
      {isCataract && (
        <IolApprovalSection sc={sc} iolApproval={data.iolApproval} active={currentStep === 'iolApproval'} refresh={refresh} num={iolApprovalNum} />
      )}

      {/* SURGERY DATE BOOKING */}
      <IolAndBookingSection sc={sc} otSchedule={data.otSchedule} iolApproval={data.iolApproval} onAction={flash} active={currentStep === 'iol'} num={bookingNum} />

      {/* MEDICAL FITNESS -- comes after the surgery date is booked
          (pre-anaesthesia clearance closer to the actual surgery date
          is more clinically useful than clearing weeks in advance). */}
      <FitnessSection sc={sc} fitnessReferral={data.fitnessReferral} onAction={flash} active={currentStep === 'fitness'} num={fitnessNum} refresh={refresh} />

      {/* PAYMENT */}
      <Section num={paymentNum} color="var(--teal)" title="Payment" done={stepDone.payment} active={currentStep === 'payment'}>
        {!sc.master_packages ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Select a package first to determine the amount payable.</div>
        ) : (
          <div>
            <div style={{ background: 'var(--g50)', borderRadius: 8, padding: 10, marginBottom: 10, fontSize: 12.5 }}>
              {/* Every procedure in the surgery gets its own line --
                  primary plus each additional procedure (see
                  surgical_case_procedures) -- since each keeps its own
                  package/price, summed into Net payable below. */}
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span>{sc.procedure_name} ({EYE_LABEL[sc.eye] || sc.eye})</span>
                <span>Rs.{Number(sc.master_packages.price).toLocaleString('en-IN')}{Number(sc.package_discount || 0) > 0 ? ` (\u2212Rs.${Number(sc.package_discount).toLocaleString('en-IN')})` : ''}</span>
              </div>
              {(data.caseProcedures || []).filter((p) => p.master_packages).map((p) => (
                <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', marginTop: 4 }}>
                  <span>{p.procedure_name} ({EYE_LABEL[p.eye] || p.eye})</span>
                  <span>Rs.{Number(p.master_packages.price).toLocaleString('en-IN')}{Number(p.package_discount || 0) > 0 ? ` (\u2212Rs.${Number(p.package_discount).toLocaleString('en-IN')})` : ''}</span>
                </div>
              ))}
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, borderTop: '1px solid var(--g200)', marginTop: 6, paddingTop: 6 }}>
                <span>Net payable</span><span>Rs.{netPackageAmount.toLocaleString('en-IN')}</span>
              </div>
              <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: 6 }}>
                <span>Advance received</span><span style={{ fontWeight: 600, color: 'var(--purple)' }}>Rs.{advanceBalance.toLocaleString('en-IN')}</span>
              </div>
            </div>
            {stepDone.payment ? (
              <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Paid in full.</div>
            ) : (
              <div>
                <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>
                  Balance due: <strong style={{ color: 'var(--amber)' }}>Rs.{Math.max(0, netPackageAmount - advanceBalance).toLocaleString('en-IN')}</strong>
                </div>
                <button
                  className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
                  onClick={() => openTab(`/payments/advance?patientId=${patient.id}&amount=${Math.max(0, netPackageAmount - advanceBalance)}&returnTo=surgical-journey`, `advance-${patient.id}`)}
                >
                  <i className="ti ti-cash"></i> Collect Advance
                </button>
              </div>
            )}
            {/* Bills every procedure's package together on ONE invoice
                (see billing/new/new-invoice-tab.js's pkgCaseId effect) --
                deactivates once package_billed is true for the whole
                surgery, since it can't be billed twice. */}
            <div style={{ marginTop: 10 }}>
              {allPackagesBilled ? (
                <button className="btn btn-sm" disabled>
                  <i className="ti ti-circle-check"></i> Invoice Created
                </button>
              ) : (
                <button className="btn btn-sm" onClick={() => openTab(`/billing/new?pkgCaseId=${sc.id}`, `invoice-${sc.id}`)}>
                  <i className="ti ti-receipt"></i> Create Invoice
                </button>
              )}
            </div>
          </div>
        )}
      </Section>

      {/* PATIENT CHECK-IN */}
      <PatientCheckinSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} paymentDone={stepDone.payment} active={currentStep === 'checkin'} num={checkinNum} />

      {/* INTRAOPERATIVE MANAGEMENT */}
      <IntraopManagementSection otSchedule={data.otSchedule} checkinCompletedAt={data.checkinCompletedAt} active={currentStep === 'intraop'} num={intraopNum} />

      {/* RECOVERY & DISCHARGE -- separate module: post-op recovery
          monitoring through to discharge. */}
      <RecoveryDischargeSection otSchedule={data.otSchedule} recoveryEpisode={data.recoveryEpisode} active={currentStep === 'recovery'} num={recoveryNum} />
    </div>
  );
}

// ── FITNESS ─────────────────────────────────────────────────────────
// Kept as a real doctor referral/review (same as Counselling), not a
// self-certify checkbox -- clearing a patient for anaesthesia is a
// genuine clinical judgment, not paperwork. Deep-links to the Medical
// Fitness module for the actual review, opened as a real new tab
// (window.opener intact) so it can signal back and close itself once
// the review is submitted -- same pattern as IOL Approval.
function FitnessSection({ sc, fitnessReferral, onAction, active, num, refresh }) {
  const cleared = sc.fitness_cleared || sc.fitness_required === false || fitnessReferral?.status === 'Cleared';

  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== 'fitness-updated' || e.data.referralId !== fitnessReferral?.id) return;
      refresh();
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [fitnessReferral?.id, refresh]);

  return (
    <Section num={num} color="var(--red)" title="Medical Fitness" done={cleared} active={active}>
      {sc.fitness_required === false && !fitnessReferral ? (
        <span className="badge b-purple"><i className="ti ti-player-skip-forward"></i> Not required for this case</span>
      ) : !fitnessReferral ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}>
          <i className="ti ti-info-circle"></i> Will appear in the Medical Fitness module automatically once the OT date is booked.
        </div>
      ) : fitnessReferral.status === 'Pending Review' ? (
        <div style={{ fontSize: 11.5 }}>
          <span className="badge b-amber" style={{ marginBottom: 8 }}><i className="ti ti-clock"></i> Awaiting doctor review (referred {new Date(fitnessReferral.referred_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })})</span>
          <div>
            <button type="button" className="btn btn-sm btn-primary" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
              <i className="ti ti-heart-rate-monitor"></i> Open Medical Fitness
            </button>
          </div>
        </div>
      ) : fitnessReferral.status === 'Cleared' ? (
        <div>
          <span className="badge b-green"><i className="ti ti-check"></i> Cleared by doctor</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
          <div style={{ marginTop: 8 }}>
            <button type="button" className="btn btn-sm" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
              <i className="ti ti-pencil"></i> Edit
            </button>
          </div>
        </div>
      ) : (
        <div>
          <span className="badge b-red"><i className="ti ti-x"></i> Not Fit</span>
          {fitnessReferral.fitness_notes && <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 6 }}>{fitnessReferral.fitness_notes}</div>}
          <div style={{ marginTop: 8 }}>
            <button type="button" className="btn btn-sm" onClick={() => openTab(`/medical-fitness?referralId=${fitnessReferral.id}`, `medical-fitness-${fitnessReferral.id}`)}>
              <i className="ti ti-pencil"></i> Review Again
            </button>
          </div>
        </div>
      )}
    </Section>
  );
}

// ── IOL APPROVAL -- separate module, deep-link only (same treatment as
// Medical Fitness and Day of Surgery). The surgeon's actual approve
// action happens in /iol-approval, not embedded here. Opens as a real
// new tab (not a popup window) so the person can use the full
// Workspace comfortably; the tab signals back via postMessage and
// closes itself once the approval is saved, returning focus straight
// to Surgical Journey with the step refreshed. ──
function IolApprovalSection({ sc, iolApproval, active, refresh, num }) {
  const approved = iolApproval?.status === 'Approved';

  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== 'iol-approved' || e.data.caseId !== sc.id) return;
      refresh();
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [sc.id, refresh]);

  return (
    <Section num={num} color="var(--indigo)" title="IOL Approval" done={approved} active={active}>
      {approved ? (
        <div style={{ fontSize: 12.5 }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 10, flexWrap: 'wrap' }}>
            <div>
              <span className="badge b-green" style={{ marginBottom: 6 }}><i className="ti ti-check"></i> Approved</span>
              <div style={{ marginTop: 6 }}>
                {iolApproval.master_iol_catalog?.brand} {iolApproval.master_iol_catalog?.model} -- {iolApproval.power}D ({iolApproval.eye})
              </div>
            </div>
            <button type="button" className="btn btn-sm" onClick={() => openTab(`/iol-approval?caseId=${sc.id}&mode=view`, `iol-approval-${sc.id}`)}>
              <i className="ti ti-pencil"></i> Edit
            </button>
          </div>
        </div>
      ) : (
        <div>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}>
            The surgeon needs to review Biometry's device recommendations and confirm the specific brand/power for this case.
          </div>
          <button type="button" className="btn btn-sm btn-primary" onClick={() => openTab(`/iol-approval?caseId=${sc.id}`, `iol-approval-${sc.id}`)}>
            <i className="ti ti-lens"></i> Open IOL Approval
          </button>
        </div>
      )}
    </Section>
  );
}

// ── INVESTIGATIONS -- flexible and optional, not a fixed required
// panel. Biometry stays its own thing (patient-level, dedicated flow).
// Everything else splits into In-House (routes through our own
// Investigation module, status + View Report) and External (done
// elsewhere -- add multiple named tests, upload/view each one's report
// separately, and print the whole list as a referral slip). ──
function InvestigationsSection({ sc, biometryRecords, inHouseInvestigations, externalTests, onAction, refresh, active }) {
  const [invOptions, setInvOptions] = useState([]);
  const [selectedInv, setSelectedInv] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [extTestName, setExtTestName] = useState('');
  const [expandedTestId, setExpandedTestId] = useState(null);
  const [invError, setInvError] = useState('');
  // Set when adding "Biometry" comes back asking to confirm a fresh
  // record despite an existing "Measured" one on file -- see the same
  // pattern in Consultation's consultation-form.js.
  const [biometryReorderPrompt, setBiometryReorderPrompt] = useState(null);
  const biometryOrdered = biometryRecords.length > 0;

  useEffect(() => { getInvestigationOptionsForCase().then(setInvOptions); }, []);

  // Shared by the suggestion chips and the manual dropdown Add button --
  // both can hit "Biometry", so both need to handle the confirmation
  // response the same way instead of the generic onAction(flash)
  // wrapper (which would show a false "Saved." for a needsConfirmation
  // response, since that's not an error).
  async function handleAddInvestigation(name, eye, confirmFreshBiometry = false) {
    setInvError('');
    const result = await addInHouseInvestigationForCase(sc.id, name, eye, confirmFreshBiometry);
    if (result?.needsConfirmation === 'biometry') {
      setBiometryReorderPrompt({ name, eye, existingDate: result.existingBiometryDate });
      return;
    }
    setBiometryReorderPrompt(null);
    if (result?.error) { setInvError(result.error); return; }
    setSelectedInv('');
    await refresh();
  }

  return (
    <Section num={2} color="var(--purple)" title="Investigations" done={biometryOrdered} active={active}>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 14 }}>
        Optional -- add whatever this case actually needs, not a fixed checklist.
      </div>

      {invError && <div className="msg-err" style={{ marginBottom: 10 }}>{invError}</div>}

      {biometryReorderPrompt && (
        <ConfirmActionModal
          icon="ti-ruler-2" iconColor="var(--purple)" iconBg="rgba(124,58,237,.12)"
          title="Biometry already on file"
          description={`Biometry for this patient was already measured on ${formatDateReadable(biometryReorderPrompt.existingDate)} and is available in the Biometry module -- it'll show up on this case automatically. Order a fresh measurement anyway?`}
          confirmLabel="Yes, order a fresh one"
          cancelLabel="No, use existing"
          onCancel={() => setBiometryReorderPrompt(null)}
          onConfirm={() => handleAddInvestigation(biometryReorderPrompt.name, biometryReorderPrompt.eye, true)}
        />
      )}

      {(() => {
        // The doctor's indicative picks from Consultation's "Pre Op
        // Requirement" field -- one-click suggestions, not
        // auto-ordered. Filters out anything already ordered so a
        // suggestion doesn't linger after it's been acted on (or was
        // never relevant here in the first place).
        const already = new Set(inHouseInvestigations.map((inv) => `${inv.name.trim().toLowerCase()}|${inv.eye}`));
        const suggestions = (sc.indicative_investigations || []).filter(
          (inv) => inv?.name?.trim() && !already.has(`${inv.name.trim().toLowerCase()}|${inv.eye || 'OU'}`)
        );
        if (suggestions.length === 0) return null;
        return (
          <div style={{ marginBottom: 14, padding: 10, background: 'var(--purple-lt)', borderRadius: 8 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--purple)', marginBottom: 6 }}>
              <i className="ti ti-bulb"></i> Suggested from Consultation -- click to order
            </div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 6 }}>
              {suggestions.map((inv, idx) => (
                <button
                  key={idx} type="button" className="btn btn-sm"
                  onClick={() => handleAddInvestigation(inv.name, inv.eye || 'OU')}
                >
                  <i className="ti ti-plus"></i> {inv.name} ({inv.eye || 'OU'})
                </button>
              ))}
            </div>
          </div>
        );
      })()}

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>In-House Investigations</div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 6 }}>Anything we do ourselves -- including Biometry, whatever the doctor feels this case needs.</div>
        {inHouseInvestigations.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {inHouseInvestigations.map((inv) => {
              const isBiometry = inv.name.toLowerCase() === 'biometry';
              const bioRecord = isBiometry ? biometryRecords[0] : null;
              return (
                <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', background: 'var(--g50)', borderRadius: 6, marginBottom: 4, fontSize: 12 }}>
                  <span>{inv.name} -- {inv.eye}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${inv.status === 'Available' ? 'b-green' : inv.status === 'Cancelled' ? 'b-red' : 'b-amber'}`} style={{ fontSize: 10 }}>{inv.status}</span>
                    {isBiometry ? (
                      <a href={bioRecord?.id ? `/biometry/${bioRecord.id}` : '/biometry'} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
                        {bioRecord?.status === 'Measured' ? 'View Report' : 'Open Biometry'}
                      </a>
                    ) : inv.status === 'Available' ? (
                      <a href={`/investigation/${inv.id}?mode=view`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>View Report</a>
                    ) : inv.status === 'Ordered' ? (
                      <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={() => onAction(removeInHouseInvestigationForCase)(inv.id)}>Remove</button>
                    ) : null}
                  </div>
                </div>
              );
            })}
          </div>
        )}
        <div style={{ display: 'flex', gap: 8 }}>
          <select className="fi fi-sm" style={{ flex: 1 }} value={selectedInv} onChange={(e) => setSelectedInv(e.target.value)}>
            <option value="">Select investigation...</option>
            {invOptions.map((o) => <option key={o.code} value={o.name}>{o.name}</option>)}
          </select>
          <select className="fi fi-sm" style={{ width: 90 }} value={invEye} onChange={(e) => setInvEye(e.target.value)}>
            <option value="OD">RE</option><option value="OS">LE</option><option value="OU">Both</option>
          </select>
          <button
            className="btn btn-sm btn-primary" disabled={!selectedInv}
            onClick={() => handleAddInvestigation(selectedInv, invEye)}
          >
            <i className="ti ti-plus"></i> Add
          </button>
        </div>
      </div>

      <div>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 6 }}>
          <div style={{ fontWeight: 600, fontSize: 12 }}>External Investigations</div>
          {externalTests.length > 0 && (
            <a href={`/external-investigation-referral-print/${sc.id}`} target="_blank" rel="noopener noreferrer" className="btn" style={{ fontSize: 11, padding: '2px 8px', textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Referral
            </a>
          )}
        </div>
        <div style={{ fontSize: 10.5, color: 'var(--g400)', marginBottom: 8 }}>Blood work, HIV test, etc -- not done in-house. Add each test, upload its report whenever it comes back.</div>

        {externalTests.length > 0 && (
          <div style={{ marginBottom: 8 }}>
            {externalTests.map((t) => (
              <div key={t.id} style={{ background: 'var(--g50)', borderRadius: 6, marginBottom: 4 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '5px 8px', fontSize: 12, cursor: 'pointer' }} onClick={() => setExpandedTestId(expandedTestId === t.id ? null : t.id)}>
                  <span>{t.test_name}</span>
                  <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className="badge b-gray" style={{ fontSize: 10 }}>{t.attachmentCount > 0 ? `${t.attachmentCount} file${t.attachmentCount > 1 ? 's' : ''}` : 'No report yet'}</span>
                    <button className="btn" style={{ fontSize: 11, padding: '2px 8px' }} onClick={(e) => { e.stopPropagation(); onAction(removeExternalTest)(t.id); }}>Remove</button>
                    <i className={`ti ${expandedTestId === t.id ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ color: 'var(--g400)' }}></i>
                  </div>
                </div>
                {expandedTestId === t.id && (
                  <div style={{ padding: '0 8px 10px' }}>
                    <AttachmentUploader entityType="external_investigation" entityId={t.id} title="" />
                  </div>
                )}
              </div>
            ))}
          </div>
        )}

        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "CBC", "HIV Test", "RBS"' value={extTestName} onChange={(e) => setExtTestName(e.target.value)} />
          <button
            className="btn btn-sm btn-primary" disabled={!extTestName.trim()}
            onClick={async () => { const r = await onAction(addExternalTest)(sc.id, extTestName); if (!r?.error) setExtTestName(''); }}
          >
            <i className="ti ti-plus"></i> Add Test
          </button>
        </div>
      </div>
    </Section>
  );
}

// ── PATIENT DECISION -- the first step. Set by the doctor at
// advise-surgery time in OPD (Consultation), reflected here, and
// updatable by Front Desk once the patient calls back. Uses the same
// locked+reason semantics setDecision already enforces everywhere else
// (locks automatically once Accepted; changing away from a locked
function DeclineReasonModal({ onCancel, onConfirm }) {
  const [reason, setReason] = useState('');
  const [saving, setSaving] = useState(false);
  const [localError, setLocalError] = useState('');

  async function handleConfirm() {
    if (!reason.trim()) { setLocalError('A reason is required.'); return; }
    setSaving(true);
    const result = await onConfirm(reason.trim());
    setSaving(false);
    if (result?.error) setLocalError(result.error);
    // On success the caller navigates away, so there's nothing left to
    // reset here -- this component unmounts along with the workspace.
  }

  return (
    <div onClick={saving ? undefined : onCancel} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 20, maxWidth: 420, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
          <span style={{ width: 34, height: 34, borderRadius: '50%', background: 'rgba(220,38,38,.12)', color: 'var(--red)', display: 'flex', alignItems: 'center', justifyContent: 'center', flexShrink: 0 }}>
            <i className="ti ti-x" style={{ fontSize: 18 }}></i>
          </span>
          <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--g800)' }}>Mark as Not Willing?</div>
        </div>
        <div style={{ fontSize: 13, color: 'var(--g600)', marginBottom: 12, lineHeight: 1.5 }}>
          This closes the case out of Active Cases and moves it to History. A reason is required for the record.
        </div>
        <textarea
          className="fi" rows={3} placeholder="Why is the patient not willing? e.g. 'Financial constraint', 'Decided against surgery', 'Opted for treatment elsewhere'..."
          value={reason} onChange={(e) => { setReason(e.target.value); setLocalError(''); }}
          style={{ marginBottom: 8 }}
          autoFocus
        />
        {localError && <div className="msg-err" style={{ marginBottom: 8 }}>{localError}</div>}
        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button type="button" className="btn btn-sm" onClick={onCancel} disabled={saving}>Cancel</button>
          <button type="button" className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleConfirm} disabled={saving}>
            {saving ? 'Saving...' : 'Yes, Mark Not Willing'}
          </button>
        </div>
      </div>
    </div>
  );
}

// decision needs a reason). ──
function DecisionSection({ sc, onAction, onDecline, active }) {
  const [reason, setReason] = useState('');
  const [showDeclineModal, setShowDeclineModal] = useState(false);
  const OPTIONS = [
    { v: 'Accepted', label: 'Willing', color: 'var(--green)' },
    { v: 'Wants Time to Decide', label: 'Needs Time to Decide', color: 'var(--amber)' },
    { v: 'Declined', label: 'Not Willing', color: 'var(--red)' },
  ];
  return (
    <Section num={1} color="var(--amber)" title="Patient Decision" done={sc.decision === 'Accepted'} active={active}>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 8 }}>
        {OPTIONS.map((o) => (
          <button
            key={o.v}
            className="btn btn-sm"
            style={{ background: sc.decision === o.v ? o.color : '', color: sc.decision === o.v ? '#fff' : '', border: sc.decision === o.v ? 'none' : undefined }}
            onClick={() => (o.v === 'Declined' ? setShowDeclineModal(true) : onAction(setDecision)(sc.id, o.v, reason))}
          >
            {o.label}
          </button>
        ))}
      </div>
      {showDeclineModal && (
        <DeclineReasonModal
          onCancel={() => setShowDeclineModal(false)}
          onConfirm={(declineReason) => onDecline(declineReason)}
        />
      )}
      {sc.decision_locked && (
        <input className="fi fi-sm" placeholder="Reason to change decision..." value={reason} onChange={(e) => setReason(e.target.value)} />
      )}
      {sc.decision === 'Accepted' && sc.decision_accepted_at && (
        <div style={{ fontSize: 11.5, color: 'var(--green)', marginTop: 8 }}>
          <i className="ti ti-lock"></i> Accepted on {new Date(sc.decision_accepted_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })} -- locked.
        </div>
      )}
      {sc.decision === 'Wants Time to Decide' && (
        <div style={{ fontSize: 11.5, color: 'var(--amber)', marginTop: 8 }}>
          <i className="ti ti-clock-pause"></i> On Front Desk's follow-up list until this is updated.
        </div>
      )}
      {sc.decision === 'Declined' && (
        <div style={{ fontSize: 11.5, color: 'var(--red)', marginTop: 8 }}>
          <i className="ti ti-x"></i> Patient declined surgery.
        </div>
      )}
      {!sc.decision && (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginTop: 8 }}>No decision recorded yet.</div>
      )}
    </Section>
  );
}

// ── PACKAGE & IOL DECISION ──────────────────────────────────────────
// ── One package picker, reused for the primary procedure AND every
// additional procedure in this surgery -- each keeps its own
// package/price (per-procedure billing), same select/change/discount
// flow either way, just pointed at a different target's actions. ──
function PackagePickerBlock({ title, target, packages, onSelect, onChangePackage, onUpdateDiscount }) {
  const [selectedPackageId, setSelectedPackageId] = useState('');
  const [discountInput, setDiscountInput] = useState('');
  const [selecting, setSelecting] = useState(false);
  const [selectError, setSelectError] = useState('');
  const [changeReason, setChangeReason] = useState('');
  const [changeDiscountInput, setChangeDiscountInput] = useState('');
  const [changing, setChanging] = useState(false);
  const [editingDiscount, setEditingDiscount] = useState(false);
  const [discountEditValue, setDiscountEditValue] = useState('');
  const [discountEditReason, setDiscountEditReason] = useState('');
  const [discountError, setDiscountError] = useState('');
  const [savingDiscount, setSavingDiscount] = useState(false);

  const selectedPreview = packages.find((p) => p.id === selectedPackageId);
  const discountNum = Number(discountInput) || 0;
  const netPreview = selectedPreview ? Math.max(0, Number(selectedPreview.price) - discountNum) : null;
  const currentDiscount = Number(target.package_discount || 0);
  const currentNet = target.master_packages ? Math.max(0, Number(target.master_packages.price) - currentDiscount) : 0;

  async function handleSelect() {
    setSelectError('');
    if (!selectedPackageId) { setSelectError('Choose a package first.'); return; }
    if (discountNum < 0) { setSelectError('Discount cannot be negative.'); return; }
    setSelecting(true);
    const result = await onSelect(selectedPackageId, discountNum);
    setSelecting(false);
    if (result?.error) { setSelectError(result.error); return; }
    setDiscountInput('');
  }

  async function handleSaveDiscount() {
    setDiscountError('');
    if (!discountEditReason.trim()) { setDiscountError('Reason is required.'); return; }
    setSavingDiscount(true);
    const result = await onUpdateDiscount(Number(discountEditValue) || 0, discountEditReason);
    setSavingDiscount(false);
    if (result?.error) { setDiscountError(result.error); return; }
    setEditingDiscount(false); setDiscountEditReason('');
  }

  return (
    <div>
      <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>{title}</div>
      {target.master_packages ? (
        <div>
          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, marginBottom: (changing || editingDiscount) ? 8 : 0 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
              <span style={{ fontWeight: 600, fontSize: 12.5 }}>{target.master_packages.name}</span>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontWeight: 700, color: 'var(--green)' }}>Rs.{Number(target.master_packages.price).toLocaleString('en-IN')}</span>
                {!changing && !editingDiscount && <button className="btn btn-sm" onClick={() => setChanging(true)}>Change</button>}
              </div>
            </div>
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, color: 'var(--g600)' }}>
              <span>Discount: {currentDiscount > 0 ? `Rs.${currentDiscount.toLocaleString('en-IN')}` : 'None'}</span>
              <span style={{ fontWeight: 700 }}>Net: Rs.{currentNet.toLocaleString('en-IN')}</span>
            </div>
            {!changing && !editingDiscount && (
              <button className="btn btn-sm" style={{ marginTop: 6 }} onClick={() => { setEditingDiscount(true); setDiscountEditValue(currentDiscount || ''); }}>
                <i className="ti ti-percentage"></i> Edit discount
              </button>
            )}
          </div>

          {editingDiscount && (
            <div>
              {discountError && <div className="msg-err" style={{ marginBottom: 8 }}>{discountError}</div>}
              <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount amount (Rs.)" value={discountEditValue} onChange={(e) => setDiscountEditValue(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for discount change..." value={discountEditReason} onChange={(e) => setDiscountEditReason(e.target.value)} />
                <button className="btn btn-sm btn-primary" disabled={savingDiscount} onClick={handleSaveDiscount}>
                  {savingDiscount ? 'Saving...' : 'Save'}
                </button>
                <button className="btn btn-sm" onClick={() => { setEditingDiscount(false); setDiscountError(''); }}>Cancel</button>
              </div>
            </div>
          )}

          {changing && (
            <div>
              <div style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                  <option value="">Select a new package...</option>
                  {packages.map((p) => (
                    <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                  ))}
                </select>
                <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={changeDiscountInput} onChange={(e) => setChangeDiscountInput(e.target.value)} />
              </div>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for changing..." value={changeReason} onChange={(e) => setChangeReason(e.target.value)} />
                <button
                  className="btn btn-sm btn-primary"
                  disabled={!selectedPackageId || !changeReason.trim()}
                  onClick={async () => {
                    const r = await onChangePackage(changeReason);
                    if (r?.error) return;
                    await onSelect(selectedPackageId, Number(changeDiscountInput) || 0);
                    setChanging(false); setChangeReason(''); setSelectedPackageId(''); setChangeDiscountInput('');
                  }}
                >
                  Confirm Change
                </button>
                <button className="btn btn-sm" onClick={() => { setChanging(false); setChangeReason(''); setChangeDiscountInput(''); }}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      ) : (
        <div>
          {selectError && <div className="msg-err" style={{ marginBottom: 8 }}>{selectError}</div>}
          {packages.length === 0 ? (
            <div style={{ textAlign: 'center', padding: 14, fontSize: 12, color: 'var(--g400)', background: 'var(--g50)', borderRadius: 8 }}>
              No active packages found. Add one under Financial Masters &gt; Surgery.
            </div>
          ) : (
            <>
              <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
                <select className="fi fi-sm" style={{ flex: 2 }} value={selectedPackageId} onChange={(e) => setSelectedPackageId(e.target.value)}>
                  <option value="">Select a package...</option>
                  {packages.map((p) => (
                    <option key={p.id} value={p.id}>{p.name}{p.origin ? ` (${p.origin})` : ''} -- Rs.{Number(p.price).toLocaleString('en-IN')}</option>
                  ))}
                </select>
                <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="Discount (Rs.)" value={discountInput} onChange={(e) => setDiscountInput(e.target.value)} />
                <button className="btn btn-sm btn-primary" disabled={!selectedPackageId || selecting} onClick={handleSelect}>
                  <i className="ti ti-check"></i> {selecting ? 'Selecting...' : 'Select'}
                </button>
              </div>
              {selectedPreview && (
                <div style={{ border: '1.5px solid var(--g200)', borderRadius: 8, padding: 10 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
                    <div style={{ fontWeight: 700, fontSize: 12.5, display: 'flex', alignItems: 'center', gap: 8 }}>
                      {selectedPreview.name}
                      {selectedPreview.origin && <span className={`badge ${selectedPreview.origin === 'Imported' ? 'b-blue' : 'b-green'}`}>{selectedPreview.origin}</span>}
                    </div>
                    <div style={{ fontWeight: 700, color: 'var(--green)', fontSize: 13 }}>Rs.{Number(selectedPreview.price).toLocaleString('en-IN')}</div>
                  </div>
                  {selectedPreview.includes && <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4 }}>{selectedPreview.includes}</div>}
                  {discountNum > 0 && (
                    <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginTop: 6, paddingTop: 6, borderTop: '1px solid var(--g200)' }}>
                      <span style={{ color: 'var(--red)' }}>Discount: Rs.{discountNum.toLocaleString('en-IN')}</span>
                      <span style={{ fontWeight: 700 }}>Net: Rs.{netPreview.toLocaleString('en-IN')}</span>
                    </div>
                  )}
                </div>
              )}
            </>
          )}
        </div>
      )}
    </div>
  );
}

function PackageDecisionSection({ sc, caseProcedures, onAction, active }) {
  const [packages, setPackages] = useState([]);
  const [loadingPackages, setLoadingPackages] = useState(true);

  useEffect(() => {
    getPackagesForCase(sc.iol_category).then((p) => { setPackages(p); setLoadingPackages(false); });
  }, [sc.iol_category]);

  const allSelected = !!sc.package_id && caseProcedures.every((p) => !!p.package_id);
  // Only meaningful once every procedure in the surgery has a package
  // -- a partial total would understate what's actually owed.
  const totalNet = allSelected
    ? Math.max(0, Number(sc.master_packages.price) - Number(sc.package_discount || 0))
      + caseProcedures.reduce((sum, p) => sum + Math.max(0, Number(p.master_packages.price) - Number(p.package_discount || 0)), 0)
    : null;

  return (
    <Section num={3} color="var(--indigo)" title="Package" done={allSelected} defaultOpen={!allSelected} active={active}>
      {loadingPackages ? (
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading packages...</div>
      ) : (
        <div>
          <PackagePickerBlock
            title={sc.procedure_name}
            target={sc}
            packages={packages}
            onSelect={(packageId, discount) => onAction(selectPackage)(sc.id, packageId, discount)}
            onChangePackage={(reason) => onAction(changePackage)(sc.id, reason)}
            onUpdateDiscount={(discount, reason) => onAction(updatePackageDiscount)(sc.id, discount, reason)}
          />
          {caseProcedures.map((p) => (
            <div key={p.id} style={{ marginTop: 14, paddingTop: 14, borderTop: '1px dashed var(--g200)' }}>
              <PackagePickerBlock
                title={`${p.procedure_name} -- ${EYE_LABEL[p.eye] || p.eye}`}
                target={p}
                packages={packages}
                onSelect={(packageId, discount) => onAction(selectProcedurePackage)(p.id, packageId, discount)}
                onChangePackage={(reason) => onAction(changeProcedurePackage)(p.id, reason)}
                onUpdateDiscount={(discount, reason) => onAction(updateProcedurePackageDiscount)(p.id, discount, reason)}
              />
            </div>
          ))}
          {caseProcedures.length > 0 && totalNet !== null && (
            <div style={{ marginTop: 14, paddingTop: 12, borderTop: '1.5px solid var(--g200)', display: 'flex', justifyContent: 'space-between', fontSize: 13, fontWeight: 700 }}>
              <span>Total for this surgery</span>
              <span>Rs.{totalNet.toLocaleString('en-IN')}</span>
            </div>
          )}
        </div>
      )}
    </Section>
  );
}

// ── SURGERY DATE BOOKING (+ IOL PROCUREMENT NOTES) ──────────────────
// Date+session picking lives entirely in the OT Calendar popup (picks
// both together, posts back via postMessage) -- so there is no
// separate session picker here anymore. Having one here too used to
// mean picking the session twice for the same booking.
function IolAndBookingSection({ sc, otSchedule, iolApproval, onAction, active, num }) {
  const [iolNotes, setIolNotesLocal] = useState(sc.iol_order_notes || '');
  const [surgeons, setSurgeons] = useState([]);
  const [surgeonId, setSurgeonId] = useState(sc.surgeon_id || '');
  const [date, setDate] = useState('');
  const [sessionId, setSessionId] = useState('');
  const [sessionName, setSessionName] = useState('');

  useEffect(() => { getSurgeons().then(setSurgeons); }, []);

  // The date+session picker lives in the OT Schedule module's own
  // Calendar tab (prior bookings visible there, one place instead of
  // duplicating a calendar here) -- opened as a real popup window, and
  // the chosen slot comes back via postMessage instead of a page
  // redirect, since this is a multi-step form the user shouldn't lose.
  useEffect(() => {
    function handleMessage(e) {
      if (e.origin !== window.location.origin) return;
      if (e.data?.type !== 'ot-slot-picked' || e.data.caseId !== sc.id) return;
      setDate(e.data.date);
      setSessionId(e.data.sessionId);
      setSessionName(e.data.sessionName || '');
    }
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [sc.id]);

  function openCalendarPicker() {
    const label = encodeURIComponent(`${formatPatientName(sc.patients)} -- ${sc.procedure_name || ''} (${sc.eye || ''})`.trim());
    openPopup(`/ot-calendar-picker?pickFor=${sc.id}&pickLabel=${label}`, `ot-calendar-${sc.id}`, { width: 460, height: 680 });
  }

  const canBook = sc.status === 'Ready for Scheduling';

  const [rescheduling, setRescheduling] = useState(false);
  const [rescheduleReason, setRescheduleReason] = useState('');

  if (otSchedule) {
    return (
      <Section num={num} color="var(--teal)" title="Surgery Date Booking" done active={active}>
        {!rescheduling ? (
          <div style={{ background: 'var(--green-lt)', border: '1px solid var(--green)', borderRadius: 8, padding: 10, fontSize: 12.5, marginBottom: 10, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><i className="ti ti-calendar-check"></i> Booked -- {new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}, {otSchedule.master_ot_sessions?.name} session</span>
            {otSchedule.status === 'Scheduled' && <button className="btn btn-sm" onClick={() => setRescheduling(true)}>Reschedule</button>}
          </div>
        ) : (
          <div style={{ marginBottom: 10 }}>
            <div style={{ marginBottom: 8 }}>
              {date ? (
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
                  <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
                  <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
                </div>
              ) : (
                <button className="btn btn-sm" onClick={openCalendarPicker}>
                  <i className="ti ti-calendar"></i> Open OT Calendar
                </button>
              )}
            </div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Reason for rescheduling..." value={rescheduleReason} onChange={(e) => setRescheduleReason(e.target.value)} />
              <button
                className="btn btn-sm btn-primary"
                disabled={!date || !sessionId || !rescheduleReason.trim()}
                onClick={async () => {
                  const r = await onAction(rescheduleOTSlot)(otSchedule.id, date, sessionId, rescheduleReason);
                  if (r?.error) return;
                  setRescheduling(false); setRescheduleReason(''); setDate(''); setSessionId(''); setSessionName('');
                }}
              >
                Confirm
              </button>
              <button className="btn btn-sm" onClick={() => setRescheduling(false)}>Cancel</button>
            </div>
          </div>
        )}

        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>
      </Section>
    );
  }

  return (
    <Section num={num} color="var(--teal)" title="Surgery Date Booking" done={false} defaultOpen active={active}>
      <div style={{ marginBottom: 10 }}>
        <label className="flbl">Date</label>
        {date ? (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--g50)', border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', fontSize: 12.5 }}>
            <span><i className="ti ti-calendar"></i> {new Date(`${date}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}{sessionName ? ` -- ${sessionName}` : ''}</span>
            <button className="btn btn-sm" onClick={openCalendarPicker}>Change</button>
          </div>
        ) : (
          <button className="btn btn-sm" onClick={openCalendarPicker}>
            <i className="ti ti-calendar"></i> Open OT Calendar
          </button>
        )}
      </div>

      <div style={{ marginBottom: 10 }}>
        <label className="flbl">Surgeon</label>
        <select className="fi fi-sm" value={surgeonId} onChange={(e) => setSurgeonId(e.target.value)}>
          <option value="">--</option>
          {surgeons.map((s) => <option key={s.id} value={s.id}>{s.full_name}</option>)}
        </select>
      </div>

      <div style={{ marginBottom: 12 }}>
        <label className="flbl">IOL Order Notes</label>
        <div style={{ display: 'flex', gap: 8 }}>
          <input className="fi fi-sm" style={{ flex: 1 }} placeholder='e.g. "Ordered Alcon monofocal +21D from XYZ Optics, expected Friday"' value={iolNotes} onChange={(e) => setIolNotesLocal(e.target.value)} />
          <button className="btn btn-sm" onClick={() => onAction(setIolOrderNotes)(sc.id, iolNotes)}>Save</button>
        </div>
      </div>

      <button
        className="btn btn-primary btn-sm"
        disabled={!date || !sessionId}
        onClick={async () => {
          if (!canBook) {
            const r = await onAction(markReadyForScheduling)(sc.id);
            if (r?.error) return;
          }
          await onAction(bookOTSlot)(sc.id, date, sessionId, surgeonId || null, null);
        }}
      >
        <i className="ti ti-calendar-check"></i> Give This Date
      </button>
    </Section>
  );
}

// ── PATIENT CHECK-IN (live status, deep-link only) ──
function PatientCheckinSection({ otSchedule, checkinCompletedAt, paymentDone, active, num }) {
  if (!paymentDone) {
    return (
      <Section num={num} color="var(--g400)" title="Patient Check-In" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Complete Payment first.</div>
      </Section>
    );
  }

  let status = 'Not yet booked';
  let color = 'var(--g400)';
  let action = null;
  const done = !!checkinCompletedAt;

  if (otSchedule) {
    if (done) {
      status = 'Checked in';
      color = 'var(--green)';
      action = { label: 'View in Patient Check-In', onClick: () => openTab(`/patient-checkin?otScheduleId=${otSchedule.id}`, `checkin-${otSchedule.id}`) };
    } else {
      status = `Scheduled -- ${new Date(otSchedule.scheduled_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })} -- not yet checked in`;
      color = 'var(--blue)';
      action = { label: 'Open in Patient Check-In', onClick: () => openTab(`/patient-checkin?otScheduleId=${otSchedule.id}`, `checkin-${otSchedule.id}`) };
    }
  }

  return (
    <Section num={num} color={color} title="Patient Check-In" done={done} defaultOpen={!!otSchedule && !done} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Balance payment, consent, and pre-op checklist all happen in the Patient Check-In module -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {action && (
        <button className="btn btn-sm btn-primary" onClick={action.onClick}>
          <i className="ti ti-arrow-right"></i> {action.label}
        </button>
      )}
    </Section>
  );
}

// ── INTRAOPERATIVE MANAGEMENT (live status, deep-links only) --
// covers Check-In through the surgery itself. Recovery and discharge
// are their own dedicated step below (9), not folded in here. ──
function IntraopManagementSection({ otSchedule, checkinCompletedAt, active, num }) {
  let status = 'Waiting on Patient Check-In';
  let color = 'var(--g400)';
  let action = null;
  const locked = !checkinCompletedAt;
  const done = otSchedule?.status === 'Completed';

  if (otSchedule && checkinCompletedAt) {
    if (otSchedule.status === 'In Progress') {
      status = 'In surgery now';
      color = 'var(--red)';
      action = { label: 'Continue in Intraoperative Management', onClick: () => openTab(`/ot-intraop?otScheduleId=${otSchedule.id}`, `intraop-${otSchedule.id}`) };
    } else if (otSchedule.status === 'Completed') {
      status = 'Surgery completed';
      color = 'var(--green)';
    } else {
      status = 'Checked in -- ready for OT';
      color = 'var(--blue)';
      action = { label: 'Open in Intraoperative Management', onClick: () => openTab(`/ot-intraop?otScheduleId=${otSchedule.id}`, `intraop-${otSchedule.id}`) };
    }
  }

  return (
    <Section num={num} color={color} title="Intraoperative Management" done={done} defaultOpen={!!checkinCompletedAt} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      {locked ? (
        <div style={{ fontSize: 11.5, color: 'var(--g500)' }}><i className="ti ti-lock"></i> Complete Patient Check-In first.</div>
      ) : (
        <>
          <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
            The surgery itself happens in the Intraoperative Management module -- that clinical documentation stays where it is. This just shows where the case currently stands.
          </div>
          {action && (
            <button className="btn btn-sm btn-primary" onClick={action.onClick}>
              <i className="ti ti-arrow-right"></i> {action.label}
            </button>
          )}
        </>
      )}
    </Section>
  );
}

// ── RECOVERY & DISCHARGE -- separate module: post-op recovery
// monitoring through to discharge. Deep-links straight to the
// patient's recovery episode, opened as a real new tab (window.opener
// intact) so it can signal back and close itself once discharge is
// confirmed -- same pattern as IOL Approval, Medical Fitness, Patient
// Check-In, and Intraoperative Management above. ──
function RecoveryDischargeSection({ otSchedule, recoveryEpisode, active, num }) {
  const surgeryDone = otSchedule?.status === 'Completed';
  const discharged = !!recoveryEpisode?.discharge_date;

  if (!surgeryDone) {
    return (
      <Section num={num} color="var(--g400)" title="Recovery &amp; Discharge" done={false} active={active}>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> Complete Intraoperative Management first.</div>
      </Section>
    );
  }

  const status = discharged
    ? `Discharged -- ${new Date(recoveryEpisode.discharge_date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`
    : 'In Recovery -- not yet discharged';

  return (
    <Section num={num} color={discharged ? 'var(--green)' : 'var(--teal)'} title="Recovery &amp; Discharge" done={discharged} defaultOpen={!discharged} active={active}>
      <div style={{ fontSize: 13, fontWeight: 600, marginBottom: 8 }}>{status}</div>
      <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 10 }}>
        Recovery monitoring, discharge instructions, and the follow-up schedule happen in the Recovery module -- that clinical documentation stays where it is. This just shows where the case currently stands.
      </div>
      {recoveryEpisode && (
        <button
          className="btn btn-sm btn-primary"
          onClick={() => openTab(`/ot-recovery?episodeId=${recoveryEpisode.id}`, `recovery-${recoveryEpisode.id}`)}
        >
          <i className="ti ti-arrow-right"></i> {discharged ? 'View Recovery Record' : 'Open Recovery & Discharge'}
        </button>
      )}
    </Section>
  );
}
