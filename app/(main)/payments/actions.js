'use server';

import { createClient } from '@/lib/supabase-server';

export async function searchPatientsForPayment(q) {
  if (!q) return [];
  const supabase = await createClient();
  const { data } = await supabase
    .from('patients')
    .select('id, uhid, first_name, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

export async function getOutstandingInvoices(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('invoices')
    .select('id, invoice_number, net, paid, status, created_at')
    .eq('patient_id', patientId)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true }); // oldest first, matches allocation order
  return data || [];
}

// ── ADVANCE ──
export async function getAdvanceBalance(patientId) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('get_advance_balance', { p_patient_id: patientId });
  if (error) return 0;
  return data || 0;
}

export async function collectAdvance(patientId, advanceType, amount, modes, reference, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_advance', {
    p_patient_id: patientId,
    p_advance_type: advanceType,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}

export async function getCurrentBalancesByPatient() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('patient_id, amount, patients(first_name, last_name, uhid)');
  if (!data) return [];

  const byPatient = {};
  data.forEach((entry) => {
    if (!byPatient[entry.patient_id]) {
      byPatient[entry.patient_id] = { patient: entry.patients, balance: 0 };
    }
    byPatient[entry.patient_id].balance += Number(entry.amount);
  });
  return Object.values(byPatient).filter((p) => p.balance > 0);
}

export async function getLedgerHistory() {
  const supabase = await createClient();
  const { data } = await supabase
    .from('patient_ledger')
    .select('*, patients(first_name, last_name, uhid), payments(mode:payment_modes(mode, amount), reference)')
    .order('recorded_at', { ascending: false })
    .limit(30);
  return data || [];
}
export async function collectPayment(patientId, invoiceIds, amount, modes, reference, remarks) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('collect_payment', {
    p_patient_id: patientId,
    p_invoice_ids: invoiceIds,
    p_amount: amount,
    p_modes: modes,
    p_reference: reference || null,
    p_remarks: remarks || null,
  });
  if (error) return { error: error.message };
  return { payment: data };
}

