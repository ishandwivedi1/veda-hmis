#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Inventory Management (Phase 1 - Pharmacy)"
echo "=================================================="
echo ""
echo "This script creates/overwrites the files itself -- no manual"
echo "upload or copy-paste needed -- then commits and pushes."
echo ""

mkdir -p "app/(main)/pharmacy/inventory"

cat > "app/(main)/pharmacy/inventory/actions.js" << 'VEDA_EOF_MARKER_9f3a'
'use server';

import { createClient } from '@/lib/supabase-server';
import { revalidatePath } from 'next/cache';

// ── DASHBOARD ──
// One row per drug that has an inventory item set up, with on-hand
// qty aggregated across its lots, nearest expiry, and a status read
// (OK / Low / Out) driven off reorder_level.
export async function getInventoryDashboard() {
  const supabase = await createClient();

  const { data: items } = await supabase
    .from('inventory_items')
    .select('*, master_drugs(id, code, brand, generic, strength, form, rate)')
    .eq('status', 'Active')
    .eq('item_type', 'Drug');

  const itemIds = (items || []).map((i) => i.id);
  let lotsByItem = {};
  if (itemIds.length > 0) {
    const { data: lots } = await supabase
      .from('inventory_lots')
      .select('*')
      .in('item_id', itemIds)
      .eq('status', 'Active');
    (lots || []).forEach((l) => {
      if (!lotsByItem[l.item_id]) lotsByItem[l.item_id] = [];
      lotsByItem[l.item_id].push(l);
    });
  }

  const sixtyDaysOut = new Date();
  sixtyDaysOut.setDate(sixtyDaysOut.getDate() + 60);

  const rows = (items || []).map((item) => {
    const lots = lotsByItem[item.id] || [];
    const onHand = lots.reduce((s, l) => s + Number(l.qty_on_hand), 0);
    const nearestExpiry = lots
      .filter((l) => l.expiry_date)
      .sort((a, b) => new Date(a.expiry_date) - new Date(b.expiry_date))[0]?.expiry_date || null;
    const expiringSoon = lots.some((l) => l.expiry_date && new Date(l.expiry_date) <= sixtyDaysOut && Number(l.qty_on_hand) > 0);

    let stockStatus = 'OK';
    if (onHand <= 0) stockStatus = 'Out';
    else if (onHand <= Number(item.reorder_level)) stockStatus = 'Low';

    return {
      itemId: item.id,
      drugId: item.master_drugs?.id,
      name: item.master_drugs ? `${item.master_drugs.brand || item.master_drugs.generic} ${item.master_drugs.strength || ''}`.trim() : 'Unknown drug',
      generic: item.master_drugs?.generic,
      form: item.master_drugs?.form,
      unit: item.unit,
      onHand,
      reorderLevel: Number(item.reorder_level),
      nearestExpiry,
      expiringSoon,
      stockStatus,
    };
  });

  rows.sort((a, b) => {
    const order = { Out: 0, Low: 1, OK: 2 };
    return order[a.stockStatus] - order[b.stockStatus];
  });

  const stats = {
    totalItems: rows.length,
    lowStock: rows.filter((r) => r.stockStatus === 'Low').length,
    outOfStock: rows.filter((r) => r.stockStatus === 'Out').length,
    expiringSoon: rows.filter((r) => r.expiringSoon).length,
  };

  return { rows, stats };
}

// ── ITEM SETUP ──
// Drugs that exist in the master list but don't have an inventory
// item yet -- so staff can "activate" tracking for them.
export async function getUntrackedDrugs() {
  const supabase = await createClient();
  const { data: drugs } = await supabase.from('master_drugs').select('id, code, brand, generic, strength, form').eq('status', 'Active').order('generic');
  const { data: items } = await supabase.from('inventory_items').select('drug_id').eq('item_type', 'Drug');
  const trackedIds = new Set((items || []).map((i) => i.drug_id));
  return (drugs || []).filter((d) => !trackedIds.has(d.id));
}

