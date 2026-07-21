'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService, deleteService,
  getPackages, addPackage, updatePackage, deletePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug, deleteDrug,
  getProcedures,
  getMasterAuditLog,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', type: 'package' }];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const ORIGINS = ['Indian', 'Imported'];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status, record.code);
    setLoading(false);
    onUpdate();
  }
  return (
    <button className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ border: 'none', cursor: 'pointer' }} onClick={handleToggle} disabled={loading}>
      {record.status}
    </button>
  );
}

export default function FinancialMastersPage() {
  const [activeTab, setActiveTab] = useState('Consultation');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [drugs, setDrugs] = useState([]);
  const [procedures, setProcedures] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const [constituentsFor, setConstituentsFor] = useState(null);
  const [constituents, setConstituents] = useState([]);
  const [newLineDesc, setNewLineDesc] = useState('');
  const [newLineAmount, setNewLineAmount] = useState('');

  const tabDef = TABS.find((t) => t.key === activeTab);
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setProcedures(await getProcedures());
    setAuditLog(await getMasterAuditLog(auditTable));
  }, [auditTable]);

  useEffect(() => { refresh(); }, [refresh]);

  const deptServices = services.filter((s) => s.dept === activeTab);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }
  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError(''); setSuccess('');
    if (tabDef.type === 'drug') {
      if (!form.generic) { setError('Generic name is required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (!form.name) {
      setError('Name is required.'); return;
    }

    let result;
    if (tabDef.type === 'package') {
      const isCataract = procedures.find((p) => p.id === form.procedureId)?.category === 'Cataract';
      result = await addPackage(isCataract ? form : { ...form, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else result = await addService({ ...form, dept: activeTab });

    if (result?.error) { setError(result.error); return; }
    setSuccess(`${form.name || form.generic} added${tabDef.type === 'package' ? ' -- add its constituents to set the price' : ''}.`);
    setForm({});
    setShowAdd(false);
    refresh();
    if (tabDef.type === 'package' && result.package) openConstituents(result.package);
  }

  function startEdit(record) {
    setError(''); setSuccess('');
    setEditingId(record.id);
    if (tabDef.type === 'package') setEditForm({ name: record.name || '', includes: record.includes || '', procedureId: record.procedure_id || '', iolCategory: record.iol_category || '', origin: record.origin || '' });
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand || '', generic: record.generic || '', strength: record.strength || '', form: record.form || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
    else setEditForm({ name: record.name || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') {
      const isCataract = procedures.find((p) => p.id === editForm.procedureId)?.category === 'Cataract';
      result = await updatePackage(record.id, record, isCataract ? editForm : { ...editForm, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else result = await updateService(record.id, record, { ...editForm, dept: record.dept });
    if (result?.error) { setError(result.error); return; }
    setSuccess('Updated.');
    setEditingId(null);
    refresh();
  }

  async function handleDelete(record) {
    if (!window.confirm(`Delete "${record.name || record.generic}"? This cannot be undone. If it's in use elsewhere, deletion will be blocked and you should mark it Inactive instead.`)) return;
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') result = await deletePackage(record.id, record.code);
    else if (tabDef.type === 'drug') result = await deleteDrug(record.id, record.code);
    else result = await deleteService(record.id, record.code);
    if (result?.error) { setError(result.error); return; }
    setSuccess('Deleted.');
    refresh();
  }

  async function openConstituents(pkg) {
    setConstituentsFor(pkg);
    setConstituents(await getPackageLineItems(pkg.id));
    setNewLineDesc(''); setNewLineAmount('');
  }

  function closeConstituents() {
    setConstituentsFor(null);
    setConstituents([]);
  }

  async function handleAddLine() {
    if (!newLineDesc.trim() || !newLineAmount) { setError('Description and amount are required.'); return; }
    setError('');
    const result = await addPackageLineItem(constituentsFor.id, newLineDesc, newLineAmount);
    if (result?.error) { setError(result.error); return; }
    setNewLineDesc(''); setNewLineAmount('');
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  async function handleRemoveLine(id) {
    await removePackageLineItem(id, constituentsFor.id);
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  const constituentsTotal = constituents.reduce((s, c) => s + Number(c.amount), 0);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div>
        <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
          {TABS.map((t) => (
            <button
              key={t.key}
              className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
              onClick={() => { setActiveTab(t.key); setShowAdd(false); setEditingId(null); setError(''); setSuccess(''); }}
            >
              {t.key}
            </button>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> {activeTab}</div>
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {(tabDef.type === 'service' || tabDef.type === 'drug') && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> Code is generated automatically from the name.
            </div>
          )}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {tabDef.type === 'service' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'drug' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Brand" onChange={update('brand')} />
                  <input className="fi" placeholder="Generic name" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <input className="fi" placeholder="Form (e.g. Eye Drop)" onChange={update('form')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'package' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery -- Standard IOL)" onChange={update('name')} />
                  <select className="fi" onChange={update('procedureId')} defaultValue="">
                    <option value="">-- Link to procedure (optional) --</option>
                    {procedures.map((p) => <option key={p.id} value={p.id}>{p.name}</option>)}
                  </select>
                  {(procedures.find((p) => p.id === form.procedureId)?.category === 'Cataract') && (
                    <>
                      <select className="fi" onChange={update('iolCategory')} defaultValue="">
                        <option value="">-- IOL type (optional) --</option>
                        {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                      </select>
                      <select className="fi" onChange={update('origin')} defaultValue="">
                        <option value="">-- Origin (optional) --</option>
                        {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                      </select>
                    </>
                  )}
                  <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 2' }} onChange={update('includes')} />
                  <div style={{ gridColumn: 'span 2', fontSize: 11, color: 'var(--g500)' }}>
                    Code auto-generates (PKG001, PKG002...). Price is set by adding constituents after saving.
                    {(procedures.find((p) => p.id === form.procedureId)?.category === 'Cataract') && (
                      <> IOL type + Origin determine which packages the Counselling module shows for a given Biometry result.</>
                    )}
                  </div>
                </div>
              )}
              <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
            </div>
          )}

          {tabDef.type === 'service' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {deptServices.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 80 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 60 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${s.status === 'Active' ? 'b-green' : 'b-gray'}`}>{s.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(s)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={s.id}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td>
                      <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(s)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {deptServices.length === 0 && (
                  <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No {activeTab.toLowerCase()} services yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Brand</th><th>Generic</th><th>Strength</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 70 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 55 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${d.status === 'Active' ? 'b-green' : 'b-gray'}`}>{d.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(d)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={d.id}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                      <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                      <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(d)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(d)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Procedure</th><th>IOL Type / Origin</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.procedureId} onChange={updateEdit('procedureId')}>
                          <option value="">--</option>
                          {procedures.map((pr) => <option key={pr.id} value={pr.id}>{pr.name}</option>)}
                        </select>
                      </td>
                      <td>
                        {(procedures.find((pr) => pr.id === editForm.procedureId)?.category === 'Cataract') ? (
                          <div style={{ display: 'flex', gap: 4 }}>
                            <select className="fi fi-sm" value={editForm.iolCategory} onChange={updateEdit('iolCategory')}>
                              <option value="">IOL type --</option>
                              {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                            </select>
                            <select className="fi fi-sm" value={editForm.origin} onChange={updateEdit('origin')}>
                              <option value="">Origin --</option>
                              {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                            </select>
                          </div>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>N/A</span>}
                      </td>
                      <td>Rs.{p.price}</td>
                      <td><span className={`badge ${p.status === 'Active' ? 'b-green' : 'b-gray'}`}>{p.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(p)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td>
                      <td style={{ fontSize: 12, color: 'var(--g500)' }}>{p.master_procedures?.name || '--'}</td>
                      <td>
                        {p.iol_category ? (
                          <span style={{ display: 'flex', gap: 4 }}>
                            <span className="badge b-purple" style={{ fontSize: 10 }}>{p.iol_category}</span>
                            {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`} style={{ fontSize: 10 }}>{p.origin}</span>}
                          </span>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>--</span>}
                      </td>
                      <td style={{ fontWeight: 600 }}>Rs.{p.price}</td>
                      <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => openConstituents(p)}><i className="ti ti-list-details"></i> Breakup</button>
                        <button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(p)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {constituentsFor && (
            <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, marginTop: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                <div style={{ fontSize: 13, fontWeight: 700 }}>
                  <i className="ti ti-list-details" style={{ color: 'var(--teal)' }}></i> Breakup -- {constituentsFor.name} ({constituentsFor.code})
                </div>
                <button className="btn btn-sm" onClick={closeConstituents}><i className="ti ti-x"></i> Close</button>
              </div>
              <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                <i className="ti ti-info-circle"></i> The package price is always the sum of these constituents.
              </div>
              <table className="tbl" style={{ marginBottom: 12 }}>
                <thead><tr><th>Description</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
                <tbody>
                  {constituents.map((c) => (
                    <tr key={c.id}>
                      <td>{c.description}</td>
                      <td style={{ textAlign: 'right' }}>Rs.{Number(c.amount).toFixed(2)}</td>
                      <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(c.id)}>Remove</button></td>
                    </tr>
                  ))}
                  {constituents.length === 0 && (
                    <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No constituents yet -- price is Rs.0 until you add some.</td></tr>
                  )}
                </tbody>
                <tfoot>
                  <tr style={{ fontWeight: 700 }}>
                    <td>Total</td><td style={{ textAlign: 'right' }}>Rs.{constituentsTotal.toFixed(2)}</td><td></td>
                  </tr>
                </tfoot>
              </table>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" placeholder="e.g. Surgeon Fee, OT Charges, IOL, Consumables..." value={newLineDesc} onChange={(e) => setNewLineDesc(e.target.value)} style={{ flex: 2 }} />
                <input type="number" className="fi" placeholder="Amount" value={newLineAmount} onChange={(e) => setNewLineAmount(e.target.value)} style={{ flex: 1 }} />
                <button className="btn btn-primary btn-sm" onClick={handleAddLine}><i className="ti ti-plus"></i> Add</button>
              </div>
            </div>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Change History -- {activeTab}
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded yet.</div>}
          {auditLog.map((a) => (
            <div key={a.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span className={`badge ${a.action === 'Create' ? 'b-green' : a.action === 'Edit' ? 'b-blue' : a.action === 'Reactivate' ? 'b-teal' : 'b-red'}`} style={{ fontSize: 10 }}>{a.action}</span>
                <span style={{ fontSize: 10, color: 'var(--g400)' }}>{new Date(a.changed_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
              </div>
              <div style={{ marginTop: 3, fontFamily: 'monospace', fontSize: 11, color: 'var(--g600)' }}>{a.record_code}</div>
              <div style={{ marginTop: 2 }}>{a.detail}</div>
              <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{a.profiles?.full_name || 'Staff'}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
