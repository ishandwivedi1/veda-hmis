#!/usr/bin/env bash
# Makes 'Visit' entries in the Patient Timeline (Ophthalmologist module)
# clickable, opening the same locked/unlock-to-edit clinical record view
# used by Doctor Dashboard's Completed Today -- reuses that exact
# /consultation/[id] route unchanged (getConsultationData() looks up
# everything by visit_id internally, so any queue_entries row for that
# visit works as the 'door in' -- Doctor department preferred when both
# Optometry and Doctor entries exist for the same visit).
#
# Also fixes the SAME wrong-column-name bug found in consultation/actions.js
# (encounters has no created_at, only started_at) -- this one was silently
# swallowed here too, meaning Diagnosis/Investigation/Prescription events
# have likely NEVER shown up in the timeline, only Visit and Surgery.
set -euo pipefail

echo "==> Writing updated files..."
cat > "app/(main)/patient-timeline/actions.js" << 'VEDA_EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function searchPatients(query) {
  if (!query || query.trim().length < 2) return [];
  const supabase = await createClient();
  const q = query.trim();
  const { data } = await supabase
    .from('patients')
    .select('id, first_name, last_name, uhid, age, gender')
    .or(`first_name.ilike.%${q}%,last_name.ilike.%${q}%,uhid.ilike.%${q}%`)
    .limit(10);
  return data || [];
}

// Aggregates real events across every visit this patient has ever had --
// visits, diagnoses, investigations, prescriptions, and surgical cases --
// into one read-only chronological feed (Section 9.9: read-only
// longitudinal history).
export async function getPatientTimeline(patientId) {
  const supabase = await createClient();

  const [{ data: patient }, { data: visits }, { data: surgicalCases }] = await Promise.all([
    supabase.from('patients').select('*').eq('id', patientId).single(),
    supabase
      .from('visits')
      .select('id, visit_number, visit_type, status, created_at, profiles(full_name)')
      .eq('patient_id', patientId)
      .order('created_at', { ascending: false }),
    supabase.from('surgical_cases').select('*').eq('patient_id', patientId).order('created_at', { ascending: false }),
  ]);

  const visitIds = (visits || []).map((v) => v.id);

  let encounters = [];
  if (visitIds.length > 0) {
    const { data } = await supabase.from('encounters').select('id, visit_id, started_at').in('visit_id', visitIds);
    encounters = data || [];
  }
  const encounterIds = encounters.map((e) => e.id);

  // One queue_entries row per visit, to link a "Visit" timeline event
  // through to its actual clinical record (same /consultation/[id] route
  // used by Doctor Dashboard's Completed Today -- getConsultationData()
  // looks up everything by visit_id internally, so it doesn't matter
  // which department's queue entry we use as the "door in", but Doctor
  // is preferred since that's the consultation itself.
  let queueEntryByVisit = {};
  if (visitIds.length > 0) {
    const { data: qEntries } = await supabase
      .from('queue_entries')
      .select('id, visit_id, department, issued_at')
      .in('visit_id', visitIds)
      .order('issued_at', { ascending: false });
    (qEntries || []).forEach((q) => {
      const existing = queueEntryByVisit[q.visit_id];
      if (!existing || (q.department === 'Doctor' && existing.department !== 'Doctor')) {
        queueEntryByVisit[q.visit_id] = q;
      }
    });
  }

  let diagnoses = [], investigations = [], prescriptions = [];
  if (encounterIds.length > 0) {
    const [{ data: d }, { data: i }, { data: p }] = await Promise.all([
      supabase.from('diagnoses').select('*').in('encounter_id', encounterIds),
      supabase.from('investigation_orders').select('*').in('encounter_id', encounterIds),
      supabase.from('prescriptions').select('*').in('encounter_id', encounterIds),
    ]);
    diagnoses = d || []; investigations = i || []; prescriptions = p || [];
  }

  const visitById = {};
  (visits || []).forEach((v) => { visitById[v.id] = v; });
  const encounterById = {};
  encounters.forEach((e) => { encounterById[e.id] = e; });

  const events = [];

  (visits || []).forEach((v) => {
    events.push({
      type: 'Visit', date: v.created_at, title: v.visit_type,
      detail: `${v.visit_number || '--'} -- ${v.profiles?.full_name || 'Doctor not assigned'} -- ${v.status}`,
      visit: v.visit_number || '--',
      queueEntryId: queueEntryByVisit[v.id]?.id || null,
    });
  });

  diagnoses.forEach((d) => {
    const visit = visitById[encounterById[d.encounter_id]?.visit_id];
    events.push({
      type: 'Diagnosis', date: d.created_at, title: d.name,
      detail: `${d.eye} -- ${d.category} -- ${d.status}`,
      visit: visit?.visit_number || '--',
    });
  });

  investigations.forEach((i) => {
    const visit = visitById[encounterById[i.encounter_id]?.visit_id];
    events.push({
      type: 'Investigation', date: i.created_at, title: i.name,
      detail: `${i.eye} -- ${i.status}${i.result_notes ? ` -- ${i.result_notes}` : ''}`,
      visit: visit?.visit_number || '--',
    });
  });

  prescriptions.forEach((r) => {
    const visit = visitById[encounterById[r.encounter_id]?.visit_id];
    events.push({
      type: 'Prescription', date: r.created_at, title: r.drug_name,
      detail: `${r.dosage} ${r.frequency} x ${r.duration} -- ${r.eye}`,
      visit: visit?.visit_number || '--',
    });
  });

  (surgicalCases || []).forEach((s) => {
    events.push({
      type: 'Surgery', date: s.created_at, title: s.procedure_name,
      detail: `${s.eye || '--'} -- ${s.status}`,
      visit: '--',
    });
  });

  events.sort((a, b) => new Date(b.date) - new Date(a.date));

  return { patient, events };
}
VEDA_EOF
echo "  wrote app/(main)/patient-timeline/actions.js"

