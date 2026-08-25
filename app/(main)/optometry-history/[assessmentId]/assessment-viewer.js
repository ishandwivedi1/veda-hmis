'use client';

import { useState, useEffect, Fragment } from 'react';
import { useRouter } from 'next/navigation';
import { getAssessmentDetail } from '@/app/(main)/optometry-history/actions';

// Same field-key helpers and row/type layout as the live entry workspace
// (app/(main)/optometry/[id]/optometry-workspace.js) -- kept identical
// on purpose so a completed sheet renders here exactly as the
// optometrist entered it, not as some older/different field layout.
// This viewer was left behind when the workspace's refraction/VA/
// additional-measurements fields were redesigned (dist/near split, ADD,
// Present Glasses section, per-eye Additional Measurements), so it was
// silently showing blank/"--" for data that was actually saved under
// the new field names. Fixed by mirroring the same key scheme here.
function vaKey(eye, distNear, row) {
  return `${eye}_${distNear}_${row}`;
}
function refKey(type, eye, distNear, metric) {
  return `ref_${type}_${eye}_${distNear}_${metric}`;
}
function addKey(type, eye) {
  return `ref_${type}_${eye}_add`;
}

// "With PH" (pinhole) is Distance-only, per standard clinical practice.
const VA_ROWS = [
  { row: 'unaided', label: 'Unaided', dist: true, near: true },
  { row: 'glasses', label: 'With Existing Glass', dist: true, near: true },
  { row: 'ph', label: 'With PH', dist: true, near: false },
];

const REF_TYPES = { pg: 'Present Glasses (PG) Power', obj: 'Objective (Auto-Rx)', subj: 'Subjective', final: 'Final Rx' };

