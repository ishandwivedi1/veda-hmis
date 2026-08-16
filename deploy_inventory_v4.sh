#!/bin/bash
set -e

echo "=================================================="
echo "Deploying: Material Input width/total fix + Reports tab"
echo "=================================================="
echo ""
echo "This script overwrites/creates the files itself -- no manual"
echo "upload or copy-paste needed -- then commits and pushes."
echo ""

mkdir -p "app/(main)/inventory/reports"

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

// ── REPORTS ──
// These are periodic/analytical views, not the hot-path dashboard, so
// aggregating the (small) result sets in JS here is fine -- no need
// for the same DB-side-view treatment given to getInventoryDashboard.

// How much money is currently sitting on the shelf, item by item.
export async function getStockValuationReport() {
  const supabase = await createClient();
  const { data: lots } = await supabase
    .from('inventory_lots')
    .select('item_id, qty_on_hand, cost_price, inventory_items(unit, master_drugs(brand, generic, strength))')
    .eq('status', 'Active')
    .gt('qty_on_hand', 0);

  const byItem = {};
  (lots || []).forEach((l) => {
    const id = l.item_id;
    if (!byItem[id]) {
      byItem[id] = {
        name: l.inventory_items?.master_drugs ? `${l.inventory_items.master_drugs.brand || l.inventory_items.master_drugs.generic} ${l.inventory_items.master_drugs.strength || ''}`.trim() : 'Unknown',
        unit: l.inventory_items?.unit, qty: 0, value: 0,
      };
    }
    byItem[id].qty += Number(l.qty_on_hand);
    byItem[id].value += Number(l.qty_on_hand) * Number(l.cost_price || 0);
  });
  const rows = Object.values(byItem)
    .map((r) => ({ ...r, avgCost: r.qty ? r.value / r.qty : 0 }))
    .sort((a, b) => b.value - a.value);
  const totalValue = rows.reduce((s, r) => s + r.value, 0);
  return { rows, totalValue };
}

// Batches expiring within N days, nearest first -- so stock can be
// pushed/sold/returned before it's wasted.
export async function getExpiryReport(days = 90) {
  const supabase = await createClient();
  const cutoff = new Date();
  cutoff.setDate(cutoff.getDate() + Number(days));

  const { data: lots } = await supabase
    .from('inventory_lots')
    .select('id, batch_number, expiry_date, qty_on_hand, inventory_items(unit, master_drugs(brand, generic, strength))')
    .eq('status', 'Active')
    .gt('qty_on_hand', 0)
    .not('expiry_date', 'is', null)
    .lte('expiry_date', cutoff.toISOString().slice(0, 10))
    .order('expiry_date', { ascending: true });

  const today = new Date();
  return (lots || []).map((l) => ({
    name: l.inventory_items?.master_drugs ? `${l.inventory_items.master_drugs.brand || l.inventory_items.master_drugs.generic} ${l.inventory_items.master_drugs.strength || ''}`.trim() : 'Unknown',
    unit: l.inventory_items?.unit,
    batchNumber: l.batch_number,
    expiryDate: l.expiry_date,
    qty: l.qty_on_hand,
    daysLeft: Math.ceil((new Date(l.expiry_date) - today) / 86400000),
  }));
}

// How much of each drug actually got dispensed over a date range --
// the real signal for reorder quantities, not just current stock.
export async function getConsumptionReport(startDate, endDate) {
  const supabase = await createClient();
  let q = supabase
    .from('inventory_movements')
    .select('item_id, qty_change, created_at, inventory_items(unit, master_drugs(brand, generic, strength))')
    .eq('movement_type', 'Dispensed');
  if (startDate) q = q.gte('created_at', `${startDate}T00:00:00`);
  if (endDate) q = q.lte('created_at', `${endDate}T23:59:59`);
  const { data } = await q;

  const byItem = {};
  (data || []).forEach((m) => {
    const id = m.item_id;
    if (!byItem[id]) {
      byItem[id] = {
        name: m.inventory_items?.master_drugs ? `${m.inventory_items.master_drugs.brand || m.inventory_items.master_drugs.generic} ${m.inventory_items.master_drugs.strength || ''}`.trim() : 'Unknown',
        unit: m.inventory_items?.unit, consumed: 0,
      };
    }
    byItem[id].consumed += Math.abs(Number(m.qty_change));
  });
  return Object.values(byItem).sort((a, b) => b.consumed - a.consumed);
}

