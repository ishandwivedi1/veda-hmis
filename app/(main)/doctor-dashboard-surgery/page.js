'use client';

import { useState, useEffect, useCallback, useMemo } from 'react';
import { formatPatientName, formatPatientAge } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import { getSurgeryDashboardScheduled, getSurgeryDashboardActive, getSurgeryDashboardDischargedToday, getSurgeryDashboardHistory } from './actions';
import { getPendingIolApprovals } from '@/app/(main)/iol-approval/actions';
import { getPostOpTurnedUpToday } from '@/app/(main)/ot-postop/actions';
import { getSurgicalCaseLists, getSurgicalEvaluationArrivalsToday } from '@/app/(main)/surgical-journey/actions';
import { getMedicalFitnessQueue } from '@/app/(main)/medical-fitness/actions';

function patientName(sc) {
  const p = sc?.patients;
  return p ? displayName(p) : 'Unknown';
}

// Shared by patientName() and the three normalize* row builders below --
// name plus age, so surgeon and OT staff can identify who's who across
// Arrivals, Surgical Evaluation, and Post-Op without opening each row.
function displayName(p) {
  if (!p) return 'Unknown';
  const age = formatPatientAge(p);
  return age ? `${formatPatientName(p)} (${age})` : formatPatientName(p);
}

