#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Inventory speedup + Dashboard reorder +"
echo "           Stock/History/Material-Input improvements"
echo "=================================================="
echo ""
echo "This script overwrites the files itself -- no manual"
echo "upload or copy-paste needed -- then commits and pushes."
echo ""

cat > "app/(main)/inventory/actions.js" << 'VEDA_EOF_MARKER_9f3a'
'use server';

import { createClient } from '@/lib/supabase-server';
import { revalidatePath } from 'next/cache';

// ── DASHBOARD ──
// Aggregation (on-hand sum, nearest expiry, expiring-soon flag) now
// happens in Postgres via the inventory_stock_summary view -- one
// round trip instead of fetching items, then lots, then reducing in
// JS. Sorting/status-labeling is cheap enough to stay client-side.
export async function getInventoryDashboard() {
  const supabase = await createClient();

  const { data: items } = await supabase.from('inventory_stock_summary').select('*');

  const rows = (items || []).map((item) => {
    const onHand = Number(item.on_hand);
    let stockStatus = 'OK';
    if (onHand <= 0) stockStatus = 'Out';
    else if (onHand <= Number(item.reorder_level)) stockStatus = 'Low';

    return {
      itemId: item.item_id,
      drugId: item.drug_id,
      name: `${item.brand || item.generic} ${item.strength || ''}`.trim(),
      generic: item.generic,
      form: item.form,
      unit: item.unit,
      onHand,
      reorderLevel: Number(item.reorder_level),
      nearestExpiry: item.nearest_expiry,
      expiringSoon: item.expiring_soon,
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

// ── DASHBOARD SUMMARY (shortages + recent bills + unpaid alert) ──
export async function getDashboardSummary() {
  const { rows, stats } = await getInventoryDashboard();
  const shortages = rows.filter((r) => r.stockStatus !== 'OK').slice(0, 10);

  const supabase = await createClient();
  const { data: recentRaw } = await supabase
    .from('inventory_purchases')
    .select('id, bill_number, bill_date, payment_status, bill_amount, inventory_vendors(name)')
    .order('created_at', { ascending: false })
    .limit(5);

  const { data: unpaidRaw } = await supabase
    .from('inventory_purchases')
    .select('id, bill_number, bill_date, bill_amount, inventory_vendors(name)')
    .eq('payment_status', 'Unpaid')
    .order('bill_date', { ascending: true });

  const unpaidPurchases = (unpaidRaw || []).map((p) => ({
    id: p.id, vendorName: p.inventory_vendors?.name || '--', billNumber: p.bill_number || '--',
    billDate: p.bill_date, billAmount: Number(p.bill_amount || 0),
  }));
  const unpaidTotal = unpaidPurchases.reduce((s, p) => s + p.billAmount, 0);

  return {
    stats,
    shortages,
    recentPurchases: (recentRaw || []).map((p) => ({
      id: p.id, vendorName: p.inventory_vendors?.name || '--', billNumber: p.bill_number || '--',
      billDate: p.bill_date, paymentStatus: p.payment_status, billAmount: Number(p.bill_amount || 0),
    })),
    unpaidPurchases,
    unpaidTotal,
    unpaidCount: unpaidPurchases.length,
  };
}

// Quick "check stock of any item" lookup used on the Dashboard.
export async function searchItemStock(query) {
  if (!query || query.trim().length < 2) return [];
  const { rows } = await getInventoryDashboard();
  const q = query.trim().toLowerCase();
  return rows.filter((r) => r.name.toLowerCase().includes(q) || (r.generic || '').toLowerCase().includes(q)).slice(0, 8);
}

export async function markPurchasePaid(purchaseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('inventory_purchases')
    .update({ payment_status: 'Paid', paid_date: new Date().toISOString().slice(0, 10) })
    .eq('id', purchaseId);
  if (error) return { error: error.message };
  revalidatePath('/inventory');
  return { success: true };
}
export async function markPurchaseUnpaid(purchaseId) {
  const supabase = await createClient();
  const { error } = await supabase.from('inventory_purchases').update({ payment_status: 'Unpaid', paid_date: null }).eq('id', purchaseId);
  if (error) return { error: error.message };
  revalidatePath('/inventory');
  return { success: true };
}

// ── VENDORS ──
// Vendors are now managed in Financial Masters (master-data/actions.js:
// getVendorsMaster/addVendorMaster/etc.) -- this just reads the same
// table for populating the vendor dropdown in Material Input.
export async function getVendors() {
  const supabase = await createClient();
  const { data } = await supabase.from('inventory_vendors').select('*').eq('status', 'Active').order('name');
  return data || [];
}

// ── PURCHASES ──
// One vendor + one bill number entered ONCE, covering many item lines.
// Vendor must already exist (added via Financial Masters) -- no more
// inline vendor creation here, to keep vendor master data clean.
export async function createPurchaseWithLines({ vendorId, billNumber, billDate, notes, billAmount, lines }) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();
  const receivedBy = userData?.user?.id || null;

  if (!vendorId) return { error: 'Select a vendor. New vendors are added under Financial Masters > Vendors.' };

  const validLines = (lines || []).filter((l) => l.itemId && Number(l.qty) > 0);
  if (validLines.length === 0) return { error: 'Add at least one item line with a quantity.' };

  const { data: purchase, error: pErr } = await supabase.rpc('create_purchase', {
    p_vendor_id: vendorId,
    p_bill_number: billNumber || null,
    p_bill_date: billDate || null,
    p_notes: notes || null,
    p_received_by: receivedBy,
    p_bill_amount: billAmount ? Number(billAmount) : null,
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
      p_discount_pct: Number(line.discountPct) || 0,
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
    paymentStatus: p.payment_status,
    billAmount: Number(p.bill_amount || 0),
  }));
}

export async function getPurchaseLines(purchaseId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('inventory_lots')
    .select('*, inventory_items(drug_id, master_drugs(brand, generic, strength))')
    .eq('purchase_id', purchaseId);
  return (data || []).map((l) => {
    const rate = Number(l.cost_price) || 0;
    const discountPct = Number(l.discount_pct) || 0;
    const qty = Number(l.qty_received) || 0;
    return {
      id: l.id,
      name: l.inventory_items?.master_drugs ? `${l.inventory_items.master_drugs.brand || l.inventory_items.master_drugs.generic} ${l.inventory_items.master_drugs.strength || ''}`.trim() : 'Unknown item',
      batchNumber: l.batch_number,
      expiryDate: l.expiry_date,
      qty,
      rate,
      discountPct,
      lineTotal: Math.round(qty * rate * (1 - discountPct / 100) * 100) / 100,
    };
  });
}

// ── MOVEMENT HISTORY (per item) ──
export async function getItemMovements(itemId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('inventory_movements')
    .select('*, inventory_lots(batch_number, inventory_vendors(name)), profiles(full_name)')
    .eq('item_id', itemId)
    .order('created_at', { ascending: false })
    .limit(50);
  return (data || []).map((m) => ({
    ...m,
    vendorName: m.inventory_lots?.inventory_vendors?.name || null,
  }));
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
import Link from 'next/link';
import InventoryTabs from './inventory-tabs';
import { getDashboardSummary, searchItemStock, markPurchasePaid } from './actions';

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

export default function InventoryDashboardPage() {
  const [data, setData] = useState(null);
  const [loading, setLoading] = useState(true);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [searching, setSearching] = useState(false);

  const refresh = useCallback(async () => {
    setData(await getDashboardSummary());
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  useEffect(() => {
    if (query.trim().length < 2) { setResults([]); return; }
    setSearching(true);
    const t = setTimeout(async () => {
      setResults(await searchItemStock(query));
      setSearching(false);
    }, 250);
    return () => clearTimeout(t);
  }, [query]);

  async function handleMarkPaid(id) {
    await markPurchasePaid(id);
    refresh();
  }

  if (loading || !data) {
    return <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>;
  }

  const { stats, shortages, recentPurchases, unpaidPurchases, unpaidTotal, unpaidCount } = data;

  return (
    <div>
      <InventoryTabs />

      {/* 1. KPI ROW */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Tracked items" value={stats.totalItems} sub="Drugs with stock tracking on" color="var(--blue)" />
        <KpiCard label="Low stock" value={stats.lowStock} sub="At or below reorder level" color="var(--amber)" />
        <KpiCard label="Out of stock" value={stats.outOfStock} sub="Zero or negative in stock" color="var(--red)" />
        <KpiCard label="Unpaid bills" value={unpaidCount} sub={`Rs.${unpaidTotal.toLocaleString('en-IN')} outstanding`} color="var(--purple)" />
      </div>

      {/* 2. NEW MATERIAL IN + STOCK LOOKUP, side by side */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16, marginBottom: 16 }}>
        <div className="card" style={{ display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
          <div className="card-title" style={{ marginBottom: 6 }}><i className="ti ti-truck-delivery" style={{ color: 'var(--blue)' }}></i> Received new stock from a vendor?</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 14 }}>Log the vendor bill once, add every item on it in one go.</div>
          <Link href="/inventory/material-input" style={{ textDecoration: 'none' }}>
            <button className="btn btn-primary" style={{ fontWeight: 700, fontSize: 14, padding: '10px 22px' }}>
              <i className="ti ti-plus"></i> New Material In
            </button>
          </Link>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Check Stock of Any Item</div>
          <input
            className="fi" placeholder="Start typing a drug name..." value={query}
            onChange={(e) => setQuery(e.target.value)}
          />
          {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>Searching...</div>}
          {results.length > 0 && (
            <div style={{ marginTop: 10 }}>
              {results.map((r) => (
                <div key={r.itemId} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                  <div>
                    <span style={{ fontWeight: 600 }}>{r.name}</span>
                    <span style={{ fontSize: 10, color: 'var(--g500)', marginLeft: 6 }}>{r.generic}</span>
                  </div>
                  <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                    <span style={{ fontWeight: 700 }}>{r.onHand} {r.unit}</span>
                    <span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* 3. ITEMS RUNNING SHORT */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Items Running Short
        </div>
        <table className="tbl">
          <thead><tr><th>Drug</th><th>In Stock</th><th>Reorder At</th><th>Status</th></tr></thead>
          <tbody>
            {shortages.map((r) => (
              <tr key={r.itemId}>
                <td style={{ fontWeight: 600 }}>{r.name}</td>
                <td style={{ fontWeight: 700, color: r.stockStatus === 'Out' ? 'var(--red)' : 'var(--amber)' }}>{r.onHand} {r.unit}</td>
                <td>{r.reorderLevel}</td>
                <td><span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span></td>
              </tr>
            ))}
            {shortages.length === 0 && (
              <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Nothing running short right now.</td></tr>
            )}
          </tbody>
        </table>
      </div>

      {/* 4. LAST 5 VENDOR BILLS + UNPAID VENDOR BILLS, equally split */}
      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-receipt-2" style={{ color: 'var(--green)' }}></i> Last 5 Vendor Bills
          </div>
          {recentPurchases.map((p) => (
            <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <div style={{ fontWeight: 600 }}>{p.vendorName}</div>
                <div style={{ color: 'var(--g500)', fontSize: 11 }}>{p.billNumber} · {new Date(p.billDate).toLocaleDateString('en-IN')}</div>
              </div>
              <span className={`badge ${p.paymentStatus === 'Paid' ? 'b-green' : 'b-red'}`}>{p.paymentStatus}</span>
            </div>
          ))}
          {recentPurchases.length === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>No purchases recorded yet.</div>
          )}
          <div style={{ marginTop: 10, textAlign: 'right' }}>
            <Link href="/inventory/material-input" style={{ fontSize: 12, color: 'var(--blue)' }}>View all purchases &rarr;</Link>
          </div>
        </div>

        <div className="card" style={{ borderLeft: unpaidCount > 0 ? '3px solid var(--red)' : 'none' }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Unpaid Vendor Bills
          </div>
          {unpaidCount > 0 && (
            <div style={{ fontSize: 12, color: 'var(--red)', fontWeight: 600, marginBottom: 8 }}>
              Rs.{unpaidTotal.toLocaleString('en-IN')} outstanding across {unpaidCount} bill{unpaidCount === 1 ? '' : 's'}
            </div>
          )}
          {unpaidPurchases.map((p) => (
            <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div>
                <div style={{ fontWeight: 600 }}>{p.vendorName}</div>
                <div style={{ color: 'var(--g500)', fontSize: 11 }}>{p.billNumber} · {new Date(p.billDate).toLocaleDateString('en-IN')}</div>
              </div>
              <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
                <span style={{ fontWeight: 700 }}>{p.billAmount ? `Rs.${p.billAmount.toLocaleString('en-IN')}` : '--'}</span>
                <button className="btn btn-sm btn-primary" onClick={() => handleMarkPaid(p.id)}>Mark Paid</button>
              </div>
            </div>
          ))}
          {unpaidCount === 0 && (
            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '8px 0' }}>All bills settled.</div>
          )}
        </div>
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/inventory/stock/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback } from 'react';
import InventoryTabs from '../inventory-tabs';
import {
  getInventoryDashboard, getUntrackedDrugs, createInventoryItem, updateInventoryItem,
  getItemMovements, writeOffLot,
} from '../actions';

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

export default function InventoryStockPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const [showAddItem, setShowAddItem] = useState(false);
  const [untrackedDrugs, setUntrackedDrugs] = useState([]);
  const [addDrugId, setAddDrugId] = useState('');
  const [addUnit, setAddUnit] = useState('Strip');
  const [addReorder, setAddReorder] = useState('10');

  const [editItem, setEditItem] = useState(null);
  const [editUnit, setEditUnit] = useState('');
  const [editReorder, setEditReorder] = useState('');

  const [historyItem, setHistoryItem] = useState(null);
  const [movements, setMovements] = useState([]);

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);

  const refresh = useCallback(async () => {
    const data = await getInventoryDashboard();
    setRows(data.rows);
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
      <InventoryTabs />

      <div className="card">
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
          <div className="card-title"><i className="ti ti-boxes" style={{ color: 'var(--blue)' }}></i> Pharmacy Stock</div>
          <button className="btn btn-primary" onClick={openAddItem}><i className="ti ti-plus"></i> Track New Drug</button>
        </div>

        {loading ? (
          <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading...</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>Drug</th><th>Form</th><th>Unit</th><th>In Stock</th><th>Reorder At</th><th>Nearest Expiry</th><th>Status</th><th></th></tr></thead>
            <tbody>
              {rows.map((r) => (
                <tr key={r.itemId}>
                  <td>
                    <div style={{ fontWeight: 600 }}>{r.name}</div>
                    <div style={{ fontSize: 10, color: 'var(--g500)' }}>{r.generic}</div>
                  </td>
                  <td>{r.form || '--'}</td>
                  <td>
                    <div>{r.unit}</div>
                    <button className="btn btn-sm" style={{ marginTop: 4, padding: '1px 8px', fontSize: 10 }} onClick={() => openEditItem(r)}>
                      <i className="ti ti-edit" style={{ fontSize: 11 }}></i> Edit
                    </button>
                  </td>
                  <td style={{ fontWeight: 700, color: r.stockStatus === 'Out' ? 'var(--red)' : r.stockStatus === 'Low' ? 'var(--amber)' : 'inherit' }}>{r.onHand}</td>
                  <td>{r.reorderLevel}</td>
                  <td style={{ color: r.expiringSoon ? 'var(--red)' : 'inherit', fontSize: 11 }}>
                    {r.nearestExpiry ? new Date(r.nearestExpiry).toLocaleDateString('en-IN') : '--'}
                    {r.expiringSoon && <span style={{ marginLeft: 4 }}>⚠</span>}
                  </td>
                  <td><span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span></td>
                  <td>
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

      {historyItem && (
        <Modal onClose={() => setHistoryItem(null)} width={520}>
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-history"></i> Movement History</div>
          <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 10 }}>{historyItem.name}</div>
          <table className="tbl" style={{ fontSize: 11 }}>
            <thead><tr><th>Date</th><th>Type</th><th>Qty</th><th>Batch</th><th>Vendor</th><th>By</th></tr></thead>
            <tbody>
              {movements.map((m) => (
                <tr key={m.id}>
                  <td>{new Date(m.created_at).toLocaleDateString('en-IN')}</td>
                  <td>{m.movement_type}{m.notes && <div style={{ fontSize: 9, color: 'var(--red)' }}>{m.notes}</div>}</td>
                  <td style={{ color: Number(m.qty_change) < 0 ? 'var(--red)' : 'var(--green)', fontWeight: 600 }}>{Number(m.qty_change) > 0 ? '+' : ''}{m.qty_change}</td>
                  <td>{m.inventory_lots?.batch_number || '--'}</td>
                  <td>{m.vendorName || '--'}</td>
                  <td>{m.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {movements.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No movements yet.</td></tr>
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

cat > "app/(main)/inventory/material-input/page.js" << 'VEDA_EOF_MARKER_9f3a'
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
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
ls -la "app/(main)/inventory/" "app/(main)/inventory/stock/" "app/(main)/inventory/material-input/"
echo ""

git add "app/(main)/inventory/actions.js" "app/(main)/inventory/page.js" "app/(main)/inventory/stock/page.js" "app/(main)/inventory/material-input/page.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Inventory: speed up dashboard (single DB-side view instead of 2 round trips + JS aggregation), add missing indexes, reorder Dashboard layout, add Edit-near-Unit, vendor in history, rate/discount/totals in Material Input"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "What changed for you:"
echo "  - Dashboard reordered: KPIs -> (New Material In + Stock Lookup side"
echo "    by side, theme-colored not the old gradient banner) -> Items"
echo "    Running Short -> (Last 5 Vendor Bills + Unpaid Vendor Bills,"
echo "    equally split side by side)"
echo "  - Stock tab: Edit now sits directly under the Unit value (that's"
echo "    what it actually edits); 'On Hand' relabeled 'In Stock' everywhere"
echo "  - Movement History: Vendor column added"
echo "  - Material Input: line items are much narrower (fixed-width"
echo "    columns), Rate + Discount% added per line, each line shows its"
echo "    own total, and a running Items Total is shown against your"
echo "    entered Bill Amount so mismatches are easy to catch"
echo "  - Speed: the Dashboard/Stock tab now does ONE database query"
echo "    (a view that aggregates stock server-side) instead of two"
echo "    round trips plus JS-side math; added indexes on every foreign"
echo "    key the module actually filters/joins on"
