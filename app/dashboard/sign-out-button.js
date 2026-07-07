'use client';

import { useRouter } from 'next/navigation';
import { createClient } from '../../lib/supabase-browser';

export default function SignOutButton() {
  const router = useRouter();
  const supabase = createClient();

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  return (
    <button className="btn" onClick={handleSignOut}>
      Sign out
    </button>
  );
}
