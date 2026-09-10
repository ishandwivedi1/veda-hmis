import { redirect } from 'next/navigation';

// /optical is a small multi-page module (see optical-tabs.js) --
// Dashboard, Book Spectacles, New Bill, Collect Payment, Advance,
// Credit Note, Refund, Payments, History. This index sends staff to
// the shop-wide overview.
export default function OpticalIndexPage() {
  redirect('/optical/dashboard');
}
