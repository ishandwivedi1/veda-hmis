'use client';

import { useState } from 'react';
import { addDoctorRepeatFinding } from '@/app/(main)/consultation/actions';

// Numeric-aware compare -- treats "12" and "12.0" as equal, falls back
// to trimmed string compare for VA notations like "6/6" or "CF 1m".
function differs(a, b) {
  if (a === null || a === undefined || a === '') return false;
  if (b === null || b === undefined || b === '') return false;
  const na = parseFloat(a);
  const nb = parseFloat(b);
  if (!Number.isNaN(na) && !Number.isNaN(nb) && `${na}` === `${a}`.trim() && `${nb}` === `${b}`.trim()) {
    return Math.abs(na - nb) > 0.001;
  }
  return String(a).trim() !== String(b).trim();
}

// Inline chip -- shows the doctor's latest repeat value next to the
// optometrist's own field. Never implies the optometrist's value was
// overwritten (CDP-004): both stay visible side by side.
function DoctorChip({ optoValue, doctorValue }) {
  if (doctorValue === null || doctorValue === undefined || doctorValue === '') return null;
  const flagged = differs(optoValue, doctorValue);
  return (
    <div
      style={{
        display: 'inline-flex', alignItems: 'center', gap: 4, marginTop: 4, padding: '2px 8px', borderRadius: 20,
        fontSize: 11, fontWeight: 700,
        background: flagged ? 'rgba(220,38,38,0.1)' : 'rgba(15,118,110,0.08)',
        color: flagged ? 'var(--red)' : 'var(--teal)',
      }}
    >
      <i className={`ti ti-${flagged ? 'alert-triangle' : 'stethoscope'}`} style={{ fontSize: 11 }}></i>
      Dr: {doctorValue}{flagged ? ' (differs)' : ''}
    </div>
  );
}

function ReadField({ label, value }) {
  return (
    <div>
      <label className="flbl">{label}</label>
      <div style={{ fontSize: 13, color: value ? 'var(--g800)' : 'var(--g400)' }}>{value || '--'}</div>
    </div>
  );
}

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

