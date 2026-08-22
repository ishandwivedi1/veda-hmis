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

let ccIdCounter = 0;
function makeComplaintId() { ccIdCounter += 1; return `cc-${Date.now()}-${ccIdCounter}`; }
function blankComplaint() { return { id: makeComplaintId(), chips: [], text: '', duration: '', laterality: '' }; }

// One eye can have a different complaint, duration, and laterality than
// the other -- e.g. diminished vision OD x 3 months, redness OS x 2 days.
// Each complaint entry is formatted independently, then joined with "; "
// to build the flattened chief_complaint string that older/simpler
// readers (visit list preview, follow-up panel, visit summary print)
// still consume as a single line.
function formatComplaintEntry(e) {
  const label = [e.chips && e.chips.length ? e.chips.join(', ') : null, e.text || null].filter(Boolean).join(', ');
  if (!label) return '';
  const bits = [label];
  if (e.duration) bits.push(`- ${e.duration}`);
  if (e.laterality) bits.push(`(${e.laterality})`);
  return bits.join(' ');
}

export default function HistoryTab({ encounter, findings, onSaved, hideOptometryBanner = false }) {
  // Multiple chief-complaint entries -- see formatComplaintEntry above.
  // Each entry: { id, chips: string[], text, duration, laterality }.
  const [complaints, setComplaints] = useState([blankComplaint()]);
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

    const savedEntries = encounter.chief_complaint_entries;
    if (Array.isArray(savedEntries) && savedEntries.length > 0) {
      setComplaints(savedEntries.map((e) => ({
        id: makeComplaintId(), chips: e.chips || [], text: e.text || '', duration: e.duration || '', laterality: e.laterality || '',
      })));
    } else if (encounter.chief_complaint || (encounter.chief_complaint_chips || []).length || encounter.hx_duration || encounter.hx_laterality) {
      // Legacy single-complaint encounter, recorded before multi-complaint
      // support -- migrate into the new shape for editing; it's written
      // back in the new format on the next autosave.
      setComplaints([{
        id: makeComplaintId(), chips: encounter.chief_complaint_chips || [], text: encounter.chief_complaint || '',
        duration: encounter.hx_duration || '', laterality: encounter.hx_laterality || '',
      }]);
    } else {
      setComplaints([blankComplaint()]);
    }

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

  function addComplaint() {
    setComplaints((list) => [...list, blankComplaint()]);
  }
  function removeComplaint(id) {
    // Always keep at least one entry -- an empty one, not a blank tab.
    setComplaints((list) => (list.length <= 1 ? list : list.filter((c) => c.id !== id)));
  }
  function updateComplaint(id, field, value) {
    setComplaints((list) => list.map((c) => (c.id === id ? { ...c, [field]: value } : c)));
  }
  function toggleComplaintChip(id, chip) {
    setComplaints((list) => list.map((c) => (c.id === id
      ? { ...c, chips: c.chips.includes(chip) ? c.chips.filter((v) => v !== chip) : [...c.chips, chip] }
      : c)));
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

      // Drop fully-empty entries (e.g. a stray "+ Add Complaint" the
      // user didn't fill in) before persisting, and derive the flattened
      // fields older readers still rely on.
      const cleanEntries = complaints
        .map(({ chips, text, duration, laterality }) => ({ chips, text: (text || '').trim(), duration: (duration || '').trim(), laterality: laterality || '' }))
        .filter((e) => e.chips.length > 0 || e.text || e.duration || e.laterality);
      const combinedText = cleanEntries.map(formatComplaintEntry).filter(Boolean).join('; ');
      const combinedChips = [...new Set(cleanEntries.flatMap((e) => e.chips))];

      const result = await saveHistory(encounterIdAtSchedule, {
        chiefComplaintEntries: cleanEntries, chiefComplaint: combinedText, chiefComplaintChips: combinedChips,
        hxDuration: cleanEntries[0]?.duration || '', hxLaterality: cleanEntries[0]?.laterality || '',
        hxHopi: hopi, ocularHistory: ocular, medicalHistory: medical, familyHistory: family,
        drugHistory, allergy, hxDrugAllergy: drugAllergy,
      });
      if (loadedEncounterId.current !== encounterIdAtSchedule) return; // encounter changed mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, AUTOSAVE_DELAY_MS);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [JSON.stringify(complaints), hopi, ocular, medical, family, drugHistory, allergy, drugAllergy]);

  return (
    <div>
      {/* OPTOMETRY FINDINGS -- see the "Optometry" tab for the full
          sheet and to record a correction. */}
      {!hideOptometryBanner && (
        <div className="card" style={{ marginBottom: 12, background: 'var(--g50)' }}>
          <div style={{ fontSize: 12, color: 'var(--g600)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i>
            {findings ? 'Optometry assessment on file for this visit.' : 'No optometry assessment on file for this visit.'}
            <span style={{ color: 'var(--g400)' }}>See the <strong>Optometry</strong> tab for the full sheet{findings ? ' and to record a correction' : ''}.</span>
          </div>
        </div>
      )}

      {/* CHIEF COMPLAINT -- one or more entries, each with its own
          complaint, duration, and laterality, so a patient with e.g.
          diminished vision OD and redness OS records (and prints)
          cleanly as two distinct complaints rather than one merged
          line. */}
      <div className="card" style={{ marginBottom: 12 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
          <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-message" style={{ color: 'var(--blue)' }}></i> Chief Complaint</div>
          <button type="button" className="btn btn-sm" onClick={addComplaint}><i className="ti ti-plus"></i> Add Complaint</button>
        </div>

        {optionsLoading && <span style={{ fontSize: 11, color: 'var(--g400)' }}>Loading options...</span>}

        {complaints.map((c, idx) => (
          <div
            key={c.id}
            style={{
              border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px',
              marginBottom: 10, background: complaints.length > 1 ? 'var(--g50)' : 'transparent',
            }}
          >
            {complaints.length > 1 && (
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                <span style={{
                  fontSize: 10, fontWeight: 700, color: '#fff', background: 'var(--blue)', borderRadius: 10,
                  padding: '2px 9px', letterSpacing: '.3px',
                }}>
                  COMPLAINT {idx + 1}
                </span>
                <span onClick={() => removeComplaint(c.id)} title="Remove this complaint" style={{ cursor: 'pointer', lineHeight: 0 }}>
                  <i className="ti ti-x" style={{ color: 'var(--red)' }}></i>
                </span>
              </div>
            )}

            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 8 }}>
              {options.chief_complaint.map((chip) => (
                <Chip key={chip} label={chip} selected={c.chips.includes(chip)} onClick={() => toggleComplaintChip(c.id, chip)} />
              ))}
            </div>
            <input
              className="fi fi-sm" style={{ marginBottom: 10 }} placeholder="Or type complaint..."
              value={c.text} onChange={(e) => updateComplaint(c.id, 'text', e.target.value)}
            />
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12 }}>
              <div>
                <label className="flbl">Duration</label>
                <input
                  className="fi fi-sm" value={c.duration} placeholder="e.g. 3 months"
                  onChange={(e) => updateComplaint(c.id, 'duration', e.target.value)}
                />
              </div>
              <div>
                <label className="flbl">Laterality</label>
                <select className="fi fi-sm" value={c.laterality} onChange={(e) => updateComplaint(c.id, 'laterality', e.target.value)}>
                  <option value="">--</option>
                  {LATERALITY_OPTIONS.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
                </select>
              </div>
            </div>
          </div>
        ))}

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

