'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOTAvailability, getOTMonthSummary, getOTUpcomingWeek } from './actions';

const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const MONTH_NAMES = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const PRIORITY_BADGE = { Emergency: 'b-red', Urgent: 'b-amber', Routine: 'b-gray' };

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

function fmtDayLabel(dateISO) {
  const d = new Date(`${dateISO}T00:00:00`);
  const today = new Date();
  const diffDays = Math.round((d - new Date(today.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }))) / 86400000);
  if (diffDays === 0) return 'Today';
  if (diffDays === 1) return 'Tomorrow';
  return d.toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: 'short', day: 'numeric', month: 'short' });
}

// ── Month grid + nav + legend -- the actual calendar, shared by both
// the full Calendar tab and the compact picker popup. ──
function MonthCalendarGrid({ viewYear, viewMonth, onChangeMonth, onJumpToday, summary, loading, selectedDate, onSelectDate, todayISO, compact }) {
  const firstOfMonth = new Date(viewYear, viewMonth, 1);
  const startWeekday = firstOfMonth.getDay();
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < startWeekday; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  const cellSize = compact ? 38 : 52;

  return (
    <div className="card">
      <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 12 }}>
        <button type="button" className="btn" style={{ padding: '4px 9px' }} onClick={() => onChangeMonth(-1)}><i className="ti ti-chevron-left"></i></button>
        <div style={{ textAlign: 'center' }}>
          <div style={{ fontWeight: 800, fontSize: compact ? 14 : 16 }}>{MONTH_NAMES[viewMonth]} {viewYear}</div>
          {!compact && <button type="button" onClick={onJumpToday} style={{ background: 'none', border: 'none', color: 'var(--blue)', fontSize: 11, fontWeight: 600, cursor: 'pointer', padding: 0 }}>Jump to Today</button>}
        </div>
        <button type="button" className="btn" style={{ padding: '4px 9px' }} onClick={() => onChangeMonth(1)}><i className="ti ti-chevron-right"></i></button>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3, marginBottom: 4 }}>
        {DOW.map((d, i) => (
          <div key={i} style={{ textAlign: 'center', fontSize: compact ? 9.5 : 10.5, fontWeight: 700, color: 'var(--g400)', padding: '2px 0', textTransform: 'uppercase' }}>{compact ? d[0] : d}</div>
        ))}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 3, opacity: loading ? 0.5 : 1 }}>
        {cells.map((day, idx) => {
          if (day === null) return <div key={`e${idx}`} />;
          const dateISO = toISODate(new Date(viewYear, viewMonth, day));
          const isPast = dateISO < todayISO;
          const isToday = dateISO === todayISO;
          const bookings = summary.byDate[dateISO] || [];
          const count = bookings.length;
          const color = loadColor(count, summary.dailyCapacity);
          const isSelected = selectedDate === dateISO;
          const isWeekend = new Date(viewYear, viewMonth, day).getDay() % 6 === 0;

          return (
            <button
              type="button"
              key={dateISO}
              disabled={isPast}
              onClick={() => onSelectDate(dateISO)}
              style={{
                height: cellSize, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', gap: 2,
                border: isSelected ? '2px solid var(--teal)' : isToday ? '1.5px solid var(--blue)' : '1px solid transparent',
                borderRadius: 8, background: isSelected ? 'var(--teal-lt, var(--green-lt))' : isPast ? 'transparent' : isWeekend ? 'var(--g50)' : '#fff',
                cursor: isPast ? 'default' : 'pointer', color: isPast ? 'var(--g300)' : isToday ? 'var(--blue)' : 'var(--g700)',
                fontSize: compact ? 12 : 13, fontWeight: isToday ? 800 : 600, padding: 0, position: 'relative',
              }}
            >
              {day}
              {count > 0 && !isPast && (
                <span style={{
                  fontSize: 9, fontWeight: 700, lineHeight: 1, padding: '1px 5px', borderRadius: 8,
                  background: color, color: '#fff', minWidth: 14, textAlign: 'center',
                }}>
                  {count}
                </span>
              )}
            </button>
          );
        })}
      </div>

      {summary.dailyCapacity > 0 && (
        <div style={{ display: 'flex', gap: 12, alignItems: 'center', marginTop: 12, fontSize: 10.5, color: 'var(--g500)', flexWrap: 'wrap', borderTop: '1px solid var(--g100)', paddingTop: 10 }}>
          <span><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 3, background: 'var(--green)', marginRight: 4 }}></span>Light</span>
          <span><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 3, background: 'var(--amber)', marginRight: 4 }}></span>Busy</span>
          <span><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: 3, background: 'var(--red)', marginRight: 4 }}></span>Full</span>
          <span style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 4 }}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', border: '1.5px solid var(--blue)' }}></span>Today</span>
        </div>
      )}
    </div>
  );
}

