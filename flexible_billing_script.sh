mkdir -p "app/(main)/billing" "app/(main)/billing/new" "app/(main)/billing/cancel" "app/(main)/front-office-dashboard"

cat > "app/(main)/billing/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getTodaysVisitsForBilling() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at, patients(id, first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

// Lists every invoice already on a visit -- used both by New Invoice
// (to show what exists before deciding to create another) and by
// Invoice Modification (to jump straight to a visit's invoice(s)
// instead of a generic search).
export async function getInvoicesForVisit(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('visit_id', visitId)
    .order('created_at', { ascending: false });
  if (error) return { error: error.message };
  return { invoices: data || [] };
}

// Always creates a brand new invoice -- creating one is now always a
// deliberate action (the "New Invoice" button + a chosen purpose), so
// there's no "get or reuse" ambiguity here. Adding to an existing
// invoice happens through Invoice Modification instead.
export async function createInvoiceForVisit(patientId, visitId, purpose) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_invoice_for_visit', {
    p_patient_id: patientId,
    p_visit_id: visitId || null,
    p_purpose: purpose || 'Consultation',
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data: services } = await supabase.from('master_services').select('*').eq('status', 'Active');
  const { data: drugs } = await supabase.from('master_drugs').select('*').eq('status', 'Active');

  // Drugs live in their own master (managed under Master Data -> Drugs)
  // but bill under the Pharmacy department -- mapped here rather than
  // duplicated into master_services, so Master Data stays the one
  // place to manage drug pricing.
  const drugsAsServices = (drugs || []).map((d) => ({
    code: d.code,
    name: `${d.generic}${d.strength ? ' ' + d.strength : ''}${d.brand ? ' (' + d.brand + ')' : ''}`,
    dept: 'Pharmacy',
    rate: d.rate,
    gst_pct: d.gst_pct,
    status: d.status,
  }));

  return [...(services || []), ...drugsAsServices].sort((a, b) => a.name.localeCompare(b.name));
}

export async function addLineItem(invoiceId, serviceCode, qty, discType, discValue, discReason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
    p_disc_type: discType || 'none',
    p_disc_value: discValue || 0,
    p_disc_reason: discReason || null,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── NEW INVOICE (standalone, not tied to visit creation) ──
export async function searchPatientsForInvoice(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,mobile.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getMostRecentVisitForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('visits')
    .select('id, visit_number, visit_type, created_at')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  return data || null;
}
export async function getVisitWithPatient(visitId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();
  if (error) return { error: error.message };
  return { visit: data };
}

export async function getInvoiceById(invoiceId) {
  const supabase = await createClient();
  const { data: invoice, error } = await supabase.from('invoices').select('*, patients(first_name, last_name, uhid, mobile)').eq('id', invoiceId).single();
  if (error) return { error: error.message };
  const { data: lineItems } = await supabase.from('invoice_line_items').select('*').eq('invoice_id', invoiceId).order('id');
  return { invoice, lineItems: lineItems || [] };
}

export async function removeLineItem(lineItemId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId, p_reason: reason || null });
  if (error) return { error: error.message };
  return { success: true };
}

export async function cancelInvoice(invoiceId, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('cancel_invoice', { p_invoice_id: invoiceId, p_reason: reason });
  if (error) return { error: error.message };
  return { success: true };
}

// ── PACKAGE BILLING ──
export async function getPostSurgicalPendingPackages() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('surgical_cases')
    .select('*, patients(id, first_name, last_name, uhid), master_packages(id, name, price)')
    .eq('status', 'Completed')
    .eq('package_billed', false);
  return data || [];
}

export async function getActivePackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function searchPatientsForPackage(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function generatePackageInvoice(patientId, packageId, paymentMode, advanceAmount, surgicalCaseId) {
  const supabase = await createClient();

  const { data: visit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data, error } = await supabase.rpc('generate_package_invoice', {
    p_patient_id: patientId,
    p_visit_id: visit?.id || null,
    p_package_id: packageId,
    p_payment_mode: paymentMode,
    p_advance_amount: advanceAmount || 0,
    p_surgical_case_id: surgicalCaseId || null,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── INVOICE DETAILS (search + history) ──
export async function getTodaysInvoicesForModification() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const { data } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid)')
    .gte('created_at', today)
    .order('created_at', { ascending: false });
  return data || [];
}

export async function searchInvoices(query, deptFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid), visits(visit_number)')
    .order('created_at', { ascending: false })
    .limit(50);

  if (query) {
    // First try to match by patient -- invoices don't carry patient
    // name/uhid directly, so we resolve matching patient ids first.
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    if (ids.length === 0) return [];
    q = q.in('patient_id', ids);
  }

  const { data: invoices } = await q;
  if (!invoices || invoices.length === 0) return [];

  if (!deptFilter) return invoices;

  // Department filter is per-line-item, not per-invoice -- keep only
  // invoices that have at least one line item in that department.
  const invoiceIds = invoices.map((i) => i.id);
  const { data: lines } = await supabase.from('invoice_line_items').select('invoice_id, dept').in('invoice_id', invoiceIds).eq('dept', deptFilter);
  const matchingIds = new Set((lines || []).map((l) => l.invoice_id));
  return invoices.filter((i) => matchingIds.has(i.id));
}

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}


