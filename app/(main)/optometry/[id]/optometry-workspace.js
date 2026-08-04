'use client';

import { useState, useEffect, useRef, Fragment } from 'react';
import { useRouter } from 'next/navigation';
import {
  getAssessmentWorkspaceData,
  saveDraft,
  completeAssessment,
  updateCompletedAssessment,
  addIopReading,
} from '@/app/(main)/optometry/actions';
import { getIopMethods } from '@/app/(main)/master-data/actions';
import { forceCloseQueueEntry } from '@/app/(main)/queue/actions';
import HistoryTab from '@/app/consultation/[id]/history-tab';
import { openPrintPopup } from '@/lib/printPopup';

// "P" = partial line read -- standard Snellen convention, one P variant
// per line from 6/6 through 6/60 (worse lines below 6/60 -- 3/60, 2/60,
// 1/60 -- don't get a P variant).
const VA_SNELLEN = [
  '6/6', '6/6P', '6/9', '6/9P', '6/12', '6/12P', '6/18', '6/18P', '6/24', '6/24P',
  '6/36', '6/36P', '6/60', '6/60P', '3/60', '2/60', '1/60',
];
const VA_SPECIAL = ['FC@1m', 'FC@2m', 'FC@3m', 'HM', 'PL+', 'PL-', 'NPL'];

// Near vision uses its own fixed N-notation scale -- independent of the
// Snellen/LogMAR/ETDRS distance scale toggle. This is a closed list (no
// custom entry), unlike Distance.
const VA_NEAR = ['N4', 'N5', 'N6', 'N8', 'N10', 'N12', 'N18', 'N24', 'N36', '<N36'];

// SPH/CYL magnitude picker grid: 0.25 steps from 0.25 to 20.00, then a
// final row for the less-common high-power values (20.25 - 30.0).
const SPH_CYL_MAGNITUDES = [];
for (let v = 0.25; v <= 20; v += 0.25) SPH_CYL_MAGNITUDES.push(v.toFixed(2).replace(/0$/, ''));
SPH_CYL_MAGNITUDES.push('20.25', '20.5', '20.75', '30.0');

// AXIS picker grid: 0 - 180 in steps of 5.
const AXIS_VALUES = [];
for (let v = 0; v <= 180; v += 5) AXIS_VALUES.push(String(v));

const REF_TYPES = { obj: 'Objective (Auto-Rx)', subj: 'Subjective', final: 'Final Rx' };

function refKey(type, eye, distNear, metric) {
  return `ref_${type}_${eye}_${distNear}_${metric}`;
}
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

// Rows x eyes for the Visual Acuity table. "With PH" (pinhole) is
// Distance-only, per standard clinical practice -- no Near column for it.
const VA_ROWS = [
  { row: 'unaided', label: 'Unaided', dist: true, near: true },
  { row: 'glasses', label: 'With Existing Glass', dist: true, near: true },
  { row: 'ph', label: 'With PH', dist: true, near: false },
];
function vaKey(eye, distNear, row) {
  return `${eye}_${distNear}_${row}`;
}

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen', va_not_assessed: false,
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1_re: '', add_k1_le: '', add_k2_re: '', add_k2_le: '', add_axial_length_re: '', add_axial_length_le: '',
    add_pachymetry_re: '', add_pachymetry_le: '', add_schirmer_re: '', add_schirmer_le: '',
    add_color_vision_re: '', add_color_vision_le: '', add_syringing_re: '', add_syringing_le: '',
    section_va_done: false, section_refraction_done: false, section_iop_done: false, section_additional_done: false,
  };
  ['re', 'le'].forEach((eye) => {
    VA_ROWS.forEach(({ row, dist, near }) => {
      if (dist) f[vaKey(eye, 'dist', row)] = '';
      if (near) f[vaKey(eye, 'near', row)] = '';
    });
  });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['dist', 'near'].forEach((dn) => {
        ['va', 'sph', 'cyl', 'axis'].forEach((m) => { f[refKey(type, eye, dn, m)] = ''; });
      });
    });
    f[`ref_${type}_copy_re_to_le`] = false;
  });
  return f;
}

