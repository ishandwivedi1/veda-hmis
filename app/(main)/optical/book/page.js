// Header: title + back to Optical Dashboard (no requests of its own).
// Recent item names are fetched while the page renders on the server, so
// opening Book New Order is ONE request (the page itself).
import { OpticalHeader } from '../optical-ui';
import { getRecentOpticalItemNames } from '../actions';
import BookSpectaclesTab from './book-spectacles-tab';

export const dynamic = 'force-dynamic';

export default async function BookSpectaclesPage() {
  const recentItems = await getRecentOpticalItemNames().catch(() => []);
  return (
    <div>
      <OpticalHeader title="Book New Order" back />
      <BookSpectaclesTab recentItems={recentItems} />
    </div>
  );
}
