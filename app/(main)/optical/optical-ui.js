'use client';

// Shared pieces for the Zoho-style Optical Shop screens (Bills, Payments)
// and the "+ New" pages: header with Bills / Payments / "+ New", the
// dropdown menu, and money / date helpers. Makes no requests of its own.

import { useState, useEffect, useRef } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';

export const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];
export const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
export const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
export const dateIST = (d) => (d ? new Date(String(d).length === 10 ? `${d}T00:00:00+05:30` : d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' }) : '--');
export const when = (d) => new Date(d).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });

export const BILL_STATUS_BADGE = { Paid: 'b-green', Partial: 'b-amber', Pending: 'b-red', Cancelled: 'b-gray' };
export const BILL_STATUS_LABEL = { Paid: 'PAID', Partial: 'PARTIALLY PAID', Pending: 'UNPAID', Cancelled: 'CANCELLED' };
export const PAYMENT_TYPE_LABEL = { sale_payment: 'Payment', advance: 'Advance', advance_adjustment: 'Advance applied', credit_note: 'Credit note', refund: 'Refund' };
export const PAYMENT_TYPE_BADGE = { sale_payment: 'b-green', advance: 'b-blue', advance_adjustment: 'b-amber', credit_note: 'b-teal', refund: 'b-red' };

export const NEW_ITEMS = [
  { href: '/optical/book', icon: 'ti-eyeglass', label: 'Book Spectacles', hint: 'Take an order + advance; bill at delivery' },
  { href: '/optical/finalize-order', icon: 'ti-package', label: 'Finalize Order', hint: 'Deliver a booked order and create its bill' },
  { href: '/optical/new', icon: 'ti-file-plus', label: 'New Bill', hint: 'Bill an over-the-counter sale now' },
  { href: '/optical/advance', icon: 'ti-piggy-bank', label: 'Advance', hint: 'Collect advance from a customer' },
  { href: '/optical/credit-note', icon: 'ti-file-minus', label: 'Credit Note', hint: 'Reduce what a customer owes on a bill' },
  { href: '/optical/refund', icon: 'ti-receipt-refund', label: 'Refund', hint: 'Return money paid or advance held' },
];

export function Menu({ label, icon, primary, items, align = 'right' }) {
  const [open, setOpen] = useState(false);
  const ref = useRef(null);
  useEffect(() => {
    if (!open) return undefined;
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
        <div style={{ position: 'absolute', [align]: 0, top: 'calc(100% + 4px)', background: '#fff', border: '1px solid var(--g200)', borderRadius: 10, boxShadow: 'var(--shadow-lg, 0 8px 24px rgba(0,0,0,.12))', minWidth: 250, zIndex: 50, padding: 4 }}>
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

// Header used on every Optical page: title, Bills | Payments switch, "+ New".
// (Replaces the old 7-tab bar, which also made its own "is today open?"
// request on every page -- the Bills / Payments screens now get that in
// their single load request.)
export function OpticalHeader({ title }) {
  const pathname = usePathname();
  const tab = (href, label, icon) => {
    const active = href === '/optical' ? pathname === '/optical' : pathname.startsWith(href);
    return (
      <Link href={href} className={active ? 'btn btn-sm btn-primary' : 'btn btn-sm'} style={{ textDecoration: 'none' }}>
        <i className={`ti ${icon}`}></i> {label}
      </Link>
    );
  };
  return (
    <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 12, gap: 8, flexWrap: 'wrap' }}>
      <div style={{ display: 'flex', alignItems: 'center', gap: 12, flexWrap: 'wrap' }}>
        <div style={{ fontSize: 22, fontWeight: 700, fontFamily: 'var(--font-display-stack)' }}>{title}</div>
        <div style={{ display: 'flex', gap: 4 }}>
          {tab('/optical', 'Bills', 'ti-file-invoice')}
          {tab('/optical/payments', 'Payments', 'ti-receipt-2')}
        </div>
      </div>
      <Menu label="New" icon="ti-plus" primary items={NEW_ITEMS} />
    </div>
  );
}

// Payment-mode rows (mode + amount), with "split into another mode".
export function ModeRows({ modes, setModes, total }) {
  const sum = r2(modes.reduce((s, m) => s + (Number(m.amount) || 0), 0));
  const setRow = (i, patch) => setModes((ms) => ms.map((m, j) => (j === i ? { ...m, ...patch } : m)));
  return (
    <div>
      {modes.map((m, i) => (
        <div key={i} style={{ display: 'flex', gap: 6, marginBottom: 6 }}>
          <select className="fi fi-sm" style={{ flex: 1 }} value={m.mode} onChange={(e) => setRow(i, { mode: e.target.value })}>
            {[...new Set([...PAYMENT_MODES, m.mode])].map((o) => <option key={o} value={o}>{o}</option>)}
          </select>
          <input type="number" min="0" step="0.01" className="fi fi-sm" style={{ width: 130 }} value={m.amount} onChange={(e) => setRow(i, { amount: e.target.value })} />
          {modes.length > 1 && <button type="button" className="btn btn-sm" onClick={() => setModes((ms) => ms.filter((_, j) => j !== i))}><i className="ti ti-x"></i></button>}
        </div>
      ))}
      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button type="button" className="btn btn-sm" onClick={() => setModes((ms) => [...ms, { mode: 'UPI', amount: '' }])}><i className="ti ti-plus"></i> Split into another mode</button>
        <span style={{ fontSize: 12, fontWeight: 600, color: Math.abs(sum - r2(total)) < 0.01 ? 'var(--green)' : 'var(--red)' }}>Modes {money(sum)} / {money(total)}</span>
      </div>
    </div>
  );
}
