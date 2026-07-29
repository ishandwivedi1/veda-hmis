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
const POST_STRUCTS = ['Vitreous', 'Disc', 'Macula', 'Vessels', 'Peripheral Retina'];
const POST_TEMPLATES = {
  Vitreous: ['Clear', 'Haze', 'Haemorrhage', 'PVD'],
  Disc: ['Healthy', 'Pale', 'Cupped', 'Swollen', 'Tilted'],
  Macula: ['Normal', 'ARMD', 'CSME', 'Macular Hole', 'Epiretinal Membrane', 'Scar'],
  Vessels: ['Normal', 'Arteriovenous nipping', 'Disc collaterals'],
  'Peripheral Retina': ['Attached', 'Lattice', 'Tear', 'Detachment', 'Laser Marks'],
};
const GONIO_TEMPLATES = ['Open Angle', 'Narrow Angle', 'Closed Angle', 'Synechiae'];

const REGIONS = {
  external: { structs: EXT_STRUCTS, templates: EXT_TEMPLATES, icon: 'ti-user', color: 'var(--g400)', title: 'External Examination' },
  anterior: { structs: ANT_STRUCTS, templates: ANT_TEMPLATES, icon: 'ti-microscope', color: 'var(--teal)', title: 'Anterior Segment' },
  posterior: { structs: POST_STRUCTS, templates: POST_TEMPLATES, icon: 'ti-eye', color: 'var(--purple)', title: 'Posterior Segment' },
};

const STAGES = [
  { key: 'without', label: 'Without Dilation' },
  { key: 'with', label: 'With Dilation' },
];

function emptyRegionState(structs) {
  const state = {};
  structs.forEach((s) => { state[s] = { re: '', le: '', re_custom: '', le_custom: '' }; });
  return state;
}

function emptyStagedRegionState(structs) {
  return { without: emptyRegionState(structs), with: emptyRegionState(structs) };
}

function normalizeFindings(raw, structs) {
  const out = {};
  structs.forEach((s) => {
    const v = raw?.[s] || {};
    out[s] = { re: v.re || '', le: v.le || '', re_custom: v.re_custom || '', le_custom: v.le_custom || '' };
  });
  return out;
}

// Examination used to be one pass. Existing saved records have findings
// as a flat {struct: {...}} object with no stage. Old data is treated
// as the "without dilation" pass (the pass that always happens first),
// with "with dilation" starting empty -- nothing is lost, it just now
// has somewhere to go for the second pass.
function normalizeStagedFindings(raw, structs) {
  const isStaged = raw && (raw.without || raw.with);
  if (isStaged) {
    return {
      without: { ...emptyRegionState(structs), ...normalizeFindings(raw.without, structs) },
      with: { ...emptyRegionState(structs), ...normalizeFindings(raw.with, structs) },
    };
  }
  return {
    without: { ...emptyRegionState(structs), ...normalizeFindings(raw, structs) },
    with: emptyRegionState(structs),
  };
}

