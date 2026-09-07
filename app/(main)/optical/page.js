import { redirect } from 'next/navigation';

// /optical is a small multi-page module (see optical-tabs.js) -- New
// Bill, Collect Payment, Advance, History. This index just sends staff
// to the natural starting point.
export default function OpticalIndexPage() {
  redirect('/optical/new');
}
