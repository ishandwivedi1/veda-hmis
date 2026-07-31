'use client';

import { useState, useEffect, useRef } from 'react';
import { saveExamination } from '@/app/(main)/consultation/actions';

const EXT_STRUCTS = ['Lids', 'Adnexa', 'Lacrimal', 'Motility'];
const EXT_TEMPLATES = {
  Lids: ['Normal', 'Blepharitis', 'Ptosis', 'Entropion', 'Ectropion', 'Chalazion', 'Stye'],
  Adnexa: ['Normal', 'Swelling', 'Mass'],
  Lacrimal: ['Patent', 'Watering', 'Blocked', 'Dacryocystitis'],
  Motility: ['Full', 'Restriction', 'Squint', 'Nystagmus'],
};
const ANT_STRUCTS = ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'];
const ANT_TEMPLATES = {
  Conjunctiva: ['Normal', 'Congested', 'PCVO', 'Pterygium', 'Subconjunctival haemorrhage'],
  Cornea: ['Clear', 'Scar', 'Ulcer', 'Edema', 'Pterygium', 'Guttata', 'Keratitis'],
  'Anterior Chamber': ['Deep & Quiet', 'Shallow', 'Cells+', 'Hypopyon', 'Hyphema'],
  Iris: ['Normal Pattern', 'Rubeosis', 'Heterochromia', 'Synechiae'],
  Pupil: ['Round & Reactive', 'RAPD', 'Irregular', 'Fixed & Dilated'],
  Lens: ['Clear', 'NS1', 'NS2', 'NS3', 'NS4', 'PSC', 'Cortical', 'Mature', 'Hypermature', 'PCIOL', 'Aphakia'],
};

// Posterior Segment struct list differs by dilation stage: a full exam
// under dilation, but only Disc (+ a CDR estimate) makes sense to
// record without dilation.
const POST_STRUCTS_WITH = ['Vitreous', 'Disc', 'Macula', 'Vessels', 'Peripheral Retina'];
const POST_STRUCTS_WITHOUT = ['Disc', 'CDR'];
const POST_TEMPLATES = {
  Vitreous: ['Clear', 'Haze', 'Haemorrhage', 'PVD'],
  Disc: ['Healthy', 'Pale', 'Cupped', 'Swollen', 'Tilted'],
  Macula: ['Normal', 'ARMD', 'CSME', 'Macular Hole', 'Epiretinal Membrane', 'Scar'],
  Vessels: ['Normal', 'Arteriovenous nipping', 'Disc collaterals'],
  'Peripheral Retina': ['Attached', 'Lattice', 'Tear', 'Detachment', 'Laser Marks'],
  CDR: ['0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.7', '0.8', '0.9', 'GOA'],
};
// Structs rendered as a dropdown instead of the usual pill row.
const POST_SELECT_STRUCTS = ['CDR'];

const REGIONS = {
  external: { structs: EXT_STRUCTS, templates: EXT_TEMPLATES, icon: 'ti-user', color: 'var(--g400)', title: 'External Examination', staged: false },
  anterior: { structs: ANT_STRUCTS, templates: ANT_TEMPLATES, icon: 'ti-microscope', color: 'var(--teal)', title: 'Anterior Segment', staged: false },
  posterior: {
    structsByStage: { without: POST_STRUCTS_WITHOUT, with: POST_STRUCTS_WITH },
    templates: POST_TEMPLATES, selectStructs: POST_SELECT_STRUCTS,
    icon: 'ti-eye', color: 'var(--purple)', title: 'Posterior Segment', staged: true,
  },
};

