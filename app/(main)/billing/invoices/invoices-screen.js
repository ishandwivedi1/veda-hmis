'use client';

// Invoices -- the single Zoho-style Billing screen (2 Oct 2026).
//   * Summary strip (outstanding, billed today) + a "To bill" row with the
//     front-office work lists the old dashboard had (surgery billing due,
//     unbilled investigations / OPD procedures / pharmacy, today's visits).
//   * Invoice list; click one -> split view: compact list left, the invoice
//     right with Edit / Record Payment / PDF-Print / WhatsApp / History and
//     a "Payments received (n)" strip.
//   * Edit uses the shared InvoiceEditPanel (edit_invoice / void_invoice);
//     surgery invoices also get the Surgery Billing Details editor that
//     used to live in Invoice Modification.
//   * ?invoiceId= opens an invoice; ?visitId= shows that visit's invoices.

import { useState, useEffect, useCallback, useRef } from 'react';
import { useSearchParams, useRouter } from 'next/navigation';
import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { openPrintPopup } from '@/lib/printPopup';
import { resendInvoiceBillWhatsApp } from '../actions';
// Saves that send back the refreshed invoice / list / history in the same
// response -- one request per click, no reloads afterwards.
import { applyCreditsAndRefresh, saveSurgeryDetailsAndRefresh } from '../invoice-change-actions';
import { getInvoicePanel, getBillingScreenData } from '@/lib/rpc-reads/billing__invoices-screen-actions'; // parallel reads (tools/parallel-reads)
import DayOpenBar from '@/app/components/DayOpenBar';
import InvoiceEditPanel from '../invoice-edit-panel';
import InvoiceHistory from '../invoice-history';
import PendingBillingWidget from '../pending-billing-widget';

const STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };
const STATUS_LABEL = { Paid: 'PAID', Partial: 'PARTIALLY PAID', Pending: 'UNPAID', Cancelled: 'VOID' };
const VISIT_TYPE_COLOR = {
  'New Consultation': '--blue', 'OPD Follow Up': '--green', 'Investigation Only': '--purple',
  'Post-operative Review': '--amber', Emergency: '--red', Procedure: '--teal', 'OPD Procedure Only': '--teal',
};

const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' });
const timeIST = (d) => new Date(d).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' });
const balanceOf = (inv) => (inv.status === 'Cancelled' ? 0 : r2(Number(inv.net) - Number(inv.paid)));

// ─────────────────────────────────────────────────────────────────────
function Menu({ label, icon, primary, items }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return;
    const close = (e) => { if (ref.current && !ref.current.contains(e.target)) setOpen(false); };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open]);
  return (
    <div ref={ref} style={{ position: 'relative' }}>
      <button type="button" className={primary ? 'btn btn-primary' : 'btn'} onClick={() => setOpen((v) => !v)}>
        {icon && <i className={`ti ${icon}`}></i>} {label} {primary && <i className="ti ti-chevron-down" style={{ fontSize: 12 }}></i>}
      </button>
      {open && (
        <div style={{ position: 'absolute', right: 0, top: 'calc(100% + 4px)', background: '#fff', border: '1px solid var(--g200)', borderRadius: 10, boxShadow: 'var(--shadow-lg, 0 8px 24px rgba(0,0,0,.12))', minWidth: 230, zIndex: 50, padding: 4 }}>
          {items.map((it) => (
            <Link key={it.label} href={it.href} onClick={() => setOpen(false)} style={{ display: 'flex', gap: 10, alignItems: 'center', padding: '8px 10px', borderRadius: 8, textDecoration: 'none', color: 'var(--g800)' }}
              onMouseEnter={(e) => { e.currentTarget.style.background = 'var(--g50)'; }} onMouseLeave={(e) => { e.currentTarget.style.background = 'transparent'; }}>
              <i className={`ti ${it.icon}`} style={{ color: 'var(--blue)', fontSize: 16 }}></i>
              <span><span style={{ fontWeight: 600, fontSize: 13 }}>{it.label}</span>{it.hint && <span style={{ display: 'block', fontSize: 11, color: 'var(--g500)' }}>{it.hint}</span>}</span>
            </Link>
          ))}
        </div>
      )}
    </div>
  );
}

