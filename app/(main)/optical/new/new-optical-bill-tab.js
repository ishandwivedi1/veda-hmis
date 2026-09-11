'use client';

import { useState, useEffect, useRef } from 'react';
import { useRouter } from 'next/navigation';
import {
  searchOpticalCustomers,
  createOpticalSale,
  getRecentOpticalItemNames,
} from '../actions';

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function NewOpticalBillTab() {
  const router = useRouter();
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selected, setSelected] = useState(null); // { type: 'patient'|'optical_customer', id, name, mobile, uhid? }
  const [useWalkIn, setUseWalkIn] = useState(false);
  const [walkInName, setWalkInName] = useState('');
  const [walkInMobile, setWalkInMobile] = useState('');

  const [lines, setLines] = useState([{ tempId: 1, description: '', qty: 1, unit_price: '' }]);
  const [discount, setDiscount] = useState('');
  const [notes, setNotes] = useState('');
  const nextTempId = useRef(2);

  const [recentItems, setRecentItems] = useState([]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [created, setCreated] = useState(null);

  useEffect(() => { getRecentOpticalItemNames().then(setRecentItems); }, []);

  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => setSearchResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  function pick(r) {
    setSelected(r);
    setSearchResults([]);
    setSearchQuery('');
    setUseWalkIn(false);
  }

  function clearCustomer() {
    setSelected(null);
    setUseWalkIn(false);
    setWalkInName('');
    setWalkInMobile('');
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
    setCreated(null);
    setSaving(true);
    try {
      const result = await createOpticalSale({
        patientId: selected?.type === 'patient' ? selected.id : null,
        opticalCustomerId: selected?.type === 'optical_customer' ? selected.id : null,
        customerName: useWalkIn ? walkInName : null,
        customerMobile: useWalkIn ? walkInMobile : null,
        items: lines.map((l) => ({ description: l.description, qty: l.qty, unit_price: l.unit_price })),
        discount,
        notes,
      });
      if (result.error) { setError(result.error); return; }
      setCreated(result.sale);
      clearCustomer();
      setLines([{ tempId: nextTempId.current++, description: '', qty: 1, unit_price: '' }]);
      setDiscount('');
      setNotes('');
      getRecentOpticalItemNames().then(setRecentItems);
    } catch (e) {
      setError('Something went wrong creating the bill -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-file-plus" style={{ color: 'var(--blue)' }}></i> New Optical Bill</div>

        {error && <div className="msg-err">{error}</div>}
        {created && (
          <div>
            <div style={{ background: 'var(--green-lt, #e3f5ec)', border: '1px solid var(--green, #157a4f)', borderRadius: 8, padding: '16px 18px', marginBottom: 16 }}>
              <div style={{ fontSize: 15, fontWeight: 700, color: 'var(--green, #157a4f)', marginBottom: 4 }}>
                <i className="ti ti-check"></i> Bill {created.sale_number} created
              </div>
              <div style={{ fontSize: 13, color: 'var(--g600)' }}>Total: {fmt(created.net)} -- nothing collected yet.</div>
              <button className="btn btn-primary" style={{ marginTop: 14, width: '100%' }} onClick={() => router.push(`/optical/collect?saleId=${created.id}`)}>
                <i className="ti ti-cash"></i> Collect Payment
              </button>
            </div>
            <span onClick={() => setCreated(null)} style={{ fontSize: 12, color: 'var(--g500)', textDecoration: 'underline', cursor: 'pointer' }}>
              + Create another bill
            </span>
          </div>
        )}

        {!created && (
          <>
            <label className="flbl">Customer</label>
            {!selected && !useWalkIn && (
              <div>
                <div style={{ display: 'flex', gap: 8 }}>
                  <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient or existing optical customer (name/UHID/mobile)..." />
                  <button className="btn" onClick={() => setUseWalkIn(true)}><i className="ti ti-user-plus"></i> New Walk-in</button>
                </div>
                {searchResults.length > 0 && (
                  <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                    {searchResults.map((r) => (
                      <div key={`${r.type}-${r.id}`} onClick={() => pick(r)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                        <strong>{r.name}</strong> -- {r.type === 'patient' ? r.uhid : 'Optical Customer'} -- {r.mobile || 'no mobile'}
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
            {selected && (
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 12px', border: '1px solid var(--g200)', borderRadius: 8 }}>
                <span><strong>{selected.name}</strong> -- {selected.type === 'patient' ? selected.uhid : 'Optical Customer'} -- {selected.mobile || 'no mobile'}</span>
                <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i> Change</button>
              </div>
            )}
            {useWalkIn && !selected && (
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
              <div style={{ flex: 2 }}>
                <label className="flbl">Notes (optional)</label>
                <input className="fi" value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="e.g. prescription reference, order details" />
              </div>
            </div>

            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '12px 0', marginTop: 16, borderTop: '1.5px solid var(--g200)' }}>
              <span style={{ fontSize: 14 }}>Gross: {fmt(gross)} {Number(discount) > 0 && <>-- Discount: {fmt(discount)}</>}</span>
              <span style={{ fontSize: 16, fontWeight: 700 }}>Bill Total: {fmt(net)}</span>
            </div>
            <button className="btn btn-primary" disabled={saving} onClick={handleSubmit}>
              <i className="ti ti-file-plus"></i> {saving ? 'Creating...' : 'Create Bill (no payment collected yet)'}
            </button>
          </>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-info-circle"></i> How this works</div>
        <ul style={{ fontSize: 12.5, color: 'var(--g500)', paddingLeft: 18, lineHeight: 1.7 }}>
          <li>Creating a bill does not collect any money -- it starts as <strong>Pending</strong>.</li>
          <li>Use <strong>Collect Payment</strong> to record full or partial payment against this bill.</li>
          <li>Use <strong>Advance</strong> to collect money from a customer before a bill even exists (e.g. a booking advance for made-to-order lenses) -- it can be applied against this or a future bill.</li>
          <li>Search results tagged "Optical Customer" are walk-ins who've bought here before, matched by mobile number.</li>
        </ul>
      </div>
    </div>
  );
}
