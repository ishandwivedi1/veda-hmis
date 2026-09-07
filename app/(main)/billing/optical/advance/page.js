import BillingTabs from '../../billing-tabs';
import OpticalTabs from '../optical-tabs';
import OpticalAdvanceTab from './optical-advance-tab';

export default function OpticalAdvancePage() {
  return (
    <div>
      <BillingTabs />
      <OpticalTabs />
      <OpticalAdvanceTab />
    </div>
  );
}
