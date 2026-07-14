'use client';

import { useState, useEffect } from 'react';
import { saveHistory } from '@/app/(main)/consultation/actions';

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

export default function HistoryTab({ encounter, onSaved }) {
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

  return (
    <div>
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

