mkdir -p "app/components" "app/(main)/payments/ledger" "app/(main)/payments/credit-note"

cat > "app/components/AppShell.js" << 'EOF'
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
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/payments/ledger', label: 'Patient Ledger', icon: 'ti-book', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/workflow-monitor', label: 'Workflow Monitor', icon: 'ti-activity', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
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
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
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

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = NAV_ITEMS
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

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
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
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

cat > "app/(main)/payments/payments-tabs.js" << 'EOF'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/payments', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/payments/collect', label: 'Collect Payment', icon: 'ti-cash' },
  { href: '/payments/advance', label: 'Advance', icon: 'ti-wallet' },
  { href: '/payments/adjustments', label: 'Adjustments', icon: 'ti-adjustments' },
  { href: '/payments/ledger', label: 'Ledger', icon: 'ti-book' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus' },
  { href: '/payments/receipt', label: 'Receipt', icon: 'ti-receipt-2' },
  { href: '/payments/cancel', label: 'Refund / Modification', icon: 'ti-receipt-refund' },
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

cat > "app/(main)/payments/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getPatientById(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .eq('id', patientId)
    .single();
  if (error) return { error: error.message };
  return { patient: data };
}

export async function getAllUnpaidInvoices() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at, patients(id, first_name, last_name, uhid)')
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── CREDIT NOTES ──
export async function getApprovers() {
  const supabase = await createClient();
  const { data } = await supabase.from('profiles').select('id, full_name, designation').eq('status', 'Active').order('full_name');
  return data || [];
}