// ── GONIOSCOPY (replaces the old Glaucoma section entirely) ──
const ANGLE_OPTIONS = ['Open Angle', 'Occludable', 'Closed Angle', 'Synechiae', 'Iris Process'];
const PTM_OPTIONS = ['+1', '+2', '+3'];
const IRIS_CONFIG_OPTIONS = ['Concave', 'Convex', 'Regular'];
const GONIO_FIELDS = [
  { key: 'angle', label: 'Angle Configuration', options: ANGLE_OPTIONS },
  { key: 'ptm', label: 'PTM Configuration', options: PTM_OPTIONS },
  { key: 'iris', label: 'Iris Configuration', options: IRIS_CONFIG_OPTIONS },
];
function emptyGonioStage() {
  const s = {};
  GONIO_FIELDS.forEach((f) => { s[`${f.key}_re`] = ''; s[`${f.key}_le`] = ''; s[`${f.key}_copy`] = false; });
  return s;
}
function emptyGonioState() {
  return { without: emptyGonioStage(), with: emptyGonioStage() };
}
function normalizeGonioStage(raw) {
  const s = emptyGonioStage();
  if (!raw) return s;
  GONIO_FIELDS.forEach((f) => {
    s[`${f.key}_re`] = raw[`${f.key}_re`] || '';
    s[`${f.key}_le`] = raw[`${f.key}_le`] || '';
    s[`${f.key}_copy`] = !!raw[`${f.key}_copy`];
  });
  return s;
}
function normalizeGonioFindings(raw) {
  const isStaged = raw && (raw.without || raw.with);
  if (isStaged) return { without: normalizeGonioStage(raw.without), with: normalizeGonioStage(raw.with) };
  // Nothing staged yet (brand new record) -- both passes start empty.
  return emptyGonioState();
}

const STAGES = [
  { key: 'without', label: 'Without Dilation' },
  { key: 'with', label: 'With Dilation' },
];

function emptyRegionState(structs) {
  const state = {};
  structs.forEach((s) => { state[s] = { re: '', le: '', re_custom: '', le_custom: '' }; });
  return state;
}

function normalizeFindings(raw, structs) {
  const out = {};
  structs.forEach((s) => {
    const v = raw?.[s] || {};
    out[s] = { re: v.re || '', le: v.le || '', re_custom: v.re_custom || '', le_custom: v.le_custom || '' };
  });
  return out;
}

// External & Anterior are a single pass now (no dilation stage). Some
// records saved while this was still staged have {without, with} --
// read "without" first (it was always the primary/first pass), and
// otherwise fall back to "with" so nothing already recorded is lost.
// New saves are written flat going forward.
function normalizeFlatFindings(raw, structs) {
  const source = raw && (raw.without || raw.with) ? (raw.without || raw.with) : raw;
  return { ...emptyRegionState(structs), ...normalizeFindings(source, structs) };
}

// Posterior Segment keeps the two-pass without/with dilation split, but
// the struct list differs per stage (see structsByStage). Legacy flat
// data (from before staging existed) used the full struct set, so it's
// treated as the "with dilation" pass -- mapping it to "without"
// (Disc/CDR only) would silently drop Vitreous/Macula/Vessels/Periphery.
function emptyStagedRegionState(structsByStage) {
  return { without: emptyRegionState(structsByStage.without), with: emptyRegionState(structsByStage.with) };
}
function normalizeStagedFindings(raw, structsByStage) {
  const isStaged = raw && (raw.without || raw.with);
  if (isStaged) {
    return {
      without: { ...emptyRegionState(structsByStage.without), ...normalizeFindings(raw.without, structsByStage.without) },
      with: { ...emptyRegionState(structsByStage.with), ...normalizeFindings(raw.with, structsByStage.with) },
    };
  }
  return {
    without: emptyRegionState(structsByStage.without),
    with: { ...emptyRegionState(structsByStage.with), ...normalizeFindings(raw, structsByStage.with) },
  };
}

