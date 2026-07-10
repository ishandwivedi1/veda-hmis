mkdir -p 'app/(main)/billing/package'

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

export async function removeLineItem(lineItemId) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId });
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

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/(main)/billing/package/package-billing-tab.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getPostSurgicalPendingPackages,
  getActivePackages,
  searchPatientsForPackage,
  generatePackageInvoice,
} from '../actions';

export default function PackageBillingTab() {
  const [pending, setPending] = useState([]);
  const [packages, setPackages] = useState([]);

  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [selectedPackage, setSelectedPackage] = useState(null);
  const [surgicalCaseId, setSurgicalCaseId] = useState(null);

  const [paymentMode, setPaymentMode] = useState('full');
  const [advanceAmount, setAdvanceAmount] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [result, setResult] = useState(null);

  const refresh = useCallback(async () => {
    setPending(await getPostSurgicalPendingPackages());
    setPackages(await getActivePackages());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPackage(searchQuery.trim()));
  }

  function pickPatient(p) {
    setSelectedPatient(p);
    setSurgicalCaseId(null);
    setSearchResults([]);
    setSearchQuery('');
  }

  function pickPostSurgical(sc) {
    setSelectedPatient(sc.patients);
    setSurgicalCaseId(sc.id);
    if (sc.master_packages) setSelectedPackage(sc.master_packages);
  }

  function reset() {
    setSelectedPatient(null);
    setSelectedPackage(null);
    setSurgicalCaseId(null);
    setPaymentMode('full');
    setAdvanceAmount('');
    setResult(null);
    setError('');
  }

  async function handleGenerate() {
    setError('');
    if (!selectedPatient || !selectedPackage) { setError('Select a patient and a package.'); return; }
    setLoading(true);
    const res = await generatePackageInvoice(
      selectedPatient.id,
      selectedPackage.id,
      paymentMode,
      paymentMode === 'advance' ? parseFloat(advanceAmount) : 0,
      surgicalCaseId
    );
    setLoading(false);
    if (res.error) { setError(res.error); return; }
    setResult(res.invoice);
    refresh();
  }

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-scissors" style={{ color: 'var(--blue)' }}></i> Post-surgical Patients -- Package Pending
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
          Surgery is complete but the package invoice hasn&apos;t been generated yet.
        </div>
        {pending.map((sc) => (
          <div
            key={sc.id}
            onClick={() => pickPostSurgical(sc)}
            style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13, display: 'flex', justifyContent: 'space-between' }}
          >
            <span><strong>{sc.patients?.first_name} {sc.patients?.last_name}</strong> -- {sc.patients?.uhid} -- {sc.procedure_name}</span>
            <span style={{ color: 'var(--g500)' }}>{sc.master_packages?.name || 'No package selected'}</span>
          </div>
        ))}
        {pending.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing pending.</div>}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-package" style={{ color: 'var(--blue)' }}></i> Package Billing
        </div>
        <div className="msg-info">
          <i className="ti ti-info-circle"></i> Surgery package invoices are generated after counselling. Full payment or advance is collected before surgery scheduling.
        </div>

        {error && <div className="msg-err">{error}</div>}

        {result ? (
          <div className="msg-success">
            <i className="ti ti-circle-check"></i> Package invoice generated -- Net Rs.{result.net}, Paid Rs.{result.paid}, Status: {result.status}.
            <div style={{ marginTop: 10 }}>
              <button className="btn btn-sm" onClick={reset}>Bill another package</button>
            </div>
          </div>
        ) : (
          <>
            {!selectedPatient ? (
              <div>
                <label className="flbl">Patient / Visit</label>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type patient name or UHID..." />
                  <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                    {searchResults.map((p) => (
                      <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                        <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            ) : (
              <div>
                <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
                  <div>
                    <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                    <div style={{ fontSize: 11, color: 'var(--g500)' }}>{selectedPatient.uhid}</div>
                  </div>
                  <button className="btn btn-sm" onClick={reset}>Change</button>
                </div>

                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 10, marginBottom: 14 }}>
                  {packages.map((pkg) => (
                    <div
                      key={pkg.id}
                      onClick={() => setSelectedPackage(pkg)}
                      style={{
                        border: selectedPackage?.id === pkg.id ? '2px solid var(--blue)' : '1px solid var(--g200)',
                        borderRadius: 8, padding: 12, cursor: 'pointer',
                        background: selectedPackage?.id === pkg.id ? 'var(--blue-lt)' : '#fff',
                      }}
                    >
                      <div style={{ fontWeight: 700, fontSize: 13 }}>{pkg.name}</div>
                      <div style={{ fontSize: 12, color: 'var(--g500)' }}>Rs.{pkg.price}</div>
                      {pkg.includes && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 4 }}>{pkg.includes}</div>}
                    </div>
                  ))}
                </div>

                {selectedPackage && (
                  <div>
                    <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 14 }}>
                      <div>
                        <label className="flbl">Payment mode</label>
                        <select className="fi" value={paymentMode} onChange={(e) => setPaymentMode(e.target.value)}>
                          <option value="full">Full payment</option>
                          <option value="advance">Advance payment</option>
                        </select>
                      </div>
                      {paymentMode === 'advance' && (
                        <div>
                          <label className="flbl">Advance amount (Rs.)</label>
                          <input type="number" className="fi" value={advanceAmount} onChange={(e) => setAdvanceAmount(e.target.value)} placeholder={`Up to Rs.${selectedPackage.price}`} />
                        </div>
                      )}
                    </div>
                    <button className="btn btn-green" onClick={handleGenerate} disabled={loading}>
                      <i className="ti ti-receipt"></i> {loading ? 'Generating...' : 'Generate package invoice'}
                    </button>
                  </div>
                )}
              </div>
            )}
          </>
        )}
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/billing/package/page.js' << 'EOF'
import BillingTabs from '../billing-tabs';
import PackageBillingTab from './package-billing-tab';

export default function PackageBillingPage() {
  return (
    <div>
      <BillingTabs />
      <PackageBillingTab />
    </div>
  );
}

EOF

echo "Package Billing tab built."
