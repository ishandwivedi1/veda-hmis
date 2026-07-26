'use client';

import { useState, useEffect } from 'react';
import { saveHistory } from '@/app/(main)/consultation/actions';
import { getActiveHistoryOptions } from '@/app/(main)/master-data/actions';

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

export default function HistoryTab({ encounter, findings, onSaved }) {
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

  // Chip option lists come from Master Data (Clinical -- History
  // Options tab): app/(main)/master-data/actions.js:getActiveHistoryOptions,
  // table master_history_options. No hardcoded arrays; staff add/retire
  // options from Master Data -> Clinical -> History Options.
  const [options, setOptions] = useState({ chief_complaint: [], ocular_history: [], medical_history: [], family_history: [] });
  const [optionsLoading, setOptionsLoading] = useState(true);

  useEffect(() => {
    getActiveHistoryOptions().then((result) => {
      setOptions(result);
      setOptionsLoading(false);
    });
  }, []);

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
      {/* OPTOMETRY FINDINGS -- see the "Optometry" tab for the full
          sheet and to record a correction. */}
      <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
        <div style={{ fontSize: 12, color: 'var(--g600)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i>
          {findings ? 'Optometry assessment on file for this visit.' : 'No optometry assessment on file for this visit.'}
          <span style={{ color: 'var(--g400)' }}>See the <strong>Optometry</strong> tab for the full sheet{findings ? ' and to record a correction' : ''}.</span>
        </div>
      </div>

      {/* CHIEF COMPLAINT */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-message" style={{ color: 'var(--blue)' }}></i> Chief Complaint</div>
        <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
          {optionsLoading && <span style={{ fontSize: 11, color: 'var(--g400)' }}>Loading options...</span>}
          {options.chief_complaint.map((c) => (
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
              {options.ocular_history.map((c) => <Chip key={c} label={c} selected={ocular.includes(c)} onClick={() => toggle(ocular, setOcular, c)} />)}
            </div>
          </div>
          <div>
            <label className="flbl">Medical history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {options.medical_history.map((c) => <Chip key={c} label={c} selected={medical.includes(c)} onClick={() => toggle(medical, setMedical, c)} />)}
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
              {options.family_history.map((c) => <Chip key={c} label={c} selected={family.includes(c)} onClick={() => toggle(family, setFamily, c)} />)}
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
