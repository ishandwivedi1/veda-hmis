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
