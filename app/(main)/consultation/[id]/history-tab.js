'use client';

import { useState, useEffect } from 'react';
import { saveHistory, addDoctorRepeatFinding } from '@/app/(main)/consultation/actions';

const CC_TEMPLATES = ['Diminution of vision', 'Watering', 'Pain', 'Redness', 'Headache', 'Floaters', 'Flashes', 'Double vision', 'Blurring', 'Follow-up'];
const OCULAR_HX = ['Cataract surgery', 'Glaucoma', 'Trauma', 'LASIK', 'Retinal disease', 'Laser procedure', 'Intravitreal injection'];
const MEDICAL_HX = ['Diabetes', 'Hypertension', 'Thyroid disease', 'Cardiac disease', 'Renal disease', 'Autoimmune'];
const FAMILY_HX = ['Glaucoma', 'High myopia', 'Retinal disorders', 'None known'];

function Chip({ label, selected, onClick }) {
  return (
    <span
      onClick={onClick}
      style={{
        padding: '3px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
        border: `1.5px solid ${selected ? 'var(--blue)' : 'var(--g200)'}`,
        background: selected ? 'var(--blue)' : '#fff',
        color: selected ? '#fff' : 'var(--g600)',
      }}
    >
      {label}
    </span>
  );
}

export default function HistoryTab({ encounter, findings, iopReadings, doctorRepeatFindings, onSaved }) {
  const [chiefComplaint, setChiefComplaint] = useState('');
  const [ccChips, setCcChips] = useState([]);
  const [duration, setDuration] = useState('');
  const [laterality, setLaterality] = useState('');
  const [hopi, setHopi] = useState('');
  const [ocular, setOcular] = useState([]);
  const [medical, setMedical] = useState([]);
  const [family, setFamily] = useState([]);
  const [drugAllergy, setDrugAllergy] = useState('');
  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState('');

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

  useEffect(() => {
    if (!encounter) return;
    setChiefComplaint(encounter.chief_complaint || '');
    setCcChips(encounter.chief_complaint_chips || []);
    setDuration(encounter.hx_duration || '');
    setLaterality(encounter.hx_laterality || '');
    setHopi(encounter.hx_hopi || '');
    setOcular(encounter.ocular_history || []);
    setMedical(encounter.medical_history || []);
    setFamily(encounter.family_history || []);
    setDrugAllergy(encounter.hx_drug_allergy || '');
  }, [encounter]);

  function toggle(list, setList, val) {
    setList(list.includes(val) ? list.filter((v) => v !== val) : [...list, val]);
  }

  async function handleSave() {
    setSaving(true);
    setSavedMsg('');
    const result = await saveHistory(encounter.id, {
      chiefComplaint, chiefComplaintChips: ccChips, hxDuration: duration, hxLaterality: laterality,
      hxHopi: hopi, ocularHistory: ocular, medicalHistory: medical, familyHistory: family, hxDrugAllergy: drugAllergy,
    });
    setSaving(false);
    if (result.error) return;
    setSavedMsg('History saved.');
    if (onSaved) onSaved();
  }

  async function handleAddRepeatFinding() {
    setRepeatSaving(true);
    const result = await addDoctorRepeatFinding(encounter.id, {
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

  return (
    <div>
      {/* OPTOMETRY FINDINGS -- auto-imported, read-only, owned by the
          Optometrist (CDP-004). Never edited here. */}
      <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
        <div className="card-title" style={{ marginBottom: 8 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Findings
          {findings && <span className="badge b-teal" style={{ fontSize: 10, marginLeft: 6 }}>Auto-imported</span>}
        </div>
        {findings ? (
          <>
            <div style={{ fontSize: 12, color: 'var(--g600)' }}>
              VA: RE {findings.re_dist_unaided || '--'} / LE {findings.le_dist_unaided || '--'} &nbsp;&nbsp;
              IOP: RE {(iopReadings || []).filter((r) => r.eye === 'RE').slice(-1)[0]?.value ?? '--'} / LE {(iopReadings || []).filter((r) => r.eye === 'LE').slice(-1)[0]?.value ?? '--'} &nbsp;&nbsp;
              Sph: RE {findings.ref_final_re_sph || findings.ref_obj_re_sph || '--'} / LE {findings.ref_final_le_sph || findings.ref_obj_le_sph || '--'} &nbsp;&nbsp;
              Cyl: RE {findings.ref_final_re_cyl || findings.ref_obj_re_cyl || '--'} / LE {findings.ref_final_le_cyl || findings.ref_obj_le_cyl || '--'}
            </div>
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>CDP-004: Measurements owned by Optometrist. Add a repeat reading below rather than editing these.</div>
          </>
        ) : (
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>No optometry assessment on file for this visit yet.</div>
        )}
      </div>

      {/* DOCTOR'S REPEAT / VERIFIED FINDINGS */}
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
      </div>

      {/* CHIEF COMPLAINT */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-message" style={{ color: 'var(--blue)' }}></i> Chief Complaint</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
          {CC_TEMPLATES.map((c) => (
            <Chip key={c} label={c} selected={ccChips.includes(c)} onClick={() => toggle(ccChips, setCcChips, c)} />
          ))}
        </div>
        <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Or type complaint..." value={chiefComplaint} onChange={(e) => setChiefComplaint(e.target.value)} />
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
          <div>
            <label className="flbl">Duration</label>
            <input className="fi fi-sm" value={duration} onChange={(e) => setDuration(e.target.value)} placeholder="e.g. 3 months" />
          </div>
          <div>
            <label className="flbl">Laterality</label>
            <select className="fi fi-sm" value={laterality} onChange={(e) => setLaterality(e.target.value)}>
              <option value="">--</option>
              <option>Right eye</option><option>Left eye</option><option>Bilateral</option>
            </select>
          </div>
        </div>
        <label className="flbl">History of present illness</label>
        <textarea className="fi fi-sm" rows={2} value={hopi} onChange={(e) => setHopi(e.target.value)} placeholder="Duration, onset, progression, associated symptoms, previous treatment..." />
      </div>

      {/* STRUCTURED HISTORY */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-forms" style={{ color: 'var(--purple)' }}></i> Structured History</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 12 }}>
          <div>
            <label className="flbl">Ocular history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {OCULAR_HX.map((c) => <Chip key={c} label={c} selected={ocular.includes(c)} onClick={() => toggle(ocular, setOcular, c)} />)}
            </div>
          </div>
          <div>
            <label className="flbl">Medical history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {MEDICAL_HX.map((c) => <Chip key={c} label={c} selected={medical.includes(c)} onClick={() => toggle(medical, setMedical, c)} />)}
            </div>
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
          <div>
            <label className="flbl">Drug history / Allergy</label>
            <input className="fi fi-sm" value={drugAllergy} onChange={(e) => setDrugAllergy(e.target.value)} placeholder="Current meds, allergies..." />
          </div>
          <div>
            <label className="flbl">Family history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {FAMILY_HX.map((c) => <Chip key={c} label={c} selected={family.includes(c)} onClick={() => toggle(family, setFamily, c)} />)}
            </div>
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Saving...' : 'Save History'}
        </button>
        {savedMsg && <span style={{ fontSize: 12, color: 'var(--green)' }}><i className="ti ti-check"></i> {savedMsg}</span>}
      </div>
    </div>
  );
}

