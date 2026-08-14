'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService, deleteService,
  getPackages, addPackage, updatePackage, deletePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug, deleteDrug,
  getDrugTypes, addDrugType, updateDrugType, deleteDrugType,
  getDosageOptions, addDosageOption, removeDosageOption,
  getVendorsMaster, addVendorMaster, updateVendorMaster, deleteVendorMaster,
  getSurgeries,
  getMasterAuditLog,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', label: 'Surgery', type: 'package' }, { key: 'Vendors', type: 'vendor' }];
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
  const [drugTypes, setDrugTypes] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);
  const [showTypesPanel, setShowTypesPanel] = useState(false);
  const [expandedTypeId, setExpandedTypeId] = useState(null);
  const [newTypeName, setNewTypeName] = useState('');
  const [newDosageText, setNewDosageText] = useState('');
  const [surgeries, setSurgeries] = useState([]);
  const [vendors, setVendors] = useState([]);
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
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : tabDef.type === 'vendor' ? 'inventory_vendors' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setDrugTypes(await getDrugTypes());
    setDosageOptions(await getDosageOptions());
    setSurgeries(await getSurgeries());
    setVendors(await getVendorsMaster());
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
      if (!form.generic) { setError('Salt Composition is required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (tabDef.type === 'vendor') {
      if (!form.name) { setError('Vendor name is required.'); return; }
    } else if (!form.name) {
      setError('Name is required.'); return;
    }

    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract';
      result = await addPackage(isCataract ? form : { ...form, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else if (tabDef.type === 'vendor') result = await addVendorMaster(form);
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
    if (tabDef.type === 'package') setEditForm({ name: record.name || '', includes: record.includes || '', surgeryId: record.surgery_id || '', iolCategory: record.iol_category || '', origin: record.origin || '' });
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand || '', generic: record.generic || '', strength: record.strength || '', form: record.form || '', drugTypeId: record.drug_type_id || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
    else if (tabDef.type === 'vendor') setEditForm({ name: record.name || '', contactPerson: record.contact_person || '', phone: record.phone || '', gstNumber: record.gst_number || '' });
    else setEditForm({ name: record.name || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '', investigationPackage: record.investigation_package || '' });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function handleAddType() {
    setError(''); setSuccess('');
    if (!newTypeName.trim()) return;
    const result = await addDrugType({ name: newTypeName });
    if (result?.error) { setError(result.error); return; }
    setNewTypeName('');
    refresh();
  }

  async function handleRenameType(t, name) {
    if (!name.trim() || name === t.name) return;
    await updateDrugType(t.id, t, { name });
    refresh();
  }

  async function handleAddDosage(typeId) {
    setError(''); setSuccess('');
    if (!newDosageText.trim()) return;
    const result = await addDosageOption(typeId, newDosageText);
    if (result?.error) { setError(result.error); return; }
    setNewDosageText('');
    refresh();
  }

  async function handleRemoveDosage(id) {
    await removeDosageOption(id);
    refresh();
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract';
      result = await updatePackage(record.id, record, isCataract ? editForm : { ...editForm, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else if (tabDef.type === 'vendor') result = await updateVendorMaster(record.id, record, editForm);
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
    else if (tabDef.type === 'vendor') result = await deleteVendorMaster(record.id, record.code);
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
              {t.label || t.key}
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

          {(tabDef.type === 'service' || tabDef.type === 'drug' || tabDef.type === 'vendor') && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> {tabDef.type === 'service' ? 'Code is generated automatically, linked to department (e.g. INV001, INV002...).' : tabDef.type === 'vendor' ? 'Code is generated automatically (VEN01, VEN02...). Vendor names must be unique.' : 'Code is generated automatically from the name.'}
            </div>
          )}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {tabDef.type === 'service' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                  {activeTab === 'Investigation' && (
                    <div style={{ gridColumn: 'span 3' }}>
                      <input className="fi" placeholder="Package (optional, e.g. Cataract) -- lets Counselling order this as part of a standard panel" onChange={update('investigationPackage')} />
                    </div>
                  )}
                </div>
              )}
              {tabDef.type === 'drug' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('brand')} />
                  <input className="fi" placeholder="Salt Composition" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <select className="fi" onChange={update('drugTypeId')} defaultValue="">
                    <option value="">-- Type (e.g. Eye Drop) --</option>
                    {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                  </select>
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'vendor' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Vendor / Distributor Name" onChange={update('name')} />
                  <input className="fi" placeholder="Contact Person (optional)" onChange={update('contactPerson')} />
                  <input className="fi" placeholder="Phone (optional)" onChange={update('phone')} />
                  <input className="fi" placeholder="GST Number (optional)" onChange={update('gstNumber')} />
                </div>
              )}
              {tabDef.type === 'package' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery -- Standard IOL)" onChange={update('name')} />
                  <select className="fi" onChange={update('surgeryId')} defaultValue="">
                    <option value="">-- Link to surgery (optional) --</option>
                    {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select>
                  {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
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
                    {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
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
              <thead><tr><th>Code</th><th>Name</th><th>Rate</th><th>GST%</th>{activeTab === 'Investigation' && <th>Package</th>}<th>Status</th><th></th></tr></thead>
              <tbody>
                {deptServices.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 80 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 60 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      {activeTab === 'Investigation' && (
                        <td><input className="fi fi-sm" style={{ width: 110 }} placeholder="optional" value={editForm.investigationPackage} onChange={updateEdit('investigationPackage')} /></td>
                      )}
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
                      {activeTab === 'Investigation' && <td>{s.investigation_package ? <span className="badge b-purple" style={{ fontSize: 10 }}>{s.investigation_package}</span> : <span style={{ color: 'var(--g400)' }}>--</span>}</td>}
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(s)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {deptServices.length === 0 && (
                  <tr><td colSpan={activeTab === 'Investigation' ? 7 : 6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No {activeTab.toLowerCase()} services yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Salt Composition</th><th>Strength</th><th>Type</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.drugTypeId || ''} onChange={updateEdit('drugTypeId')}>
                          <option value="">-- Type --</option>
                          {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                        </select>
                      </td>
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
                      <td>{d.master_drug_types?.name || <span style={{ color: 'var(--g400)' }}>-- unset --</span>}</td>
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

          {tabDef.type === 'vendor' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Contact Person</th><th>Phone</th><th>GST Number</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {vendors.map((v) => (
                  editingId === v.id ? (
                    <tr key={v.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input className="fi fi-sm" value={editForm.contactPerson} onChange={updateEdit('contactPerson')} /></td>
                      <td><input className="fi fi-sm" value={editForm.phone} onChange={updateEdit('phone')} /></td>
                      <td><input className="fi fi-sm" value={editForm.gstNumber} onChange={updateEdit('gstNumber')} /></td>
                      <td><span className={`badge ${v.status === 'Active' ? 'b-green' : 'b-gray'}`}>{v.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(v)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={v.id}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td><td style={{ fontWeight: 600 }}>{v.name}</td>
                      <td>{v.contact_person || '--'}</td><td>{v.phone || '--'}</td><td>{v.gst_number || '--'}</td>
                      <td><StatusToggle record={v} table="inventory_vendors" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(v)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(v)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {vendors.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No vendors yet. Add one to start using it in Inventory &gt; Material Input.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <div className="card" style={{ marginTop: 16 }}>
              <div className="card-head" style={{ cursor: 'pointer' }} onClick={() => setShowTypesPanel((p) => !p)}>
                <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-category-2" style={{ color: 'var(--purple)' }}></i> Manage Drug Types &amp; Dosage Options</div>
                <i className={`ti ti-chevron-${showTypesPanel ? 'up' : 'down'}`}></i>
              </div>
              {showTypesPanel && (
                <div style={{ marginTop: 12 }}>
                  <div className="msg-info" style={{ marginBottom: 12 }}>
                    <i className="ti ti-info-circle"></i> Each type&apos;s dosage options are what shows up in the doctor&apos;s Prescription dosage dropdown when a drug of that type is selected -- e.g. &quot;Apply thin layer&quot; for Eye Ointment instead of &quot;1 drop&quot;.
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                    <input className="fi" style={{ maxWidth: 260 }} placeholder="New type name (e.g. Suspension)" value={newTypeName} onChange={(e) => setNewTypeName(e.target.value)} />
                    <button className="btn btn-primary" onClick={handleAddType}>Add Type</button>
                  </div>
                  {drugTypes.map((t) => (
                    <div key={t.id} style={{ border: '1px solid var(--g100)', borderRadius: 8, marginBottom: 8, overflow: 'hidden' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: 'var(--g50)' }}>
                        <button className="btn btn-sm" onClick={() => setExpandedTypeId((id) => (id === t.id ? null : t.id))}>
                          <i className={`ti ti-chevron-${expandedTypeId === t.id ? 'up' : 'down'}`}></i>
                        </button>
                        <input
                          className="fi fi-sm" style={{ maxWidth: 220, fontWeight: 600 }}
                          defaultValue={t.name}
                          onBlur={(e) => handleRenameType(t, e.target.value)}
                        />
                        <span style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{t.code}</span>
                        <span style={{ marginLeft: 'auto' }}><StatusToggle record={t} table="master_drug_types" onUpdate={refresh} /></span>
                      </div>
                      {expandedTypeId === t.id && (
                        <div style={{ padding: 12 }}>
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).map((o) => (
                            <div key={o.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
                              <span style={{ fontSize: 13 }}>{o.dosage_text}</span>
                              <button className="btn btn-sm" style={{ marginLeft: 'auto', padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveDosage(o.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i>
                              </button>
                            </div>
                          ))}
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).length === 0 && (
                            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No dosage options yet for this type.</div>
                          )}
                          <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                            <input className="fi fi-sm" placeholder="e.g. Apply thin layer" value={newDosageText} onChange={(e) => setNewDosageText(e.target.value)} />
                            <button className="btn btn-sm btn-primary" onClick={() => handleAddDosage(t.id)}>Add</button>
                          </div>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Surgery</th><th>IOL Type / Origin</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  <Fragment key={p.id}>
                  {editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.surgeryId} onChange={updateEdit('surgeryId')}>
                          <option value="">--</option>
                          {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                        </select>
                      </td>
                      <td>
                        {(surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract') ? (
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
                      <td style={{ fontSize: 12, color: 'var(--g500)' }}>{p.master_surgeries?.name || '--'}</td>
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
                  )}

                  {constituentsFor?.id === p.id && (
                    <tr>
                      <td colSpan={7} style={{ padding: 0, border: 'none' }}>
                        <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, margin: '4px 0 12px' }}>
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
                      </td>
                    </tr>
                  )}
                  </Fragment>
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
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
                <span style={{ fontSize: 10, color: 'var(--g400)' }}>{new Date(a.changed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
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
