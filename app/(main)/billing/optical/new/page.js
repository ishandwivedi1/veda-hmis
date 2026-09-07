import BillingTabs from '../../billing-tabs';
import OpticalTabs from '../optical-tabs';
import NewOpticalBillTab from './new-optical-bill-tab';

export default function NewOpticalBillPage() {
  return (
    <div>
      <BillingTabs />
      <OpticalTabs />
      <NewOpticalBillTab />
    </div>
  );
}
