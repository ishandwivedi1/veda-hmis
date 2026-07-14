mkdir -p "app/components" "app/(main)/patient-timeline" "app/(main)/workflow-monitor"

cat > "app/components/AppShell.js" << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/reports', label: 'Reports', icon: 'ti-chart-bar', section: 'Overview' },
  { href: '/front-office-dashboard', label: 'Front Office Dashboard', icon: 'ti-user-check', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/billing', label: 'Billing', icon: 'ti-receipt', section: 'Front Office' },
  { href: '/payments', label: 'Payments', icon: 'ti-cash', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
  { href: '/doctor-dashboard', label: 'Doctor Dashboard', icon: 'ti-stethoscope', section: 'Ophthalmologist' },
  { href: '/patient-timeline', label: 'Patient Timeline', icon: 'ti-timeline', section: 'Ophthalmologist' },
  { href: '/workflow-monitor', label: 'Workflow Monitor', icon: 'ti-activity', section: 'Ophthalmologist' },
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
  { href: '/optometry-history', label: 'Optometry History', icon: 'ti-history', section: 'Optometrist' },
  { href: '/optometry-reports', label: 'Optometry Reports', icon: 'ti-chart-bar', section: 'Optometrist' },
  { href: '/surgical', label: 'Surgical Coordination', icon: 'ti-scalpel', section: 'Surgical' },
  { href: '/ot-schedule', label: 'OT Scheduling', icon: 'ti-calendar-time', section: 'Surgical' },
  { href: '/master-data', label: 'Master Data', icon: 'ti-database', section: 'Administration' },
  { href: '/users', label: 'User Management', icon: 'ti-users-group', section: 'Administration' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/reports/, title: 'Reports' },
  { match: /^\/front-office-dashboard/, title: 'Front Office Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/doctor-dashboard/, title: 'Doctor Dashboard' },
  { match: /^\/patient-timeline/, title: 'Patient Timeline' },
  { match: /^\/workflow-monitor/, title: 'Workflow Monitor' },
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
  { match: /^\/optometry-history/, title: 'Optometry History' },
  { match: /^\/optometry-reports/, title: 'Optometry Reports' },
  { match: /^\/optometry/, title: 'Optometry Assessment' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/payments/, title: 'Payments' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
  { match: /^\/surgical/, title: 'Surgical Coordination' },
  { match: /^\/ot-schedule/, title: 'OT Scheduling' },
  { match: /^\/master-data/, title: 'Master Data' },
  { match: /^\/users/, title: 'User Management' },
];

export default function AppShell({ children }) {
  const pathname = usePathname();
  const router = useRouter();
  const supabase = createClient();
  const [profile, setProfile] = useState(null);
  const [today, setToday] = useState('');

  const pageTitle = PAGE_TITLES.find((t) => t.match.test(pathname))?.title || 'VEDA HMIS';

  useEffect(() => {
    setToday(new Date().toLocaleDateString('en-IN', { weekday: 'short', day: 'numeric', month: 'short', year: 'numeric' }));

    supabase.auth.getUser().then(async ({ data: { user } }) => {
      if (!user) return;
      const { data } = await supabase.from('profiles').select('*').eq('id', user.id).single();
      setProfile(data);
    });
  }, []);

  async function handleSignOut() {
    await supabase.auth.signOut();
    router.push('/login');
    router.refresh();
  }

  const sections = [...new Set(NAV_ITEMS.map((i) => i.section))];

  return (
    <div className="app-layout">
      <div className="sidebar">
        <div className="sb-logo">
          <div className="sb-logo-icon"><i className="ti ti-eye"></i></div>
          <div>
            <div className="sb-name">VEDA HMIS</div>
            <div className="sb-sub">Veda Eye Hospital</div>
          </div>
        </div>
        {sections.map((section) => (
          <div key={section}>
            <div className="sb-sec">{section}</div>
            {NAV_ITEMS.filter((i) => i.section === section).map((item) => (
              <Link
                key={item.href}
                href={item.href}
                className={`sb-item ${pathname.startsWith(item.href) ? 'active' : ''}`}
              >
                <span className="sb-icon-wrap"><i className={`ti ${item.icon}`}></i></span>
                {item.label}
              </Link>
            ))}
          </div>
        ))}
      </div>

      <div className="main-area">
        <div className="topbar">
          <div>
            <div className="top-title">{pageTitle}</div>
            <div className="top-sub">Veda Eye Hospital</div>
          </div>
          <div style={{ display: 'flex', alignItems: 'center', gap: 16 }}>
            <div style={{ textAlign: 'right' }}>
              <div style={{ fontSize: 12, color: 'var(--g500)' }}>{today}</div>
              {profile && (
                <div style={{ fontSize: 11, color: 'var(--g400)' }}>
                  {profile.full_name} -- {profile.designation}
                </div>
              )}
            </div>
            <button className="btn btn-sm" onClick={handleSignOut}>Sign out</button>
          </div>
        </div>
        <div className="content-area">{children}</div>
      </div>
    </div>
  );
}


EOF

cat > "app/(main)/patient-timeline/actions.js" << 'EOF'
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
    const { data } = await supabase.from('encounters').select('id, visit_id, created_at').in('visit_id', visitIds);
    encounters = data || [];
  }
  const encounterIds = encounters.map((e) => e.id);

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

EOF

cat > "app/(main)/patient-timeline/page.js" << 'EOF'
'use client';

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
                      <div style={{ border: '1px solid var(--g200)', borderRadius: 8, padding: '8px 10px' }}>
                        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 6 }}>
                          <i className={`ti ${TYPE_ICON[ev.type]}`} style={{ color: TYPE_COLOR[ev.type] }}></i> {ev.type} -- {ev.title}
                        </div>
                        <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 2 }}>{ev.detail}</div>
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

