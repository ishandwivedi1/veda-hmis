'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getAssessmentDetail } from '@/app/(main)/optometry-history/actions';

// Same VA field layout as the live entry workspace (app/(main)/optometry/[id]/optometry-workspace.js)
// -- kept in sync deliberately so a completed sheet renders identically here, just non-editable.
const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

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
  if (!value) return <span style={{ fontSize: 12, color: 'var(--g400)' }}>Not recorded</span>;
  return (
    <div style={{ display: 'inline-block', padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>
      {value}
    </div>
  );
}

export default function AssessmentViewer({ assessmentId }) {
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [overrideCount, setOverrideCount] = useState(0);
  const [loadError, setLoadError] = useState('');
  const [openSections, setOpenSections] = useState({ va: true, refraction: true, iop: true, additional: true, obs: true });
  const router = useRouter();

  useEffect(() => {
    getAssessmentDetail(assessmentId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setOverrideCount(result.overrideCount);
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
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' });
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
      <div style={{ background: 'linear-gradient(135deg,#0f766e,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
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
          <i className="ti ti-alert-triangle"></i> A doctor has overridden {overrideCount} field{overrideCount > 1 ? 's' : ''} on this record. See the highlighted entries in the Audit Log below for exactly what changed and when.
        </div>
      )}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={1} color="var(--teal)" title={`Visual Acuity (${assessment.va_scale || 'Snellen'})`} open={openSections.va} onToggle={() => toggleSection('va')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaPill value={assessment[f.key]} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={2} color="var(--blue)" title="Refraction" open={openSections.refraction} onToggle={() => toggleSection('refraction')}>
          {['obj', 'subj', 'final'].map((type) => (
            <div key={type} style={{ marginBottom: 16 }}>
              <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', marginBottom: 6 }}>
                {type === 'obj' ? 'Objective (Auto-Rx)' : type === 'subj' ? 'Subjective' : 'Final Rx'}
              </div>
              <table className="tbl">
                <thead>
                  <tr>
                    <th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{type === 'final' && <th>ADD (near)</th>}
                  </tr>
                </thead>
                <tbody>
                  {['re', 'le'].map((eye) => (
                    <tr key={eye}>
                      <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_sph`] || '--'}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_cyl`] || '--'}</td>
                      <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_axis`] || '--'}</td>
                      {type === 'final' && <td style={{ textAlign: 'center' }}>{assessment[`ref_${type}_${eye}_add`] || '--'}</td>}
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          ))}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div><label className="flbl">Pupillary Distance (PD)</label><div style={{ fontSize: 13 }}>{assessment.ref_pd || '--'}</div></div>
            <div><label className="flbl">Vertex Distance</label><div style={{ fontSize: 13 }}>{assessment.ref_vd || '--'}</div></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={3} color="var(--purple)" title={`Intraocular Pressure (${assessment.iop_method || '--'})`} open={openSections.iop} onToggle={() => toggleSection('iop')}>
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

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={4} color="var(--amber)" title="Additional Measurements" open={openSections.additional} onToggle={() => toggleSection('additional')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><div style={{ fontSize: 13 }}>{assessment.add_k1 || '--'}</div></div>
            <div><label className="flbl">Keratometry K2</label><div style={{ fontSize: 13 }}>{assessment.add_k2 || '--'}</div></div>
            <div><label className="flbl">Axial Length</label><div style={{ fontSize: 13 }}>{assessment.add_axial_length || '--'}</div></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><div style={{ fontSize: 13 }}>{assessment.add_pachymetry || '--'}</div></div>
            <div><label className="flbl">White-to-White</label><div style={{ fontSize: 13 }}>{assessment.add_white_to_white || '--'}</div></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><div style={{ fontSize: 13 }}>{assessment.add_schirmer || '--'}</div></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div><label className="flbl">Color vision</label><div style={{ fontSize: 13 }}>{assessment.add_color_vision || 'Not tested'}</div></div>
            <div><label className="flbl">Ocular motility</label><div style={{ fontSize: 13 }}>{assessment.add_ocular_motility || 'Not tested'}</div></div>
            <div><label className="flbl">Syringing</label><div style={{ fontSize: 13 }}>{assessment.add_syringing || 'Not done'}</div></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={5} color="var(--g500)" title="Clinical Observations" open={openSections.obs} onToggle={() => toggleSection('obs')}>
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

      {/* AUDIT LOG -- doctor overrides are highlighted here since they're
          logged as regular entries on this same assessment (no separate
          shadow table). */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
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
              {new Date(a.created_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
            </span>
            <span style={{ color: a.isDoctorOverride ? 'var(--red)' : 'var(--g500)', fontWeight: a.isDoctorOverride ? 600 : 400 }}>
              {a.isDoctorOverride && <i className="ti ti-stethoscope" style={{ marginRight: 4 }}></i>}
              {a.message}
              {a.isDoctorOverride && a.created_by_name && <span style={{ fontWeight: 400 }}> -- {a.created_by_name}</span>}
            </span>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-history')}>
          <i className="ti ti-arrow-left"></i> Back to History
        </button>
      </div>
    </div>
  );
}
