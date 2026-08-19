'use client';

import { useState, useEffect } from 'react';
import { updateOptometryFindings, createOptometryAssessmentForVisit } from '@/app/(main)/consultation/actions';
import { addIopReading } from '@/app/(main)/optometry/actions';

// Same VA scale/field definitions as the optometrist's own entry form
// (app/(main)/optometry/[id]/optometry-workspace.js) -- kept in sync so
// this editable view behaves identically, just reached from Consultation.
const VA_SNELLEN = ['6/6', '6/9', '6/12', '6/18', '6/24', '6/36', '6/60', '3/60', '2/60', '1/60'];
const VA_SPECIAL = ['CF', 'HM', 'PL', 'NPL'];
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

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

const OBS_CHIPS = ['Poor fixation', 'Excessive blinking', 'Difficulty cooperating', 'Media opacity limiting measurement', 'Nystagmus noted', 'Patient anxious'];

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen',
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1: '', add_k2: '', add_axial_length: '', add_pachymetry: '', add_white_to_white: '', add_schirmer: '',
    add_color_vision: '', add_ocular_motility: '', add_syringing: '',
    observation_chips: [], observations_text: '',
  };
  VA_FIELDS.forEach((f2) => { f[f2.key] = ''; });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['sph', 'cyl', 'axis'].forEach((p) => { f[`ref_${type}_${eye}_${p}`] = ''; });
      if (type === 'final') f[`ref_${type}_${eye}_add`] = '';
    });
  });
  return f;
}

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