EOF

cat > "app/(main)/workflow-monitor/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getWorkflowMonitorData() {
  const supabase = await createClient();

  const { data: encounters } = await supabase
    .from('encounters')
    .select('*, visits(id, visit_number, patients(first_name, last_name, uhid)), profiles!encounters_doctor_id_fkey(full_name)')
    .eq('status', 'In Consultation')
    .order('started_at', { ascending: true });

  const rows = encounters || [];
  const encounterIds = rows.map((e) => e.id);
  const visitIds = rows.map((e) => e.visits?.id).filter(Boolean);

  let queueEntryByVisit = {};
  if (visitIds.length > 0) {
    const { data: qe } = await supabase
      .from('queue_entries')
      .select('id, visit_id, status')
      .eq('department', 'Doctor')
      .in('visit_id', visitIds);
    (qe || []).forEach((q) => { queueEntryByVisit[q.visit_id] = q; });
  }

  // "Transitions" -- count of state-changing audit entries for this
  // encounter (sent for dilation/investigation, workflow requested or
  // cancelled). A genuine count from the persisted audit log, not a
  // simulated counter.
  let transitionCountByEncounter = {};
  if (encounterIds.length > 0) {
    const { data: logs } = await supabase
      .from('encounter_audit_log')
      .select('encounter_id, message')
      .in('encounter_id', encounterIds);
    (logs || []).forEach((l) => {
      if (/^(Sent for|Workflow requested|Workflow request cancelled)/.test(l.message)) {
        transitionCountByEncounter[l.encounter_id] = (transitionCountByEncounter[l.encounter_id] || 0) + 1;
      }
    });
  }

  return rows.map((e) => ({
    ...e,
    queueStatus: queueEntryByVisit[e.visits?.id]?.status || '--',
    queueEntryId: queueEntryByVisit[e.visits?.id]?.id || null,
    transitions: transitionCountByEncounter[e.id] || 0,
  }));
}

EOF

cat > "app/(main)/workflow-monitor/page.js" << 'EOF'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getWorkflowMonitorData } from './actions';

