#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Inventory Module restructure"
echo "=================================================="
echo ""
echo "This script:"
echo "  1. Removes the old app/(main)/pharmacy/inventory/ folder"
echo "     (module is moving to its own top-level nav item)"
echo "  2. Creates app/(main)/inventory/ (standalone module)"
echo "  3. Updates pharmacy-tabs.js (Inventory tab removed)"
echo "  4. Updates AppShell.js (adds Inventory to sidebar nav)"
echo "  5. Commits and pushes"
echo ""

# Remove old nested location if it exists
rm -rf "app/(main)/pharmacy/inventory"

mkdir -p "app/(main)/inventory"

cat > "app/(main)/inventory/actions.js" << 'VEDA_EOF_MARKER_9f3a'
'use server';

import { createClient } from '@/lib/supabase-server';
import { revalidatePath } from 'next/cache';

// ── DASHBOARD ──
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

// ── ITEM SETUP / EDITING ──
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
  revalidatePath('/inventory');
  return { success: true };
}

// Now covers BOTH unit and reorder level -- previously only reorder
// level could be changed after tracking started.
export async function updateInventoryItem(itemId, unit, reorderLevel) {
  const supabase = await createClient();
  const { error } = await supabase.from('inventory_items').update({
    unit: unit || 'Unit',
    reorder_level: Number(reorderLevel) || 0,
  }).eq('id', itemId);
  if (error) return { error: error.message };
  revalidatePath('/inventory');
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

// ── PURCHASES (new) ──
// One vendor + one bill number entered ONCE, covering many item lines.
// Each line just becomes a stock_in call tagged with the purchase --
// the RPC pulls vendor/bill from the purchase itself, so there's no
// re-typing (and no risk of a typo splitting one bill across two
// different-looking vendor/bill combinations).
export async function createPurchaseWithLines({ vendorId, newVendorName, billNumber, billDate, notes, lines }) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const receivedBy = userData?.user?.id || null;

  let finalVendorId = vendorId;
  if (!finalVendorId && newVendorName?.trim()) {
    const vRes = await addVendor(newVendorName.trim());
    if (vRes.error) return { error: vRes.error };
    finalVendorId = vRes.vendor.id;
  }
  if (!finalVendorId) return { error: 'Select or enter a vendor.' };

  const validLines = (lines || []).filter((l) => l.itemId && Number(l.qty) > 0);
  if (validLines.length === 0) return { error: 'Add at least one item line with a quantity.' };

  const { data: purchase, error: pErr } = await supabase.rpc('create_purchase', {
    p_vendor_id: finalVendorId,
    p_bill_number: billNumber || null,
    p_bill_date: billDate || null,
    p_notes: notes || null,
    p_received_by: receivedBy,
  });
  if (pErr) return { error: pErr.message };

  const { data: location } = await supabase.from('inventory_locations').select('id').eq('status', 'Active').order('created_at').limit(1).single();
  if (!location) return { error: 'No active stock location found.' };

  const failures = [];
  for (const line of validLines) {
    const { error: lineErr } = await supabase.rpc('stock_in', {
      p_item_id: line.itemId,
      p_location_id: location.id,
      p_batch_number: line.batchNumber || null,
      p_expiry_date: line.expiryDate || null,
      p_qty: Number(line.qty),
      p_cost_price: Number(line.costPrice) || 0,
      p_vendor_id: null,
      p_vendor_bill_number: null,
      p_received_by: receivedBy,
      p_purchase_id: purchase.id,
    });
    if (lineErr) failures.push(`${line.itemName || line.itemId}: ${lineErr.message}`);
  }

  revalidatePath('/inventory');
  if (failures.length > 0) return { partial: true, error: `Some lines failed: ${failures.join('; ')}` };
  return { success: true, purchaseId: purchase.id };
}

