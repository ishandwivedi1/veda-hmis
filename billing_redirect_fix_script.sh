# Remove the old per-visit billing page -- nothing links to it anymore
rm -rf 'app/(main)/billing/[visitId]'

mkdir -p 'app/(main)/billing/new' 'app/(main)/front-office-dashboard' 'app/(main)/visits'

cat > 'app/(main)/billing/new/new-invoice-tab.js' << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter, useSearchParams } from 'next/navigation';
import {
  searchPatientsForInvoice,
  createStandaloneInvoice,
  getInvoiceById,
  getServiceCatalog,
  addLineItem,
  removeLineItem,
  getTodaysVisitsForBilling,
  getInvoiceForVisit,
} from '../actions';

const DEPARTMENTS = ['Consultation', 'Investigation', 'Surgery', 'Pharmacy'];

export default function NewInvoiceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
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

  useEffect(() => {
    getServiceCatalog().then(setCatalog);
    getTodaysVisitsForBilling().then(setTodaysVisits);
  }, []);

  // If we arrived here via a "Bill" link elsewhere in the app (e.g. from
  // Visits or Front Office Dashboard), open that visit's real invoice
  // automatically -- so the redirect still feels seamless, not like
  // starting over.
  useEffect(() => {
    if (!urlVisitId) return;
    (async () => {
      const details = await getInvoiceForVisit(urlVisitId);
      if (details.error) { setError(details.error); return; }
      setSelectedPatient(details.visit.patients);
      setInvoice(details.invoice);
      setLineItems(details.lineItems);
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
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const result = await createStandaloneInvoice(p.id);
    if (result.error) { setError(result.error); return; }
    const details = await getInvoiceById(result.invoice.id);
    setInvoice(details.invoice);
    setLineItems(details.lineItems);
  }

  async function pickVisit(v) {
    setError('');
    setSelectedPatient(v.patients);
    const details = await getInvoiceForVisit(v.id);
    if (details.error) { setError(details.error); return; }
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
    setSelectedPatient(null);
    setInvoice(null);
    setLineItems([]);
    setFinalized(false);
  }

  function handleFinalize() {
    setError('');
    if (lineItems.length === 0) { setError('Add at least one line item before finalizing.'); return; }
    setFinalized(true);
  }

  function handleSaveDraft() {
    // Every line item is already saved to the database the moment it's
    // added -- there's no separate "draft" storage to write to. This
    // just confirms that and lets staff step away and resume later from
    // Invoice Details.
    router.push('/billing/details');
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Invoice
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
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
            <i className="ti ti-circle-check"></i> Invoice finalized for {selectedPatient.first_name} {selectedPatient.last_name} -- Net Rs.{invoice.net}.{' '}
            <a href={`/billing/details?q=${selectedPatient.uhid}`} style={{ color: 'var(--blue)' }}>Go collect payment in Invoice Details &rarr;</a>
            <div style={{ marginTop: 10 }}>
              <button className="btn btn-sm" onClick={startOver}>Start a new invoice</button>
            </div>
          </div>
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--blue-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 16 }}>
              <span><strong>{selectedPatient.first_name} {selectedPatient.last_name}</strong> -- {selectedPatient.uhid}</span>
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
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>Click a visit to auto-fill and continue their invoice.</div>
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
              <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Invoice Summary
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

cat > 'app/(main)/billing/new/page.js' << 'EOF'
import { Suspense } from 'react';
import BillingTabs from '../billing-tabs';
import NewInvoiceTab from './new-invoice-tab';

export default function NewInvoicePage() {
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <NewInvoiceTab />
      </Suspense>
    </div>
  );
}

EOF

cat > 'app/(main)/front-office-dashboard/page.js' << 'EOF'
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
                      <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                        <i className="ti ti-receipt"></i> Bill
                      </Link>
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

cat > 'app/(main)/visits/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '@/lib/supabase-server';

const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue',
  'Follow-up': '--green',
  'Investigation Only': '--purple',
  'Post-operative Review': '--amber',
  'Emergency': '--red',
  'Procedure': '--teal',
};

const BILLING_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', '--': 'b-gray' };

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;
  const tab = params?.tab === 'all' ? 'all' : 'today';

  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  let query = supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .order('created_at', { ascending: false });

  if (tab === 'today') {
    query = query.gte('created_at', today);
  } else {
    query = query.limit(100); // most recent 100 -- avoids loading the entire visit history at once
  }

  const { data: visits, error } = await query;

  const visitIds = (visits || []).map((v) => v.id);
  let billingByVisit = {};
  if (visitIds.length > 0) {
    const { data: invoices } = await supabase.from('invoices').select('visit_id, status').in('visit_id', visitIds);
    (invoices || []).forEach((inv) => { billingByVisit[inv.visit_id] = inv.status; });
  }

  return (
    <div className="card">
      <div className="card-head">
        <div>
          <div className="card-title"><i className="ti ti-door-enter" style={{ color: 'var(--green)' }}></i> Visits <span className="badge b-gray">{visits?.length ?? 0}</span></div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 4 }}>{tab === 'today' ? "Today's visits, all statuses." : 'Most recent 100 visits, all time.'}</div>
        </div>
        <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
          <i className="ti ti-plus"></i> Walk-in Visit
        </Link>
      </div>

      <div style={{ display: 'flex', gap: 6, marginBottom: 16 }}>
        <Link href="/visits?tab=today" className={tab === 'today' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          Today&apos;s Visits
        </Link>
        <Link href="/visits?tab=all" className={tab === 'all' ? 'btn btn-primary' : 'btn'} style={{ textDecoration: 'none' }}>
          All Visits
        </Link>
      </div>

      {justCreated && <div className="msg-success"><i className="ti ti-circle-check"></i> Visit created successfully.</div>}
      {error && <div className="msg-err">{error.message}</div>}

      <table className="tbl">
        <thead>
          <tr>
            <th>Visit ID</th>
            <th>{tab === 'today' ? 'Time' : 'Date'}</th>
            <th>Patient</th>
            <th>Type</th>
            <th>Doctor</th>
            <th>Status</th>
            <th>Billing</th>
            <th></th>
          </tr>
        </thead>
        <tbody>
          {(visits || []).map((v) => {
            const billStatus = billingByVisit[v.id] || '--';
            return (
              <tr key={v.id}>
                <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                <td style={{ color: 'var(--g500)' }}>
                  {tab === 'today'
                    ? new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })
                    : new Date(v.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
                </td>
                <td>
                  <div style={{ fontWeight: 600 }}>{v.patients?.first_name} {v.patients?.last_name}</div>
                  <div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div>
                </td>
                <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g100'})`, color: '#fff' }}>{v.visit_type}</span></td>
                <td>{v.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${v.status === 'Open' ? 'b-blue' : 'b-gray'}`}>{v.status}</span></td>
                <td><span className={`badge ${BILLING_BADGE[billStatus]}`}>{billStatus}</span></td>
                <td>
                  <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                    <i className="ti ti-receipt"></i> Bill
                  </Link>
                </td>
              </tr>
            );
          })}
          {(!visits || visits.length === 0) && (
            <tr>
              <td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>
                {tab === 'today' ? 'No visits yet today.' : 'No visits found.'}
              </td>
            </tr>
          )}
        </tbody>
      </table>
    </div>
  );
}

EOF

echo "All Bill links now redirect to New Invoice with the visit auto-selected. Old billing page removed."
