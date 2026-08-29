'use client';

import Link from 'next/link';
import { formatPatientName } from '@/lib/patientName';
import { useState, useEffect, useCallback, useRef, Suspense } from 'react';
import { useSearchParams } from 'next/navigation';
import { searchPatients, getPatientTimeline } from './actions';
import { openPopup } from '@/lib/popup';

// Same mapping used in the Consultation workspace's context sidebar --
// kept identical across both so an event type reads as the same color
// everywhere in the app.
const TYPE_COLOR = {
  Visit: 'var(--indigo)',
  Diagnosis: 'var(--blue)',
  Investigation: 'var(--teal)',
  Prescription: 'var(--purple)',
  Surgery: 'var(--red)',
};
const TYPE_ICON = {
  Visit: 'ti-door-enter',
  Diagnosis: 'ti-clipboard-list',
  Investigation: 'ti-flask',
  Prescription: 'ti-pill',
  Surgery: 'ti-scalpel',
};

function PatientTimelineInner() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [events, setEvents] = useState([]);
  const [filter, setFilter] = useState('');
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [loading, setLoading] = useState(false);
  const searchParams = useSearchParams();
  const skipNextSearch = useRef(false);

  function handleSearch(val) {
    setQuery(val);
  }

  // Debounced live search -- waits for a short pause in typing before
  // querying, rather than firing a request on every keystroke. Skipped
  // once when the query box is set programmatically (e.g. after picking
  // a patient below), so the dropdown doesn't reopen right after selection.
  useEffect(() => {
    if (skipNextSearch.current) { skipNextSearch.current = false; return; }
    const q = query.trim();
    if (q.length < 2) { setResults([]); return; }
    const t = setTimeout(async () => {
      setResults(await searchPatients(q));
    }, 300);
    return () => clearTimeout(t);
  }, [query]);

  const loadPatientById = useCallback(async (patientId) => {
    setLoading(true);
    setResults([]);
    setSelectedEvent(null);
    const result = await getPatientTimeline(patientId);
    setLoading(false);
    setPatient(result.patient);
    setEvents(result.events || []);
    if (result.patient) {
      skipNextSearch.current = true;
      setQuery(`${formatPatientName(result.patient)} -- ${result.patient.uhid}`);
    }
  }, []);

  async function handleSelectPatient(p) {
    await loadPatientById(p.id);
  }

  // Deep link from elsewhere in the app (e.g. the Consultation workspace's
  // "Open full timeline" link) -- skip the search step and load directly.
  useEffect(() => {
    const patientId = searchParams.get('patientId');
    if (patientId) loadPatientById(patientId);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [searchParams]);

  const filteredEvents = filter ? events.filter((e) => e.type === filter) : events;
  const counts = {};
  events.forEach((e) => { counts[e.type] = (counts[e.type] || 0) + 1; });

  return (
    <div>
      <div className="card" style={{ marginBottom: 14 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-timeline" style={{ color: 'var(--blue)' }}></i> Clinical Timeline</div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Read-only longitudinal history, aggregated across every visit this patient has had.
        </div>
        <div style={{ position: 'relative' }}>
          <input className="fi" placeholder="Search patient by name or UHID..." value={query} onChange={(e) => handleSearch(e.target.value)} />
          {results.length > 0 && (
            <div style={{ position: 'absolute', top: '100%', left: 0, right: 0, background: '#fff', border: '1px solid var(--g200)', borderRadius: 8, marginTop: 4, zIndex: 10, boxShadow: '0 4px 16px rgba(0,0,0,.1)' }}>
              {results.map((p) => (
                <div
                  key={p.id}
                  onClick={() => handleSelectPatient(p)}
                  style={{ padding: '8px 12px', cursor: 'pointer', fontSize: 13, borderBottom: '1px solid var(--g100)' }}
                  onMouseEnter={(e) => (e.currentTarget.style.background = 'var(--g50)')}
                  onMouseLeave={(e) => (e.currentTarget.style.background = '#fff')}
                >
                  <strong>{formatPatientName(p)}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {loading && <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading timeline...</div>}

      {!loading && patient && (
        <div style={{ display: 'grid', gridTemplateColumns: '1fr 280px', gap: 20, alignItems: 'start' }}>
          <div>
            <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
              <div style={{ padding: '12px 14px', background: 'var(--g50)', borderBottom: '1px solid var(--g200)', display: 'flex', gap: 8 }}>
                <select className="fi fi-sm" style={{ width: 'auto' }} value={filter} onChange={(e) => setFilter(e.target.value)}>
                  <option value="">All events</option>
                  <option value="Visit">OPD Visits</option>
                  <option value="Diagnosis">Diagnoses</option>
                  <option value="Investigation">Investigations</option>
                  <option value="Surgery">Surgeries</option>
                  <option value="Prescription">Prescriptions</option>
                </select>
              </div>
              <div style={{ padding: 16 }}>
                {filteredEvents.length === 0 && (
                  <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>No events match this filter.</div>
                )}
                {filteredEvents.map((ev, i) => (
                  <div key={i} style={{ display: 'flex', gap: 12 }}>
                    <div style={{ display: 'flex', flexDirection: 'column', alignItems: 'center', width: 16, flexShrink: 0 }}>
                      <div style={{ width: 12, height: 12, borderRadius: '50%', background: TYPE_COLOR[ev.type], border: '2px solid #fff', boxShadow: '0 0 0 2px var(--g200)', flexShrink: 0 }}></div>
                      {i < filteredEvents.length - 1 && <div style={{ width: 2, background: 'var(--g200)', flex: 1, minHeight: 20, margin: '3px 0' }}></div>}
                    </div>
                    <div style={{ flex: 1, paddingBottom: 16, cursor: 'pointer' }} onClick={() => setSelectedEvent(ev)}>
                      <div style={{ fontSize: 10, fontWeight: 700, color: 'var(--g400)', textTransform: 'uppercase', letterSpacing: '.4px', marginBottom: 3 }}>
                        {new Date(ev.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' })}
                      </div>
                      <div style={{ border: ev.type === 'Visit' && ev.queueEntryId ? '1.5px solid var(--blue)' : '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px', display: 'flex', alignItems: 'center', gap: 8 }}>
                        <div style={{ flex: 1 }}>
                          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 6 }}>
                            <i className={`ti ${TYPE_ICON[ev.type]}`} style={{ color: TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                          </div>
                          <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{ev.detail}</div>
                        </div>
                        {ev.type === 'Visit' && ev.queueEntryId && (
                          <i className="ti ti-chevron-right" style={{ color: 'var(--blue)' }}></i>
                        )}
                      </div>
                    </div>
                  </div>
                ))}
              </div>
            </div>
          </div>

          <div>
            {selectedEvent && (
              <div className="card" style={{ marginBottom: 16 }}>
                <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-file"></i> Event Detail</div>
                <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Type</span><span className="badge" style={{ background: `${TYPE_COLOR[selectedEvent.type]}20`, color: TYPE_COLOR[selectedEvent.type] }}>{selectedEvent.type}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Date</span><span>{new Date(selectedEvent.date).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })}</span></div>
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Visit</span><span style={{ fontFamily: 'monospace' }}>{selectedEvent.visit}</span></div>
                  <div style={{ marginTop: 6 }}><strong>{selectedEvent.title}</strong></div>
                  <div style={{ color: 'var(--g500)', marginTop: 2 }}>{selectedEvent.detail}</div>
                </div>
                <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 8 }}>Read-only. Editing happens through the corresponding encounter only.</div>
                {selectedEvent.type === 'Visit' && selectedEvent.queueEntryId && (
                  <Link
                    href={`/consultation/${selectedEvent.queueEntryId}`}
                    className="btn btn-primary btn-sm"
                    style={{ marginTop: 10, width: '100%', textAlign: 'center', textDecoration: 'none', display: 'block' }}
                  >
                    <i className="ti ti-file-text"></i> Open Clinical Record
                  </Link>
                )}
                {selectedEvent.type === 'Visit' && !selectedEvent.queueEntryId && (
                  <div style={{ fontSize: 10, color: 'var(--g400)', marginTop: 6 }}>No clinical record was created for this visit.</div>
                )}
                {selectedEvent.type === 'Investigation' && selectedEvent.id && (
                  selectedEvent.title?.trim().toLowerCase() === 'biometry' ? (
                    <a
                      href={`/biometry/${selectedEvent.id}`}
                      target="_blank"
                      rel="noopener noreferrer"
                      className="btn btn-primary btn-sm"
                      style={{ marginTop: 10, width: '100%', justifyContent: 'center', textDecoration: 'none' }}
                    >
                      <i className="ti ti-ruler-measure"></i> Open Biometry
                    </a>
                  ) : (
                    <button
                      className="btn btn-primary btn-sm"
                      style={{ marginTop: 10, width: '100%', justifyContent: 'center' }}
                      onClick={() => openPopup(`/investigation/${selectedEvent.id}?mode=view`, `inv-${selectedEvent.id}`)}
                    >
                      <i className="ti ti-eye"></i> View Result
                    </button>
                  )
                )}
              </div>
            )}

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Timeline Summary</div>
              <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Patient</span><span style={{ fontWeight: 600 }}>{formatPatientName(patient)}</span></div>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Total events</span><span style={{ fontWeight: 700 }}>{events.length}</span></div>
                {Object.entries(counts).map(([type, count]) => (
                  <div key={type} style={{ display: 'flex', justifyContent: 'space-between' }}>
                    <span>{type}</span><span className="badge" style={{ background: `${TYPE_COLOR[type]}20`, color: TYPE_COLOR[type] }}>{count}</span>
                  </div>
                ))}
              </div>
            </div>
          </div>
        </div>
      )}

      {!loading && !patient && (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-search" style={{ fontSize: 32, display: 'block', marginBottom: 10 }}></i>
          Search for a patient above to view their clinical timeline.
        </div>
      )}
    </div>
  );
}

export default function PatientTimelinePage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>}>
      <PatientTimelineInner />
    </Suspense>
  );
}

