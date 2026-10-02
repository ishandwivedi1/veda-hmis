import { Suspense } from 'react';
import BillingTabs from './billing-tabs';
import InvoicesScreen from './invoices/invoices-screen';
import { getTodaysVisitsWithBillingStatus, getPendingPackageBilling } from './actions';

// Billing is one Zoho-style Invoices screen (2 Oct 2026): summary strip,
// the "To bill" work lists, the invoice list and a split view to open,
// edit, collect, print or WhatsApp an invoice. The old dashboard and tab
// bar (Dashboard / Invoice Details / Invoice Modification) were retired.
export default async function BillingPage() {
  const [todaysVisitsData, fullyPaidUnbilled] = await Promise.all([
    getTodaysVisitsWithBillingStatus(),
    getPendingPackageBilling(),
  ]);
  return (
    <div>
      <BillingTabs />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <InvoicesScreen
          fullyPaidUnbilled={fullyPaidUnbilled || []}
          todaysVisits={todaysVisitsData?.visits || []}
          billingByVisit={todaysVisitsData?.billingByVisit || {}}
        />
      </Suspense>
    </div>
  );
}
