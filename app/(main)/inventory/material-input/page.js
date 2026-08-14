'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import InventoryTabs from '../inventory-tabs';
import {
  getVendors, createPurchaseWithLines, getRecentPurchases, getPurchaseLines,
  getTrackedItemsForPicker, markPurchasePaid, markPurchaseUnpaid,
} from '../actions';

const emptyLine = () => ({ key: Math.random().toString(36).slice(2), itemId: '', batchNumber: '', expiryDate: '', qty: '', rate: '', discountPct: '' });

function lineTotal(l) {
  const qty = Number(l.qty) || 0;
  const rate = Number(l.rate) || 0;
  const disc = Number(l.discountPct) || 0;
  return qty * rate * (1 - disc / 100);
}

function Modal({ onClose, width = 420, children }) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={onClose}>
      <div className="card" style={{ width, marginBottom: 0, maxHeight: '85vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

export default function MaterialInputPage() {
  const [vendors, setVendors] = useState([]);
  const [itemPicker, setItemPicker] = useState([]);
  const [purchases, setPurchases] = useState([]);
  const [loading, setLoading] = useState(true);

  const [pVendorId, setPVendorId] = useState('');
  const [pBillNumber, setPBillNumber] = useState('');
  const [pBillDate, setPBillDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [pBillAmount, setPBillAmount] = useState('');
  const [pNotes, setPNotes] = useState('');
  const [pLines, setPLines] = useState([emptyLine()]);

  const [viewPurchase, setViewPurchase] = useState(null);
  const [purchaseLines, setPurchaseLines] = useState([]);

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [saving, setSaving] = useState(false);

  async function refresh() {
    const [v, items, recent] = await Promise.all([getVendors(), getTrackedItemsForPicker(), getRecentPurchases()]);
    setVendors(v);
    setItemPicker(items);
    setPurchases(recent);
    setLoading(false);
  }

  useEffect(() => { refresh(); }, []);

  function updateLine(key, field, value) {
    setPLines((prev) => prev.map((l) => (l.key === key ? { ...l, [field]: value } : l)));
  }
  function addLine() { setPLines((prev) => [...prev, emptyLine()]); }
  function removeLine(key) { setPLines((prev) => (prev.length > 1 ? prev.filter((l) => l.key !== key) : prev)); }

  function resetForm() {
    setPVendorId(''); setPBillNumber(''); setPBillAmount(''); setPNotes('');
    setPBillDate(new Date().toISOString().slice(0, 10));
    setPLines([emptyLine()]);
  }

  async function handleSavePurchase() {
    setError(''); setSuccess('');
    if (!pVendorId) { setError('Select a vendor. New vendors are added under Financial Masters > Vendors.'); return; }
    const validLines = pLines.filter((l) => l.itemId && Number(l.qty) > 0);
    if (validLines.length === 0) { setError('Add at least one item with a quantity.'); return; }

    setSaving(true);
    const res = await createPurchaseWithLines({
      vendorId: pVendorId, billNumber: pBillNumber, billDate: pBillDate, billAmount: pBillAmount, notes: pNotes,
      lines: validLines.map((l) => ({ ...l, costPrice: l.rate, itemName: itemPicker.find((p) => p.itemId === l.itemId)?.name })),
    });
    setSaving(false);
    if (res.error && !res.partial) { setError(res.error); return; }
    if (res.partial) alert(res.error);
    setSuccess('Purchase saved and stock updated.');
    resetForm();
    refresh();
  }

  async function openViewPurchase(p) {
    setViewPurchase(p);
    const lines = await getPurchaseLines(p.id);
    setPurchaseLines(lines);
  }

  async function togglePaid(p) {
    if (p.paymentStatus === 'Paid') await markPurchaseUnpaid(p.id);
    else await markPurchasePaid(p.id);
    refresh();
  }

  const vendorName = vendors.find((v) => v.id === pVendorId)?.name;
  const grandTotal = pLines.reduce((s, l) => s + lineTotal(l), 0);
  const billAmountNum = Number(pBillAmount) || 0;
  const totalsMismatch = pBillAmount && Math.abs(billAmountNum - grandTotal) > 0.5;

  return (
    <div>
      <InventoryTabs />

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-truck-delivery" style={{ color: 'var(--blue)' }}></i> Material Input</div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>
          Enter the vendor and bill once -- it applies to every item you add below. New vendors are added under{' '}
          <Link href="/master-data/financial" style={{ color: 'var(--blue)' }}>Financial Masters &gt; Vendors</Link>.
        </div>
        {error && <div className="msg-err">{error}</div>}
        {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, marginBottom: 8 }}>
          <div>
            <label className="flbl">Vendor *</label>
            <select className="fi" value={pVendorId} onChange={(e) => setPVendorId(e.target.value)}>
              <option value="">-- Select vendor --</option>
              {vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
            </select>
          </div>
          <div>
            <label className="flbl">Bill date</label>
            <input className="fi" type="date" value={pBillDate} onChange={(e) => setPBillDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">Vendor bill number</label>
            <input className="fi" value={pBillNumber} onChange={(e) => setPBillNumber(e.target.value)} placeholder="Applies to every item below" />
          </div>
        </div>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8, marginBottom: 14 }}>
          <div>
            <label className="flbl">Total bill amount (optional)</label>
            <input className="fi" type="number" min="0" step="0.01" value={pBillAmount} onChange={(e) => setPBillAmount(e.target.value)} placeholder="Rs. -- to match against items below" />
          </div>
          <div style={{ gridColumn: 'span 2' }}>
            <label className="flbl">Notes (optional)</label>
            <input className="fi" value={pNotes} onChange={(e) => setPNotes(e.target.value)} />
          </div>
        </div>

        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 8 }}>
          Items on this bill {vendorName && <span style={{ textTransform: 'none', fontWeight: 400 }}>-- from {vendorName}</span>}
        </div>

        {/* Column headers -- fixed-width columns keep this from sprawling */}
        <div style={{ display: 'flex', gap: 6, marginBottom: 4, fontSize: 10, fontWeight: 600, color: 'var(--g500)', textTransform: 'uppercase', padding: '0 2px' }}>
          <div style={{ flex: '1 1 0', minWidth: 0 }}>Item</div>
          <div style={{ width: 88 }}>Batch</div>
          <div style={{ width: 118 }}>Expiry</div>
          <div style={{ width: 55 }}>Qty</div>
          <div style={{ width: 70 }}>Rate</div>
          <div style={{ width: 60 }}>Disc%</div>
          <div style={{ width: 74, textAlign: 'right' }}>Total</div>
          <div style={{ width: 24 }}></div>
        </div>

        {pLines.map((line) => (
          <div key={line.key} style={{ display: 'flex', gap: 6, marginBottom: 6, alignItems: 'center' }}>
            <select className="fi fi-sm" style={{ flex: '1 1 0', minWidth: 0 }} value={line.itemId} onChange={(e) => updateLine(line.key, 'itemId', e.target.value)}>
              <option value="">-- Item --</option>
              {itemPicker.map((i) => <option key={i.itemId} value={i.itemId}>{i.name}</option>)}
            </select>
            <input className="fi fi-sm" style={{ width: 88 }} placeholder="Batch" value={line.batchNumber} onChange={(e) => updateLine(line.key, 'batchNumber', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 118 }} type="date" value={line.expiryDate} onChange={(e) => updateLine(line.key, 'expiryDate', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 55 }} type="number" min="1" placeholder="0" value={line.qty} onChange={(e) => updateLine(line.key, 'qty', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 70 }} type="number" min="0" step="0.01" placeholder="0" value={line.rate} onChange={(e) => updateLine(line.key, 'rate', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 60 }} type="number" min="0" max="100" step="0.01" placeholder="0" value={line.discountPct} onChange={(e) => updateLine(line.key, 'discountPct', e.target.value)} />
            <div style={{ width: 74, textAlign: 'right', fontSize: 12, fontWeight: 600 }}>
              {lineTotal(line) > 0 ? `Rs.${lineTotal(line).toFixed(2)}` : '--'}
            </div>
            <button className="btn btn-sm" onClick={() => removeLine(line.key)} title="Remove line" style={{ width: 24, padding: '2px 4px', color: 'var(--red)' }}><i className="ti ti-x"></i></button>
          </div>
        ))}
        <button className="btn btn-sm" onClick={addLine} style={{ marginBottom: 14 }}><i className="ti ti-plus"></i> Add another item</button>

        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', borderTop: '1px solid var(--g100)', paddingTop: 12 }}>
          <div style={{ fontSize: 13 }}>
            <span style={{ color: 'var(--g500)' }}>Items total:</span>{' '}
            <span style={{ fontWeight: 700, fontSize: 15 }}>Rs.{grandTotal.toFixed(2)}</span>
            {totalsMismatch && (
              <span style={{ color: 'var(--red)', fontSize: 11, marginLeft: 10 }}>
                <i className="ti ti-alert-triangle"></i> Doesn&apos;t match bill amount (Rs.{billAmountNum.toFixed(2)})
              </span>
            )}
          </div>
          <button className="btn btn-primary" onClick={handleSavePurchase} disabled={saving} style={{ fontSize: 14, padding: '10px 24px', fontWeight: 700 }}>
            {saving ? 'Saving...' : 'Save Purchase & Add Stock'}
          </button>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt-2" style={{ color: 'var(--green)' }}></i> Purchase History</div>
        {loading ? (
          <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>Date</th><th>Vendor</th><th>Bill No.</th><th>Items</th><th>Amount</th><th>Payment</th><th></th></tr></thead>
            <tbody>
              {purchases.map((p) => (
                <tr key={p.id}>
                  <td>{new Date(p.billDate).toLocaleDateString('en-IN')}</td>
                  <td style={{ fontWeight: 600 }}>{p.vendorName}</td>
                  <td>{p.billNumber}</td>
                  <td>{p.itemCount} items, {p.totalQty} units</td>
                  <td>{p.billAmount ? `Rs.${p.billAmount.toLocaleString('en-IN')}` : '--'}</td>
                  <td>
                    <button className={`badge ${p.paymentStatus === 'Paid' ? 'b-green' : 'b-red'}`} style={{ border: 'none', cursor: 'pointer' }} onClick={() => togglePaid(p)}>
                      {p.paymentStatus}
                    </button>
                  </td>
                  <td><button className="btn btn-sm" onClick={() => openViewPurchase(p)}>View</button></td>
                </tr>
              ))}
              {purchases.length === 0 && (
                <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No purchases recorded yet.</td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      {viewPurchase && (
        <Modal onClose={() => setViewPurchase(null)} width={560}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-receipt-2"></i> Purchase Details</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
            {viewPurchase.vendorName} · Bill {viewPurchase.billNumber} · {new Date(viewPurchase.billDate).toLocaleDateString('en-IN')}
          </div>
          <table className="tbl" style={{ fontSize: 11 }}>
            <thead><tr><th>Item</th><th>Batch</th><th>Expiry</th><th>Qty</th><th>Rate</th><th>Disc%</th><th>Total</th></tr></thead>
            <tbody>
              {purchaseLines.map((l) => (
                <tr key={l.id}>
                  <td>{l.name}</td>
                  <td>{l.batchNumber || '--'}</td>
                  <td>{l.expiryDate ? new Date(l.expiryDate).toLocaleDateString('en-IN') : '--'}</td>
                  <td>{l.qty}</td>
                  <td>{l.rate ? `Rs.${l.rate}` : '--'}</td>
                  <td>{l.discountPct ? `${l.discountPct}%` : '--'}</td>
                  <td style={{ fontWeight: 600 }}>Rs.{l.lineTotal.toFixed(2)}</td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr style={{ fontWeight: 700 }}>
                <td colSpan={6} style={{ textAlign: 'right' }}>Total</td>
                <td>Rs.{purchaseLines.reduce((s, l) => s + l.lineTotal, 0).toFixed(2)}</td>
              </tr>
            </tfoot>
          </table>
          <div style={{ marginTop: 12, textAlign: 'right' }}>
            <button className="btn" onClick={() => setViewPurchase(null)}>Close</button>
          </div>
        </Modal>
      )}
    </div>
  );
}
