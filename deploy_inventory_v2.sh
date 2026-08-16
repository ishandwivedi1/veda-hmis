#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Inventory redesign (Dashboard/Stock/Material Input)"
echo "           + Vendors moved into Financial Masters"
echo "=================================================="
echo ""
echo "This script creates/overwrites every file itself -- no manual"
echo "upload or copy-paste needed -- then commits and pushes."
echo ""

mkdir -p "app/(main)/inventory/stock"
mkdir -p "app/(main)/inventory/material-input"

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

      {/* BIG PRIMARY ACTION */}
      <div className="card" style={{ marginBottom: 16, padding: '18px 20px', display: 'flex', alignItems: 'center', justifyContent: 'space-between', background: 'linear-gradient(135deg, var(--blue), var(--teal))' }}>
        <div>
          <div style={{ fontSize: 16, fontWeight: 800, color: '#fff' }}>Received new stock from a vendor?</div>
          <div style={{ fontSize: 12, color: 'rgba(255,255,255,.85)', marginTop: 2 }}>Log the vendor bill once, add every item on it in one go.</div>
        </div>
        <Link href="/inventory/material-input" style={{ textDecoration: 'none' }}>
          <button className="btn" style={{ background: '#fff', color: 'var(--blue)', fontWeight: 800, fontSize: 15, padding: '12px 26px', border: 'none' }}>
            <i className="ti ti-plus" style={{ marginRight: 6 }}></i> New Material In
          </button>
        </Link>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginBottom: 16 }}>
        <KpiCard label="Tracked items" value={stats.totalItems} sub="Drugs with stock tracking on" color="var(--blue)" />
        <KpiCard label="Low stock" value={stats.lowStock} sub="At or below reorder level" color="var(--amber)" />
        <KpiCard label="Out of stock" value={stats.outOfStock} sub="Zero or negative on hand" color="var(--red)" />
        <KpiCard label="Unpaid bills" value={unpaidCount} sub={`Rs.${unpaidTotal.toLocaleString('en-IN')} outstanding`} color="var(--purple)" />
      </div>

      {/* STOCK LOOKUP */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Check Stock of Any Item</div>
        <input
          className="fi" placeholder="Start typing a drug name..." value={query}
          onChange={(e) => setQuery(e.target.value)} style={{ maxWidth: 400 }}
        />
        {searching && <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 6 }}>Searching...</div>}
        {results.length > 0 && (
          <div style={{ marginTop: 10 }}>
            {results.map((r) => (
              <div key={r.itemId} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '7px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                <div>
                  <span style={{ fontWeight: 600 }}>{r.name}</span>
                  <span style={{ fontSize: 11, color: 'var(--g500)', marginLeft: 8 }}>{r.generic}</span>
                </div>
                <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
                  <span style={{ fontWeight: 700 }}>{r.onHand} {r.unit}</span>
                  <span className={`badge ${STATUS_BADGE[r.stockStatus]}`}>{r.stockStatus}</span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* UNPAID BILLS ALERT */}
      {unpaidCount > 0 && (
        <div className="card" style={{ marginBottom: 16, borderLeft: '3px solid var(--red)' }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-triangle" style={{ color: 'var(--red)' }}></i> Unpaid Vendor Bills -- Rs.{unpaidTotal.toLocaleString('en-IN')} outstanding
          </div>
          <table className="tbl">
            <thead><tr><th>Vendor</th><th>Bill No.</th><th>Bill Date</th><th>Amount</th><th></th></tr></thead>
            <tbody>
              {unpaidPurchases.map((p) => (
                <tr key={p.id}>
                  <td style={{ fontWeight: 600 }}>{p.vendorName}</td>
                  <td>{p.billNumber}</td>
                  <td>{new Date(p.billDate).toLocaleDateString('en-IN')}</td>
                  <td>{p.billAmount ? `Rs.${p.billAmount.toLocaleString('en-IN')}` : <span style={{ color: 'var(--g400)' }}>Not entered</span>}</td>
                  <td><button className="btn btn-sm btn-primary" onClick={() => handleMarkPaid(p.id)}>Mark Paid</button></td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}

      <div style={{ display: 'grid', gridTemplateColumns: '1.3fr 1fr', gap: 16 }}>
        {/* ITEMS RUNNING SHORT */}
        <div className="card">
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-alert-circle" style={{ color: 'var(--amber)' }}></i> Items Running Short
          </div>
          <table className="tbl">
            <thead><tr><th>Drug</th><th>On Hand</th><th>Reorder At</th><th>Status</th></tr></thead>
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

        {/* LAST 5 VENDOR BILLS */}
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
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/inventory/inventory-tabs.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';

const TABS = [
  { href: '/inventory', label: 'Dashboard', icon: 'ti-layout-dashboard' },
  { href: '/inventory/stock', label: 'Stock', icon: 'ti-boxes' },
  { href: '/inventory/material-input', label: 'Material Input', icon: 'ti-truck-delivery' },
];

export default function InventoryTabs() {
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

cat > "app/(main)/inventory/material-input/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect } from 'react';
import Link from 'next/link';
import InventoryTabs from '../inventory-tabs';
import {
  getVendors, createPurchaseWithLines, getRecentPurchases, getPurchaseLines,
  getTrackedItemsForPicker, markPurchasePaid, markPurchaseUnpaid,
} from '../actions';

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
      lines: validLines.map((l) => ({ ...l, itemName: itemPicker.find((p) => p.itemId === l.itemId)?.name })),
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
            <input className="fi" type="number" min="0" step="0.01" value={pBillAmount} onChange={(e) => setPBillAmount(e.target.value)} placeholder="Rs." />
          </div>
          <div style={{ gridColumn: 'span 2' }}>
            <label className="flbl">Notes (optional)</label>
            <input className="fi" value={pNotes} onChange={(e) => setPNotes(e.target.value)} />
          </div>
        </div>

        <div style={{ fontSize: 11, fontWeight: 600, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>
          Items on this bill {vendorName && <span style={{ textTransform: 'none', fontWeight: 400 }}>-- from {vendorName}</span>}
        </div>
        {pLines.map((line) => (
          <div key={line.key} style={{ display: 'flex', gap: 6, marginBottom: 6, alignItems: 'center' }}>
            <select className="fi fi-sm" style={{ flex: 2 }} value={line.itemId} onChange={(e) => updateLine(line.key, 'itemId', e.target.value)}>
              <option value="">-- Item --</option>
              {itemPicker.map((i) => <option key={i.itemId} value={i.itemId}>{i.name}</option>)}
            </select>
            <input className="fi fi-sm" style={{ flex: 1 }} placeholder="Batch" value={line.batchNumber} onChange={(e) => updateLine(line.key, 'batchNumber', e.target.value)} />
            <input className="fi fi-sm" style={{ flex: 1 }} type="date" value={line.expiryDate} onChange={(e) => updateLine(line.key, 'expiryDate', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 70 }} type="number" min="1" placeholder="Qty" value={line.qty} onChange={(e) => updateLine(line.key, 'qty', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 80 }} type="number" min="0" step="0.01" placeholder="Cost" value={line.costPrice} onChange={(e) => updateLine(line.key, 'costPrice', e.target.value)} />
            <button className="btn btn-sm" onClick={() => removeLine(line.key)} title="Remove line" style={{ color: 'var(--red)' }}><i className="ti ti-x"></i></button>
          </div>
        ))}
        <button className="btn btn-sm" onClick={addLine} style={{ marginBottom: 16 }}><i className="ti ti-plus"></i> Add another item</button>

        <div style={{ display: 'flex', justifyContent: 'flex-end' }}>
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
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/master-data/actions.js" << 'VEDA_EOF_MARKER_9f3a'
'use server';

import { createClient } from '@/lib/supabase-server';

async function logMasterAudit(supabase, masterTable, recordCode, action, detail) {
  const { data: userData } = await supabase.auth.getUser();
  await supabase.from('master_data_audit_log').insert({
    master_table: masterTable, record_code: recordCode, action, detail, changed_by: userData?.user?.id || null,
  });
}

export async function getMasterAuditLog(masterTable) {
  const supabase = await createClient();
  let q = supabase.from('master_data_audit_log').select('*, profiles(full_name)').order('changed_at', { ascending: false }).limit(30);
  if (masterTable) q = q.eq('master_table', masterTable);
  const { data } = await q;
  return data || [];
}

// Generic toggle works the same way across all master tables -- every
// one of them uses the same status column and Active/Inactive values.
export async function toggleStatus(table, id, currentStatus, code) {
  const supabase = await createClient();
  const newStatus = currentStatus === 'Active' ? 'Inactive' : 'Active';
  const { error } = await supabase.from(table).update({ status: newStatus }).eq('id', id);
  if (error) return { error: error.message };
  await logMasterAudit(supabase, table, code || id, newStatus === 'Active' ? 'Reactivate' : 'Deactivate', `Status changed to ${newStatus}`);
  return { success: true };
}

// ── SHARED HELPERS: auto-code + consistent text formatting ──
// Applied everywhere a person types a free-text name/label into a
// master, so two staff members never accidentally create "iol",
// "IOL", and "Iol" as three different-looking entries, and nobody has
// to invent a unique code by hand.

// Title-cases each word, collapses repeated whitespace, trims ends.
// Deliberately simple/predictable rather than clever -- staff can
// still see exactly what they typed, just consistently capitalized.
function normalizeName(s) {
  return (s || '')
    .trim()
    .replace(/\s+/g, ' ')
    .replace(/\w\S*/g, (w) => w.charAt(0).toUpperCase() + w.slice(1).toLowerCase());
}

// Derives a short prefix from a category (or a fixed fallback for
// tables with no category concept) -- multi-word categories become an
// initialism ("Minor Procedure" -> MP, "chief_complaint" -> CC), single
// words are used whole if short enough or trimmed to 3 letters
// otherwise ("Cataract" -> CAT, "EDOF" -> EDOF).
function codePrefix(categoryOrFallback) {
  const words = (categoryOrFallback || '').trim().split(/[\s_]+/).filter(Boolean);
  if (words.length === 0) return 'GEN';
  if (words.length === 1) return words[0].length <= 4 ? words[0].toUpperCase() : words[0].slice(0, 3).toUpperCase();
  return words.map((w) => w[0]).join('').toUpperCase().slice(0, 4);
}

// Short alphanumeric codes, auto-generated and linked to category where
// one exists (e.g. Surgery category "Cataract" -> CAT01, CAT02...;
// Procedure category "Minor Procedure" -> MP01, MP02...; History
// Option category "chief_complaint" -> CC01, CC02...). For Clinical
// Master tables with no category concept (IOP Methods, Clinical
// Observations), pass a fixed short fallback prefix instead, so every
// code in Clinical Masters follows the same short PREFIX+NN pattern
// rather than some being long name-derived slugs like the old scheme
// produced.
async function generateCategoryCode(supabase, table, categoryOrFallback) {
  const prefix = codePrefix(categoryOrFallback);
  const { data } = await supabase.from(table).select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(2, '0')}`;
}

// Delete with a friendly message instead of a raw Postgres error when
// the record is still referenced elsewhere (e.g. a service used on a
// past invoice) -- staff should mark it Inactive in that case instead.
async function deleteMasterRecord(supabase, table, id, code) {
  const { error } = await supabase.from(table).delete().eq('id', id);
  if (error) {
    if (error.code === '23503') return { error: 'Cannot delete -- this item is already in use elsewhere (e.g. on a past invoice or record). Set it to Inactive instead.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, table, code || id, 'Delete', 'Record deleted');
  return { success: true };
}

// ── EXPENSE CATEGORIES (Financial Master -- used in Cash Management > Petty Cash) ──
export async function getExpenseCategories() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_expense_categories').select('*').order('name');
  return data || [];
}
export async function addExpenseCategory(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_expense_categories', 'EXP');
  const { error } = await supabase.from('master_expense_categories').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_expense_categories', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateExpenseCategory(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_expense_categories').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_expense_categories', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}

// ── IOP METHODS (Clinical Master -- used in Optometry Assessment) ──
export async function getIopMethods() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iop_methods').select('*').order('name');
  return data || [];
}
export async function addIopMethod(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_iop_methods', 'IOP');
  const { error } = await supabase.from('master_iop_methods').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iop_methods', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateIopMethod(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_iop_methods').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_iop_methods', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteIopMethod(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iop_methods', id, code);
}

// ── DRUG TYPES (Financial Master -- Pharmacy tab, drives what dosage
// phrasing options the doctor's Prescription picker shows) ──
export async function getDrugTypes() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drug_types').select('*').order('name');
  return data || [];
}
export async function addDrugType(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_drug_types', 'TYP');
  const { error } = await supabase.from('master_drug_types').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drug_types', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDrugType(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_drug_types').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_drug_types', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteDrugType(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drug_types', id, code);
}

// Dosage phrasing options nested under a drug type -- e.g. "Apply thin
// layer" under Eye Ointment, "1 drop" under Eye Drop. Simple list items
// (like Package line items), not full master records, so no audit code.
export async function getDosageOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_dosage_options').select('*').eq('status', 'Active').order('display_order');
  return data || [];
}
export async function addDosageOption(drugTypeId, dosageText) {
  const supabase = await createClient();
  const text = (dosageText || '').trim();
  if (!text) return { error: 'Dosage text is required.' };
  const { data: existing } = await supabase.from('master_dosage_options').select('display_order').eq('drug_type_id', drugTypeId).order('display_order', { ascending: false }).limit(1);
  const nextOrder = (existing?.[0]?.display_order ?? 0) + 1;
  const { error } = await supabase.from('master_dosage_options').insert({ drug_type_id: drugTypeId, dosage_text: text, display_order: nextOrder });
  if (error) return { error: error.message };
  return { success: true };
}
export async function removeDosageOption(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('master_dosage_options').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── SURGICAL CONSUMABLES (Clinical Master -- Patient Check-In dropdown
// and Intraoperative Management quick-pick, both in OT Intraop) ──
export async function getSurgicalConsumablesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgical_consumables').select('*').order('name');
  return data || [];
}
export async function addSurgicalConsumable(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_surgical_consumables', 'CONS');
  const { error } = await supabase.from('master_surgical_consumables').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgical_consumables', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgicalConsumable(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_surgical_consumables').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_surgical_consumables', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteSurgicalConsumable(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgical_consumables', id, code);
}

// ── CLINICAL OBSERVATIONS (Clinical Master -- quick-pick chips in
// Optometry Assessment's Clinical Observations section) ──
export async function getClinicalObservations() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_clinical_observations').select('*').order('name');
  return data || [];
}
export async function addClinicalObservation(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_clinical_observations', 'OBS');
  const { error } = await supabase.from('master_clinical_observations').insert({ code, name, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_clinical_observations', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateClinicalObservation(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_clinical_observations').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_clinical_observations', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteClinicalObservation(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_clinical_observations', id, code);
}

// ── HISTORY OPTIONS (Clinical Master -- chip options in the doctor's
// Consultation History tab: Chief Complaint, Ocular/Medical/Family
// History). Four categories in one table; code is unique per category
// (not globally) since e.g. "Glaucoma" is a legitimate chip in both
// Ocular History and Family History. ──
export async function getHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_history_options').select('*').order('category').order('name');
  return data || [];
}
export async function addHistoryOption(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'master_history_options', values.category);
  const { error } = await supabase.from('master_history_options').insert({ code, name, category: values.category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_history_options', code, 'Create', `${name} (${values.category}) created`);
  return { success: true };
}
export async function updateHistoryOption(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_history_options').update({ name }).eq('id', id);
  if (error) return { error: error.message };
  if (oldValues.name !== name) await logMasterAudit(supabase, 'master_history_options', oldValues.code, 'Edit', `Name ${oldValues.name} -> ${name}`);
  return { success: true };
}
export async function deleteHistoryOption(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_history_options', id, code);
}

// Active-only, grouped by category -- what the doctor's Consultation
// History tab actually renders as selectable chips
// (app/(main)/consultation/[id]/history-tab.js).
export async function getActiveHistoryOptions() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_history_options')
    .select('category, name')
    .eq('status', 'Active')
    .order('name');

  const grouped = { chief_complaint: [], ocular_history: [], medical_history: [], family_history: [], drug_history: [], allergy: [] };
  (data || []).forEach((row) => {
    if (grouped[row.category]) grouped[row.category].push(row.name);
  });
  return grouped;
}

// ── DOCTORS (Clinical Master) ──
// Deliberately NOT a separate table -- doctors are profiles (same
// source User Management and Appointments' doctor dropdown already
// use). This is a management view onto that same data, filtered to
// doctor-type designations, showing both Active and Inactive (unlike
// the dropdown-facing getDoctors() in appointments/actions.js, which
// only wants Active ones). New doctor accounts are still created in
// User Management (needs a real login, service-role auth), and name
// changes belong there too (it's tied to their login identity) -- so
// this tab intentionally offers status management only, no Edit/Delete.
export async function getDoctorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('profiles')
    .select('id, code, full_name, designation, status')
    .eq('designation', 'Doctor')
    .order('full_name');
  const doctors = data || [];

  // Self-heal: any doctor profile created via User Management since this
  // was added (or missed by the one-time backfill) won't have a code yet.
  // Assign the next one in the same uniform DOC01, DOC02... sequence used
  // everywhere else in Clinical Masters, rather than anything category- or
  // designation-specific.
  const missing = doctors.filter((d) => !d.code);
  for (const d of missing) {
    // Re-queried fresh each time so each new code accounts for the one
    // just assigned above it.
    const code = await generateCategoryCode(supabase, 'profiles', 'DOC');
    const { error } = await supabase.from('profiles').update({ code }).eq('id', d.id);
    if (!error) d.code = code;
  }
  return doctors;
}

// ── SERVICES ──
// Services (Consultation, Investigation, Surgery, Pharmacy departments
// in master_services) follow their own long-established CON001, INV001...
// pattern -- 3-digit, scoped per department -- rather than the 2-digit
// generateCategoryCode scheme above. Kept separate so it stays exactly
// consistent with the codes already seeded in the database.
async function generateServiceCode(supabase, dept) {
  const prefix = (dept || 'SVC').slice(0, 3).toUpperCase();
  const { data } = await supabase.from('master_services').select('code').ilike('code', `${prefix}%`);
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(new RegExp(`^${prefix}(\\d+)$`));
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `${prefix}${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function getServices() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').order('name');
  return data || [];
}
export async function addService(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateServiceCode(supabase, values.dept);
  const { error } = await supabase.from('master_services').insert({
    code, name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
    investigation_package: values.investigationPackage?.trim() || null,
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_services', code, 'Create', `${name} created -- Rs.${values.rate}, ${values.gstPct || 0}% GST`);
  return { success: true };
}
export async function updateService(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('master_services').update({
    name, dept: values.dept, rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
    investigation_package: values.investigationPackage?.trim() || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  if (oldValues.dept !== values.dept) changes.push(`Dept ${oldValues.dept} -> ${values.dept}`);
  if ((oldValues.investigation_package || '') !== (values.investigationPackage || '')) changes.push(`Package ${oldValues.investigation_package || '--'} -> ${values.investigationPackage || '--'}`);
  await logMasterAudit(supabase, 'master_services', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteService(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_services', id, code);
}

// ── PACKAGES ──
export async function getPackages() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_packages').select('*, master_surgeries(name)').order('name');
  return data || [];
}
export async function addPackage(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { data: code, error: codeError } = await supabase.rpc('next_package_code');
  if (codeError) return { error: codeError.message };
  const { data: newPackage, error } = await supabase.from('master_packages').insert({
    code, name, price: 0, includes: values.includes ? normalizeName(values.includes) : null,
    surgery_id: values.surgeryId || null, status: 'Active',
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).select().single();
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_packages', code, 'Create', `${name} created`);
  return { success: true, package: newPackage };
}
export async function updatePackage(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const includes = values.includes ? normalizeName(values.includes) : values.includes;
  const { error } = await supabase.from('master_packages').update({
    name, includes, surgery_id: values.surgeryId || null,
    iol_category: values.iolCategory || null, origin: values.origin || null,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.includes !== includes) changes.push('Includes updated');
  if ((oldValues.iol_category || '') !== (values.iolCategory || '')) changes.push(`IOL type ${oldValues.iol_category || '--'} -> ${values.iolCategory || '--'}`);
  if ((oldValues.origin || '') !== (values.origin || '')) changes.push(`Origin ${oldValues.origin || '--'} -> ${values.origin || '--'}`);
  await logMasterAudit(supabase, 'master_packages', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deletePackage(id, code) {
  const supabase = await createClient();
  // Constituents belong to the package -- clear them first so the
  // package row itself isn't blocked by its own line items.
  await supabase.from('package_line_items').delete().eq('package_id', id);
  return deleteMasterRecord(supabase, 'master_packages', id, code);
}

// ── PACKAGE CONSTITUENTS (breakup for billing / insurance requests) ──
export async function getPackageLineItems(packageId) {
  const supabase = await createClient();
  const { data } = await supabase.from('package_line_items').select('*').eq('package_id', packageId).order('sort_order');
  return data || [];
}
export async function addPackageLineItem(packageId, description, amount) {
  const supabase = await createClient();
  const { data: existing } = await supabase.from('package_line_items').select('sort_order').eq('package_id', packageId).order('sort_order', { ascending: false }).limit(1).maybeSingle();
  const { error } = await supabase.from('package_line_items').insert({
    package_id: packageId, description: normalizeName(description), amount: parseFloat(amount) || 0, sort_order: (existing?.sort_order || 0) + 1,
  });
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', `Constituent added: ${normalizeName(description)} -- Rs.${amount}`);
  return { success: true };
}
export async function removePackageLineItem(id, packageId) {
  const supabase = await createClient();
  const { error } = await supabase.from('package_line_items').delete().eq('id', id);
  if (error) return { error: error.message };
  await supabase.rpc('recompute_package_price', { p_package_id: packageId });
  const { data: pkg } = await supabase.from('master_packages').select('code').eq('id', packageId).single();
  await logMasterAudit(supabase, 'master_packages', pkg?.code || packageId, 'Edit', 'Constituent removed');
  return { success: true };
}

// ── PROCEDURES (Clinical Master -- minor, in-clinic procedures a doctor
// performs directly, e.g. "Syringing", "FB Removal". Distinct from
// SURGERIES below, which are OT-based and back billing Packages.) ──
export async function getProcedures() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_procedures').select('*').order('name');
  return data || [];
}
export async function addProcedure(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_procedures', category);
  const { error } = await supabase.from('master_procedures').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_procedures', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateProcedure(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_procedures').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_procedures', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteProcedure(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_procedures', id, code);
}

// ── SURGERIES (Clinical Master -- the OT-based surgery a doctor advises,
// e.g. "Phaco Cataract Surgery". No price -- pure clinical classification.
// Multiple billing Packages can point at one surgery, sub-classified by
// IOL type/origin for Cataract.) ──
export async function getSurgeries() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_surgeries').select('*').order('name');
  return data || [];
}
export async function addSurgery(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_surgeries', 'SUR');
  const { error } = await supabase.from('master_surgeries').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_surgeries', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateSurgery(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_surgeries').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_surgeries', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteSurgery(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_surgeries', id, code);
}

// ── DRUGS ──
export async function getDrugs() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_drugs').select('*, master_drug_types(id, name)').order('generic');
  return data || [];
}
// Drugs (Pharmacy tab) -- fixed "DRG" prefix, 3-digit sequence, same
// PREFIX+NNN shape as Services (CON001...) and Packages (PKG001...)
// rather than the old name-derived slug codes.
async function generateDrugCode(supabase) {
  const { data } = await supabase.from('master_drugs').select('code').ilike('code', 'DRG%');
  const maxSeq = (data || []).reduce((max, row) => {
    const m = row.code && row.code.match(/^DRG(\d+)$/);
    return m ? Math.max(max, parseInt(m[1], 10)) : max;
  }, 0);
  return `DRG${String(maxSeq + 1).padStart(3, '0')}`;
}

export async function addDrug(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const code = await generateDrugCode(supabase);
  const { error } = await supabase.from('master_drugs').insert({
    code, brand, generic, strength: values.strength, form: normalizeName(values.form),
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_drugs', code, 'Create', `${generic} (${brand}) created -- Rs.${values.rate}`);
  return { success: true };
}
export async function updateDrug(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const generic = normalizeName(values.generic);
  const form = normalizeName(values.form);
  const { error } = await supabase.from('master_drugs').update({
    brand, generic, strength: values.strength, form,
    drug_type_id: values.drugTypeId || null,
    rate: parseFloat(values.rate) || 0, gst_pct: parseFloat(values.gstPct) || 0,
  }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.generic !== generic) changes.push(`Generic ${oldValues.generic} -> ${generic}`);
  if (String(oldValues.rate) !== String(values.rate)) changes.push(`Rate Rs.${oldValues.rate} -> Rs.${values.rate}`);
  if (String(oldValues.gst_pct) !== String(values.gstPct)) changes.push(`GST ${oldValues.gst_pct}% -> ${values.gstPct}%`);
  await logMasterAudit(supabase, 'master_drugs', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDrug(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_drugs', id, code);
}

// ── VENDORS (Financial Master -- used by Inventory > Material Input) ──
export async function getVendorsMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('inventory_vendors').select('*').order('name');
  return data || [];
}
export async function addVendorMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const code = await generateCategoryCode(supabase, 'inventory_vendors', 'Vendor');
  const { error } = await supabase.from('inventory_vendors').insert({
    code, name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
    status: 'Active',
  });
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  await logMasterAudit(supabase, 'inventory_vendors', code, 'Create', `${name} added`);
  return { success: true };
}
export async function updateVendorMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const { error } = await supabase.from('inventory_vendors').update({
    name,
    contact_person: values.contactPerson ? normalizeName(values.contactPerson) : null,
    phone: values.phone || null,
    gst_number: values.gstNumber || null,
  }).eq('id', id);
  if (error) {
    if (error.code === '23505') return { error: 'A vendor with this name already exists.' };
    return { error: error.message };
  }
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.phone !== values.phone) changes.push(`Phone updated`);
  await logMasterAudit(supabase, 'inventory_vendors', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteVendorMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'inventory_vendors', id, code);
}

// ── DIAGNOSES ──
export async function getDiagnosesMaster() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_diagnoses').select('*').order('name');
  return data || [];
}
export async function addDiagnosisMaster(values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const code = await generateCategoryCode(supabase, 'master_diagnoses', 'DIAG');
  const { error } = await supabase.from('master_diagnoses').insert({ code, name, category, status: 'Active' });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_diagnoses', code, 'Create', `${name} created`);
  return { success: true };
}
export async function updateDiagnosisMaster(id, oldValues, values) {
  const supabase = await createClient();
  const name = normalizeName(values.name);
  const category = normalizeName(values.category);
  const { error } = await supabase.from('master_diagnoses').update({ name, category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.name !== name) changes.push(`Name ${oldValues.name} -> ${name}`);
  if (oldValues.category !== category) changes.push(`Category ${oldValues.category} -> ${category}`);
  await logMasterAudit(supabase, 'master_diagnoses', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteDiagnosisMaster(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_diagnoses', id, code);
}

// ── IOL CATALOG (Clinical Master, M29 -- referenced by Biometry &
// IOL Planning's Surgeon Approval screen). Brand/model act as the
// name-equivalent fields for code generation and normalization. ──
export async function getIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_iol_catalog').select('*').order('brand').order('model');
  return data || [];
}
export async function addIolCatalogItem(values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const code = await generateCategoryCode(supabase, 'master_iol_catalog', 'IOL');
  const { error } = await supabase.from('master_iol_catalog').insert({
    code, brand, model, manufacturer, category: values.category, status: 'Active',
  });
  if (error) return { error: error.message };
  await logMasterAudit(supabase, 'master_iol_catalog', code, 'Create', `${brand} -- ${model} (${values.category}) created`);
  return { success: true };
}
export async function updateIolCatalogItem(id, oldValues, values) {
  const supabase = await createClient();
  const brand = normalizeName(values.brand);
  const model = normalizeName(values.model);
  const manufacturer = normalizeName(values.manufacturer);
  const { error } = await supabase.from('master_iol_catalog').update({ brand, model, manufacturer, category: values.category }).eq('id', id);
  if (error) return { error: error.message };
  const changes = [];
  if (oldValues.brand !== brand) changes.push(`Brand ${oldValues.brand} -> ${brand}`);
  if (oldValues.model !== model) changes.push(`Model ${oldValues.model} -> ${model}`);
  if (oldValues.category !== values.category) changes.push(`Category ${oldValues.category} -> ${values.category}`);
  await logMasterAudit(supabase, 'master_iol_catalog', oldValues.code, 'Edit', changes.join('; ') || 'No field changes');
  return { success: true };
}
export async function deleteIolCatalogItem(id, code) {
  const supabase = await createClient();
  return deleteMasterRecord(supabase, 'master_iol_catalog', id, code);
}

// Active-only, grouped by category -- what Surgeon Approval's "Specific
// IOL" dropdown actually consumes.
export async function getActiveIolCatalog() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('master_iol_catalog')
    .select('id, code, brand, model, manufacturer, category')
    .eq('status', 'Active')
    .order('brand');
  return data || [];
}

// NOTE: Investigations previously had their own master_investigations
// table here, but it was empty and unused everywhere except this
// module -- every real investigation (with its actual rate) already
// lives in master_services where dept = 'Investigation'. Consolidated
// into Financial Masters (Migration 48) to avoid the same item ever
// having two different prices in two different places.
VEDA_EOF_MARKER_9f3a

cat > "app/(main)/master-data/financial/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback, Fragment } from 'react';
import {
  toggleStatus,
  getServices, addService, updateService, deleteService,
  getPackages, addPackage, updatePackage, deletePackage,
  getPackageLineItems, addPackageLineItem, removePackageLineItem,
  getDrugs, addDrug, updateDrug, deleteDrug,
  getDrugTypes, addDrugType, updateDrugType, deleteDrugType,
  getDosageOptions, addDosageOption, removeDosageOption,
  getVendorsMaster, addVendorMaster, updateVendorMaster, deleteVendorMaster,
  getSurgeries,
  getMasterAuditLog,
} from '../actions';

const SERVICE_DEPTS = ['Consultation', 'Investigation', 'Biometry', 'Minor Procedure'];
const TABS = [...SERVICE_DEPTS.map((d) => ({ key: d, type: 'service' })), { key: 'Pharmacy', type: 'drug' }, { key: 'Packages', label: 'Surgery', type: 'package' }, { key: 'Vendors', type: 'vendor' }];
const IOL_CATEGORIES = ['Monofocal', 'Monofocal Toric', 'Multifocal', 'EDOF'];
const ORIGINS = ['Indian', 'Imported'];

function StatusToggle({ record, table, onUpdate }) {
  const [loading, setLoading] = useState(false);
  async function handleToggle() {
    setLoading(true);
    await toggleStatus(table, record.id, record.status, record.code);
    setLoading(false);
    onUpdate();
  }
  return (
    <button className={`badge ${record.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ border: 'none', cursor: 'pointer' }} onClick={handleToggle} disabled={loading}>
      {record.status}
    </button>
  );
}

export default function FinancialMastersPage() {
  const [activeTab, setActiveTab] = useState('Consultation');
  const [services, setServices] = useState([]);
  const [packages, setPackages] = useState([]);
  const [drugs, setDrugs] = useState([]);
  const [drugTypes, setDrugTypes] = useState([]);
  const [dosageOptions, setDosageOptions] = useState([]);
  const [showTypesPanel, setShowTypesPanel] = useState(false);
  const [expandedTypeId, setExpandedTypeId] = useState(null);
  const [newTypeName, setNewTypeName] = useState('');
  const [newDosageText, setNewDosageText] = useState('');
  const [surgeries, setSurgeries] = useState([]);
  const [vendors, setVendors] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({});
  const [editingId, setEditingId] = useState(null);
  const [editForm, setEditForm] = useState({});
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');

  const [constituentsFor, setConstituentsFor] = useState(null);
  const [constituents, setConstituents] = useState([]);
  const [newLineDesc, setNewLineDesc] = useState('');
  const [newLineAmount, setNewLineAmount] = useState('');

  const tabDef = TABS.find((t) => t.key === activeTab);
  const auditTable = tabDef.type === 'package' ? 'master_packages' : tabDef.type === 'drug' ? 'master_drugs' : tabDef.type === 'vendor' ? 'inventory_vendors' : 'master_services';

  const refresh = useCallback(async () => {
    setServices(await getServices());
    setPackages(await getPackages());
    setDrugs(await getDrugs());
    setDrugTypes(await getDrugTypes());
    setDosageOptions(await getDosageOptions());
    setSurgeries(await getSurgeries());
    setVendors(await getVendorsMaster());
    setAuditLog(await getMasterAuditLog(auditTable));
  }, [auditTable]);

  useEffect(() => { refresh(); }, [refresh]);

  const deptServices = services.filter((s) => s.dept === activeTab);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }
  function updateEdit(field) {
    return (e) => setEditForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleAdd() {
    setError(''); setSuccess('');
    if (tabDef.type === 'drug') {
      if (!form.generic) { setError('Salt Composition is required.'); return; }
    } else if (tabDef.type === 'package') {
      if (!form.name) { setError('Name is required.'); return; }
    } else if (tabDef.type === 'vendor') {
      if (!form.name) { setError('Vendor name is required.'); return; }
    } else if (!form.name) {
      setError('Name is required.'); return;
    }

    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract';
      result = await addPackage(isCataract ? form : { ...form, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await addDrug(form);
    else if (tabDef.type === 'vendor') result = await addVendorMaster(form);
    else result = await addService({ ...form, dept: activeTab });

    if (result?.error) { setError(result.error); return; }
    setSuccess(`${form.name || form.generic} added${tabDef.type === 'package' ? ' -- add its constituents to set the price' : ''}.`);
    setForm({});
    setShowAdd(false);
    refresh();
    if (tabDef.type === 'package' && result.package) openConstituents(result.package);
  }

  function startEdit(record) {
    setError(''); setSuccess('');
    setEditingId(record.id);
    if (tabDef.type === 'package') setEditForm({ name: record.name || '', includes: record.includes || '', surgeryId: record.surgery_id || '', iolCategory: record.iol_category || '', origin: record.origin || '' });
    else if (tabDef.type === 'drug') setEditForm({ brand: record.brand || '', generic: record.generic || '', strength: record.strength || '', form: record.form || '', drugTypeId: record.drug_type_id || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '' });
    else if (tabDef.type === 'vendor') setEditForm({ name: record.name || '', contactPerson: record.contact_person || '', phone: record.phone || '', gstNumber: record.gst_number || '' });
    else setEditForm({ name: record.name || '', rate: record.rate ?? '', gstPct: record.gst_pct ?? '', investigationPackage: record.investigation_package || '' });
  }

  function cancelEdit() {
    setEditingId(null);
    setError('');
  }

  async function handleAddType() {
    setError(''); setSuccess('');
    if (!newTypeName.trim()) return;
    const result = await addDrugType({ name: newTypeName });
    if (result?.error) { setError(result.error); return; }
    setNewTypeName('');
    refresh();
  }

  async function handleRenameType(t, name) {
    if (!name.trim() || name === t.name) return;
    await updateDrugType(t.id, t, { name });
    refresh();
  }

  async function handleAddDosage(typeId) {
    setError(''); setSuccess('');
    if (!newDosageText.trim()) return;
    const result = await addDosageOption(typeId, newDosageText);
    if (result?.error) { setError(result.error); return; }
    setNewDosageText('');
    refresh();
  }

  async function handleRemoveDosage(id) {
    await removeDosageOption(id);
    refresh();
  }

  async function saveEdit(record) {
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') {
      const isCataract = surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract';
      result = await updatePackage(record.id, record, isCataract ? editForm : { ...editForm, iolCategory: '', origin: '' });
    }
    else if (tabDef.type === 'drug') result = await updateDrug(record.id, record, editForm);
    else if (tabDef.type === 'vendor') result = await updateVendorMaster(record.id, record, editForm);
    else result = await updateService(record.id, record, { ...editForm, dept: record.dept });
    if (result?.error) { setError(result.error); return; }
    setSuccess('Updated.');
    setEditingId(null);
    refresh();
  }

  async function handleDelete(record) {
    if (!window.confirm(`Delete "${record.name || record.generic}"? This cannot be undone. If it's in use elsewhere, deletion will be blocked and you should mark it Inactive instead.`)) return;
    setError(''); setSuccess('');
    let result;
    if (tabDef.type === 'package') result = await deletePackage(record.id, record.code);
    else if (tabDef.type === 'drug') result = await deleteDrug(record.id, record.code);
    else if (tabDef.type === 'vendor') result = await deleteVendorMaster(record.id, record.code);
    else result = await deleteService(record.id, record.code);
    if (result?.error) { setError(result.error); return; }
    setSuccess('Deleted.');
    refresh();
  }

  async function openConstituents(pkg) {
    setConstituentsFor(pkg);
    setConstituents(await getPackageLineItems(pkg.id));
    setNewLineDesc(''); setNewLineAmount('');
  }

  function closeConstituents() {
    setConstituentsFor(null);
    setConstituents([]);
  }

  async function handleAddLine() {
    if (!newLineDesc.trim() || !newLineAmount) { setError('Description and amount are required.'); return; }
    setError('');
    const result = await addPackageLineItem(constituentsFor.id, newLineDesc, newLineAmount);
    if (result?.error) { setError(result.error); return; }
    setNewLineDesc(''); setNewLineAmount('');
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  async function handleRemoveLine(id) {
    await removePackageLineItem(id, constituentsFor.id);
    setConstituents(await getPackageLineItems(constituentsFor.id));
    refresh();
  }

  const constituentsTotal = constituents.reduce((s, c) => s + Number(c.amount), 0);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div>
        <div style={{ display: 'flex', gap: 6, marginBottom: 16, flexWrap: 'wrap' }}>
          {TABS.map((t) => (
            <button
              key={t.key}
              className={activeTab === t.key ? 'btn btn-primary' : 'btn'}
              onClick={() => { setActiveTab(t.key); setShowAdd(false); setEditingId(null); setError(''); setSuccess(''); }}
            >
              {t.label || t.key}
            </button>
          ))}
        </div>

        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> {activeTab}</div>
            <button className="btn btn-primary btn-sm" onClick={() => { setShowAdd(!showAdd); setEditingId(null); }}>
              <i className="ti ti-plus"></i> Add New
            </button>
          </div>

          {error && <div className="msg-err">{error}</div>}
          {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

          {(tabDef.type === 'service' || tabDef.type === 'drug' || tabDef.type === 'vendor') && (
            <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-info-circle"></i> {tabDef.type === 'service' ? 'Code is generated automatically, linked to department (e.g. INV001, INV002...).' : tabDef.type === 'vendor' ? 'Code is generated automatically (VEN01, VEN02...). Vendor names must be unique.' : 'Code is generated automatically from the name.'}
            </div>
          )}

          {showAdd && (
            <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
              {tabDef.type === 'service' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('name')} />
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                  {activeTab === 'Investigation' && (
                    <div style={{ gridColumn: 'span 3' }}>
                      <input className="fi" placeholder="Package (optional, e.g. Cataract) -- lets Counselling order this as part of a standard panel" onChange={update('investigationPackage')} />
                    </div>
                  )}
                </div>
              )}
              {tabDef.type === 'drug' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(3, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name" onChange={update('brand')} />
                  <input className="fi" placeholder="Salt Composition" onChange={update('generic')} />
                  <input className="fi" placeholder="Strength (e.g. 0.5%)" onChange={update('strength')} />
                  <select className="fi" onChange={update('drugTypeId')} defaultValue="">
                    <option value="">-- Type (e.g. Eye Drop) --</option>
                    {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                  </select>
                  <input type="number" className="fi" placeholder="Rate" onChange={update('rate')} />
                  <input type="number" className="fi" placeholder="GST %" onChange={update('gstPct')} />
                </div>
              )}
              {tabDef.type === 'vendor' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Vendor / Distributor Name" onChange={update('name')} />
                  <input className="fi" placeholder="Contact Person (optional)" onChange={update('contactPerson')} />
                  <input className="fi" placeholder="Phone (optional)" onChange={update('phone')} />
                  <input className="fi" placeholder="GST Number (optional)" onChange={update('gstNumber')} />
                </div>
              )}
              {tabDef.type === 'package' && (
                <div style={{ display: 'grid', gridTemplateColumns: 'repeat(2, 1fr)', gap: 8 }}>
                  <input className="fi" placeholder="Name (e.g. Cataract Surgery -- Standard IOL)" onChange={update('name')} />
                  <select className="fi" onChange={update('surgeryId')} defaultValue="">
                    <option value="">-- Link to surgery (optional) --</option>
                    {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                  </select>
                  {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
                    <>
                      <select className="fi" onChange={update('iolCategory')} defaultValue="">
                        <option value="">-- IOL type (optional) --</option>
                        {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                      </select>
                      <select className="fi" onChange={update('origin')} defaultValue="">
                        <option value="">-- Origin (optional) --</option>
                        {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                      </select>
                    </>
                  )}
                  <input className="fi" placeholder="Includes (description)" style={{ gridColumn: 'span 2' }} onChange={update('includes')} />
                  <div style={{ gridColumn: 'span 2', fontSize: 11, color: 'var(--g500)' }}>
                    Code auto-generates (PKG001, PKG002...). Price is set by adding constituents after saving.
                    {(surgeries.find((s) => s.id === form.surgeryId)?.category === 'Cataract') && (
                      <> IOL type + Origin determine which packages the Counselling module shows for a given Biometry result.</>
                    )}
                  </div>
                </div>
              )}
              <button className="btn btn-primary btn-sm" style={{ marginTop: 10 }} onClick={handleAdd}>Save</button>
            </div>
          )}

          {tabDef.type === 'service' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Rate</th><th>GST%</th>{activeTab === 'Investigation' && <th>Package</th>}<th>Status</th><th></th></tr></thead>
              <tbody>
                {deptServices.map((s) => (
                  editingId === s.id ? (
                    <tr key={s.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 80 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 60 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      {activeTab === 'Investigation' && (
                        <td><input className="fi fi-sm" style={{ width: 110 }} placeholder="optional" value={editForm.investigationPackage} onChange={updateEdit('investigationPackage')} /></td>
                      )}
                      <td><span className={`badge ${s.status === 'Active' ? 'b-green' : 'b-gray'}`}>{s.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(s)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={s.id}>
                      <td style={{ fontFamily: 'monospace' }}>{s.code}</td><td>{s.name}</td>
                      <td>Rs.{s.rate}</td><td>{s.gst_pct}%</td>
                      {activeTab === 'Investigation' && <td>{s.investigation_package ? <span className="badge b-purple" style={{ fontSize: 10 }}>{s.investigation_package}</span> : <span style={{ color: 'var(--g400)' }}>--</span>}</td>}
                      <td><StatusToggle record={s} table="master_services" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(s)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(s)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {deptServices.length === 0 && (
                  <tr><td colSpan={activeTab === 'Investigation' ? 7 : 6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No {activeTab.toLowerCase()} services yet.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Salt Composition</th><th>Strength</th><th>Type</th><th>Rate</th><th>GST%</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {drugs.map((d) => (
                  editingId === d.id ? (
                    <tr key={d.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td>
                      <td><input className="fi fi-sm" value={editForm.brand} onChange={updateEdit('brand')} /></td>
                      <td><input className="fi fi-sm" value={editForm.generic} onChange={updateEdit('generic')} /></td>
                      <td><input className="fi fi-sm" style={{ width: 80 }} value={editForm.strength} onChange={updateEdit('strength')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.drugTypeId || ''} onChange={updateEdit('drugTypeId')}>
                          <option value="">-- Type --</option>
                          {drugTypes.filter((t) => t.status === 'Active').map((t) => <option key={t.id} value={t.id}>{t.name}</option>)}
                        </select>
                      </td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 70 }} value={editForm.rate} onChange={updateEdit('rate')} /></td>
                      <td><input type="number" className="fi fi-sm" style={{ width: 55 }} value={editForm.gstPct} onChange={updateEdit('gstPct')} /></td>
                      <td><span className={`badge ${d.status === 'Active' ? 'b-green' : 'b-gray'}`}>{d.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(d)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={d.id}>
                      <td style={{ fontFamily: 'monospace' }}>{d.code}</td><td>{d.brand}</td><td>{d.generic}</td><td>{d.strength}</td>
                      <td>{d.master_drug_types?.name || <span style={{ color: 'var(--g400)' }}>-- unset --</span>}</td>
                      <td>Rs.{d.rate}</td><td>{d.gst_pct}%</td>
                      <td><StatusToggle record={d} table="master_drugs" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(d)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(d)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
              </tbody>
            </table>
          )}

          {tabDef.type === 'vendor' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Contact Person</th><th>Phone</th><th>GST Number</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {vendors.map((v) => (
                  editingId === v.id ? (
                    <tr key={v.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td><input className="fi fi-sm" value={editForm.contactPerson} onChange={updateEdit('contactPerson')} /></td>
                      <td><input className="fi fi-sm" value={editForm.phone} onChange={updateEdit('phone')} /></td>
                      <td><input className="fi fi-sm" value={editForm.gstNumber} onChange={updateEdit('gstNumber')} /></td>
                      <td><span className={`badge ${v.status === 'Active' ? 'b-green' : 'b-gray'}`}>{v.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(v)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={v.id}>
                      <td style={{ fontFamily: 'monospace' }}>{v.code}</td><td style={{ fontWeight: 600 }}>{v.name}</td>
                      <td>{v.contact_person || '--'}</td><td>{v.phone || '--'}</td><td>{v.gst_number || '--'}</td>
                      <td><StatusToggle record={v} table="inventory_vendors" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => startEdit(v)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(v)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )
                ))}
                {vendors.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No vendors yet. Add one to start using it in Inventory &gt; Material Input.</td></tr>
                )}
              </tbody>
            </table>
          )}

          {tabDef.type === 'drug' && (
            <div className="card" style={{ marginTop: 16 }}>
              <div className="card-head" style={{ cursor: 'pointer' }} onClick={() => setShowTypesPanel((p) => !p)}>
                <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-category-2" style={{ color: 'var(--purple)' }}></i> Manage Drug Types &amp; Dosage Options</div>
                <i className={`ti ti-chevron-${showTypesPanel ? 'up' : 'down'}`}></i>
              </div>
              {showTypesPanel && (
                <div style={{ marginTop: 12 }}>
                  <div className="msg-info" style={{ marginBottom: 12 }}>
                    <i className="ti ti-info-circle"></i> Each type&apos;s dosage options are what shows up in the doctor&apos;s Prescription dosage dropdown when a drug of that type is selected -- e.g. &quot;Apply thin layer&quot; for Eye Ointment instead of &quot;1 drop&quot;.
                  </div>
                  <div style={{ display: 'flex', gap: 8, marginBottom: 14 }}>
                    <input className="fi" style={{ maxWidth: 260 }} placeholder="New type name (e.g. Suspension)" value={newTypeName} onChange={(e) => setNewTypeName(e.target.value)} />
                    <button className="btn btn-primary" onClick={handleAddType}>Add Type</button>
                  </div>
                  {drugTypes.map((t) => (
                    <div key={t.id} style={{ border: '1px solid var(--g100)', borderRadius: 8, marginBottom: 8, overflow: 'hidden' }}>
                      <div style={{ display: 'flex', alignItems: 'center', gap: 10, padding: '8px 12px', background: 'var(--g50)' }}>
                        <button className="btn btn-sm" onClick={() => setExpandedTypeId((id) => (id === t.id ? null : t.id))}>
                          <i className={`ti ti-chevron-${expandedTypeId === t.id ? 'up' : 'down'}`}></i>
                        </button>
                        <input
                          className="fi fi-sm" style={{ maxWidth: 220, fontWeight: 600 }}
                          defaultValue={t.name}
                          onBlur={(e) => handleRenameType(t, e.target.value)}
                        />
                        <span style={{ fontSize: 11, color: 'var(--g400)', fontFamily: 'monospace' }}>{t.code}</span>
                        <span style={{ marginLeft: 'auto' }}><StatusToggle record={t} table="master_drug_types" onUpdate={refresh} /></span>
                      </div>
                      {expandedTypeId === t.id && (
                        <div style={{ padding: 12 }}>
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).map((o) => (
                            <div key={o.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '4px 0' }}>
                              <span style={{ fontSize: 13 }}>{o.dosage_text}</span>
                              <button className="btn btn-sm" style={{ marginLeft: 'auto', padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveDosage(o.id)}>
                                <i className="ti ti-trash" style={{ color: 'var(--red)' }}></i>
                              </button>
                            </div>
                          ))}
                          {dosageOptions.filter((o) => o.drug_type_id === t.id).length === 0 && (
                            <div style={{ fontSize: 12, color: 'var(--g400)', padding: '4px 0' }}>No dosage options yet for this type.</div>
                          )}
                          <div style={{ display: 'flex', gap: 6, marginTop: 8 }}>
                            <input className="fi fi-sm" placeholder="e.g. Apply thin layer" value={newDosageText} onChange={(e) => setNewDosageText(e.target.value)} />
                            <button className="btn btn-sm btn-primary" onClick={() => handleAddDosage(t.id)}>Add</button>
                          </div>
                        </div>
                      )}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}

          {tabDef.type === 'package' && (
            <table className="tbl">
              <thead><tr><th>Code</th><th>Name</th><th>Surgery</th><th>IOL Type / Origin</th><th>Price</th><th>Status</th><th></th></tr></thead>
              <tbody>
                {packages.map((p) => (
                  <Fragment key={p.id}>
                  {editingId === p.id ? (
                    <tr key={p.id} style={{ background: 'var(--g50)' }}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td>
                      <td><input className="fi fi-sm" value={editForm.name} onChange={updateEdit('name')} /></td>
                      <td>
                        <select className="fi fi-sm" value={editForm.surgeryId} onChange={updateEdit('surgeryId')}>
                          <option value="">--</option>
                          {surgeries.map((s) => <option key={s.id} value={s.id}>{s.name}</option>)}
                        </select>
                      </td>
                      <td>
                        {(surgeries.find((s) => s.id === editForm.surgeryId)?.category === 'Cataract') ? (
                          <div style={{ display: 'flex', gap: 4 }}>
                            <select className="fi fi-sm" value={editForm.iolCategory} onChange={updateEdit('iolCategory')}>
                              <option value="">IOL type --</option>
                              {IOL_CATEGORIES.map((c) => <option key={c} value={c}>{c}</option>)}
                            </select>
                            <select className="fi fi-sm" value={editForm.origin} onChange={updateEdit('origin')}>
                              <option value="">Origin --</option>
                              {ORIGINS.map((o) => <option key={o} value={o}>{o}</option>)}
                            </select>
                          </div>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>N/A</span>}
                      </td>
                      <td>Rs.{p.price}</td>
                      <td><span className={`badge ${p.status === 'Active' ? 'b-green' : 'b-gray'}`}>{p.status}</span></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm btn-primary" onClick={() => saveEdit(p)}>Save</button>
                        <button className="btn btn-sm" onClick={cancelEdit}>Cancel</button>
                      </td>
                    </tr>
                  ) : (
                    <tr key={p.id}>
                      <td style={{ fontFamily: 'monospace' }}>{p.code}</td><td>{p.name}</td>
                      <td style={{ fontSize: 12, color: 'var(--g500)' }}>{p.master_surgeries?.name || '--'}</td>
                      <td>
                        {p.iol_category ? (
                          <span style={{ display: 'flex', gap: 4 }}>
                            <span className="badge b-purple" style={{ fontSize: 10 }}>{p.iol_category}</span>
                            {p.origin && <span className={`badge ${p.origin === 'Imported' ? 'b-blue' : 'b-green'}`} style={{ fontSize: 10 }}>{p.origin}</span>}
                          </span>
                        ) : <span style={{ fontSize: 11, color: 'var(--g400)' }}>--</span>}
                      </td>
                      <td style={{ fontWeight: 600 }}>Rs.{p.price}</td>
                      <td><StatusToggle record={p} table="master_packages" onUpdate={refresh} /></td>
                      <td style={{ display: 'flex', gap: 4 }}>
                        <button className="btn btn-sm" onClick={() => openConstituents(p)}><i className="ti ti-list-details"></i> Breakup</button>
                        <button className="btn btn-sm" onClick={() => startEdit(p)}><i className="ti ti-edit"></i></button>
                        <button className="btn btn-sm" onClick={() => handleDelete(p)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                      </td>
                    </tr>
                  )}

                  {constituentsFor?.id === p.id && (
                    <tr>
                      <td colSpan={7} style={{ padding: 0, border: 'none' }}>
                        <div style={{ border: '1.5px solid var(--teal)', borderRadius: 8, padding: 14, margin: '4px 0 12px' }}>
                          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
                            <div style={{ fontSize: 13, fontWeight: 700 }}>
                              <i className="ti ti-list-details" style={{ color: 'var(--teal)' }}></i> Breakup -- {constituentsFor.name} ({constituentsFor.code})
                            </div>
                            <button className="btn btn-sm" onClick={closeConstituents}><i className="ti ti-x"></i> Close</button>
                          </div>
                          <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
                            <i className="ti ti-info-circle"></i> The package price is always the sum of these constituents.
                          </div>
                          <table className="tbl" style={{ marginBottom: 12 }}>
                            <thead><tr><th>Description</th><th style={{ textAlign: 'right' }}>Amount</th><th></th></tr></thead>
                            <tbody>
                              {constituents.map((c) => (
                                <tr key={c.id}>
                                  <td>{c.description}</td>
                                  <td style={{ textAlign: 'right' }}>Rs.{Number(c.amount).toFixed(2)}</td>
                                  <td><button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLine(c.id)}>Remove</button></td>
                                </tr>
                              ))}
                              {constituents.length === 0 && (
                                <tr><td colSpan={3} style={{ padding: 12, textAlign: 'center', color: 'var(--g400)' }}>No constituents yet -- price is Rs.0 until you add some.</td></tr>
                              )}
                            </tbody>
                            <tfoot>
                              <tr style={{ fontWeight: 700 }}>
                                <td>Total</td><td style={{ textAlign: 'right' }}>Rs.{constituentsTotal.toFixed(2)}</td><td></td>
                              </tr>
                            </tfoot>
                          </table>
                          <div style={{ display: 'flex', gap: 8 }}>
                            <input className="fi" placeholder="e.g. Surgeon Fee, OT Charges, IOL, Consumables..." value={newLineDesc} onChange={(e) => setNewLineDesc(e.target.value)} style={{ flex: 2 }} />
                            <input type="number" className="fi" placeholder="Amount" value={newLineAmount} onChange={(e) => setNewLineAmount(e.target.value)} style={{ flex: 1 }} />
                            <button className="btn btn-primary btn-sm" onClick={handleAddLine}><i className="ti ti-plus"></i> Add</button>
                          </div>
                        </div>
                      </td>
                    </tr>
                  )}
                  </Fragment>
                ))}
                {packages.length === 0 && (
                  <tr><td colSpan={7} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No packages yet.</td></tr>
                )}
              </tbody>
            </table>
          )}
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--g400)' }}></i> Change History -- {activeTab}
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes recorded yet.</div>}
          {auditLog.map((a) => (
            <div key={a.id} style={{ padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                <span className={`badge ${a.action === 'Create' ? 'b-green' : a.action === 'Edit' ? 'b-blue' : a.action === 'Reactivate' ? 'b-teal' : 'b-red'}`} style={{ fontSize: 10 }}>{a.action}</span>
                <span style={{ fontSize: 10, color: 'var(--g400)' }}>{new Date(a.changed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</span>
              </div>
              <div style={{ marginTop: 3, fontFamily: 'monospace', fontSize: 11, color: 'var(--g600)' }}>{a.record_code}</div>
              <div style={{ marginTop: 2 }}>{a.detail}</div>
              <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 2 }}>{a.profiles?.full_name || 'Staff'}</div>
            </div>
          ))}
        </div>
      </div>
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
find "app/(main)/inventory" -type f
echo ""

git add -A "app/(main)/inventory/" "app/(main)/master-data/actions.js" "app/(main)/master-data/financial/page.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Inventory: redesign as multi-tab module (Dashboard/Stock/Material Input) with shortages, unpaid-bill tracking, stock lookup; move Vendors into Financial Masters"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "What changed for you:"
echo "  - Inventory is now 3 tabs: Dashboard, Stock, Material Input"
echo "  - Dashboard: items running short, last 5 vendor bills (paid/unpaid),"
echo "    an unpaid-bills alert with running total, a big 'New Material In'"
echo "    button, and a quick stock-lookup search box"
echo "  - Stock tab: the full item table -- Track New Drug, Edit (unit +"
echo "    reorder level, now actually editable), History"
echo "  - Material Input tab: enter vendor + bill number + total bill amount"
echo "    ONCE, add as many item lines as are on that bill, then a full"
echo "    Purchase History list where you can toggle Paid/Unpaid per bill"
echo "  - Vendors are now managed under Financial Masters > Vendors"
echo "    (auto-coded VEN01, VEN02..., names must be unique) -- the"
echo "    Material Input vendor dropdown reads from there directly"