export async function createCreditNote(patientId, invoiceId, amount, reason, approvedBy, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('create_credit_note', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
    p_approved_by: approvedBy,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function getCreditNoteRegister() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('credit_notes')
    .select('*, patients(first_name, last_name, uhid), invoices(invoice_number), profiles!credit_notes_approved_by_fkey(full_name)')
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── UNIFIED PATIENT LEDGER (Invoice / Payment / Advance / Advance
// Adjustment / Credit Note / Refund, interleaved with a running
// balance). patient_ledger itself is deliberately NOT a source here --
// it's an internal advance-balance tracker (get_advance_balance sums
// it), and every event it records already has a richer counterpart in
// payments/invoices/credit_notes, so including both would double-count.
export async function getPatientUnifiedLedger(patientId) {
  const supabase = await createClient();

  const [{ data: invoices }, { data: payments }, { data: refunds }, { data: creditNotes }] = await Promise.all([
    supabase.from('invoices').select('id, invoice_number, net, status, created_at, visits(visit_number)').eq('patient_id', patientId),
    supabase.from('payments').select('*, payment_modes(mode, amount)').eq('patient_id', patientId),
    supabase.from('payment_refunds').select('*, payments!inner(patient_id, receipt_number), invoices(invoice_number, visits(visit_number))').eq('payments.patient_id', patientId),
    supabase.from('credit_notes').select('*, invoices(invoice_number, visits(visit_number))').eq('patient_id', patientId),
  ]);

  const PAYMENT_TYPE_LABEL = { advance: 'Advance', advance_adjustment: 'Advance Adjustment', credit_note: 'Credit Note' };

  const entries = [];

  (invoices || []).forEach((inv) => {
    entries.push({
      date: inv.created_at, type: 'Invoice', ref: inv.invoice_number, visit: inv.visits?.visit_number || '--',
      desc: `Invoice ${inv.invoice_number}`, debit: Number(inv.net), credit: 0, by: 'System',
    });
  });

  (payments || []).forEach((p) => {
    if (p.payment_type === 'credit_note') return; // shown from credit_notes instead, richer detail there
    const type = PAYMENT_TYPE_LABEL[p.payment_type] || 'Payment';
    const modeDesc = (p.payment_modes || []).map((m) => m.mode).join('+') || 'Advance';
    entries.push({
      date: p.collected_at, type, ref: p.receipt_number, visit: '--',
      desc: `${type} via ${modeDesc}${p.remarks ? ' -- ' + p.remarks : ''}`, debit: 0, credit: Number(p.total_amount), by: 'Staff',
    });
  });

  (refunds || []).forEach((r) => {
    entries.push({
      date: r.refunded_at, type: 'Refund', ref: r.payments?.receipt_number || '--', visit: r.invoices?.visits?.visit_number || '--',
      desc: `Refund against ${r.invoices?.invoice_number || '--'} -- ${r.reason}`, debit: Number(r.amount), credit: 0, by: 'Staff',
    });
  });

  (creditNotes || []).forEach((cn) => {
    entries.push({
      date: cn.created_at, type: 'Credit Note', ref: cn.credit_note_number, visit: cn.invoices?.visits?.visit_number || '--',
      desc: `${cn.reason} -- against ${cn.invoices?.invoice_number || '--'}`, debit: 0, credit: Number(cn.amount), by: 'Staff',
    });
  });

  entries.sort((a, b) => new Date(a.date) - new Date(b.date));

  let balance = 0;
  entries.forEach((e) => {
    balance += e.debit - e.credit;
    e.balance = balance;
  });

  return entries.reverse(); // newest first for display
}

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

// ── ADVANCE ──
export async function getAdvanceBalance(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_advance_balance', { p_patient_id: patientId });
  if (error) return 0;
  return data || 0;
}

export async function collectAdvance(patientId, advanceType, amount, modes, reference, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_advance', {
    p_patient_id: patientId,
    p_advance_type: advanceType,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}

export async function getCurrentBalancesByPatient() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('patient_id, amount, patients(id, first_name, last_name, uhid)');
  if (!data) return [];

  const byPatient = {};
  data.forEach((entry) => {
    if (!byPatient[entry.patient_id]) {
      byPatient[entry.patient_id] = { patient: entry.patients, balance: 0 };
    }
    byPatient[entry.patient_id].balance += Number(entry.amount);
  });
  return Object.values(byPatient).filter((p) => p.balance > 0);
}

export async function getLedgerHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*, patients(id, first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
    .order('recorded_at', { ascending: false })
    .limit(30);
  return data || [];
}
// ── ADJUSTMENTS ──
export async function getPatientLedgerAudit(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*')
    .eq('patient_id', patientId)
    .order('recorded_at', { ascending: false });
  return data || [];
}

export async function applyAdjustment(patientId, invoiceId, amount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('apply_advance_adjustment', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_amount: amount,
  });
  if (error) return { error: error.message };
  return { invoice: data };
}

// ── RECEIPTS ──
export async function searchReceipts(query, modeFilter) {
  const supabase = await createClient();

  let q = supabase
    .from('payments')
    .select('*, patients(id, first_name, last_name, uhid), payment_modes(mode, amount), payment_allocations(invoice_id, invoices(invoice_number))')
    .order('collected_at', { ascending: false })
    .limit(50);

  if (query) {
    const { data: matches } = await supabase
      .from('patients')
      .select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    q = q.or(`receipt_number.ilike.%${query}%${ids.length ? ',patient_id.in.(' + ids.join(',') + ')' : ''}`);
  }

  const { data: receipts } = await q;
  if (!receipts) return [];

  if (!modeFilter) return receipts;
  return receipts.filter((r) => (r.payment_modes || []).some((m) => m.mode === modeFilter));
}

export async function getReceiptById(paymentId) {
  const supabase = await createClient();
  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();
  if (error) return { error: error.message };

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return { payment, modes: modes || [], allocations: allocations || [] };
}

// ── REFUND / MODIFICATION ──
export async function getRefundableAllocations(paymentId) {
  const supabase = await createClient();
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  const { data: refunds } = await supabase
    .from('payment_refunds')
    .select('*')
    .eq('payment_id', paymentId);

  return (allocations || []).map((a) => {
    const alreadyRefunded = (refunds || [])
      .filter((r) => r.invoice_id === a.invoice_id)
      .reduce((s, r) => s + Number(r.amount), 0);
    return { ...a, alreadyRefunded, refundable: Number(a.amount) - alreadyRefunded };
  });
}

export async function getRefundHistory(paymentId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('payment_refunds')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId)
    .order('refunded_at', { ascending: false });
  return data || [];
}

