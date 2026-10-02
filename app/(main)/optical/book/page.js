// Header: title + back to Optical Dashboard (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import BookSpectaclesTab from './book-spectacles-tab';

export default function BookSpectaclesPage() {
  return (
    <div>
      <OpticalHeader title="Book New Order" back />
      <BookSpectaclesTab />
    </div>
  );
}