EOF

cat > "app/(main)/billing/new/new-invoice-tab.js" << 'EOF'
'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  getMostRecentVisitForPatient,
  getVisitWithPatient,
  getInvoicesForVisit,
  createInvoiceForVisit,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  removeLineItem,
  getTodaysVisitsForBilling,
} from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const PURPOSES = ['Consultation', 'Investigation', 'Pharmacy', 'Surgery', 'Combined', 'Other'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);

  // Context: who we're billing, and what visit (if any) it's tied to.
  const [contextPatient, setContextPatient] = useState(null);
  const [contextVisit, setContextVisit] = useState(null);
  const [existingInvoices, setExistingInvoices] = useState([]);
  const [purpose, setPurpose] = useState('Consultation');
  const [creating, setCreating] = useState(false);

  const [invoice, setInvoice] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);

  const [dept, setDept] = useState('');
  const [selectedServiceCode, setSelectedServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [error, setError] = useState('');
  const [finalized, setFinalized] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);
  const router = useRouter();
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const contextLoadedFor = useRef(null);

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
    getTodaysVisitsForBilling().then(setTodaysVisits);
  }, []);

  // Arrived via a "New Invoice" link elsewhere in the app -- load the
  // visit + patient context and show what invoices already exist
  // before offering to create another. Never auto-creates anything.
  useEffect(() => {
    if (!urlVisitId) return;
    if (contextLoadedFor.current === urlVisitId) return;
    contextLoadedFor.current = urlVisitId;
    (async () => {
      const details = await getVisitWithPatient(urlVisitId);
      if (details.error) { setError(details.error); return; }
      setContextPatient(details.visit.patients);
      setContextVisit(details.visit);
      const invResult = await getInvoicesForVisit(urlVisitId);
      setExistingInvoices(invResult.invoices || []);
    })();
  }, [urlVisitId]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    const results = await searchPatientsForInvoice(searchQuery.trim());
    setSearchResults(results);
  }

  async function pickPatient(p) {
    setError('');
    setSearchResults([]);
    setSearchQuery('');
    setContextPatient(p);
    const visit = await getMostRecentVisitForPatient(p.id);
    setContextVisit(visit);
    if (visit) {
      const invResult = await getInvoicesForVisit(visit.id);
      setExistingInvoices(invResult.invoices || []);
    } else {
      setExistingInvoices([]);
    }
  }

  async function pickVisit(v) {
    setError('');
    setContextPatient(v.patients);
    setContextVisit(v);
    const invResult = await getInvoicesForVisit(v.id);
    setExistingInvoices(invResult.invoices || []);
  }

  async function openExistingInvoice(inv) {
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function handleCreateInvoice() {
    setError('');
    setCreating(true);
    const result = await createInvoiceForVisit(contextPatient.id, contextVisit?.id || null, purpose);
    setCreating(false);
    if (result.error) { setError(result.error); return; }
    const details = await getInvoiceById(result.invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function refreshInvoice() {
    const details = await getInvoiceById(invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  function handleDeptChange(e) {
    setDept(e.target.value);
    setSelectedServiceCode('');
    setRate('');
    setGstPct('');
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setSelectedServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  async function handleAddLine() {
    setError('');
    if (!selectedServiceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(invoice.id, selectedServiceCode, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }

    setDept(''); setSelectedServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
    refreshInvoice();
  }

  async function handleRemoveLine(id) {
    await removeLineItem(id);
    refreshInvoice();
  }

  function startOver() {
    setContextPatient(null);
    setContextVisit(null);
    setExistingInvoices([]);
    setInvoice(null);
    setLineItems([]);
    setFinalized(false);
    contextLoadedFor.current = null;
    router.push('/billing/new');
  }

  function handleFinalize() {
    setError('');
    if (lineItems.length === 0) { setError('Add at least one line item before finalizing.'); return; }
    setFinalized(true);
  }

  function handleSaveDraft() {
    router.push('/billing/details');
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Invoice
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!contextPatient ? (
          <div>
            <label className="flbl">Find patient (name, UHID, or mobile)</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid} -- {p.mobile}
                  </div>
                ))}
              </div>
            )}
          </div>
        ) : finalized ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Invoice finalized for {contextPatient.first_name} {contextPatient.last_name} -- Net Rs.{invoice.net}.{' '}
            <a href={`/billing/details?q=${contextPatient.uhid}`} style={{ color: 'var(--blue)' }}>Go collect payment in Invoice Details &rarr;</a>
            <div style={{ marginTop: 10, display: 'flex', gap: 8 }}>
              <a href={`/invoice-print/${invoice.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <button className="btn btn-sm" onClick={startOver}>Start a new invoice</button>
            </div>
          </div>
        ) : !invoice ? (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span>
                <strong>{contextPatient.first_name} {contextPatient.last_name}</strong> -- {contextPatient.uhid}
                {contextVisit && <span style={{ color: 'var(--g500)' }}> -- Visit {contextVisit.visit_number || '--'}</span>}
              </span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            {existingInvoices.length > 0 && (
              <div style={{ marginBottom: 16 }}>
                <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>
                  This visit already has {existingInvoices.length} invoice{existingInvoices.length > 1 ? 's' : ''}
                </div>
                {existingInvoices.map((inv) => (
                  <div key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 10px', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 6 }}>
                    <div>
                      <span style={{ fontFamily: 'monospace', fontWeight: 700, fontSize: 12 }}>{inv.invoice_number}</span>
                      <span style={{ marginLeft: 8, fontSize: 12, color: 'var(--g500)' }}>{inv.purpose} -- Rs.{inv.net}</span>
                    </div>
                    <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                      <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                      <a href={`/billing/cancel?visitId=${contextVisit.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                        Modify
                      </a>
                    </div>
                  </div>
                ))}
                <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginTop: 8 }}>
                  <i className="ti ti-info-circle"></i> To add items to one of these, use <strong>Modify</strong> above instead of creating a new invoice.
                </div>
              </div>
            )}

            <div style={{ border: '1.5px dashed var(--g200)', borderRadius: 8, padding: 14 }}>
              <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 10 }}>
                <i className="ti ti-plus"></i> Start a new invoice
              </div>
              <label className="flbl">Purpose</label>
              <select className="fi" value={purpose} onChange={(e) => setPurpose(e.target.value)} style={{ marginBottom: 10 }}>
                {PURPOSES.map((p) => <option key={p} value={p}>{p}</option>)}
              </select>
              <button className="btn btn-primary" onClick={handleCreateInvoice} disabled={creating}>
                {creating ? 'Creating...' : 'Create Invoice'}
              </button>
            </div>
          </div>
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span>
                <strong>{contextPatient.first_name} {contextPatient.last_name}</strong> -- {contextPatient.uhid}
                <span style={{ marginLeft: 8 }} className="badge b-blue">{invoice.purpose}</span>
              </span>
              <button className="btn btn-sm" onClick={startOver}>Change / New</button>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Department *</label>
                <select className="fi" value={dept} onChange={handleDeptChange}>
                  <option value="">-- Select --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Service *</label>
                <select className="fi" value={selectedServiceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">{dept ? '-- Select --' : '-- Select dept first --'}</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name}</option>)}
                </select>
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
              <div>
                <label className="flbl">Qty</label>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
              </div>
              <div>
                <label className="flbl">Unit rate (Rs.)</label>
                <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
              </div>
              <div>
                <label className="flbl">GST %</label>
                <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
              </div>
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
              <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                <option value="none">No discount</option>
                <option value="pct">Percentage (%)</option>
                <option value="fixed">Fixed (Rs.)</option>
              </select>
              <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
              <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
            </div>

            <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
              <i className="ti ti-plus"></i> Add line item
            </button>

            <table className="tbl">
              <thead><tr><th>Service</th><th>Qty</th><th>Rate</th><th>Disc</th><th>GST</th><th>Net</th><th></th></tr></thead>
              <tbody>
                {lineItems.map((li) => (
                  <tr key={li.id}>
                    <td>{li.service_name}</td>
                    <td>{li.qty}</td>
                    <td>Rs.{li.rate}</td>
                    <td>{li.disc > 0 ? `Rs.${li.disc}` : '--'}</td>
                    <td>Rs.{li.gst_amount}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{li.net}</td>
                    <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(li.id)}>Remove</button></td>
                  </tr>
                ))}
                {lineItems.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet.</td></tr>
                )}
              </tbody>
            </table>

            <div style={{ display: 'flex', gap: 8, marginTop: 16 }}>
              <button className="btn btn-green" onClick={handleFinalize}>
                <i className="ti ti-circle-check"></i> Finalize invoice
              </button>
              <button className="btn" onClick={handleSaveDraft}>
                <i className="ti ti-device-floppy"></i> Save draft
              </button>
            </div>
          </div>
        )}
      </div>

      <div>
        <div className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to bill against it.</div>
          {todaysVisits.map((v) => (
            <div
              key={v.id}
              onClick={() => pickVisit(v)}
              style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}
            >
              <strong>{v.patients?.first_name} {v.patients?.last_name}</strong>
              <div style={{ color: 'var(--g500)' }}>{v.visit_number} -- {v.visit_type}</div>
            </div>
          ))}
          {todaysVisits.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>}
        </div>

        {invoice && (
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> {invoice.invoice_number || 'Invoice Summary'}
            </div>
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Gross</span><span>Rs.{invoice.gross}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>GST</span><span>Rs.{invoice.gst}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Net Total</span><span>Rs.{invoice.net}</span></div>
              <div style={{ marginTop: 8 }}><span className={`badge ${invoice.status === 'Paid' ? 'b-green' : 'b-amber'}`}>{invoice.status}</span></div>
            </div>
          </div>
        )}
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/billing/cancel/page.js" << 'EOF'
import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import InvoiceModificationTab from './invoice-modification-tab';

