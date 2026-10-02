import { redirect } from 'next/navigation';

// The old Optical Dashboard tab was folded into the Bills screen (summary,
// outstanding, bookings awaiting delivery) in Oct 2026.
export default function OpticalDashboardPage() {
  redirect('/optical');
}
