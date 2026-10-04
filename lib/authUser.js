// Fast "who is logged in" without a round trip to Supabase Auth.
//
// supabase.auth.getUser() asks the Auth server every time (a full network
// round trip). Where the app only needs the user's id -- to record who
// registered a patient, created a visit, sent a WhatsApp -- the session
// token's signature can be verified locally instead, against Supabase's
// public signing keys (ES256), cached here per server instance. Expired
// tokens are still refreshed with Supabase as before; a tampered token
// fails. If the keys can't be fetched, getClaims() falls back to the old
// getUser() network check by itself.
//
// Also used by middleware.js for the page-navigation login check.

const JWKS_TTL_MS = 10 * 60 * 1000;
let jwksCache = null;
let jwksCachedAt = 0;

// Public keys Supabase signs login tokens with (not secret -- anyone can
// read /.well-known/jwks.json). A token signed with a key not in this list
// (e.g. right after a key rotation) makes getClaims() fetch it itself.
export async function getSigningKeys() {
  if (jwksCache && Date.now() - jwksCachedAt < JWKS_TTL_MS) return jwksCache;
  try {
    const res = await fetch(`${process.env.NEXT_PUBLIC_SUPABASE_URL}/auth/v1/.well-known/jwks.json`, {
      headers: { apikey: process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY },
    });
    if (!res.ok) return jwksCache;
    const body = await res.json();
    if (Array.isArray(body?.keys) && body.keys.length > 0) {
      jwksCache = body.keys;
      jwksCachedAt = Date.now();
    }
  } catch {
    // network hiccup: use what we have (or let getClaims fetch / fall back)
  }
  return jwksCache;
}

// Verified claims of the current session ({ data, error } like getClaims).
export async function getVerifiedClaims(supabase) {
  const keys = await getSigningKeys();
  return supabase.auth.getClaims(undefined, keys ? { keys } : {});
}

// The logged-in user's id, or null. For attribution ("created_by",
// "triggeredBy") -- not a replacement for RLS.
export async function getCurrentUserId(supabase) {
  try {
    const { data } = await getVerifiedClaims(supabase);
    return data?.claims?.sub || null;
  } catch {
    return null;
  }
}

// Drop-in for `supabase.auth.getUser()` where only the user's id is used:
// same { data: { user } } shape, but verified locally instead of a network
// round trip to Supabase Auth on every save. (The database still enforces
// RLS on the session token either way.)
export async function getUserFast(supabase) {
  const id = await getCurrentUserId(supabase);
  return { data: { user: id ? { id } : null }, error: null };
}
