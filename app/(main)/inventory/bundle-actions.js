'use server';

// Inventory Reports on open in ONE request (was 7: the four reports, then
// three of them again from their filter watchers). Same functions.

import { getStockValuationReport, getExpiryReport, getConsumptionReport, getVendorPurchaseSummary } from './actions';

export async function getInventoryReportsBundle(expiryDays, consumptionStart, consumptionEnd, vendorStart, vendorEnd) {
  return Promise.all([
    getStockValuationReport(),
    getExpiryReport(expiryDays),
    getConsumptionReport(consumptionStart, consumptionEnd),
    getVendorPurchaseSummary(vendorStart, vendorEnd),
  ]);
}
