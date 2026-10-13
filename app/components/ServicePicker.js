'use client';

// Type-to-search service picker that is ALSO a dropdown (Oct 2026 request
// from billing staff: medicines were slow to find in a plain dropdown).
//   * Click the box or the ▾ arrow -> the full list opens, like before.
//   * Type any part of the name (e.g. "moxi", "drop 5") -> the list narrows
//     as you type; ↑ / ↓ to move, Enter to pick, Esc to close.
//   * With no department chosen it searches every department and shows
//     which department each item belongs to (onPick gets the full item, so
//     the caller can fill the department in).
// No requests of its own -- it filters the list it is given.

import { useState, useRef, useEffect, useMemo } from 'react';

const norm = (s) => String(s || '').toLowerCase().replace(/\s+/g, ' ').trim();

export default function ServicePicker({
  services = [], value = '', onPick, disabled = false, placeholder = 'Type to search or pick from the list...',
  showDept = false, showRate = false, small = false, style,
}) {
  const selected = services.find((s) => s.code === value) || null;
  const [text, setText] = useState(selected ? selected.name : '');
  const [open, setOpen] = useState(false);
  const [hi, setHi] = useState(0);
  const boxRef = useRef(null);
  const listRef = useRef(null);
  const [typed, setTyped] = useState(false); // true once the user types (filter on); false = show the full list

  // Keep the box in step with the chosen value (e.g. cleared after "Add").
  // (Skipped when the change came from typing here -- clearing the choice
  // while the user types must not wipe what they are typing.)
  const fromTypingRef = useRef(false);
  useEffect(() => {
    if (fromTypingRef.current) { fromTypingRef.current = false; return; }
    setText(selected ? selected.name : ''); setTyped(false);
  }, [value]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!open) return undefined;
    const close = (e) => { if (boxRef.current && !boxRef.current.contains(e.target)) { setOpen(false); setText(selected ? selected.name : ''); setTyped(false); } };
    document.addEventListener('mousedown', close);
    return () => document.removeEventListener('mousedown', close);
  }, [open, selected]);

  const matches = useMemo(() => {
    const q = norm(text);
    if (!typed || !q) return services;
    const words = q.split(' ');
    const scored = [];
    services.forEach((s) => {
      const name = norm(s.name);
      const hay = `${name} ${norm(s.code)} ${norm(s.dept)}`;
      if (!words.every((w) => hay.includes(w))) return;
      // names starting with what was typed first, then word starts, then anywhere
      const rank = name.startsWith(q) ? 0 : name.split(' ').some((w) => w.startsWith(words[0])) ? 1 : 2;
      scored.push([rank, s]);
    });
    return scored.sort((a, b) => a[0] - b[0] || a[1].name.localeCompare(b[1].name)).map(([, s]) => s);
  }, [services, text, typed]);

  useEffect(() => { setHi(0); }, [text, open]);
  useEffect(() => {
    const el = listRef.current?.children?.[hi];
    if (el) el.scrollIntoView({ block: 'nearest' });
  }, [hi]);

  function pick(s) {
    setOpen(false);
    setTyped(false);
    setText(s.name);
    onPick?.(s);
  }

  function onKeyDown(e) {
    if (e.key === 'ArrowDown') { e.preventDefault(); if (!open) setOpen(true); else setHi((h) => Math.min(h + 1, matches.length - 1)); }
    else if (e.key === 'ArrowUp') { e.preventDefault(); setHi((h) => Math.max(h - 1, 0)); }
    else if (e.key === 'Enter') { if (open && matches[hi]) { e.preventDefault(); pick(matches[hi]); } }
    else if (e.key === 'Escape') { setOpen(false); setText(selected ? selected.name : ''); setTyped(false); }
  }

  return (
    <div ref={boxRef} style={{ position: 'relative', ...style }}>
      <input
        className={small ? 'fi fi-sm' : 'fi'}
        style={{ paddingRight: 28, width: '100%' }}
        value={text}
        disabled={disabled}
        placeholder={placeholder}
        onFocus={(e) => { setOpen(true); e.target.select(); }}
        onClick={() => setOpen(true)}
        onChange={(e) => { setTyped(true); setText(e.target.value); setOpen(true); if (selected) { fromTypingRef.current = true; onPick?.(null); } }}
        onKeyDown={onKeyDown}
        autoComplete="off"
      />
      <button type="button" tabIndex={-1} disabled={disabled} aria-label="Show list"
        onMouseDown={(e) => { e.preventDefault(); setTyped(false); setOpen((o) => !o); boxRef.current?.querySelector('input')?.focus(); }}
        style={{ position: 'absolute', right: 4, top: '50%', transform: 'translateY(-50%)', border: 'none', background: 'transparent', cursor: 'pointer', color: 'var(--g500)', padding: '2px 4px' }}>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`}></i>
      </button>
      {open && !disabled && (
        <div ref={listRef} style={{ position: 'absolute', left: 0, right: 0, top: 'calc(100% + 2px)', maxHeight: 280, overflowY: 'auto', background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, boxShadow: '0 8px 24px rgba(0,0,0,.12)', zIndex: 60 }}>
          {matches.length === 0 && <div style={{ padding: '8px 10px', fontSize: 12.5, color: 'var(--g400)' }}>No service matches “{text}”.</div>}
          {matches.map((s, i) => (
            <div key={s.code}
              onMouseDown={(e) => { e.preventDefault(); pick(s); }}
              onMouseEnter={() => setHi(i)}
              style={{ padding: '7px 10px', fontSize: 13, cursor: 'pointer', display: 'flex', justifyContent: 'space-between', gap: 8,
                background: i === hi ? 'var(--blue-lt, #eef2ff)' : (s.code === value ? 'var(--g50)' : '#fff') }}>
              <span>{s.name}{showDept && s.dept && <span style={{ fontSize: 11, color: 'var(--g400)', marginLeft: 6 }}>{s.dept}</span>}</span>
              {showRate && s.rate != null && <span style={{ fontSize: 12, color: 'var(--g500)', whiteSpace: 'nowrap' }}>Rs.{s.rate}</span>}
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
