'use server';

// Pending Billing widget's ONE request: the four pending lists run in
// parallel on the server (was 4 requests). Functions are unchanged.

import { getPendingInvestigationBilling } from '@/app/(main)/investigation/actions';
import { getPendingProcedureBilling } from './actions';
import { getPendingPrescriptionsForFrontOffice } from '@/app/(main)/pharmacy/actions';
import { getPendingBiometryBilling } from '@/app/(main)/biometry/actions';

export async function getPendingBillingBundle(opts) {
  return Promise.all([
    getPendingInvestigationBilling(opts),
    getPendingProcedureBilling(opts),
    getPendingPrescriptionsForFrontOffice(opts),
    getPendingBiometryBilling(opts),
  ]);
}

// Invoice Modification tab on open: today's invoices + surgery billing
// options in ONE request (was 2).
import { getTodaysInvoicesForModification, getSurgeryBillingOptions } from './actions';
export async function getInvoiceModificationBundle() {
  return Promise.all([getTodaysInvoicesForModification(), getSurgeryBillingOptions()]);
}

// Invoice Modification -> Save surgery billing details: the save plus the
// refreshed invoice in ONE request (was save, then a separate reload).
import { setManualSurgeryDetails, getInvoiceById } from './actions';
export async function saveSurgeryDetailsAndReloadInvoice(invoiceId, surgeryName, surgeryEye, surgeonId) {
  const result = (await setManualSurgeryDetails(invoiceId, surgeryName, surgeryEye, surgeonId)) || {};
  if (result.error) return result;
  return { ...result, details: await getInvoiceById(invoiceId) };
}
