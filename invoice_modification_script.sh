mkdir -p 'app/(main)/billing/cancel'

cat > 'app/(main)/billing/actions.js' << 'EOF'
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

export async function getInvoiceForVisit(visitId) {
  const supabase = await createClient();

  const { data: visit, error: visitError } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();

  if (visitError) return { error: visitError.message };

  const { data: invoice, error: invError } = await supabase.rpc('get_or_create_invoice_for_visit', {
    p_visit_id: visitId,
  });

  if (invError) return { error: invError.message };

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoice.id)
    .order('id');

  return { visit, invoice, lineItems: lineItems || [] };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').eq('status', 'Active').order('name');
  return data || [];
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

export async function createStandaloneInvoice(patientId) {
  const supabase = await createClient();
  const { data: visit } = await supabase
    .from('visits')
    .select('id')
    .eq('patient_id', patientId)
    .order('created_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  const { data, error } = await supabase.rpc('create_standalone_invoice', {
    p_patient_id: patientId,
    p_visit_id: visit?.id || null,
  });
  if (error) return { error: error.message };
  return { invoice: data };
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

cat > 'app/(main)/billing/cancel/invoice-modification-tab.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchInvoices, getInvoiceById, getServiceCatalog, addLineItem, removeLineItem, cancelInvoice } from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];
const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };

export default function InvoiceModificationTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [results, setResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [lineItems, setLineItems] = useState([]);
  const [catalog, setCatalog] = useState([]);

  const [dept, setDept] = useState('');
  const [serviceCode, setServiceCode] = useState('');
  const [qty, setQty] = useState(1);

  const [removeReasonFor, setRemoveReasonFor] = useState(null);
  const [removeReason, setRemoveReason] = useState('');

  const [showCancelForm, setShowCancelForm] = useState(false);
  const [cancelReason, setCancelReason] = useState('');

  const [error, setError] = useState('');
  const [info, setInfo] = useState('');

  useEffect(() => { getServiceCatalog().then(setCatalog); }, []);

  const servicesForDept = catalog.filter((s) => s.dept === dept);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setResults(await searchInvoices(searchQuery.trim()));
  }

  async function openInvoice(inv) {
    setError(''); setInfo('');
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

  async function handleAddLine() {
    setError('');
    if (!serviceCode) { setError('Select department and service.'); return; }
    const result = await addLineItem(selected.id, serviceCode, parseInt(qty, 10) || 1, 'none', 0, null);
    if (result.error) { setError(result.error); return; }
    setDept(''); setServiceCode(''); setQty(1);
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

  async function handleCancel() {
    setError('');
    if (!cancelReason.trim()) { setError('A cancellation reason is required.'); return; }
    const result = await cancelInvoice(selected.id, cancelReason);
    if (result.error) { setError(result.error); return; }
    setInfo('Invoice cancelled and logged for audit.');
    setShowCancelForm(false);
    setCancelReason('');
    refresh();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: selected ? '1fr 1.3fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-edit" style={{ color: 'var(--blue)' }}></i> Find Invoice
        </div>
        <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
          <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Patient name or UHID..." />
          <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
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
        {results.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Search to find an invoice.</div>}
      </div>

      {selected && (
        <div className="card">
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div className="card-title" style={{ marginBottom: 0 }}>{selected.invoice_number}</div>
            <span className={`badge ${STATUS_BADGE[selected.status] || 'b-gray'}`}>{selected.status}</span>
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
              <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 80px', gap: 8, marginBottom: 8 }}>
                <select className="fi" value={dept} onChange={(e) => { setDept(e.target.value); setServiceCode(''); }}>
                  <option value="">-- Dept --</option>
                  {DEPARTMENTS.map((d) => <option key={d} value={d}>{d}</option>)}
                </select>
                <select className="fi" value={serviceCode} onChange={(e) => setServiceCode(e.target.value)} disabled={!dept}>
                  <option value="">-- Service --</option>
                  {servicesForDept.map((s) => <option key={s.code} value={s.code}>{s.name} -- Rs.{s.rate}</option>)}
                </select>
                <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} min={1} />
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
          </div>
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/(main)/billing/cancel/page.js' << 'EOF'
import BillingTabs from '../billing-tabs';
import InvoiceModificationTab from './invoice-modification-tab';

export default function InvoiceModificationPage() {
  return (
    <div>
      <BillingTabs />
      <InvoiceModificationTab />
    </div>
  );
}

EOF

cat > 'app/(main)/billing/billing-tabs.js' << 'EOF'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/billing', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/billing/new', label: 'New Invoice', icon: 'ti-file-plus' },
  { href: '/billing/package', label: 'Package Billing', icon: 'ti-package' },
  { href: '/billing/details', label: 'Invoice Details', icon: 'ti-search' },
  { href: '/billing/cancel', label: 'Invoice Modification', icon: 'ti-edit' },
  { href: '/billing/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function BillingTabs() {
  const pathname = usePathname();
  return (
    <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
      {TABS.map((t) => (
        <Link
          key={t.href}
          href={t.href}
          className={pathname === t.href ? 'btn btn-primary' : 'btn'}
          style={{ textDecoration: 'none' }}
        >
          <i className={`ti ${t.icon}`}></i> {t.label}
        </Link>
      ))}
    </div>
  );
}

EOF

echo "Invoice Modification tab built."
