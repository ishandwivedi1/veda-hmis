import { createClient } from '@supabase/supabase-js';

// This client uses the SERVICE ROLE key -- it bypasses all security
// rules and can do anything (including creating logins for other
// people). It must NEVER be imported into a Client Component or
// anything that runs in the browser -- only inside 'use server'
// actions, which always run on the server and never ship this code
// (or the key) to the browser.
export function createAdminClient() {
  return createClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.SUPABASE_SERVICE_ROLE_KEY,
    { auth: { autoRefreshToken: false, persistSession: false } }
  );
}

