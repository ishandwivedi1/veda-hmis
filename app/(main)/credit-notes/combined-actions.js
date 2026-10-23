'use server';

// One request per click on the Credit Notes screen (speed-up, 23 Oct 2026).
// Before: "Apply to invoices" was one request PER invoice, one after another,
// then two more to reload the note and the list; Void was 1 + 2. Now each
// does the same work (same functions, same order) and returns the refreshed
// note and list in the SAME response.

import { applyCreditNote, voidCreditNote, getCreditNote, searchCreditNotes } from './actions';

async function reload(id, search) {
  const [detail, list] = await Promise.all([
    getCreditNote(id),
    search ? searchCreditNotes(search.query || '', search.status || '', search.dateFrom || '', search.dateTo || '') : Promise.resolve(null),
  ]);
  return { detail, list };
}

// rows: [{ invoiceId, invoiceNumber, amount }] -- applied one by one, in
// order; on the first failure the earlier ones stay applied (as before)
// and the error names that invoice.
export async function applyCreditNoteRowsAndReload(creditNoteId, rows, search) {
  for (const r of rows || []) {
    const res = await applyCreditNote(creditNoteId, r.invoiceId, r.amount);
    if (res?.error) return { error: `${r.invoiceNumber}: ${res.error}`, reloaded: await reload(creditNoteId, search) };
  }
  return { ok: true, reloaded: await reload(creditNoteId, search) };
}

export async function voidCreditNoteAndReload(creditNoteId, reason, search) {
  const res = await voidCreditNote(creditNoteId, reason);
  if (res?.error) return { error: res.error };
  return { ok: true, reloaded: await reload(creditNoteId, search) };
}
