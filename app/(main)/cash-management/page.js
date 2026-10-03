import CashManagementClient from './cash-management-client';
import { getCashScreen } from './screen-actions';

// Server Component: the whole Cash Management screen (collections, day
// status, reconciliation, Cash Counter, expenses, history, approvers) is
// gathered here, in parallel, BEFORE the page is sent -- the page opens
// in ONE request and the browser does not fetch it all again afterwards.
// Every save on the page sends back the refreshed screen in its own
// response (see screen-actions.js).
export default async function CashManagementPage() {
  const initialData = await getCashScreen();
  return <CashManagementClient initialData={initialData} />;
}