cat > "app/(main)/patient-timeline/page.js" << 'VEDA_EOF'
'use client';

import Link from 'next/link';
import { useState } from 'react';
import { searchPatients, getPatientTimeline } from './actions';

const TYPE_COLOR = {
  Visit: 'var(--blue)',
  Diagnosis: 'var(--red)',
  Investigation: 'var(--teal)',
  Prescription: 'var(--purple)',
  Surgery: 'var(--amber)',
};
const TYPE_ICON = {
  Visit: 'ti-door-enter',
  Diagnosis: 'ti-clipboard-list',
  Investigation: 'ti-flask',
  Prescription: 'ti-pill',
  Surgery: 'ti-scalpel',
};

export default function PatientTimelinePage() {
  const [query, setQuery] = useState('');
  const [results, setResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [events, setEvents] = useState([]);
  const [filter, setFilter] = useState('');
  const [selectedEvent, setSelectedEvent] = useState(null);
  const [loading, setLoading] = useState(false);

  async function handleSearch(val) {
    setQuery(val);
    if (val.trim().length < 2) { setResults([]); return; }
    const rows = await searchPatients(val);
    setResults(rows);
  }

  async function handleSelectPatient(p) {
    setLoading(true);
    setResults([]);
    setQuery(`${p.first_name} ${p.last_name} -- ${p.uhid}`);
    setSelectedEvent(null);
    const result = await getPatientTimeline(p.id);
    setLoading(false);
    setPatient(result.patient);
    setEvents(result.events);
  }

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
                  <strong>{p.first_name} {p.last_name}</strong> <span style={{ color: 'var(--g400)', fontSize: 11 }}>{p.uhid} -- {p.age} {p.gender}</span>
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
                        {new Date(ev.date).toLocaleDateString('en-IN', { day: 'numeric', month: 'short', year: 'numeric' })}
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
                  <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Date</span><span>{new Date(selectedEvent.date).toLocaleDateString('en-IN')}</span></div>
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
              </div>
            )}

            <div className="card">
              <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-chart-bar" style={{ color: 'var(--blue)' }}></i> Timeline Summary</div>
              <div style={{ fontSize: 12, lineHeight: 1.9 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}><span>Patient</span><span style={{ fontWeight: 600 }}>{patient.first_name} {patient.last_name}</span></div>
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
VEDA_EOF
echo "  wrote app/(main)/patient-timeline/page.js"

echo ""
echo "==> Done. Next steps:"
echo "  1. npm run build"
echo "  2. git add -A && git commit -m \"Patient Timeline: link Visit events to locked clinical record; fix"
echo "     encounters column name (was silently hiding Diagnosis/Investigation/"
echo "     Prescription events)\" && git push"
echo "  3. Re-test: search Shriram Singla, click his Visit event -- should show"
echo "     an Open Clinical Record button, and Diagnosis events should now"
echo "     appear for any patient with prior recorded diagnoses."
