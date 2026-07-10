mkdir -p 'app/(main)/payments/collect' 'app/(main)/payments/advance' 'app/(main)/payments/adjustments' 'app/(main)/payments/receipt' 'app/(main)/payments/cancel' 'app/(main)/payments/reports' app/components

cat > 'app/(main)/payments/page.js' << 'EOF'
import PaymentsTabs from './payments-tabs';

export default function PaymentsDashboardPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-layout-dashboard" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Payments Dashboard -- coming soon.
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/payments-tabs.js' << 'EOF'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/cancel', label: 'Cancellation', icon: 'ti-x-circle' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-file-report' },
];

export default function PaymentsTabs() {
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

cat > 'app/(main)/payments/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function searchPatientsForPayment(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getOutstandingInvoices(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at')
    .eq('patient_id', patientId)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true }); // oldest first, matches allocation order
  return data || [];
}

export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_payment', {
    p_patient_id: patientId,
    p_invoice_ids: invoiceIds,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}

EOF

cat > 'app/(main)/payments/receipt/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';

export default function ReceiptPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-receipt-2" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Receipt -- coming soon.
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/cancel/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';

export default function PaymentCancellationPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-x-circle" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Cancellation -- coming soon.
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/collect/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';
import CollectPaymentTab from './collect-payment-tab';

export default function CollectPaymentPage() {
  return (
    <div>
      <PaymentsTabs />
      <CollectPaymentTab />
    </div>
  );
}

EOF

cat > 'app/(main)/payments/collect/collect-payment-tab.js' << 'EOF'
'use client';

import { useState } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, collectPayment } from '../actions';

const MODES = ['Cash', 'Card', 'UPI', 'Cheque', 'Bank Transfer'];

