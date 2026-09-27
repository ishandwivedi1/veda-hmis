'use client';

// Auto-refresh that only runs while the page is actually on screen.
//
// Dashboards used to refetch every 15-20s even in a background tab or a
// minimised window -- wasted server calls, and on return the screen
// could still be showing data up to 15s old. This pauses while the tab
// is hidden and, when it comes back, refreshes straight away (if a
// refresh was due) before resuming the normal rhythm.
//
// A dashboard left open on a visible screen (e.g. a queue display)
// keeps refreshing exactly as before.

import { useEffect, useRef } from 'react';

export function useVisibleInterval(callback, ms, enabled = true) {
  const cb = useRef(callback);
  useEffect(() => { cb.current = callback; }, [callback]);

  useEffect(() => {
    if (!enabled) return undefined;
    let timer = null;
    let last = Date.now();
    const tick = () => { last = Date.now(); cb.current(); };
    const start = () => { if (!timer) timer = setInterval(tick, ms); };
    const stop = () => { if (timer) { clearInterval(timer); timer = null; } };
    const onVisibility = () => {
      if (document.visibilityState === 'visible') {
        if (Date.now() - last >= ms) tick();
        start();
      } else {
        stop();
      }
    };
    if (document.visibilityState === 'visible') start();
    document.addEventListener('visibilitychange', onVisibility);
    return () => { stop(); document.removeEventListener('visibilitychange', onVisibility); };
  }, [ms, enabled]);
}