const STATE_MATRIX = [
  { from: 'Waiting (Optometry)', event: 'Call Next / Call', to: 'Calling (Optometry)' },
  { from: 'Calling (Optometry)', event: 'Complete Assessment', to: 'Done -- Doctor token issued' },
  { from: 'Waiting (Doctor)', event: 'Call Next / Call', to: 'In Consultation' },
  { from: 'In Consultation', event: 'Send for Dilation', to: 'Awaiting Dilation' },
  { from: 'In Consultation', event: 'Send for Investigation', to: 'Awaiting Investigation' },
  { from: 'Awaiting Dilation / Investigation', event: 'Mark Ready', to: 'Ready for Review' },
  { from: 'Ready for Review', event: 'Call', to: 'In Consultation' },
  { from: 'In Consultation', event: 'Complete Visit', to: 'Done -- Encounter Completed' },
  { from: 'Requested (Biometry / Fitness / Counselling)', event: 'Toggle again, or Mark Done', to: 'Cancelled or Completed' },
];

function stateBadgeClass(state) {
  if (state === '--') return 'b-gray';
  if (state.includes('Awaiting')) return 'b-purple';
  if (state === 'Ready for Review') return 'b-green';
  if (state === 'In Consultation') return 'b-blue';
  return 'b-gray';
}

function elapsedMin(iso) {
  if (!iso) return 0;
  return Math.floor((Date.now() - new Date(iso).getTime()) / 60000);
}

export default function WorkflowMonitorPage() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);

  const refresh = useCallback(async () => {
    const data = await getWorkflowMonitorData();
    setRows(data);
    setLoading(false);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-head">
          <div className="card-title"><i className="ti ti-activity" style={{ color: 'var(--blue)' }}></i> Workflow Status Monitor</div>
          <span style={{ fontSize: 11, color: 'var(--g400)' }}>Live view -- all in-progress consultations</span>
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
          <i className="ti ti-info-circle"></i> Workflow-driven architecture -- all state transitions are logged. No manual patient routing.
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> State Transition Matrix</div>
        <table className="tbl">
          <thead><tr><th>From State</th><th>Event</th><th>Next State</th></tr></thead>
          <tbody>
            {STATE_MATRIX.map((s, i) => (
              <tr key={i}>
                <td><span className={`badge ${stateBadgeClass(s.from)}`} style={{ fontSize: 11 }}>{s.from}</span></td>
                <td style={{ fontSize: 12, color: 'var(--g600)' }}>{s.event}</td>
                <td><span className={`badge ${stateBadgeClass(s.to)}`} style={{ fontSize: 11 }}>{s.to}</span></td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>

      <div className="card">
        <div className="card-head">
          <div className="card-title"><i className="ti ti-list" style={{ color: 'var(--blue)' }}></i> All Active Encounters</div>
          <span className="badge b-blue">{rows.length} encounters</span>
        </div>
        <table className="tbl">
          <thead>
            <tr><th>Patient</th><th>UHID</th><th>Visit</th><th>Doctor</th><th>Queue State</th><th>Time in Consultation</th><th>Transitions</th><th></th></tr>
          </thead>
          <tbody>
            {rows.map((e) => (
              <tr key={e.id}>
                <td style={{ fontWeight: 600 }}>{e.visits?.patients?.first_name} {e.visits?.patients?.last_name}</td>
                <td style={{ fontSize: 11, fontFamily: 'monospace' }}>{e.visits?.patients?.uhid}</td>
                <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.visits?.visit_number || '--'}</td>
                <td style={{ fontSize: 12 }}>{e.profiles?.full_name || '--'}</td>
                <td><span className={`badge ${stateBadgeClass(e.queueStatus)}`} style={{ fontSize: 10 }}>{e.queueStatus}</span></td>
                <td style={{ fontSize: 11, color: 'var(--g500)' }}>{elapsedMin(e.started_at)}m</td>
                <td style={{ textAlign: 'center' }}><span className="badge b-gray">{e.transitions}</span></td>
                <td>
                  {e.queueEntryId && (
                    <Link href={`/consultation/${e.queueEntryId}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>Open</Link>
                  )}
                </td>
              </tr>
            ))}
            {!loading && rows.length === 0 && (
              <tr><td colSpan={8} style={{ padding: 24, textAlign: 'center', color: 'var(--g400)' }}>No encounters in progress right now.</td></tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

echo "Ophthalmologist Section Phase 2 batch 3 (Patient Timeline + Workflow Monitor) created/updated -- Phase 2 complete."