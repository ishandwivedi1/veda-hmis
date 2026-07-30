'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForInvestigation, getInvestigationComparisonData } from '../actions';
import { matchInvestigationType, parseNumeric } from '../investigation-types';
import InvestigationTabs from '../investigation-tabs';

const COMPARE_TYPES = ['OCT', 'Visual Field'];

export default function InvestigationComparisonPage() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [type, setType] = useState('OCT');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvestigation(searchQuery.trim());
    setSearchResults(results);
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForInvestigation(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    await loadData(p.id, type);
  }

  async function loadData(patientId, t) {
    setLoading(true);
    const result = await getInvestigationComparisonData(patientId);
    setLoading(false);
    if (result.error) { setRows([]); return; }
    const filtered = (result.rows || []).filter((r) => matchInvestigationType(r.name) === t);
    setRows(filtered);
  }

  async function handleTypeChange(t) {
    setType(t);
    if (patient) await loadData(patient.id, t);
  }

  const first = rows[0];
  const last = rows[rows.length - 1];
  const trend = type === 'OCT' && rows.length > 1 && first && last
    ? {
        cmt: (() => { const a = parseNumeric(first.result_data?.['cmt-re']); const b = parseNumeric(last.result_data?.['cmt-re']); return a !== null && b !== null ? b - a : null; })(),
        rnfl: (() => { const a = parseNumeric(first.result_data?.rnfl); const b = parseNumeric(last.result_data?.rnfl); return a !== null && b !== null ? b - a : null; })(),
      }
    : null;

  return (
    <div>
      <InvestigationTabs />

      <div className="card" style={{ marginBottom: 12 }}>
        <div className="card-head" style={{ marginBottom: 0 }}>
          <div className="card-title"><i className="ti ti-chart-bar-off" style={{ color: 'var(--teal)' }}></i> Longitudinal Comparison</div>
        </div>
        <div style={{ display: 'flex', gap: 8, marginTop: 10, flexWrap: 'wrap', alignItems: 'center' }}>
          {!patient ? (
            <div style={{ position: 'relative', flex: 1, minWidth: 240 }}>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient by name or UHID..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, position: 'absolute', background: '#fff', width: '100%', zIndex: 5 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
          ) : (
            <div style={{ display: 'flex', alignItems: 'center', gap: 8, background: 'var(--blue-lt)', padding: '6px 12px', borderRadius: 8 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={() => { setPatient(null); setRows([]); }}>Change</button>
            </div>
          )}
          <select className="fi" style={{ width: 'auto', padding: '7px 10px' }} value={type} onChange={(e) => handleTypeChange(e.target.value)}>
            {COMPARE_TYPES.map((t) => <option key={t} value={t}>{t}</option>)}
          </select>
        </div>
      </div>

      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: 20, textAlign: 'center' }}>Loading...</div>}

      {!loading && patient && rows.length === 0 && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No {type} history for this patient.</div>
      )}

      {!loading && rows.length > 0 && (
        <>
          <div style={{ display: 'grid', gridTemplateColumns: `repeat(${rows.length}, 1fr)`, gap: 12, marginBottom: 12 }}>
            {rows.map((r) => (
              <div key={r.id} className="card" style={{ marginBottom: 0 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', marginBottom: 8 }}>
                  {new Date(r.created_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                </div>
                {type === 'OCT' ? (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>CMT</span><strong>{r.result_data?.['cmt-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>RNFL</span><strong>{r.result_data?.rnfl || '--'}</strong></div>
                  </>
                ) : (
                  <>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD RE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-re'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>MD LE</span><strong style={{ color: 'var(--red)' }}>{r.result_data?.['md-le'] || '--'}</strong></div>
                    <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0', fontSize: 12 }}><span style={{ color: 'var(--g500)' }}>VFI</span><strong>{r.result_data?.vfi || '--'}</strong></div>
                  </>
                )}
              </div>
            ))}
          </div>

          {trend && (trend.cmt !== null || trend.rnfl !== null) && (
            <div className="card">
              <div className="card-title"><i className="ti ti-trending-up" style={{ color: 'var(--teal)' }}></i> Trend Analysis</div>
              {trend.cmt !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <span>CMT change</span>
                  <span style={{ fontWeight: 700, color: trend.cmt > 10 ? 'var(--red)' : trend.cmt < -10 ? 'var(--green)' : 'var(--g600)' }}>{trend.cmt >= 0 ? '+' : ''}{trend.cmt} um over {rows.length - 1} visit(s)</span>
                </div>
              )}
              {trend.rnfl !== null && (
                <div style={{ display: 'flex', justifyContent: 'space-between', padding: '5px 0', fontSize: 12 }}>
                  <span>RNFL change</span>
                  <span style={{ fontWeight: 700, color: trend.rnfl < -5 ? 'var(--red)' : 'var(--green)' }}>{trend.rnfl >= 0 ? '+' : ''}{trend.rnfl} um</span>
                </div>
              )}
              <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 8 }}>For clinical decision support. Interpretation by Ophthalmologist only.</div>
            </div>
          )}
        </>
      )}

      {!patient && (
        <div className="card" style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Search for a patient to compare their investigation results over time.</div>
      )}
    </div>
  );
}


