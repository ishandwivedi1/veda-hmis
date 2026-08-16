'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOTMonthSummary } from '@/app/(main)/ot-schedule/actions';

const DOW = ['S', 'M', 'T', 'W', 'T', 'F', 'S'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

function toISODate(d) {
  return d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' });
}

function loadColor(count, capacity) {
  if (!capacity || count <= 0) return null;
  const ratio = count / capacity;
  if (ratio >= 1) return 'var(--red)';
  if (ratio >= 0.6) return 'var(--amber)';
  return 'var(--green)';
}

// Month-grid date picker for booking/rescheduling OT surgery dates --
// shows how many cases are already booked each day (color-coded
// against total daily capacity) so a date can be picked with prior
// bookings visible at a glance, not just typed blind into a date
// field. Clicking a day selects it (via onSelect) and expands that
// day's existing bookings below the grid.
export default function OTCalendarPicker({ value, onSelect }) {
  const todayISO = toISODate(new Date());
  const initial = value ? new Date(`${value}T00:00:00`) : new Date();
  const [viewYear, setViewYear] = useState(initial.getFullYear());
  const [viewMonth, setViewMonth] = useState(initial.getMonth());
  const [summary, setSummary] = useState({ dailyCapacity: 0, byDate: {} });
  const [loading, setLoading] = useState(true);
  const [expandedDate, setExpandedDate] = useState(value || null);

  const loadMonth = useCallback(async (year, month) => {
    setLoading(true);
    const start = new Date(year, month, 1);
    const end = new Date(year, month + 1, 0);
    const result = await getOTMonthSummary(toISODate(start), toISODate(end));
    setSummary(result);
    setLoading(false);
  }, []);

  useEffect(() => { loadMonth(viewYear, viewMonth); }, [viewYear, viewMonth, loadMonth]);

  function changeMonth(delta) {
    let m = viewMonth + delta;
    let y = viewYear;
    if (m < 0) { m = 11; y -= 1; }
    if (m > 11) { m = 0; y += 1; }
    setViewYear(y); setViewMonth(m);
  }

  const firstOfMonth = new Date(viewYear, viewMonth, 1);
  const startWeekday = firstOfMonth.getDay();
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < startWeekday; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  const expandedBookings = expandedDate ? (summary.byDate[expandedDate] || []) : [];

  return (
    <div>
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 8 }}>
        <button type="button" className="btn" style={{ padding: '3px 9px', fontSize: 12 }} onClick={() => changeMonth(-1)}>
          <i className="ti ti-chevron-left"></i>
        </button>
        <div style={{ fontWeight: 700, fontSize: 13 }}>{MONTH_NAMES[viewMonth]} {viewYear}</div>
        <button type="button" className="btn" style={{ padding: '3px 9px', fontSize: 12 }} onClick={() => changeMonth(1)}>
          <i className="ti ti-chevron-right"></i>
        </button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3, marginBottom: 3 }}>
        {DOW.map((d, i) => (
          <div key={i} style={{ textAlign: 'center', fontSize: 10, fontWeight: 700, color: 'var(--g400)', padding: '2px 0' }}>{d}</div>
        ))}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3, opacity: loading ? 0.5 : 1 }}>
        {cells.map((day, idx) => {
          if (day === null) return <div key={`e${idx}`} />;
          const dateISO = toISODate(new Date(viewYear, viewMonth, day));
          const isPast = dateISO < todayISO;
          const dayBookings = summary.byDate[dateISO] || [];
          const count = dayBookings.length;
          const color = loadColor(count, summary.dailyCapacity);
          const isSelected = value === dateISO;
          const isExpanded = expandedDate === dateISO;

          return (
            <button
              type="button"
              key={dateISO}
              disabled={isPast}
              onClick={() => { onSelect(dateISO); setExpandedDate(dateISO); }}
              style={{
                aspectRatio: '1', display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                border: isSelected ? '2px solid var(--teal)' : isExpanded ? '1.5px solid var(--g300)' : '1px solid var(--g100)',
                borderRadius: 6, background: isSelected ? 'var(--teal-lt, var(--green-lt))' : isPast ? 'var(--g50)' : '#fff',
                cursor: isPast ? 'default' : 'pointer', color: isPast ? 'var(--g300)' : 'var(--g700)', fontSize: 11.5, fontWeight: 600, padding: 2,
              }}
            >
              {day}
              {count > 0 && !isPast && (
                <span style={{ width: 5, height: 5, borderRadius: '50%', background: color, marginTop: 1 }}></span>
              )}
            </button>
          );
        })}
      </div>

      {summary.dailyCapacity > 0 && (
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginTop: 8, fontSize: 10, color: 'var(--g400)' }}>
          <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--green)', marginRight: 3 }}></span>Light</span>
          <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--amber)', marginRight: 3 }}></span>Busy</span>
          <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--red)', marginRight: 3 }}></span>Full</span>
          <span style={{ marginLeft: 'auto' }}>{summary.dailyCapacity} slots/day total</span>
        </div>
      )}

      {expandedDate && (
        <div style={{ marginTop: 10, border: '1px solid var(--g100)', borderRadius: 8, padding: 10 }}>
          <div style={{ fontSize: 11.5, fontWeight: 700, marginBottom: 6 }}>
            Prior bookings -- {new Date(`${expandedDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
          </div>
          {expandedBookings.length === 0 ? (
            <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Nothing booked yet on this date.</div>
          ) : (
            expandedBookings.map((b) => (
              <div key={b.id} style={{ fontSize: 11.5, padding: '4px 0', borderBottom: '1px solid var(--g50)' }}>
                <strong>{b.patientName}</strong> ({b.uhid}) -- {b.procedureName}{b.eye ? ` (${b.eye})` : ''} -- <span style={{ color: 'var(--g500)' }}>{b.sessionName}</span>
              </div>
            ))
          )}
        </div>
      )}
    </div>
  );
}
