'use client';

import { Suspense, useState, useEffect, useCallback } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { useSearchParams } from 'next/navigation';
import { getPendingIolApprovals, getApprovedToday, getIolApprovalHistory, getIolApprovalDetail, approveIol } from './actions';
import { getActiveIolCatalog } from '@/app/(main)/master-data/actions';

const EYE_LABEL = { OD: 'Right (OD)', OS: 'Left (OS)', OU: 'Both (OU)' };

function TabButton({ active, onClick, icon, label, disabled }) {
  return (
    <button
      type="button"
      onClick={disabled ? undefined : onClick}
      disabled={disabled}
      style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: active ? '#fff' : 'transparent', color: disabled ? 'var(--g300)' : active ? 'var(--indigo)' : 'var(--g500)', cursor: disabled ? 'not-allowed' : 'pointer', boxShadow: active ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }}
    >
      <i className={`ti ${icon}`}></i> {label}
    </button>
  );
}

// ── DASHBOARD ─────────────────────────────────────────────────────
function DashboardTab({ pending, approvedToday, loading, onOpen }) {
  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-clock" style={{ color: 'var(--amber)' }}></i> Pending Approval
          <span className="badge b-amber" style={{ marginLeft: 8 }}>{pending.length}</span>
        </div>
        {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}
        {!loading && pending.map((item) => (
          <div key={item.caseId} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(item.caseId)}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--indigo)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {item.patient?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(item.patient)}</span>
              <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[item.eye] || item.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {item.patient?.uhid} -- {item.procedureName}{item.packageName ? ` -- ${item.packageName}` : ''}
              </div>
            </div>
            <button className="btn btn-sm btn-primary" onClick={(e) => { e.stopPropagation(); onOpen(item.caseId); }}>
              <i className="ti ti-lens"></i> Approve
            </button>
          </div>
        ))}
        {!loading && pending.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Nothing pending approval.</div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Approved Today</div>
        {approvedToday.map((a) => (
          <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '10px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(a.surgical_case_id)}>
            <div style={{ width: 34, height: 34, borderRadius: '50%', background: 'var(--green)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 14, fontWeight: 700, flexShrink: 0 }}>
              {a.surgical_cases?.patients?.first_name?.charAt(0)}
            </div>
            <div style={{ flex: 1 }}>
              <span style={{ fontWeight: 700, fontSize: 13 }}>{formatPatientName(a.surgical_cases?.patients)}</span>
              <span className="badge b-green" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
                {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              </div>
            </div>
            <button className="btn btn-sm" onClick={(e) => { e.stopPropagation(); onOpen(a.surgical_case_id); }}>
              <i className="ti ti-edit"></i> Edit
            </button>
          </div>
        ))}
        {approvedToday.length === 0 && (
          <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>Nothing approved yet today.</div>
        )}
      </div>
    </div>
  );
}

// ── HISTORY -- full tab, not a collapsible aside. Every approval ever
// made, searchable by patient and filterable by date range. ──
function HistoryTab({ onOpen }) {
  const [rows, setRows] = useState([]);
  const [search, setSearch] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    setLoading(true);
    setRows(await getIolApprovalHistory(fromDate || undefined, toDate || undefined, search || undefined));
    setLoading(false);
  }, [fromDate, toDate, search]);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10 }}>
        <i className="ti ti-history" style={{ color: 'var(--indigo)' }}></i> Approval History
        <span className="badge b-gray" style={{ marginLeft: 8 }}>{rows.length}</span>
      </div>

      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
        <input className="fi fi-sm" style={{ flex: 1, minWidth: 200 }} placeholder="Search patient name or UHID..." value={search} onChange={(e) => setSearch(e.target.value)} />
        <input type="date" className="fi fi-sm" value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
        <input type="date" className="fi fi-sm" value={toDate} onChange={(e) => setToDate(e.target.value)} />
        {(fromDate || toDate || search) && (
          <button className="btn btn-sm" onClick={() => { setSearch(''); setFromDate(''); setToDate(''); }}>Clear</button>
        )}
      </div>

      {loading && <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>}

      {!loading && rows.map((a) => (
        <div key={a.id} style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '9px 0', borderBottom: '1px solid var(--g100)', cursor: 'pointer' }} onClick={() => onOpen(a.surgical_case_id)}>
          <div style={{ width: 32, height: 32, borderRadius: '50%', background: 'var(--g300)', color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 13, fontWeight: 700, flexShrink: 0 }}>
            {a.surgical_cases?.patients?.first_name?.charAt(0)}
          </div>
          <div style={{ flex: 1 }}>
            <span style={{ fontWeight: 700, fontSize: 12.5 }}>{formatPatientName(a.surgical_cases?.patients)}</span>
            <span className="badge b-gray" style={{ marginLeft: 8, fontSize: 10 }}>{EYE_LABEL[a.eye] || a.eye}</span>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 1 }}>
              {a.surgical_cases?.patients?.uhid} -- {a.master_iol_catalog?.brand} {a.master_iol_catalog?.model} -- {a.power}D
              {a.approved_at && <> -- {new Date(a.approved_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}</>}
            </div>
          </div>
          <button className="btn btn-sm" onClick={(e) => { e.stopPropagation(); onOpen(a.surgical_case_id); }}>
            <i className="ti ti-edit"></i> Edit
          </button>
        </div>
      ))}
      {!loading && rows.length === 0 && (
        <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 20 }}>No approvals found.</div>
      )}
    </div>
  );
}

