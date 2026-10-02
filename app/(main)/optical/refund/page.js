// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import OpticalRefundTab from './optical-refund-tab';

export default function OpticalRefundPage() {
  return (
    <div>
      <OpticalHeader title="Refund" />
      <OpticalRefundTab />
    </div>
  );
}
