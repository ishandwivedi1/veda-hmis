'use client';

import { useState, useEffect, useRef } from 'react';
import { saveHistory } from '@/app/(main)/consultation/actions';
import { getActiveHistoryOptions } from '@/app/(main)/master-data/actions';

// Right eye = Oculus Dexter (OD), Left eye = Oculus Sinister (OS),
// Both = Oculus Uterque (OU) -- the scientific abbreviations, paired
// correctly (OD is right, not left).
const LATERALITY_OPTIONS = [
  { value: 'Right eye (OD)', label: 'Right / OD' },
  { value: 'Left eye (OS)', label: 'Left / OS' },
  { value: 'Both eyes (OU)', label: 'Both / OU' },
];

const AUTOSAVE_DELAY_MS = 1200;

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
  const [drugHistory, setDrugHistory] = useState([]);
  const [allergy, setAllergy] = useState([]);
  const [drugAllergy, setDrugAllergy] = useState('');

  // 'idle' | 'pending' | 'saving' | 'saved' | 'error' -- drives the
  // small inline status indicator that replaced the Save button.
  const [saveState, setSaveState] = useState('idle');

  // Chip option lists come from Master Data (Clinical -- Patient
  // History tab): app/(main)/master-data/actions.js:getActiveHistoryOptions,
  // table master_history_options. No hardcoded arrays; staff add/retire
  // options from Master Data -> Clinical -> Patient History.
  const [options, setOptions] = useState({
    chief_complaint: [], ocular_history: [], medical_history: [], family_history: [], drug_history: [], allergy: [],
  });
  const [optionsLoading, setOptionsLoading] = useState(true);

  const loadedEncounterId = useRef(null);
  const saveTimer = useRef(null);
  const skipNextAutosave = useRef(true);

  useEffect(() => {
    getActiveHistoryOptions().then((result) => {
      setOptions(result);
      setOptionsLoading(false);
    });
  }, []);

  useEffect(() => {
    if (!encounter) return;
    // Loading a (possibly different) encounter's saved data shouldn't
    // itself trigger an autosave -- only actual edits should.
    skipNextAutosave.current = true;
    loadedEncounterId.current = encounter.id;
    setChiefComplaint(encounter.chief_complaint || '');
    setCcChips(encounter.chief_complaint_chips || []);
    setDuration(encounter.hx_duration || '');
    setLaterality(encounter.hx_laterality || '');
    setHopi(encounter.hx_hopi || '');
    setOcular(encounter.ocular_history || []);
    setMedical(encounter.medical_history || []);
    setFamily(encounter.family_history || []);
    setDrugHistory(encounter.drug_history || []);
    setAllergy(encounter.allergy || []);
    setDrugAllergy(encounter.hx_drug_allergy || '');
  }, [encounter]);

  function toggle(list, setList, val) {
    setList(list.includes(val) ? list.filter((v) => v !== val) : [...list, val]);
  }

  // Autosave: debounced ~1.2s after the last change to any field, so a
  // doctor clicking through several chips in a row doesn't fire a save
  // per click. No Save button -- this is the only way history gets
  // written.
  useEffect(() => {
    if (!encounter) return;
    if (skipNextAutosave.current) { skipNextAutosave.current = false; return; }

    setSaveState('pending');
    if (saveTimer.current) clearTimeout(saveTimer.current);
    const encounterIdAtSchedule = encounter.id;

    saveTimer.current = setTimeout(async () => {
      setSaveState('saving');
      const result = await saveHistory(encounterIdAtSchedule, {
        chiefComplaint, chiefComplaintChips: ccChips, hxDuration: duration, hxLaterality: laterality,
        hxHopi: hopi, ocularHistory: ocular, medicalHistory: medical, familyHistory: family,
        drugHistory, allergy, hxDrugAllergy: drugAllergy,
      });
      if (loadedEncounterId.current !== encounterIdAtSchedule) return; // encounter changed mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, AUTOSAVE_DELAY_MS);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [chiefComplaint, ccChips, duration, laterality, hopi, ocular, medical, family, drugHistory, allergy, drugAllergy]);

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
              {LATERALITY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
            </select>
          </div>
        </div>
        <label className="flbl">History of present illness</label>
        <textarea className="fi fi-sm" rows={2} value={hopi} onChange={(e) => setHopi(e.target.value)} placeholder="Duration, onset, progression, associated symptoms, previous treatment..." />
      </div>

      {/* STRUCTURED HISTORY */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-forms" style={{ color: 'var(--purple)' }}></i> Structured History</div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
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
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
          <div>
            <label className="flbl">Family history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {options.family_history.map((c) => <Chip key={c} label={c} selected={family.includes(c)} onClick={() => toggle(family, setFamily, c)} />)}
            </div>
          </div>
          <div>
            <label className="flbl">Drug history</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {options.drug_history.map((c) => <Chip key={c} label={c} selected={drugHistory.includes(c)} onClick={() => toggle(drugHistory, setDrugHistory, c)} />)}
            </div>
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
          <div>
            <label className="flbl">Allergy</label>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
              {options.allergy.map((c) => <Chip key={c} label={c} selected={allergy.includes(c)} onClick={() => toggle(allergy, setAllergy, c)} />)}
            </div>
          </div>
          <div>
            <label className="flbl">Other drug / allergy notes</label>
            <input className="fi fi-sm" value={drugAllergy} onChange={(e) => setDrugAllergy(e.target.value)} placeholder="Anything not covered above..." />
          </div>
        </div>
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 12, color: 'var(--g500)' }}>
        {saveState === 'pending' && <><i className="ti ti-clock"></i> Unsaved changes...</>}
        {saveState === 'saving' && <><i className="ti ti-loader-2"></i> Saving...</>}
        {saveState === 'saved' && <span style={{ color: 'var(--green)' }}><i className="ti ti-check"></i> Saved</span>}
        {saveState === 'error' && <span style={{ color: 'var(--red)' }}><i className="ti ti-alert-triangle"></i> Couldn&apos;t save -- check your connection</span>}
      </div>
    </div>
  );
}
