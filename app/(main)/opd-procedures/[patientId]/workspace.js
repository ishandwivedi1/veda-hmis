'use client';

import { useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useRouter } from 'next/navigation';
import { getPatientById } from '@/app/(main)/visits/actions';
import { openTab } from '@/lib/popup';
import {
  getPatientOpdProcedureJourney,
  getOpdProcedureMonthSummary,
  getPostProcedurePrescriptions,
  getDrugCatalogForOpdProcedures,
  addPostProcedureMedicine,
  removePostProcedureMedicine,
  addPostProcedureTaperedMedicine,
  removePostProcedureTaperGroup,
  setOpdProcedureDecision,
  scheduleOpdProcedure,
  checkInOpdProcedure,
  completeOpdProcedure,
  cancelOpdProcedure,
  updateCompletedProcedureNotes,
} from '../actions';

const DECISIONS = ['Accepted', 'Wants Time to Decide', 'Discuss with Family', 'Financial Constraint', 'Declined', 'Second Opinion', 'Other'];

const STAGE = {
  AwaitingDecision: { label: 'Awaiting Decision', color: 'var(--amber)' },
  FollowUp: { label: 'Follow Up', color: 'var(--amber)' },
  Scheduled: { label: 'Scheduled', color: 'var(--blue)' },
  'Checked In': { label: 'Checked In', color: 'var(--indigo)' },
  Completed: { label: 'Completed', color: 'var(--green)' },
  Done: { label: 'Completed (same day)', color: 'var(--green)' },
  Cancelled: { label: 'Cancelled', color: 'var(--g400)' },
  Declined: { label: 'Declined', color: 'var(--g400)' },
};

function stageFor(p) {
  if (p.status === 'Cancelled') return STAGE.Cancelled;
  if (p.decision === 'Declined') return STAGE.Declined;
  if (p.status === 'Completed') return STAGE.Completed;
  if (p.status === 'Done') return STAGE.Done;
  if (p.status === 'Checked In') return STAGE['Checked In'];
  if (p.status === 'Scheduled') return STAGE.Scheduled;
  if (p.decision && p.decision !== 'Accepted') return STAGE.FollowUp;
  return STAGE.AwaitingDecision;
}

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