// ── Selected day's prior bookings + session availability -- shared by
// both modes. isPicker adds the "pick this slot" click behavior. ──
function DayDetailPanel({ selectedDate, dayBookings, sessions, loadingSessions, isPicker, onPickSlot, compact }) {
  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 10, fontSize: compact ? 13 : 14 }}>
        <i className="ti ti-calendar-event"></i> {new Date(`${selectedDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', weekday: compact ? undefined : 'long', day: 'numeric', month: 'short', year: 'numeric' })}
      </div>

      <div style={{ fontWeight: 700, fontSize: 11, marginBottom: 6, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.3px' }}>Prior Bookings</div>
      {dayBookings.length === 0 ? (
        <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 14 }}>Nothing booked yet on this date.</div>
      ) : (
        <div style={{ marginBottom: 14 }}>
          {dayBookings.map((b) => (
            <div key={b.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 0', borderBottom: '1px solid var(--g50)' }}>
              <span style={{ width: 26, height: 26, borderRadius: '50%', background: 'var(--indigo-lt, var(--blue-lt))', color: 'var(--indigo, var(--blue))', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>
                {b.patientName?.charAt(0)}
              </span>
              <div style={{ fontSize: 11.5, minWidth: 0 }}>
                <strong>{b.patientName}</strong> <span style={{ color: 'var(--g400)' }}>({b.uhid})</span>
                <div style={{ color: 'var(--g500)', fontSize: 11 }}>{b.procedureName}{b.eye ? ` -- ${b.eye}` : ''} -- {b.sessionName}</div>
              </div>
            </div>
          ))}
        </div>
      )}

      <div style={{ fontWeight: 700, fontSize: 11, marginBottom: 6, color: 'var(--g500)', textTransform: 'uppercase', letterSpacing: '.3px' }}>Sessions</div>
      {loadingSessions ? (
        <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Checking availability...</div>
      ) : (
        <div style={{ display: 'flex', flexDirection: 'column', gap: 6 }}>
          {sessions.map((s) => {
            const full = s.remaining <= 0;
            return (
              <button
                key={s.session_id}
                type="button"
                disabled={full}
                onClick={() => isPicker && onPickSlot(s)}
                className="btn btn-sm"
                style={{
                  textAlign: 'left', width: '100%', display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 10px',
                  background: full ? 'var(--g100)' : '',
                  color: full ? 'var(--g400)' : '',
                  cursor: full ? 'not-allowed' : isPicker ? 'pointer' : 'default',
                }}
              >
                <span>
                  <span style={{ fontWeight: 700 }}>{s.name}</span>
                  <span style={{ fontSize: 10.5, opacity: .75, marginLeft: 6 }}>{s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}</span>
                </span>
                <span style={{ fontSize: 10.5, fontWeight: 700, whiteSpace: 'nowrap' }}>
                  {full ? 'FULL' : isPicker ? <><i className="ti ti-arrow-back"></i> {s.remaining} left</> : `${s.remaining} left`}
                </span>
              </button>
            );
          })}
        </div>
      )}
    </div>
  );
}

// ── Month Overview -- four stat cards summarizing the currently
// browsed month, computed client-side from the already-fetched month
// summary (no extra query). ──
function MonthOverviewWidget({ summary, viewYear, viewMonth }) {
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const dates = Object.keys(summary.byDate);
  const totalBookings = dates.reduce((sum, d) => sum + summary.byDate[d].length, 0);
  const fullyBookedDays = summary.dailyCapacity > 0 ? dates.filter((d) => summary.byDate[d].length >= summary.dailyCapacity).length : 0;
  const avgLoad = summary.dailyCapacity > 0 ? Math.round((totalBookings / (daysInMonth * summary.dailyCapacity)) * 100) : 0;
  let busiestDay = null;
  let busiestCount = 0;
  dates.forEach((d) => { if (summary.byDate[d].length > busiestCount) { busiestCount = summary.byDate[d].length; busiestDay = d; } });

  const stats = [
    { label: 'Total Bookings', value: totalBookings, color: '--blue' },
    { label: 'Avg. Daily Load', value: `${avgLoad}%`, color: '--teal' },
    { label: 'Fully Booked Days', value: fullyBookedDays, color: '--amber' },
    { label: 'Busiest Day', value: busiestDay ? new Date(`${busiestDay}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' }) : '--', sub: busiestDay ? `${busiestCount} booked` : null, color: '--purple' },
  ];

  return (
    <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 12, marginBottom: 16 }}>
      {stats.map((s) => (
        <div key={s.label} className="card" style={{ borderTop: `3px solid var(${s.color})`, padding: '12px 14px' }}>
          <div style={{ fontSize: 10, color: 'var(--g500)', fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.3px' }}>{s.label}</div>
          <div style={{ fontSize: 22, fontWeight: 800, marginTop: 4 }}>{s.value}</div>
          {s.sub && <div style={{ fontSize: 10.5, color: 'var(--g400)' }}>{s.sub}</div>}
        </div>
      ))}
    </div>
  );
}

