'use server';

// Combined server calls for New Invoice (speed-up, 27 Sep 2026).
//
// Next.js runs a page's server actions strictly one at a time, so a screen
// that called 3-6 small actions on open waited for each round trip in
// turn. These wrap the SAME existing actions (no query or rule changes)
// and run them in parallel on the server, so the screen pays for one
// round trip instead of several.

import {
  getServiceCatalog,
  getTodaysVisitsForBilling,
  getSurgeryBillingOptions,
  getVisitWithPatient,
  getVisitsForPatient,
  getInvoicesForVisit,
  createInvoiceForVisit,
  addLineItem,
  getInvoiceById,
  markInvestigationOrdersBilled,
  markProceduresBilled,
  markPrescriptionsBilled,
  markBiometryBilled,
  markPackageBilled,
  setManualSurgeryDetails,
  getInvestigationOrdersForBilling,
  getProceduresForBilling,
  getPrescriptionsForBilling,
  getBiometryForBilling,
  getPackageForBilling,
} from './actions';
import { redirect } from 'next/navigation';
import { isTodayOpen, getSuggestedOpeningBalance } from '@/app/(main)/cash-management/actions';

// Everything New Invoice needs before anyone picks a patient.
export async function getNewInvoiceBootstrap() {
  const [catalog, todaysVisits, surgery] = await Promise.all([
    getServiceCatalog(),
    getTodaysVisitsForBilling(),
    getSurgeryBillingOptions(),
  ]);
  return { catalog, todaysVisits, surgery };
}

// A visit plus its patient's other visits and the visit's invoices.
export async function getVisitBillingContext(visitId) {
  const details = await getVisitWithPatient(visitId);
  if (details.error) return { error: details.error };
  const [visits, invResult] = await Promise.all([
    getVisitsForPatient(details.visit.patients.id),
    getInvoicesForVisit(visitId),
  ]);
  return { visit: details.visit, visits, invoices: invResult.invoices || [] };
}

// A patient's visits (newest first) plus the invoices on the newest one.
export async function getPatientBillingContext(patientId) {
  const visits = await getVisitsForPatient(patientId);
  const latest = visits[0] || null;
  const invResult = latest ? await getInvoicesForVisit(latest.id) : { invoices: [] };
  return { visits, invoices: invResult.invoices || [] };
}

// Picking one of today's visits: the patient's visit list and that
// visit's invoices, fetched together.
export async function getPickedVisitContext(patientId, visitId) {
  const [visits, invResult] = await Promise.all([
    getVisitsForPatient(patientId),
    getInvoicesForVisit(visitId),
  ]);
  return { visits, invoices: invResult.invoices || [] };
}

// Finalize / Save Draft in one round trip. Exactly the steps New Invoice
// used to run from the browser, in the same order: create the invoice,
// add each line (strictly one after another -- add_invoice_line_item
// recomputes totals on the live row), flip the source items to Billed,
// save manual surgery details, then return the fresh invoice.
// On a failure returns { error, stage } so the screen can show the same
// message it always did.
export async function commitNewInvoice({ patientId, visitId, purpose, lines, marks, surgery }) {
  const created = await createInvoiceForVisit(patientId, visitId || null, purpose);
  if (created.error) return { error: created.error, stage: 'create' };
  const invoiceId = created.invoice.id;

  for (const line of lines || []) {
    const result = await addLineItem(invoiceId, line.serviceCode, line.qty, line.discType, line.discValue, line.discReason);
    if (result.error) return { error: result.error, stage: 'line', serviceName: line.serviceName, invoiceId };
  }

  const m = marks || {};
  await Promise.all([
    m.invOrderIds?.length ? markInvestigationOrdersBilled(m.invOrderIds, invoiceId) : null,
    m.procIds?.length ? markProceduresBilled(m.procIds, invoiceId) : null,
    m.rxIds?.length ? markPrescriptionsBilled(m.rxIds) : null,
    m.bioIds?.length ? markBiometryBilled(m.bioIds, invoiceId) : null,
    ...(m.pkgCaseIds || []).map((caseId) => markPackageBilled(caseId, invoiceId)),
  ]);

  if (surgery?.name) {
    await setManualSurgeryDetails(invoiceId, surgery.name, surgery.eye, surgery.doctorId);
  }

  const details = await getInvoiceById(invoiceId);
  if (details.error) return { error: details.error, stage: 'reload', invoiceId };
  return { invoice: details.invoice };
}