function VaOptPills({ values, selected, onSelect }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 6 }}>
      {values.map((v) => (
        <div
          key={v}
          onClick={() => onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
            border: `1.5px solid ${selected === v ? 'var(--teal)' : 'var(--g200)'}`,
            background: selected === v ? 'var(--teal)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
      {VA_SPECIAL.map((v) => (
        <div
          key={v}
          onClick={() => onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
            border: `1.5px dashed ${selected === v ? 'var(--amber)' : 'var(--g200)'}`,
            borderStyle: selected === v ? 'solid' : 'dashed',
            background: selected === v ? 'var(--amber)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
    </div>
  );
}

export default function OptometryTab({ findings, iopReadings, visitId, encounterId, onSaved }) {
  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ va: true, refraction: true, iop: true, additional: false, obs: false });
  const [refTab, setRefTab] = useState('final');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [creating, setCreating] = useState(false);
  const [dirty, setDirty] = useState(false);
  const [showConfirmModal, setShowConfirmModal] = useState(false);

  useEffect(() => {
    if (!findings) { setForm(emptyForm()); return; }
    const f = emptyForm();
    Object.keys(f).forEach((key) => {
      if (findings[key] !== null && findings[key] !== undefined) f[key] = findings[key];
    });
    setForm(f);
    setDirty(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- deliberately
    // keyed on the assessment's id, not the findings object itself. Any
    // parent refresh (e.g. another tab saving) creates a new findings
    // object reference for the *same* assessment, and resetting on every
    // such reference change was wiping out not-yet-saved edits in this
    // tab whenever something elsewhere triggered a refresh.
  }, [findings?.id]);

  const [localIopReadings, setLocalIopReadings] = useState(iopReadings || []);
  useEffect(() => {
    setLocalIopReadings(iopReadings || []);
    // Re-sync only when switching to a different assessment, same reasoning as above.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [findings?.id]);

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
    setDirty(true);
  }

  function setRef(type, eye, part, value) {
    setField(`ref_${type}_${eye}_${part}`, value);
  }

  function toggleObsChip(chip) {
    setForm((prev) => {
      const has = prev.observation_chips.includes(chip);
      return { ...prev, observation_chips: has ? prev.observation_chips.filter((c) => c !== chip) : [...prev.observation_chips, chip] };
    });
    setDirty(true);
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value || !findings) return;
    const result = await addIopReading(findings.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setLocalIopReadings((prev) => [...prev, result.reading]);
  }

  async function handleSave() {
    if (!findings) return;
    setShowConfirmModal(false);
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateOptometryFindings(findings.id, encounterId, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(result.changedCount > 0 ? `Saved -- ${result.changedCount} field(s) updated. Visible in Optometry History.` : 'No changes to save.');
    setDirty(false);
    if (onSaved) onSaved();
  }

  async function handleCreate() {
    setCreating(true);
    setError('');
    const result = await createOptometryAssessmentForVisit(visitId, encounterId);
    setCreating(false);
    if (result.error) { setError(result.error); return; }
    if (onSaved) onSaved();
  }

  const vaScaleValues = vaValuesForScale(form.va_scale);
  const reIopSorted = (localIopReadings || []).filter((r) => r.eye === 'RE');
  const leIopSorted = (localIopReadings || []).filter((r) => r.eye === 'LE');

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

  if (!findings) {
    return (
      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Findings
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12 }}>No optometry assessment on file for this visit.</div>
        <button type="button" className="btn btn-primary" onClick={handleCreate} disabled={creating}>
          {creating ? 'Creating...' : 'Start Assessment Here'}
        </button>
        {error && <div className="msg-err" style={{ marginTop: 10 }}>{error}</div>}
      </div>
    );
  }

  return (
    <div>
      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-edit"></i> Editable -- this is the optometrist's own record. Any change you save here updates it directly and is logged to Optometry History so the optometrist can see what changed.
      </div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={1} color="var(--teal)" title="Visual Acuity" open={openSections.va} onToggle={() => toggleSection('va')}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaOptPills values={vaScaleValues} selected={form[f.key]} onSelect={(v) => setField(f.key, v)} />
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
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {[['obj', 'Objective (Auto-Rx)'], ['subj', 'Subjective'], ['final', 'Final Rx']].map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>
          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead>
              <tr><th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{refTab === 'final' && <th>ADD (near)</th>}</tr>
            </thead>
            <tbody>
              {['re', 'le'].map((eye) => (
                <tr key={eye}>
                  <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_sph`]} onChange={(e) => setRef(refTab, eye, 'sph', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_cyl`]} onChange={(e) => setRef(refTab, eye, 'cyl', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_axis`]} onChange={(e) => setRef(refTab, eye, 'axis', e.target.value)} placeholder="--" /></td>
                  {refTab === 'final' && (
                    <td><input className="fi fi-sm" style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_add`]} onChange={(e) => setRef(refTab, eye, 'add', e.target.value)} placeholder="--" /></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
            <div><label className="flbl">Pupillary Distance (PD)</label><input className="fi fi-sm" value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" /></div>
            <div><label className="flbl">Vertex Distance</label><input className="fi fi-sm" value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" /></div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={3} color="var(--purple)" title="Intraocular Pressure" open={openSections.iop} onToggle={() => toggleSection('iop')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {['Non-Contact Tonometer (NCT)', 'Goldmann Applanation', 'Perkins', 'Tono-Pen', 'iCare'].map((m) => <option key={m}>{m}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
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
                <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                  <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                  <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                </div>
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={4} color="var(--amber)" title="Additional Measurements" open={openSections.additional} onToggle={() => toggleSection('additional')}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><input className="fi fi-sm" value={form.add_k1} onChange={(e) => setField('add_k1', e.target.value)} placeholder="e.g. 43.50 D" /></div>
            <div><label className="flbl">Keratometry K2</label><input className="fi fi-sm" value={form.add_k2} onChange={(e) => setField('add_k2', e.target.value)} placeholder="e.g. 44.25 D" /></div>
            <div><label className="flbl">Axial Length</label><input className="fi fi-sm" value={form.add_axial_length} onChange={(e) => setField('add_axial_length', e.target.value)} placeholder="e.g. 23.2 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><input className="fi fi-sm" value={form.add_pachymetry} onChange={(e) => setField('add_pachymetry', e.target.value)} placeholder="e.g. 542 microns" /></div>
            <div><label className="flbl">White-to-White</label><input className="fi fi-sm" value={form.add_white_to_white} onChange={(e) => setField('add_white_to_white', e.target.value)} placeholder="e.g. 11.8 mm" /></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><input className="fi fi-sm" value={form.add_schirmer} onChange={(e) => setField('add_schirmer', e.target.value)} placeholder="e.g. 8/6 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div>
              <label className="flbl">Color vision</label>
              <select className="fi fi-sm" value={form.add_color_vision} onChange={(e) => setField('add_color_vision', e.target.value)}>
                <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
              </select>
            </div>
            <div>
              <label className="flbl">Ocular motility</label>
              <select className="fi fi-sm" value={form.add_ocular_motility} onChange={(e) => setField('add_ocular_motility', e.target.value)}>
                <option value="">Not tested</option><option>Full in all directions</option><option>Restricted</option><option>Nystagmus present</option>
              </select>
            </div>
            <div>
              <label className="flbl">Syringing</label>
              <select className="fi fi-sm" value={form.add_syringing} onChange={(e) => setField('add_syringing', e.target.value)}>
                <option value="">Not done</option><option>Patent RE</option><option>Patent LE</option><option>Patent bilateral</option><option>Block RE</option><option>Block LE</option>
              </select>
            </div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection num={5} color="var(--g500)" title="Clinical Observations" open={openSections.obs} onToggle={() => toggleSection('obs')}>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
            {OBS_CHIPS.map((chip) => (
              <div
                key={chip}
                onClick={() => toggleObsChip(chip)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${form.observation_chips.includes(chip) ? 'var(--teal)' : 'var(--g200)'}`, background: form.observation_chips.includes(chip) ? 'var(--teal)' : '#fff', color: form.observation_chips.includes(chip) ? '#fff' : 'var(--g600)' }}
              >
                {chip}
              </div>
            ))}
          </div>
          <label className="flbl">Additional observations</label>
          <textarea className="fi" rows={2} value={form.observations_text} onChange={(e) => setField('observations_text', e.target.value)} placeholder="e.g. Patient had difficulty with right eye assessment due to glare sensitivity..." />
        </AsmtSection>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginTop: 4 }}>
        <button type="button" className="btn btn-primary" onClick={() => setShowConfirmModal(true)} disabled={saving || !dirty}>
          {saving ? 'Saving...' : 'Save Changes'}
        </button>
        {!dirty && <span style={{ fontSize: 11, color: 'var(--g400)' }}>No unsaved changes</span>}
      </div>

      {showConfirmModal && (
        <div onClick={() => setShowConfirmModal(false)} style={{ position: 'fixed', inset: 0, background: 'rgba(15,23,42,.45)', zIndex: 200, display: 'flex', alignItems: 'center', justifyContent: 'center', padding: 16 }}>
          <div onClick={(e) => e.stopPropagation()} style={{ background: '#fff', borderRadius: 12, padding: 20, maxWidth: 420, width: '100%', boxShadow: '0 12px 40px rgba(0,0,0,.2)' }}>
            <div style={{ fontSize: 14, fontWeight: 700, color: 'var(--g800)', marginBottom: 8, display: 'flex', alignItems: 'center', gap: 8 }}>
              <i className="ti ti-alert-triangle" style={{ color: 'var(--amber)' }}></i> Confirm change to optometrist's record
            </div>
            <div style={{ fontSize: 12.5, color: 'var(--g600)', lineHeight: 1.5, marginBottom: 16 }}>
              You're about to overwrite reading(s) originally recorded by the optometrist. This will be logged as a doctor override in Optometry History, visible to the optometrist. Are you sure you want to save these changes?
            </div>
            <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
              <button type="button" className="btn btn-sm" onClick={() => setShowConfirmModal(false)}>Cancel</button>
              <button type="button" className="btn btn-sm btn-primary" onClick={handleSave} disabled={saving}>
                {saving ? 'Saving...' : 'Confirm & Save'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