export async function getRecentPurchases() {
  const supabase = await createClient();
  const { data: purchases } = await supabase
    .from('inventory_purchases')
    .select('*, inventory_vendors(name), profiles(full_name)')
    .order('created_at', { ascending: false })
    .limit(20);

  const purchaseIds = (purchases || []).map((p) => p.id);
  let lineCounts = {};
  if (purchaseIds.length > 0) {
    const { data: lots } = await supabase.from('inventory_lots').select('purchase_id, qty_received').in('purchase_id', purchaseIds);
    (lots || []).forEach((l) => {
      if (!lineCounts[l.purchase_id]) lineCounts[l.purchase_id] = { count: 0, totalQty: 0 };
      lineCounts[l.purchase_id].count += 1;
      lineCounts[l.purchase_id].totalQty += Number(l.qty_received);
    });
  }

  return (purchases || []).map((p) => ({
    id: p.id,
    vendorName: p.inventory_vendors?.name || '--',
    billNumber: p.bill_number || '--',
    billDate: p.bill_date,
    receivedBy: p.profiles?.full_name || '--',
    itemCount: lineCounts[p.id]?.count || 0,
    totalQty: lineCounts[p.id]?.totalQty || 0,
  }));
}

export async function getPurchaseLines(purchaseId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('inventory_lots')
    .select('*, inventory_items(drug_id, master_drugs(brand, generic, strength))')
    .eq('purchase_id', purchaseId);
  return (data || []).map((l) => ({
    id: l.id,
    name: l.inventory_items?.master_drugs ? `${l.inventory_items.master_drugs.brand || l.inventory_items.master_drugs.generic} ${l.inventory_items.master_drugs.strength || ''}`.trim() : 'Unknown item',
    batchNumber: l.batch_number,
    expiryDate: l.expiry_date,
    qty: l.qty_received,
    costPrice: l.cost_price,
  }));
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

  revalidatePath('/inventory');
  return { success: true };
}