// ── New Invoice in ONE request (Oct 2026) ──────────────────────────────
// Everything the New Invoice page shows when it opens -- catalog, today's
// visits, surgery options, the day-open bar, and (from the URL) the visit,
// prescribed investigations / procedures / medicines / biometry and the
// surgery package -- gathered in parallel on the server while the page
// renders. Before, the page opened and then the browser fetched these in
// up to 8 separate requests, some waiting on others.
export async function getNewInvoicePageData(p = {}) {
  const ids = (v) => (v ? String(v).split(',').filter(Boolean) : []);
  const inv = ids(p.invOrderIds); const proc = ids(p.procIds); const rx = ids(p.rxIds); const bio = ids(p.bioIds);
  const [bootstrap, visitCtx, invRes, procRes, rxRes, bioRes, pkg, dayOpen] = await Promise.all([
    getNewInvoiceBootstrap(),
    p.visitId ? getVisitBillingContext(p.visitId) : null,
    inv.length ? getInvestigationOrdersForBilling(inv) : null,
    proc.length ? getProceduresForBilling(proc) : null,
    rx.length ? getPrescriptionsForBilling(rx) : null,
    bio.length ? getBiometryForBilling(bio) : null,
    p.pkgCaseId ? getPackageForBilling(p.pkgCaseId) : null,
    isTodayOpen().catch(() => true),
  ]);

  // Surgery billing link (pkgCaseId, no visitId): the patient/visit come
  // from the package's own case -- same rules as the screen used before.
  let pkgContext = null;
  const primary = pkg?.items?.[0];
  const visitOk = visitCtx && !visitCtx.error;
  if (primary?.patient && !visitOk) {
    if (primary.visitId) {
      const c = await getVisitBillingContext(primary.visitId);
      if (!c.error) {
        const same = c.visit.patients?.id === primary.patient.id;
        pkgContext = { patient: c.visit.patients, visit: c.visit, invoices: c.invoices, visits: same ? c.visits : await getVisitsForPatient(primary.patient.id) };
      } else {
        pkgContext = { patient: null, visit: null, invoices: null, visits: await getVisitsForPatient(primary.patient.id) };
      }
    } else {
      pkgContext = { patient: primary.patient, visit: null, invoices: null, visits: await getVisitsForPatient(primary.patient.id) };
    }
  }

  const suggestedOpening = dayOpen ? null : await getSuggestedOpeningBalance().catch(() => null);
  return {
    bootstrap, visitCtx, prefill: { inv: invRes, proc: procRes, rx: rxRes, bio: bioRes }, pkg, pkgContext,
    day: { open: !!dayOpen, suggested: suggestedOpening },
  };
}

// Finalize / Save Draft and open the next screen in the SAME response:
// Finalize -> Collect Payment for this invoice (or the invoice list when
// nothing is due); Save Draft -> Invoice Details. Was the save, then a
// second request to open the next page.
export async function commitNewInvoiceAndOpen(args, { then = 'finalize', patientId, uhid } = {}) {
  const result = await commitNewInvoice(args);
  if (result.error) return result;
  const inv = result.invoice;
  if (then === 'draft') redirect('/billing/details');
  if (Number(inv.net) <= 0) redirect(`/billing/details?q=${encodeURIComponent(uhid || '')}`);
  redirect(`/payments/collect?patientId=${patientId}&invoiceId=${inv.id}`);
}
