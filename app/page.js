import { redirect } from 'next/navigation';
import { getMyDesignation } from '@/app/(main)/users/actions';

export default async function Home() {
  const designation = await getMyDesignation();
  redirect(designation === 'Doctor' ? '/doctor-dashboard' : '/front-office-dashboard');
}

