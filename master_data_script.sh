mkdir -p 'app/(main)/master-data' app/components

cat > 'app/(main)/master-data/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

// Generic toggle works the same way across all 5 master tables --
// every one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SERVICES ──
export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_services').insert({
    code: values.code, name: values.name, dept: values.dept,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── PACKAGES ──
export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_packages').insert({
    code: values.code, name: values.name, price: parseFloat(values.price) || 0,
    includes: values.includes, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*').order('generic');
  return data || [];
}
export async function addDrug(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_drugs').insert({
    code: values.code, brand: values.brand, generic: values.generic, strength: values.strength,
    form: values.form, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── DIAGNOSES ──
export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_diagnoses').insert({
    code: values.code, name: values.name, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── INVESTIGATIONS (master catalog) ──
export async function getInvestigationsMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_investigations').select('*').order('name');
  return data || [];
}
export async function addInvestigationMaster(values) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_investigations').insert({
    code: values.code, name: values.name, dept: values.dept,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/(main)/master-data/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  toggleStatus,
  getServices, addService,
  getPackages, addPackage,
  getDrugs, addDrug,
  getDiagnosesMaster, addDiagnosisMaster,
  getInvestigationsMaster, addInvestigationMaster,
} from './actions';

const TABS = [
  { key: 'services', label: 'Services', table: 'master_services' },
  { key: 'packages', label: 'Packages', table: 'master_packages' },
  { key: 'drugs', label: 'Drugs', table: 'master_drugs' },
  { key: 'diagnoses', label: 'Diagnoses', table: 'master_diagnoses' },
  { key: 'investigations', label: 'Investigations', table: 'master_investigations' },
];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status);
    setLoading(false);
    onUpdate();
  }
  return (
    <button
      className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`}
      style={{ border: 'none', cursor: 'pointer' }}
      onClick={handleToggle}
      disabled={loading}
    >
      {record.status}
    </button>
  );
}

export default function MasterDataPage() {
  const [activeTab, setActiveTab] = useState('services');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [drugs, setDrugs] = useState([]);
  const [diagnoses, setDiagnoses] = useState([]);
  const [investigations, setInvestigations] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setDiagnoses(await getDiagnosesMaster());
    setInvestigations(await getInvestigationsMaster());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError('');
    if (!form.code || !form.name && !form.generic) { setError('Code and name are required.'); return; }

    let result;
    if (activeTab === 'services') result = await addService(form);
    else if (activeTab === 'packages') result = await addPackage(form);
    else if (activeTab === 'drugs') result = await addDrug(form);
    else if (activeTab === 'diagnoses') result = await addDiagnosisMaster(form);
    else if (activeTab === 'investigations') result = await addInvestigationMaster(form);

    if (result?.error) { setError(result.error); return; }
    setForm({});
    setShowAdd(false);
    refresh();
  }

  return (
    <div>
      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        {TABS.map((t) => (
          <button
            key={t.key}
            className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
            onClick={() => { setActiveTab(t.key); setShowAdd(false); setError(''); }}
          >
            {t.label}
          </button>
        ))}
      </div>

      <div className="card">
        <div className="card-head">
          <div className="card-title">{TABS.find((t) => t.key === activeTab).label}</div>
          <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(!showAdd)}>
            <i className="ti ti-plus"></i> Add New
          </button>
        </div>

        {error && <div className="msg-err">{error}</div>}

        {showAdd && (
          <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
            {activeTab === 'services' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Name" onChange={update('name')} />
                <select className="fi" onChange={update('dept')}>
                  <option value="">Dept</option>
                  <option>Consultation</option><option>Investigation</option><option>Pharmacy</option><option>Surgery</option>
                </select>
                <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
              </div>
            )}
            {activeTab === 'packages' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Name" onChange={update('name')} />
                <input type="number" className="fi" placeholder="Price" onChange={update('price')} />
                <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 3' }} onChange={update('includes')} />
              </div>
            )}
            {activeTab === 'drugs' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Brand" onChange={update('brand')} />
                <input className="fi" placeholder="Generic name" onChange={update('generic')} />
                <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                <input className="fi" placeholder="Form (e.g. Eye Drop)" onChange={update('form')} />
                <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
              </div>
            )}
            {activeTab === 'diagnoses' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Name" onChange={update('name')} />
                <input className="fi" placeholder="Category (e.g. Lens, Retina)" onChange={update('category')} />
              </div>
            )}
            {activeTab === 'investigations' && (
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(5, 1fr)', gap: 8 }}>
                <input className="fi" placeholder="Code" onChange={update('code')} />
                <input className="fi" placeholder="Name" onChange={update('name')} />
                <input className="fi" placeholder="Dept" onChange={update('dept')} />
                <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
              </div>
            )}
            <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
          </div>
        )}

        {activeTab === 'services' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Name</th><th>Dept</th><th>Rate</th><th>GST%</th><th>Status</th></tr></thead>
            <tbody>
              {services.map((s) => (
                <tr key={s.id}>
                  <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td><td>{s.dept}</td>
                  <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                  <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {activeTab === 'packages' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Name</th><th>Price</th><th>Includes</th><th>Status</th></tr></thead>
            <tbody>
              {packages.map((p) => (
                <tr key={p.id}>
                  <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td><td>Rs.{p.price}</td><td>{p.includes}</td>
                  <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {activeTab === 'drugs' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Brand</th><th>Generic</th><th>Strength</th><th>Rate</th><th>GST%</th><th>Status</th></tr></thead>
            <tbody>
              {drugs.map((d) => (
                <tr key={d.id}>
                  <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                  <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                  <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {activeTab === 'diagnoses' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Name</th><th>Category</th><th>Status</th></tr></thead>
            <tbody>
              {diagnoses.map((d) => (
                <tr key={d.id}>
                  <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.name}</td><td>{d.category}</td>
                  <td><StatusToggle record={d} table="master_diagnoses" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}

        {activeTab === 'investigations' && (
          <table className="tbl">
            <thead><tr><th>Code</th><th>Name</th><th>Dept</th><th>Rate</th><th>GST%</th><th>Status</th></tr></thead>
            <tbody>
              {investigations.map((i) => (
                <tr key={i.id}>
                  <td style={{ fontFamily: 'monospace' }}>{i.code}</td><td>{i.name}</td><td>{i.dept}</td>
                  <td>Rs.{i.rate}</td><td>{i.gst_pct}%</td>
                  <td><StatusToggle record={i} table="master_investigations" onUpdate={refresh} /></td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}

EOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Open Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/master-data/, title: 'Master Data' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${pathname.startsWith(item.href) ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                {item.label}
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}

EOF

echo "Master Data admin module created."