// Button-styled stand-in for a text input, whose value is set via the
// SPH/CYL/AXIS pop-up picker rather than typed directly.
function PickerField({ value, onClick, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      className="fi fi-sm"
      style={{ textAlign: 'center', cursor: disabled ? 'default' : 'pointer', background: disabled ? 'var(--g50)' : '#fff', color: value ? 'var(--g800)' : 'var(--g400)', fontWeight: value ? 600 : 400 }}
    >
      {value || '--'}
    </button>
  );
}

// SPH/CYL magnitude + sign picker, or AXIS picker, depending on picker.kind.
function ValuePickerModal({ picker, currentValue, onSelect, onClose }) {
  const isAxis = picker.kind === 'axis';
  const [negative, setNegative] = useState(!String(currentValue || '').trim().startsWith('+'));

  return (
    <div onClick={onClose} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
      <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 16, maxWidth: 480, width: '100%', maxHeight: '80vh', overflowY: 'auto', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>{picker.label}</div>
          <button type="button" className="btn btn-sm" onClick={onClose}><i className="ti ti-x"></i></button>
        </div>

        {!isAxis && (
          <>
            <div style={{ display: 'flex', gap: 6, marginBottom: 12 }}>
              <div
                onClick={() => setNegative(false)}
                style={{ flex: 1, textAlign: 'center', padding: '6px 0', borderRadius: 8, fontSize: 12, fontWeight: 700, cursor: 'pointer', border: `1.5px solid ${!negative ? 'var(--teal)' : 'var(--g200)'}`, background: !negative ? 'var(--teal)' : '#fff', color: !negative ? '#fff' : 'var(--g600)' }}
              >
                +ve
              </div>
              <div
                onClick={() => setNegative(true)}
                style={{ flex: 1, textAlign: 'center', padding: '6px 0', borderRadius: 8, fontSize: 12, fontWeight: 700, cursor: 'pointer', border: `1.5px solid ${negative ? 'var(--red)' : 'var(--g200)'}`, background: negative ? 'var(--red)' : '#fff', color: negative ? '#fff' : 'var(--g600)' }}
              >
                -ve
              </div>
            </div>
            <div
              onClick={() => { onSelect('0.00'); onClose(); }}
              style={{ marginBottom: 10, padding: '6px 10px', borderRadius: 8, fontSize: 12, fontWeight: 600, textAlign: 'center', cursor: 'pointer', border: '1.5px dashed var(--g300)', color: 'var(--g600)' }}
            >
              Plano (0.00)
            </div>
          </>
        )}

        <div style={{ display: 'grid', gridTemplateColumns: isAxis ? 'repeat(4, 1fr)' : 'repeat(5, 1fr)', gap: 6 }}>
          {(isAxis ? AXIS_VALUES : SPH_CYL_MAGNITUDES).map((v) => (
            <div
              key={v}
              onClick={() => { onSelect(isAxis ? v : `${negative ? '-' : '+'}${v}`); onClose(); }}
              style={{ textAlign: 'center', padding: '8px 4px', borderRadius: 8, fontSize: 12, fontWeight: 600, cursor: 'pointer', background: 'var(--g50)', border: '1px solid var(--g200)', color: 'var(--g700)' }}
            >
              {v}
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}

function AsmtSection({ id, num, color, title, badge, badgeCls, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
          <span className={`badge ${badgeCls}`}>{badge}</span>
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}


export default function OptometryWorkspace({ queueEntryId, embedded = false }) {
  const [entry, setEntry] = useState(null);
  const [assessment, setAssessment] = useState(null);
  const [encounter, setEncounter] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ history: true, va: true, refraction: false, iop: false, additional: false });
  const [refTab, setRefTab] = useState('obj');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');
  const [picker, setPicker] = useState(null); // { kind: 'sphcyl'|'axis', fieldKey }
  const [showRefInstructions, setShowRefInstructions] = useState(false);

  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [showForceClose, setShowForceClose] = useState(false);
  const [forceCloseReason, setForceCloseReason] = useState('');
  const [forceClosing, setForceClosing] = useState(false);
  const [iopMethods, setIopMethods] = useState([]);
  const router = useRouter();

  // 'idle' | 'pending' | 'saving' | 'saved' | 'error'
  const [autosaveState, setAutosaveState] = useState('idle');
  const autosaveTimer = useRef(null);
  const skipNextAutosave = useRef(true);

  function load() {
    getAssessmentWorkspaceData(queueEntryId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setEntry(result.entry);
      setAssessment(result.assessment);
      setEncounter(result.encounter);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setLocked(result.locked);

      const f = emptyForm();
      Object.keys(f).forEach((key) => {
        if (result.assessment[key] !== null && result.assessment[key] !== undefined) f[key] = result.assessment[key];
      });
      // Loading data (initial open, or a reload after a manual save)
      // sets the form too -- skip the very next autosave tick so that
      // doesn't get mistaken for a real edit.
      skipNextAutosave.current = true;
      setForm(f);
    });
  }

  useEffect(() => { load(); }, [queueEntryId]);

  useEffect(() => {
    getIopMethods().then((all) => setIopMethods(all.filter((m) => m.status === 'Active')));
  }, []);

  const isEdit = assessment?.status === 'Completed';

  // Autosaves the whole assessment ~1.2s after the last edit, in both
  // the Optometry module and embedded inside the Doctor module -- same
  // debounced pattern as the Examination tab, so nothing is lost if the
  // user navigates away without pressing Save Draft / Save Changes.
  useEffect(() => {
    if (!assessment || locked) return;
    if (skipNextAutosave.current) { skipNextAutosave.current = false; return; }

    setAutosaveState('pending');
    if (autosaveTimer.current) clearTimeout(autosaveTimer.current);
    const assessmentIdAtSchedule = assessment.id;

    autosaveTimer.current = setTimeout(async () => {
      setAutosaveState('saving');
      const saveFn = isEdit ? updateCompletedAssessment : saveDraft;
      const result = await saveFn(assessmentIdAtSchedule, form);
      setAutosaveState(result.error ? 'error' : 'saved');
    }, 1200);

    return () => clearTimeout(autosaveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [form]);

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function setAdditional(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_additional_done: true }));
  }

  function setVa(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_va_done: true }));
  }

  function setVaNotAssessed(checked) {
    setForm((prev) => ({ ...prev, va_not_assessed: checked, section_va_done: true }));
  }

  function setRef(type, eye, distNear, metric, value) {
    setForm((prev) => {
      const next = { ...prev, [refKey(type, eye, distNear, metric)]: value, section_refraction_done: true };
      // Keep LE mirroring RE live while "Copy RE Value to LE" is on for this refraction type.
      if (eye === 're' && prev[`ref_${type}_copy_re_to_le`]) {
        next[refKey(type, 'le', distNear, metric)] = value;
      }
      return next;
    });
  }

  function toggleCopyToLE(type, checked) {
    setForm((prev) => {
      const next = { ...prev, [`ref_${type}_copy_re_to_le`]: checked };
      if (checked) {
        ['dist', 'near'].forEach((dn) => {
          ['va', 'sph', 'cyl', 'axis'].forEach((m) => {
            next[refKey(type, 'le', dn, m)] = prev[refKey(type, 're', dn, m)];
          });
        });
      }
      return next;
    });
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value) return;
    const result = await addIopReading(assessment.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setForm((prev) => ({ ...prev, section_iop_done: true }));
    // Append the new reading locally rather than calling load() -- a
    // full reload would overwrite any not-yet-saved edits sitting in
    // other sections (VA, refraction, additional measurements) with
    // whatever's still on the server, silently discarding them.
    setIopReadings((prev) => [...prev, result.reading]);
  }

  async function handleSaveDraft() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await saveDraft(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in Optometry Queue.');
    load();
  }

  async function handleComplete() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await completeAssessment(assessment.id, queueEntryId, form);
    setSaving(false);
    if (result.error) {
      setError(result.error);
      if (!openSections.va) toggleSection('va');
      return;
    }
    setOkMsg('Assessment completed -- routed to Doctor Queue.');
    setTimeout(() => router.push('/optometry-dashboard'), 1200);
  }

  // Escape hatch for a visit that can't reach the Visual Acuity
  // requirement above (patient left before being seen, etc). Doesn't
  // bypass VAL-OPT-002 for anyone else -- just closes this one entry
  // with a reason on record.
  async function handleForceClose() {
    setError('');
    if (!forceCloseReason.trim()) { setError('A reason is required to close this visit without a VA measurement.'); return; }
    setForceClosing(true);
    const result = await forceCloseQueueEntry(queueEntryId, forceCloseReason);
    setForceClosing(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Visit closed.');
    setTimeout(() => router.push('/optometry-dashboard'), 1000);
  }

  async function handleUpdate() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateCompletedAssessment(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Changes saved.');
    load();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!entry || !assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = entry.visits?.patients;
  const doneCount = ['section_va_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done'].filter((k) => form[k]).length;
  const vaScaleValues = vaValuesForScale(form.va_scale);

  const reIopSorted = iopReadings.filter((r) => r.eye === 'RE');
  const leIopSorted = iopReadings.filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  return (
    <div>
      {/* PATIENT STRIP */}
      {!embedded && (
        <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
          <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
            {patient?.first_name?.charAt(0) || '?'}
          </div>
          <div>
            <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
            <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
            <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
              <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>Token {entry.token}</span>
            </div>
          </div>
        </div>
      )}

      {/* WORKFLOW PANEL */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#5eead4', boxShadow: '0 0 6px #5eead4', flexShrink: 0 }}></div>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#5eead4' }}>
          {locked ? (embedded ? 'Locked -- Visit Closed' : 'Locked -- Doctor Reviewing') : isEdit ? 'Assessment Completed -- Editable' : 'Optometry -- In Progress'}
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 10, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.4px' }}>Assessment progress</div>
            <div style={{ fontSize: 13, fontWeight: 700, color: '#e2e8f0' }}>{doneCount} / 4 sections</div>
            <div style={{ height: 6, borderRadius: 3, background: 'var(--g200)', width: 160, marginTop: 4, overflow: 'hidden' }}>
              <div style={{ height: '100%', borderRadius: 3, background: 'var(--teal)', width: `${(doneCount / 4) * 100}%`, transition: 'width .3s' }}></div>
            </div>
          </div>
          {!locked && (
            <div style={{ fontSize: 10.5, color: autosaveState === 'error' ? '#fca5a5' : '#64748b', display: 'flex', alignItems: 'center', gap: 4 }}>
              {autosaveState === 'pending' && <>Unsaved changes...</>}
              {autosaveState === 'saving' && <><i className="ti ti-loader-2"></i> Saving...</>}
              {autosaveState === 'saved' && <><i className="ti ti-cloud-check"></i> All changes saved</>}
              {autosaveState === 'error' && <><i className="ti ti-alert-triangle"></i> Autosave failed -- use Save button</>}
            </div>
          )}
          {!locked && (
            <div style={{ display: 'flex', gap: 6 }}>
              {!isEdit && (
                <>
                  <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.1)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSaveDraft} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> Save Draft
                  </button>
                  <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleComplete} disabled={saving}>
                    <i className="ti ti-circle-check"></i> Complete Assessment
                  </button>
                </>
              )}
              {isEdit && (
                <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleUpdate} disabled={saving}>
                  <i className="ti ti-device-floppy"></i> Save Changes
                </button>
              )}
            </div>
          )}
        </div>
      </div>

      {locked && (
        <div className="msg-err" style={{ marginBottom: 12 }}>
          <i className="ti ti-lock"></i> {embedded ? 'This visit is closed. Shown here for reference only -- no further edits.' : 'The doctor has already started this consultation. Shown here for reference only -- no further edits.'}
        </div>
      )}
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* Escape hatch -- for a visit that can't reach the VA requirement
          above (patient left, no-show after being called, etc). Kept
          visually separate from the main actions so it isn't a tempting
          shortcut for normal visits. */}
      {!locked && !isEdit && (
        <div style={{ marginBottom: 12 }}>
          {!showForceClose ? (
            <button className="btn btn-sm" style={{ fontSize: 11.5, background: 'rgba(255,255,255,.06)', color: '#94a3b8', borderColor: 'rgba(255,255,255,.15)' }} onClick={() => setShowForceClose(true)}>
              <i className="ti ti-player-skip-forward"></i> Unable to Complete This Visit
            </button>
          ) : (
            <div style={{ background: 'rgba(255,255,255,.05)', border: '1px solid rgba(255,255,255,.15)', borderRadius: 8, padding: 10 }}>
              <label className="flbl" style={{ color: '#cbd5e1' }}>Why can&apos;t this visit be completed normally? *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi fi-sm" value={forceCloseReason} onChange={(e) => setForceCloseReason(e.target.value)} placeholder="e.g. Patient left before being seen" />
                <button className="btn btn-sm" style={{ background: 'var(--amber)', color: '#fff', borderColor: 'transparent' }} onClick={handleForceClose} disabled={forceClosing}>
                  {forceClosing ? 'Closing...' : 'Confirm'}
                </button>
                <button className="btn btn-sm" onClick={() => { setShowForceClose(false); setForceCloseReason(''); }}>Cancel</button>
              </div>
            </div>
          )}
        </div>
      )}

      {/* PATIENT HISTORY -- same HistoryTab component and encounter
          record the doctor's History tab uses (app/consultation/[id]/history-tab.js,
          table `encounters`). Filling it in here means it's already on
          file by the time the doctor opens the consultation. */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num="H" color="var(--blue)" title="Patient History" badge={locked ? 'Locked' : 'Editable'} badgeCls={locked ? 'b-gray' : 'b-green'}
          open={openSections.history} onToggle={() => toggleSection('history')}
        >
          <fieldset disabled={locked} style={{ border: 'none', margin: 0, padding: 0 }}>
            {encounter && <HistoryTab encounter={encounter} findings={null} onSaved={() => {}} hideOptometryBanner />}
          </fieldset>
        </AsmtSection>
      </div>

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={1} color="var(--teal)" title="Visual Acuity" badge={form.section_va_done ? 'Done' : 'Not started'} badgeCls={form.section_va_done ? 'b-green' : 'b-gray'}
          open={openSections.va} onToggle={() => toggleSection('va')}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => !locked && !form.va_not_assessed && setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: (locked || form.va_not_assessed) ? 'default' : 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>

          <label style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13, fontWeight: 600, color: 'var(--g700)', marginBottom: 12, cursor: locked ? 'default' : 'pointer' }}>
            <input type="checkbox" disabled={locked} checked={form.va_not_assessed} onChange={(e) => setVaNotAssessed(e.target.checked)} />
            None
          </label>

          {!form.va_not_assessed && (
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr>
                    <th style={{ width: 150 }}></th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                      OD (RE)
                    </th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                      OS (LE)
                    </th>
                  </tr>
                  <tr>
                    <th></th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>Dist</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>Near</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: '4px solid #fff' }}>Dist</th>
                    <th style={{ width: '21%', padding: '6px 10px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700 }}>Near</th>
                  </tr>
                </thead>
                <tbody>
                  {VA_ROWS.map(({ row, label, dist, near }) => (
                    <tr key={row} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>{label}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                            {dist ? (
                              <input className="fi fi-sm" list="va-dist-options" disabled={locked} value={form[vaKey(eye, 'dist', row)]} onChange={(e) => setVa(vaKey(eye, 'dist', row), e.target.value)} placeholder="--" />
                            ) : null}
                          </td>
                          <td style={{ padding: '6px 8px' }}>
                            {near ? (
                              <select className="fi fi-sm" disabled={locked} value={form[vaKey(eye, 'near', row)]} onChange={(e) => setVa(vaKey(eye, 'near', row), e.target.value)}>
                                <option value="">--</option>
                                {VA_NEAR.map((v) => <option key={v} value={v}>{v}</option>)}
                              </select>
                            ) : null}
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
          <datalist id="va-dist-options">
            {vaScaleValues.map((v) => <option key={v} value={v} />)}
            {VA_SPECIAL.map((v) => <option key={v} value={v} />)}
          </datalist>
        </AsmtSection>
      </div>
      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={2} color="var(--blue)" title="Refraction" badge={form.section_refraction_done ? 'Done' : 'Not started'} badgeCls={form.section_refraction_done ? 'b-green' : 'b-gray'}
          open={openSections.refraction} onToggle={() => toggleSection('refraction')}
        >
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {Object.entries(REF_TYPES).map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>

          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 10 }}>
            <div style={{ fontSize: 11, color: 'var(--g500)', flex: 1 }}>
              {refTab === 'obj' ? 'Auto-refractometer values. Review before finalizing.' : refTab === 'subj' ? 'Values obtained during subjective refraction with trial lenses.' : 'Final accepted refraction used for prescription / optical order.'}
            </div>
            <button
              type="button"
              className="btn btn-sm"
              style={{ background: 'var(--teal)', color: '#fff', border: 'none', flexShrink: 0 }}
              onClick={() => openPrintPopup(`/glasses-prescription-print/${assessment.id}`)}
            >
              <i className="ti ti-printer"></i> Print Prescription
            </button>
          </div>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 60 }}></th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                    OD (RE)
                  </th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                    OS (LE)
                  </th>
                </tr>
                <tr>
                  <th></th>
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h) => (
                    <th key={`re-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>{h}</th>
                  ))}
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h, i) => (
                    <th key={`le-${h}`} style={{ width: h === 'VA' ? '9%' : '14%', padding: '6px 8px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: i === 0 ? '4px solid #fff' : undefined }}>{h}</th>
                  ))}
                </tr>
              </thead>
              <tbody>
                {['dist', 'near'].map((distNear) => {
                  const leCopying = form[`ref_${refTab}_copy_re_to_le`];
                  return (
                    <tr key={distNear} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)', textTransform: 'capitalize' }}>{distNear === 'dist' ? 'Dist' : 'Near'}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                            {distNear === 'dist' ? (
                              <input className="fi fi-sm" list="va-dist-options" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'va')]} onChange={(e) => setRef(refTab, eye, distNear, 'va', e.target.value)} placeholder="--" />
                            ) : (
                              <select className="fi fi-sm" disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'va')]} onChange={(e) => setRef(refTab, eye, distNear, 'va', e.target.value)}>
                                <option value="">--</option>
                                {VA_NEAR.map((v) => <option key={v} value={v}>{v}</option>)}
                              </select>
                            )}
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'sph')]} onClick={() => setPicker({ kind: 'sphcyl', label: `SPH -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'sph') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'cyl')]} onClick={() => setPicker({ kind: 'sphcyl', label: `CYL -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'cyl') })} />
                          </td>
                          <td style={{ padding: '6px 6px' }}>
                            <PickerField disabled={locked || (eye === 'le' && leCopying)} value={form[refKey(refTab, eye, distNear, 'axis')]} onClick={() => setPicker({ kind: 'axis', label: `AXIS -- ${distNear === 'dist' ? 'Distance' : 'Near'} -- ${eye.toUpperCase()}`, fieldKey: refKey(refTab, eye, distNear, 'axis') })} />
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  );
                })}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>IPD</td>
                  <td colSpan={2} style={{ padding: '6px 6px' }}>
                    <input className="fi fi-sm" disabled={locked} style={{ width: 90 }} value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" />
                  </td>
                  <td colSpan={3} style={{ padding: '6px 6px' }}>
                    <button type="button" className="btn btn-sm" style={{ background: 'var(--indigo, #4338ca)', color: '#fff', border: 'none' }} onClick={() => setShowRefInstructions(true)}>
                      <i className="ti ti-info-circle"></i> Instructions
                    </button>
                  </td>
                  <td colSpan={3} style={{ padding: '6px 6px' }}>
                    <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 12, fontWeight: 600, color: 'var(--g700)', cursor: locked ? 'default' : 'pointer' }}>
                      <input type="checkbox" disabled={locked} checked={!!form[`ref_${refTab}_copy_re_to_le`]} onChange={(e) => toggleCopyToLE(refTab, e.target.checked)} />
                      Copy RE Value to LE
                    </label>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>

          <div style={{ marginTop: 12 }}>
            <label className="flbl">Vertex Distance (optional)</label>
            <input className="fi fi-sm" style={{ maxWidth: 200 }} disabled={locked} value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" />
          </div>

          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginTop: 12 }}>
            <i className="ti ti-info-circle"></i> Device-imported values should be reviewed before finalizing. All 3 refraction types are recorded independently.
          </div>
        </AsmtSection>
      </div>

      {picker && (
        <ValuePickerModal
          picker={picker}
          currentValue={form[picker.fieldKey]}
          onSelect={(v) => {
            const [, type, eye, distNear, metric] = picker.fieldKey.split('_');
            setRef(type, eye, distNear, metric, v);
          }}
          onClose={() => setPicker(null)}
        />
      )}

      {showRefInstructions && (
        <div onClick={() => setShowRefInstructions(false)} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
          <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 18, maxWidth: 440, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
            <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
              <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>Refraction -- Instructions</div>
              <button type="button" className="btn btn-sm" onClick={() => setShowRefInstructions(false)}><i className="ti ti-x"></i></button>
            </div>
            <ul style={{ fontSize: 12, color: 'var(--g600)', paddingLeft: 18, lineHeight: 1.7 }}>
              <li>Record Distance and Near separately for each eye -- tap a field to open the value picker.</li>
              <li>Tap SPH / CYL and choose +ve or -ve before selecting the magnitude.</li>
              <li>Enable &quot;Copy RE Value to LE&quot; only when both eyes genuinely match -- it overwrites LE with RE and keeps them locked together until unchecked.</li>
              <li>IPD (Interpupillary Distance) is recorded once per assessment, not per refraction type.</li>
            </ul>
          </div>
        </div>
      )}

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={3} color="var(--purple)" title="Intraocular Pressure" badge={form.section_iop_done ? 'Done' : 'Not started'} badgeCls={form.section_iop_done ? 'b-green' : 'b-gray'}
          open={openSections.iop} onToggle={() => toggleSection('iop')}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" disabled={locked} value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {iopMethods.map((m) => <option key={m.id}>{m.name}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" disabled={locked} value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIopSorted, reIopInput, setReIopInput], ['LE', leIopSorted, leIopInput, setLeIopInput]].map(([eye, list, val, setVal]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings yet</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
                {!locked && (
                  <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                    <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                    <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                  </div>
                )}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={4} color="var(--amber)" title="Additional Measurements" badge={form.section_additional_done ? 'Done' : 'Not started'} badgeCls={form.section_additional_done ? 'b-green' : 'b-gray'}
          open={openSections.additional} onToggle={() => toggleSection('additional')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 12 }}>Complete only the measurements relevant to this visit -- recorded per eye.</div>
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 150 }}></th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>
                    OD (RE)
                  </th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>
                    OS (LE)
                  </th>
                </tr>
              </thead>
              <tbody>
                {[
                  { key: 'k1', label: 'Keratometry K1', placeholder: 'e.g. 43.50 D' },
                  { key: 'k2', label: 'Keratometry K2', placeholder: 'e.g. 44.25 D' },
                  { key: 'axial_length', label: 'Axial Length', placeholder: 'e.g. 23.2 mm' },
                  { key: 'pachymetry', label: 'Pachymetry (CCT)', placeholder: 'e.g. 542 microns' },
                  { key: 'schirmer', label: 'Schirmer test', placeholder: 'e.g. 8 mm' },
                ].map(({ key, label, placeholder }) => (
                  <tr key={key} style={{ borderTop: '1px solid var(--g100)' }}>
                    <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>{label}</td>
                    <td style={{ padding: '6px 8px' }}>
                      <input className="fi fi-sm" disabled={locked} value={form[`add_${key}_re`]} onChange={(e) => setAdditional(`add_${key}_re`, e.target.value)} placeholder={placeholder} />
                    </td>
                    <td style={{ padding: '6px 8px', borderLeft: '4px solid #fff' }}>
                      <input className="fi fi-sm" disabled={locked} value={form[`add_${key}_le`]} onChange={(e) => setAdditional(`add_${key}_le`, e.target.value)} placeholder={placeholder} />
                    </td>
                  </tr>
                ))}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Color Vision</td>
                  {['re', 'le'].map((eye) => (
                    <td key={eye} style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                      <select className="fi fi-sm" disabled={locked} value={form[`add_color_vision_${eye}`]} onChange={(e) => setAdditional(`add_color_vision_${eye}`, e.target.value)}>
                        <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
                      </select>
                    </td>
                  ))}
                </tr>
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Syringing</td>
                  {['re', 'le'].map((eye) => (
                    <td key={eye} style={{ padding: '6px 8px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}>
                      <select className="fi fi-sm" disabled={locked} value={form[`add_syringing_${eye}`]} onChange={(e) => setAdditional(`add_syringing_${eye}`, e.target.value)}>
                        <option value="">Not done</option><option>Patent</option><option>Blocked</option>
                      </select>
                    </td>
                  ))}
                </tr>
              </tbody>
            </table>
          </div>
        </AsmtSection>
      </div>

      {/* AUDIT LOG */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
        {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
        {auditLog.map((a) => (
          <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8 }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
            <span>{a.message}</span>
          </div>
        ))}
      </div>

      {!embedded && (
        <div style={{ marginTop: 16 }}>
          <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
            <i className="ti ti-arrow-left"></i> Back to Queue
          </button>
        </div>
      )}
    </div>
  );
}



