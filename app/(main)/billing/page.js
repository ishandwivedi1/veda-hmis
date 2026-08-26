import BillingTabs from './billing-tabs';
import BillingDashboardClient from './billing-dashboard-client';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus, getPendingPackageBilling } from './actions';

export default async function BillingDashboardPage() {
  const [data, todaysVisitsData, fullyPaidUnbilled] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
    getPendingPackageBilling(),
  ]);
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />
      <BillingDashboardClient
        fullyPaidUnbilled={fullyPaidUnbilled}
        todaysVisits={todaysVisits}
        billingByVisit={billingByVisit}
        todaysInvoices={data.todaysInvoices}
        outstandingInvoices={data.outstandingInvoices}
        outstandingTotal={data.outstandingTotal}
      />
    </div>
  );
}