// ── This Week -- always the real next 7 days, independent of whatever
// month the calendar is currently browsing. ──
function ThisWeekWidget({ bookings, loading }) {
  return (
    <div className="card" style={{ marginBottom: 16 }}>
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-calendar-week" style={{ color: 'var(--blue)' }}></i> This Week
        <span className="badge b-blue" style={{ marginLeft: 8 }}>{bookings.length}</span>
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Scheduled surgeries over the next 7 days.</div>
      {loading && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '10px 0' }}>Loading...</div>}
      {!loading && bookings.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '10px 0' }}>Nothing scheduled this week.</div>}
      {!loading && bookings.map((b) => (
        <div key={b.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '7px 0', borderBottom: '1px solid var(--g50)' }}>
          <div style={{ width: 54, flexShrink: 0, fontSize: 10.5, fontWeight: 700, color: 'var(--g500)' }}>{fmtDayLabel(b.date)}</div>
          <div style={{ flex: 1, minWidth: 0 }}>
            <span style={{ fontWeight: 700, fontSize: 12 }}>{b.patientName}</span>
            {b.priority !== 'Routine' && <span className={`badge ${PRIORITY_BADGE[b.priority] || 'b-gray'}`} style={{ marginLeft: 6, fontSize: 9 }}>{b.priority}</span>}
            <div style={{ fontSize: 10.5, color: 'var(--g500)' }}>
              {b.procedureName}{b.eye ? ` -- ${b.eye}` : ''} -- {b.sessionName}{b.surgeonName ? ` -- ${b.surgeonName}` : ''}
            </div>
          </div>
        </div>
      ))}
    </div>
  );
}

// ── Session Utilization -- how each OT session is loaded across the
// currently browsed month, computed client-side from the month summary
// (each booking carries its sessionId already). ──
function SessionUtilizationWidget({ summary, viewYear, viewMonth }) {
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const counts = {};
  Object.values(summary.byDate).flat().forEach((b) => {
    counts[b.sessionId] = (counts[b.sessionId] || 0) + 1;
  });

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-chart-bar" style={{ color: 'var(--purple)' }}></i> Session Utilization
      </div>
      <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>Bookings per session this month, against total capacity.</div>
      {summary.sessions.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No active OT sessions configured.</div>}
      {summary.sessions.map((s) => {
        const booked = counts[s.id] || 0;
        const capacityThisMonth = (s.capacity || 0) * daysInMonth;
        const pct = capacityThisMonth > 0 ? Math.min(100, Math.round((booked / capacityThisMonth) * 100)) : 0;
        return (
          <div key={s.id} style={{ marginBottom: 10 }}>
            <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 11.5, marginBottom: 3 }}>
              <span style={{ fontWeight: 600 }}>{s.name}</span>
              <span style={{ color: 'var(--g500)' }}>{booked} booked -- {s.capacity}/day cap.</span>
            </div>
            <div style={{ height: 6, borderRadius: 3, background: 'var(--g100)', overflow: 'hidden' }}>
              <div style={{ height: '100%', width: `${pct}%`, background: pct >= 90 ? 'var(--red)' : pct >= 60 ? 'var(--amber)' : 'var(--green)', borderRadius: 3 }}></div>
            </div>
          </div>
        );
      })}
    </div>
  );
}

