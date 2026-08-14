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