export default function InvoiceModificationPage() {
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoiceModificationTab />
      </Suspense>
    </div>
  );
}

EOF

cat > "app/(main)/billing/cancel/invoice-modification-tab.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchInvoices, getInvoiceById, getServiceCatalog, addLineItem, removeLineItem, cancelInvoice, getTodaysInvoicesForModification, getInvoicesForVisit } from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);
  const [visitInvoices, setVisitInvoices] = useState(null);
  const searchParams = useSearchParams();
  const urlVisitId = searchParams.get('visitId');
  const visitLoadedFor = useRef(null);

  const [dept, setDept] = useState('');
  const [serviceCode, setServiceCode] = useState('');
  const [qty, setQty] = useState(1);
  const [rate, setRate] = useState('');
  const [gstPct, setGstPct] = useState('');
  const [discType, setDiscType] = useState('none');
  const [discValue, setDiscValue] = useState('');
  const [discReason, setDiscReason] = useState('');

  const [removeReasonFor, setRemoveReasonFor] = useState(null);
  const [removeReason, setRemoveReason] = useState('');

  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');
  const [todaysInvoices, setTodaysInvoices] = useState([]);
  const [searched, setSearched] = useState(false);
  const [confirmedMessage, setConfirmedMessage] = useState('');

  const loadToday = useCallback(async () => {
    setTodaysInvoices(await getTodaysInvoicesForModification());
  }, []);

  useEffect(() => { getServiceCatalog().then(setCatalog); loadToday(); }, [loadToday]);

  // Arrived via "Modify" from Front Office Dashboard or New Invoice --
  // jump straight to this visit's invoice(s) instead of a generic
  // search. If there's exactly one, open it directly; if more than
  // one, show them as a pre-filtered pick list.
  useEffect(() => {
    if (!urlVisitId) return;
    if (visitLoadedFor.current === urlVisitId) return;
    visitLoadedFor.current = urlVisitId;
    (async () => {
      const result = await getInvoicesForVisit(urlVisitId);
      const invoices = result.invoices || [];
      if (invoices.length === 1) {
        openInvoice(invoices[0]);
      } else {
        setVisitInvoices(invoices);
      }
    })();
  }, [urlVisitId]);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setVisitInvoices(null);
    setResults(await searchInvoices(searchQuery.trim()));
    setSearched(true);
  }

  async function openInvoice(inv) {
    setError(''); setInfo(''); setConfirmedMessage('');
    const details = await getInvoiceById(inv.id);
    if (details.error) { setError(details.error); return; }
    setSelected(details.invoice);
    setLineItems(details.lineItems);
    setShowCancelForm(false);
    setCancelReason('');
  }

  async function refresh() {
    const details = await getInvoiceById(selected.id);
    setSelected(details.invoice);
    setLineItems(details.lineItems);
  }

  function handleServiceChange(e) {
    const code = e.target.value;
    setServiceCode(code);
    const svc = catalog.find((s) => s.code === code);
    setRate(svc ? svc.rate : '');
    setGstPct(svc ? svc.gst_pct : '');
  }

  async function handleAddLine() {
    setError('');
    if (!serviceCode) { setError('Select department and service.'); return; }
    if (discType !== 'none' && !discReason.trim()) { setError('A discount reason is required whenever a discount is applied.'); return; }

    const result = await addLineItem(selected.id, serviceCode, parseInt(qty, 10) || 1, discType, parseFloat(discValue) || 0, discReason);
    if (result.error) { setError(result.error); return; }
    setDept(''); setServiceCode(''); setQty(1); setRate(''); setGstPct('');
    setDiscType('none'); setDiscValue(''); setDiscReason('');
    refresh();
  }

  async function confirmRemoveLine() {
    setError('');
    if (!removeReason.trim()) { setError('A reason is required to remove a line item from an existing invoice.'); return; }
    const result = await removeLineItem(removeReasonFor, removeReason);
    if (result.error) { setError(result.error); return; }
    setRemoveReasonFor(null);
    setRemoveReason('');
    setInfo('Line item removed and logged.');
    refresh();
  }

  function handleConfirmModification() {
    setConfirmedMessage(`Modification confirmed for ${selected.invoice_number} -- Net Total: Rs.${selected.net}.`);
    setSelected(null);
    setLineItems([]);
    loadToday();
  }

  async function handleCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A cancellation reason is required.'); return; }
    const result = await cancelInvoice(selected.id, cancelReason);
    if (result.error) { setError(result.error); return; }
    setInfo('Invoice cancelled and logged for audit.');
    setShowCancelForm(false);
    setCancelReason('');
    refresh();
    loadToday();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.3fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Find Invoice
        </div>
        {confirmedMessage && (
          <div className="msg-success"><i className="ti ti-circle-check"></i> {confirmedMessage}</div>
        )}
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={searchQuery} onChange={(e) => { setSearchQuery(e.target.value); setSearched(false); }} placeholder="Patient name or UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
        </div>

        {visitInvoices ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6 }}>
              Invoices for this visit
            </div>
            {visitInvoices.map((inv) => (
              <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.purpose}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {visitInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices found for this visit.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => setVisitInvoices(null)}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : searched ? (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>
              Search Results
            </div>
            {results.map((inv) => (
              <div key={inv.id} onClick={() => openInvoice(inv)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g500)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No matches found.</div>}
            <button className="btn btn-sm" style={{ marginTop: 10 }} onClick={() => { setSearched(false); setSearchQuery(''); }}>
              &larr; Back to today&apos;s invoices
            </button>
          </>
        ) : (
          <>
            <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--blue)', textTransform: 'uppercase', marginBottom: 6, display: 'flex', alignItems: 'center', gap: 6 }}>
              <i className="ti ti-calendar-event"></i> Today&apos;s Invoices
              <span className="badge b-blue">{todaysInvoices.length}</span>
            </div>
            {todaysInvoices.map((inv) => (
              <div
                key={inv.id}
                onClick={() => openInvoice(inv)}
                style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12, background: 'var(--blue-lt)', borderRadius: 4, marginBottom: 4 }}
              >
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{inv.patients?.first_name} {inv.patients?.last_name}</strong>
                  <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{inv.status}</span>
                </div>
                <div style={{ color: 'var(--g600)', fontFamily: 'monospace' }}>{inv.invoice_number} -- Rs.{inv.net}</div>
              </div>
            ))}
            {todaysInvoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No invoices generated today yet.</div>}
          </>
        )}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.invoice_number}</div>
            <div style={{ display: 'flex', gap: 8, alignItems: 'center' }}>
              <a href={`/invoice-print/${selected.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-printer"></i> Print / PDF
              </a>
              <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
            </div>
          </div>
          <div style={{ fontSize: 13, marginBottom: 12 }}>
            <strong>{selected.patients?.first_name} {selected.patients?.last_name}</strong> -- {selected.patients?.uhid}
          </div>

          {error && <div className="msg-err">{error}</div>}
          {info && <div className="msg-success"><i className="ti ti-circle-check"></i> {info}</div>}

          <table className="tbl">
            <thead><tr><th>Service</th><th>Qty</th><th>Net</th><th></th></tr></thead>
            <tbody>
              {lineItems.map((li) => (
                <tr key={li.id}>
                  <td>{li.service_name}</td>
                  <td>{li.qty}</td>
                  <td>Rs.{li.net}</td>
                  <td>
                    {selected.status !== 'Cancelled' && (
                      <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => { setRemoveReasonFor(li.id); setRemoveReason(''); setError(''); }}>
                        Remove
                      </button>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>

          {removeReasonFor && (
            <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12, marginTop: 10 }}>
              <label className="flbl">Reason for removing this line item *</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={removeReason} onChange={(e) => setRemoveReason(e.target.value)} placeholder="e.g. Billed in error" />
                <button className="btn btn-primary btn-sm" onClick={confirmRemoveLine}>Confirm</button>
                <button className="btn btn-sm" onClick={() => setRemoveReasonFor(null)}>Cancel</button>
              </div>
            </div>
          )}

          {selected.status !== 'Cancelled' && (
            <>
              <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', margin: '16px 0 8px' }}>Add Line Item</div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
                <select className="fi" value={dept} onChange={(e) => { setDept(e.target.value); setServiceCode(''); setRate(''); setGstPct(''); }}>
                  <option value="">-- Dept --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
                <select className="fi" value={serviceCode} onChange={handleServiceChange} disabled={!dept}>
                  <option value="">-- Service --</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 8, marginBottom: 8 }}>
                <div>
                  <label className="flbl">Qty</label>
                  <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
                </div>
                <div>
                  <label className="flbl">Unit rate (Rs.)</label>
                  <input className="fi" value={rate} readOnly style={{ background: 'var(--g50)' }} />
                </div>
                <div>
                  <label className="flbl">GST %</label>
                  <input className="fi" value={gstPct} readOnly style={{ background: 'var(--g50)' }} />
                </div>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 2fr', gap: 8, marginBottom: 10 }}>
                <select className="fi" value={discType} onChange={(e) => setDiscType(e.target.value)}>
                  <option value="none">No discount</option>
                  <option value="pct">Percentage (%)</option>
                  <option value="fixed">Fixed (Rs.)</option>
                </select>
                <input type="number" className="fi" value={discValue} onChange={(e) => setDiscValue(e.target.value)} placeholder="Discount value" disabled={discType === 'none'} />
                <input className="fi" value={discReason} onChange={(e) => setDiscReason(e.target.value)} placeholder="Reason (required if discounted)" disabled={discType === 'none'} />
              </div>
              <button className="btn btn-primary btn-sm" onClick={handleAddLine} style={{ marginBottom: 16 }}>
                <i className="ti ti-plus"></i> Add
              </button>
            </>
          )}

          <div style={{ borderTop: '1px solid var(--g200)', paddingTop: 12, marginTop: 4 }}>
            <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Net Total: Rs.{selected.net} -- Paid: Rs.{selected.paid}</div>

            {selected.status === 'Cancelled' ? (
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>
                <i className="ti ti-x-circle" style={{ color: 'var(--red)' }}></i> Cancelled -- reason: {selected.cancellation_reason}
              </div>
            ) : selected.paid > 0 ? (
              <div className="msg-info" style={{ margin: 0 }}>
                <i className="ti ti-info-circle"></i> This invoice has payments recorded and cannot be cancelled. Contact an administrator if needed.
              </div>
            ) : !showCancelForm ? (
              <button className="btn" style={{ color: 'var(--red)' }} onClick={() => setShowCancelForm(true)}>
                <i className="ti ti-x-circle"></i> Cancel Invoice
              </button>
            ) : (
              <div style={{ border: '1.5px solid var(--red-lt)', borderRadius: 8, padding: 12 }}>
                <label className="flbl">Cancellation reason *</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} />
                  <button className="btn btn-sm" style={{ background: 'var(--red)', color: '#fff', borderColor: 'transparent' }} onClick={handleCancel}>Confirm Cancel</button>
                  <button className="btn btn-sm" onClick={() => setShowCancelForm(false)}>Back</button>
                </div>
              </div>
            )}

            {selected.status !== 'Cancelled' && !showCancelForm && (
              <button className="btn btn-green" style={{ marginTop: 12 }} onClick={handleConfirmModification}>
                <i className="ti ti-circle-check"></i> Confirm Modification &amp; Close
              </button>
            )}
          </div>
        </div>
      )}
    </div>
  );
}


EOF

cat > "app/(main)/front-office-dashboard/page.js" << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';
import CheckInButton from '@/app/(main)/appointments/check-in-button';
import RegisterUnregisteredButton from '@/app/(main)/appointments/register-button';

function elapsedMin(iso) {
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

const BILLING_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', '--': 'b-gray' };
const APPT_STATUS_BADGE = { Booked: 'b-amber', 'Checked-in': 'b-green', Cancelled: 'b-red', 'No-show': 'b-gray' };

export default async function FrontOfficeDashboardPage({ searchParams }) {
  const params = await searchParams;
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [
    { data: todaysRegistrations },
    { data: queueEntries },
    { count: walkInsToday },
    { data: pendingInvoices },
    { data: todaysVisits },
    { data: todaysAppointments },
    { count: surgicalPendingWorkup },
  ] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }).gte('created_at', today),
    supabase.from('queue_entries').select('*, visits(patients(first_name, last_name))').neq('status', 'Done').order('issued_at', { ascending: true }),
    supabase.from('visits').select('*', { count: 'exact', head: true }).gte('created_at', today).is('appointment_id', null),
    supabase.from('invoices').select('net, paid').in('status', ['Pending', 'Partial']),
    supabase.from('visits').select('*, patients(first_name, last_name, uhid), profiles(full_name)').gte('created_at', today).order('created_at', { ascending: false }),
    supabase.from('appointments').select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)').eq('appointment_date', today).order('appointment_time', { ascending: true }),
    supabase.from('surgical_cases').select('*', { count: 'exact', head: true }).eq('status', 'Pending Workup'),
  ]);

  const waitingEntries = (queueEntries || []).filter((e) => e.status === 'Waiting');
  const avgWait = waitingEntries.length
    ? Math.round(waitingEntries.reduce((s, e) => s + elapsedMin(e.issued_at), 0) / waitingEntries.length)
    : 0;

  const outstandingTotal = (pendingInvoices || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0);
  const unregisteredCount = (todaysAppointments || []).filter((a) => !a.patients).length;

  // Billing status per visit, batched in one query rather than per-row.
  const visitIds = (todaysVisits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, status').in('visit_id', visitIds);
    (invoices || []).forEach((inv) => { billingByVisit[inv.visit_id] = inv.status; });
  }

  const visitTypeCounts = {};
  (todaysVisits || []).forEach((v) => {
    visitTypeCounts[v.visit_type] = (visitTypeCounts[v.visit_type] || 0) + 1;
  });
  const totalVisitsToday = todaysVisits?.length || 0;

  return (
    <div>
      {params?.registered && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Registered successfully -- UHID: <strong>{params.registered}</strong>
        </div>
      )}
      {params?.visitCreated && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Visit created successfully.
        </div>
      )}
      {params?.linked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Patient registered and linked to their appointment.
        </div>
      )}
      {params?.booked && (
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Appointment booked successfully.
        </div>
      )}

      {/* QUICK ACTIONS */}
      <div className="card" style={{ marginBottom: 16, padding: '14px 16px' }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', flexWrap: 'wrap', gap: 10 }}>
          <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.4px' }}>
            Quick Actions
          </div>
          <div style={{ display: 'flex', gap: 10, flexWrap: 'wrap' }}>
            <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
              <i className="ti ti-user-plus"></i> New Registration
            </Link>
            <Link href="/appointments/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-calendar-plus"></i> Book Appointment
            </Link>
            <Link href="/visits/new" className="btn" style={{ textDecoration: 'none' }}>
              <i className="ti ti-stethoscope"></i> New Visit
            </Link>
          </div>
        </div>
      </div>

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Visits</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{totalVisitsToday}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>{todaysRegistrations ?? 0} new registrations</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Patients Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingEntries.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Avg wait: {avgWait} min</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{todaysAppointments?.length ?? 0}</div>
          {unregisteredCount > 0 && <div style={{ fontSize: 11, color: 'var(--red)', marginTop: 2 }}>{unregisteredCount} not registered</div>}
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--red)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Billing Pending</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{pendingInvoices?.length ?? 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Rs.{outstandingTotal.toLocaleString('en-IN')} outstanding</div>
        </div>
      </div>

      {/* TODAY'S APPOINTMENTS */}
      <div className="card" style={{ marginBottom: 20 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-calendar-event" style={{ color: 'var(--green)' }}></i> Today&apos;s Appointments
        </div>
        <table className="tbl">
          <thead><tr><th>Time</th><th>Patient</th><th>Mobile</th><th>Type</th><th>Doctor</th><th>Status</th><th></th></tr></thead>
          <tbody>
            {(todaysAppointments || []).map((a) => {
              const isRegistered = !!a.patients;
              const name = isRegistered ? `${a.patients.first_name} ${a.patients.last_name}` : a.patient_name_temp;
              const mobile = isRegistered ? a.patients.mobile : a.mobile_temp;
              return (
                <tr key={a.id}>
                  <td style={{ fontWeight: 600 }}>{a.appointment_time?.slice(0, 5)}</td>
                  <td>{name}</td>
                  <td>{mobile}</td>
                  <td>{a.visit_type}</td>
                  <td>{a.profiles?.full_name || '--'}</td>
                  <td><span className={`badge ${APPT_STATUS_BADGE[a.status] || 'b-gray'}`}>{a.status}</span></td>
                  <td style={{ position: 'relative' }}>
                    {!isRegistered && <RegisterUnregisteredButton appointmentId={a.id} tempName={a.patient_name_temp} tempMobile={a.mobile_temp} />}
                    {isRegistered && a.status === 'Booked' && <CheckInButton appointmentId={a.id} />}
                    {isRegistered && a.status === 'Checked-in' && <span className="badge b-green">Registered</span>}
                  </td>
                </tr>
              );
            })}
            {(!todaysAppointments || todaysAppointments.length === 0) && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No appointments today.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
        {/* TODAY'S VISITS */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-door-enter" style={{ color: 'var(--blue)' }}></i> Today&apos;s Visits
          </div>
          <table className="tbl">
            <thead><tr><th>Visit ID</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Status</th><th>Billing</th><th></th></tr></thead>
            <tbody>
              {(todaysVisits || []).map((v) => {
                const billStatus = billingByVisit[v.id] || '--';
                return (
                  <tr key={v.id}>
                    <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                    <td>{new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}</td>
                    <td>
                      <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                      <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                    </td>
                    <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                    <td>{v.profiles?.full_name || '--'}</td>
                    <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                    <td><span className={`badge ${BILLING_BADGE[billStatus]}`}>{billStatus}</span></td>
                    <td>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                          <i className="ti ti-receipt"></i> New Invoice
                        </Link>
                        {billStatus !== '--' && (
                          <Link href={`/billing/cancel?visitId=${v.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                            <i className="ti ti-edit"></i> Modify
                          </Link>
                        )}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {(!todaysVisits || todaysVisits.length === 0) && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>
              )}
            </tbody>
          </table>
        </div>

        <div>
          {/* VISIT TYPE BREAKDOWN */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-chart-pie" style={{ color: 'var(--purple)' }}></i> Visits by Type Today
            </div>
            {Object.keys(visitTypeCounts).length === 0 && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>No visits yet today.</div>
            )}
            {Object.entries(visitTypeCounts).map(([type, count]) => (
              <div key={type} style={{ marginBottom: 8 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, marginBottom: 3 }}>
                  <span>{type}</span><span style={{ fontWeight: 600 }}>{count}</span>
                </div>
                <div style={{ height: 6, background: 'var(--g100)', borderRadius: 3 }}>
                  <div style={{
                    width: `${totalVisitsToday ? (count / totalVisitsToday) * 100 : 0}%`,
                    height: '100%', background: `var(${VISIT_TYPE_COLOR[type] || '--g400'})`, borderRadius: 3,
                  }}></div>
                </div>
              </div>
            ))}
          </div>

          {/* PATIENTS WAITING NOW */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-list-numbers" style={{ color: 'var(--amber)' }}></i> Patients Waiting Now
            </div>
            {(queueEntries || []).slice(0, 5).map((e) => (
              <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                  {e.visits?.patients?.first_name} {e.visits?.patients?.last_name}
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.department} -- {elapsedMin(e.issued_at)} min</div>
                </div>
                <span className={`badge ${e.status === 'Calling' || e.status === 'In Consultation' ? 'b-blue' : 'b-amber'}`}>{e.status}</span>
              </div>
            ))}
            {(!queueEntries || queueEntries.length === 0) && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Queue is empty.</div>
            )}
          </div>

          {/* PENDING ACTIONS */}
          <div className="card">
            <div className="card-title" style={{ marginBottom: 10 }}>
              <i className="ti ti-alert-circle" style={{ color: 'var(--red)' }}></i> Pending Actions
            </div>
            {(pendingInvoices?.length ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-receipt" style={{ color: 'var(--red)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{pendingInvoices.length} invoices -- payment pending</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>Total: Rs.{outstandingTotal.toLocaleString('en-IN')}</div>
                </div>
              </div>
            )}
            {unregisteredCount > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0', borderBottom: '1px solid var(--g100)' }}>
                <i className="ti ti-user-plus" style={{ color: 'var(--amber)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{unregisteredCount} appointments not yet registered</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>See Today&apos;s Appointments above</div>
                </div>
              </div>
            )}
            {(surgicalPendingWorkup ?? 0) > 0 && (
              <div style={{ display: 'flex', gap: 8, alignItems: 'flex-start', padding: '8px 0' }}>
                <i className="ti ti-scalpel" style={{ color: 'var(--blue)' }}></i>
                <div>
                  <div style={{ fontSize: 12, fontWeight: 600 }}>{surgicalPendingWorkup} surgical cases pending workup</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                    <Link href="/surgical" style={{ color: 'var(--blue)' }}>Go to Surgical Coordination</Link>
                  </div>
                </div>
              </div>
            )}
            {!(pendingInvoices?.length) && !unregisteredCount && !surgicalPendingWorkup && (
              <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending -- all caught up.</div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}


EOF

echo "Flexible multi-invoice billing (New Invoice + Modify Existing) created/updated."