function StructRow({ struct, templates, eyeState, onSelect, onCustom }) {
  const options = templates[struct] || [];
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

function RegionSection({ regionKey, region, open, onToggle, status, stagedState, stage, onStageChange, onSelect, onCustom, onAllNormal }) {
  const state = stagedState[stage];
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
          <StageToggle stage={stage} onChange={onStageChange} />
          <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={(e) => { e.stopPropagation(); onAllNormal(); }}>
            <i className="ti ti-check"></i> All Normal
          </button>
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && (
        <div style={{ padding: 16 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: stage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 10 }}>
            <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === stage)?.label}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            {['re', 'le'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 11, fontWeight: 700, color: eye === 're' ? 'var(--blue)' : 'var(--teal)', marginBottom: 6, padding: '4px 8px', background: eye === 're' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 6, display: 'inline-block' }}>
                  <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {eye === 're' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {region.structs.map((struct) => (
                  <StructRow
                    key={struct}
                    struct={struct}
                    templates={region.templates}
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
    external: emptyStagedRegionState(EXT_STRUCTS),
    anterior: emptyStagedRegionState(ANT_STRUCTS),
    posterior: emptyStagedRegionState(POST_STRUCTS),
  });
  const [regionStage, setRegionStage] = useState({ external: 'without', anterior: 'without', posterior: 'without' });
  const [status, setStatus] = useState({ external: 'Not started', anterior: 'Not started', posterior: 'Not started', glaucoma: 'Not started' });
  const [open, setOpen] = useState({ external: true, anterior: false, posterior: false, glaucoma: false, remarks: false });

  const [glaucomaStage, setGlaucomaStage] = useState('without');
  const [cdrRe, setCdrRe] = useState('');
  const [cdrLe, setCdrLe] = useState('');
  const [gonioRe, setGonioRe] = useState('');
  const [gonioLe, setGonioLe] = useState('');
  const [discAppearance, setDiscAppearance] = useState('');
  const [cdrReDilated, setCdrReDilated] = useState('');
  const [cdrLeDilated, setCdrLeDilated] = useState('');
  const [gonioReDilated, setGonioReDilated] = useState('');
  const [gonioLeDilated, setGonioLeDilated] = useState('');
  const [discAppearanceDilated, setDiscAppearanceDilated] = useState('');
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
      external: normalizeStagedFindings(examination.external_findings, EXT_STRUCTS),
      anterior: normalizeStagedFindings(examination.anterior_findings, ANT_STRUCTS),
      posterior: normalizeStagedFindings(examination.posterior_findings, POST_STRUCTS),
    });
    setStatus({
      external: examination.external_status || 'Not started',
      anterior: examination.anterior_status || 'Not started',
      posterior: examination.posterior_status || 'Not started',
      glaucoma: examination.glaucoma_status || 'Not started',
    });
    setCdrRe(examination.cdr_re || '');
    setCdrLe(examination.cdr_le || '');
    setGonioRe(examination.gonio_re || '');
    setGonioLe(examination.gonio_le || '');
    setDiscAppearance(examination.disc_appearance || '');
    setCdrReDilated(examination.cdr_re_dilated || '');
    setCdrLeDilated(examination.cdr_le_dilated || '');
    setGonioReDilated(examination.gonio_re_dilated || '');
    setGonioLeDilated(examination.gonio_le_dilated || '');
    setDiscAppearanceDilated(examination.disc_appearance_dilated || '');
    setRemarksRe(examination.remarks_re || '');
    setRemarksLe(examination.remarks_le || '');
  }, [examination]);

  function markDirty(region) {
    setStatus((prev) => (prev[region] === 'Not started' ? { ...prev, [region]: 'In progress' } : prev));
  }

  function handleSelect(region, struct, eye, val) {
    const stage = regionStage[region];
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [eye]: val } } },
    }));
    markDirty(region);
  }

  function handleCustom(region, struct, eye, val) {
    const stage = regionStage[region];
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [stage]: { ...prev[region][stage], [struct]: { ...prev[region][stage][struct], [`${eye}_custom`]: val } } },
    }));
    markDirty(region);
  }

  function handleAllNormal(region) {
    const { structs, templates } = REGIONS[region];
    const stage = regionStage[region];
    const next = {};
    structs.forEach((s) => {
      const normalVal = templates[s]?.[0] || '';
      next[s] = { re: normalVal, le: normalVal, re_custom: '', le_custom: '' };
    });
    setRegionState((prev) => ({ ...prev, [region]: { ...prev[region], [stage]: next } }));
    setStatus((prev) => ({ ...prev, [region]: 'Normal' }));
  }

  function applyFavorite(fav) {
    if (fav === 'normal') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); }
    else if (fav === 'cataract') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); setOpen((p) => ({ ...p, anterior: true })); }
    else if (fav === 'glaucoma') { setOpen((p) => ({ ...p, glaucoma: true })); }
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
      const fields = {
        external_findings: regionState.external,
        external_status: status.external,
        anterior_findings: regionState.anterior,
        anterior_status: status.anterior,
        posterior_findings: regionState.posterior,
        posterior_status: status.posterior,
        cdr_re: cdrRe, cdr_le: cdrLe, gonio_re: gonioRe, gonio_le: gonioLe, disc_appearance: discAppearance,
        cdr_re_dilated: cdrReDilated, cdr_le_dilated: cdrLeDilated, gonio_re_dilated: gonioReDilated, gonio_le_dilated: gonioLeDilated, disc_appearance_dilated: discAppearanceDilated,
        glaucoma_status: (cdrRe || cdrLe || gonioRe || gonioLe || discAppearance || cdrReDilated || cdrLeDilated || gonioReDilated || gonioLeDilated || discAppearanceDilated) ? 'Done' : status.glaucoma,
        remarks_re: remarksRe, remarks_le: remarksLe,
      };
      const result = await saveExamination(examIdAtSchedule, encounterId, fields);
      if (loadedExamId.current !== examIdAtSchedule) return; // switched encounters mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, 1200);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [regionState, status, cdrRe, cdrLe, gonioRe, gonioLe, discAppearance, cdrReDilated, cdrLeDilated, gonioReDilated, gonioLeDilated, discAppearanceDilated, remarksRe, remarksLe]);

  const glaucomaFieldsForStage = glaucomaStage === 'with'
    ? { cdrReVal: cdrReDilated, cdrLeVal: cdrLeDilated, gonioReVal: gonioReDilated, gonioLeVal: gonioLeDilated, discVal: discAppearanceDilated, setCdrReVal: setCdrReDilated, setCdrLeVal: setCdrLeDilated, setGonioReVal: setGonioReDilated, setGonioLeVal: setGonioLeDilated, setDiscVal: setDiscAppearanceDilated }
    : { cdrReVal: cdrRe, cdrLeVal: cdrLe, gonioReVal: gonioRe, gonioLeVal: gonioLe, discVal: discAppearance, setCdrReVal: setCdrRe, setCdrLeVal: setCdrLe, setGonioReVal: setGonioRe, setGonioLeVal: setGonioLe, setDiscVal: setDiscAppearance };
  const { cdrReVal, cdrLeVal, gonioReVal, gonioLeVal, discVal, setCdrReVal, setCdrLeVal, setGonioReVal, setGonioLeVal, setDiscVal } = glaucomaFieldsForStage;

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Exception-based documentation. Click <strong>All Normal</strong> to auto-populate normal findings, then change only what&apos;s abnormal. Each section is recorded in two passes -- <strong>Without Dilation</strong> and <strong>With Dilation</strong> -- switch using the toggle in each section&apos;s header.
      </div>

      <div className="card" style={{ padding: '10px 14px', marginBottom: 12 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>Favorites</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('normal')}><i className="ti ti-star"></i> Normal Routine</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('cataract')}><i className="ti ti-eye"></i> Routine Cataract</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('glaucoma')}><i className="ti ti-activity"></i> Glaucoma Follow-up</button>
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
        />
      ))}

      {/* GLAUCOMA -- moved to appear after Posterior Segment. No "All Normal" (not exception-based) */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.glaucoma ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer', flexWrap: 'wrap', gap: 8 }} onClick={() => setOpen((p) => ({ ...p, glaucoma: !p.glaucoma }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-activity" style={{ color: 'var(--amber)' }}></i> Glaucoma Assessment
            <span className={`badge ${status.glaucoma === 'Done' ? 'b-green' : status.glaucoma === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status.glaucoma}</span>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
            <StageToggle stage={glaucomaStage} onChange={setGlaucomaStage} />
            <i className={`ti ti-chevron-${open.glaucoma ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
          </div>
        </div>
        {open.glaucoma && (
          <div style={{ padding: 16 }}>
            <div style={{ fontSize: 11, fontWeight: 700, color: glaucomaStage === 'with' ? 'var(--purple)' : 'var(--g500)', marginBottom: 10 }}>
              <i className="ti ti-droplet"></i> Recording: {STAGES.find((s) => s.key === glaucomaStage)?.label}
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div><label className="flbl">Cup-disc ratio RE</label><input className="fi fi-sm" value={cdrReVal} onChange={(e) => { setCdrReVal(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
              <div><label className="flbl">Cup-disc ratio LE</label><input className="fi fi-sm" value={cdrLeVal} onChange={(e) => { setCdrLeVal(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              {[['RE', gonioReVal, setGonioReVal], ['LE', gonioLeVal, setGonioLeVal]].map(([eye, val, setVal]) => (
                <div key={eye}>
                  <label className="flbl">Gonioscopy {eye}</label>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                    {GONIO_TEMPLATES.map((opt) => (
                      <div
                        key={opt}
                        onClick={() => { setVal(opt); markDirty('glaucoma'); }}
                        style={{ padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${val === opt ? 'var(--blue)' : 'var(--g200)'}`, background: val === opt ? 'var(--blue)' : '#fff', color: val === opt ? '#fff' : 'var(--g600)' }}
                      >
                        {opt}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
            <div>
              <label className="flbl">Disc appearance</label>
              <input className="fi fi-sm" value={discVal} onChange={(e) => { setDiscVal(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. Healthy, Pale, Cupped" />
            </div>
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
