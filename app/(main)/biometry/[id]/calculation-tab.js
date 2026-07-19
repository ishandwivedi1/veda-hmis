'use client';

import { useState, useEffect } from 'react';
import { saveFormulaResults } from '../actions';

const MEAS_FIELDS = [
  { key: 'axl', label: 'Axial Length', unit: 'mm' },
  { key: 'k1', label: 'K1', unit: 'D' },
  { key: 'k2', label: 'K2', unit: 'D' },
  { key: 'acd', label: 'ACD', unit: 'mm' },
  { key: 'lt', label: 'Lens Thickness', unit: 'mm' },
  { key: 'wtw', label: 'White-to-White', unit: 'mm' },
];

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const TARGETS = ['Plano (Emmetropia)', '-0.50 D (Mild myopia)', 'Monovision'];

export default function CalculationTab({ record, recordId, onSaved }) {
  const [targetRefraction, setTargetRefraction] = useState('Plano (Emmetropia)');
  const [rows, setRows] = useState([]);
  const [selectedIdx, setSelectedIdx] = useState(null);
  const [newFormula, setNewFormula] = useState(FORMULA_NAMES[0]);
  const [newPower, setNewPower] = useState('');
  const [newRefraction, setNewRefraction] = useState('');
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);

  useEffect(() => {
    setTargetRefraction(record.target_refraction || 'Plano (Emmetropia)');
    setRows(Array.isArray(record.formula_results) ? record.formula_results : []);
    if (record.selected_formula) {
      const idx = (record.formula_results || []).findIndex((r) => r.name === record.selected_formula);
      setSelectedIdx(idx >= 0 ? idx : null);
    }
  }, [record]);

  const eyeKey = record.surgical_eye === 'RE' ? 're' : record.surgical_eye === 'LE' ? 'le' : null;
  const surgicalEyeSets = eyeKey && Array.isArray(record.measurements?.[eyeKey]) ? record.measurements[eyeKey] : [];

  const notVerified = record.status !== 'Calculated' && record.status !== 'Approved';
  const readOnlyRows = record.status === 'Approved';

  function addRow() {
    if (!newPower.trim()) { setError('Enter the IOL power for this formula.'); return; }
    setError('');
    setRows((prev) => [...prev, { name: newFormula, power: newPower, refraction: newRefraction || '--' }]);
    setNewPower(''); setNewRefraction('');
  }

  function removeRow(idx) {
    setRows((prev) => prev.filter((_, i) => i !== idx));
    if (selectedIdx === idx) setSelectedIdx(null);
  }

  async function handleSave() {
    setError(''); setOkMsg('');
    if (rows.length === 0) { setError('Add at least one formula result before saving.'); return; }
    setSaving(true);
    const selectedFormula = selectedIdx !== null ? rows[selectedIdx]?.name : null;
    const result = await saveFormulaResults(recordId, targetRefraction, rows, selectedFormula);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Calculation saved. Continue to Surgeon Approval.');
    if (onSaved) onSaved();
  }

  if (notVerified) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Measurements must be verified first (see the Measurements tab) before IOL Calculation is available.
      </div>
    );
  }

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 2fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-ruler-measure" style={{ color: 'var(--indigo)' }}></i> Biometry Summary ({record.surgical_eye || '--'})</div>
            {surgicalEyeSets.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No readings recorded.</div>}
            {surgicalEyeSets.map((set, idx) => (
              <div key={idx} style={{ marginBottom: idx < surgicalEyeSets.length - 1 ? 10 : 0, paddingBottom: idx < surgicalEyeSets.length - 1 ? 10 : 0, borderBottom: idx < surgicalEyeSets.length - 1 ? '1px dashed var(--g200)' : 'none' }}>
                <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--indigo)', marginBottom: 4 }}>
                  <i className="ti ti-device-tablet" style={{ fontSize: 10 }}></i> {set.device}
                </div>
                {MEAS_FIELDS.map((f) => (
                  <div key={f.key} style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', fontSize: 12 }}>
                    <span style={{ color: 'var(--g500)' }}>{f.label}</span>
                    <span style={{ fontWeight: 700, fontFamily: 'monospace' }}>{set[f.key] || '--'} {f.unit}</span>
                  </div>
                ))}
              </div>
            ))}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-target" style={{ color: 'var(--amber)' }}></i> Target Refraction</div>
            <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5 }}>
              {TARGETS.map((t) => (
                <span
                  key={t}
                  className={`badge ${targetRefraction === t ? 'b-green' : 'b-gray'}`}
                  style={{ cursor: readOnlyRows ? 'default' : 'pointer' }}
                  onClick={() => !readOnlyRows && setTargetRefraction(t)}
                >
                  {t}
                </span>
              ))}
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 8 }}>Selected: <strong>{targetRefraction}</strong></div>
          </div>
        </div>

        <div>
          <div className="card">
            <div className="card-head" style={{ marginBottom: 8 }}>
              <div className="card-title"><i className="ti ti-table" style={{ color: 'var(--blue)' }}></i> Formula Comparison</div>
              <span className="badge b-indigo" style={{ fontSize: 10 }}>From device printout</span>
            </div>
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 10 }}>
              <i className="ti ti-info-circle"></i> This system does not compute IOL power -- transcribe each formula's result from the biometry device's own printout (see Device Reports in the Measurements tab). The surgeon makes the clinical decision on which formula to use.
            </div>

            <table className="tbl" style={{ marginBottom: 10 }}>
              <thead><tr><th></th><th>Formula</th><th>IOL Power</th><th>Predicted Refraction</th><th></th></tr></thead>
              <tbody>
                {rows.map((r, idx) => (
                  <tr key={idx} style={{ background: selectedIdx === idx ? 'var(--green-lt)' : 'transparent' }}>
                    <td>
                      <input type="radio" checked={selectedIdx === idx} onChange={() => setSelectedIdx(idx)} disabled={readOnlyRows} style={{ accentColor: 'var(--green)' }} />
                    </td>
                    <td style={{ fontWeight: 600 }}>{r.name}</td>
                    <td style={{ fontFamily: 'monospace', fontWeight: 700, color: 'var(--indigo)' }}>{r.power} D</td>
                    <td>{r.refraction}</td>
                    <td>
                      {!readOnlyRows && <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => removeRow(idx)}>Remove</button>}
                    </td>
                  </tr>
                ))}
                {rows.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No formula results entered yet.</td></tr>
                )}
              </tbody>
            </table>

            {!readOnlyRows && (
              <div style={{ display: 'flex', gap: 6, alignItems: 'flex-end', flexWrap: 'wrap', borderTop: '1px solid var(--g100)', paddingTop: 10 }}>
                <div>
                  <label className="flbl">Formula</label>
                  <select className="fi fi-sm" value={newFormula} onChange={(e) => setNewFormula(e.target.value)}>
                    {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                  </select>
                </div>
                <div>
                  <label className="flbl">IOL Power (D)</label>
                  <input className="fi fi-sm" style={{ width: 90 }} placeholder="+21.5" value={newPower} onChange={(e) => setNewPower(e.target.value)} />
                </div>
                <div>
                  <label className="flbl">Predicted Refraction</label>
                  <input className="fi fi-sm" style={{ width: 110 }} placeholder="Plano" value={newRefraction} onChange={(e) => setNewRefraction(e.target.value)} />
                </div>
                <button className="btn btn-sm btn-primary" onClick={addRow}><i className="ti ti-plus"></i> Add row</button>
              </div>
            )}

            {selectedIdx !== null && (
              <div style={{ marginTop: 10, padding: '8px 10px', background: 'var(--green-lt)', borderRadius: 8, fontSize: 12, color: 'var(--green)' }}>
                <i className="ti ti-circle-check"></i> {rows[selectedIdx]?.name} selected as the surgeon's preferred formula. Proceed to Surgeon Approval.
              </div>
            )}

            {!readOnlyRows && (
              <button className="btn btn-primary" style={{ marginTop: 10 }} onClick={handleSave} disabled={saving}>
                {saving ? 'Saving...' : 'Save Calculation'}
              </button>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}