// Full month-grid calendar of OT bookings -- used both as a rich
// browsing view (OT Schedule module's own Calendar tab, with month
// overview / this-week / session-utilization widgets alongside it) and
// as a lean "picker" (opened as a small popup window from Surgical
// Journey with pickFor=<caseId>&pickLabel=..): clicking a date and then
// a session posts the choice back to the window that opened it and
// closes itself, instead of duplicating the booking UI in two places.
// The picker deliberately skips all the widgets below -- it's a small
// focused popup for one decision, not a dashboard.
export default function OTCalendar({ pickFor, pickLabel }) {
  const isPicker = !!pickFor;

  const today = new Date();
  const [viewYear, setViewYear] = useState(today.getFullYear());
  const [viewMonth, setViewMonth] = useState(today.getMonth());
  const [summary, setSummary] = useState({ dailyCapacity: 0, sessions: [], byDate: {} });
  const [loading, setLoading] = useState(true);
  const [selectedDate, setSelectedDate] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [loadingSessions, setLoadingSessions] = useState(false);
  const [upcomingWeek, setUpcomingWeek] = useState([]);
  const [loadingWeek, setLoadingWeek] = useState(true);

  const todayISO = toISODate(today);

  const loadMonth = useCallback(async (year, month) => {
    setLoading(true);
    const start = new Date(year, month, 1);
    const end = new Date(year, month + 1, 0);
    const result = await getOTMonthSummary(toISODate(start), toISODate(end));
    setSummary(result);
    setLoading(false);
  }, []);

  useEffect(() => { loadMonth(viewYear, viewMonth); }, [viewYear, viewMonth, loadMonth]);

  useEffect(() => {
    if (isPicker) return;
    getOTUpcomingWeek().then((rows) => { setUpcomingWeek(rows); setLoadingWeek(false); });
  }, [isPicker]);

  useEffect(() => {
    if (!selectedDate) { setSessions([]); return; }
    setLoadingSessions(true);
    getOTAvailability(selectedDate).then((rows) => { setSessions(rows); setLoadingSessions(false); });
  }, [selectedDate]);

  function changeMonth(delta) {
    let m = viewMonth + delta;
    let y = viewYear;
    if (m < 0) { m = 11; y -= 1; }
    if (m > 11) { m = 0; y += 1; }
    setViewYear(y); setViewMonth(m);
  }

  function jumpToday() {
    setViewYear(today.getFullYear());
    setViewMonth(today.getMonth());
    setSelectedDate(todayISO);
  }

  function pickSlot(session) {
    if (window.opener) {
      window.opener.postMessage({ type: 'ot-slot-picked', caseId: pickFor, date: selectedDate, sessionId: session.session_id, sessionName: session.name }, window.location.origin);
    }
    window.close();
  }

  const dayBookings = selectedDate ? (summary.byDate[selectedDate] || []) : [];

  if (isPicker) {
    return (
      <div>
        <div style={{ background: 'var(--indigo-lt, var(--blue-lt))', border: '1px solid var(--indigo)', borderRadius: 8, padding: '8px 12px', fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-calendar-plus"></i> Picking a surgery date{pickLabel ? ` for ${pickLabel}` : ''}. Pick a date, then a session.
        </div>
        <div style={{ maxWidth: 340 }}>
          <MonthCalendarGrid
            viewYear={viewYear} viewMonth={viewMonth} onChangeMonth={changeMonth} onJumpToday={jumpToday}
            summary={summary} loading={loading} selectedDate={selectedDate} onSelectDate={setSelectedDate} todayISO={todayISO} compact
          />
        </div>
        {selectedDate && (
          <div style={{ maxWidth: 400, marginTop: 12 }}>
            <DayDetailPanel
              selectedDate={selectedDate} dayBookings={dayBookings} sessions={sessions} loadingSessions={loadingSessions}
              isPicker onPickSlot={pickSlot} compact
            />
          </div>
        )}
      </div>
    );
  }

  return (
    <div>
      <MonthOverviewWidget summary={summary} viewYear={viewYear} viewMonth={viewMonth} />

      <div style={{ display: 'grid', gridTemplateColumns: '420px 1fr', gap: 16, alignItems: 'start' }}>
        <div>
          <MonthCalendarGrid
            viewYear={viewYear} viewMonth={viewMonth} onChangeMonth={changeMonth} onJumpToday={jumpToday}
            summary={summary} loading={loading} selectedDate={selectedDate} onSelectDate={setSelectedDate} todayISO={todayISO}
          />
          {selectedDate && (
            <div style={{ marginTop: 16 }}>
              <DayDetailPanel
                selectedDate={selectedDate} dayBookings={dayBookings} sessions={sessions} loadingSessions={loadingSessions}
                isPicker={false}
              />
            </div>
          )}
        </div>

        <div>
          <ThisWeekWidget bookings={upcomingWeek} loading={loadingWeek} />
          <SessionUtilizationWidget summary={summary} viewYear={viewYear} viewMonth={viewMonth} />
        </div>
      </div>
    </div>
  );
}