function fmtDate(d) {
  if (!d) return '--';
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

// IST "today" as YYYY-MM-DD, matching the date-only columns (scheduled_date,
// discharge_date) coming back from Postgres -- string comparison is exact.
function todayIst() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

function TabButton({ active, onClick, icon, label }) {
  return (
    <button
      type="button"
      onClick={onClick}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: active ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

function initials(name) {
  const parts = (name || '').trim().split(/\s+/);
  return ((parts[0]?.[0] || '') + (parts[1]?.[0] || '')).toUpperCase();
}

const ARRIVAL_STAGE_COLOR = { 'Pending Check-In': 'var(--amber)', 'Checked In': 'var(--cyan)', 'In OT': 'var(--blue)', 'In Recovery': 'var(--purple)', 'Discharged': 'var(--green)' };

// Normalizes the three different row shapes (ot_schedule "active" rows,
// surgical_cases rows, recovery_episodes rows) into one common row
// shape so all three columns below can render the same way -- each
// linking straight to wherever that patient's record actually lives.
function normalizeArrival(row, stageLabel) {
  const sc = row.surgical_cases;
  const p = sc?.patients;
  const href = (stageLabel === 'Pending Check-In' || stageLabel === 'Checked In' || stageLabel === 'In OT') ? `/ot-intraop?otScheduleId=${row.id}` : `/ot-recovery?episodeId=${stageLabel === 'In Recovery' ? row.recoveryEpisodeId : row.id}`;
  return { key: `arr-${row.id}`, name: displayName(p), uhid: p?.uhid, subtitle: `${sc?.procedure_name || ''}${sc?.eye ? ` (${sc.eye})` : ''}`, stageLabel, href };
}
function normalizeSurgicalEval(c) {
  const p = c.patients;
  return { key: `eval-${c.id}`, name: displayName(p), uhid: p?.uhid, subtitle: `${c.procedure_name || ''}${c.eye ? ` (${c.eye})` : ''}`, href: `/surgical-journey/${c.id}` };
}
function normalizePostOp(e) {
  const sc = e.surgical_cases;
  const p = sc?.patients;
  return { key: `postop-${e.id}`, name: displayName(p), uhid: p?.uhid, subtitle: `${sc?.procedure_name || ''}${sc?.eye ? ` (${sc.eye})` : ''}`, href: `/ot-postop?episodeId=${e.id}` };
}

// One column within Today's Surgery Related Visits -- header (icon,
// title, count) then a scrollable list of real patient rows, each a
// direct link into that patient's actual record (Surgical Journey for
// evaluation, Intraop/Recovery for surgery day, Post-Op for review) --
// not a generic module landing page.
function ArrivalColumn({ icon, color, title, items, emptyText, showStage, borderLeft }) {
  return (
    <div style={{ padding: '14px 16px', borderTop: '1px solid var(--g200)', borderLeft: borderLeft ? '1px solid var(--g200)' : 'none' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 6, marginBottom: 10 }}>
        <i className={`ti ${icon}`} style={{ color, fontSize: 15 }}></i>
        <span style={{ fontSize: 14.5, fontWeight: 700, color: 'var(--g700)' }}>{title}</span>
        <span className="badge" style={{ background: items.length > 0 ? `${color}20` : 'var(--g100)', color: items.length > 0 ? color : 'var(--g400)', marginLeft: 'auto' }}>{items.length}</span>
      </div>
      {items.length === 0 ? (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', padding: '6px 0' }}>{emptyText}</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6, maxHeight: 260, overflowY: 'auto' }}>
          {items.map((a) => (
            <a key={a.key} href={a.href} className="queue-row" style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 9px', borderRadius: 'var(--r)', border: '1px solid var(--g200)', textDecoration: 'none', color: 'inherit' }}>
              <div style={{ width: 24, height: 24, borderRadius: '50%', flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 9.5, fontWeight: 700, background: 'var(--g100)', color: 'var(--g600)' }}>
                {initials(a.name)}
              </div>
              <div style={{ minWidth: 0, flex: 1 }}>
                <div style={{ fontWeight: 600, fontSize: 11.5, color: 'var(--g800)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.name}</div>
                <div style={{ fontSize: 10.5, color: 'var(--g500)', overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{a.uhid}{a.subtitle ? ` -- ${a.subtitle}` : ''}</div>
              </div>
              {showStage && a.stageLabel && (
                <span className="badge" style={{ background: `${ARRIVAL_STAGE_COLOR[a.stageLabel]}20`, color: ARRIVAL_STAGE_COLOR[a.stageLabel], fontWeight: 700, fontSize: 9, flexShrink: 0 }}>{a.stageLabel}</span>
              )}
            </a>
          ))}
        </div>
      )}
    </div>
  );
}

// ── TODAY'S SURGERY RELATED VISITS -- same full-width-banner-plus-
// divided-strip treatment as Surgical Workflow below it, since that's
// the pattern that landed well. Order matches the actual patient
// journey: Surgical Evaluation, then Surgeries Today, then Post-Op
// Review. Every column shows real patient rows now, not just a count
// -- each one a direct link into that specific patient's actual
// record (Surgical Journey / Intraop-Recovery / Post-Op), not a
// generic module page. Sits above the workflow strip since it answers
// a different question (THAT they arrived, not WHERE the case
// currently stands) -- no count here repeats a count below.
//
// Color coding: cyan = pre-op/evaluation, blue = the OT/surgery day
// itself (matches Intraoperative Mgmt in the strip below -- same
// concept), teal = post-op (matches the Post-Op module everywhere
// else it's shown).
function TodaysArrivals({ surgicalEval, arrivedForSurgery, postOpToday, onOpenSurgicalJourney }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 20 }}>
      <div
        onClick={onOpenSurgicalJourney}
        style={{ cursor: 'pointer', padding: '16px 20px', background: 'var(--blue-lt)' }}
      >
        <div className="card-title" style={{ marginBottom: 2 }}><i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today's Surgery Related Visits</div>
        <div style={{ fontSize: 11, color: 'var(--g500)' }}>Everyone who has walked in today, across the whole surgical journey.</div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)' }}>
        <ArrivalColumn icon="ti-door-enter" color="var(--cyan)" title="Surgical Evaluation" items={surgicalEval} emptyText="No one arrived for evaluation yet today." />
        <ArrivalColumn icon="ti-scalpel" color="var(--blue)" title="Surgeries Today" items={arrivedForSurgery} emptyText="No one has checked in for surgery yet today." showStage borderLeft />
        <ArrivalColumn icon="ti-stethoscope" color="var(--teal)" title="Post-Op Review" items={postOpToday} emptyText="No post-op reviews yet today." borderLeft />
      </div>
    </div>
  );
}

const STAGE_COLORS = {
  'Scheduled': 'var(--amber)',
  'Checked-In / In OT': 'var(--blue)',
  'In Recovery': 'var(--purple)',
  'Discharged': 'var(--green)',
};

function StageBadge({ stage }) {
  const c = STAGE_COLORS[stage] || 'var(--g400)';
  return <span className="badge" style={{ background: `${c}20`, color: c, fontWeight: 700 }}>{stage}</span>;
}

function CaseRow({ sc, dateLabel, dateValue, stage, onClick }) {
  return (
    <tr onClick={onClick} style={{ cursor: 'pointer' }}>
      <td style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{sc.surgery_code || '--'}</td>
      <td>
        <strong>{patientName(sc)}</strong>
        <br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span>
      </td>
      <td style={{ fontSize: 12 }}>{sc.procedure_name}{sc.eye ? ` (${sc.eye})` : ''}</td>
      <td style={{ fontSize: 11 }}>{sc.profiles?.full_name || '--'}</td>
      <td style={{ fontSize: 11 }}>{dateLabel}: {fmtDate(dateValue)}</td>
      <td><StageBadge stage={stage} /></td>
      <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
    </tr>
  );
}

// ── SURGICAL WORKFLOW GROUP -- Medical Fitness, IOL Approval, Check-In,
// Intraoperative Management, and Recovery & Discharge aren't peers of
// Surgical Workflow, they're STAGES within it -- the same case moving
// through the same journey. Previously all six sat as equal-sized
// tiles side by side, which flattened that relationship. Now Surgical
// Workflow is a full-width header banner (with its own Active /
// Awaiting Confirmation counts, still one click to the list), and the
// five stages sit underneath it as a single divided strip, inside the
// same card -- reads as one group, not six unrelated ones.
//
// Color coding: indigo for the banner itself (the umbrella), then each
// stage gets a color tied to real meaning -- green for IOL Approval
// (a green light), red for Medical Fitness (a medical clearance flag),
// amber for Check-In (arrival/waiting, matches Patient Check-In
// elsewhere), blue for Intraop (matches Surgeries Today above -- same
// OT-day concept), purple for Recovery (matches its own badge color on
// Surgical Journey's own list page). ──
function SurgicalWorkflowGroup({ active, awaitingConfirmation, stages, onOpenSurgicalJourney }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 20 }}>
      <div
        onClick={onOpenSurgicalJourney}
        style={{ cursor: 'pointer', padding: '16px 20px', background: 'var(--indigo-lt)', display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 10 }}
      >
        <div>
          <div className="card-title" style={{ marginBottom: 2 }}><i className="ti ti-route" style={{ color: 'var(--indigo)' }}></i> Surgical Workflow</div>
          <div style={{ fontSize: 11, color: 'var(--g500)' }}>Advance paid vs. still awaiting confirmation.</div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 28 }}>
          <div style={{ textAlign: 'center' }}>
            <div style={{ fontSize: 22, fontWeight: 800, color: active > 0 ? 'var(--indigo)' : 'var(--g300)' }}>{active}</div>
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Active</div>
          </div>
          <div style={{ textAlign: 'center' }}>
            <div style={{ fontSize: 22, fontWeight: 800, color: awaitingConfirmation > 0 ? 'var(--amber)' : 'var(--g300)' }}>{awaitingConfirmation}</div>
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>Awaiting Confirmation</div>
          </div>
          <i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: `repeat(${stages.length}, 1fr)` }}>
        {stages.map((s, i) => (
          <div
            key={s.title}
            onClick={s.onClick}
            style={{
              cursor: 'pointer', padding: '14px 12px', textAlign: 'center',
              borderTop: '1px solid var(--g200)', borderLeft: i > 0 ? '1px solid var(--g200)' : 'none',
            }}
          >
            <i className={`ti ${s.icon}`} style={{ color: s.color, fontSize: 16 }}></i>
            <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--g700)', marginTop: 4 }}>{s.title}</div>
            <div style={{ fontSize: 22, fontWeight: 800, color: s.count > 0 ? 'var(--g800)' : 'var(--g300)', marginTop: 2 }}>{s.count}</div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ── DASHBOARD -- Today's Arrivals up top (who's actually walked
// through the door today, across all three surgical-patient
// journeys), then the workflow tile grid below it (where every case
// currently stands in the pipeline). Two different questions, kept in
// two separate sections rather than one wall of numbers -- and no
// count appears in both, so nothing is shown twice in two different
// visual styles.
function DashboardTab({ scheduled, active, dischargedToday, iolApprovals, postOpToday, surgicalJourneyActive, awaitingReturnCases, medicalFitnessQueue, surgicalEvalArrivals, error, onOpenScheduled, onOpenIntraop, onOpenRecovery, onOpenIol, onOpenSurgicalJourney, onOpenMedicalFitness }) {
  const today = todayIst();
  const todayScheduled = useMemo(() => scheduled.filter((b) => b.scheduled_date === today), [scheduled, today]);
  // Two genuinely different moments, previously conflated:
  // patient_reported_at is stamped automatically the instant a
  // Surgery visit is created (i.e. "they walked in the building"),
  // while checkin_completed_at is only stamped once the actual
  // check-in workflow -- consent, checklist, IOL verification -- is
  // finished in Patient Check-In. "Not yet checked in" (this tile's
  // own hint text) means checkin_completed_at is null, regardless of
  // whether they've physically arrived yet.
  const notYetCheckedIn = useMemo(() => todayScheduled.filter((b) => !b.ot_intraop_records?.checkin_completed_at), [todayScheduled]);
  // Arrived, but the check-in workflow itself isn't done yet.
  const pendingCheckIn = useMemo(() => todayScheduled.filter((b) => b.patient_reported_at && !b.ot_intraop_records?.checkin_completed_at), [todayScheduled]);
  // Check-in workflow genuinely complete, just not yet moved into OT.
  const checkedInNotStarted = useMemo(() => todayScheduled.filter((b) => b.ot_intraop_records?.checkin_completed_at && b.status === 'Scheduled'), [todayScheduled]);
  const inOt = useMemo(() => active.filter((b) => b.stage === 'Checked-In / In OT'), [active]);
  const inRecovery = useMemo(() => active.filter((b) => b.stage === 'In Recovery'), [active]);

  // Same underlying rows as the tiles below, but scoped to TODAY's
  // arrivals specifically -- someone still in recovery from
  // yesterday still counts on the "Recovery & Discharge" pipeline
  // tile, but isn't one of today's arrivals. Includes both
  // pendingCheckIn and checkedInNotStarted -- anyone who's walked in
  // today shows up here, with the badge making clear which of the two
  // they actually are, rather than only surfacing once check-in is
  // fully done.
  const arrivedForSurgery = useMemo(() => [
    ...pendingCheckIn.map((b) => normalizeArrival(b, 'Pending Check-In')),
    ...checkedInNotStarted.map((b) => normalizeArrival(b, 'Checked In')),
    ...inOt.filter((b) => b.scheduled_date === today).map((b) => normalizeArrival(b, 'In OT')),
    ...inRecovery.filter((b) => b.scheduled_date === today).map((b) => normalizeArrival(b, 'In Recovery')),
    ...dischargedToday.map((b) => normalizeArrival(b, 'Discharged')),
  ], [pendingCheckIn, checkedInNotStarted, inOt, inRecovery, dischargedToday, today]);

  const surgicalEvalRows = useMemo(() => surgicalEvalArrivals.map(normalizeSurgicalEval), [surgicalEvalArrivals]);
  const postOpTodayRows = useMemo(() => postOpToday.map(normalizePostOp), [postOpToday]);

  return (
    <div>
      {error && <div className="msg-err" style={{ marginBottom: 16 }}><i className="ti ti-alert-triangle"></i> {error}</div>}

      <TodaysArrivals
        surgicalEval={surgicalEvalRows}
        arrivedForSurgery={arrivedForSurgery}
        postOpToday={postOpTodayRows}
        onOpenSurgicalJourney={onOpenSurgicalJourney}
      />

      <SurgicalWorkflowGroup
        active={surgicalJourneyActive.length}
        awaitingConfirmation={awaitingReturnCases.length}
        onOpenSurgicalJourney={onOpenSurgicalJourney}
        stages={[
          { icon: 'ti-heartbeat', color: 'var(--red)', title: 'Medical Fitness', count: medicalFitnessQueue.length, onClick: onOpenMedicalFitness },
          { icon: 'ti-lens', color: 'var(--green)', title: 'IOL Approval', count: iolApprovals.length, onClick: onOpenIol },
          { icon: 'ti-clipboard-check', color: 'var(--amber)', title: 'Patient Check-In', count: notYetCheckedIn.length, onClick: onOpenScheduled },
          { icon: 'ti-scalpel', color: 'var(--blue)', title: 'Intraoperative Mgmt', count: inOt.length, onClick: onOpenIntraop },
          { icon: 'ti-bed', color: 'var(--purple)', title: 'Recovery & Discharge', count: inRecovery.length, onClick: onOpenRecovery },
        ]}
      />
    </div>
  );
}

function HistoryTab({ rows, loading, onOpen }) {
  const [search, setSearch] = useState('');
  const filtered = rows.filter((e) => {
    if (!search.trim()) return true;
    const q = search.toLowerCase();
    const sc = e.surgical_cases;
    return patientName(sc).toLowerCase().includes(q) || sc.patients?.uhid?.toLowerCase().includes(q) || sc.surgery_code?.toLowerCase().includes(q) || sc.procedure_name?.toLowerCase().includes(q);
  });

  return (
    <div className="card">
      <div className="card-head" style={{ marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
        <div className="card-title"><i className="ti ti-history" style={{ color: 'var(--green)' }}></i> Completed & Discharged Surgeries</div>
        <input className="fi fi-sm" placeholder="Search patient, UHID, surgery ID..." value={search} onChange={(e) => setSearch(e.target.value)} style={{ width: 220 }} />
      </div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 24, textAlign: 'center' }}>Loading...</div>}
      {!loading && (
        <table className="tbl">
          <thead><tr><th>Surgery ID</th><th>Patient</th><th>Procedure</th><th>Surgeon</th><th>Discharged</th><th>Stage</th><th></th></tr></thead>
          <tbody>
            {filtered.map((e) => (
              <CaseRow key={e.id} sc={e.surgical_cases} stage="Discharged" dateLabel="Discharged" dateValue={e.discharge_date} onClick={() => onOpen(e)} />
            ))}
            {filtered.length === 0 && <tr><td colSpan={7} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No completed surgeries found.</td></tr>}
          </tbody>
        </table>
      )}
    </div>
  );
}

export default function DoctorSurgeryDashboardPage() {
  const router = useRouter();
  const [activeTab, setActiveTab] = useState('dashboard');
  const [scheduled, setScheduled] = useState([]);
  const [active, setActive] = useState([]);
  const [dischargedToday, setDischargedToday] = useState([]);
  const [iolApprovals, setIolApprovals] = useState([]);
  const [postOpToday, setPostOpToday] = useState([]);
  const [surgicalJourneyActive, setSurgicalJourneyActive] = useState([]);
  const [awaitingReturnCases, setAwaitingReturnCases] = useState([]);
  const [medicalFitnessQueue, setMedicalFitnessQueue] = useState([]);
  const [surgicalEvalArrivals, setSurgicalEvalArrivals] = useState([]);
  const [error, setError] = useState('');

  // Only what the Dashboard tab actually needs -- getSurgeryDashboardHistory's
  // full 200-row joined history is fetched separately (below), only when the
  // History tab is actually opened, not on every 15s poll regardless of
  // which tab is showing. That query alone was likely the single biggest
  // contributor to this dashboard feeling slow.
  const refresh = useCallback(async () => {
    try {
      const [s, a, dischargedTodayResult, iol, postOp, surgicalCaseLists, medFitness, surgicalEvalArrivalsData] = await Promise.all([
        getSurgeryDashboardScheduled(),
        getSurgeryDashboardActive(),
        getSurgeryDashboardDischargedToday(),
        getPendingIolApprovals(),
        getPostOpTurnedUpToday(),
        getSurgicalCaseLists(),
        getMedicalFitnessQueue(),
        getSurgicalEvaluationArrivalsToday(),
      ]);
      const firstError = s.error || a.error || dischargedTodayResult.error;
      setScheduled(s.rows); setActive(a.rows); setDischargedToday(dischargedTodayResult.rows);
      setIolApprovals(iol || []);
      setPostOpToday(postOp || []);
      setSurgicalJourneyActive(surgicalCaseLists.active || []);
      setAwaitingReturnCases(surgicalCaseLists.awaitingConfirmation || []);
      setMedicalFitnessQueue(medFitness || []);
      setSurgicalEvalArrivals(surgicalEvalArrivalsData || []);
      setError(firstError || '');
      if (firstError) console.error('Surgery Dashboard load error:', firstError);
    } catch (e) {
      // Belt-and-braces: even if a Server Action call itself fails
      // (network drop, deploy mid-flight, etc.) rather than returning
      // its own { error }, this still guarantees loading clears and
      // something visible shows up instead of an infinite spinner.
      console.error('Surgery Dashboard refresh failed:', e);
      setError(e?.message || 'Failed to load Surgery Dashboard.');
    }
  }, []);

  // The heavy 200-row history query -- lazy-loaded only when the
  // History tab is actually selected, and only re-fetched if they
  // switch back to it, not on the 15s poll interval.
  const [fullHistory, setFullHistory] = useState([]);
  const [loadingHistory, setLoadingHistory] = useState(true);
  const refreshFullHistory = useCallback(async () => {
    setLoadingHistory(true);
    const h = await getSurgeryDashboardHistory();
    setFullHistory(h.rows || []);
    setLoadingHistory(false);
  }, []);
  useEffect(() => { if (activeTab === 'history') refreshFullHistory(); }, [activeTab, refreshFullHistory]);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  // Every tile below is a pure count -- no patient names shown on this
  // dashboard -- so clicking always lands on the workflow page's own
  // list/queue, not a specific patient's record. The surgeon picks the
  // patient from there.
  function openScheduled() {
    router.push('/patient-checkin');
  }

  function openIntraop() {
    router.push('/ot-intraop');
  }

  function openRecovery() {
    router.push('/ot-recovery');
  }

  function openIol() {
    router.push('/iol-approval');
  }

  function openMedicalFitness() {
    router.push('/medical-fitness');
  }

  function openSurgicalJourney() {
    router.push('/surgical-journey');
  }

  // History -- Recovery & Discharge workspace already renders discharged
  // episodes fine (Recovery's own History tab uses the same component).
  function openHistory(episode) {
    router.push(`/ot-recovery?episodeId=${episode.id}`);
  }

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 16 }}>
        <div style={{ display: 'flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 520, flex: 1 }}>
          <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
          <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
        </div>
        <button className="btn btn-sm" style={{ marginLeft: 16 }} onClick={() => router.push('/doctor-dashboard')}>
          <i className="ti ti-stethoscope"></i> OPD Dashboard
        </button>
      </div>

      {activeTab === 'dashboard' && (
        <DashboardTab
          scheduled={scheduled} active={active} dischargedToday={dischargedToday}
          iolApprovals={iolApprovals} postOpToday={postOpToday}
          surgicalJourneyActive={surgicalJourneyActive} awaitingReturnCases={awaitingReturnCases}
          medicalFitnessQueue={medicalFitnessQueue} surgicalEvalArrivals={surgicalEvalArrivals}
          error={error}
          onOpenScheduled={openScheduled} onOpenIntraop={openIntraop} onOpenRecovery={openRecovery}
          onOpenIol={openIol} onOpenSurgicalJourney={openSurgicalJourney}
          onOpenMedicalFitness={openMedicalFitness}
        />
      )}

      {activeTab === 'history' && <HistoryTab rows={fullHistory} loading={loadingHistory} onOpen={openHistory} />}
    </div>
  );
}