// Purchases grouped by vendor over a date range -- bill count, total
// spend, and how much of that is still unpaid, per vendor.
export async function getVendorPurchaseSummary(startDate, endDate) {
  const supabase = await createClient();
  let q = supabase.from('inventory_purchases').select('vendor_id, bill_amount, payment_status, bill_date, inventory_vendors(name)');
  if (startDate) q = q.gte('bill_date', startDate);
  if (endDate) q = q.lte('bill_date', endDate);
  const { data } = await q;

  const byVendor = {};
  (data || []).forEach((p) => {
    const id = p.vendor_id;
    if (!byVendor[id]) byVendor[id] = { name: p.inventory_vendors?.name || '--', bills: 0, total: 0, paid: 0, unpaid: 0 };
    byVendor[id].bills += 1;
    const amt = Number(p.bill_amount || 0);
    byVendor[id].total += amt;
    if (p.payment_status === 'Paid') byVendor[id].paid += amt;
    else byVendor[id].unpaid += amt;
  });
  return Object.values(byVendor).sort((a, b) => b.total - a.total);
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
  { href: '/inventory/reports', label: 'Reports', icon: 'ti-report' },
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

        {/* Column headers -- Item is capped narrower, other columns widened */}
        <div style={{ display: 'flex', gap: 6, marginBottom: 4, fontSize: 10, fontWeight: 600, color: 'var(--g500)', textTransform: 'uppercase', padding: '0 2px' }}>
          <div style={{ width: 150 }}>Item</div>
          <div style={{ width: 110 }}>Batch</div>
          <div style={{ width: 140 }}>Expiry</div>
          <div style={{ width: 75 }}>Qty</div>
          <div style={{ width: 95 }}>Rate</div>
          <div style={{ width: 80 }}>Disc%</div>
          <div style={{ flex: '1 1 0', minWidth: 90, textAlign: 'right' }}>Total</div>
          <div style={{ width: 24 }}></div>
        </div>

        {pLines.map((line) => (
          <div key={line.key} style={{ display: 'flex', gap: 6, marginBottom: 6, alignItems: 'center' }}>
            <select className="fi fi-sm" style={{ width: 150 }} value={line.itemId} onChange={(e) => updateLine(line.key, 'itemId', e.target.value)}>
              <option value="">-- Item --</option>
              {itemPicker.map((i) => <option key={i.itemId} value={i.itemId}>{i.name}</option>)}
            </select>
            <input className="fi fi-sm" style={{ width: 110 }} placeholder="Batch" value={line.batchNumber} onChange={(e) => updateLine(line.key, 'batchNumber', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 140 }} type="date" value={line.expiryDate} onChange={(e) => updateLine(line.key, 'expiryDate', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 75 }} type="number" min="1" placeholder="0" value={line.qty} onChange={(e) => updateLine(line.key, 'qty', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 95 }} type="number" min="0" step="0.01" placeholder="0" value={line.rate} onChange={(e) => updateLine(line.key, 'rate', e.target.value)} />
            <input className="fi fi-sm" style={{ width: 80 }} type="number" min="0" max="100" step="0.01" placeholder="0" value={line.discountPct} onChange={(e) => updateLine(line.key, 'discountPct', e.target.value)} />
            <div style={{ flex: '1 1 0', minWidth: 90, textAlign: 'right', fontSize: 12, fontWeight: 600 }}>
              {lineTotal(line) > 0 ? `Rs.${lineTotal(line).toFixed(2)}` : '--'}
            </div>
            <button className="btn btn-sm" onClick={() => removeLine(line.key)} title="Remove line" style={{ width: 24, padding: '2px 4px', color: 'var(--red)' }}><i className="ti ti-x"></i></button>
          </div>
        ))}
        <button className="btn btn-sm" onClick={addLine} style={{ marginBottom: 10 }}><i className="ti ti-plus"></i> Add another item</button>

        {/* Grand total -- aligned directly under the Total column above it */}
        <div style={{ display: 'flex', gap: 6, alignItems: 'center', borderTop: '1px solid var(--g100)', paddingTop: 10, marginBottom: 14 }}>
          <div style={{ width: 150 + 110 + 140 + 75 + 95 + 80 + 36, textAlign: 'right', fontSize: 12, color: 'var(--g500)', fontWeight: 600 }}>Grand Total</div>
          <div style={{ flex: '1 1 0', minWidth: 90, textAlign: 'right', fontSize: 15, fontWeight: 800 }}>Rs.{grandTotal.toFixed(2)}</div>
          <div style={{ width: 24 }}></div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div style={{ fontSize: 12 }}>
            {totalsMismatch && (
              <span style={{ color: 'var(--red)' }}>
                <i className="ti ti-alert-triangle"></i> Doesn&apos;t match bill amount (Rs.{billAmountNum.toFixed(2)})</span>
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

cat > "app/(main)/inventory/reports/page.js" << 'VEDA_EOF_MARKER_9f3a'
'use client';

import { useState, useEffect, useCallback } from 'react';
import InventoryTabs from '../inventory-tabs';
import { getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary } from '../actions';

function daysAgo(n) {
  const d = new Date();
  d.setDate(d.getDate() - n);
  return d.toISOString().slice(0, 10);
}
const today = () => new Date().toISOString().slice(0, 10);

export default function InventoryReportsPage() {
  const [valuation, setValuation] = useState({ rows: [], totalValue: 0 });
  const [expiryDays, setExpiryDays] = useState('90');
  const [expiry, setExpiry] = useState([]);
  const [consumptionStart, setConsumptionStart] = useState(() => daysAgo(30));
  const [consumptionEnd, setConsumptionEnd] = useState(() => today());
  const [consumption, setConsumption] = useState([]);
  const [vendorStart, setVendorStart] = useState(() => daysAgo(90));
  const [vendorEnd, setVendorEnd] = useState(() => today());
  const [vendorSummary, setVendorSummary] = useState([]);
  const [loading, setLoading] = useState(true);

  const loadValuation = useCallback(async () => setValuation(await getStockValuationReport()), []);
  const loadExpiry = useCallback(async () => setExpiry(await getExpiryReport(expiryDays)), [expiryDays]);
  const loadConsumption = useCallback(async () => setConsumption(await getConsumptionReport(consumptionStart, consumptionEnd)), [consumptionStart, consumptionEnd]);
  const loadVendorSummary = useCallback(async () => setVendorSummary(await getVendorPurchaseSummary(vendorStart, vendorEnd)), [vendorStart, vendorEnd]);

  useEffect(() => {
    Promise.all([loadValuation(), loadExpiry(), loadConsumption(), loadVendorSummary()]).then(() => setLoading(false));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  useEffect(() => { loadExpiry(); }, [loadExpiry]);
  useEffect(() => { loadConsumption(); }, [loadConsumption]);
  useEffect(() => { loadVendorSummary(); }, [loadVendorSummary]);

  return (
    <div>
      <InventoryTabs />

      {loading ? (
        <div style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>Loading reports...</div>
      ) : (
        <>
          {/* STOCK VALUATION */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-currency-rupee" style={{ color: 'var(--green)' }}></i> Stock Valuation</div>
              <div style={{ fontSize: 13 }}>
                <span style={{ color: 'var(--g500)' }}>Total value on shelf: </span>
                <span style={{ fontWeight: 800, fontSize: 16 }}>Rs.{valuation.totalValue.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</span>
              </div>
            </div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>In Stock</th><th>Avg. Cost</th><th>Value</th></tr></thead>
              <tbody>
                {valuation.rows.map((r) => (
                  <tr key={r.name}>
                    <td style={{ fontWeight: 600 }}>{r.name}</td>
                    <td>{r.qty} {r.unit}</td>
                    <td>Rs.{r.avgCost.toFixed(2)}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{r.value.toLocaleString('en-IN', { maximumFractionDigits: 0 })}</td>
                  </tr>
                ))}
                {valuation.rows.length === 0 && (
                  <tr><td colSpan={4} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No stock on hand yet.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* EXPIRY REPORT */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-calendar-exclamation" style={{ color: 'var(--red)' }}></i> Expiry Report</div>
              <select className="fi fi-sm" style={{ width: 160 }} value={expiryDays} onChange={(e) => setExpiryDays(e.target.value)}>
                <option value="30">Next 30 days</option>
                <option value="60">Next 60 days</option>
                <option value="90">Next 90 days</option>
                <option value="180">Next 180 days</option>
              </select>
            </div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>Batch</th><th>Expiry Date</th><th>Days Left</th><th>Qty</th></tr></thead>
              <tbody>
                {expiry.map((e) => (
                  <tr key={e.batchNumber + e.expiryDate + e.name}>
                    <td style={{ fontWeight: 600 }}>{e.name}</td>
                    <td>{e.batchNumber || '--'}</td>
                    <td>{new Date(e.expiryDate).toLocaleDateString('en-IN')}</td>
                    <td style={{ color: e.daysLeft <= 30 ? 'var(--red)' : e.daysLeft <= 60 ? 'var(--amber)' : 'inherit', fontWeight: 600 }}>{e.daysLeft} days</td>
                    <td>{e.qty} {e.unit}</td>
                  </tr>
                ))}
                {expiry.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Nothing expiring in this window.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* CONSUMPTION REPORT */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Consumption Report</div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm" type="date" value={consumptionStart} onChange={(e) => setConsumptionStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm" type="date" value={consumptionEnd} onChange={(e) => setConsumptionEnd(e.target.value)} />
              </div>
            </div>
            <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 8 }}>What actually moved off the shelf -- the real signal for how much to reorder.</div>
            <table className="tbl">
              <thead><tr><th>Drug</th><th>Consumed</th></tr></thead>
              <tbody>
                {consumption.map((c) => (
                  <tr key={c.name}>
                    <td style={{ fontWeight: 600 }}>{c.name}</td>
                    <td style={{ fontWeight: 600 }}>{c.consumed} {c.unit}</td>
                  </tr>
                ))}
                {consumption.length === 0 && (
                  <tr><td colSpan={2} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No dispensing recorded in this range.</td></tr>
                )}
              </tbody>
            </table>
          </div>

          {/* VENDOR PURCHASE SUMMARY */}
          <div className="card">
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10, flexWrap: 'wrap', gap: 8 }}>
              <div className="card-title" style={{ marginBottom: 0 }}><i className="ti ti-building-store" style={{ color: 'var(--purple)' }}></i> Vendor Purchase Summary</div>
              <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input className="fi fi-sm" type="date" value={vendorStart} onChange={(e) => setVendorStart(e.target.value)} />
                <span style={{ fontSize: 12, color: 'var(--g400)' }}>to</span>
                <input className="fi fi-sm" type="date" value={vendorEnd} onChange={(e) => setVendorEnd(e.target.value)} />
              </div>
            </div>
            <table className="tbl">
              <thead><tr><th>Vendor</th><th>Bills</th><th>Total</th><th>Paid</th><th>Unpaid</th></tr></thead>
              <tbody>
                {vendorSummary.map((v) => (
                  <tr key={v.name}>
                    <td style={{ fontWeight: 600 }}>{v.name}</td>
                    <td>{v.bills}</td>
                    <td style={{ fontWeight: 600 }}>Rs.{v.total.toLocaleString('en-IN')}</td>
                    <td style={{ color: 'var(--green)' }}>Rs.{v.paid.toLocaleString('en-IN')}</td>
                    <td style={{ color: v.unpaid > 0 ? 'var(--red)' : 'inherit', fontWeight: v.unpaid > 0 ? 600 : 400 }}>Rs.{v.unpaid.toLocaleString('en-IN')}</td>
                  </tr>
                ))}
                {vendorSummary.length === 0 && (
                  <tr><td colSpan={5} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No purchases in this range.</td></tr>
                )}
              </tbody>
            </table>
          </div>
        </>
      )}
    </div>
  );
}
VEDA_EOF_MARKER_9f3a

echo "--- Files written ---"
find "app/(main)/inventory" -type f
echo ""

git add "app/(main)/inventory/actions.js" "app/(main)/inventory/inventory-tabs.js" "app/(main)/inventory/material-input/page.js" "app/(main)/inventory/reports/page.js"

echo "--- Git status ---"
git status
echo ""

git commit -m "Inventory: fix Material Input column widths + move Grand Total under Total column, add Reports tab (Stock Valuation, Expiry, Consumption, Vendor Purchase Summary)"

git push origin main

echo ""
echo "Pushed. Vercel will auto-build main -> both portal.vedaeyehospital.com and training.vedaeyehospital.com."
echo ""
echo "What changed for you:"
echo "  - Material Input: Item column narrower (150px), Batch/Expiry/Qty/"
echo "    Rate/Disc%%/Total all widened -- much less cramped"
echo "  - Grand Total now sits directly below the Total column (reads as"
echo "    the sum of the column above it), separate from the mismatch"
echo "    warning and Save button"
echo "  - New Reports tab with four reports:"
echo "      1. Stock Valuation -- current shelf value, item by item"
echo "      2. Expiry Report -- batches expiring within a chosen window"
echo "         (30/60/90/180 days), nearest first"
echo "      3. Consumption Report -- what actually got dispensed over a"
echo "         date range you pick -- the real signal for reorder qty"
echo "      4. Vendor Purchase Summary -- bills/total/paid/unpaid per"
echo "         vendor over a date range you pick"