function StructRow({ struct, templates, eyeState, onSelect, onCustom, asSelect }) {
  const options = templates[struct] || [];

  if (asSelect) {
    return (
      <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr', gap: 8, alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
        <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{struct}</div>
        <select className="fi fi-sm" style={{ maxWidth: 160 }} value={eyeState.value} onChange={(e) => onSelect(e.target.value)}>
          <option value="">--</option>
          {options.map((opt) => <option key={opt} value={opt}>{opt}</option>)}
        </select>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr', gap: 8, alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{struct}</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center' }}>
        {options.map((opt) => (
          <div
            key={opt}
            onClick={() => onSelect(opt)}
            style={{
              padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
              border: `1.5px solid ${eyeState.value === opt ? 'var(--blue)' : 'var(--g200)'}`,
              background: eyeState.value === opt ? 'var(--blue)' : '#fff',
              color: eyeState.value === opt ? '#fff' : 'var(--g600)',
            }}
          >
            {opt}
          </div>
        ))}
        <input
          type="text"
          className="fi fi-sm"
          style={{ width: 100 }}
          placeholder="Custom..."
          value={eyeState.custom}
          onChange={(e) => onCustom(e.target.value)}
        />
      </div>
    </div>
  );
}

function StageToggle({ stage, onChange }) {
  return (
    <div style={{ display: 'flex', gap: 2, background: 'var(--g100)', borderRadius: 6, padding: 2 }} onClick={(e) => e.stopPropagation()}>
      {STAGES.map((s) => (
        <button
          key={s.key}
          type="button"
          onClick={() => onChange(s.key)}
          style={{
            padding: '3px 9px', borderRadius: 4, fontSize: 10.5, fontWeight: 600, border: 'none', cursor: 'pointer',
            background: stage === s.key ? '#fff' : 'transparent',
            color: stage === s.key ? 'var(--blue)' : 'var(--g500)',
            boxShadow: stage === s.key ? '0 1px 3px rgba(0,0,0,.1)' : 'none',
          }}
        >
          {s.label}
        </button>
      ))}
    </div>
  );
}

