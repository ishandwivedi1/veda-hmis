'use client';

import { useState, useEffect, useRef } from 'react';
import { formatPatientName } from '@/lib/patientName';
import {
  searchPatientsForInvoice,
  createOpticalSale,
  cancelOpticalSale,
  getRecentOpticalItemNames,
  getOpticalSalesForDate,
} from './actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function todayIST() {
  return new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

export default function OpticalShopTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [contextPatient, setContextPatient] = useState(null);
  const [walkInName, setWalkInName] = useState('');
  const [walkInMobile, setWalkInMobile] = useState('');
  const [useWalkIn, setUseWalkIn] = useState(false);

  const [lines, setLines] = useState([{ tempId: 1, description: '', qty: 1, unit_price: '' }]);
  const [discount, setDiscount] = useState('');
  const [paymentMode, setPaymentMode] = useState('Cash');
  const [notes, setNotes] = useState('');
  const nextTempId = useRef(2);

  const [recentItems, setRecentItems] = useState([]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [lastSale, setLastSale] = useState(null);

  const [todaySales, setTodaySales] = useState([]);
  const [loadingSales, setLoadingSales] = useState(true);
  const [cancelTarget, setCancelTarget] = useState(null);
  const [cancelReason, setCancelReason] = useState('');

  useEffect(() => {
    getRecentOpticalItemNames().then(setRecentItems);
    refreshTodaySales();
  }, []);

  async function refreshTodaySales() {
    setLoadingSales(true);
    const result = await getOpticalSalesForDate(todayIST());
    setTodaySales(result.sales || []);
    setLoadingSales(false);
  }

  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => setSearchResults(await searchPatientsForInvoice(q)), 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function pickPatient(p) {
    setContextPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setUseWalkIn(false);
  }

  function clearCustomer() {
    setContextPatient(null);
    setWalkInName('');
    setWalkInMobile('');
    setUseWalkIn(false);
  }

  function updateLine(tempId, field, value) {
    setLines((prev) => prev.map((l) => (l.tempId === tempId ? { ...l, [field]: value } : l)));
  }

  function addLine() {
    setLines((prev) => [...prev, { tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
  }

  function removeLine(tempId) {
    setLines((prev) => (prev.length > 1 ? prev.filter((l) => l.tempId !== tempId) : prev));
  }

  const gross = lines.reduce((s, l) => s + (Number(l.qty) || 0) * (Number(l.unit_price) || 0), 0);
  const net = Math.max(0, gross - (Number(discount) || 0));

  async function handleSubmit() {
    setError('');
    setLastSale(null);
    setSaving(true);
    const result = await createOpticalSale({
      patientId: contextPatient?.id || null,
      customerName: useWalkIn || !contextPatient ? walkInName : null,
      customerMobile: useWalkIn || !contextPatient ? walkInMobile : null,
      paymentMode,
      items: lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
      discount,
      notes,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setLastSale(result.sale);
    clearCustomer();
    setLines([{ tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
    setDiscount('');
    setNotes('');
    getRecentOpticalItemNames().then(setRecentItems);
    refreshTodaySales();
  }

  async function handleCancel() {
    if (!cancelTarget) return;
    const result = await cancelOpticalSale(cancelTarget.id, cancelReason);
    if (result.error) { setError(result.error); return; }
    setCancelTarget(null);
    setCancelReason('');
    refreshTodaySales();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-glasses" style={{ color: 'var(--blue)' }}></i> New Optical Sale
        </div>

        {error && <div className="msg-err">{error}</div>}
        {lastSale && (
          <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '10px 12px', borderRadius: 8, fontSize: 13, marginBottom: 12, display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
            <span><i className="ti ti-check"></i> Sale {lastSale.sale_number} recorded -- {fmt(lastSale.net)}</span>
            <a href={`/optical-receipt-print/${lastSale.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print Receipt
            </a>
          </div>
        )}

        <label className="flbl">Customer</label>
        {!contextPatient && !useWalkIn && (
          <div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search registered patient by name, UHID, or mobile..." />
              <button className="btn" onClick={() => setUseWalkIn(true)}><i className="ti ti-user-plus"></i> Walk-in Customer</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{formatPatientName(p)}</strong> -- {p.uhid} -- {p.mobile}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
        {contextPatient && (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 12px', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 4 }}>
            <span><strong>{formatPatientName(contextPatient)}</strong> -- {contextPatient.uhid} -- {contextPatient.mobile}</span>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i> Change</button>
          </div>
        )}
        {useWalkIn && !contextPatient && (
          <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end' }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Walk-in name</label>
              <input className="fi" value={walkInName} onChange={(e) => setWalkInName(e.target.value)} placeholder="Customer name" />
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Mobile (optional)</label>
              <input className="fi" value={walkInMobile} onChange={(e) => setWalkInMobile(e.target.value)} placeholder="10-digit mobile" />
            </div>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i></button>
          </div>
        )}

        <label className="flbl" style={{ marginTop: 16 }}>Items</label>
        {recentItems.length > 0 && (
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 6 }}>
            Recent: {recentItems.slice(0, 8).map((name, i) => (
              <span key={name}>
                <span
                  onClick={() => {
                    const emptyLine = lines.find((l) => !l.description);
                    if (emptyLine) updateLine(emptyLine.tempId, 'description', name);
                    else setLines((prev) => [...prev, { tempId: nextTempId.current++, description: name, qty: 1, unit_price: '' }]);
                  }}
                  style={{ cursor: 'pointer', textDecoration: 'underline', color: 'var(--blue)' }}
                >
                  {name}
                </span>
                {i < Math.min(recentItems.length, 8) - 1 ? ', ' : ''}
              </span>
            ))}
          </div>
        )}
        {lines.map((l) => (
          <div key={l.tempId} style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
            <input className="fi" style={{ flex: 3 }} value={l.description} onChange={(e) => updateLine(l.tempId, 'description', e.target.value)} placeholder="Item description (e.g. Titan frame TN-2201)" />
            <input className="fi" type="number" min="1" style={{ flex: 1 }} value={l.qty} onChange={(e) => updateLine(l.tempId, 'qty', e.target.value)} placeholder="Qty" />
            <input className="fi" type="number" min="0" style={{ flex: 1 }} value={l.unit_price} onChange={(e) => updateLine(l.tempId, 'unit_price', e.target.value)} placeholder="Price" />
            <div style={{ flex: 1, alignSelf: 'center', fontSize: 13, textAlign: 'right' }}>{fmt((Number(l.qty) || 0) * (Number(l.unit_price) || 0))}</div>
            <button className="btn btn-sm" onClick={() => removeLine(l.tempId)}><i className="ti ti-trash"></i></button>
          </div>
        ))}
        <button className="btn btn-sm" onClick={addLine}><i className="ti ti-plus"></i> Add Item</button>

        <div style={{ display: 'flex', gap: 16, marginTop: 16 }}>
          <div style={{ flex: 1 }}>
            <label className="flbl">Discount (\u20b9)</label>
            <input className="fi" type="number" min="0" value={discount} onChange={(e) => setDiscount(e.target.value)} placeholder="0" />
          </div>
          <div style={{ flex: 1 }}>
            <label className="flbl">Payment Mode</label>
            <select className="fi" value={paymentMode} onChange={(e) => setPaymentMode(e.target.value)}>
              {PAYMENT_MODES.map((m) => <option key={m} value={m}>{m}</option>)}
            </select>
          </div>
        </div>
        <label className="flbl" style={{ marginTop: 8 }}>Notes (optional)</label>
        <input className="fi" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. prescription reference, order details" />

        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0', marginTop: 16, borderTop: '1.5px solid var(--g200)' }}>
          <span style={{ fontSize: 14 }}>Gross: {fmt(gross)} {Number(discount) > 0 && <>-- Discount: {fmt(discount)}</>}</span>
          <span style={{ fontSize: 16, fontWeight: 700 }}>Net Payable: {fmt(net)}</span>
        </div>
        <button className="btn btn-primary" disabled={saving} onClick={handleSubmit}>
          <i className="ti ti-receipt"></i> {saving ? 'Recording...' : 'Record Sale & Collect Payment'}
        </button>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-list"></i> Today's Optical Sales</div>
        {loadingSales ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>
        ) : todaySales.length === 0 ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>No optical sales recorded today.</div>
        ) : (
          <>
            {todaySales.map((s) => (
              <div key={s.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12.5, opacity: s.status === 'Cancelled' ? 0.5 : 1 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{s.sale_number}</strong>
                  <span>{fmt(s.net)}{s.status === 'Cancelled' && ' (Cancelled)'}</span>
                </div>
                <div style={{ color: 'var(--g500)', display: 'flex', justifyContent: 'space-between' }}>
                  <span>{s.displayName || 'Walk-in'} -- {s.payment_mode}</span>
                  <span>{new Date(s.created_at).toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}</span>
                </div>
                <div style={{ display: 'flex', gap: 10, marginTop: 4 }}>
                  <a href={`/optical-receipt-print/${s.id}`} target="_blank" rel="noopener noreferrer" style={{ fontSize: 11, color: 'var(--blue)' }}>Print</a>
                  {s.status !== 'Cancelled' && (
                    <span onClick={() => setCancelTarget(s)} style={{ fontSize: 11, color: 'var(--red)', cursor: 'pointer' }}>Cancel</span>
                  )}
                </div>
              </div>
            ))}
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '10px 0 0', marginTop: 4, fontSize: 13, fontWeight: 700 }}>
              <span>Total today</span>
              <span>{fmt(todaySales.filter((s) => s.status !== 'Cancelled').reduce((sum, s) => sum + Number(s.net), 0))}</span>
            </div>
          </>
        )}
      </div>

      {cancelTarget && (
        <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 50 }}>
          <div className="card" style={{ width: 380 }}>
            <div className="card-title">Cancel Sale {cancelTarget.sale_number}</div>
            <p style={{ fontSize: 13, color: 'var(--g500)' }}>This marks the sale as cancelled and keeps it on record for audit -- it isn't deleted.</p>
            <label className="flbl">Reason</label>
            <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Reason for cancellation" />
            <div style={{ display: 'flex', gap: 8, marginTop: 12, justifyContent: 'flex-end' }}>
              <button className="btn btn-sm" onClick={() => { setCancelTarget(null); setCancelReason(''); }}>Back</button>
              <button className="btn btn-sm btn-primary" style={{ background: 'var(--red)', borderColor: 'var(--red)' }} onClick={handleCancel}>Confirm Cancel</button>
            </div>
          </div>
        </div>
      )}
    </div>
  );
}
