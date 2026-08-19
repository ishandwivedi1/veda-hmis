import BillingTabs from './billing-tabs';
import BillingDashboardClient from './billing-dashboard-client';
import { getBillingDashboardData, getTodaysVisitsWithBillingStatus, getDischargedUnbilledSurgeries } from './actions';

export default async function BillingDashboardPage() {
  const [data, todaysVisitsData, dischargedUnbilled] = await Promise.all([
    getBillingDashboardData(),
    getTodaysVisitsWithBillingStatus(),
    getDischargedUnbilledSurgeries(),
  ]);
  const { visits: todaysVisits, billingByVisit } = todaysVisitsData;

  return (
    <div>
      <BillingTabs />
      <BillingDashboardClient
        dischargedUnbilled={dischargedUnbilled}
        todaysVisits={todaysVisits}
        billingByVisit={billingByVisit}
        todaysInvoices={data.todaysInvoices}
        outstandingInvoices={data.outstandingInvoices}
        outstandingTotal={data.outstandingTotal}
      />
    </div>
  );
}
