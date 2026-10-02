// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import OpticalAdvanceTab from './optical-advance-tab';

export default function OpticalAdvancePage() {
  return (
    <div>
      <OpticalHeader title="Advance" />
      <OpticalAdvanceTab />
    </div>
  );
}