export default function OptometryTab({ findings, iopReadings, doctorRepeatFindings, encounterId, onSaved }) {
  const [openSections, setOpenSections] = useState({ va: true, refraction: true, iop: true, additional: false, obs: false });
  const [showRepeatForm, setShowRepeatForm] = useState(false);
  const [repeatReVa, setRepeatReVa] = useState('');
  const [repeatLeVa, setRepeatLeVa] = useState('');
  const [repeatReIop, setRepeatReIop] = useState('');
  const [repeatLeIop, setRepeatLeIop] = useState('');
  const [repeatReSph, setRepeatReSph] = useState('');
  const [repeatLeSph, setRepeatLeSph] = useState('');
  const [repeatReCyl, setRepeatReCyl] = useState('');
  const [repeatLeCyl, setRepeatLeCyl] = useState('');
  const [repeatNotes, setRepeatNotes] = useState('');
  const [repeatSaving, setRepeatSaving] = useState(false);

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddRepeatFinding() {
    setRepeatSaving(true);
    const result = await addDoctorRepeatFinding(encounterId, {
      reVa: repeatReVa, leVa: repeatLeVa, reIop: repeatReIop, leIop: repeatLeIop,
      reSph: repeatReSph, leSph: repeatLeSph, reCyl: repeatReCyl, leCyl: repeatLeCyl, notes: repeatNotes,
    });
    setRepeatSaving(false);
    if (result.error) return;
    setRepeatReVa(''); setRepeatLeVa(''); setRepeatReIop(''); setRepeatLeIop('');
    setRepeatReSph(''); setRepeatLeSph(''); setRepeatReCyl(''); setRepeatLeCyl(''); setRepeatNotes('');
    setShowRepeatForm(false);
    if (onSaved) onSaved();
  }

  const latestFinding = (doctorRepeatFindings || [])[0] || null;
  const reIop = (iopReadings || []).filter((r) => r.eye === 'RE');
  const leIop = (iopReadings || []).filter((r) => r.eye === 'LE');

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
      {!findings ? (
        <div className="card" style={{ marginBottom: 12 }}>
          <div className="card-title" style={{ marginBottom: 8 }}>
            <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Findings
          </div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>No optometry assessment on file for this visit. You can enter readings directly below.</div>
        </div>
      ) : (
        <>
          <div className="msg-err" style={{ marginBottom: 12 }}>
            <i className="ti ti-lock"></i> Optometrist's sheet -- read only, auto-filled. Any correction is recorded separately below and never overwrites this record (CDP-004).
          </div>

          {/* SECTION 1: VISUAL ACUITY */}
          <div style={{ marginBottom: 12 }}>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: openSections.va ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => toggleSection('va')}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--teal)', color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, marginRight: 8 }}>1</span>
                  Visual Acuity ({findings.va_scale || 'Snellen'})
                </div>
                <i className={`ti ti-chevron-${openSections.va ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
              </div>
              {openSections.va && (
                <div style={{ padding: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                  {['RE', 'LE'].map((eye) => (
                    <div key={eye}>
                      <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                        <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                      </div>
                      {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                        <div key={f.key} style={{ marginBottom: 12 }}>
                          <ReadField label={f.label} value={findings[f.key]} />
                          {f.key === (eye === 'RE' ? 're_dist_unaided' : 'le_dist_unaided') && (
                            <DoctorChip optoValue={findings[f.key]} doctorValue={eye === 'RE' ? latestFinding?.re_va : latestFinding?.le_va} />
                          )}
                        </div>
                      ))}
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* SECTION 2: REFRACTION */}
          <div style={{ marginBottom: 12 }}>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: openSections.refraction ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => toggleSection('refraction')}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--blue)', color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, marginRight: 8 }}>2</span>
                  Refraction
                </div>
                <i className={`ti ti-chevron-${openSections.refraction ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
              </div>
              {openSections.refraction && (
                <div style={{ padding: 16 }}>
                  {['obj', 'subj', 'final'].map((type) => (
                    <div key={type} style={{ marginBottom: 16 }}>
                      <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase', marginBottom: 6 }}>
                        {type === 'obj' ? 'Objective (Auto-Rx)' : type === 'subj' ? 'Subjective' : 'Final Rx'}
                      </div>
                      <table className="tbl">
                        <thead>
                          <tr><th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{type === 'final' && <th>ADD (near)</th>}</tr>
                        </thead>
                        <tbody>
                          {['re', 'le'].map((eye) => (
                            <tr key={eye}>
                              <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                              <td style={{ textAlign: 'center' }}>
                                {findings[`ref_${type}_${eye}_sph`] || '--'}
                                {type === 'final' && <DoctorChip optoValue={findings[`ref_${type}_${eye}_sph`]} doctorValue={eye === 're' ? latestFinding?.re_sph : latestFinding?.le_sph} />}
                              </td>
                              <td style={{ textAlign: 'center' }}>
                                {findings[`ref_${type}_${eye}_cyl`] || '--'}
                                {type === 'final' && <DoctorChip optoValue={findings[`ref_${type}_${eye}_cyl`]} doctorValue={eye === 're' ? latestFinding?.re_cyl : latestFinding?.le_cyl} />}
                              </td>
                              <td style={{ textAlign: 'center' }}>{findings[`ref_${type}_${eye}_axis`] || '--'}</td>
                              {type === 'final' && <td style={{ textAlign: 'center' }}>{findings[`ref_${type}_${eye}_add`] || '--'}</td>}
                            </tr>
                          ))}
                        </tbody>
                      </table>
                    </div>
                  ))}
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
                    <ReadField label="Pupillary Distance (PD)" value={findings.ref_pd} />
                    <ReadField label="Vertex Distance" value={findings.ref_vd} />
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* SECTION 3: IOP */}
          <div style={{ marginBottom: 12 }}>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: openSections.iop ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => toggleSection('iop')}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--purple)', color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, marginRight: 8 }}>3</span>
                  Intraocular Pressure ({findings.iop_method || '--'})
                </div>
                <i className={`ti ti-chevron-${openSections.iop ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
              </div>
              {openSections.iop && (
                <div style={{ padding: 16, display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
                  {[['RE', reIop], ['LE', leIop]].map(([eye, list]) => (
                    <div key={eye}>
                      <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                        <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                      </div>
                      {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings recorded</div>}
                      {list.map((r, i) => iopReadingRow(r, list, i))}
                      <DoctorChip optoValue={list.length ? list[list.length - 1].value : null} doctorValue={eye === 'RE' ? latestFinding?.re_iop : latestFinding?.le_iop} />
                    </div>
                  ))}
                </div>
              )}
            </div>
          </div>

          {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
          <div style={{ marginBottom: 12 }}>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: openSections.additional ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => toggleSection('additional')}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--amber)', color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, marginRight: 8 }}>4</span>
                  Additional Measurements
                </div>
                <i className={`ti ti-chevron-${openSections.additional ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
              </div>
              {openSections.additional && (
                <div style={{ padding: 16 }}>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
                    <ReadField label="Keratometry K1" value={findings.add_k1} />
                    <ReadField label="Keratometry K2" value={findings.add_k2} />
                    <ReadField label="Axial Length" value={findings.add_axial_length} />
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
                    <ReadField label="Pachymetry (CCT)" value={findings.add_pachymetry} />
                    <ReadField label="White-to-White" value={findings.add_white_to_white} />
                    <ReadField label="Schirmer test (RE/LE)" value={findings.add_schirmer} />
                  </div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
                    <ReadField label="Color vision" value={findings.add_color_vision} />
                    <ReadField label="Ocular motility" value={findings.add_ocular_motility} />
                    <ReadField label="Syringing" value={findings.add_syringing} />
                  </div>
                </div>
              )}
            </div>
          </div>

          {/* SECTION 5: CLINICAL OBSERVATIONS */}
          <div style={{ marginBottom: 12 }}>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: openSections.obs ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => toggleSection('obs')}>
                <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)' }}>
                  <span style={{ width: 22, height: 22, borderRadius: '50%', background: 'var(--g500)', color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, marginRight: 8 }}>5</span>
                  Clinical Observations
                </div>
                <i className={`ti ti-chevron-${openSections.obs ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
              </div>
              {openSections.obs && (
                <div style={{ padding: 16 }}>
                  {findings.observation_chips?.length > 0 && (
                    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
                      {findings.observation_chips.map((chip) => (
                        <div key={chip} style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, border: '1.5px solid var(--teal)', background: 'var(--teal)', color: '#fff' }}>{chip}</div>
                      ))}
                    </div>
                  )}
                  <ReadField label="Additional observations" value={findings.observations_text} />
                </div>
              )}
            </div>
          </div>
        </>
      )}

      {/* DOCTOR'S REPEAT / VERIFIED FINDINGS -- feeds back into Optometry
          History (CDP-004): a separate, timestamped record, never an
          overwrite of the optometrist's own row. */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 8, display: 'flex', justifyContent: 'space-between' }}>
          <span><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor&apos;s Repeat / Verified Findings</span>
          {!showRepeatForm && (
            <button type="button" className="btn btn-sm" onClick={() => setShowRepeatForm(true)}>
              <i className="ti ti-plus"></i> {findings ? 'Add Repeat Reading' : 'Enter Readings'}
            </button>
          )}
        </div>

        {(doctorRepeatFindings || []).length === 0 && !showRepeatForm && (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>No doctor-recorded readings yet.</div>
        )}

        {(doctorRepeatFindings || []).map((r) => (
          <div key={r.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
            <div style={{ color: 'var(--g400)', fontSize: 10 }}>{new Date(r.recorded_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</div>
            <div style={{ color: 'var(--g600)' }}>
              VA: RE {r.re_va || '--'} / LE {r.le_va || '--'} &nbsp;&nbsp;
              IOP: RE {r.re_iop ?? '--'} / LE {r.le_iop ?? '--'} &nbsp;&nbsp;
              Sph: RE {r.re_sph || '--'} / LE {r.le_sph || '--'} &nbsp;&nbsp;
              Cyl: RE {r.re_cyl || '--'} / LE {r.le_cyl || '--'}
            </div>
            {r.notes && <div style={{ color: 'var(--g500)', fontSize: 11, marginTop: 2 }}>{r.notes}</div>}
          </div>
        ))}

        {showRepeatForm && (
          <div style={{ marginTop: 10, paddingTop: 10, borderTop: '1px solid var(--g100)' }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div><label className="flbl">RE VA</label><input className="fi fi-sm" value={repeatReVa} onChange={(e) => setRepeatReVa(e.target.value)} placeholder="e.g. 6/9" /></div>
              <div><label className="flbl">LE VA</label><input className="fi fi-sm" value={repeatLeVa} onChange={(e) => setRepeatLeVa(e.target.value)} placeholder="e.g. 6/12" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div><label className="flbl">RE IOP</label><input type="number" className="fi fi-sm" value={repeatReIop} onChange={(e) => setRepeatReIop(e.target.value)} /></div>
              <div><label className="flbl">LE IOP</label><input type="number" className="fi fi-sm" value={repeatLeIop} onChange={(e) => setRepeatLeIop(e.target.value)} /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div><label className="flbl">RE Sph</label><input className="fi fi-sm" value={repeatReSph} onChange={(e) => setRepeatReSph(e.target.value)} placeholder="-2.00" /></div>
              <div><label className="flbl">RE Cyl</label><input className="fi fi-sm" value={repeatReCyl} onChange={(e) => setRepeatReCyl(e.target.value)} placeholder="-0.50" /></div>
              <div><label className="flbl">LE Sph</label><input className="fi fi-sm" value={repeatLeSph} onChange={(e) => setRepeatLeSph(e.target.value)} placeholder="-1.50" /></div>
              <div><label className="flbl">LE Cyl</label><input className="fi fi-sm" value={repeatLeCyl} onChange={(e) => setRepeatLeCyl(e.target.value)} placeholder="-0.25" /></div>
            </div>
            <input className="fi fi-sm" placeholder="Notes (optional)" value={repeatNotes} onChange={(e) => setRepeatNotes(e.target.value)} style={{ marginBottom: 8 }} />
            <div style={{ display: 'flex', gap: 6 }}>
              <button type="button" className="btn btn-sm btn-primary" onClick={handleAddRepeatFinding} disabled={repeatSaving}>
                {repeatSaving ? 'Saving...' : 'Save Reading'}
              </button>
              <button type="button" className="btn btn-sm" onClick={() => setShowRepeatForm(false)}>Cancel</button>
            </div>
          </div>
        )}

        <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>
          Saved readings appear back in the optometrist's Assessment History, flagged wherever they differ from the original.
        </div>
      </div>
    </div>
  );
}
