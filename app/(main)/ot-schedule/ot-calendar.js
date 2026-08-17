'use client';

import { useState, useEffect, useCallback } from 'react';
import { getOTAvailability, getOTMonthSummary } from './actions';

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

// Compact month-grid calendar of OT bookings -- used both as a plain
// browsing view (OT Schedule module's own Calendar tab) and as a
// "picker" (opened as a popup window from Surgical Journey with
// pickFor=<caseId>&pickLabel=..): clicking a date and then a session
// posts the choice back to the window that opened it and closes
// itself, instead of duplicating the booking UI in two places.
export default function OTCalendar({ pickFor, pickLabel }) {
  const isPicker = !!pickFor;

  const today = new Date();
  const [viewYear, setViewYear] = useState(today.getFullYear());
  const [viewMonth, setViewMonth] = useState(today.getMonth());
  const [summary, setSummary] = useState({ dailyCapacity: 0, byDate: {} });
  const [loading, setLoading] = useState(true);
  const [selectedDate, setSelectedDate] = useState(null);
  const [sessions, setSessions] = useState([]);
  const [loadingSessions, setLoadingSessions] = useState(false);

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

  function pickSlot(session) {
    if (window.opener) {
      window.opener.postMessage({ type: 'ot-slot-picked', caseId: pickFor, date: selectedDate, sessionId: session.session_id, sessionName: session.name }, window.location.origin);
    }
    window.close();
  }

  const firstOfMonth = new Date(viewYear, viewMonth, 1);
  const startWeekday = firstOfMonth.getDay();
  const daysInMonth = new Date(viewYear, viewMonth + 1, 0).getDate();
  const cells = [];
  for (let i = 0; i < startWeekday; i++) cells.push(null);
  for (let d = 1; d <= daysInMonth; d++) cells.push(d);

  const dayBookings = selectedDate ? (summary.byDate[selectedDate] || []) : [];

  return (
    <div>
      {isPicker && (
        <div style={{ background: 'var(--indigo-lt, var(--blue-lt))', border: '1px solid var(--indigo)', borderRadius: 8, padding: '8px 12px', fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-calendar-plus"></i> Picking a surgery date{pickLabel ? ` for ${pickLabel}` : ''}. Pick a date, then a session.
        </div>
      )}

      <div className="card" style={{ maxWidth: 340 }}>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', marginBottom: 10 }}>
          <button type="button" className="btn" style={{ padding: '3px 8px' }} onClick={() => changeMonth(-1)}><i className="ti ti-chevron-left"></i></button>
          <div style={{ fontWeight: 700, fontSize: 13.5 }}>{MONTH_NAMES[viewMonth]} {viewYear}</div>
          <button type="button" className="btn" style={{ padding: '3px 8px' }} onClick={() => changeMonth(1)}><i className="ti ti-chevron-right"></i></button>
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2, marginBottom: 2 }}>
          {DOW.map((d, i) => (
            <div key={i} style={{ textAlign: 'center', fontSize: 10, fontWeight: 700, color: 'var(--g400)', padding: '2px 0' }}>{d}</div>
          ))}
        </div>

        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(7, 1fr)', gap: 2, opacity: loading ? 0.5 : 1 }}>
          {cells.map((day, idx) => {
            if (day === null) return <div key={`e${idx}`} />;
            const dateISO = toISODate(new Date(viewYear, viewMonth, day));
            const isPast = dateISO < todayISO;
            const bookings = summary.byDate[dateISO] || [];
            const count = bookings.length;
            const color = loadColor(count, summary.dailyCapacity);
            const isSelected = selectedDate === dateISO;

            return (
              <button
                type="button"
                key={dateISO}
                disabled={isPast}
                onClick={() => setSelectedDate(dateISO)}
                style={{
                  width: 38, height: 38, display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center',
                  border: isSelected ? '2px solid var(--teal)' : '1px solid transparent',
                  borderRadius: 6, background: isSelected ? 'var(--teal-lt, var(--green-lt))' : isPast ? 'transparent' : '#fff',
                  cursor: isPast ? 'default' : 'pointer', color: isPast ? 'var(--g300)' : 'var(--g700)', fontSize: 12, fontWeight: 600, padding: 0,
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
          <div style={{ display: 'flex', gap: 8, alignItems: 'center', marginTop: 10, fontSize: 10, color: 'var(--g400)', flexWrap: 'wrap' }}>
            <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--green)', marginRight: 3 }}></span>Light</span>
            <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--amber)', marginRight: 3 }}></span>Busy</span>
            <span><span style={{ display: 'inline-block', width: 6, height: 6, borderRadius: '50%', background: 'var(--red)', marginRight: 3 }}></span>Full</span>
          </div>
        )}
      </div>

      {selectedDate && (
        <div className="card" style={{ marginTop: 12, maxWidth: 400 }}>
          <div className="card-title" style={{ marginBottom: 8, fontSize: 13 }}>
            <i className="ti ti-calendar-event"></i> {new Date(`${selectedDate}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
          </div>

          <div style={{ fontWeight: 600, fontSize: 11.5, marginBottom: 5, color: 'var(--g500)' }}>PRIOR BOOKINGS</div>
          {dayBookings.length === 0 ? (
            <div style={{ fontSize: 11.5, color: 'var(--g400)', marginBottom: 12 }}>Nothing booked yet on this date.</div>
          ) : (
            <div style={{ marginBottom: 12 }}>
              {dayBookings.map((b) => (
                <div key={b.id} style={{ fontSize: 11.5, padding: '4px 0', borderBottom: '1px solid var(--g50)' }}>
                  <strong>{b.patientName}</strong> ({b.uhid}) -- {b.procedureName}{b.eye ? ` (${b.eye})` : ''} -- <span style={{ color: 'var(--g500)' }}>{b.sessionName}</span>
                </div>
              ))}
            </div>
          )}

          <div style={{ fontWeight: 600, fontSize: 11.5, marginBottom: 5, color: 'var(--g500)' }}>SESSIONS</div>
          {loadingSessions ? (
            <div style={{ fontSize: 11.5, color: 'var(--g400)' }}>Checking availability...</div>
          ) : (
            <div style={{ display: 'flex', flexDirection: 'column', gap: 5 }}>
              {sessions.map((s) => {
                const full = s.remaining <= 0;
                return (
                  <button
                    key={s.session_id}
                    type="button"
                    disabled={full}
                    onClick={() => isPicker && pickSlot(s)}
                    className="btn btn-sm"
                    style={{
                      textAlign: 'left', width: '100%', display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                      background: full ? 'var(--g100)' : '',
                      color: full ? 'var(--g400)' : '',
                      cursor: full ? 'not-allowed' : isPicker ? 'pointer' : 'default',
                    }}
                  >
                    <span>
                      <span style={{ fontWeight: 700 }}>{s.name}</span>
                      <span style={{ fontSize: 10.5, opacity: .75, marginLeft: 6 }}>{s.start_time?.slice(0, 5)}--{s.end_time?.slice(0, 5)} -- {s.default_room || 'Room TBD'}</span>
                    </span>
                    <span style={{ fontSize: 10.5, fontWeight: 600, whiteSpace: 'nowrap' }}>
                      {full ? 'FULL' : isPicker ? <><i className="ti ti-arrow-back"></i> {s.remaining} left</> : `${s.remaining} left`}
                    </span>
                  </button>
                );
              })}
            </div>
          )}
        </div>
      )}
    </div>
  );
}
