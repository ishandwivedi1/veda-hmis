import { redirect } from 'next/navigation';

// /billing/optical is now a small multi-page module (see optical-tabs.js)
// -- New Bill, Collect Payment, Advance, History. This index just sends
// staff to the natural starting point.
export default function OpticalShopIndexPage() {
  redirect('/billing/optical/new');
}
