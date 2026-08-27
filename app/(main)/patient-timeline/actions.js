'use server';

import { createClient } from '@/lib/supabase-server';

export async function searchPatients(query) {
  if (!query || query.trim().length < 2) return [];
  const supabase = await createClient();
  const q = query.trim();
  const { data } = await supabase
    .from('patients')
    .select('id, first_name, salutation, last_name, uhid, age, gender')
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
      .select('id, visit_number, visit_type, status, created_at, profiles!doctor_id(full_name)')
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
      id: i.id, status: i.status,
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

