// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import NewOpticalBillTab from './new-optical-bill-tab';

export default function NewOpticalBillPage() {
  return (
    <div>
      <OpticalHeader title="New Bill" />
      <NewOpticalBillTab />
    </div>
  );
}