function AsmtSection({ num, color, title, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

// Read-only VA pill -- same visual language as the entry form's
// selectable pills, minus the click handler.
function VaPill({ value }) {
  if (!value) return <span style={{ fontSize: 12, color: 'var(--g400)' }}>--</span>;
  return (
    <div style={{ display: 'inline-block', padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>
      {value}
    </div>
  );
}

// Read-only SPH/CYL/AXIS/VA value box -- same visual language as the
// entry form's PickerField, minus the click handler.
function ValueBox({ value, muted }) {
  return (
    <div className="fi fi-sm" style={{ textAlign: 'center', background: muted ? 'var(--g50)' : '#fff', color: value ? 'var(--g800)' : 'var(--g400)', fontWeight: value ? 600 : 400 }}>
      {value || '--'}
    </div>
  );
}

export default function AssessmentViewer({ assessmentId, onBack }) {
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [overrideCount, setOverrideCount] = useState(0);
  const [isAdmin, setIsAdmin] = useState(false);
  const [loadError, setLoadError] = useState('');
  const [openSections, setOpenSections] = useState({ va: true, pg: true, refraction: true, iop: true, additional: true, obs: true });
  const [refTab, setRefTab] = useState('final');
  const [auditLogOpen, setAuditLogOpen] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getAssessmentDetail(assessmentId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setOverrideCount(result.overrideCount);
      setIsAdmin(!!result.isAdmin);
      // Collapsed by default like every other Audit Log dropdown, but
      // opens itself when there's a flagged doctor override to review
      // -- the banner above points here, so it shouldn't require an
      // extra click to actually see what changed.
      if (result.overrideCount > 0) setAuditLogOpen(true);
    });
  }, [assessmentId]);

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = assessment.visits?.patients;
  const reIop = iopReadings.filter((r) => r.eye === 'RE');
  const leIop = iopReadings.filter((r) => r.eye === 'LE');

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
      <div style={{ background: 'linear-gradient(135deg,#0e6b60,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>
              Visit {assessment.visits?.visit_number || '--'}
            </span>
          </div>
        </div>
      </div>

      {/* LOCK / STATUS BANNER */}
      <div className="msg-err" style={{ marginBottom: 12 }}>
        <i className="ti ti-lock"></i> Historical record -- read only. Current values shown, including any doctor edits.
      </div>
      {overrideCount > 0 && (
        <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-alert-triangle"></i> {isAdmin
            ? <>A doctor has overridden {overrideCount} field{overrideCount > 1 ? 's' : ''} on this record. See the highlighted entries in the Audit Log below for exactly what changed and when.</>
            : <>A doctor has overridden one or more fields on this record.</>}
        </div>
      )}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={1} color="var(--teal)" title={`Visual Acuity (${assessment.va_scale || 'Snellen'})`} open={openSections.va} onToggle={() => toggleSection('va')}>
          {assessment.va_not_assessed ? (
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>Not assessed for this visit.</div>
          ) : (
            <div style={{ overflowX: 'auto' }}>
              <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
                <thead>
                  <tr>
                    <th style={{ width: 150 }}></th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>OD (RE)</th>
                    <th colSpan={2} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>OS (LE)</th>
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
                            {dist ? <VaPill value={assessment[vaKey(eye, 'dist', row)]} /> : null}
                          </td>
                          <td style={{ padding: '6px 8px' }}>
                            {near ? <VaPill value={assessment[vaKey(eye, 'near', row)]} /> : null}
                          </td>
                        </Fragment>
                      ))}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </AsmtSection>
      </div>

      {/* SECTION 2: PRESENT GLASSES (PG) POWER */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={2} color="var(--indigo, #4338ca)" title="Present Glasses (PG) Power" open={openSections.pg} onToggle={() => toggleSection('pg')}>
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 60 }}></th>
                  <th colSpan={3} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>OD (RE)</th>
                  <th colSpan={3} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>OS (LE)</th>
                </tr>
                <tr>
                  <th></th>
                  {['SPH', 'CYL', 'AXIS'].map((h) => <th key={`pg-re-${h}`} style={{ padding: '6px 8px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>{h}</th>)}
                  {['SPH', 'CYL', 'AXIS'].map((h, i) => <th key={`pg-le-${h}`} style={{ padding: '6px 8px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: i === 0 ? '4px solid #fff' : undefined }}>{h}</th>)}
                </tr>
              </thead>
              <tbody>
                {['dist', 'near'].map((distNear) => (
                  <tr key={distNear} style={{ borderTop: '1px solid var(--g100)' }}>
                    <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)', textTransform: 'capitalize' }}>{distNear === 'dist' ? 'Dist' : 'Near'}</td>
                    {['re', 'le'].map((eye) => (
                      <Fragment key={eye}>
                        <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}><ValueBox value={assessment[refKey('pg', eye, distNear, 'sph')]} /></td>
                        <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[refKey('pg', eye, distNear, 'cyl')]} /></td>
                        <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[refKey('pg', eye, distNear, 'axis')]} /></td>
                      </Fragment>
                    ))}
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: REFRACTION -- Objective / Subjective / Final Rx, each
          with Dist / ADD / Near rows, same layout as the live entry form. */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={3} color="var(--blue)" title="Refraction" open={openSections.refraction} onToggle={() => toggleSection('refraction')}>
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {['obj', 'subj', 'final'].map((key) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {REF_TYPES[key]}
              </button>
            ))}
          </div>

          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 60 }}></th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>OD (RE)</th>
                  <th colSpan={4} style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>OS (LE)</th>
                </tr>
                <tr>
                  <th></th>
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h) => <th key={`re-${h}`} style={{ padding: '6px 8px', textAlign: 'left', color: 'var(--blue)', fontWeight: 700 }}>{h}</th>)}
                  {['VA', 'SPH', 'CYL', 'AXIS'].map((h, i) => <th key={`le-${h}`} style={{ padding: '6px 8px', textAlign: 'left', color: 'var(--teal)', fontWeight: 700, borderLeft: i === 0 ? '4px solid #fff' : undefined }}>{h}</th>)}
                </tr>
              </thead>
              <tbody>
                {['dist', 'add', 'near'].map((rowKind) => {
                  if (rowKind === 'add') {
                    return (
                      <tr key="add" style={{ borderTop: '1px solid var(--g100)', background: 'var(--amber-lt, #fffbeb)' }}>
                        <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--amber, #b45309)' }}>ADD</td>
                        {['re', 'le'].map((eye) => (
                          <Fragment key={eye}>
                            <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined, textAlign: 'center', fontSize: 11, color: 'var(--g300)' }}>--</td>
                            <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[addKey(refTab, eye)]} /></td>
                            <td style={{ padding: '6px 6px', textAlign: 'center', fontSize: 11, color: 'var(--g300)' }}>--</td>
                            <td style={{ padding: '6px 6px', textAlign: 'center', fontSize: 11, color: 'var(--g300)' }}>--</td>
                          </Fragment>
                        ))}
                      </tr>
                    );
                  }
                  const distNear = rowKind;
                  const isNear = distNear === 'near';
                  return (
                    <tr key={distNear} style={{ borderTop: '1px solid var(--g100)' }}>
                      <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)', textTransform: 'capitalize' }}>{distNear === 'dist' ? 'Dist' : 'Near'}</td>
                      {['re', 'le'].map((eye) => (
                        <Fragment key={eye}>
                          <td style={{ padding: '6px 6px', borderLeft: eye === 'le' ? '4px solid #fff' : undefined }}><ValueBox value={assessment[refKey(refTab, eye, distNear, 'va')]} /></td>
                          <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[refKey(refTab, eye, distNear, 'sph')]} muted={isNear} /></td>
                          <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[refKey(refTab, eye, distNear, 'cyl')]} muted={isNear} /></td>
                          <td style={{ padding: '6px 6px' }}><ValueBox value={assessment[refKey(refTab, eye, distNear, 'axis')]} muted={isNear} /></td>
                        </Fragment>
                      ))}
                    </tr>
                  );
                })}
              </tbody>
            </table>
          </div>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginTop: 12 }}>
            <div><label className="flbl">IPD</label><div style={{ fontSize: 13 }}>{assessment.ref_pd || '--'}</div></div>
            <div><label className="flbl">Vertex Distance</label><div style={{ fontSize: 13 }}>{assessment.ref_vd || '--'}</div></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={4} color="var(--purple)" title={`Intraocular Pressure (${assessment.iop_method || '--'})`} open={openSections.iop} onToggle={() => toggleSection('iop')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIop], ['LE', leIop]].map(([eye, list]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings recorded</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: ADDITIONAL MEASUREMENTS -- per-eye, matching the
          live entry form (White-to-White and Ocular Motility were
          dropped from the workspace and no longer exist here either). */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={5} color="var(--amber)" title="Additional Measurements" open={openSections.additional} onToggle={() => toggleSection('additional')}>
          <div style={{ overflowX: 'auto' }}>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12 }}>
              <thead>
                <tr>
                  <th style={{ width: 150 }}></th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700 }}>OD (RE)</th>
                  <th style={{ background: 'var(--g200)', color: 'var(--g800)', padding: '6px 10px', textAlign: 'center', fontWeight: 700, borderLeft: '4px solid #fff' }}>OS (LE)</th>
                </tr>
              </thead>
              <tbody>
                {[
                  { key: 'k1', label: 'Keratometry K1' },
                  { key: 'k2', label: 'Keratometry K2' },
                  { key: 'axial_length', label: 'Axial Length' },
                  { key: 'pachymetry', label: 'Pachymetry (CCT)' },
                  { key: 'schirmer', label: 'Schirmer test' },
                ].map(({ key, label }) => (
                  <tr key={key} style={{ borderTop: '1px solid var(--g100)' }}>
                    <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>{label}</td>
                    <td style={{ padding: '6px 8px', textAlign: 'center' }}>{assessment[`add_${key}_re`] || '--'}</td>
                    <td style={{ padding: '6px 8px', textAlign: 'center', borderLeft: '4px solid #fff' }}>{assessment[`add_${key}_le`] || '--'}</td>
                  </tr>
                ))}
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Color Vision</td>
                  <td style={{ padding: '6px 8px', textAlign: 'center' }}>{assessment.add_color_vision_re || 'Not tested'}</td>
                  <td style={{ padding: '6px 8px', textAlign: 'center', borderLeft: '4px solid #fff' }}>{assessment.add_color_vision_le || 'Not tested'}</td>
                </tr>
                <tr style={{ borderTop: '1px solid var(--g100)' }}>
                  <td style={{ padding: '8px 10px', fontWeight: 600, color: 'var(--g700)' }}>Syringing</td>
                  <td style={{ padding: '6px 8px', textAlign: 'center' }}>{assessment.add_syringing_re || 'Not done'}</td>
                  <td style={{ padding: '6px 8px', textAlign: 'center', borderLeft: '4px solid #fff' }}>{assessment.add_syringing_le || 'Not done'}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 6: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={6} color="var(--g500)" title="Clinical Observations" open={openSections.obs} onToggle={() => toggleSection('obs')}>
          {assessment.observation_chips?.length > 0 && (
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
              {assessment.observation_chips.map((chip) => (
                <div key={chip} style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>
                  {chip}
                </div>
              ))}
            </div>
          )}
          <label className="flbl">Additional observations</label>
          <div style={{ fontSize: 13, color: assessment.observations_text ? 'var(--g800)' : 'var(--g400)' }}>
            {assessment.observations_text || 'None recorded'}
          </div>
        </AsmtSection>
      </div>

      {/* AUDIT LOG -- Administrator-only. Doctor overrides are highlighted
          here since they're logged as regular entries on this same
          assessment (no separate shadow table). Collapsed into a
          dropdown by default; opens itself when there's an override to
          review (see the effect above). */}
      {isAdmin && (
        <div className="card">
          <div
            className="card-title"
            style={{ marginBottom: auditLogOpen ? 10 : 0, cursor: 'pointer', display: 'flex', alignItems: 'center' }}
            onClick={() => setAuditLogOpen((v) => !v)}
          >
            <i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log
            <span className="badge b-gray" style={{ marginLeft: 8 }}>{auditLog.length}</span>
            <i className={`ti ${auditLogOpen ? 'ti-chevron-up' : 'ti-chevron-down'}`} style={{ marginLeft: 'auto', color: 'var(--g400)' }}></i>
          </div>
          {auditLogOpen && (
            <>
              {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity recorded.</div>}
              {auditLog.map((a) => (
                <div
                  key={a.id}
                  style={{
                    fontSize: 11, padding: '6px 8px', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8,
                    background: a.isDoctorOverride ? 'rgba(220,38,38,0.06)' : 'transparent',
                    borderRadius: a.isDoctorOverride ? 6 : 0,
                    marginBottom: a.isDoctorOverride ? 2 : 0,
                  }}
                >
                  <span style={{ color: a.isDoctorOverride ? 'var(--red)' : 'var(--g400)', flexShrink: 0 }}>
                    {new Date(a.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                  </span>
                  <span style={{ color: a.isDoctorOverride ? 'var(--red)' : 'var(--g500)', fontWeight: a.isDoctorOverride ? 600 : 400 }}>
                    {a.isDoctorOverride && <i className="ti ti-stethoscope" style={{ marginRight: 4 }}></i>}
                    {a.message}
                    {a.isDoctorOverride && a.created_by_name && <span style={{ fontWeight: 400 }}> -- {a.created_by_name}</span>}
                  </span>
                </div>
              ))}
            </>
          )}
        </div>
      )}

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => (onBack ? onBack() : router.push('/optometry-dashboard'))}>
          <i className="ti ti-arrow-left"></i> Back to History
        </button>
      </div>
    </div>
  );
}
