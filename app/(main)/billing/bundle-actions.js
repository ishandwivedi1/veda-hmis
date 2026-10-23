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