// ── WORKSPACE -- one patient's full record. Same header/summary layout
// convention as Patient Check-In / Intraoperative Management (gradient
// banner with all patient/case info up top, big-visibility summary
// cards below), instead of the small popup this used to be. ──
function WorkspaceView({ caseId, onBack, onDone, initialLocked }) {
  const [detail, setDetail] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [catalog, setCatalog] = useState([]);
  const [catalogId, setCatalogId] = useState('');
  const [power, setPower] = useState('');
  const [notes, setNotes] = useState('');
  const [error, setError] = useState('');
  const [ok, setOk] = useState('');
  const [saving, setSaving] = useState(false);
  const [locked, setLocked] = useState(!!initialLocked);

  const refresh = useCallback(async () => {
    const result = await getIolApprovalDetail(caseId);
    if (result.error) { setLoadError(result.error); return; }
    setDetail(result);
  }, [caseId]);

  useEffect(() => { refresh(); getActiveIolCatalog().then(setCatalog); }, [refresh]);

  // Pre-fill from the existing approval when re-opening to revise it --
  // otherwise Edit silently opened a blank form and looked like nothing
  // could be changed.
  useEffect(() => {
    if (detail?.approval) {
      setCatalogId(detail.approval.iol_catalog_id || '');
      setPower(detail.approval.power || '');
      setNotes(detail.approval.notes || '');
    }
  }, [detail]);

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!detail) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const sc = detail.case;
  const patient = sc.patients;
  const approved = detail.approval?.status === 'Approved';
  const isLocked = locked && approved;
  const eyeKey = sc.eye === 'OD' ? 're_power' : sc.eye === 'OS' ? 'le_power' : null;

  function pickRecommendation(rec) {
    setCatalogId(rec.master_iol_catalog.id);
    setPower(eyeKey ? (rec[eyeKey] ?? '') : '');
  }

  // Flags when the doctor's choice doesn't match any device
  // recommendation on file -- either a brand/model with no
  // recommendation row at all, or a power that differs from what the
  // device recommended for this eye. A genuine clinical call either
  // way, but worth surfacing rather than silently letting it slide.
  const matchingRec = catalogId ? detail.recommendations.find((r) => r.master_iol_catalog.id === catalogId) : null;
  const recommendedPower = matchingRec && eyeKey ? matchingRec[eyeKey] : null;
  const deviatesNoRec = !!catalogId && !matchingRec && detail.recommendations.length > 0;
  const deviatesPower = !!matchingRec && !!power && recommendedPower != null && String(power).trim() !== String(recommendedPower).trim();
  const deviates = deviatesNoRec || deviatesPower;

  async function handleApprove() {
    setError(''); setOk('');
    if (!detail.biometry) { setError('No measured biometry on file for this patient.'); return; }
    setSaving(true);
    const result = await approveIol(caseId, detail.biometry.id, catalogId, power, notes);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOk('Saved.');
    // Opened as a deep link from Surgical Journey (a real opener window
    // exists) -- signal the approval back and close this tab so the
    // person lands right back on Surgical Journey instead of having to
    // switch tabs and manually refresh. Opened normally from the
    // sidebar (no opener), just refresh in place as before.
    if (typeof window !== 'undefined' && window.opener) {
      window.opener.postMessage({ type: 'iol-approved', caseId }, window.location.origin);
      window.close();
      return;
    }
    refresh();
    onDone();
  }

  return (
    <div>
      <div style={{ background: approved ? 'linear-gradient(135deg,#312e81,#4338ca)' : 'linear-gradient(135deg,#78350f,#b45309)', borderRadius: 12, padding: '11px 18px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14, flexWrap: 'wrap' }}>
        {sc.surgery_code && <div style={{ background: 'rgba(255,255,255,.15)', padding: '5px 12px', borderRadius: 8, fontFamily: 'monospace', fontWeight: 700, fontSize: 13 }}>{sc.surgery_code}</div>}
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{formatPatientName(patient)}</div>
          <div style={{ fontSize: 11, opacity: .85 }}>
            {patient?.uhid} -- {patient?.age}y {patient?.gender} -- {patient?.mobile || 'No mobile on file'} -- {sc.procedure_name} {sc.eye ? `(${EYE_LABEL[sc.eye] || sc.eye})` : ''} -- {sc.profiles?.full_name || 'No surgeon assigned'}
          </div>
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <span className="badge" style={{ background: 'rgba(255,255,255,.2)', color: '#fff' }}>{approved ? 'Approved' : 'Pending Approval'}</span>
          {detail.biometry && (
            <a href={`/biometry/${detail.biometry.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none', borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }}>
              <i className="ti ti-file-report"></i> Biometry Report
            </a>
          )}
          <button className="btn btn-sm" style={{ borderColor: 'rgba(255,255,255,.3)', background: 'rgba(255,255,255,.1)', color: '#fff' }} onClick={onBack}>
            <i className="ti ti-arrow-left"></i> Dashboard
          </button>
        </div>
      </div>

      {/* Big-visibility case summary -- same convention as Patient
          Check-In / Intraoperative Management */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 14 }}>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--indigo)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-scalpel"></i> Procedure</div>
          <div style={{ fontSize: 14, fontWeight: 700, lineHeight: 1.2 }}>{sc.procedure_name}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--blue)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-eye"></i> Eye</div>
          <div style={{ fontSize: 20, fontWeight: 700, color: 'var(--blue)' }}>{sc.eye}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--green)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-package"></i> Package</div>
          <div style={{ fontSize: 13, fontWeight: 700, lineHeight: 1.2, color: sc.master_packages ? 'inherit' : 'var(--g400)' }}>{sc.master_packages?.name || 'No package'}</div>
        </div>
        <div style={{ background: '#fff', border: '1px solid var(--g200)', borderRadius: 12, padding: '12px 14px', borderLeft: '4px solid var(--amber)' }}>
          <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 4 }}><i className="ti ti-stethoscope"></i> Surgeon</div>
          <div style={{ fontSize: 13, fontWeight: 700, lineHeight: 1.2 }}>{sc.profiles?.full_name || 'Not assigned'}</div>
        </div>
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 12 }}>{error}</div>}
      {ok && <div className="msg-ok" style={{ marginBottom: 12 }}>{ok}</div>}

      {isLocked && (
        <div className="msg-info" style={{ background: 'var(--g100)', color: 'var(--g600)', padding: '9px 13px', borderRadius: 8, fontSize: 12.5, marginBottom: 12, display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className="ti ti-lock"></i>
          <span style={{ flex: 1 }}>This approval is finalized and locked for viewing.</span>
          <button className="btn btn-sm" onClick={() => setLocked(false)}>
            <i className="ti ti-lock-open"></i> Unlock to Edit
          </button>
        </div>
      )}

      <div className="card">
        {isLocked ? (
          <div style={{ fontSize: 12.5 }}>
            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 10 }}>Approved IOL</div>
            <table style={{ width: '100%', fontSize: 12.5 }}>
              <tbody>
                <tr><td style={{ color: 'var(--g500)', padding: '4px 0', width: 140 }}>Brand / Model</td><td style={{ padding: '4px 0' }}><strong>{detail.approval.master_iol_catalog?.brand} {detail.approval.master_iol_catalog?.model}</strong></td></tr>
                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Category</td><td style={{ padding: '4px 0' }}>{detail.approval.master_iol_catalog?.category || '--'}</td></tr>
                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Power</td><td style={{ padding: '4px 0' }}><strong>{detail.approval.power} D</strong></td></tr>
                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Eye</td><td style={{ padding: '4px 0' }}>{EYE_LABEL[sc.eye] || sc.eye}</td></tr>
                {detail.approval.notes && <tr><td style={{ color: 'var(--g500)', padding: '4px 0', verticalAlign: 'top' }}>Notes</td><td style={{ padding: '4px 0' }}>{detail.approval.notes}</td></tr>}
                <tr><td style={{ color: 'var(--g500)', padding: '4px 0' }}>Approved On</td><td style={{ padding: '4px 0' }}>{detail.approval.approved_at ? new Date(detail.approval.approved_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' }) : '--'}</td></tr>
              </tbody>
            </table>
          </div>
        ) : !detail.biometry ? (
          <div style={{ textAlign: 'center', padding: 20, color: 'var(--red)' }}>No measured biometry on file for this patient.</div>
        ) : (
          <>
            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Device Recommendations</div>
            {detail.recommendations.length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 10 }}>No recommendations recorded on the biometry report.</div>
            )}
            <table className="tbl" style={{ marginBottom: 14 }}>
              <thead><tr><th>Brand / Model</th><th>RE</th><th>LE</th><th></th></tr></thead>
              <tbody>
                {detail.recommendations.map((r) => (
                  <tr key={r.id} style={{ background: catalogId === r.master_iol_catalog.id ? 'var(--indigo-lt, var(--blue-lt))' : 'transparent' }}>
                    <td>{r.master_iol_catalog.brand} {r.master_iol_catalog.model}</td>
                    <td>{r.re_power ?? '--'}</td>
                    <td>{r.le_power ?? '--'}</td>
                    <td>
                      <button className="btn btn-sm" onClick={() => pickRecommendation(r)}>
                        {catalogId === r.master_iol_catalog.id ? <i className="ti ti-check"></i> : 'Use this'}
                      </button>
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ fontWeight: 600, fontSize: 12, marginBottom: 6 }}>Confirm Choice for {EYE_LABEL[sc.eye] || sc.eye}</div>
            <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 8, marginBottom: 8 }}>
              <select className="fi fi-sm" value={catalogId} onChange={(e) => setCatalogId(e.target.value)}>
                <option value="">Select brand/model...</option>
                {catalog.map((c) => <option key={c.id} value={c.id}>{c.brand} {c.model}</option>)}
              </select>
              <input className="fi fi-sm" placeholder="Power" value={power} onChange={(e) => setPower(e.target.value)} />
            </div>

            {deviates && (
              <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 11.5, marginBottom: 10 }}>
                <i className="ti ti-alert-triangle"></i>{' '}
                {deviatesNoRec
                  ? 'This brand/model has no device recommendation on file for this patient -- deviating from the biometry report.'
                  : `Device recommended ${recommendedPower ?? '--'} D for ${EYE_LABEL[sc.eye] || sc.eye}, but ${power} D is being approved -- deviating from the biometry report.`}
              </div>
            )}

            <input className="fi fi-sm" style={{ marginBottom: 12 }} placeholder="Notes (optional)" value={notes} onChange={(e) => setNotes(e.target.value)} />

            <button className="btn btn-primary" onClick={handleApprove} disabled={saving || !catalogId || !power}>
              {saving ? 'Saving...' : approved ? 'Update Approval' : 'Approve'}
            </button>
          </>
        )}
      </div>
    </div>
  );
}

// Deep-linkable via ?caseId=...&mode=view -- Surgical Journey's IOL
// Approval step links straight here with the case's id so it opens
// that patient's own record instead of dropping onto the Dashboard for
// a manual pick. mode=view additionally opens an already-approved
// record locked/read-only (the "Edit" entry point from Surgical
// Journey), matching the same treatment as Biometry.
function IolApprovalInner() {
  const searchParams = useSearchParams();
  const deepLinkCaseId = searchParams.get('caseId');
  const lockMode = searchParams.get('mode') === 'view';

  const [activeTab, setActiveTab] = useState(deepLinkCaseId ? 'workspace' : 'dashboard');
  const [selectedCaseId, setSelectedCaseId] = useState(deepLinkCaseId || null);
  const [pending, setPending] = useState([]);
  const [approvedToday, setApprovedToday] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const [pendingList, approvedList] = await Promise.all([getPendingIolApprovals(), getApprovedToday()]);
    setPending(pendingList);
    setApprovedToday(approvedList);
    setLoading(false);
  }, []);

  // Same live-queue pattern used elsewhere (Queue, OT Intraop, etc) --
  // without this, an approval made by someone else, or just leaving
  // this tab open, never shows up until a manual hard refresh.
  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  function openCase(caseId) {
    setSelectedCaseId(caseId);
    setActiveTab('workspace');
  }

  function handleBack() {
    refresh();
    setSelectedCaseId(null);
    setActiveTab('dashboard');
  }

  return (
    <div>
      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}>IOL Approval</div>
        <div style={{ fontSize: 12, color: 'var(--g500)' }}>The surgeon's final sign-off on which IOL brand/model/power to actually use, per case.</div>
      </div>

      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4, maxWidth: 420 }}>
        <TabButton active={activeTab === 'dashboard'} onClick={() => setActiveTab('dashboard')} icon="ti-layout-dashboard" label="Dashboard" />
        <TabButton active={activeTab === 'workspace'} onClick={() => setActiveTab('workspace')} icon="ti-lens" label="Workspace" disabled={!selectedCaseId} />
        <TabButton active={activeTab === 'history'} onClick={() => setActiveTab('history')} icon="ti-history" label="History" />
      </div>

      {activeTab === 'dashboard' && <DashboardTab pending={pending} approvedToday={approvedToday} loading={loading} onOpen={openCase} />}
      {activeTab === 'history' && <HistoryTab onOpen={openCase} />}
      {activeTab === 'workspace' && selectedCaseId && <WorkspaceView caseId={selectedCaseId} onBack={handleBack} onDone={refresh} initialLocked={lockMode} />}
      {activeTab === 'workspace' && !selectedCaseId && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Select a case from the Dashboard or History.</div>
      )}
    </div>
  );
}

export default function IolApprovalPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <IolApprovalInner />
    </Suspense>
  );
}
