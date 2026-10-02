'use client';

// Clinical Masters > Examination Options
// Manages the pill/dropdown options shown in the doctor's Examination tab
// (app/consultation/[id]/examination-tab.js). Structures themselves
// (Conjunctiva, Cornea, Disc...) are fixed; only their options are edited
// here. The first ACTIVE option of each structure is what "All Normal"
// fills in, so order matters -- use the arrows to change it.

import { useState, useEffect, useCallback } from 'react';
import { addExamOption, updateExamOption, deleteExamOption, moveExamOption, toggleStatus } from '../actions';
import { getExamOptions } from '@/lib/rpc-reads/master-data__actions'; // parallel reads (tools/parallel-reads)

export const EXAM_SECTIONS = [
  { key: 'external', label: 'External Examination', structures: ['Lids', 'Adnexa', 'Lacrimal', 'Motility'] },
  { key: 'anterior', label: 'Anterior Segment', structures: ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'] },
  { key: 'posterior', label: 'Posterior Segment', structures: ['Vitreous', 'Disc', 'CDR', 'Macula', 'Vessels', 'Peripheral Retina'] },
  { key: 'gonioscopy', label: 'Gonioscopy', structures: ['Angle Configuration', 'PTM Pigmentation', 'Iris Configuration'] },
];

// Structures where the first option is NOT used as an "All Normal"
// default: CDR is a measured ratio, and Gonioscopy has no All Normal.
function hasNormalDefault(section, structure) {
  return section !== 'gonioscopy' && structure !== 'CDR';
}

const STRUCT_NOTE = {
  Disc: 'Shown in both Without and With Dilatation.',
  CDR: 'Shown as a dropdown (C.D Ratio).',
};

export default function ExamOptionsTab() {
  const [section, setSection] = useState('anterior');
  const [structure, setStructure] = useState('Conjunctiva');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [newName, setNewName] = useState('');
  const [editingId, setEditingId] = useState(null);
  const [editName, setEditName] = useState('');

  const refresh = useCallback(async () => {
    const data = await getExamOptions();
    setRows(data || []);
    setLoading(false);
  }, []);
  useEffect(() => { refresh(); }, [refresh]);

  const sectionCfg = EXAM_SECTIONS.find((s) => s.key === section);
  const list = rows
    .filter((r) => r.region === section && r.structure === structure)
    .sort((a, b) => (a.sort_order - b.sort_order) || a.name.localeCompare(b.name));
  const firstActiveId = list.find((r) => r.status === 'Active')?.id;

  function chooseSection(key) {
    const cfg = EXAM_SECTIONS.find((s) => s.key === key);
    setSection(key); setStructure(cfg.structures[0]);
    setError(''); setEditingId(null); setNewName('');
  }
  function chooseStructure(s) {
    setStructure(s); setError(''); setEditingId(null); setNewName('');
  }

  // Every action runs once at a time -- the button row is disabled while
  // busy, so a slow connection can't fire the same change twice.
  async function run(fn) {
    if (busy) return;
    setBusy(true); setError('');
    const result = await fn();
    if (result?.error) setError(result.error);
    await refresh();
    setBusy(false);
    return result;
  }

  async function handleAdd() {
    if (!newName.trim()) { setError('Type the option name first.'); return; }
    const result = await run(() => addExamOption({ region: section, structure, name: newName }));
    if (!result?.error) setNewName('');
  }
  async function handleSaveEdit(row) {
    const result = await run(() => updateExamOption(row.id, row, { name: editName }));
    if (!result?.error) setEditingId(null);
  }
  async function handleDelete(row) {
    if (!confirm(`Delete "${row.name}" from ${structure}?\n\nPast patient records that used it keep their text. To hide it without deleting, set it to Inactive instead.`)) return;
    await run(() => deleteExamOption(row.id, row.code));
  }

  const tabBtn = (active) => ({
    padding: '6px 12px', borderRadius: 999, fontSize: 12, fontWeight: 600, cursor: 'pointer',
    border: `1.5px solid ${active ? 'var(--blue)' : 'var(--g200)'}`,
    background: active ? 'var(--blue)' : '#fff', color: active ? '#fff' : 'var(--g700)',
  });

  return (
    <>
      <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> The options doctors click in Consultation &gt; Examination. Pick a section and structure, then add, rename, reorder, deactivate or delete its options. The <strong>first active option</strong> is what <strong>All Normal</strong> fills in. Changes show the next time the Examination tab is opened; past patient records keep the wording they were saved with.
      </div>

      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 10 }}>
        {EXAM_SECTIONS.map((s) => (
          <button key={s.key} type="button" className={section === s.key ? 'btn btn-primary btn-sm' : 'btn btn-sm'} onClick={() => chooseSection(s.key)}>{s.label}</button>
        ))}
      </div>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 14 }}>
        {sectionCfg.structures.map((s) => {
          const count = rows.filter((r) => r.region === section && r.structure === s && r.status === 'Active').length;
          return (
            <button key={s} type="button" style={tabBtn(structure === s)} onClick={() => chooseStructure(s)}>
              {s} <span style={{ opacity: 0.7, fontWeight: 500 }}>({count})</span>
            </button>
          );
        })}
      </div>

      {STRUCT_NOTE[structure] && section === 'posterior' && (
        <div style={{ fontSize: 11.5, color: 'var(--g500)', marginBottom: 8 }}><i className="ti ti-info-circle"></i> {STRUCT_NOTE[structure]}</div>
      )}

      {error && <div className="msg-err">{error}</div>}

      <div style={{ display: 'flex', gap: 8, marginBottom: 12, flexWrap: 'wrap' }}>
        <input
          className="fi"
          style={{ flex: '1 1 240px' }}
          placeholder={`New option for ${structure} (e.g. ${section === 'gonioscopy' ? 'Open Angle till SL' : 'type exactly as it should appear'})`}
          value={newName}
          autoCapitalize="off" autoCorrect="off" spellCheck="false"
          onChange={(e) => setNewName(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') handleAdd(); }}
        />
        <button type="button" className="btn btn-primary" disabled={busy} onClick={handleAdd}><i className="ti ti-plus"></i> Add to {structure}</button>
      </div>

      <table className="tbl">
        <thead><tr><th style={{ width: 70 }}>Order</th><th>Option</th><th>Code</th><th>Status</th><th></th></tr></thead>
        <tbody>
          {loading && <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
          {!loading && list.map((row, i) => (
            <tr key={row.id} style={editingId === row.id ? { background: 'var(--g50)' } : (row.status !== 'Active' ? { opacity: 0.55 } : undefined)}>
              <td>
                <div style={{ display: 'flex', gap: 2 }}>
                  <button type="button" className="btn btn-sm" title="Move up" disabled={busy || i === 0} onClick={() => run(() => moveExamOption(row.id, -1))}><i className="ti ti-arrow-up"></i></button>
                  <button type="button" className="btn btn-sm" title="Move down" disabled={busy || i === list.length - 1} onClick={() => run(() => moveExamOption(row.id, 1))}><i className="ti ti-arrow-down"></i></button>
                </div>
              </td>
              <td>
                {editingId === row.id ? (
                  <input className="fi fi-sm" value={editName} autoFocus autoCapitalize="off" autoCorrect="off" spellCheck="false"
                    onChange={(e) => setEditName(e.target.value)}
                    onKeyDown={(e) => { if (e.key === 'Enter') handleSaveEdit(row); if (e.key === 'Escape') setEditingId(null); }} />
                ) : (
                  <span style={{ fontWeight: 600 }}>
                    {row.name}
                    {row.id === firstActiveId && hasNormalDefault(section, structure) && (
                      <span className="badge b-green" style={{ marginLeft: 8, fontWeight: 600 }}>All Normal default</span>
                    )}
                  </span>
                )}
              </td>
              <td style={{ fontFamily: 'monospace', fontSize: 12, color: 'var(--g500)' }}>{row.code}</td>
              <td>
                <button
                  type="button"
                  className={`badge ${row.status === 'Active' ? 'b-green' : 'b-gray'}`}
                  style={{ border: 'none', cursor: 'pointer' }}
                  disabled={busy}
                  onClick={() => run(() => toggleStatus('master_exam_options', row.id, row.status, row.code))}
                >
                  {row.status}
                </button>
              </td>
              <td style={{ display: 'flex', gap: 4 }}>
                {editingId === row.id ? (
                  <>
                    <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => handleSaveEdit(row)}>Save</button>
                    <button type="button" className="btn btn-sm" onClick={() => setEditingId(null)}>Cancel</button>
                  </>
                ) : (
                  <>
                    <button type="button" className="btn btn-sm" title="Rename" disabled={busy} onClick={() => { setEditingId(row.id); setEditName(row.name); setError(''); }}><i className="ti ti-edit"></i></button>
                    <button type="button" className="btn btn-sm" title="Delete" disabled={busy} onClick={() => handleDelete(row)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                  </>
                )}
              </td>
            </tr>
          ))}
          {!loading && list.length === 0 && (
            <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No options for {structure} yet -- add one above.</td></tr>
          )}
        </tbody>
      </table>
    </>
  );
}
