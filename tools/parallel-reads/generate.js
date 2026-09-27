// Parallel reads generator.
//
// WHY: Next.js runs a page's server actions one at a time. This finds every
// exported server action that only READS (no insert/update/delete, no
// write-type rpc, no storage/external calls, no redirects -- checked through
// every helper it calls, across files) and whose name starts with
// get/search/list/fetch/load/count/is/has/find/lookup, then:
//   1. writes app/api/rpc/registry.js   -- the allow-list the /api/rpc route runs
//   2. writes lib/rpc-reads/*.js        -- browser wrappers (fetch, runs in parallel)
//   3. rewrites 'use client' files to import those reads from lib/rpc-reads
// Saves are left as server actions (their order matters).
//
// Run after adding or changing server actions:
//   npm i --prefix /tmp/ts5 typescript@5
//   TS5=/tmp/ts5/node_modules/typescript node tools/parallel-reads/generate.js
// Add --check to only report what would change (exit code 1 if anything).

// Needs the TypeScript 5 JS API (the project's own TypeScript 7 has none).
const ts = require(process.env.TS5 || 'typescript');
if (!ts.createSourceFile) { console.error('Set TS5 to a TypeScript 5 install, e.g.\n  npm i --prefix /tmp/ts5 typescript@5 && TS5=/tmp/ts5/node_modules/typescript node tools/parallel-reads/generate.js'); process.exit(3); }
const fs = require('fs'); const path = require('path');
const ROOT = path.resolve(__dirname, '../..');
const walk = (d) => fs.readdirSync(d, { withFileTypes: true }).flatMap((e) => {
  const p = path.join(d, e.name);
  if (e.isDirectory()) return e.name === 'node_modules' || e.name.startsWith('.') ? [] : walk(p);
  return /\.(js|jsx)$/.test(e.name) ? [p] : [];
});
const files = [...walk(ROOT + '/app'), ...walk(ROOT + '/lib')];
const isServer = (src) => /^\s*(['"])use server\1/.test(src);
const isClient = (src) => /^\s*(['"])use client\1/.test(src);

function resolveImport(from, spec) {
  let base;
  if (spec.startsWith('@/')) base = path.join(ROOT, spec.slice(2));
  else if (spec.startsWith('.')) base = path.resolve(path.dirname(from), spec);
  else return null;
  for (const c of [base, base + '.js', base + '.jsx', base + '/index.js']) if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  return null;
}

const mods = {}; // file -> { fns: {name: {text, calls:[], exported}}, imports: {local: {file, name}} }
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  if (!isServer(src) && !f.startsWith(ROOT + '/lib/')) continue;
  const sf = ts.createSourceFile(f, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.JSX);
  const m = { server: isServer(src), fns: {}, imports: {} };
  sf.statements.forEach((st) => {
    if (ts.isImportDeclaration(st) && st.importClause) {
      const target = resolveImport(f, st.moduleSpecifier.text);
      const nb = st.importClause.namedBindings;
      if (nb && ts.isNamedImports(nb)) nb.elements.forEach((el) => {
        m.imports[el.name.text] = { file: target, name: (el.propertyName || el.name).text, spec: st.moduleSpecifier.text };
      });
      if (st.importClause.name) m.imports[st.importClause.name.text] = { file: target, name: 'default', spec: st.moduleSpecifier.text };
    }
    const exported = !!(st.modifiers || []).find((x) => x.kind === ts.SyntaxKind.ExportKeyword);
    if (ts.isFunctionDeclaration(st) && st.name) {
      m.fns[st.name.text] = { text: st.getText(sf), exported, node: st };
    } else if (ts.isVariableStatement(st)) {
      st.declarationList.declarations.forEach((d) => {
        if (d.initializer && (ts.isArrowFunction(d.initializer) || ts.isFunctionExpression(d.initializer)))
          m.fns[d.name.getText(sf)] = { text: d.getText(sf), exported, node: d };
      });
    }
  });
  // identifiers called in each fn
  for (const [n, fn] of Object.entries(m.fns)) {
    const calls = new Set();
    const visit = (node) => { if (ts.isCallExpression(node) && ts.isIdentifier(node.expression)) calls.add(node.expression.text); ts.forEachChild(node, visit); };
    visit(fn.node); fn.calls = [...calls]; delete fn.node;
  }
  mods[f] = m;
}

const READ_RPC = /\.rpc\(\s*['"](get_|search_|list_|count_|billing_reconciliation|has_billing_permission|is_)/;
const WRITE_RE = [
  /\.(insert|update|upsert|delete)\s*\(/, /revalidate(Path|Tag)\s*\(/, /\bredirect\s*\(/, /\bnotFound\s*\(/,
  /\bafter\s*\(/, /createAdminClient/, /\.storage\b/, /\bfetch\s*\(/, /auth\.(signOut|admin|signIn|updateUser|resetPassword)/,
  /cookies\(\)/, /\bheaders\(\)/, /process\.env\.(?!NEXT_PUBLIC)/, /puppeteer|chromium/,
];
const NAME_RE = /^(get|search|list|fetch|load|count|is|has|find|lookup)[A-Z_]/;

const memo = {};
function fnVerdict(file, name, stack = []) {
  const key = file + '#' + name;
  if (key in memo) return memo[key];
  if (stack.includes(key)) return { ok: true };
  const m = mods[file];
  if (!m || !m.fns[name]) return (memo[key] = { ok: false, why: `unknown ${path.relative(ROOT, file || '?')}#${name}` });
  const fn = m.fns[name];
  let text = fn.text;
  // rpc calls: allow read-only ones, reject others
  const rpcs = [...text.matchAll(/\.rpc\(\s*['"]([a-z0-9_]+)/g)].map((x) => x[1]);
  for (const r of rpcs) if (!READ_RPC.test(`.rpc('${r}`)) return (memo[key] = { ok: false, why: `rpc ${r}` });
  for (const re of WRITE_RE) if (re.test(text)) return (memo[key] = { ok: false, why: `matches ${re}` });
  for (const c of fn.calls) {
    if (m.fns[c]) { const v = fnVerdict(file, c, [...stack, key]); if (!v.ok) return (memo[key] = { ok: false, why: `${c} -> ${v.why}` }); continue; }
    const imp = m.imports[c];
    if (imp) {
      if (!imp.file) continue; // package import (e.g. formatting helpers)
      if (['createClient'].includes(c) && /supabase-server/.test(imp.spec)) continue;
      const v = fnVerdict(imp.file, imp.name, [...stack, key]);
      if (!v.ok) return (memo[key] = { ok: false, why: `${c} -> ${v.why}` });
    }
  }
  return (memo[key] = { ok: true });
}


const CHECK = process.argv.includes('--check');
const rel = (f) => path.relative(ROOT, f).split(path.sep).join('/');
const modKey = (r) => r.replace(/^app\//, '').replace(/\(main\)\//, '').replace(/\.js$/, '').split('/').join('.');
const fileKey = (k) => k.split('.').join('__');
const READS_DIR = path.join(ROOT, 'lib/rpc-reads');
const PUBLIC_DIRS = ['app/login/', 'app/forgot-password/', 'app/reset-password/'];

const reads = {}; // rel file -> [names]
for (const [f, m] of Object.entries(mods)) {
  if (!m.server) continue;
  for (const [n, fn] of Object.entries(m.fns)) {
    if (fn.exported && NAME_RE.test(n) && fnVerdict(f, n).ok) (reads[rel(f)] ||= []).push(n);
  }
}
const readsByKey = Object.fromEntries(Object.entries(reads).map(([r, l]) => [modKey(r), { rel: r, names: new Set(l) }]));

// Which reads the browser actually uses (both original and already-rewritten imports).
const used = {}; // modKey -> Set(names)
const edits = []; // { file, newText }
for (const f of files) {
  const src = fs.readFileSync(f, 'utf8');
  if (!isClient(src)) continue;
  // Pages used before/without a session keep plain server actions (the
  // /api/rpc route answers 401 without a session cookie).
  if (PUBLIC_DIRS.some((d) => rel(f).startsWith(d))) continue;
  const sf = ts.createSourceFile(f, src, ts.ScriptTarget.Latest, true, ts.ScriptKind.JSX);
  const replacements = [];
  sf.statements.forEach((st) => {
    if (!ts.isImportDeclaration(st) || !st.importClause) return;
    const spec = st.moduleSpecifier.text;
    const nb = st.importClause.namedBindings;
    if (!nb || !ts.isNamedImports(nb)) return;
    const already = spec.match(/^@\/lib\/rpc-reads\/(.+)$/);
    if (already) {
      const key = already[1].split('__').join('.');
      nb.elements.forEach((el) => (used[key] ||= new Set()).add((el.propertyName || el.name).text));
      return;
    }
    const target = resolveImport(f, spec);
    if (!target) return;
    const key = modKey(rel(target));
    const info = readsByKey[key];
    if (!info) return;
    const keep = [], move = [];
    nb.elements.forEach((el) => {
      const orig = (el.propertyName || el.name).text;
      (info.names.has(orig) && !el.isTypeOnly ? move : keep).push(el.getText(sf));
      if (info.names.has(orig)) (used[key] ||= new Set()).add(orig);
    });
    if (!move.length) return;
    const q = st.moduleSpecifier.getText(sf)[0];
    const lines = [];
    if (keep.length || st.importClause.name) {
      const def = st.importClause.name ? st.importClause.name.text + (keep.length ? ', ' : '') : '';
      lines.push(`import ${def}${keep.length ? `{ ${keep.join(', ')} }` : ''} from ${q}${spec}${q};`);
    }
    lines.push(`import { ${move.join(', ')} } from ${q}@/lib/rpc-reads/${fileKey(key)}${q}; // parallel reads (tools/parallel-reads)`);
    replacements.push({ start: st.getStart(sf), end: st.getEnd(), text: lines.join('\n') });
  });
  if (replacements.length) {
    let out = src;
    for (const r of replacements.sort((a, b) => b.start - a.start)) out = out.slice(0, r.start) + r.text + out.slice(r.end);
    edits.push({ file: f, newText: out });
  }
}

// Drop names that are no longer reads (e.g. a function started writing).
const stale = [];
for (const [key, set] of Object.entries(used)) for (const n of set) {
  if (!readsByKey[key] || !readsByKey[key].names.has(n)) stale.push(`${key}.${n}`);
}
if (stale.length) {
  console.error('These are imported from lib/rpc-reads but are no longer read-only -- switch those imports back to the actions file:\n  ' + stale.join('\n  '));
  process.exit(2);
}

const keys = Object.keys(used).sort();
const registry = [
  '// GENERATED by tools/parallel-reads/generate.js -- do not edit by hand.',
  '// Allow-list of read-only server functions the /api/rpc route may run.',
  '',
  ...keys.map((k, i) => `import * as m${i} from '@/${readsByKey[k].rel.replace(/\.js$/, '')}';`),
  '',
  'export const READS = {',
  ...keys.flatMap((k, i) => [...used[k]].sort().map((n) => `  '${k}.${n}': m${i}.${n},`)),
  '};',
  '',
].join('\n');

const wrappers = Object.fromEntries(keys.map((k) => [path.join(READS_DIR, fileKey(k) + '.js'), [
  '// GENERATED by tools/parallel-reads/generate.js -- do not edit by hand.',
  `// Browser wrappers for read-only functions in ${readsByKey[k].rel}.`,
  "import { rpcCall } from '@/lib/rpcClient';",
  '',
  ...[...used[k]].sort().map((n) => `export const ${n} = (...args) => rpcCall('${k}.${n}', args);`),
  '',
].join('\n')]));

const outputs = { [path.join(ROOT, 'app/api/rpc/registry.js')]: registry, ...wrappers };
const changed = [];
for (const [f, text] of Object.entries(outputs)) if (!fs.existsSync(f) || fs.readFileSync(f, 'utf8') !== text) changed.push(f);
for (const e of edits) changed.push(e.file);
const existingWrappers = fs.existsSync(READS_DIR) ? fs.readdirSync(READS_DIR).map((x) => path.join(READS_DIR, x)) : [];
const orphanWrappers = existingWrappers.filter((f) => !(f in outputs));

if (CHECK) {
  if (changed.length || orphanWrappers.length) { console.log('Out of date:\n  ' + [...changed, ...orphanWrappers].map(rel).join('\n  ')); process.exit(1); }
  console.log('Parallel reads up to date.'); process.exit(0);
}
fs.mkdirSync(READS_DIR, { recursive: true });
for (const [f, text] of Object.entries(outputs)) fs.writeFileSync(f, text);
for (const e of edits) fs.writeFileSync(e.file, e.newText);
for (const f of orphanWrappers) fs.unlinkSync(f);
console.log(`reads in registry: ${keys.reduce((s, k) => s + used[k].size, 0)} from ${keys.length} modules; client files rewritten: ${edits.length}`);