// Data comes from the screen's single load request (no request of its own).
function Summary({ s }) {
  const cell = (label, value, sub, color) => (
    <div style={{ flex: '1 1 160px', padding: '4px 16px', borderLeft: '1px solid var(--g200)' }}>
      <div style={{ fontSize: 12, color: 'var(--g500)' }}>{label}</div>
      <div style={{ fontSize: 18, fontWeight: 700, color: color || 'var(--g800)', marginTop: 2 }}>{s ? value : '--'}</div>
      {sub && s && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{sub}</div>}
    </div>
  );
  return (
    <div className="card" style={{ display: 'flex', flexWrap: 'wrap', alignItems: 'center', padding: '12px 4px', marginBottom: 12, gap: '8px 0' }}>
      <div style={{ flex: '1 1 200px', padding: '4px 16px', display: 'flex', gap: 10, alignItems: 'center' }}>
        <span style={{ width: 38, height: 38, borderRadius: '50%', background: '#fde68a', display: 'inline-flex', alignItems: 'center', justifyContent: 'center' }}><i className="ti ti-arrow-down-left" style={{ color: '#b45309', fontSize: 18 }}></i></span>
        <div>
          <div style={{ fontSize: 12, color: 'var(--g500)' }}>Total outstanding</div>
          <div style={{ fontSize: 20, fontWeight: 800 }}>{s ? money(s.outstanding) : '--'}</div>
          {s && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{s.outstandingCount} unpaid / part-paid invoice{s.outstandingCount === 1 ? '' : 's'}</div>}
        </div>
      </div>
      {cell('Billed today', s ? money(s.todayBilled) : '', s ? `${s.todayCount} invoice${s.todayCount === 1 ? '' : 's'}` : '')}
      {cell('Still due from today', s ? money(s.todayDue) : '', null, s && s.todayDue > 0 ? 'var(--red)' : undefined)}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// "To bill" -- the front-office work lists from the old dashboard.
// ─────────────────────────────────────────────────────────────────────
function ToBill({ fullyPaidUnbilled, todaysVisits, billingByVisit, pending, onShowVisit }) {
  const router = useRouter();
  const [open, setOpen] = useState(null); // null | surgery | investigations | opdProcedures | pharmacy | visits
  const [todayOnly, setTodayOnly] = useState(true);
  const [counts, setCounts] = useState({ investigation: 0, procedure: 0, pharmacy: 0 });
  const unbilledVisits = todaysVisits.filter((v) => !(billingByVisit[v.id]?.count > 0)).length;

  const chip = (key, label, n, color) => (
    <button key={key} type="button" onClick={() => setOpen(open === key ? null : key)}
      style={{ display: 'inline-flex', alignItems: 'center', gap: 6, padding: '6px 12px', borderRadius: 999, fontSize: 12.5, fontWeight: 600, cursor: 'pointer',
        border: `1.5px solid ${open === key ? `var(${color})` : 'var(--g200)'}`, background: open === key ? `var(${color}-lt, #eef2ff)` : '#fff', color: 'var(--g700)' }}>
      {label}
      <span style={{ minWidth: 20, padding: '0 6px', borderRadius: 999, background: n > 0 ? `var(${color})` : 'var(--g200)', color: n > 0 ? '#fff' : 'var(--g600)', fontSize: 11.5, lineHeight: '18px' }}>{n}</span>
    </button>
  );

  return (
    <div style={{ marginBottom: 12 }}>
      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', alignItems: 'center' }}>
        <span style={{ fontSize: 12, fontWeight: 700, color: 'var(--g500)', marginRight: 2 }}>TO BILL</span>
        {chip('surgery', 'Surgery billing due', fullyPaidUnbilled.length, '--purple')}
        {chip('investigations', 'Investigations', counts.investigation, '--teal')}
        {chip('opdProcedures', 'OPD Procedures', counts.procedure, '--amber')}
        {chip('pharmacy', 'Pharmacy', counts.pharmacy, '--indigo')}
        {chip('visits', "Today's visits not billed", unbilledVisits, '--blue')}
        <span style={{ marginLeft: 'auto', display: 'inline-flex', gap: 4, background: 'var(--g100)', borderRadius: 8, padding: 3 }}>
          {[true, false].map((t) => (
            <button key={String(t)} type="button" onClick={() => setTodayOnly(t)}
              style={{ padding: '4px 10px', borderRadius: 6, fontSize: 11.5, fontWeight: 600, border: 'none', cursor: 'pointer', background: todayOnly === t ? '#fff' : 'transparent', color: todayOnly === t ? 'var(--indigo)' : 'var(--g500)' }}>
              {t ? 'Today' : 'All dates'}
            </button>
          ))}
        </span>
      </div>

      {/* Kept mounted (hidden when closed) so the chip counts stay live. */}
      <div className="card" style={{ marginTop: 8, display: ['investigations', 'opdProcedures', 'pharmacy'].includes(open) ? 'block' : 'none' }}>
        <PendingBillingWidget
          initialData={pending}
          bare todayOnly={todayOnly} onCounts={setCounts}
          visibleCategories={open === 'investigations' ? ['Investigation', 'Biometry'] : open === 'opdProcedures' ? ['Procedure'] : open === 'pharmacy' ? ['Pharmacy'] : []}
        />
      </div>

      {open === 'surgery' && (
        <div className="card" style={{ marginTop: 8 }}>
          <table className="tbl">
            <thead><tr><th>Patient</th><th>Surgery</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {fullyPaidUnbilled.map((sc) => (
                <tr key={sc.id}>
                  <td><strong>{formatPatientName(sc.patients)}</strong><br /><span style={{ fontSize: 11, color: 'var(--g400)' }}>{sc.patients?.uhid}</span></td>
                  <td style={{ fontSize: 12 }}>
                    {sc.procedure_name} ({sc.eye})
                    {sc.additionalProcedures?.length > 0 && <div style={{ color: 'var(--g400)' }}>+ {sc.additionalProcedures.map((p) => `${p.procedure_name} (${p.eye})`).join(', ')}</div>}
                  </td>
                  <td style={{ fontWeight: 600 }}>{money(sc.netTotal)}</td>
                  <td><button type="button" className="btn btn-primary btn-sm" onClick={() => router.push(`/billing/new?pkgCaseId=${sc.id}`)}><i className="ti ti-receipt"></i> Bill Now</button></td>
                </tr>
              ))}
              {fullyPaidUnbilled.length === 0 && <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No surgeries fully paid and awaiting billing.</td></tr>}
            </tbody>
          </table>
        </div>
      )}

      {open === 'visits' && (
        <div className="card" style={{ marginTop: 8 }}>
          <table className="tbl">
            <thead><tr><th>Visit</th><th>Time</th><th>Patient</th><th>Type</th><th>Doctor</th><th>Billing</th><th></th></tr></thead>
            <tbody>
              {todaysVisits.map((v) => {
                const billing = billingByVisit[v.id] || { count: 0, label: '--', badge: 'b-gray' };
                return (
                  <tr key={v.id}>
                    <td style={{ fontFamily: 'monospace', color: 'var(--blue)', fontSize: 11 }}>{v.visit_number || '--'}</td>
                    <td>{timeIST(v.created_at)}</td>
                    <td><div style={{ fontWeight: 600 }}>{formatPatientName(v.patients)}</div><div style={{ fontSize: 11, color: 'var(--g500)', fontFamily: 'monospace' }}>{v.patients?.uhid}</div></td>
                    <td><span className="badge" style={{ background: `var(${VISIT_TYPE_COLOR[v.visit_type] || '--g400'})`, color: '#fff' }}>{v.visit_type}</span></td>
                    <td>{v.profiles?.full_name || '--'}</td>
                    <td><span className={`badge ${billing.badge}`}>{billing.label}</span>{billing.count > 1 && <span style={{ fontSize: 10, color: 'var(--g400)', marginLeft: 4 }}>({billing.count})</span>}</td>
                    <td>
                      <div style={{ display: 'flex', gap: 4 }}>
                        <Link href={`/billing/new?visitId=${v.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-receipt"></i> New Invoice</Link>
                        {billing.count > 0 && <button type="button" className="btn btn-sm" onClick={() => { setOpen(null); onShowVisit(v.id, v.visit_number); }}><i className="ti ti-list"></i> Invoices</button>}
                      </div>
                    </td>
                  </tr>
                );
              })}
              {todaysVisits.length === 0 && <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No visits yet today.</td></tr>}
            </tbody>
          </table>
        </div>
      )}
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Surgery Billing Details (prints on the Surgery Bill) -- moved here from
// the retired Invoice Modification tab.
// ─────────────────────────────────────────────────────────────────────
function SurgeryDetails({ invoice, opts = { surgeries: [], doctors: [] }, refresh, onSaved }) {
  const [name, setName] = useState(invoice.manual_surgery_name || '');
  const [eye, setEye] = useState(invoice.manual_surgery_eye || '');
  const [doctorId, setDoctorId] = useState(invoice.manual_surgeon_id || '');
  const [saving, setSaving] = useState(false);
  const [msg, setMsg] = useState('');
  // (surgery + surgeon lists arrive with the Edit screen's single load)
  async function save() {
    if (saving) return;
    setSaving(true); setMsg('');
    const res = await saveSurgeryDetailsAndRefresh(invoice.id, name, eye, doctorId, refresh);
    setSaving(false);
    if (res?.error) { setMsg(res.error); return; }
    setMsg('Saved.');
    onSaved(res.refresh);
  }
  return (
    <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '10px 12px', marginTop: 12 }}>
      <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
        <i className="ti ti-scalpel"></i> Surgery Billing Details <span style={{ fontWeight: 400, color: 'var(--g400)' }}>(prints on the Surgery Bill)</span>
      </div>
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: 8 }}>
        <select className="fi fi-sm" value={name} onChange={(e) => setName(e.target.value)}>
          <option value="">-- Surgery --</option>
          {opts.surgeries.map((s) => <option key={s.id} value={s.name}>{s.name}</option>)}
        </select>
        <select className="fi fi-sm" value={eye} onChange={(e) => setEye(e.target.value)}>
          <option value="">-- Eye --</option>
          <option value="OD">Right (OD)</option><option value="OS">Left (OS)</option><option value="OU">Both (OU)</option>
        </select>
        <select className="fi fi-sm" value={doctorId} onChange={(e) => setDoctorId(e.target.value)}>
          <option value="">-- Surgeon --</option>
          {opts.doctors.map((d) => <option key={d.id} value={d.id}>{d.full_name}</option>)}
        </select>
      </div>
      <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 8 }}>
        <button type="button" className="btn btn-sm" disabled={saving} onClick={save}><i className="ti ti-device-floppy"></i> {saving ? 'Saving...' : 'Save surgery details'}</button>
        {msg && <span style={{ fontSize: 12, color: msg === 'Saved.' ? 'var(--green)' : 'var(--red)' }}>{msg}</span>}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Right-hand invoice pane
// ─────────────────────────────────────────────────────────────────────
function InvoiceDetail({ invoiceId, onChanged, onClose, listArgs, onScreen }) {
  const [data, setData] = useState(null);
  const [error, setError] = useState('');
  const [mode, setMode] = useState('view'); // view | edit
  const [showPayments, setShowPayments] = useState(false);
  const [showHistory, setShowHistory] = useState(false);
  const [historyKey, setHistoryKey] = useState(0);
  // History entries that came back with a save (no separate reload).
  const [historyEntries, setHistoryEntries] = useState(undefined);
  // Surgery / surgeon lists, from the Edit screen's single load.
  const [surgeryOpts, setSurgeryOpts] = useState({ surgeries: [], doctors: [] });
  const [wa, setWa] = useState({ status: '', msg: '' });
  const [flash, setFlash] = useState('');
  // Zoho-style "Credits available -- Apply credits": the patient's unused
  // advance credit (apply_advance_adjustment) and any Open credit notes
  // (cn_apply), each with its own "amount to credit".
  const [credit, setCredit] = useState(0);
  const [openCNs, setOpenCNs] = useState([]);
  const [applyOpen, setApplyOpen] = useState(false);
  const [applyAmts, setApplyAmts] = useState({}); // sourceKey -> amount string
  const [applying, setApplying] = useState(false);
  const [applyErr, setApplyErr] = useState('');

  const applyPanel = useCallback((d) => {
    if (!d) return;
    if (d.error) { setError(d.error); return; }
    setError('');
    setData(d);
    // Credits arrive with the invoice (same request) -- no follow-up calls.
    setCredit(r2(d.advanceBalance));
    setOpenCNs(d.openCreditNotes || []);
  }, []);

  const load = useCallback(async () => {
    applyPanel(await getInvoicePanel(invoiceId));
  }, [invoiceId, applyPanel]);
  useEffect(() => { load(); }, [load]);

  async function sendWhatsApp() {
    if (wa.status === 'sending') return;
    setWa({ status: 'sending', msg: '' });
    try {
      const res = await resendInvoiceBillWhatsApp(invoiceId);
      if (res?.error) setWa({ status: 'error', msg: res.error });
      else if (res?.warning) setWa({ status: 'warning', msg: res.warning });
      else setWa({ status: 'sent', msg: 'Bill sent on WhatsApp.' });
    } catch {
      setWa({ status: 'error', msg: 'Could not send -- check the connection and try again.' });
    }
  }

  // Credit sources shown in the Apply credits table.
  const creditSources = [
    ...(credit > 0 ? [{ key: 'advance', label: 'Advance credit', balance: credit }] : []),
    ...openCNs.map((c) => ({ key: c.id, label: c.credit_note_number, date: c.created_at, balance: c.balance, cn: true })),
  ];
  const totalCredit = r2(creditSources.reduce((s, x) => s + x.balance, 0));

  function openApply(due) {
    // Pre-fill oldest-first up to the balance due (credit notes, then advance).
    let left = due;
    const next = {};
    [...creditSources.filter((x) => x.cn), ...creditSources.filter((x) => !x.cn)].forEach((x) => {
      const a = r2(Math.min(left, x.balance));
      if (a > 0) { next[x.key] = String(a); left = r2(left - a); }
    });
    setApplyAmts(next); setApplyErr(''); setApplyOpen(true);
  }

  async function applyCredits(due) {
    if (applying) return;
    setApplyErr('');
    const rows = creditSources.map((x) => ({ x, amt: r2(applyAmts[x.key]) })).filter((r) => r.amt > 0);
    const sum = r2(rows.reduce((s, r) => s + r.amt, 0));
    if (rows.length === 0) { setApplyErr('Enter an amount against at least one credit.'); return; }
    const over = rows.find((r) => r.amt > r.x.balance);
    if (over) { setApplyErr(`${over.x.label} only has ${money(over.x.balance)}.`); return; }
    if (sum > due) { setApplyErr(`Only ${money(due)} is due on this invoice.`); return; }
    setApplying(true);
    // ONE request: every chosen credit applied on the server, then the
    // refreshed invoice / list / history come back with it.
    const res = await applyCreditsAndRefresh(
      data.invoice.id, data.invoice.patient_id,
      rows.map((r) => ({ cn: !!r.x.cn, id: r.x.key, amount: r.amt, label: r.x.label })),
      refreshArgs(),
    );
    setApplying(false);
    if (res?.error) { setApplyErr(res.error); applyRefresh(res.refresh); return; }
    setApplyOpen(false);
    afterChange(`${money(sum)} of credit applied to ${data.invoice.invoice_number}.`, res.refresh);
  }

  // What a save should send back with it: the list (with the screen's
  // current filters) and, if it's open, the history.
  function refreshArgs() {
    return { list: listArgs || null, history: showHistory };
  }

  // Use what came back with the save -- no reload requests.
  function applyRefresh(refresh) {
    if (!refresh) return false;
    applyPanel(refresh.panel);
    if (refresh.screen) onScreen?.(refresh.screen);
    if (refresh.history) setHistoryEntries(refresh.history);
    // history closed: forget what we had, it loads fresh when opened
    else { setHistoryEntries(undefined); setHistoryKey((k) => k + 1); }
    return true;
  }

  function afterChange(msg, refresh) {
    setMode('view'); setFlash(msg);
    if (applyRefresh(refresh)) return;
    // (older callers without refreshed data: reload as before)
    setHistoryEntries(undefined); setHistoryKey((k) => k + 1);
    load(); onChanged(msg);
  }

  if (error) return <div className="card"><div className="msg-err">{error}</div><button type="button" className="btn btn-sm" onClick={onClose}>Close</button></div>;
  if (!data) return <div className="card" style={{ padding: 24, color: 'var(--g400)' }}>Loading...</div>;

  const inv = data.invoice;
  const cancelled = inv.status === 'Cancelled';
  const due = balanceOf(inv);
  const discount = r2(data.lineItems.reduce((s, li) => s + Number(li.disc || 0), 0));
  const hasSurgeryLine = data.lineItems.some((li) => li.dept === 'Surgery');

  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', padding: '12px 16px', borderBottom: '1px solid var(--g200)' }}>
        <div style={{ fontSize: 18, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>
          {inv.invoice_number || 'Invoice'} <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`} style={{ marginLeft: 6, verticalAlign: 'middle' }}>{STATUS_LABEL[inv.status] || inv.status}</span>
        </div>
        <button type="button" className="btn btn-sm" onClick={onClose} title="Close"><i className="ti ti-x"></i></button>
      </div>

      <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', padding: '8px 16px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)' }}>
        {!cancelled && (
          <button type="button" className={mode === 'edit' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode(mode === 'edit' ? 'view' : 'edit')}><i className="ti ti-edit"></i> Edit</button>
        )}
        {!cancelled && due > 0 && (
          <Link href={`/payments/collect?patientId=${inv.patient_id}&invoiceId=${inv.id}`} className="btn btn-sm btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-cash"></i> Record Payment</Link>
        )}
        <button type="button" className="btn btn-sm" onClick={() => openPrintPopup(`/invoice-print/${inv.id}`)}><i className="ti ti-printer"></i> PDF/Print</button>
        {!cancelled && (
          <Link href={`/credit-notes/new?patientId=${inv.patient_id}&invoiceId=${inv.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}><i className="ti ti-file-minus"></i> Credit Note</Link>
        )}
        {!cancelled && (
          <button type="button" className="btn btn-sm" disabled={wa.status === 'sending'} onClick={sendWhatsApp}>
            <i className="ti ti-brand-whatsapp" style={{ color: 'var(--green)' }}></i> {wa.status === 'sending' ? 'Sending...' : 'WhatsApp'}
          </button>
        )}
        <button type="button" className={showHistory ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setShowHistory((v) => !v)}><i className="ti ti-history"></i> History</button>
      </div>
      {wa.msg && <div className={wa.status === 'error' ? 'msg-err' : 'msg-success'} style={{ margin: '8px 16px 0' }}>{wa.msg}</div>}
      {flash && <div className="msg-success" style={{ margin: '8px 16px 0' }}><i className="ti ti-circle-check"></i> {flash}</div>}

      {/* Credits available (Zoho-style): advance credit + open credit notes */}
      {!cancelled && due > 0 && totalCredit > 0 && (
        <div style={{ margin: '12px 16px 0', padding: '10px 12px', borderRadius: 8, background: 'var(--purple-lt)', border: '1px solid #d8b4fe' }}>
          <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 13, color: 'var(--purple)' }}>
              <i className="ti ti-wallet"></i> <strong>Credits available: {money(totalCredit)}</strong>{' '}
              <span style={{ color: 'var(--g600)' }}>({creditSources.map((x) => x.label).join(', ')})</span>
            </span>
            {!applyOpen && (
              <button type="button" className="btn btn-sm" style={{ background: 'var(--purple)', color: '#fff', border: 'none' }} onClick={() => openApply(due)}>
                Apply credits
              </button>
            )}
          </div>
          {applyOpen && (
            <div style={{ marginTop: 8, background: '#fff', borderRadius: 8, padding: 8 }}>
              <table className="tbl" style={{ margin: 0 }}>
                <thead><tr><th>Credit</th><th>Date</th><th style={{ textAlign: 'right' }}>Available</th><th style={{ textAlign: 'right', width: 130 }}>Amount to credit</th></tr></thead>
                <tbody>
                  {creditSources.map((x) => (
                    <tr key={x.key}>
                      <td style={{ fontWeight: 600 }}>{x.label}</td>
                      <td>{x.date ? dateIST(x.date) : '--'}</td>
                      <td style={{ textAlign: 'right' }}>{money(x.balance)}</td>
                      <td style={{ textAlign: 'right' }}>
                        <input className="fi fi-sm" type="number" min="0" step="0.01" style={{ width: 115, textAlign: 'right' }}
                          value={applyAmts[x.key] || ''} onChange={(e) => setApplyAmts((a) => ({ ...a, [x.key]: e.target.value }))} />
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 8, flexWrap: 'wrap' }}>
                <span style={{ fontSize: 12.5 }}>Balance due {money(due)} · applying <strong>{money(r2(Object.values(applyAmts).reduce((t, v) => t + (Number(v) || 0), 0)))}</strong></span>
                <span style={{ flex: 1 }}></span>
                <button type="button" className="btn btn-sm btn-primary" disabled={applying} onClick={() => applyCredits(due)}>{applying ? 'Applying...' : 'Apply credits'}</button>
                <button type="button" className="btn btn-sm" disabled={applying} onClick={() => setApplyOpen(false)}>Cancel</button>
              </div>
              {applyErr && <div style={{ fontSize: 12, color: 'var(--red)', marginTop: 6 }}>{applyErr}</div>}
            </div>
          )}
        </div>
      )}

      {/* Payments received strip (Zoho-style) */}
      <div style={{ margin: '12px 16px 0', border: '1px solid var(--g200)', borderRadius: 8 }}>
        <button type="button" onClick={() => setShowPayments((v) => !v)} style={{ width: '100%', display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 12px', background: 'transparent', border: 'none', cursor: 'pointer', fontSize: 13, fontWeight: 600, color: 'var(--g700)' }}>
          <span>Payments received <span className="badge b-blue" style={{ marginLeft: 4 }}>{data.payments.length}</span>{data.refunds.length > 0 && <span className="badge b-red" style={{ marginLeft: 4 }}>{data.refunds.length} refund{data.refunds.length === 1 ? '' : 's'}</span>}</span>
          <i className={`ti ti-chevron-${showPayments ? 'up' : 'down'}`}></i>
        </button>
        {showPayments && (
          <table className="tbl" style={{ margin: 0 }}>
            <thead><tr><th>Date</th><th>Receipt #</th><th>Mode</th><th style={{ textAlign: 'right' }}>Applied</th></tr></thead>
            <tbody>
              {data.payments.map((p) => (
                <tr key={p.id}>
                  <td>{dateIST(p.collected_at)}</td>
                  <td><Link href={`/payments?paymentId=${p.id}`} style={{ color: 'var(--blue)', fontWeight: 600 }}>{p.receipt_number}</Link>{p.payment_type === 'advance_adjustment' && <span className="badge b-amber" style={{ marginLeft: 6 }}>Advance</span>}{p.payment_type === 'credit_note' && <span className="badge b-teal" style={{ marginLeft: 6 }}>Credit note</span>}</td>
                  <td>{p.modes || '--'}</td>
                  <td style={{ textAlign: 'right' }}>{money(p.applied)}</td>
                </tr>
              ))}
              {data.refunds.map((r) => (
                <tr key={r.id} style={{ color: 'var(--red)' }}>
                  <td>{dateIST(r.refunded_at)}</td><td>Refund</td><td>{r.refund_mode || '--'}</td><td style={{ textAlign: 'right' }}>-{money(r.amount)}</td>
                </tr>
              ))}
              {data.payments.length === 0 && data.refunds.length === 0 && <tr><td colSpan={4} style={{ color: 'var(--g400)', textAlign: 'center', padding: 12 }}>No payments yet.</td></tr>}
            </tbody>
          </table>
        )}
      </div>

      <div style={{ padding: 16 }}>
        {mode === 'edit' && (
          <>
            <InvoiceEditPanel
              key={`edit-${inv.id}`}
              invoiceId={inv.id}
              refresh={refreshArgs()}
              onContext={(c) => setSurgeryOpts(c.surgeryOptions || { surgeries: [], doctors: [] })}
              onClose={() => setMode('view')}
              onSaved={(_, credited, refresh) => afterChange(credited > 0 ? `Invoice updated. ${money(credited)} already paid is now kept as patient credit.` : 'Invoice updated.', refresh)}
              onVoided={(_, credited, refresh) => afterChange(credited > 0 ? `Invoice voided. ${money(credited)} already paid is now kept as patient credit.` : 'Invoice voided.', refresh)}
            />
            {hasSurgeryLine && <SurgeryDetails invoice={inv} opts={surgeryOpts} refresh={{ list: null, history: showHistory }} onSaved={(refresh) => applyRefresh(refresh)} />}
          </>
        )}

        {mode === 'view' && (
          <>
            {cancelled && (
              <div className="msg-err" style={{ marginBottom: 12 }}><i className="ti ti-ban"></i> Voided{inv.cancellation_reason ? ` -- ${inv.cancellation_reason}` : ''}.</div>
            )}
            <div style={{ display: 'grid', gridTemplateColumns: 'minmax(0, 1fr) auto', gap: 12, marginBottom: 12, fontSize: 13 }}>
              <div>
                <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 700 }}>BILL TO</div>
                <div style={{ fontWeight: 700, fontSize: 15 }}>{formatPatientName(inv.patients)}</div>
                <div style={{ color: 'var(--g500)' }}>{inv.patients?.uhid}{inv.patients?.mobile ? ` · ${inv.patients.mobile}` : ''}</div>
              </div>
              <div style={{ textAlign: 'right' }}>
                <div><span style={{ color: 'var(--g500)' }}>Invoice date </span><strong>{dateIST(inv.created_at)}</strong></div>
                {inv.visits?.visit_number && <div><span style={{ color: 'var(--g500)' }}>Visit </span>{inv.visits.visit_number}</div>}
                {inv.purpose && <div><span style={{ color: 'var(--g500)' }}>For </span>{inv.purpose}</div>}
              </div>
            </div>

            <table className="tbl">
              <thead><tr><th>#</th><th>Description</th><th style={{ textAlign: 'right' }}>Qty</th><th style={{ textAlign: 'right' }}>Rate</th><th style={{ textAlign: 'right' }}>Disc</th><th style={{ textAlign: 'right' }}>Amount</th></tr></thead>
              <tbody>
                {data.lineItems.map((li, i) => (
                  <tr key={li.id}>
                    <td>{i + 1}</td>
                    <td>{li.service_name}{li.dept && <span style={{ fontSize: 11, color: 'var(--g400)', marginLeft: 6 }}>{li.dept}</span>}</td>
                    <td style={{ textAlign: 'right' }}>{li.qty}</td>
                    <td style={{ textAlign: 'right' }}>{money(li.rate)}</td>
                    <td style={{ textAlign: 'right' }}>{Number(li.disc) > 0 ? money(li.disc) : ''}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600 }}>{money(li.net)}</td>
                  </tr>
                ))}
              </tbody>
            </table>

            <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 10 }}>
              <div style={{ minWidth: 240, fontSize: 13, lineHeight: 1.9 }}>
                {discount > 0 && <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Sub total</span><span>{money(inv.gross)}</span></div>}
                {discount > 0 && <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}><span>Discount</span><span>-{money(discount)}</span></div>}
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}><span>Total</span><span>{money(inv.net)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}><span>Paid</span><span>-{money(inv.paid)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 800, borderTop: '1px solid var(--g200)', color: due > 0 ? 'var(--red)' : 'var(--green)' }}><span>Balance due</span><span>{money(due)}</span></div>
              </div>
            </div>

            {hasSurgeryLine && (inv.manual_surgery_name || data.surgeonName) && (
              <div style={{ fontSize: 12, color: 'var(--g600)', marginTop: 8 }}>
                <i className="ti ti-scalpel"></i> {inv.manual_surgery_name || '--'}{inv.manual_surgery_eye ? ` (${inv.manual_surgery_eye})` : ''}{data.surgeonName ? ` · ${data.surgeonName}` : ''}
              </div>
            )}
          </>
        )}

        {showHistory && <div style={{ marginTop: 12 }}><InvoiceHistory invoiceId={inv.id} refreshKey={historyKey} entries={historyEntries} /></div>}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────
// Page
// ─────────────────────────────────────────────────────────────────────
export default function InvoicesScreen() {
  const searchParams = useSearchParams();
  const [query, setQuery] = useState(searchParams.get('q') || '');
  const [deptFilter, setDeptFilter] = useState('');
  const [statusFilter, setStatusFilter] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(searchParams.get('invoiceId') || null);
  const [visitFilter, setVisitFilter] = useState(searchParams.get('visitId') ? { id: searchParams.get('visitId'), label: '' } : null);
  const [screen, setScreen] = useState({ day: null, summary: null, todaysVisits: [], billingByVisit: {}, fullyPaidUnbilled: [], pending: null });
  const reqId = useRef(0);
  // First load and after any change: the full screen (day, summary, To
  // bill lists, invoices) in ONE request. A search/filter change: just the
  // list, still one request.
  const needFull = useRef(true);

  const runSearch = useCallback(async () => {
    const my = ++reqId.current;
    setLoading(true);
    const full = needFull.current;
    needFull.current = false;
    const res = await getBillingScreenData({ query, dept: deptFilter, dateFrom, dateTo, visitId: visitFilter?.id || null, full });
    if (my !== reqId.current) { if (full) needFull.current = true; return; }
    applyScreen(res, full);
    setLoading(false);
  }, [query, deptFilter, dateFrom, dateTo, visitFilter]);

  // Same screen data, whether from the screen's own request or sent back
  // with a save in the invoice pane.
  function applyScreen(res, full = true) {
    if (full && res) {
      setScreen({
        day: res.day, summary: res.summary, todaysVisits: res.todaysVisits || [], billingByVisit: res.billingByVisit || {},
        fullyPaidUnbilled: res.fullyPaidUnbilled || [], pending: res.pending || null,
      });
    }
    setRows(res?.invoices || []);
  }

  useEffect(() => {
    const t = setTimeout(runSearch, query ? 300 : 0);
    return () => clearTimeout(t);
  }, [runSearch, query]);

  // ?visitId= with exactly one invoice -> open it straight away.
  const autoOpened = useRef(false);
  useEffect(() => {
    if (!visitFilter || autoOpened.current || loading) return;
    autoOpened.current = true;
    if (rows.length === 1 && !selectedId) setSelectedId(rows[0].id);
  }, [visitFilter, rows, loading, selectedId]);

  const list = rows.filter((r) => !statusFilter || r.status === statusFilter);
  const split = !!selectedId;
  const totalDue = r2(list.reduce((s, r) => s + balanceOf(r), 0));

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, gap: 8, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 22, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>Invoices</div>
        <div style={{ display: 'flex', gap: 6 }}>
          <Link href="/billing/new" className="btn btn-primary" style={{ textDecoration: 'none' }}><i className="ti ti-plus"></i> New Invoice</Link>
          <Menu label="" icon="ti-dots" items={[
            { href: '/payments', icon: 'ti-receipt-2', label: 'Payments Received' },
            { href: '/payments/reports', icon: 'ti-file-report', label: 'Payment Reports' },
          ]} />
        </div>
      </div>

      <DayOpenBar status={screen.day} note="collecting money (incl. package advances) is blocked" source="Billing" />
      <Summary s={screen.summary} />
      <ToBill fullyPaidUnbilled={screen.fullyPaidUnbilled} todaysVisits={screen.todaysVisits} billingByVisit={screen.billingByVisit} pending={screen.pending}
        onShowVisit={(id, label) => { autoOpened.current = false; setSelectedId(null); setVisitFilter({ id, label }); }} />

      <div className="card" style={{ marginBottom: 12, padding: '10px 12px' }}>
        {visitFilter ? (
          <div style={{ display: 'flex', alignItems: 'center', gap: 8, fontSize: 13 }}>
            <span className="badge b-blue">Visit {visitFilter.label || ''}</span> Showing this visit&apos;s invoices.
            <button type="button" className="btn btn-sm" onClick={() => { setVisitFilter(null); setSelectedId(null); }}><i className="ti ti-x"></i> Show all invoices</button>
          </div>
        ) : (
          <>
            <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <input className="fi" style={{ flex: 2, minWidth: 200 }} value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Search patient name or UHID..." />
              <select className="fi" style={{ flex: 1, minWidth: 130 }} value={statusFilter} onChange={(e) => setStatusFilter(e.target.value)}>
                <option value="">All statuses</option>
                <option value="Pending">Unpaid</option>
                <option value="Partial">Partially paid</option>
                <option value="Paid">Paid</option>
                <option value="Cancelled">Void</option>
              </select>
              <select className="fi" style={{ flex: 1, minWidth: 140 }} value={deptFilter} onChange={(e) => setDeptFilter(e.target.value)}>
                <option value="">All departments</option>
                <option>Consultation</option><option>Investigation</option><option>Surgery</option><option>Pharmacy</option>
              </select>
              <input type="date" className="fi" style={{ width: 150 }} value={dateFrom} onChange={(e) => setDateFrom(e.target.value)} title="From" />
              <input type="date" className="fi" style={{ width: 150 }} value={dateTo} onChange={(e) => setDateTo(e.target.value)} title="To" />
            </div>
            <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>
              {!query && !dateFrom && !dateTo ? 'Latest 50 invoices. Search or pick dates to see older ones. ' : ''}
              {list.length} shown{totalDue > 0 ? ` · balance due ${money(totalDue)}` : ''}
            </div>
          </>
        )}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: split ? 'minmax(260px, 340px) minmax(0, 1fr)' : '1fr', gap: 12, alignItems: 'start' }}>
        <div className="card" style={{ padding: 0, overflow: 'auto', maxHeight: split ? 'calc(100vh - 230px)' : undefined }}>
          {split ? (
            <div>
              {list.map((inv) => (
                <div key={inv.id} onClick={() => setSelectedId(inv.id)}
                  style={{ padding: '10px 12px', borderBottom: '1px solid var(--g100)', cursor: 'pointer', background: selectedId === inv.id ? 'var(--blue-lt)' : 'transparent', opacity: inv.status === 'Cancelled' ? 0.55 : 1 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', gap: 8 }}>
                    <span style={{ fontWeight: 600, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>{formatPatientName(inv.patients)}</span>
                    <span style={{ fontWeight: 700 }}>{money(inv.net)}</span>
                  </div>
                  <div style={{ fontSize: 11.5, color: 'var(--g500)', marginTop: 2 }}>{inv.invoice_number} · {dateIST(inv.created_at)}</div>
                  <div style={{ fontSize: 11, marginTop: 3, display: 'flex', gap: 6, alignItems: 'center' }}>
                    <span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{STATUS_LABEL[inv.status] || inv.status}</span>
                    {balanceOf(inv) > 0 && <span style={{ color: 'var(--red)', fontWeight: 600 }}>Due {money(balanceOf(inv))}</span>}
                  </div>
                </div>
              ))}
              {!loading && list.length === 0 && <div style={{ padding: 16, color: 'var(--g400)', textAlign: 'center' }}>No invoices found.</div>}
            </div>
          ) : (
            <table className="tbl">
              <thead>
                <tr><th>Date</th><th>Invoice #</th><th>Visit</th><th>Patient</th><th>Status</th><th style={{ textAlign: 'right' }}>Amount</th><th style={{ textAlign: 'right' }}>Balance due</th><th></th></tr>
              </thead>
              <tbody>
                {list.map((inv) => (
                  <tr key={inv.id} onClick={() => setSelectedId(inv.id)} style={{ cursor: 'pointer', opacity: inv.status === 'Cancelled' ? 0.55 : 1 }}>
                    <td>{dateIST(inv.created_at)}</td>
                    <td style={{ color: 'var(--blue)', fontWeight: 600 }}>{inv.invoice_number || '--'}</td>
                    <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{inv.visits?.visit_number || '--'}</td>
                    <td style={{ fontWeight: 600 }}>{formatPatientName(inv.patients)} <span style={{ fontSize: 11, color: 'var(--g400)', fontWeight: 400 }}>{inv.patients?.uhid}</span></td>
                    <td><span className={`badge ${STATUS_BADGE[inv.status] || 'b-gray'}`}>{STATUS_LABEL[inv.status] || inv.status}</span></td>
                    <td style={{ textAlign: 'right' }}>{money(inv.net)}</td>
                    <td style={{ textAlign: 'right', fontWeight: 600, color: balanceOf(inv) > 0 ? 'var(--red)' : 'inherit' }}>{money(balanceOf(inv))}</td>
                    <td onClick={(e) => e.stopPropagation()}>
                      <button type="button" className="btn btn-sm" title="Print / PDF" onClick={() => openPrintPopup(`/invoice-print/${inv.id}`)}><i className="ti ti-printer"></i></button>
                    </td>
                  </tr>
                ))}
                {loading && list.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
                {!loading && list.length === 0 && <tr><td colSpan={8} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No invoices found.</td></tr>}
              </tbody>
            </table>
          )}
        </div>

        {split && (
          <div style={{ position: 'sticky', top: 12 }}>
            <InvoiceDetail
              key={selectedId}
              invoiceId={selectedId}
              onClose={() => setSelectedId(null)}
              onChanged={() => { needFull.current = true; runSearch(); }}
              listArgs={{ query, dept: deptFilter, dateFrom, dateTo, visitId: visitFilter?.id || null }}
              onScreen={(res) => { reqId.current += 1; applyScreen(res, true); setLoading(false); }}
            />
          </div>
        )}
      </div>
    </div>
  );
}