// ── STEP ACCORDION -- identical pattern to Surgical Journey's Section
// component: numbered circle (green check once done), colored active
// border + "Next Step" badge, click to expand/collapse.
function Section({ num, color, title, done, active, children }) {
  const [open, setOpen] = useState(!!active);
  return (
    <div
      style={{
        marginBottom: 10,
        borderRadius: 8,
        border: active ? `2px solid ${color}` : '1px solid var(--g200)',
        background: active ? `color-mix(in srgb, ${color} 8%, white)` : '#fff',
        padding: 12,
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

function LockedNote({ text }) {
  return <div style={{ fontSize: 12, color: 'var(--g400)' }}><i className="ti ti-lock"></i> {text}</div>;
}

function DecisionPanel({ c, onSave, busy }) {
  const [decision, setDecision] = useState(c.decision || '');
  const [reason, setReason] = useState('');
  const needsReason = c.decision_locked && decision && decision !== c.decision;
  return (
    <div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 10 }}>
        {DECISIONS.map((d) => (
          <button key={d} type="button" className="btn" style={{ fontSize: 12, background: decision === d ? 'var(--red)' : undefined, color: decision === d ? '#fff' : undefined }} onClick={() => setDecision(d)}>{d}</button>
        ))}
      </div>
      {needsReason && <input className="fi fi-sm" placeholder="Reason for changing a locked decision" value={reason} onChange={(e) => setReason(e.target.value)} style={{ width: '100%', marginBottom: 10 }} />}
      <button className="btn btn-primary" disabled={!decision || busy} onClick={() => onSave(decision, reason)}>Save Decision</button>
    </div>
  );
}

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function todayISO() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

// ── Lightweight calendar picker for the Procedure Date step -- same
// month-grid interaction as OT Schedule's calendar, but without any of
// the OT-specific session/room/capacity machinery, since OPD Procedures
// don't book against theatre capacity. Shows a small dot + count on
// days that already have other OPD Procedures booked, purely for
// awareness while picking a date.
function ProcedureCalendar({ selectedDate, onSelectDate }) {
  const today = todayISO();
  const initial = selectedDate ? new Date(`${selectedDate}T00:00:00`) : new Date();
  const [viewYear, setViewYear] = useState(initial.getFullYear());
  const [viewMonth, setViewMonth] = useState(initial.getMonth());
  const [summary, setSummary] = useState({});
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    getOpdProcedureMonthSummary(viewYear, viewMonth).then((s) => { if (!cancelled) { setSummary(s); setLoading(false); } });
    return () => { cancelled = true; };
  }, [viewYear, viewMonth]);

  function changeMonth(delta) {
    let m = viewMonth + delta;
    let y = viewYear;
    if (m < 0) { m = 11; y -= 1; }
    if (m > 11) { m = 0; y += 1; }
    setViewMonth(m);
    setViewYear(y);
  }

  const firstOfMonth = new Date(viewYear, viewMonth, 1);
  const startWeekday = firstOfMonth.getDay();
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < startWeekday; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  return (
    <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: 10, marginBottom: 10, maxWidth: 300 }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <button type="button" className="btn" style={{ padding: '3px 8px' }} onClick={() => changeMonth(-1)}><i className="ti ti-chevron-left"></i></button>
        <div style={{ fontWeight: 700, fontSize: 13 }}>{MONTH_NAMES[viewMonth]} {viewYear}</div>
        <button type="button" className="btn" style={{ padding: '3px 8px' }} onClick={() => changeMonth(1)}><i className="ti ti-chevron-right"></i></button>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2, marginBottom: 2 }}>
        {DOW.map((d) => <div key={d} style={{ textAlign: 'center', fontSize: 9.5, fontWeight: 700, color: 'var(--g400)' }}>{d[0]}</div>)}
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2, opacity: loading ? 0.5 : 1 }}>
        {cells.map((day, idx) => {
          if (day === null) return <div key={`e${idx}`} />;
          const dateISO = new Date(viewYear, viewMonth, day).toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
          const isPast = dateISO < today;
          const isToday = dateISO === today;
          const isSelected = selectedDate === dateISO;
          const count = summary[dateISO] || 0;
          return (
            <button
              type="button"
              key={dateISO}
              disabled={isPast}
              onClick={() => onSelectDate(dateISO)}
              style={{
                height: 32, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                border: isSelected ? '2px solid var(--blue)' : isToday ? '1.5px solid var(--indigo)' : '1px solid transparent',
                borderRadius: 6, background: isSelected ? 'var(--blue-lt, #dbeafe)' : isPast ? 'transparent' : '#fff',
                cursor: isPast ? 'default' : 'pointer', color: isPast ? 'var(--g300)' : 'var(--g700)', fontSize: 12, fontWeight: isToday ? 800 : 500, position: 'relative',
              }}
            >
              {day}
              {count > 0 && !isPast && <span style={{ position: 'absolute', bottom: 1, fontSize: 7, color: 'var(--amber)', fontWeight: 700 }}>{count}</span>}
            </button>
          );
        })}
      </div>
    </div>
  );
}

function SchedulePanel({ c, onSave, onCancel, busy }) {
  const [date, setDate] = useState(c.scheduled_date || '');
  const [time, setTime] = useState(c.scheduled_time ? c.scheduled_time.slice(0, 5) : '');
  return (
    <div>
      <ProcedureCalendar selectedDate={date} onSelectDate={setDate} />
      <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginBottom: 10 }}>
        <label style={{ fontSize: 12, color: 'var(--g500)' }}>Time (optional)</label>
        <input type="time" className="fi fi-sm" value={time} onChange={(e) => setTime(e.target.value)} />
      </div>
      {date && <div style={{ fontSize: 12.5, color: 'var(--g600)', marginBottom: 10 }}>Selected date: <strong>{fmtDate(date)}</strong></div>}
      <div style={{ display: 'flex', gap: 8 }}>
        <button className="btn btn-primary" disabled={!date || busy} onClick={() => onSave(date, time)}>{c.status === 'Scheduled' ? 'Confirm Reschedule' : 'Confirm Schedule'}</button>
        {c.status === 'Scheduled' && <button className="btn" style={{ color: 'var(--red)' }} disabled={busy} onClick={onCancel}>Cancel Procedure</button>}
      </div>
    </div>
  );
}

function PaymentPanel({ c, patient }) {
  const balanceDue = c.rate != null ? Math.max(0, Number(c.rate) - c.advanceBalance) : null;
  return (
    <div>
      <div style={{ background: 'var(--g50)', borderRadius: 8, padding: 10, marginBottom: 10, fontSize: 12.5 }}>
        {c.rate != null && (
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span>{c.name} {c.eye ? `(${c.eye})` : ''}</span>
            <span>Rs. {Number(c.rate).toLocaleString('en-IN')}</span>
          </div>
        )}
        <div style={{ display: 'flex', justifyContent: 'space-between', marginTop: c.rate != null ? 6 : 0 }}>
          <span>Advance received</span>
          <span style={{ fontWeight: 600, color: 'var(--purple)' }}>Rs. {c.advanceBalance.toLocaleString('en-IN')}</span>
        </div>
      </div>
      {c.advanceBalance > 0 ? (
        <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Advance received.</div>
      ) : (
        <div>
          {balanceDue != null && <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 8 }}>Balance due: <strong style={{ color: 'var(--amber)' }}>Rs. {balanceDue.toLocaleString('en-IN')}</strong></div>}
          <button
            className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', border: 'none' }}
            onClick={() => openTab(`/payments/advance?patientId=${patient.id}${balanceDue != null ? `&amount=${balanceDue}` : ''}&returnTo=opd-procedures`, `advance-${patient.id}`)}
          >
            <i className="ti ti-cash"></i> Collect Advance
          </button>
        </div>
      )}
    </div>
  );
}