function RegionSection({ regionKey, region, open, onToggle, status, stagedState, stage, onStageChange, onSelect, onCustom, onAllNormal, allNormalOn }) {
  const staged = region.staged;
  const state = staged ? stagedState[stage] : stagedState;
  const structs = staged ? region.structsByStage[stage] : region.structs;
  const selectStructs = region.selectStructs || [];

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', flexWrap: 'wrap', gap: 8 }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className={`ti ${region.icon}`} style={{ color: region.color }}></i>
          {region.title}
          <span className={`badge ${status === 'Normal' ? 'b-green' : status === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          {staged && <StageToggle stage={stage} onChange={onStageChange} />}
          <button
            type="button"
            className="btn btn-sm"
            style={{ background: allNormalOn ? 'var(--green)' : '#fff', color: allNormalOn ? '#fff' : 'var(--green)', border: '1.5px solid var(--green)' }}
            onClick={(e) => { e.stopPropagation(); onAllNormal(); }}
          >
            <i className={`ti ti-${allNormalOn ? 'square-check' : 'square'}`}></i> All Normal
          </button>
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && (
        <div style={{ padding: 16, background: staged && stage === 'with' ? 'var(--purple-lt)' : '#fff', transition: 'background .15s ease' }}>
          {staged && (
            <div style={{ fontSize: 11, fontWeight: 700, color: stage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 10 }}>
              <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === stage)?.label}
            </div>
          )}
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            {['re', 'le'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 11, fontWeight: 700, color: eye === 're' ? 'var(--blue)' : 'var(--teal)', marginBottom: 6, padding: '4px 8px', background: eye === 're' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 6, display: 'inline-block' }}>
                  <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {eye === 're' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {structs.map((struct) => (
                  <StructRow
                    key={struct}
                    struct={struct}
                    templates={region.templates}
                    asSelect={selectStructs.includes(struct)}
                    eyeState={{ value: state[struct]?.[eye] || '', custom: state[struct]?.[`${eye}_custom`] || '' }}
                    onSelect={(val) => onSelect(struct, eye, val)}
                    onCustom={(val) => onCustom(struct, eye, val)}
                  />
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

export default function ExaminationTab({ examination, encounterId, onSaved }) {
  const [regionState, setRegionState] = useState({
    external: emptyRegionState(EXT_STRUCTS),
    anterior: emptyRegionState(ANT_STRUCTS),
    posterior: emptyStagedRegionState(REGIONS.posterior.structsByStage),
  });
  const [regionStage, setRegionStage] = useState({ posterior: 'without' });
  const [status, setStatus] = useState({ external: 'Not started', anterior: 'Not started', posterior: 'Not started', gonioscopy: 'Not started' });
  const [open, setOpen] = useState({ external: true, anterior: false, posterior: false, gonioscopy: false, remarks: false });
  // Tracks whether "All Normal" is currently toggled on, so it can be
  // unticked (reverts fields to empty) instead of being a one-way action.
  // External/Anterior: one flag. Posterior: one per stage, since Without
  // and With Dilation are recorded and toggled independently.
  const [allNormalOn, setAllNormalOn] = useState({ external: false, anterior: false, posterior: { without: false, with: false } });

  const [gonioStage, setGonioStage] = useState('without');
  const [gonioState, setGonioState] = useState(emptyGonioState());
  const [remarksRe, setRemarksRe] = useState('');
  const [remarksLe, setRemarksLe] = useState('');

  // 'idle' | 'pending' | 'saving' | 'saved' | 'error'
  const [saveState, setSaveState] = useState('idle');
  const saveTimer = useRef(null);
  const skipNextAutosave = useRef(true);
  const loadedExamId = useRef(null);

  useEffect(() => {
    if (!examination) return;
    skipNextAutosave.current = true;
    loadedExamId.current = examination.id;
    setRegionState({
      external: normalizeFlatFindings(examination.external_findings, EXT_STRUCTS),
      anterior: normalizeFlatFindings(examination.anterior_findings, ANT_STRUCTS),
      posterior: normalizeStagedFindings(examination.posterior_findings, REGIONS.posterior.structsByStage),
    });
    setStatus({
      external: examination.external_status || 'Not started',
      anterior: examination.anterior_status || 'Not started',
      posterior: examination.posterior_status || 'Not started',
      gonioscopy: examination.glaucoma_status || 'Not started',
    });
    setGonioState(normalizeGonioFindings(examination.gonioscopy_findings));
    setRemarksRe(examination.remarks_re || '');
    setRemarksLe(examination.remarks_le || '');
  }, [examination]);

  function markDirty(region) {
    setStatus((prev) => (prev[region] === 'Not started' ? { ...prev, [region]: 'In progress' } : prev));
  }

  function handleSelect(region, struct, eye, val) {
    setRegionState((prev) => {
      if (!REGIONS[region].staged) {
        return { ...prev, [region]: { ...prev[region], [struct]: { ...prev[region][struct], [eye]: val } } };
      }
      const stage = regionStage[region];
      return { ...prev, [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [eye]: val } } } };
    });
    markDirty(region);
  }

  function handleCustom(region, struct, eye, val) {
    setRegionState((prev) => {
      if (!REGIONS[region].staged) {
        return { ...prev, [region]: { ...prev[region], [struct]: { ...prev[region][struct], [`${eye}_custom`]: val } } };
      }
      const stage = regionStage[region];
      return { ...prev, [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [`${eye}_custom`]: val } } } };
    });
    markDirty(region);
  }

  // Toggle -- clicking again unticks it: fields clear back to empty and
  // status reverts to Not started, rather than being a one-way action.
  function handleAllNormal(region) {
    const { templates, staged } = REGIONS[region];
    const stage = staged ? regionStage[region] : null;
    const structs = staged ? REGIONS[region].structsByStage[stage] : REGIONS[region].structs;
    const isOn = staged ? allNormalOn[region][stage] : allNormalOn[region];

    let next;
    if (isOn) {
      next = emptyRegionState(structs);
    } else {
      next = {};
      structs.forEach((s) => {
        // CDR has no sensible "normal" default (it's a measured ratio),
        // so All Normal skips it and leaves it for the doctor to enter.
        const normalVal = (REGIONS.posterior.selectStructs || []).includes(s) ? '' : (templates[s]?.[0] || '');
        next[s] = { re: normalVal, le: normalVal, re_custom: '', le_custom: '' };
      });
    }

    setRegionState((prev) => (staged
      ? { ...prev, [region]: { ...prev[region], [stage]: next } }
      : { ...prev, [region]: next }));
    setStatus((prev) => ({ ...prev, [region]: isOn ? 'Not started' : 'Normal' }));
    setAllNormalOn((prev) => (staged
      ? { ...prev, [region]: { ...prev[region], [stage]: !isOn } }
      : { ...prev, [region]: !isOn }));
  }

  function applyFavorite(fav) {
    if (fav === 'normal') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); }
    else if (fav === 'cataract') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); setOpen((p) => ({ ...p, anterior: true })); }
    else if (fav === 'glaucoma') { setOpen((p) => ({ ...p, gonioscopy: true })); }
    else if (fav === 'postop') { handleAllNormal('anterior'); handleAllNormal('posterior'); }
  }

  // Autosave: debounced ~1.2s after the last change to any field. No
  // Save button -- this is the only way examination findings get
  // written.
  useEffect(() => {
    if (!examination) return;
    if (skipNextAutosave.current) { skipNextAutosave.current = false; return; }

    setSaveState('pending');
    if (saveTimer.current) clearTimeout(saveTimer.current);
    const examIdAtSchedule = examination.id;

    saveTimer.current = setTimeout(async () => {
      setSaveState('saving');
      const gonioHasData = ['without', 'with'].some((st) => GONIO_FIELDS.some((f) => gonioState[st][`${f.key}_re`] || gonioState[st][`${f.key}_le`]));
      const fields = {
        external_findings: regionState.external,
        external_status: status.external,
        anterior_findings: regionState.anterior,
        anterior_status: status.anterior,
        posterior_findings: regionState.posterior,
        posterior_status: status.posterior,
        gonioscopy_findings: gonioState,
        glaucoma_status: gonioHasData ? 'Done' : status.gonioscopy,
        remarks_re: remarksRe, remarks_le: remarksLe,
      };
      const result = await saveExamination(examIdAtSchedule, encounterId, fields);
      if (loadedExamId.current !== examIdAtSchedule) return; // switched encounters mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, 1200);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [regionState, status, gonioState, remarksRe, remarksLe]);

  // Live-mirrors RE into LE while "Copy RE Value to LE" is checked for
  // that field, same pattern as the Optometry Refraction section.
  function setGonioField(fieldKey, eye, val) {
    setGonioState((prev) => {
      const stageState = { ...prev[gonioStage], [`${fieldKey}_${eye}`]: val };
      if (eye === 're' && prev[gonioStage][`${fieldKey}_copy`]) {
        stageState[`${fieldKey}_le`] = val;
      }
      return { ...prev, [gonioStage]: stageState };
    });
    markDirty('gonioscopy');
  }

  function toggleGonioCopy(fieldKey, checked) {
    setGonioState((prev) => {
      const stageState = { ...prev[gonioStage], [`${fieldKey}_copy`]: checked };
      if (checked) stageState[`${fieldKey}_le`] = prev[gonioStage][`${fieldKey}_re`];
      return { ...prev, [gonioStage]: stageState };
    });
  }

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Exception-based documentation. Click <strong>All Normal</strong> to auto-populate normal findings, then change only what&apos;s abnormal (click it again to untick and clear back to empty). Posterior Segment is recorded in two passes -- <strong>Without Dilation</strong> (Disc + CDR only) and <strong>With Dilation</strong> (full segment) -- switch using the toggle in its header.
      </div>

      <div className="card" style={{ padding: '10px 14px', marginBottom: 12 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>Favorites</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('normal')}><i className="ti ti-star"></i> Normal Routine</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('cataract')}><i className="ti ti-eye"></i> Routine Cataract</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('glaucoma')}><i className="ti ti-activity"></i> Gonioscopy Follow-up</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('postop')}><i className="ti ti-calendar-check"></i> Post-op Review</button>
        </div>
      </div>

      {['external', 'anterior', 'posterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          stagedState={regionState[key]}
          stage={regionStage[key]}
          onStageChange={(stage) => setRegionStage((p) => ({ ...p, [key]: stage }))}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
          allNormalOn={REGIONS[key].staged ? allNormalOn[key][regionStage[key]] : allNormalOn[key]}
        />
      ))}

      {/* GONIOSCOPY (formerly "Glaucoma Assessment") -- Angle / PTM / Iris
          Configuration, each split RE and LE with a Copy RE to LE option.
          No "All Normal" (not exception-based). */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.gonioscopy ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', flexWrap: 'wrap', gap: 8 }} onClick={() => setOpen((p) => ({ ...p, gonioscopy: !p.gonioscopy }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-activity" style={{ color: 'var(--amber)' }}></i> Gonioscopy
            <span className={`badge ${status.gonioscopy === 'Done' ? 'b-green' : status.gonioscopy === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status.gonioscopy}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <StageToggle stage={gonioStage} onChange={setGonioStage} />
            <i className={`ti ti-chevron-${open.gonioscopy ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
          </div>
        </div>
        {open.gonioscopy && (
          <div style={{ padding: 16, background: gonioStage === 'with' ? 'var(--purple-lt)' : '#fff', transition: 'background .15s ease' }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: gonioStage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 14 }}>
              <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === gonioStage)?.label}
            </div>
            {GONIO_FIELDS.map((f) => {
              const stageState = gonioState[gonioStage];
              const copying = stageState[`${f.key}_copy`];
              return (
                <div key={f.key} style={{ marginBottom: 18, paddingBottom: 16, borderBottom: '1px solid var(--g100)' }}>
                  <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g700)', marginBottom: 8 }}>{f.label}</div>
                  <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 8 }}>
                    {[['re', 'RE -- Oculus Dexter (OD)'], ['le', 'LE -- Oculus Sinister (OS)']].map(([eye, label]) => (
                      <div key={eye}>
                        <label className="flbl">{label}</label>
                        <select
                          className="fi fi-sm"
                          disabled={eye === 'le' && copying}
                          value={stageState[`${f.key}_${eye}`]}
                          onChange={(e) => setGonioField(f.key, eye, e.target.value)}
                        >
                          <option value="">--</option>
                          {f.options.map((opt) => <option key={opt} value={opt}>{opt}</option>)}
                        </select>
                      </div>
                    ))}
                  </div>
                  <label style={{ display: 'flex', alignItems: 'center', gap: 6, fontSize: 11.5, fontWeight: 600, color: 'var(--g600)', cursor: 'pointer' }}>
                    <input type="checkbox" checked={copying} onChange={(e) => toggleGonioCopy(f.key, e.target.checked)} />
                    Copy RE Value to LE
                  </label>
                </div>
              );
            })}
          </div>
        )}
      </div>

      {/* CLINICAL REMARKS -- stays a single entry, not split by dilation stage */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.remarks ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setOpen((p) => ({ ...p, remarks: !p.remarks }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Clinical Remarks
          </div>
          <i className={`ti ti-chevron-${open.remarks ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
        {open.remarks && (
          <div style={{ padding: 16 }}>
            <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-alert-triangle"></i> Remarks supplement structured findings, they do not replace them.
            </div>
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Right Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksRe} onChange={(e) => setRemarksRe(e.target.value)} placeholder="Additional observations for RE..." />
            </div>
            <div>
              <label className="flbl">Left Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksLe} onChange={(e) => setRemarksLe(e.target.value)} placeholder="Additional observations for LE..." />
            </div>
          </div>
        )}
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