export async function refundPayment(paymentId, invoiceId, amount, reason) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('refund_payment', {
    p_payment_id: paymentId,
    p_invoice_id: invoiceId,
    p_amount: amount,
    p_reason: reason,
  });
  if (error) return { error: error.message };
  return { success: true };
}

// ── REPORTS ──
export async function getPaymentReport(reportId, fromDate, toDate) {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);
  const from = fromDate || today;
  const to = toDate || today;
  // Include the entire "to" day, not just its midnight instant.
  const toEnd = `${to}T23:59:59`;
  const rangeLabel = from === to ? new Date(from).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })
    : `${new Date(from).toLocaleDateString('en-IN', { day: 'numeric', month: 'short' })} -- ${new Date(to).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}`;

  if (reportId === 'daily') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false });
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, new Date(p.collected_at).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }), `Rs.${p.total_amount}`],
    }));
    return { title: `Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date/Time', 'Amount'], rows, total: (data || []).reduce((s, p) => s + Number(p.total_amount), 0) };
  }

  if (reportId === 'mode' || reportId === 'cash' || reportId === 'upi') {
    const modeFilter = reportId === 'cash' ? 'Cash' : reportId === 'upi' ? 'UPI' : null;
    let q = supabase
      .from('payment_modes')
      .select('mode, amount, payments!inner(receipt_number, collected_at, patients(first_name, last_name))')
      .gte('payments.collected_at', from)
      .lte('payments.collected_at', toEnd);
    if (modeFilter) q = q.eq('mode', modeFilter);
    const { data } = await q;

    if (reportId === 'mode') {
      const byMode = {};
      (data || []).forEach((m) => { byMode[m.mode] = (byMode[m.mode] || 0) + Number(m.amount); });
      const rows = Object.entries(byMode).map(([mode, amount]) => ({ cols: [mode, `Rs.${amount.toFixed(2)}`] }));
      return { title: `Payment Mode Summary -- ${rangeLabel}`, headers: ['Mode', 'Total'], rows, total: Object.values(byMode).reduce((s, v) => s + v, 0) };
    }

    const rows = (data || []).map((m) => ({
      cols: [m.payments?.receipt_number, `${m.payments?.patients?.first_name} ${m.payments?.patients?.last_name}`, new Date(m.payments?.collected_at).toLocaleDateString('en-IN'), `Rs.${m.amount}`],
    }));
    return { title: `${modeFilter} Collection -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Date', 'Amount'], rows, total: (data || []).reduce((s, m) => s + Number(m.amount), 0) };
  }

  if (reportId === 'advance') {
    const { data } = await supabase
      .from('patient_ledger')
      .select('*, patients(id, first_name, last_name, uhid)')
      .gte('recorded_at', from)
      .lte('recorded_at', toEnd)
      .order('recorded_at', { ascending: false });
    const rows = (data || []).map((l) => ({
      cols: [`${l.patients?.first_name} ${l.patients?.last_name}`, l.patients?.uhid, l.entry_type, `Rs.${Math.abs(l.amount).toFixed(2)}`],
    }));
    return { title: `Advance Report -- ${rangeLabel}`, headers: ['Patient', 'UHID', 'Entry', 'Amount'], rows, total: null };
  }

  if (reportId === 'out') {
    // Outstanding balances are inherently "as of now", not date-ranged --
    // the range here filters by when the invoice was created, so you can
    // still see "what's still outstanding from invoices raised in period X".
    const { data } = await supabase
      .from('invoices')
      .select('invoice_number, net, paid, created_at, patients(id, first_name, last_name, uhid)')
      .in('status', ['Pending', 'Partial'])
      .gte('created_at', from)
      .lte('created_at', toEnd)
      .order('created_at', { ascending: true });
    const rows = (data || []).map((i) => ({
      cols: [i.invoice_number, `${i.patients?.first_name} ${i.patients?.last_name}`, i.patients?.uhid, `Rs.${(i.net - i.paid).toFixed(2)}`],
    }));
    return { title: `Outstanding Balances -- invoices raised ${rangeLabel}`, headers: ['Invoice #', 'Patient', 'UHID', 'Outstanding'], rows, total: (data || []).reduce((s, i) => s + (Number(i.net) - Number(i.paid)), 0) };
  }

  if (reportId === 'register') {
    const { data } = await supabase
      .from('payments')
      .select('receipt_number, total_amount, collected_at, payment_type, patients(first_name, last_name)')
      .gte('collected_at', from)
      .lte('collected_at', toEnd)
      .order('collected_at', { ascending: false })
      .limit(200);
    const rows = (data || []).map((p) => ({
      cols: [p.receipt_number, `${p.patients?.first_name} ${p.patients?.last_name}`, p.payment_type, new Date(p.collected_at).toLocaleDateString('en-IN'), `Rs.${p.total_amount}`],
    }));
    return { title: `Receipt Register -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Type', 'Date', 'Amount'], rows, total: null };
  }

  if (reportId === 'cancel') {
    const { data } = await supabase
      .from('payment_refunds')
      .select('*, payments(receipt_number, patients(first_name, last_name)), invoices(invoice_number)')
      .gte('refunded_at', from)
      .lte('refunded_at', toEnd)
      .order('refunded_at', { ascending: false });
    const rows = (data || []).map((r) => ({
      cols: [r.payments?.receipt_number, `${r.payments?.patients?.first_name} ${r.payments?.patients?.last_name}`, r.invoices?.invoice_number, `Rs.${r.amount}`, r.reason],
    }));
    return { title: `Refund Report -- ${rangeLabel}`, headers: ['Receipt #', 'Patient', 'Invoice', 'Amount', 'Reason'], rows, total: (data || []).reduce((s, r) => s + Number(r.amount), 0) };
  }

  return { title: 'Report', headers: [], rows: [], total: null };
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

cat > "app/(main)/payments/ledger/page.js" << 'EOF'
import PaymentsTabs from '../payments-tabs';
import LedgerTab from './ledger-tab';

export default function LedgerPage() {
  return (
    <div>
      <PaymentsTabs />
      <LedgerTab />
    </div>
  );
}

EOF

cat > "app/(main)/payments/ledger/ledger-tab.js" << 'EOF'
'use client';

import { useState } from 'react';
import { searchPatientsForPayment, getPatientUnifiedLedger, getAdvanceBalance, getOutstandingInvoices } from '../actions';

const TYPE_COLOR = {
  Invoice: 'var(--red)', Payment: 'var(--green)', Advance: 'var(--purple)',
  'Advance Adjustment': 'var(--blue)', Refund: 'var(--amber)', 'Credit Note': 'var(--teal)',
};

function fmt(n) {
  return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function LedgerTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [entries, setEntries] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [outstandingInvoices, setOutstandingInvoices] = useState([]);
  const [typeFilter, setTypeFilter] = useState('');
  const [visitFilter, setVisitFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setLoading(true);
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate('');
    const [ledgerEntries, balance, outstanding] = await Promise.all([
      getPatientUnifiedLedger(p.id), getAdvanceBalance(p.id), getOutstandingInvoices(p.id),
    ]);
    setEntries(ledgerEntries);
    setAdvanceBalance(balance);
    setOutstandingInvoices(outstanding);
    setLoading(false);
  }

  function changePatient() {
    setPatient(null);
    setEntries([]);
  }

  const visits = [...new Set(entries.map((e) => e.visit).filter((v) => v && v !== '--'))];
  const filtered = entries.filter((e) => {
    if (typeFilter && e.type !== typeFilter) return false;
    if (visitFilter && e.visit !== visitFilter) return false;
    if (fromDate && new Date(e.date) < new Date(fromDate)) return false;
    if (toDate && new Date(e.date) > new Date(`${toDate}T23:59:59`)) return false;
    return true;
  });

  const totalInvoiced = entries.filter((e) => e.type === 'Invoice').reduce((s, e) => s + e.debit, 0);
  const totalCollected = entries.filter((e) => e.type !== 'Invoice').reduce((s, e) => s + e.credit - e.debit, 0);
  const currentBalance = entries.length > 0 ? entries[0].balance : 0;

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Patient Ledger
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Spans all visits for this patient. Outstanding balance is calculated dynamically from every entry below -- Balance {'>'} 0 means the patient owes the hospital; Balance {'<'} 0 means the hospital owes the patient (unused advance).
        </div>

        {!patient ? (
          <div>
            <label className="flbl">Search patient (name, UHID, or mobile)</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
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
            <div style={{ background: 'linear-gradient(135deg,#4c1d95,#7c3aed)', borderRadius: 12, padding: '14px 18px', color: '#fff', marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 16, fontWeight: 700 }}>{patient.first_name} {patient.last_name}</div>
                  <div style={{ fontSize: 12, opacity: .8, marginTop: 2 }}>{patient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={changePatient} style={{ background: 'rgba(255,255,255,.15)', color: '#fff', border: '1px solid rgba(255,255,255,.3)' }}>
                  <i className="ti ti-arrow-left"></i> Change patient
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginTop: 14 }}>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Invoiced</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3 }}>Rs.{fmt(totalInvoiced)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Collected</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#86efac' }}>Rs.{fmt(totalCollected)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Advance Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#c4b5fd' }}>Rs.{fmt(advanceBalance)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Current Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: currentBalance > 0 ? '#fca5a5' : '#86efac' }}>Rs.{fmt(currentBalance)}</div>
                </div>
              </div>
            </div>

            {loading ? (
              <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading ledger...</div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
                  <select className="fi" style={{ width: 'auto' }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                    <option value="">All types</option>
                    {Object.keys(TYPE_COLOR).map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                  <select className="fi" style={{ width: 'auto' }} value={visitFilter} onChange={(e) => setVisitFilter(e.target.value)}>
                    <option value="">All visits</option>
                    {visits.map((v) => <option key={v} value={v}>{v}</option>)}
                  </select>
                  <input type="date" className="fi" style={{ width: 'auto' }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
                  <input type="date" className="fi" style={{ width: 'auto' }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
                  {(typeFilter || visitFilter || fromDate || toDate) && (
                    <button className="btn btn-sm" onClick={() => { setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate(''); }}>
                      <i className="ti ti-x"></i> Clear
                    </button>
                  )}
                </div>

                <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
                  <table className="tbl">
                    <thead>
                      <tr><th>Date/Time</th><th>Type</th><th>Reference</th><th>Visit</th><th>Description</th><th style={{ textAlign: 'right' }}>Debit</th><th style={{ textAlign: 'right' }}>Credit</th><th style={{ textAlign: 'right' }}>Balance</th></tr>
                    </thead>
                    <tbody>
                      {filtered.map((e, i) => (
                        <tr key={i} style={{ borderLeft: `3px solid ${TYPE_COLOR[e.type]}` }}>
                          <td style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{new Date(e.date).toLocaleString('en-IN', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                          <td>
                            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600 }}>
                              <span style={{ width: 7, height: 7, borderRadius: '50%', background: TYPE_COLOR[e.type], flexShrink: 0 }}></span>
                              {e.type}
                            </span>
                          </td>
                          <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.ref}</td>
                          <td style={{ fontSize: 11 }}>{e.visit}</td>
                          <td style={{ fontSize: 12 }}>{e.desc}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.debit > 0 ? <span style={{ color: 'var(--red)', fontWeight: 600 }}>{fmt(e.debit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.credit > 0 ? <span style={{ color: 'var(--green)', fontWeight: 600 }}>{fmt(e.credit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 700, color: e.balance > 0 ? 'var(--red)' : e.balance < 0 ? 'var(--purple)' : 'var(--green)' }}>{fmt(e.balance)}</td>
                        </tr>
                      ))}
                      {filtered.length === 0 && (
                        <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No entries match these filters.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <div className="card" style={{ padding: '10px 14px' }}>
                  <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: 'var(--g600)' }}>
                    {Object.entries(TYPE_COLOR).map(([type, color]) => (
                      <span key={type}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: color, marginRight: 4 }}></span>{type}</span>
                    ))}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/payments/credit-note/page.js" << 'EOF'
import PaymentsTabs from '../payments-tabs';
import CreditNoteTab from './credit-note-tab';

export default function CreditNotePage() {
  return (
    <div>
      <PaymentsTabs />
      <CreditNoteTab />
    </div>
  );
}

EOF

cat > "app/(main)/payments/credit-note/credit-note-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, getApprovers, createCreditNote, getCreditNoteRegister } from '../actions';

const REASONS = ['Billing correction', 'Service cancellation', 'Approved financial adjustment', 'Goodwill gesture', 'Insurance adjustment', 'Other'];

export default function CreditNoteTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [invoiceId, setInvoiceId] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
  }, []);

  async function refreshRegister() {
    setRegister(await getCreditNoteRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setInvoices(await getOutstandingInvoices(p.id));
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
  }

  function changePatient() {
    setPatient(null);
    setInvoices([]);
  }

  const selectedInvoice = invoices.find((i) => i.id === invoiceId);
  const outstandingOnSelected = selectedInvoice ? Number(selectedInvoice.net) - Number(selectedInvoice.paid) : 0;

  async function handleSubmit() {
    setError(''); setSuccess('');
    if (!invoiceId) { setError('Select an invoice to credit.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid credit amount.'); return; }
    if (amt > outstandingOnSelected) { setError(`Credit amount cannot exceed this invoice's outstanding balance (Rs.${outstandingOnSelected.toFixed(2)}).`); return; }
    if (!reason) { setError('Select a reason.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    const result = await createCreditNote(patient.id, invoiceId, amt, reason, approvedBy, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Credit note ${result.creditNote.credit_note_number} created for Rs.${amt.toFixed(2)}.`);
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
    setInvoices(await getOutstandingInvoices(patient.id));
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-file-minus" style={{ color: 'var(--teal)' }}></i> Credit Note
        </div>
        <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Reduces what a patient owes on an invoice without reversing any payment -- for billing corrections, service cancellations, goodwill, or insurance adjustments. Different from a refund, which returns money already collected.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

        {!patient ? (
          <div>
            <label className="flbl">Patient</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
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
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--teal-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 14 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={changePatient}>Change</button>
            </div>

            <label className="flbl">Invoice to credit *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
              <option value="">-- Select invoice --</option>
              {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)} outstanding</option>)}
            </select>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 12 }}>No outstanding invoices for this patient.</div>}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Reason *</label>
                <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                  <option value="">-- Select reason --</option>
                  {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Credit amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={selectedInvoice ? `Up to Rs.${outstandingOnSelected.toFixed(2)}` : '0.00'} />
              </div>
            </div>

            <label className="flbl">Approved by *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
              <option value="">-- Select approver --</option>
              {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` -- ${a.designation}` : ''}</option>)}
            </select>

            <label className="flbl">Remarks</label>
            <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Supporting details for this credit note..." />

            <button className="btn" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleSubmit} disabled={loading || invoices.length === 0}>
              <i className="ti ti-file-minus"></i> {loading ? 'Creating...' : 'Create Credit Note'}
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Credit Note Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>CN #</th><th>Patient</th><th>Invoice</th><th>Amount</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((cn) => (
                <tr key={cn.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.credit_note_number}</td>
                  <td style={{ fontSize: 12 }}>{cn.patients?.first_name} {cn.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.invoices?.invoice_number || '--'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(cn.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{cn.reason}</td>
                  <td style={{ fontSize: 11 }}>{cn.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No credit notes issued yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Credit Note + unified Patient Ledger View created."