// Full active-item list, used to populate item-line pickers in the
// New Purchase form (separate from getInventoryDashboard's aggregated
// stock view, since here we just need id/name pairs for a dropdown).
export async function getTrackedItemsForPicker() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('inventory_items')
    .select('id, unit, master_drugs(brand, generic, strength)')
    .eq('status', 'Active')
    .eq('item_type', 'Drug');
  return (data || []).map((i) => ({
    itemId: i.id,
    unit: i.unit,
    name: i.master_drugs ? `${i.master_drugs.brand || i.master_drugs.generic} ${i.master_drugs.strength || ''}`.trim() : 'Unknown drug',
  })).sort((a, b) => a.name.localeCompare(b.name));
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/inventory/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback } from 'react';
import {
  getInventoryDashboard, getUntrackedDrugs, createInventoryItem, updateInventoryItem,
  getVendors, addVendor, createPurchaseWithLines, getRecentPurchases, getPurchaseLines,
  getItemMovements, writeOffLot, getTrackedItemsForPicker,
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
const emptyLine = () => ({ key: Math.random().toString(36).slice(2), itemId: '', batchNumber: '', expiryDate: '', qty: '', costPrice: '' });

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
  const [purchases, setPurchases] = useState([]);

  const [showAddItem, setShowAddItem] = useState(false);
  const [untrackedDrugs, setUntrackedDrugs] = useState([]);
  const [addDrugId, setAddDrugId] = useState('');
  const [addUnit, setAddUnit] = useState('Strip');
  const [addReorder, setAddReorder] = useState('10');

  const [editItem, setEditItem] = useState(null); // { itemId, name, unit, reorderLevel }
  const [editUnit, setEditUnit] = useState('');
  const [editReorder, setEditReorder] = useState('');

  const [showPurchase, setShowPurchase] = useState(false);
  const [vendors, setVendors] = useState([]);
  const [itemPicker, setItemPicker] = useState([]);
  const [pVendorId, setPVendorId] = useState('');
  const [pNewVendor, setPNewVendor] = useState('');
  const [pBillNumber, setPBillNumber] = useState('');
  const [pBillDate, setPBillDate] = useState(() => new Date().toISOString().slice(0, 10));
  const [pNotes, setPNotes] = useState('');
  const [pLines, setPLines] = useState([emptyLine()]);

  const [viewPurchase, setViewPurchase] = useState(null);
  const [purchaseLines, setPurchaseLines] = useState([]);

  const [historyItem, setHistoryItem] = useState(null);
  const [movements, setMovements] = useState([]);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const [data, recent] = await Promise.all([getInventoryDashboard(), getRecentPurchases()]);
    setRows(data.rows);
    setStats(data.stats);
    setPurchases(recent);
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

  function openEditItem(row) {
    setError('');
    setEditItem(row);
    setEditUnit(row.unit);
    setEditReorder(String(row.reorderLevel));
  }

  async function handleEditItem() {
    setSaving(true);
    const res = await updateInventoryItem(editItem.itemId, editUnit, editReorder);
    setSaving(false);
    if (res.error) { setError(res.error); return; }
    setEditItem(null);
    refresh();
  }

  async function openPurchase() {
    setError('');
    const [v, items] = await Promise.all([getVendors(), getTrackedItemsForPicker()]);
    setVendors(v);
    setItemPicker(items);
    setPVendorId(''); setPNewVendor(''); setPBillNumber(''); setPNotes('');
    setPBillDate(new Date().toISOString().slice(0, 10));
    setPLines([emptyLine()]);
    setShowPurchase(true);
  }

  function updateLine(key, field, value) {
    setPLines((prev) => prev.map((l) => (l.key === key ? { ...l, [field]: value } : l)));
  }
  function addLine() { setPLines((prev) => [...prev, emptyLine()]); }
  function removeLine(key) { setPLines((prev) => (prev.length > 1 ? prev.filter((l) => l.key !== key) : prev)); }

  async function handleSavePurchase() {
    if (!pVendorId && !pNewVendor.trim()) { setError('Select or enter a vendor.'); return; }
    const validLines = pLines.filter((l) => l.itemId && Number(l.qty) > 0);
    if (validLines.length === 0) { setError('Add at least one item with a quantity.'); return; }

    setSaving(true);
    const res = await createPurchaseWithLines({
      vendorId: pVendorId || null,
      newVendorName: pVendorId ? null : pNewVendor,
      billNumber: pBillNumber, billDate: pBillDate, notes: pNotes,
      lines: validLines.map((l) => ({ ...l, itemName: itemPicker.find((p) => p.itemId === l.itemId)?.name })),
    });
    setSaving(false);
    if (res.error && !res.partial) { setError(res.error); return; }
    if (res.partial) { alert(res.error); }
    setShowPurchase(false);
    refresh();
  }

  async function openViewPurchase(p) {
    setViewPurchase(p);
    const lines = await getPurchaseLines(p.id);
    setPurchaseLines(lines);
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
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Tracked items" value={stats.totalItems} sub="Drugs with stock tracking on" color="var(--blue)" />
        <KpiCard label="Low stock" value={stats.lowStock} sub="At or below reorder level" color="var(--amber)" />
        <KpiCard label="Out of stock" value={stats.outOfStock} sub="Zero or negative on hand" color="var(--red)" />
        <KpiCard label="Expiring soon" value={stats.expiringSoon} sub="Within 60 days" color="var(--purple)" />
      </div>

      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-boxes" style={{ color: 'var(--blue)' }}></i> Pharmacy Stock</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <button className="btn" onClick={openAddItem}><i className="ti ti-plus"></i> Track New Drug</button>
            <button className="btn btn-primary" onClick={openPurchase}><i className="ti ti-truck-delivery"></i> New Purchase (Stock In)</button>
          </div>
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
                    <button className="btn btn-sm" onClick={() => openEditItem(r)}>Edit</button>
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

      <div className="card" style={{ marginTop: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-receipt-2" style={{ color: 'var(--green)' }}></i> Recent Purchases</div>
        <table className="tbl">
          <thead><tr><th>Date</th><th>Vendor</th><th>Bill No.</th><th>Items</th><th>Total Qty</th><th>Received By</th><th></th></tr></thead>
          <tbody>
            {purchases.map((p) => (
              <tr key={p.id}>
                <td>{new Date(p.billDate).toLocaleDateString('en-IN')}</td>
                <td>{p.vendorName}</td>
                <td>{p.billNumber}</td>
                <td>{p.itemCount}</td>
                <td>{p.totalQty}</td>
                <td>{p.receivedBy}</td>
                <td><button className="btn btn-sm" onClick={() => openViewPurchase(p)}>View</button></td>
              </tr>
            ))}
            {purchases.length === 0 && (
              <tr><td colSpan={7} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No purchases recorded yet.</td></tr>
            )}
          </tbody>
        </table>
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

      {/* EDIT ITEM MODAL */}
      {editItem && (
        <Modal onClose={() => setEditItem(null)} width={380}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-edit"></i> Edit Item</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{editItem.name}</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}
          <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Stocking unit</label>
              <select className="fi" value={editUnit} onChange={(e) => setEditUnit(e.target.value)}>
                <option>Strip</option><option>Bottle</option><option>Vial</option><option>Box</option><option>Tube</option><option>Unit</option>
              </select>
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Reorder level</label>
              <input className="fi" type="number" min="0" value={editReorder} onChange={(e) => setEditReorder(e.target.value)} />
            </div>
          </div>
          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setEditItem(null)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleEditItem} disabled={saving}>{saving ? 'Saving...' : 'Save Changes'}</button>
          </div>
        </Modal>
      )}

      {/* NEW PURCHASE MODAL (vendor + bill entered once, many item lines) */}
      {showPurchase && (
        <Modal onClose={() => setShowPurchase(false)} width={640}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-truck-delivery"></i> New Purchase</div>
          {error && <div className="msg-err" style={{ fontSize: 12 }}>{error}</div>}

          <div style={{ display: 'flex', gap: 8, marginBottom: 8 }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Vendor</label>
              <select className="fi" value={pVendorId} onChange={(e) => setPVendorId(e.target.value)}>
                <option value="">-- Select or type new below --</option>
                {vendors.map((v) => <option key={v.id} value={v.id}>{v.name}</option>)}
              </select>
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Bill date</label>
              <input className="fi" type="date" value={pBillDate} onChange={(e) => setPBillDate(e.target.value)} />
            </div>
          </div>
          {!pVendorId && (
            <div style={{ marginBottom: 8 }}>
              <label className="flbl">Or new vendor name</label>
              <input className="fi" value={pNewVendor} onChange={(e) => setPNewVendor(e.target.value)} placeholder="e.g. Sunrise Pharma Distributors" />
            </div>
          )}
          <div style={{ marginBottom: 14 }}>
            <label className="flbl">Vendor bill number</label>
            <input className="fi" value={pBillNumber} onChange={(e) => setPBillNumber(e.target.value)} placeholder="Applies to every item below" />
          </div>

          <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>Items on this bill</div>
          {pLines.map((line) => (
            <div key={line.key} style={{ display: 'flex', gap: 6, marginBottom: 6, alignItems: 'center' }}>
              <select className="fi fi-sm" style={{ flex: 2 }} value={line.itemId} onChange={(e) => updateLine(line.key, 'itemId', e.target.value)}>
                <option value="">-- Item --</option>
                {itemPicker.map((i) => <option key={i.itemId} value={i.itemId}>{i.name}</option>)}
              </select>
              <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Batch" value={line.batchNumber} onChange={(e) => updateLine(line.key, 'batchNumber', e.target.value)} />
              <input className="fi fi-sm" style={{ flex: 1 }} type="date" value={line.expiryDate} onChange={(e) => updateLine(line.key, 'expiryDate', e.target.value)} />
              <input className="fi fi-sm" style={{ width: 60 }} type="number" min="1" placeholder="Qty" value={line.qty} onChange={(e) => updateLine(line.key, 'qty', e.target.value)} />
              <input className="fi fi-sm" style={{ width: 70 }} type="number" min="0" step="0.01" placeholder="Cost" value={line.costPrice} onChange={(e) => updateLine(line.key, 'costPrice', e.target.value)} />
              <button className="btn btn-sm" onClick={() => removeLine(line.key)} title="Remove line" style={{ color: 'var(--red)' }}><i className="ti ti-x"></i></button>
            </div>
          ))}
          <button className="btn btn-sm" onClick={addLine} style={{ marginBottom: 14 }}><i className="ti ti-plus"></i> Add another item</button>

          <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
            <button className="btn" onClick={() => setShowPurchase(false)}>Cancel</button>
            <button className="btn btn-primary" onClick={handleSavePurchase} disabled={saving}>{saving ? 'Saving...' : 'Save Purchase & Add Stock'}</button>
          </div>
        </Modal>
      )}

      {/* VIEW PURCHASE MODAL */}
      {viewPurchase && (
        <Modal onClose={() => setViewPurchase(null)} width={480}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-receipt-2"></i> Purchase Details</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>
            {viewPurchase.vendorName} · Bill {viewPurchase.billNumber} · {new Date(viewPurchase.billDate).toLocaleDateString('en-IN')}
          </div>
          <table className="tbl" style={{ fontSize: 11 }}>
            <thead><tr><th>Item</th><th>Batch</th><th>Expiry</th><th>Qty</th><th>Cost</th></tr></thead>
            <tbody>
              {purchaseLines.map((l) => (
                <tr key={l.id}>
                  <td>{l.name}</td>
                  <td>{l.batchNumber || '--'}</td>
                  <td>{l.expiryDate ? new Date(l.expiryDate).toLocaleDateString('en-IN') : '--'}</td>
                  <td>{l.qty}</td>
                  <td>{l.costPrice ? `Rs.${l.costPrice}` : '--'}</td>
                </tr>
              ))}
            </tbody>
          </table>
          <div style={{ marginTop: 12, textAlign: 'right' }}>
            <button className="btn" onClick={() => setViewPurchase(null)}>Close</button>
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

cat > "app/components/AppShell.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState, useRef } from 'react';
import { createClient } from '@/lib/supabase-browser';
import { updateHeartbeat } from '@/app/(main)/users/actions';

// 30 minutes of no mouse/keyboard/touch activity -> automatic sign-out.
// Balances security (unattended shared terminals in a hospital) against
// not interrupting a doctor mid-consultation for a shorter window.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
const CHECK_INTERVAL_MS = 60 * 1000;

const NAV_ITEMS = [
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Front Office' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Finance' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Finance' },
  { href: '/cash-management', label: 'Cash Management', icon: 'ti-cash-register', section: 'Finance' },
  { href: '/payments/reports', label: 'Reports', icon: 'ti-report-money', section: 'Finance' },
  { href: '/payments/ledger', label: 'Ledger View', icon: 'ti-book', section: 'Patient Ledger' },
  { href: '/payments/credit-note', label: 'Credit Note', icon: 'ti-file-minus', section: 'Patient Ledger' },
  { href: '/payments/refund', label: 'Refund', icon: 'ti-rotate-clockwise', section: 'Patient Ledger' },
  { href: '/queue', label: 'Patient Flow', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/biometry', label: 'Biometry', icon: 'ti-ruler-measure', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/inventory', label: 'Inventory', icon: 'ti-boxes', section: 'Inventory' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/medical-fitness', label: 'Medical Fitness', icon: 'ti-heart-rate-monitor', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/counselling', label: 'Counselling', icon: 'ti-messages', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Schedule', icon: 'ti-calendar-event', section: 'Surgical' },
  { href: '/ot-intraop', label: 'Operation Theatre', icon: 'ti-building-hospital', section: 'Surgical' },
  { href: '/ot-recovery', label: 'Recovery & Discharge', icon: 'ti-bed', section: 'Surgical' },
  { href: '/ot-postop', label: 'Post Op', icon: 'ti-calendar-plus', section: 'Surgical' },
  { href: '/master-data/clinical', label: 'Clinical Masters', icon: 'ti-stethoscope', section: 'Administration' },
  { href: '/master-data/financial', label: 'Financial Masters', icon: 'ti-currency-rupee', section: 'Administration' },
  { href: '/print-templates', label: 'Print Templates', icon: 'ti-file-invoice', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration', adminOnly: true },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Patient Flow' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/medical-fitness/, title: 'Medical Fitness' },
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
  { match: /^\/cash-management/, title: 'Cash Management' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/inventory/, title: 'Inventory' },
  { match: /^\/counselling/, title: 'Counselling' },
  { match: /^\/ot-schedule/, title: 'OT Schedule' },
  { match: /^\/biometry/, title: 'Biometry & IOL Planning' },
  { match: /^\/ot-intraop/, title: 'Operation Theatre' },
  { match: /^\/ot-recovery/, title: 'Recovery & Discharge' },
  { match: /^\/ot-postop/, title: 'Post Op' },
  { match: /^\/master-data\/clinical/, title: 'Clinical Masters' },
  { match: /^\/master-data\/financial/, title: 'Financial Masters' },
  { match: /^\/print-templates/, title: 'Print Templates' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');
  const [mobileNavOpen, setMobileNavOpen] = useState(false);

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  // Every navigation should close the drawer -- without this, tapping
  // a link would leave it sitting open over the new page underneath.
  useEffect(() => { setMobileNavOpen(false); }, [pathname]);

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  // Idle auto-logout + "who's online" heartbeat. Checked on an interval,
  // AND immediately whenever the tab becomes visible again -- browsers
  // (Chrome especially) heavily throttle setInterval in backgrounded
  // tabs, sometimes to firing only once every several minutes or less,
  // so the interval alone can miss the 30-minute mark while the tab
  // sits unfocused. visibilitychange isn't subject to that throttling
  // and fires exactly when someone switches back to the tab, so it
  // catches what the interval missed. It doesn't count as "activity"
  // itself -- only real mouse/keyboard/touch input resets the clock.
  const lastActivityRef = useRef(Date.now());
  useEffect(() => {
    const markActive = () => { lastActivityRef.current = Date.now(); };
    const events = ['mousemove', 'keydown', 'mousedown', 'scroll', 'touchstart'];
    events.forEach((e) => window.addEventListener(e, markActive, { passive: true }));

    const checkIdle = async () => {
      const idleMs = Date.now() - lastActivityRef.current;
      if (idleMs >= IDLE_TIMEOUT_MS) {
        await supabase.auth.signOut();
        router.push('/login?reason=idle');
        router.refresh();
      } else {
        updateHeartbeat();
      }
    };

    const onVisible = () => { if (document.visibilityState === 'visible') checkIdle(); };
    document.addEventListener('visibilitychange', onVisible);

    updateHeartbeat(); // immediately on mount, not just on the first interval tick -- extra safety net beyond the login-page write

    const interval = setInterval(checkIdle, CHECK_INTERVAL_MS);

    return () => {
      events.forEach((e) => window.removeEventListener(e, markActive));
      document.removeEventListener('visibilitychange', onVisible);
      clearInterval(interval);
    };
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const visibleNavItems = NAV_ITEMS.filter((i) => !i.adminOnly || profile?.designation === 'Administrator');
  const sections = [...new Set(visibleNavItems.map((i) => i.section))];

  // Pick the single longest matching href across all items, so nested
  // routes (e.g. /payments and /payments/advance both being valid nav
  // targets) never highlight more than one item at once.
  const activeHref = visibleNavItems
    .map((i) => i.href)
    .filter((href) => pathname.startsWith(href))
    .sort((a, b) => b.length - a.length)[0];

  return (
    <div className="app-layout">
      {mobileNavOpen && <div className="mobile-nav-backdrop" onClick={() => setMobileNavOpen(false)}></div>}

      <div className={`sidebar ${mobileNavOpen ? 'mobile-open' : ''}`}>
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
            {visibleNavItems.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${item.href === activeHref ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                <span>{item.label}</span>
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
            <button
              className="mobile-menu-btn btn"
              style={{ padding: '7px 10px', flexShrink: 0 }}
              onClick={() => setMobileNavOpen(true)}
              aria-label="Open menu"
            >
              <i className="ti ti-menu-2"></i>
            </button>
            <div>
              <div className="top-title">{pageTitle}</div>
              <div className="top-sub">Veda Eye Hospital</div>
            </div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            <div className="topbar-userinfo" style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 11.5, color: 'var(--g500)', fontWeight: 500 }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            {profile && (
              <div style={{
                width: 34, height: 34, borderRadius: '50%', flexShrink: 0,
                background: 'linear-gradient(135deg, var(--blue), var(--blue-dk))',
                color: '#fff', display: 'flex', alignItems: 'center', justifyContent: 'center',
                fontFamily: 'var(--font-display-stack)', fontWeight: 700, fontSize: 13,
              }}>
                {profile.full_name?.charAt(0)?.toUpperCase() || '?'}
              </div>
            )}
            <div style={{ width: 1, height: 24, background: 'var(--g200)' }}></div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
ls -la "app/(main)/inventory/"
echo ""

git add -A "app/(main)/inventory/" "app/(main)/pharmacy/inventory/" "app/(main)/pharmacy/pharmacy-tabs.js" "app/components/AppShell.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Inventory: make it a standalone top-level module, allow editing unit after tracking starts, replace per-item vendor/bill entry with a proper Purchase flow (one vendor+bill, many item lines, auto-inherited)"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "What changed for you:"
echo "  - Inventory is now its own sidebar item (no longer under Pharmacy)"
echo "  - Edit button on each stock row now lets you change unit + reorder level any time"
echo "  - 'New Purchase (Stock In)' replaces the old per-item Stock In:"
echo "    enter vendor + bill number ONCE, then add as many item lines as are on that bill"
echo "  - A 'Recent Purchases' list at the bottom shows past bills with a View to see line items"
