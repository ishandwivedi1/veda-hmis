// Server side of parallel reads (see lib/rpcClient.js).
//
// Runs one of the allow-listed READ-ONLY functions in ./registry.js --
// the exact same functions the screens used to call as server actions,
// with the same user session (cookies) and the same database rules (RLS).
// Anything not in the registry is refused. Saves never come through here.

import { NextResponse } from 'next/server';
import { READS } from '../registry';
import { encode, decode } from '@/lib/rpcCodec';

export const dynamic = 'force-dynamic';

export async function POST(request, { params }) {
  const { name } = await params;
  const fn = Object.prototype.hasOwnProperty.call(READS, name) ? READS[name] : null;
  if (!fn) return NextResponse.json({ error: 'Unknown function' }, { status: 404 });

  // Same-origin only (server actions enforce the same check).
  const origin = request.headers.get('origin');
  const host = request.headers.get('x-forwarded-host') || request.headers.get('host');
  if (origin && host && new URL(origin).host !== host) {
    return NextResponse.json({ error: 'Forbidden' }, { status: 403 });
  }

  let args;
  try {
    args = decode(await request.json());
    if (!Array.isArray(args)) throw new Error('bad args');
  } catch {
    return NextResponse.json({ error: 'Bad request' }, { status: 400 });
  }

  try {
    const result = await fn(...args);
    return NextResponse.json({ r: encode(result) }, { headers: { 'cache-control': 'no-store' } });
  } catch (e) {
    console.error(`[rpc] ${name} failed:`, e);
    return NextResponse.json({ error: 'Something went wrong loading data -- try again.' }, { status: 500 });
  }
}