function CheckinPanel({ c, onCheckIn, onCancel, onReschedule, busy }) {
  return (
    <div>
      <div style={{ fontSize: 13, marginBottom: 10 }}>
        Scheduled for <strong>{fmtDate(c.scheduled_date)}</strong>{c.scheduled_time ? ` at ${c.scheduled_time.slice(0, 5)}` : ''}.
      </div>
      <div style={{ fontSize: 12.5, marginBottom: 10, color: c.hasActiveVisitToday ? 'var(--green)' : 'var(--red)' }}>
        <i className={`ti ${c.hasActiveVisitToday ? 'ti-check' : 'ti-alert-circle'}`}></i>{' '}
        {c.hasActiveVisitToday ? 'Active visit on file for today.' : "No active visit today -- register at the front desk (OPD Procedure Only) first."}
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn btn-primary" disabled={busy || !c.hasActiveVisitToday} onClick={onCheckIn}>Check In</button>
        <button className="btn" style={{ fontSize: 12 }} disabled={busy} onClick={onReschedule}><i className="ti ti-calendar-time"></i> Reschedule</button>
        <button className="btn" style={{ color: 'var(--red)' }} disabled={busy} onClick={onCancel}>Cancel Procedure</button>
      </div>
    </div>
  );
}

function CompletePanel({ c, onSave, busy, editMode, onCancelEdit }) {
  const [procedurePerformed, setProcedurePerformed] = useState(c.procedure_performed || c.name || '');
  const [findings, setFindings] = useState(c.findings || '');
  const [instructions, setInstructions] = useState(c.post_procedure_instructions || '');
  return (
    <div>
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Procedure Performed</label>
      <input className="fi fi-sm" value={procedurePerformed} onChange={(e) => setProcedurePerformed(e.target.value)} style={{ width: '100%', marginBottom: 8 }} />
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Findings</label>
      <textarea className="fi fi-sm" value={findings} onChange={(e) => setFindings(e.target.value)} style={{ width: '100%', marginBottom: 8, minHeight: 60 }} />
      <label style={{ fontSize: 11, color: 'var(--g500)' }}>Post-Procedure Instructions</label>
      <textarea className="fi fi-sm" value={instructions} onChange={(e) => setInstructions(e.target.value)} style={{ width: '100%', marginBottom: 10, minHeight: 60 }} />
      <MedicineSection procedureId={c.id} />
      <div style={{ display: 'flex', gap: 8, marginTop: 12 }}>
        <button className="btn btn-primary" disabled={busy} onClick={() => onSave({ procedurePerformed, findings, instructions })}>{editMode ? 'Save Changes' : 'Mark Completed'}</button>
        {editMode && <button className="btn" disabled={busy} onClick={onCancelEdit}>Cancel</button>}
      </div>
    </div>
  );
}

// Groups flat prescription rows by taper_group_id so a tapering
// schedule reads (and is removed) as one entry instead of N separate
// rows -- same idea as Consultation's Action Tracker grouping.
function groupPrescriptions(rows) {
  const grouped = [];
  const taperGroups = {};
  (rows || []).forEach((rx) => {
    if (rx.taper_group_id) {
      if (!taperGroups[rx.taper_group_id]) {
        const g = { id: rx.taper_group_id, isTaper: true, drug_name: rx.drug_name, eye: rx.eye, steps: [] };
        taperGroups[rx.taper_group_id] = g;
        grouped.push(g);
      }
      taperGroups[rx.taper_group_id].steps.push(rx);
    } else {
      grouped.push({ ...rx, isTaper: false });
    }
  });
  grouped.forEach((g) => { if (g.isTaper) g.steps.sort((a, b) => (a.taper_step || 0) - (b.taper_step || 0)); });
  return grouped;
}

