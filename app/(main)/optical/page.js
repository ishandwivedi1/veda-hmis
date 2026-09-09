import { redirect } from 'next/navigation';

// /optical is a small multi-page module (see optical-tabs.js) -- Book
// Spectacles, New Bill, Collect Payment, Advance, Credit Note, Refund,
// Payments, History. This index sends staff to the simplified hub.
export default function OpticalIndexPage() {
  redirect('/optical/book');
}
