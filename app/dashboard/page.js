import { redirect } from 'next/navigation';
import { getMyDesignation } from '@/app/(main)/users/actions';

// Not a route this app normally links to -- exists purely because
// something (a stale bookmark, an old cached client-side router
// state from before this app's routing was finalized, etc.) keeps
// reaching for /dashboard specifically and 404ing here. Cheaper and
// safer to just make it work than to fully track down the exact
// client-side mechanism sending it here.
export default async function DashboardRedirect() {
  const designation = await getMyDesignation();
  redirect(designation === 'Doctor' ? '/doctor-dashboard' : '/front-office-dashboard');
}