export default function CollectPaymentTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selectedPatient, setSelectedPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [selectedInvoiceIds, setSelectedInvoiceIds] = useState([]);

  const [amount, setAmount] = useState('');
  const [modeRows, setModeRows] = useState([{ mode: 'Cash', amount: '' }]);
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [receipt, setReceipt] = useState(null);

  const totalSelectedOutstanding = invoices
    .filter((inv) => selectedInvoiceIds.includes(inv.id))
    .reduce((s, inv) => s + (Number(inv.net) - Number(inv.paid)), 0);

  const modesTotal = modeRows.reduce((s, m) => s + (parseFloat(m.amount) || 0), 0);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError('');
    setSelectedPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    const invs = await getOutstandingInvoices(p.id);
    setInvoices(invs);
    setSelectedInvoiceIds(invs.map((i) => i.id)); // pre-select all, matching "select invoice(s) to pay"
  }

  function toggleInvoice(id) {
    setSelectedInvoiceIds((prev) => (prev.includes(id) ? prev.filter((x) => x !== id) : [...prev, id]));
  }

  function useFullOutstanding() {
    setAmount(totalSelectedOutstanding.toFixed(2));
    setModeRows([{ mode: 'Cash', amount: totalSelectedOutstanding.toFixed(2) }]);
  }

  function updateModeRow(idx, field, value) {
    setModeRows((rows) => rows.map((r, i) => (i === idx ? { ...r, [field]: value } : r)));
  }

  function addModeRow() {
    setModeRows((rows) => [...rows, { mode: 'Cash', amount: '' }]);
  }

  function removeModeRow(idx) {
    setModeRows((rows) => rows.filter((_, i) => i !== idx));
  }

  function reset() {
    setSelectedPatient(null);
    setInvoices([]);
    setSelectedInvoiceIds([]);
    setAmount('');
    setModeRows([{ mode: 'Cash', amount: '' }]);
    setReference('');
    setRemarks('');
    setReceipt(null);
    setError('');
  }

  async function handleCollect() {
    setError('');
    if (selectedInvoiceIds.length === 0) { setError('Select at least one invoice to pay.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid amount collecting.'); return; }
    if (Math.abs(modesTotal - amt) > 0.01) {
      setError(`Payment mode split (Rs.${modesTotal.toFixed(2)}) must add up to the amount collecting (Rs.${amt.toFixed(2)}).`);
      return;
    }

    setLoading(true);
    const modesPayload = modeRows.filter((m) => parseFloat(m.amount) > 0).map((m) => ({ mode: m.mode, amount: parseFloat(m.amount) }));
    const result = await collectPayment(selectedPatient.id, selectedInvoiceIds, amt, modesPayload, reference, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setReceipt(result.payment);
  }

  if (receipt) {
    return (
      <div className="card">
        <div className="msg-success">
          <i className="ti ti-circle-check"></i> Payment collected -- Receipt <strong>{receipt.receipt_number}</strong> -- Rs.{receipt.total_amount}
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Patient:</strong> {selectedPatient.first_name} {selectedPatient.last_name} -- {selectedPatient.uhid}</div>
          <div><strong>Amount:</strong> Rs.{receipt.total_amount}</div>
          {receipt.reference && <div><strong>Reference:</strong> {receipt.reference}</div>}
        </div>
        <button className="btn btn-primary" style={{ marginTop: 16 }} onClick={reset}>Collect another payment</button>
      </div>
    );
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-cash" style={{ color: 'var(--green)' }}></i> Collect Payment
        </div>

        {error && <div className="msg-err">{error}</div>}

        {!selectedPatient ? (
          <div>
            <label className="flbl">Patient (name, UHID, or mobile) *</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
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
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--green-lt)', padding: '10px 14px', borderRadius: 8, marginBottom: 14 }}>
              <div>
                <div style={{ fontWeight: 700 }}>{selectedPatient.first_name} {selectedPatient.last_name}</div>
                <div style={{ fontSize: 11, color: 'var(--g600)' }}>{selectedPatient.uhid}</div>
              </div>
              <button className="btn btn-sm" onClick={reset}>Change</button>
            </div>

            <label className="flbl">Select invoice(s) to pay *</label>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 14 }}>No outstanding invoices for this patient.</div>}
            <div style={{ marginBottom: 14 }}>
              {invoices.map((inv) => (
                <label key={inv.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 4px', borderBottom: '1px solid var(--g100)', fontSize: 13, cursor: 'pointer' }}>
                  <span>
                    <input type="checkbox" checked={selectedInvoiceIds.includes(inv.id)} onChange={() => toggleInvoice(inv.id)} style={{ marginRight: 8 }} />
                    {inv.invoice_number} -- <span className={`badge ${inv.status === 'Partial' ? 'b-amber' : 'b-red'}`}>{inv.status}</span>
                  </span>
                  <span style={{ fontWeight: 600 }}>Rs.{(inv.net - inv.paid).toFixed(2)}</span>
                </label>
              ))}
            </div>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
              <div>
                <label className="flbl">Amount collecting (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Total selected outstanding</label>
                <input className="fi" value={`Rs.${totalSelectedOutstanding.toFixed(2)}`} readOnly style={{ background: 'var(--g50)', fontWeight: 700, color: 'var(--red)' }} />
              </div>
            </div>
            <button className="btn btn-sm" onClick={useFullOutstanding} style={{ marginBottom: 14 }}>Use full outstanding amount</button>

            <label className="flbl">Payment mode(s) * -- split across multiple if needed</label>
            {modeRows.map((row, idx) => (
              <div key={idx} style={{ display: 'flex', gap: 8, marginBottom: 6 }}>
                <select className="fi" value={row.mode} onChange={(e) => updateModeRow(idx, 'mode', e.target.value)} style={{ flex: 1 }}>
                  {MODES.map((m) => <option key={m} value={m}>{m}</option>)}
                </select>
                <input type="number" className="fi" value={row.amount} onChange={(e) => updateModeRow(idx, 'amount', e.target.value)} placeholder="Amount" style={{ flex: 1 }} />
                {modeRows.length > 1 && <button className="btn" onClick={() => removeModeRow(idx)} style={{ padding: '4px 10px' }}>x</button>}
              </div>
            ))}
            <button className="btn btn-sm" onClick={addModeRow} style={{ marginBottom: 6 }}><i className="ti ti-plus"></i> Add mode</button>
            <div style={{ fontSize: 11, color: Math.abs(modesTotal - (parseFloat(amount) || 0)) > 0.01 ? 'var(--red)' : 'var(--green)', marginBottom: 14 }}>
              Split total: Rs.{modesTotal.toFixed(2)}
            </div>

            <div style={{ marginBottom: 10 }}>
              <label className="flbl">Reference / Transaction ID</label>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="UPI ref, card last 4, cheque no..." />
            </div>
            <div style={{ marginBottom: 16 }}>
              <label className="flbl">Remarks</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Optional..." />
            </div>

            <button className="btn btn-green" onClick={handleCollect} disabled={loading}>
              <i className="ti ti-circle-check"></i> {loading ? 'Collecting...' : 'Collect payment'}
            </button>
          </div>
        )}
      </div>

      <div>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-calculator" style={{ color: 'var(--green)' }}></i> Payment Summary
          </div>
          {!selectedPatient ? (
            <div style={{ textAlign: 'center', padding: 20, color: 'var(--g400)', fontSize: 13 }}>Select patient and invoice</div>
          ) : (
            <div style={{ fontSize: 13, lineHeight: 1.9 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Invoices selected</span><span>{selectedInvoiceIds.length}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total outstanding</span><span>Rs.{totalSelectedOutstanding.toFixed(2)}</span></div>
              <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Amount collecting</span><span>Rs.{(parseFloat(amount) || 0).toFixed(2)}</span></div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/adjustments/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';

export default function AdjustmentsPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-adjustments" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Adjustments -- coming soon.
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/reports/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';

export default function PaymentReportsPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-file-report" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Reports -- coming soon.
      </div>
    </div>
  );
}

EOF

cat > 'app/(main)/payments/advance/page.js' << 'EOF'
import PaymentsTabs from '../payments-tabs';

export default function AdvancePage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-wallet" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Advance -- coming soon.
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
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Front Office' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/surgical', label: 'Surgical Coordination', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Scheduling', icon: 'ti-calendar-time', section: 'Surgical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/surgical/, title: 'Surgical Coordination' },
  { match: /^\/ot-schedule/, title: 'OT Scheduling' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
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

echo "Payments module tab shell + Collect Payment tab created."
