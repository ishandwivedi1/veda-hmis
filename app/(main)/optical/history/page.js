import { redirect } from 'next/navigation';

// Bills History is now the Bills screen itself (search, status, dates).
export default function OpticalHistoryPage() {
  redirect('/optical');
}
