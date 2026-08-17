'use client';

import { useState, useEffect } from 'react';
import { approveIolPlan, getIolVersionHistory } from '../actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';
import { openPrintPopup } from '@/lib/printPopup';

const FORMULA_NAMES = ['Barrett Universal II', 'SRK/T', 'Haigis', 'Hoffer Q', 'Holladay 1', 'Other'];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const EYE_LABEL = { RE: 'Right (OD)', LE: 'Left (OS)', Both: 'Both (OU)', OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

export default function ApprovalTab({ record, recordId, surgeonName, onSaved }) {
  const [finalPower, setFinalPower] = useState('');
  const [finalFormula, setFinalFormula] = useState(FORMULA_NAMES[0]);
  const [finalCategory, setFinalCategory] = useState(IOL_CATEGORIES[0]);
  const [finalTarget, setFinalTarget] = useState('');
  const [iolCatalogId, setIolCatalogId] = useState('');
  const [surgeonNotes, setSurgeonNotes] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [versions, setVersions] = useState([]);
  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const [revising, setRevising] = useState(false);

  async function loadVersions() {
    const v = await getIolVersionHistory(recordId);
    setVersions(v);
  }

  useEffect(() => {
    getActiveIolCatalog().then(setCatalog);
    loadVersions();
  }, [recordId]);

  useEffect(() => {
    const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
    setFinalPower(record.final_iol_power || selected?.power || '');
    setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
    setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
    setFinalTarget(record.target_refraction || '');
    setIolCatalogId(record.final_iol_catalog_id || '');
    setSurgeonNotes(record.surgeon_notes || '');
  }, [record]);

  const notCalculated = record.status !== 'Calculated' && record.status !== 'Approved';
  const isApproved = record.status === 'Approved' && !revising;
  const catalogForCategory = catalog.filter((c) => c.category === finalCategory);

  async function handleApprove() {
    setError(''); setOkMsg('');
    if (!finalPower.trim()) { setError('Final IOL power is required.'); return; }
    setSaving(true);
    const result = await approveIolPlan(recordId, {
      finalPower, finalFormula, finalCategory, finalTarget, iolCatalogId: iolCatalogId || null, surgeonNotes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg(`IOL Plan approved (version ${result.versionNo}).`);
    setRevising(false);
    loadVersions();
    if (onSaved) onSaved();
  }

  if (notCalculated) {
    return (
      <div className="msg-err">
        <i className="ti ti-lock"></i> Save at least one formula result in IOL Calculation before approval is available.
      </div>
    );
  }

  const selectedCatalogItem = catalog.find((c) => c.id === record.final_iol_catalog_id);

  return (
    <div>
      <div style={{ background: 'linear-gradient(135deg,#166534,#157a4f)', borderRadius: 12, padding: '11px 16px', color: '#fff', marginBottom: 12, display: 'flex', alignItems: 'center', gap: 12 }}>
        <i className="ti ti-shield-check" style={{ fontSize: 26, flexShrink: 0 }}></i>
        <div>
          <div style={{ fontSize: 14, fontWeight: 700 }}>Final IOL Plan Approval</div>
          <div style={{ fontSize: 11, opacity: .8 }}>{record.procedure_name || 'Procedure not set'} -- Dr. {surgeonName}</div>
        </div>
        <div style={{ marginLeft: 16, background: 'rgba(255,255,255,.15)', borderRadius: 8, padding: '6px 12px' }}>
          <div style={{ fontSize: 9, opacity: .8, textTransform: 'uppercase', letterSpacing: .4 }}>Eye to be Operated</div>
          <div style={{ fontSize: 13, fontWeight: 700 }}>{EYE_LABEL[record.surgical_eye] || record.surgical_eye || '--'}</div>
        </div>
        <div style={{ marginLeft: 'auto', textAlign: 'right' }}>
          <div style={{ fontSize: 10, opacity: .7 }}>Only surgeon/ophthalmologist should approve</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 2 }}>{isApproved ? 'Approved' : revising ? 'Revising' : 'Approval required'}</div>
        </div>
      </div>

      <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11, marginBottom: 12 }}>
        <i className="ti ti-alert-triangle"></i> This isn't role-restricted at the database level yet -- please only approve if you're the operating surgeon or ophthalmologist for this case.
      </div>

      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success"><i className="ti ti-circle-check"></i> {okMsg}</div>}
      {revising && (
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-edit"></i> Revising the approved plan. Approving again will add a new version -- the current approved version stays in history, marked Superseded.
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 14 }}>
        <div>
          <div className="card" style={{ marginBottom: 12 }}>
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-calculator" style={{ color: 'var(--indigo)' }}></i> Calculation Review</div>
            {record.formula_results?.length > 0 ? (
              record.formula_results.map((r, i) => (
                <div key={i} style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12, fontWeight: r.name === record.selected_formula ? 700 : 400, color: r.name === record.selected_formula ? 'var(--green)' : 'var(--g700)' }}>
                  <span>{r.name}{r.name === record.selected_formula ? ' (selected)' : ''}</span>
                  <span style={{ fontFamily: 'monospace' }}>{r.power} D -- {r.refraction}</span>
                </div>
              ))
            ) : (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No calculation saved yet.</div>
            )}
          </div>

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-shield-check" style={{ color: 'var(--green)' }}></i> Final IOL Plan</div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">Final IOL power (D) *</label>
                <input className="fi fi-sm" placeholder="+21.5" value={finalPower} onChange={(e) => setFinalPower(e.target.value)} disabled={isApproved} />
              </div>
              <div>
                <label className="flbl">Formula used</label>
                <select className="fi fi-sm" value={finalFormula} onChange={(e) => setFinalFormula(e.target.value)} disabled={isApproved}>
                  {FORMULA_NAMES.map((f) => <option key={f}>{f}</option>)}
                </select>
              </div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 8 }}>
              <div>
                <label className="flbl">IOL category *</label>
                <select className="fi fi-sm" value={finalCategory} onChange={(e) => { setFinalCategory(e.target.value); setIolCatalogId(''); }} disabled={isApproved}>
                  {IOL_CATEGORIES.map((c) => <option key={c}>{c}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Target refraction</label>
                <input className="fi fi-sm" value={finalTarget} onChange={(e) => setFinalTarget(e.target.value)} disabled={isApproved} />
              </div>
            </div>
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Specific IOL (Master Data -- IOL Catalog)</label>
              <select className="fi fi-sm" value={iolCatalogId} onChange={(e) => setIolCatalogId(e.target.value)} disabled={isApproved}>
                <option value="">-- Not specified --</option>
                {catalogForCategory.map((c) => <option key={c.id} value={c.id}>{c.brand} -- {c.model}</option>)}
              </select>
              {catalogForCategory.length === 0 && (
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 3 }}>No catalog items for {finalCategory} yet -- add them in Master Data -&gt; Clinical -&gt; IOL Catalog.</div>
              )}
            </div>
            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Surgeon notes</label>
              <textarea className="fi fi-sm" rows={2} value={surgeonNotes} onChange={(e) => setSurgeonNotes(e.target.value)} disabled={isApproved} placeholder="e.g. Aim for slight myopia. Avoid multifocal due to macular finding. Toric axis to be confirmed intra-op..." />
            </div>

            {!isApproved && (
              <button className="btn" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={handleApprove} disabled={saving}>
                <i className="ti ti-shield-check"></i> {saving ? 'Approving...' : revising ? 'Approve Revised Plan' : 'Approve Final IOL Plan'}
              </button>
            )}
            {revising && (
              <button
                className="btn btn-sm"
                style={{ marginLeft: 8 }}
                onClick={() => {
                  setRevising(false);
                  const selected = (record.formula_results || []).find((r) => r.name === record.selected_formula);
                  setFinalPower(record.final_iol_power || selected?.power || '');
                  setFinalFormula(record.selected_formula || selected?.name || FORMULA_NAMES[0]);
                  setFinalCategory(record.final_iol_category || IOL_CATEGORIES[0]);
                  setFinalTarget(record.target_refraction || '');
                  setIolCatalogId(record.final_iol_catalog_id || '');
                  setSurgeonNotes(record.surgeon_notes || '');
                  setError(''); setOkMsg('');
                }}
              >
                Cancel revision
              </button>
            )}
            {record.status === 'Approved' && !revising && (
              <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                Approved{record.approved_at ? ` on ${new Date(record.approved_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}` : ''}. To change the plan (e.g. patient requests a different IOL), click Revise -- this creates a new version without deleting the old one.
              </div>
            )}
            {record.status === 'Approved' && !revising && (
              <button className="btn btn-sm" style={{ marginTop: 8 }} onClick={() => setRevising(true)}>
                <i className="ti ti-edit"></i> Revise plan (creates new version)
              </button>
            )}
          </div>
        </div>

        <div>
          {record.status === 'Approved' && (
            <div className="card" style={{ marginBottom: 12, background: 'var(--green-lt)', borderColor: '#86efac' }}>
              <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
                <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--green)' }}>
                  <i className="ti ti-clipboard-check"></i> IOL Planning Summary
                </div>
                <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={() => openPrintPopup(`/biometry-print/${recordId}`)}>
                  <i className="ti ti-printer"></i> Print Biometry Report
                </button>
              </div>
              <div style={{ fontSize: 12, color: 'var(--g700)', lineHeight: 1.8 }}>
                <div><strong>Power:</strong> {record.final_iol_power} D</div>
                <div><strong>Category:</strong> {record.final_iol_category}</div>
                {selectedCatalogItem && <div><strong>Lens:</strong> {selectedCatalogItem.brand} -- {selectedCatalogItem.model}</div>}
                <div><strong>Target:</strong> {record.target_refraction}</div>
              </div>
            </div>
          )}

          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Version History</div>
            {versions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No approved versions yet.</div>}
            {versions.map((v) => (
              <div key={v.id} style={{ padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <span style={{ fontWeight: 700 }}>v{v.version_no} -- {v.power} D ({v.formula})</span>
                  <span className={`badge ${v.status === 'Approved' ? 'b-green' : 'b-gray'}`} style={{ fontSize: 9 }}>{v.status}</span>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>
                  {v.profiles?.full_name || 'Staff'} -- {new Date(v.created_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                </div>
              </div>
            ))}
            <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Approval supersedes the previous plan but never deletes historical versions.</div>
          </div>
        </div>
      </div>
    </div>
  );
}

