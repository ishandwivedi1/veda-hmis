// Encoding for the parallel-reads route (/api/rpc). Plain JSON would
// silently turn undefined into null (breaking default parameters) and
// Dates into strings; server actions preserve both, so this does too.
// Shared by the browser (lib/rpcClient.js) and the route handler.

const TAG = '$rpc';

export function encode(v) {
  if (v === undefined) return { [TAG]: 'u' };
  if (typeof v === 'number') {
    if (Number.isNaN(v)) return { [TAG]: 'n', v: 'NaN' };
    if (!Number.isFinite(v)) return { [TAG]: 'n', v: v > 0 ? 'Inf' : '-Inf' };
    return v;
  }
  if (typeof v === 'bigint') return { [TAG]: 'b', v: v.toString() };
  if (v === null || typeof v !== 'object') return v;
  if (v instanceof Date) return { [TAG]: 'd', v: Number.isNaN(v.getTime()) ? null : v.toISOString() };
  if (Array.isArray(v)) return v.map(encode);
  if (v instanceof Map) return { [TAG]: 'm', v: [...v].map(([k, x]) => [encode(k), encode(x)]) };
  if (v instanceof Set) return { [TAG]: 's', v: [...v].map(encode) };
  const out = {};
  for (const k of Object.keys(v)) out[k] = encode(v[k]);
  // An ordinary object that happens to use our tag key is wrapped so it
  // is never mistaken for an encoded value.
  return TAG in v ? { [TAG]: 'o', v: out } : out;
}

export function decode(v) {
  if (v === null || typeof v !== 'object') return v;
  if (Array.isArray(v)) return v.map(decode);
  if (TAG in v) {
    switch (v[TAG]) {
      case 'u': return undefined;
      case 'n': return v.v === 'NaN' ? NaN : v.v === 'Inf' ? Infinity : -Infinity;
      case 'b': return BigInt(v.v);
      case 'd': return v.v === null ? new Date(NaN) : new Date(v.v);
      case 'm': return new Map(v.v.map(([k, x]) => [decode(k), decode(x)]));
      case 's': return new Set(v.v.map(decode));
      case 'o': { const o = {}; for (const k of Object.keys(v.v)) o[k] = decode(v.v[k]); return o; }
      default: break;
    }
  }
  const out = {};
  for (const k of Object.keys(v)) {
    const d = decode(v[k]);
    // keep "key present but undefined", like server actions do
    out[k] = d;
  }
  return out;
}