export async function createInventoryItem(drugId, unit, reorderLevel) {
  const supabase = await createClient();
  const { error } = await supabase.from('inventory_items').insert({
    item_type: 'Drug',
    drug_id: drugId,
    unit: unit || 'Unit',
    reorder_level: Number(reorderLevel) || 0,
  });
  if (error) return { error: error.message };
  revalidatePath('/pharmacy/inventory');
  return { success: true };
}

export async function updateReorderLevel(itemId, reorderLevel) {
  const supabase = await createClient();
  const { error } = await supabase.from('inventory_items').update({ reorder_level: Number(reorderLevel) || 0 }).eq('id', itemId);
  if (error) return { error: error.message };
  revalidatePath('/pharmacy/inventory');
  return { success: true };
}

// ── VENDORS ──
export async function getVendors() {
  const supabase = await createClient();
  const { data } = await supabase.from('inventory_vendors').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function addVendor(name, phone) {
  const supabase = await createClient();
  const { data, error } = await supabase.from('inventory_vendors').insert({ name: name.trim(), phone: phone?.trim() || null }).select().single();
  if (error) return { error: error.message };
  return { vendor: data };
}

// ── STOCK IN ──
export async function stockIn({ itemId, batchNumber, expiryDate, qty, costPrice, vendorId, vendorBillNumber }) {
  const supabase = await createClient();

  const { data: location } = await supabase.from('inventory_locations').select('id').eq('status', 'Active').order('created_at').limit(1).single();
  if (!location) return { error: 'No active stock location found.' };

  const { data: userData } = await supabase.auth.getUser();

  const { data, error } = await supabase.rpc('stock_in', {
    p_item_id: itemId,
    p_location_id: location.id,
    p_batch_number: batchNumber || null,
    p_expiry_date: expiryDate || null,
    p_qty: Number(qty),
    p_cost_price: Number(costPrice) || 0,
    p_vendor_id: vendorId || null,
    p_vendor_bill_number: vendorBillNumber || null,
    p_received_by: userData?.user?.id || null,
  });

  if (error) return { error: error.message };
  revalidatePath('/pharmacy/inventory');
  return { success: true, lot: data };
}

// ── MOVEMENT HISTORY (per item) ──
export async function getItemMovements(itemId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('inventory_movements')
    .select('*, inventory_lots(batch_number), profiles(full_name)')
    .eq('item_id', itemId)
    .order('created_at', { ascending: false })
    .limit(50);
  return data || [];
}

// ── MANUAL WRITE-OFF (expired / damaged) ──
export async function writeOffLot(lotId, movementType, notes) {
  const supabase = await createClient();
  const { data: lot } = await supabase.from('inventory_lots').select('*').eq('id', lotId).single();
  if (!lot) return { error: 'Lot not found.' };
  if (Number(lot.qty_on_hand) <= 0) return { error: 'This lot has no remaining stock to write off.' };

  const { data: userData } = await supabase.auth.getUser();
  const qty = Number(lot.qty_on_hand);

  const { error: updErr } = await supabase.from('inventory_lots').update({ qty_on_hand: 0, status: 'Written Off' }).eq('id', lotId);
  if (updErr) return { error: updErr.message };

  const { error: movErr } = await supabase.from('inventory_movements').insert({
    item_id: lot.item_id,
    lot_id: lot.id,
    location_id: lot.location_id,
    movement_type: movementType,
    qty_change: -qty,
    reference_type: 'manual',
    notes: notes || null,
    created_by: userData?.user?.id || null,
  });
  if (movErr) return { error: movErr.message };

  revalidatePath('/pharmacy/inventory');
  return { success: true };
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/pharmacy/inventory/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback } from 'react';
import PharmacyTabs from '../pharmacy-tabs';
import {
  getInventoryDashboard, getUntrackedDrugs, createInventoryItem, updateReorderLevel,
  getVendors, addVendor, stockIn, getItemMovements, writeOffLot,
} from './actions';

function KpiCard({ label, value, sub, color }) {
  return (
    <div className="card" style={{ borderLeft: `3px solid ${color}`, marginBottom: 0 }}>
      <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 500, marginBottom: 4 }}>{label}</div>
      <div style={{ fontSize: 20, fontWeight: 700 }}>{value}</div>
      <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{sub}</div>
    </div>
  );
}