function MedicineLine({ g }) {
  if (g.isTaper) {
    return (
      <>
        <strong>{g.drug_name}</strong> ({g.eye}) --{' '}
        {g.steps.map((s, i) => (
          <span key={s.id}>{i > 0 && ' -> '}{s.dosage} {s.frequency} x{s.duration}</span>
        ))}, then stop
      </>
    );
  }
  return <><strong>{g.drug_name}</strong> -- {g.dosage} {g.frequency} x {g.duration} ({g.eye})</>;
}

// ── Post-procedure medicines -- same drug catalog, fields, and
// prescriptions table Consultation's writer uses, including tapering
// schedules. No separate print button here -- medicines print as part
// of the Procedure Summary Sheet (renderOpdProcedureSummaryHtml).
function MedicineSection({ procedureId }) {
  const [prescriptions, setPrescriptions] = useState([]);
  const [catalog, setCatalog] = useState({ drugs: [], dosages: [] });
  const [loading, setLoading] = useState(true);
  const [drug, setDrug] = useState('');
  const [drugTypeId, setDrugTypeId] = useState(null);
  const [isOcular, setIsOcular] = useState(true);
  const [dosage, setDosage] = useState('');
  const [frequency, setFrequency] = useState('BD');
  const [duration, setDuration] = useState('1 week');
  const [eye, setEye] = useState('BE');
  const [showSuggestions, setShowSuggestions] = useState(false);
  const [adding, setAdding] = useState(false);
  const [error, setError] = useState('');
  const [showTaperBuilder, setShowTaperBuilder] = useState(false);
  const [taperSteps, setTaperSteps] = useState([{ frequency: 'OD', duration: '1 week', dosage: '' }]);

  const refresh = useCallback(async () => {
    const [pres, cat] = await Promise.all([getPostProcedurePrescriptions(procedureId), getDrugCatalogForOpdProcedures()]);
    setPrescriptions(pres.prescriptions);
    setCatalog(cat);
    setLoading(false);
  }, [procedureId]);

  useEffect(() => { refresh(); }, [refresh]);

  const suggestions = drug.trim().length > 0
    ? catalog.drugs.filter((d) => d.brand?.toLowerCase().includes(drug.toLowerCase()) || (d.generic && d.generic.toLowerCase().includes(drug.toLowerCase()))).slice(0, 8)
    : [];

  function selectDrug(d) {
    setDrug(d.brand || d.generic);
    setDrugTypeId(d.master_drug_types?.id || null);
    setIsOcular(d.master_drug_types?.is_ocular !== false);
    setShowSuggestions(false);
  }

  async function handleAdd() {
    setError('');
    if (!drug.trim()) { setError('Drug name is required.'); return; }
    setAdding(true);
    const result = await addPostProcedureMedicine(procedureId, { drugName: drug, dosage, frequency, duration, eye: isOcular ? eye : 'Oral' });
    setAdding(false);
    if (result.error) { setError(result.error); return; }
    setDrug(''); setDosage(''); setDrugTypeId(null); setIsOcular(true);
    refresh();
  }

  function addTaperStep() { setTaperSteps((prev) => [...prev, { frequency: 'OD', duration: '1 week', dosage: dosage || '' }]); }
  function updateTaperStep(i, field, value) { setTaperSteps((prev) => prev.map((s, idx) => (idx === i ? { ...s, [field]: value } : s))); }
  function removeTaperStep(i) { setTaperSteps((prev) => prev.filter((_, idx) => idx !== i)); }

  async function handleAddTaper() {
    setError('');
    if (!drug.trim()) { setError('Enter a drug name for the tapering schedule.'); return; }
    const steps = taperSteps.map((s) => ({ ...s, dosage: s.dosage || dosage }));
    if (steps.some((s) => !s.dosage.trim())) { setError('Select a dosage for every step of the tapering schedule.'); return; }
    setAdding(true);
    const result = await addPostProcedureTaperedMedicine(procedureId, { drugName: drug, eye: isOcular ? eye : 'Oral', steps });
    setAdding(false);
    if (result.error) { setError(result.error); return; }
    setDrug(''); setDosage(''); setDrugTypeId(null); setIsOcular(true); setShowTaperBuilder(false);
    setTaperSteps([{ frequency: 'OD', duration: '1 week', dosage: '' }]);
    refresh();
  }

  async function handleRemove(id) {
    await removePostProcedureMedicine(id);
    refresh();
  }

  async function handleRemoveTaperGroup(groupId) {
    await removePostProcedureTaperGroup(groupId);
    refresh();
  }

  const dosageOptions = drugTypeId ? catalog.dosages.filter((o) => o.drug_type_id === drugTypeId) : [];
  const grouped = groupPrescriptions(prescriptions);

  return (
    <div style={{ marginTop: 14, paddingTop: 14, borderTop: '1px solid var(--g100)' }}>
      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 8 }}>Medicines</div>
      {error && <div style={{ color: 'var(--red)', fontSize: 12, marginBottom: 8 }}>{error}</div>}
      {loading ? <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div> : (
        <>
          {grouped.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 8 }}>No medicines added yet.</div>}
          {grouped.map((g) => (
            <div key={g.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0', fontSize: 12.5 }}>
              <span style={{ flex: 1 }}><MedicineLine g={g} /></span>
              <button className="btn" style={{ fontSize: 10, padding: '2px 6px' }} onClick={() => (g.isTaper ? handleRemoveTaperGroup(g.id) : handleRemove(g.id))}><i className="ti ti-x"></i></button>
            </div>
          ))}

          {!showTaperBuilder ? (
            <>
              <div style={{ display: 'flex', gap: 6, marginTop: 8, flexWrap: 'wrap', alignItems: 'flex-start' }}>
                <div style={{ position: 'relative', flex: '2 1 160px' }}>
                  <input
                    className="fi fi-sm" placeholder="Type to search medicines..."
                    value={drug}
                    onChange={(e) => { setDrug(e.target.value); setDrugTypeId(null); setIsOcular(true); setShowSuggestions(true); }}
                    onFocus={() => setShowSuggestions(true)}
                    onBlur={() => setTimeout(() => setShowSuggestions(false), 150)}
                    style={{ width: '100%' }}
                  />
                  {showSuggestions && drug.trim().length > 0 && suggestions.length > 0 && (
                    <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, zIndex: 20, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 6px 16px rgba(0,0,0,.12)', maxHeight: 200, overflowY: 'auto', marginTop: 3 }}>
                      {suggestions.map((d) => (
                        <div key={d.id} onMouseDown={() => selectDrug(d)} style={{ padding: '6px 10px', cursor: 'pointer', fontSize: 12 }}>
                          <strong>{d.brand}</strong>{d.generic ? ` (${d.generic})` : ''}
                        </div>
                      ))}
                    </div>
                  )}
                </div>
                <select className="fi fi-sm" value={dosage} onChange={(e) => setDosage(e.target.value)} style={{ flex: '1 1 80px' }}>
                  <option value="">-- Dosage --</option>
                  {dosageOptions.map((o) => <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>)}
                  {dosageOptions.length === 0 && <><option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option></>}
                </select>
                <select className="fi fi-sm" value={frequency} onChange={(e) => setFrequency(e.target.value)} style={{ flex: '1 1 70px' }}>
                  <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                </select>
                <select className="fi fi-sm" value={duration} onChange={(e) => setDuration(e.target.value)} style={{ flex: '1 1 90px' }}>
                  <option>1 day</option><option>2 days</option><option>3 days</option><option>5 days</option>
                  <option>1 week</option><option>2 weeks</option><option>10 days</option>
                  <option>1 month</option><option>2 months</option><option>3 months</option>
                  <option>Ongoing</option>
                </select>
                {isOcular ? (
                  <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)} style={{ width: 90 }}>
                    <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
                  </select>
                ) : (
                  <div className="fi fi-sm" style={{ width: 90, display: 'flex', alignItems: 'center', justifyContent: 'center', color: 'var(--g500)' }}>Oral</div>
                )}
                <button className="btn btn-primary" style={{ fontSize: 12 }} disabled={adding} onClick={handleAdd}>Add</button>
              </div>
              <button
                className="btn" style={{ fontSize: 11.5, color: 'var(--purple)', marginTop: 8 }}
                onClick={() => { setShowTaperBuilder(true); setTaperSteps((prev) => prev.map((s) => ({ ...s, dosage: s.dosage || dosage }))); }}
              >
                <i className="ti ti-chart-line"></i> Add as Tapering Schedule instead
              </button>
            </>
          ) : (
            <div style={{ marginTop: 8, padding: 10, background: 'var(--g50)', borderRadius: 8 }}>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 6 }}>
                Tapering Schedule -- uses the Drug{isOcular ? ' & Eye' : ''} entered above; dosage defaults to what&apos;s set above but can vary per step, alongside frequency and duration
              </div>
              {taperSteps.map((s, i) => (
                <div key={i} style={{ display: 'flex', gap: 6, marginBottom: 4, alignItems: 'center' }}>
                  <span style={{ fontSize: 11, width: 16, color: 'var(--g500)' }}>{i + 1}.</span>
                  <select className="fi fi-sm" value={s.dosage} onChange={(e) => updateTaperStep(i, 'dosage', e.target.value)} style={{ flex: '1 1 80px' }}>
                    <option value="">-- Dosage --</option>
                    {dosageOptions.map((o) => <option key={o.id} value={o.dosage_text}>{o.dosage_text}</option>)}
                    {dosageOptions.length === 0 && <><option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option></>}
                  </select>
                  <select className="fi fi-sm" value={s.frequency} onChange={(e) => updateTaperStep(i, 'frequency', e.target.value)} style={{ flex: '1 1 70px' }}>
                    <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
                  </select>
                  <select className="fi fi-sm" value={s.duration} onChange={(e) => updateTaperStep(i, 'duration', e.target.value)} style={{ flex: '1 1 90px' }}>
                    <option>1 day</option><option>2 days</option><option>3 days</option><option>5 days</option>
                    <option>1 week</option><option>2 weeks</option><option>10 days</option>
                    <option>1 month</option><option>2 months</option><option>3 months</option>
                  </select>
                  {taperSteps.length > 1 && <button className="btn" style={{ fontSize: 10, padding: '2px 6px' }} onClick={() => removeTaperStep(i)}><i className="ti ti-x"></i></button>}
                </div>
              ))}
              <div style={{ display: 'flex', gap: 8, marginTop: 6 }}>
                <button className="btn" style={{ fontSize: 11 }} onClick={addTaperStep}><i className="ti ti-plus"></i> Add Step</button>
                <button className="btn btn-primary" style={{ fontSize: 12 }} disabled={adding} onClick={handleAddTaper}>Save Tapering Schedule</button>
                <button className="btn" style={{ fontSize: 12 }} onClick={() => setShowTaperBuilder(false)}>Cancel</button>
              </div>
            </div>
          )}
        </>
      )}
    </div>
  );
}

