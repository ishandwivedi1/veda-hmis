#!/bin/bash
set -e
echo "Re-applying: Examination tab autosave (no Save button) -- confirming latest version is live"

cat > "app/consultation/[id]/examination-tab.js" << 'PYEOF_EXAM'
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

function emptyRegionState(structs) {
  const state = {};
  structs.forEach((s) => { state[s] = { re: '', le: '', re_custom: '', le_custom: '' }; });
  return state;
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

function RegionSection({ regionKey, region, open, onToggle, status, state, onSelect, onCustom, onAllNormal }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className={`ti ${region.icon}`} style={{ color: region.color }}></i>
          {region.title}
          <span className={`badge ${status === 'Normal' ? 'b-green' : status === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={(e) => { e.stopPropagation(); onAllNormal(); }}>
            <i className="ti ti-check"></i> All Normal
          </button>
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && (
        <div style={{ padding: 16 }}>
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
    external: emptyRegionState(EXT_STRUCTS),
    anterior: emptyRegionState(ANT_STRUCTS),
    posterior: emptyRegionState(POST_STRUCTS),
  });
  const [status, setStatus] = useState({ external: 'Not started', anterior: 'Not started', posterior: 'Not started', glaucoma: 'Not started' });
  const [open, setOpen] = useState({ external: true, anterior: false, glaucoma: false, posterior: false, remarks: false });

  const [cdrRe, setCdrRe] = useState('');
  const [cdrLe, setCdrLe] = useState('');
  const [gonioRe, setGonioRe] = useState('');
  const [gonioLe, setGonioLe] = useState('');
  const [discAppearance, setDiscAppearance] = useState('');
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
      external: { ...emptyRegionState(EXT_STRUCTS), ...normalizeFindings(examination.external_findings, EXT_STRUCTS) },
      anterior: { ...emptyRegionState(ANT_STRUCTS), ...normalizeFindings(examination.anterior_findings, ANT_STRUCTS) },
      posterior: { ...emptyRegionState(POST_STRUCTS), ...normalizeFindings(examination.posterior_findings, POST_STRUCTS) },
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
    setRemarksRe(examination.remarks_re || '');
    setRemarksLe(examination.remarks_le || '');
  }, [examination]);

  function normalizeFindings(raw, structs) {
    const out = {};
    structs.forEach((s) => {
      const v = raw?.[s] || {};
      out[s] = { re: v.re || '', le: v.le || '', re_custom: v.re_custom || '', le_custom: v.le_custom || '' };
    });
    return out;
  }

  function markDirty(region) {
    setStatus((prev) => (prev[region] === 'Not started' ? { ...prev, [region]: 'In progress' } : prev));
  }

  function handleSelect(region, struct, eye, val) {
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [struct]: { ...prev[region][struct], [eye]: val } },
    }));
    markDirty(region);
  }

  function handleCustom(region, struct, eye, val) {
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [struct]: { ...prev[region][struct], [`${eye}_custom`]: val } },
    }));
    markDirty(region);
  }

  function handleAllNormal(region) {
    const { structs, templates } = REGIONS[region];
    const next = {};
    structs.forEach((s) => {
      const normalVal = templates[s]?.[0] || '';
      next[s] = { re: normalVal, le: normalVal, re_custom: '', le_custom: '' };
    });
    setRegionState((prev) => ({ ...prev, [region]: next }));
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
        glaucoma_status: (cdrRe || cdrLe || gonioRe || gonioLe || discAppearance) ? 'Done' : status.glaucoma,
        remarks_re: remarksRe, remarks_le: remarksLe,
      };
      const result = await saveExamination(examIdAtSchedule, encounterId, fields);
      if (loadedExamId.current !== examIdAtSchedule) return; // switched encounters mid-flight
      setSaveState(result.error ? 'error' : 'saved');
      if (!result.error && onSaved) onSaved();
    }, 1200);

    return () => clearTimeout(saveTimer.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [regionState, status, cdrRe, cdrLe, gonioRe, gonioLe, discAppearance, remarksRe, remarksLe]);

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Exception-based documentation. Click <strong>All Normal</strong> to auto-populate normal findings, then change only what&apos;s abnormal.
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

      {['external', 'anterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          state={regionState[key]}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
        />
      ))}

      {/* GLAUCOMA -- no "All Normal" (not exception-based) */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.glaucoma ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setOpen((p) => ({ ...p, glaucoma: !p.glaucoma }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-activity" style={{ color: 'var(--amber)' }}></i> Glaucoma Assessment
            <span className={`badge ${status.glaucoma === 'Done' ? 'b-green' : status.glaucoma === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status.glaucoma}</span>
          </div>
          <i className={`ti ti-chevron-${open.glaucoma ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
        {open.glaucoma && (
          <div style={{ padding: 16 }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div><label className="flbl">Cup-disc ratio RE</label><input className="fi fi-sm" value={cdrRe} onChange={(e) => { setCdrRe(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
              <div><label className="flbl">Cup-disc ratio LE</label><input className="fi fi-sm" value={cdrLe} onChange={(e) => { setCdrLe(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              {[['RE', gonioRe, setGonioRe], ['LE', gonioLe, setGonioLe]].map(([eye, val, setVal]) => (
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
              <input className="fi fi-sm" value={discAppearance} onChange={(e) => { setDiscAppearance(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. Healthy, Pale, Cupped" />
            </div>
          </div>
        )}
      </div>

      {['posterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          state={regionState[key]}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
        />
      ))}

      {/* CLINICAL REMARKS */}
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

PYEOF_EXAM

echo "File written. Run: npm run build"
