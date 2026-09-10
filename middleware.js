import { createServerClient } from '@supabase/ssr';
import { NextResponse } from 'next/server';

// --- Basic-Auth bot/scanner gate -------------------------------------
// Runs FIRST, before any Supabase call, so anonymous bots/scanners get
// blocked at the edge without costing you a Supabase round-trip or
// counting as real app traffic. Set BASIC_AUTH_USER and
// BASIC_AUTH_PASSWORD as Environment Variables in Vercel (Project ->
// Settings -> Environment Variables) for Production (and Preview, if
// you want training-veda-hmis covered too).
function checkBasicAuth(request) {
  const authHeader = request.headers.get('authorization');

  if (!authHeader || !authHeader.startsWith('Basic ')) {
    return false;
  }

  const base64Credentials = authHeader.split(' ')[1];
  const credentials = Buffer.from(base64Credentials, 'base64').toString('utf-8');
  const [user, password] = credentials.split(':');

  return (
    user === process.env.BASIC_AUTH_USER &&
    password === process.env.BASIC_AUTH_PASSWORD
  );
}

function basicAuthChallenge() {
  return new NextResponse('Authentication required', {
    status: 401,
    headers: { 'WWW-Authenticate': 'Basic realm="Veda HMIS"' },
  });
}
// -----------------------------------------------------------------------

// Must match AppShell.js's client-side timer. This is the real
// enforcement -- the client-side timer only runs while a tab is open,
// so it can't catch "closed the browser and came back 2 hours later"
// (the session cookie is still valid regardless of tab state). This
// check runs server-side on every navigation instead.
const IDLE_TIMEOUT_MS = 30 * 60 * 1000;
// Re-checking last_active_at on literally every request would double
// the DB round-trip on every single page load. A short-lived cookie
// caches "checked recently, still fine" so the actual check only runs
// about once every 2 minutes per person, not on every request.
const IDLE_CHECK_INTERVAL_MS = 2 * 60 * 1000;

export async function middleware(request) {
  // Gate everything behind Basic-Auth before touching Supabase at all.
  if (!checkBasicAuth(request)) {
    return basicAuthChallenge();
  }

  let response = NextResponse.next({
    request: { headers: request.headers },
  });

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY,
    {
      cookies: {
        get(name) {
          return request.cookies.get(name)?.value;
        },
        set(name, value, options) {
          response.cookies.set({ name, value, ...options });
        },
        remove(name, options) {
          response.cookies.set({ name, value: '', ...options });
        },
      },
    }
  );

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const isLoginPage = request.nextUrl.pathname.startsWith('/login');
  const isPublicPage =
    isLoginPage ||
    request.nextUrl.pathname.startsWith('/forgot-password') ||
    request.nextUrl.pathname.startsWith('/reset-password');

  // Not logged in and trying to reach a protected page -> send to login
  if (!user && !isPublicPage) {
    return NextResponse.redirect(new URL('/login', request.url));
  }

  // Server-side idle check -- catches sessions revived from a cookie
  // after the tab/browser was closed, which the client-side timer
  // structurally cannot detect on its own.
  if (user && !isPublicPage) {
    const lastCheckedAt = request.cookies.get('idle_checked_at')?.value;
    const needsCheck = !lastCheckedAt || Date.now() - parseInt(lastCheckedAt, 10) > IDLE_CHECK_INTERVAL_MS;

    if (needsCheck) {
      const { data: profile } = await supabase.from('profiles').select('last_active_at').eq('id', user.id).single();
      const lastActiveMs = profile?.last_active_at ? new Date(profile.last_active_at).getTime() : 0;

      if (Date.now() - lastActiveMs > IDLE_TIMEOUT_MS) {
        response = NextResponse.redirect(new URL('/login?reason=idle', request.url));
        // supabase's cookie `remove` handler above writes onto whatever
        // `response` currently points to -- reassigning it first means
        // signOut()'s cookie-clearing lands on this redirect response.
        await supabase.auth.signOut();
        return response;
      }

      response.cookies.set('idle_checked_at', String(Date.now()), { httpOnly: true, sameSite: 'lax', maxAge: 60 * 60 });
    }
  }

  // Already logged in and looking at the login page -> send to dashboard
  // (but NOT reset-password -- a password-recovery link creates a temporary
  // session, and that person needs to reach reset-password, not get bounced
  // straight to the dashboard before they've actually set a new password)
  if (user && isLoginPage) {
    return NextResponse.redirect(new URL('/dashboard', request.url));
  }

  return response;
}

export const config = {
  matcher: ['/((?!_next/static|_next/image|favicon.ico).*)'],
};