const STATUS_BADGE = { OK: 'b-green', Low: 'b-amber', Out: 'b-red' };

function Modal({ onClose, width = 420, children }) {
  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 200 }} onClick={onClose}>
      <div className="card" style={{ width, marginBottom: 0, maxHeight: '85vh', overflowY: 'auto' }} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

export default function InventoryPage() {
  const [rows, setRows] = useState([]);
  const [stats, setStats] = useState({ totalItems: 0, lowStock: 0, outOfStock: 0, expiringSoon: 0 });
  const [loading, setLoading] = useState(true);

  const [showAddItem, setShowAddItem] = useState(false);
  const [untrackedDrugs, setUntrackedDrugs] = useState([]);
  const [addDrugId, setAddDrugId] = useState('');
  const [addUnit, setAddUnit] = useState('Strip');
  const [addReorder, setAddReorder] = useState('10');

  const [stockInItem, setStockInItem] = useState(null); // { itemId, name }
  const [vendors, setVendors] = useState([]);
  const [siBatch, setSiBatch] = useState('');
  const [siExpiry, setSiExpiry] = useState('');
  const [siQty, setSiQty] = useState('');
  const [siCost, setSiCost] = useState('');
  const [siVendorId, setSiVendorId] = useState('');
  const [siNewVendor, setSiNewVendor] = useState('');
  const [siBillNumber, setSiBillNumber] = useState('');

  const [historyItem, setHistoryItem] = useState(null);
  const [movements, setMovements] = useState([]);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const data = await getInventoryDashboard();
    setRows(data.rows);
    setStats(data.stats);
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  async function openAddItem() {
    setError('');
    const drugs = await getUntrackedDrugs();
    setUntrackedDrugs(drugs);
    setAddDrugId(drugs[0]?.id || '');
    setShowAddItem(true);
  }

  async function handleAddItem() {
    if (!addDrugId) return;
    setSaving(true);
    const res = await createInventoryItem(addDrugId, addUnit, addReorder);
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    setShowAddItem(false);
    refresh();
  }

  async function openStockIn(row) {
    setError('');
    setStockInItem(row);
    setSiBatch(''); setSiExpiry(''); setSiQty(''); setSiCost(''); setSiVendorId(''); setSiNewVendor(''); setSiBillNumber('');
    const v = await getVendors();
    setVendors(v);
  }

  async function handleStockIn() {
    if (!siQty || Number(siQty) <= 0) { setError('Enter a quantity greater than zero.'); return; }
    setSaving(true);
    let vendorId = siVendorId || null;
    if (!vendorId && siNewVendor.trim()) {
      const vRes = await addVendor(siNewVendor.trim());
      if (vRes.error) { setSaving(false); setError(vRes.error); return; }
      vendorId = vRes.vendor.id;
    }
    const res = await stockIn({
      itemId: stockInItem.itemId, batchNumber: siBatch, expiryDate: siExpiry || null,
      qty: siQty, costPrice: siCost, vendorId, vendorBillNumber: siBillNumber,
    });
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    setStockInItem(null);
    refresh();
  }

  async function openHistory(row) {
    setHistoryItem(row);
    const m = await getItemMovements(row.itemId);
    setMovements(m);
  }

  async function handleWriteOff(lotId, type) {
    const notes = window.prompt(`Reason for ${type.toLowerCase()}?`) || '';
    const res = await writeOffLot(lotId, type, notes);
    if (res.error) { alert(res.error); return; }
    refresh();
    if (historyItem) openHistory(historyItem);
  }

  return (
    <div>
      <div className="g4" style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Tracked items" value={stats.totalItems} sub="Drugs with stock tracking on" color="var(--blue)" />
        <KpiCard label="Low stock" value={stats.lowStock} sub="At or below reorder level" color="var(--amber)" />
        <KpiCard label="Out of stock" value={stats.outOfStock} sub="Zero or negative on hand" color="var(--red)" />
        <KpiCard label="Expiring soon" value={stats.expiringSoon} sub="Within 60 days" color="var(--purple)" />
      </div>

      <PharmacyTabs />

      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-boxes" style={{ color: 'var(--blue)' }}></i> Pharmacy Stock</div>
          <button className="btn btn-primary" onClick={openAddItem}><i className="ti ti-plus"></i> Track New Drug</button>
        </div>

        {loading ? (
          <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>Drug</th><th>Form</th><th>Unit</th><th>On Hand</th><th>Reorder At</th><th>Nearest Expiry</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.itemId}>
                  <td>
                    <div style={{ fontWeight: 600 }}>{r.name}</div>
                    <div style={{ fontSize: 10, color: 'var(--g500)' }}>{r.generic}</div>
                  </td>
                  <td>{r.form || '--'}</td>
                  <td>{r.unit}</td>
                  <td style={{ fontWeight: 700, color: r.stockStatus === 'Out' ? 'var(--red)' : r.stockStatus === 'Low' ? 'var(--amber)' : 'inherit' }}>{r.onHand}</td>
                  <td>{r.reorderLevel}</td>
                  <td style={{ color: r.expiringSoon ? 'var(--red)' : 'inherit', fontSize: 11 }}>
                    {r.nearestExpiry ? new Date(r.nearestExpiry).toLocaleDateString('en-IN') : '--'}
                    {r.expiringSoon && <span style={{ marginLeft: 4 }}>⚠</span>}
                  </td>
                  <td><span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span></td>
                  <td style={{ display: 'flex', gap: 6 }}>
                    <button className="btn btn-sm" onClick={() => openStockIn(r)}>Stock In</button>
                    <button className="btn btn-sm" onClick={() => openHistory(r)}>History</button>
                  </td>
                </tr>
              ))}
              {rows.length === 0 && (
                <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>
                  No drugs are being stock-tracked yet. Click &quot;Track New Drug&quot; to start.
                </td></tr>
              )}
            </tbody>
          </table>
        )}
      </div>

      {/* ADD ITEM MODAL */}
      {showAddItem && (
        <Modal onClose={() => setShowAddItem(false)} width={400}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Track New Drug</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Drug</label>
            <select className="fi" value={addDrugId} onChange={(e) => setAddDrugId(e.target.value)}>
              {untrackedDrugs.length === 0 && <option value="">-- All drugs already tracked --</option>}
              {untrackedDrugs.map((d) => (
                <option key={d.id} value={d.id}>{d.brand || d.generic} {d.strength} ({d.generic})</option>
              ))}
            </select>
          </div>
          <div style={{ display: 'flex', gap: 8, marginBottom: 12 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Stocking unit</label>
              <select className="fi" value={addUnit} onChange={(e) => setAddUnit(e.target.value)}>
                <option>Strip</option><option>Bottle</option><option>Vial</option><option>Box</option><option>Tube</option><option>Unit</option>
              </select>
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Reorder level</label>
              <input className="fi" type="number" min="0" value={addReorder} onChange={(e) => setAddReorder(e.target.value)} />
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setShowAddItem(false)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleAddItem} disabled={saving || !addDrugId}>{saving ? 'Saving...' : 'Start Tracking'}</button>
          </div>
        </Modal>
      )}

      {/* STOCK IN MODAL */}
      {stockInItem && (
        <Modal onClose={() => setStockInItem(null)} width={420}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-truck-delivery"></i> Stock In</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{stockInItem.name}</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}

          <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Batch number</label>
              <input className="fi" value={siBatch} onChange={(e) => setSiBatch(e.target.value)} placeholder="Optional" />
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Expiry date</label>
              <input className="fi" type="date" value={siExpiry} onChange={(e) => setSiExpiry(e.target.value)} />
            </div>
          </div>

          <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Quantity received *</label>
              <input className="fi" type="number" min="1" value={siQty} onChange={(e) => setSiQty(e.target.value)} />
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Cost price (per unit)</label>
              <input className="fi" type="number" min="0" step="0.01" value={siCost} onChange={(e) => setSiCost(e.target.value)} />
            </div>
          </div>

          <div style={{ marginBottom: 8 }}>
            <label className="flbl">Vendor</label>
            <select className="fi" value={siVendorId} onChange={(e) => setSiVendorId(e.target.value)}>
              <option value="">-- Select or type new below --</option>
              {vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
            </select>
          </div>
          {!siVendorId && (
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Or new vendor name</label>
              <input className="fi" value={siNewVendor} onChange={(e) => setSiNewVendor(e.target.value)} placeholder="e.g. Sunrise Pharma Distributors" />
            </div>
          )}
          <div style={{ marginBottom: 14 }}>
            <label className="flbl">Vendor bill number</label>
            <input className="fi" value={siBillNumber} onChange={(e) => setSiBillNumber(e.target.value)} placeholder="Optional" />
          </div>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setStockInItem(null)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleStockIn} disabled={saving}>{saving ? 'Saving...' : 'Add Stock'}</button>
          </div>
        </Modal>
      )}

      {/* HISTORY MODAL */}
      {historyItem && (
        <Modal onClose={() => setHistoryItem(null)} width={520}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-history"></i> Movement History</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{historyItem.name}</div>
          <table className="tbl" style={{ fontSize: 11 }}>
            <thead><tr><th>Date</th><th>Type</th><th>Qty</th><th>Batch</th><th>By</th></tr></thead>
            <tbody>
              {movements.map((m) => (
                <tr key={m.id}>
                  <td>{new Date(m.created_at).toLocaleDateString('en-IN')}</td>
                  <td>{m.movement_type}{m.notes && <div style={{ fontSize: 9, color: 'var(--red)' }}>{m.notes}</div>}</td>
                  <td style={{ color: Number(m.qty_change) < 0 ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>{Number(m.qty_change) > 0 ? '+' : ''}{m.qty_change}</td>
                  <td>{m.inventory_lots?.batch_number || '--'}</td>
                  <td>{m.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {movements.length === 0 && (
                <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No movements yet.</td></tr>
              )}
            </tbody>
          </table>
          <div style={{ marginTop: 12, textAlign: 'right' }}>
            <button className="btn" onClick={() => setHistoryItem(null)}>Close</button>
          </div>
        </Modal>
      )}
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/pharmacy/pharmacy-tabs.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/pharmacy', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/pharmacy/inventory', label: 'Inventory', icon: 'ti-boxes' },
  { href: '/pharmacy/history', label: 'History', icon: 'ti-history' },
];

export default function PharmacyTabs() {
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
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
ls -la "app/(main)/pharmacy/inventory/"
echo ""

git add "app/(main)/pharmacy/inventory/" "app/(main)/pharmacy/pharmacy-tabs.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Add Inventory Management Phase 1: pharmacy stock tracking with FEFO dispensing, stock-in, low-stock/expiry alerts, and movement history"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "After it deploys:"
echo "  1. Go to Pharmacy -> Inventory"
echo "  2. Click 'Track New Drug' for a few high-value/fast-moving drugs"
echo "  3. Use 'Stock In' to record what you currently have on the shelf"
echo "  4. Dispense a prescription for one of those drugs and confirm the on-hand count drops by 1"