function CompletedSummary({ c, onEdit }) {
  const [medicines, setMedicines] = useState([]);
  const [medsLoading, setMedsLoading] = useState(true);

  useEffect(() => {
    if (c.status !== 'Completed') return;
    getPostProcedurePrescriptions(c.id).then((r) => { setMedicines(r.prescriptions); setMedsLoading(false); });
  }, [c.id, c.status]);

  if (c.status !== 'Completed') return null;
  const isToday = c.completed_at && c.completed_at.slice(0, 10) === todayISO();
  const grouped = groupPrescriptions(medicines);

  return (
    <div style={{ fontSize: 13, lineHeight: 1.7, background: 'var(--g50)', borderRadius: 8, padding: 12 }}>
      <div><strong>Procedure Performed:</strong> {c.procedure_performed || '--'}</div>
      <div><strong>Findings:</strong> {c.findings || '--'}</div>
      <div><strong>Instructions:</strong> {c.post_procedure_instructions || '--'}</div>
      <div style={{ marginTop: 4 }}>
        <strong>Medicines:</strong>{' '}
        {medsLoading ? <span style={{ color: 'var(--g400)' }}>Loading...</span> : grouped.length === 0 ? <span style={{ color: 'var(--g400)' }}>None prescribed.</span> : (
          <ul style={{ margin: '4px 0 0 18px', padding: 0 }}>
            {grouped.map((g) => <li key={g.id} style={{ fontSize: 12.5 }}><MedicineLine g={g} /></li>)}
          </ul>
        )}
      </div>
      <div style={{ color: 'var(--g400)', fontSize: 11, marginTop: 6 }}>Completed {c.completed_at ? new Date(c.completed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : ''}</div>
      <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap' }}>
        <button
          className="btn btn-sm" style={{ background: 'var(--teal, #0d9488)', color: '#fff', border: 'none' }}
          onClick={() => openTab(`/opd-procedure-summary-print/${c.id}`, `procedure-summary-${c.id}`)}
        >
          <i className="ti ti-printer"></i> Print Procedure Summary
        </button>
        {isToday && (
          <button className="btn btn-sm" onClick={onEdit}>
            <i className="ti ti-edit"></i> Edit
          </button>
        )}
      </div>
      {!isToday && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>Editing is only available on the day a procedure is completed.</div>}
    </div>
  );
}

function JourneyCard({ p, patient, expanded, onToggle, onAction, busy, error }) {
  const s = stageFor(p);
  const isTerminal = p.status === 'Completed' || p.status === 'Done' || p.status === 'Cancelled' || p.decision === 'Declined';

  const decisionDone = !!p.decision;
  const scheduleDone = ['Scheduled', 'Checked In', 'Completed'].includes(p.status);
  const paymentDone = p.advanceBalance > 0;
  const checkinDone = ['Checked In', 'Completed'].includes(p.status);
  const completeDone = p.status === 'Completed';

  // Decision and Procedure Date are independent of each other now (a
  // date can be given before the patient has formally decided), so
  // each gets its own "next step" activation instead of one shared
  // sequential pointer. Payment -> Check-in -> Complete stay strictly
  // sequential, gated on the step before them.
  const decisionActive = p.decision !== 'Accepted';
  const scheduleActive = !scheduleDone;
  const paymentActive = scheduleDone && !paymentDone;
  const checkinActive = paymentDone && !checkinDone;
  const completeActive = checkinDone && !completeDone;

  return (
    <div className="card" style={{ marginBottom: 14, padding: 0, overflow: 'hidden' }}>
      <div
        style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', cursor: 'pointer', padding: '14px 16px', background: 'var(--indigo)', color: '#fff' }}
        onClick={onToggle}
      >
        <div>
          <div style={{ fontWeight: 700, fontSize: 14 }}>{p.name} {p.eye ? `(${p.eye})` : ''}</div>
          <div style={{ fontSize: 11, opacity: 0.8, marginTop: 2 }}>
            Advised {fmtDate(p.created_at?.slice(0, 10))}
            {p.scheduled_date ? ` -- procedure date ${fmtDate(p.scheduled_date)}` : ''}
          </div>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff', fontWeight: 600 }}>{s.label}</span>
          <i className={`ti ${expanded ? 'ti-chevron-up' : 'ti-chevron-down'}`}></i>
        </div>
      </div>

      {expanded && (
        <div style={{ padding: 16 }}>
          {error && (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--red-lt, #fee2e2)', color: 'var(--red)', fontWeight: 700, fontSize: 13.5, padding: '10px 14px', borderRadius: 8, marginBottom: 12, border: '1px solid var(--red)' }}>
              <i className="ti ti-alert-triangle" style={{ fontSize: 16, flexShrink: 0 }}></i> {error}
            </div>
          )}
          {p.notes && <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}><strong>Doctor&apos;s note:</strong> {p.notes}</div>}

          {isTerminal ? (
            p.status === 'Completed' ? (
              p._editing ? (
                <CompletePanel c={p} busy={busy} editMode onSave={(fields) => onAction('editComplete', p, fields)} onCancelEdit={() => onAction('toggleEdit', p)} />
              ) : (
                <CompletedSummary c={p} onEdit={() => onAction('toggleEdit', p)} />
              )
            ) : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>
                {p.status === 'Cancelled' && 'This procedure was cancelled.'}
                {p.decision === 'Declined' && p.status !== 'Cancelled' && `Patient declined${p.decision_reason ? ` -- ${p.decision_reason}` : ''}.`}
                {p.status === 'Done' && 'Performed same-sitting and billed -- no further workflow needed.'}
              </div>
            )
          ) : (
            <>
              <Section num={1} color="var(--indigo)" title="Patient Decision" done={p.decision === 'Accepted'} active={decisionActive}>
                <DecisionPanel c={p} busy={busy} onSave={(decision, reason) => onAction('decision', p, decision, reason)} />
              </Section>

              <Section num={2} color="var(--blue)" title="Procedure Date" done={scheduleDone} active={scheduleActive}>
                {p._rescheduling || !scheduleDone ? (
                  <SchedulePanel c={p} busy={busy} onSave={(date, time) => onAction('schedule', p, date, time)} onCancel={() => onAction('cancel', p)} />
                ) : (
                  <div>
                    <div style={{ fontSize: 13, marginBottom: 8 }}>Scheduled for <strong>{fmtDate(p.scheduled_date)}</strong>{p.scheduled_time ? ` at ${p.scheduled_time.slice(0, 5)}` : ''}.</div>
                    {!checkinDone && <button className="btn" style={{ fontSize: 12 }} onClick={() => onAction('toggleReschedule', p)}><i className="ti ti-calendar-time"></i> Reschedule</button>}
                  </div>
                )}
              </Section>

              <Section num={3} color="var(--teal, #0d9488)" title="Advance Payment" done={paymentDone} active={paymentActive}>
                {!scheduleDone ? <LockedNote text="Confirm the procedure date first." /> : <PaymentPanel c={p} patient={patient} />}
              </Section>

              <Section num={4} color="var(--purple)" title="Patient Check-In" done={checkinDone} active={checkinActive}>
                {!paymentDone ? <LockedNote text="Advance payment must be collected first." /> : checkinDone ? (
                  <div style={{ fontSize: 12.5, color: 'var(--green)' }}><i className="ti ti-check"></i> Checked in {p.checked_in_at ? new Date(p.checked_in_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata' }) : ''}.</div>
                ) : (
                  <CheckinPanel c={p} busy={busy} onCheckIn={() => onAction('checkin', p)} onCancel={() => onAction('cancel', p)} onReschedule={() => onAction('toggleReschedule', p)} />
                )}
              </Section>

              <Section num={5} color="var(--green)" title="Post-Procedure Notes" done={completeDone} active={completeActive}>
                {!checkinDone ? <LockedNote text="Patient must be checked in first." /> : (
                  <CompletePanel c={p} busy={busy} onSave={(fields) => onAction('complete', p, fields)} />
                )}
              </Section>
            </>
          )}
        </div>
      )}
    </div>
  );
}

function PatientHeader({ patient }) {
  return (
    <div className="card" style={{ display: 'flex', alignItems: 'center', gap: 14, marginBottom: 16, padding: '14px 18px' }}>
      <div style={{ width: 44, height: 44, borderRadius: '50%', background: 'var(--red-lt, #fee2e2)', color: 'var(--red)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontWeight: 700, fontSize: 16, flexShrink: 0 }}>
        {patient.first_name?.[0]}{patient.last_name?.[0]}
      </div>
      <div style={{ flex: 1 }}>
        <div style={{ fontSize: 16, fontWeight: 700 }}>{formatPatientName(patient)}</div>
        <div style={{ fontSize: 12, color: 'var(--g400)' }}>{patient.uhid} -- {patient.mobile}</div>
      </div>
    </div>
  );
}

// ── Per-patient OPD Procedures workspace, at its own route
// (/opd-procedures/[patientId]) exactly like Surgical Journey's
// per-case workspace at /surgical-journey/[id] -- so opening a patient
// is a real navigable page (openable in a new browser tab like any
// other link) rather than an in-place expand, with a matching
// "All Cases" link back to the search/landing page.
export default function Workspace({ patientId }) {
  const router = useRouter();
  const [patient, setPatient] = useState(null);
  const [journey, setJourney] = useState([]);
  const [loading, setLoading] = useState(true);
  const [expandedId, setExpandedId] = useState(null);
  const [busyId, setBusyId] = useState(null);
  const [rowError, setRowError] = useState({});
  const [reschedulingId, setReschedulingId] = useState(null);
  const [editingId, setEditingId] = useState(null);

  const refresh = useCallback(async () => {
    const [patientData, journeyData] = await Promise.all([getPatientById(patientId), getPatientOpdProcedureJourney(patientId)]);
    setPatient(patientData);
    setJourney(journeyData);
    return journeyData;
  }, [patientId]);

  useEffect(() => {
    (async () => {
      setLoading(true);
      const data = await refresh();
      const priority = data.find((x) => !['Completed', 'Done', 'Cancelled'].includes(x.status) && x.decision !== 'Declined');
      setExpandedId(priority?.id || data[0]?.id || null);
      setLoading(false);
    })();
  }, [refresh]);

  async function handleAction(type, p, ...args) {
    setRowError((e) => ({ ...e, [p.id]: '' }));
    if (type === 'toggleReschedule') {
      setReschedulingId((cur) => (cur === p.id ? null : p.id));
      return;
    }
    if (type === 'toggleEdit') {
      setEditingId((cur) => (cur === p.id ? null : p.id));
      return;
    }
    setBusyId(p.id);
    let result;
    if (type === 'decision') result = await setOpdProcedureDecision(p.id, args[0], args[1]);
    if (type === 'schedule') { result = await scheduleOpdProcedure(p.id, args[0], args[1]); setReschedulingId(null); }
    if (type === 'checkin') result = await checkInOpdProcedure(p.id);
    if (type === 'complete') result = await completeOpdProcedure(p.id, args[0]);
    if (type === 'editComplete') { result = await updateCompletedProcedureNotes(p.id, args[0]); if (!result?.error) setEditingId(null); }
    if (type === 'cancel') result = await cancelOpdProcedure(p.id, 'Cancelled from patient journey view');
    setBusyId(null);
    if (result?.error) { setRowError((e) => ({ ...e, [p.id]: result.error })); return; }
    refresh();
  }

  if (loading) return <div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading patient journey...</div>;
  if (!patient) return <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Patient not found.</div>;

  return (
    <div>
      <button className="btn btn-sm" style={{ marginBottom: 12 }} onClick={() => router.push('/opd-procedures')}>
        <i className="ti ti-arrow-left"></i> All Cases
      </button>

      <PatientHeader patient={patient} />

      {journey.length === 0 && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No OPD Procedures on file for this patient yet.</div>
      )}
      {journey.map((p) => (
        <JourneyCard
          key={p.id}
          p={{ ...p, _rescheduling: reschedulingId === p.id, _editing: editingId === p.id }}
          patient={patient}
          expanded={expandedId === p.id}
          onToggle={() => setExpandedId((cur) => (cur === p.id ? null : p.id))}
          onAction={handleAction}
          busy={busyId === p.id}
          error={rowError[p.id]}
        />
      ))}
    </div>
  );
}
