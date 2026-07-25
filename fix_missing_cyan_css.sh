#!/bin/bash
set -e

echo 'Applying: fix missing --cyan CSS variable (invisible Schedule button)...'

cat > 'app/globals.css' << 'GLOBALS_CSS_EOF'
* {
  box-sizing: border-box;
  margin: 0;
  padding: 0;
}

:root {
  --blue: #1d4ed8; --blue-lt: #dbeafe; --blue-dk: #1e3a8a; --blue-mid: #3b82f6;
  --green: #15803d; --green-lt: #dcfce7;
  --red: #b91c1c; --red-lt: #fee2e2;
  --amber: #b45309; --amber-lt: #fef3c7;
  --purple: #7c3aed; --purple-lt: #ede9fe;
  --indigo: #4338ca; --indigo-lt: #e0e7ff;
  --cyan: #0e7490; --cyan-lt: #cffafe;
  --teal: #0f766e; --teal-lt: #ccfbf1;
  --g50: #f9fafb; --g100: #f3f4f6; --g200: #e5e7eb; --g300: #d1d5db;
  --g400: #9ca3af; --g500: #6b7280; --g600: #4b5563; --g700: #374151; --g800: #1f2937; --g900: #111827;
  --r: 8px; --r-lg: 12px;
}

body {
  font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
  background: var(--g50);
  color: var(--g800);
  font-size: 14px;
}

/* ── APP SHELL ── */
.app-layout { display: flex; min-height: 100vh; }
.sidebar { width: 220px; background: #fff; border-right: 1px solid var(--g200); display: flex; flex-direction: column; flex-shrink: 0; }
.sb-logo { display: flex; align-items: center; gap: 10px; padding: 18px 16px; border-bottom: 1px solid var(--g100); }
.sb-logo-icon { width: 34px; height: 34px; border-radius: 8px; background: var(--blue); color: #fff; display: flex; align-items: center; justify-content: center; font-size: 17px; flex-shrink: 0; }
.sb-name { font-weight: 700; font-size: 13px; }
.sb-sub { font-size: 10px; color: var(--g400); }
.sb-sec { padding: 14px 16px 6px; font-size: 10px; font-weight: 700; color: var(--g400); text-transform: uppercase; letter-spacing: .4px; }
.sb-item { display: flex; align-items: center; gap: 10px; padding: 9px 16px; font-size: 13px; color: var(--g600); cursor: pointer; border-left: 3px solid transparent; text-decoration: none; }
.sb-item:hover { background: var(--g50); }
.sb-item.active { background: var(--blue-lt); color: var(--blue-dk); border-left-color: var(--blue); font-weight: 600; }
.sb-icon-wrap { width: 18px; text-align: center; flex-shrink: 0; }
.main-area { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.topbar { background: #fff; border-bottom: 1px solid var(--g200); padding: 12px 24px; display: flex; justify-content: space-between; align-items: center; }
.top-title { font-size: 16px; font-weight: 700; }
.top-sub { font-size: 11px; color: var(--g400); margin-top: 1px; }
.content-area { flex: 1; overflow-y: auto; padding: 24px; }

/* ── CARDS ── */
.card { background: #fff; border: 1px solid var(--g200); border-radius: var(--r-lg); padding: 20px; }
.card-head { display: flex; justify-content: space-between; align-items: center; margin-bottom: 14px; }
.card-title { font-size: 14px; font-weight: 700; display: flex; align-items: center; gap: 7px; }

/* ── BUTTONS ── */
.btn { padding: 9px 16px; border-radius: var(--r); font-size: 13px; font-weight: 600; cursor: pointer; border: 1px solid var(--g200); background: #fff; color: var(--g700); font-family: inherit; transition: all .12s; display: inline-flex; align-items: center; gap: 6px; }
.btn:hover { background: var(--g50); }
.btn:disabled { opacity: .5; cursor: not-allowed; }
.btn-primary { background: var(--blue); color: #fff; border-color: transparent; }
.btn-primary:hover { background: var(--blue-dk); }
.btn-green { background: var(--green); color: #fff; border-color: transparent; }
.btn-sm { padding: 5px 10px; font-size: 11.5px; }

/* ── BADGES ── */
.badge { padding: 2px 10px; border-radius: 12px; font-size: 11px; font-weight: 700; display: inline-flex; align-items: center; gap: 4px; }
.b-blue { background: var(--blue-lt); color: var(--blue); }
.b-green { background: var(--green-lt); color: var(--green); }
.b-amber { background: var(--amber-lt); color: var(--amber); }
.b-red { background: var(--red-lt); color: var(--red); }
.b-gray { background: var(--g100); color: var(--g500); }
.b-purple { background: var(--purple-lt); color: var(--purple); }
.b-indigo { background: var(--indigo-lt); color: var(--indigo); }
.b-cyan { background: var(--cyan-lt); color: var(--cyan); }
.b-teal { background: var(--teal-lt); color: var(--teal); }

/* ── FORMS ── */
.fi { width: 100%; padding: 9px 12px; border: 1.5px solid var(--g200); border-radius: var(--r); font-size: 13px; font-family: inherit; background: #fff; }
.fi:focus { outline: none; border-color: var(--blue); }
.flbl { font-size: 11.5px; font-weight: 600; color: var(--g600); display: block; margin-bottom: 4px; }
.msg-err { background: var(--red-lt); color: var(--red); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-info { background: var(--blue-lt); color: var(--blue-dk); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }
.msg-success { background: var(--green-lt); color: var(--green); padding: 10px 14px; border-radius: var(--r); font-size: 12.5px; margin-bottom: 12px; }

/* ── TABLE ── */
.tbl { width: 100%; border-collapse: collapse; font-size: 12.5px; }
.tbl th { text-align: left; padding: 8px 10px; color: var(--g500); font-weight: 600; font-size: 11px; text-transform: uppercase; letter-spacing: .3px; border-bottom: 1.5px solid var(--g200); }
.tbl td { padding: 9px 10px; border-bottom: 1px solid var(--g100); }

/* ── PRINT ── */
@media print {
  .no-print { display: none !important; }
  body { background: #fff; }
}


GLOBALS_CSS_EOF

echo 'Files written. Running build check...'
npm run build

echo ''
echo 'Build succeeded. Review the changes, then commit:'
echo '  git add "app/globals.css"'
echo '  git commit -m "Fix missing --cyan CSS variable causing invisible buttons in OT Scheduling"'
echo '  git push'
