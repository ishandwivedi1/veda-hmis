// Header: Bills | Payments | + New (no requests of its own).
import { OpticalHeader } from '../optical-ui';
import BookSpectaclesTab from './book-spectacles-tab';

export default function BookSpectaclesPage() {
  return (
    <div>
      <OpticalHeader title="Book Spectacles" />
      <BookSpectaclesTab />
    </div>
  );
}
