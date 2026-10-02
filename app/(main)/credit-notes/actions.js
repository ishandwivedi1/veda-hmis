'use server';

// Credit Notes (Zoho-style, 2 Oct 2026). A credit note is a document with
// items and a credit balance that is applied to the patient's unpaid
// invoices. All money changes go through Postgres: cn_create, cn_apply,
// cn_void (migration 045).

import { createClient } from '@/lib/supabase-server';

const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;

function withBalance(cn) {
  const applied = r2((cn.credit_note_applications || []).reduce((s, a) => s + Number(a.amount), 0));
  return { ...cn, applied, balance: cn.status === 'Void' ? 0 : r2(Number(cn.amount) - applied) };
}

export async function searchCreditNotes(query, status, dateFrom, dateTo) {
  const supabase = await createClient();
  let q = supabase
    .from('credit_notes')
    .select('id, credit_note_number, created_at, amount, status, reason, patient_id, invoice_id, patients(first_name, salutation, last_name, uhid), invoices(invoice_number), credit_note_applications(amount)')
    .order('created_at', { ascending: false });
  if (dateFrom) q = q.gte('created_at', `${dateFrom}T00:00:00+05:30`);
  if (dateTo) q = q.lte('created_at', `${dateTo}T23:59:59+05:30`);
  if (status) q = q.eq('status', status);
  if (!dateFrom && !dateTo && !query) q = q.limit(100); else q = q.limit(1000);
  if (query) {
    const { data: matches } = await supabase.from('patients').select('id')
      .or(`uhid.ilike.%${query}%,first_name.ilike.%${query}%,last_name.ilike.%${query}%`);
    const ids = (matches || []).map((p) => p.id);
    q = q.or(`credit_note_number.ilike.%${query}%${ids.length ? `,patient_id.in.(${ids.join(',')})` : ''}`);
  }
  const { data } = await q;
  return (data || []).map(withBalance);
}

export async function getCreditNote(id) {
  const supabase = await createClient();
  const { data: cn, error } = await supabase
    .from('credit_notes')
    .select('*, patients(id, first_name, salutation, last_name, uhid, mobile), invoices(id, invoice_number, created_at), credit_note_items(*), credit_note_applications(id, amount, applied_at, invoice_id, payment_id, invoices(invoice_number), payments(receipt_number))')
    .eq('id', id)
    .single();
  if (error) return { error: error.message };

  const ids = [cn.approved_by, cn.created_by, cn.voided_by].filter(Boolean);
  const { data: people } = ids.length ? await supabase.from('profiles').select('id, full_name').in('id', ids) : { data: [] };
  const name = (pid) => (people || []).find((p) => p.id === pid)?.full_name || null;

  // Unpaid invoices of this patient, for "Apply to invoices".
  const { data: open } = await supabase
    .from('invoices')
    .select('id, invoice_number, created_at, net, paid, status')
    .eq('patient_id', cn.patient_id)
    .in('status', ['Pending', 'Partial'])
    .order('created_at', { ascending: true });

  const full = withBalance(cn);
  return {
    creditNote: {
      ...full,
      credit_note_items: (cn.credit_note_items || []).sort((a, b) => a.sort_order - b.sort_order),
      credit_note_applications: (cn.credit_note_applications || []).sort((a, b) => new Date(a.applied_at) - new Date(b.applied_at)),
    },
    approvedByName: name(cn.approved_by),
    createdByName: name(cn.created_by),
    voidedByName: name(cn.voided_by),
    openInvoices: (open || []).map((i) => ({ ...i, due: r2(Number(i.net) - Number(i.paid)) })).filter((i) => i.due > 0),
  };
}

// Open credit notes with balance, for an invoice's "Credits available".
export async function getOpenCreditNotesForPatient(patientId) {
  const supabase = await createClient();
  const { data } = await supabase
    .from('credit_notes')
    .select('id, credit_note_number, created_at, amount, status, credit_note_applications(amount)')
    .eq('patient_id', patientId)
    .eq('status', 'Open')
    .order('created_at', { ascending: true });
  return (data || []).map(withBalance).filter((c) => c.balance > 0);
}

// New Credit Note form: the patient's invoices (non-void) and, if an
// invoice is chosen, its lines and how much credit it can still take.
export async function getCreditNoteFormData(patientId, invoiceId) {
  const supabase = await createClient();
  const [{ data: patient }, { data: invoices }, { data: approvers }] = await Promise.all([
    patientId
      ? supabase.from('patients').select('id, uhid, first_name, salutation, last_name, mobile').eq('id', patientId).maybeSingle()
      : Promise.resolve({ data: null }),
    patientId
      ? supabase.from('invoices').select('id, invoice_number, created_at, net, paid, status').eq('patient_id', patientId).neq('status', 'Cancelled').order('created_at', { ascending: false })
      : Promise.resolve({ data: [] }),
    supabase.from('profiles').select('id, full_name, designation').eq('status', 'Active').order('full_name'),
  ]);

  let lines = [];
  let creditedSoFar = 0;
  if (invoiceId) {
    const [{ data: li }, { data: prior }] = await Promise.all([
      supabase.from('invoice_line_items').select('id, service_name, dept, qty, rate, disc, net').eq('invoice_id', invoiceId).order('id'),
      supabase.from('credit_notes').select('amount').eq('invoice_id', invoiceId).neq('status', 'Void'),
    ]);
    lines = li || [];
    creditedSoFar = r2((prior || []).reduce((s, c) => s + Number(c.amount), 0));
  }
  return { patient, invoices: invoices || [], approvers: approvers || [], lines, creditedSoFar };
}

export async function searchPatientsForCreditNote(query) {
  const supabase = await createClient();
  const q = (query || '').trim();
  if (q.length < 2) return [];
  const { data } = await supabase.from('patients').select('id, uhid, first_name, salutation, last_name, mobile')
    .or(`uhid.ilike.%${q}%,first_name.ilike.%${q}%,last_name.ilike.%${q}%,mobile.ilike.%${q}%`).limit(15);
  return data || [];
}

export async function createCreditNote({ patientId, invoiceId, items, reason, approvedBy, remarks, applyAmount }) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('cn_create', {
    p_patient_id: patientId,
    p_invoice_id: invoiceId,
    p_items: items,
    p_reason: reason,
    p_approved_by: approvedBy || null,
    p_remarks: remarks || null,
    p_apply_amount: Number(applyAmount) || 0,
  });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function applyCreditNote(creditNoteId, invoiceId, amount) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('cn_apply', { p_credit_note_id: creditNoteId, p_invoice_id: invoiceId, p_amount: Number(amount) });
  if (error) return { error: error.message };
  return { creditNote: data };
}

export async function voidCreditNote(creditNoteId, reason) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('cn_void', { p_credit_note_id: creditNoteId, p_reason: reason });
  if (error) return { error: error.message };
  return { creditNote: data };
}
