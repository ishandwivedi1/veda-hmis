import BillingTabs from '../../billing-tabs';
import OpticalTabs from '../optical-tabs';
import OpticalHistoryTab from './optical-history-tab';

export default function OpticalHistoryPage() {
  return (
    <div>
      <BillingTabs />
      <OpticalTabs />
      <OpticalHistoryTab />
    </div>
  );
}
