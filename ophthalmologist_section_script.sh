mkdir -p "app/components" "app/(main)/doctor-dashboard" "app/(main)/consultation" "app/(main)/consultation/[id]"

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

cat > "app/(main)/doctor-dashboard/page.js" << 'EOF'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getDoctorDashboardData } from './actions';
import { doctorCallNext, doctorCallSpecific, doctorMarkReady } from '@/app/(main)/queue/actions';

function elapsedMin(isoString) {
  if (!isoString) return 0;
  return Math.floor((Date.now() - new Date(isoString).getTime()) / 60000);
}

function waitBadgeClass(mins) {
  if (mins >= 20) return 'b-red';
  if (mins >= 10) return 'b-amber';
  return 'b-green';
}

function patientName(entry) {
  const p = entry.visits?.patients;
  return p ? `${p.first_name} ${p.last_name}` : 'Unknown';
}

function TokenBadge({ token, color }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: color || 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

export default function DoctorDashboardPage() {
  const [active, setActive] = useState([]);
  const [intermediate, setIntermediate] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const result = await getDoctorDashboardData();
    setActive(result.active);
    setIntermediate(result.intermediate);
    setCompleted(result.completed);
  }, []);

  useEffect(() => {
    refresh();
    const interval = setInterval(refresh, 15000);
    return () => clearInterval(interval);
  }, [refresh]);

  async function runAction(fn, ...args) {
    setError('');
    const result = await fn(...args);
    if (result?.error) setError(result.error);
    refresh();
  }

  const inConsultation = active.find((e) => e.status === 'In Consultation');
  const waitingCount = active.filter((e) => e.status === 'Waiting' || e.status === 'Ready for Review').length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Consultation</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{inConsultation ? 1 : 0}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>With doctor now</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting for Doctor</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>In doctor queue</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Intermediate</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{intermediate.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Dilation / Investigation</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Completed Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{completed.length}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Encounters closed</div>
        </div>
      </div>

      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 16 }}>
        <i className="ti ti-info-circle"></i> Live token order and wait times are managed in Queue Management -- this dashboard shows clinical context for patients already in that queue. <Link href="/queue" style={{ color: 'var(--blue)', fontWeight: 600 }}>Open Queue Management &rarr;</Link>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* DOCTOR QUEUE */}
        <div className="card">
          <div className="card-head">
            <div className="card-title"><i className="ti ti-stethoscope" style={{ color: 'var(--blue)' }}></i> Doctor Queue<span className="badge b-gray">{active.length}</span></div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(doctorCallNext)} disabled={!!inConsultation}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>

          {inConsultation && (
            <div style={{ background: 'var(--blue-lt)', padding: 12, borderRadius: 8, marginBottom: 12 }}>
              <div style={{ display: 'flex', alignItems: 'center', marginBottom: 8 }}>
                <TokenBadge token={inConsultation.token} color="var(--blue)" />
                <span style={{ fontWeight: 700, fontSize: 14 }}>{patientName(inConsultation)}</span>
              </div>
              <Link href={`/consultation/${inConsultation.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                <i className="ti ti-clipboard-text"></i> Open Consultation
              </Link>
            </div>
          )}

          {active.filter((e) => e.id !== inConsultation?.id).map((e) => (
            <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6 }}>
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} color={e.status === 'Ready for Review' ? 'var(--green)' : 'var(--amber)'} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Ready for Review' ? 'b-green' : 'b-amber'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}><i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m</span>
                </div>
              </div>
              <button className="btn btn-sm" onClick={() => runAction(doctorCallSpecific, e.id)} disabled={!!inConsultation}>Call</button>
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        <div>
          {/* INTERMEDIATE QUEUES */}
          <div className="card" style={{ marginBottom: 16 }}>
            <div className="card-head">
              <div className="card-title"><i className="ti ti-arrows-exchange" style={{ color: 'var(--purple)' }}></i> Intermediate Queues<span className="badge b-gray">{intermediate.length}</span></div>
            </div>
            {intermediate.map((e) => (
              <div key={e.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 6px', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <div>
                  <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span>{' '}
                  {patientName(e)}
                  <div style={{ fontSize: 11, color: 'var(--g500)' }}>{e.status} -- {elapsedMin(e.sent_out_at)}m</div>
                </div>
                <button className="btn btn-sm" onClick={() => runAction(doctorMarkReady, e.id)}>Mark Ready</button>
              </div>
            ))}
            {intermediate.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No one in Dilation or Investigation.</div>}
          </div>

          {/* COMPLETED TODAY */}
          <div className="card">
            <div className="card-head">
              <div className="card-title"><i className="ti ti-circle-check" style={{ color: 'var(--green)' }}></i> Completed Today<span className="badge b-green">{completed.length}</span></div>
            </div>
            {completed.slice(0, 8).map((e) => (
              <div key={e.id} style={{ padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 12 }}>
                <span style={{ fontFamily: 'monospace', fontWeight: 700 }}>{e.token}</span> {patientName(e)}
                <div style={{ fontSize: 11, color: 'var(--g500)' }}>
                  {e.completed_at ? new Date(e.completed_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' }) : '--'}
                </div>
              </div>
            ))}
            {completed.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing completed yet today.</div>}
          </div>
        </div>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/doctor-dashboard/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getDoctorDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: active }, { data: intermediate }, { data: completed }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .in('status', ['Waiting', 'Ready for Review', 'In Consultation'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .in('status', ['Awaiting Dilation', 'Awaiting Investigation'])
      .gte('issued_at', today)
      .order('sent_out_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Doctor')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
  ]);

  return { active: active || [], intermediate: intermediate || [], completed: completed || [] };
}

EOF

cat > "app/(main)/consultation/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';
import { doctorComplete, doctorSendOut } from '@/app/(main)/queue/actions';

export async function getConsultationData(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, doctor_id, patients(id, first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits.id;

  const { data: findings } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'Completed')
    .maybeSingle();

  let iopReadings = [];
  if (findings) {
    const { data: readings } = await supabase
      .from('optometry_iop_readings')
      .select('*')
      .eq('assessment_id', findings.id)
      .order('recorded_at', { ascending: true });
    iopReadings = readings || [];
  }

  let { data: encounter } = await supabase
    .from('encounters')
    .select('*')
    .eq('visit_id', visitId)
    .eq('status', 'In Consultation')
    .maybeSingle();

  if (!encounter) {
    const { data: newEncounter, error: encError } = await supabase
      .from('encounters')
      .insert({ visit_id: visitId, doctor_id: entry.visits.doctor_id })
      .select()
      .single();
    if (encError) return { error: encError.message };
    encounter = newEncounter;
  }

  // Section 12: exam is 1:1 with the encounter, auto-created on first
  // open -- same pattern as the encounter itself and the optometry
  // assessment.
  let { data: examination } = await supabase
    .from('clinical_examinations')
    .select('*')
    .eq('encounter_id', encounter.id)
    .maybeSingle();

  if (!examination) {
    const { data: newExam, error: examError } = await supabase
      .from('clinical_examinations')
      .insert({ encounter_id: encounter.id })
      .select()
      .single();
    if (examError) return { error: examError.message };
    examination = newExam;
  }

  const [{ data: diagnoses }, { data: prescriptions }, { data: investigations }] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
  ]);

  return { entry, findings, iopReadings, encounter, examination, diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [] };
}

// ── EXAMINATION (Section 12, M19 Examination tab) ──
export async function saveExamination(examinationId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('clinical_examinations')
    .update({ ...fields, recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', examinationId);

  if (error) return { error: error.message };
  return { success: true };
}

// ── DIAGNOSES ──
export async function addDiagnosis(encounterId, values) {
  const supabase = await createClient();

  if (values.category === 'primary') {
    const { data: existing } = await supabase
      .from('diagnoses')
      .select('id, name')
      .eq('encounter_id', encounterId)
      .eq('category', 'primary')
      .eq('status', 'Active');

    if (existing && existing.length > 0) {
      return { error: `"${existing[0].name}" is already the primary diagnosis. Change it to secondary first, or remove it, before adding a new primary.` };
    }
  }

  const { error } = await supabase.from('diagnoses').insert({
    encounter_id: encounterId,
    name: values.name,
    category: values.category,
    eye: values.eye,
  });

  if (error) return { error: error.message };
  return { success: true };
}

export async function removeDiagnosis(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('diagnoses').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── PRESCRIPTIONS ──
export async function addPrescription(encounterId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').insert({
    encounter_id: encounterId,
    drug_name: values.drugName,
    dosage: values.dosage,
    frequency: values.frequency,
    duration: values.duration,
    eye: values.eye,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removePrescription(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── INVESTIGATIONS ──
export async function addInvestigation(encounterId, values) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').insert({
    encounter_id: encounterId,
    name: values.name,
    eye: values.eye,
    priority: values.priority,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').delete().eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

// ── ENCOUNTER ACTIONS ──
export async function completeConsultation(encounterId, queueEntryId) {
  const supabase = await createClient();

  const { error } = await supabase
    .from('encounters')
    .update({ status: 'Completed', completed_at: new Date().toISOString() })
    .eq('id', encounterId);

  if (error) return { error: error.message };

  return doctorComplete(queueEntryId);
}

export async function sendForDilationFromConsultation(queueEntryId) {
  return doctorSendOut(queueEntryId, 'dilate');
}

export async function sendForInvestigationFromConsultation(queueEntryId) {
  return doctorSendOut(queueEntryId, 'investigate');
}


EOF

cat > "app/(main)/consultation/[id]/consultation-form.js" << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import {
  getConsultationData,
  addDiagnosis,
  removeDiagnosis,
  addPrescription,
  removePrescription,
  addInvestigation,
  removeInvestigation,
  completeConsultation,
  sendForDilationFromConsultation,
  sendForInvestigationFromConsultation,
} from '@/app/(main)/consultation/actions';
import { markForSurgery } from '@/app/(main)/surgical/actions';
import ExaminationTab from './examination-tab';

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
  const [activeTab, setActiveTab] = useState('exam');
  const router = useRouter();

  // Diagnosis form
  const [dxName, setDxName] = useState('');
  const [dxCategory, setDxCategory] = useState('primary');
  const [dxEye, setDxEye] = useState('OU');

  // Prescription form
  const [rxDrug, setRxDrug] = useState('');
  const [rxDosage, setRxDosage] = useState('1 drop');
  const [rxFrequency, setRxFrequency] = useState('BD');
  const [rxDuration, setRxDuration] = useState('1 week');
  const [rxEye, setRxEye] = useState('BE');

  // Investigation form
  const [invName, setInvName] = useState('');
  const [invEye, setInvEye] = useState('OU');
  const [invPriority, setInvPriority] = useState('Routine');

  const refresh = useCallback(async () => {
    const result = await getConsultationData(queueEntryId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [queueEntryId]);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function handleAddDiagnosis() {
    setError('');
    if (!dxName.trim()) { setError('Diagnosis name is required.'); return; }
    const result = await addDiagnosis(data.encounter.id, { name: dxName, category: dxCategory, eye: dxEye });
    if (result.error) { setError(result.error); return; }
    setDxName('');
    refresh();
  }

  async function handleAddPrescription() {
    setError('');
    if (!rxDrug.trim()) { setError('Drug name is required.'); return; }
    const result = await addPrescription(data.encounter.id, {
      drugName: rxDrug, dosage: rxDosage, frequency: rxFrequency, duration: rxDuration, eye: rxEye,
    });
    if (result.error) { setError(result.error); return; }
    setRxDrug('');
    refresh();
  }

  async function handleAddInvestigation() {
    setError('');
    if (!invName.trim()) { setError('Investigation name is required.'); return; }
    const result = await addInvestigation(data.encounter.id, { name: invName, eye: invEye, priority: invPriority });
    if (result.error) { setError(result.error); return; }
    setInvName('');
    refresh();
  }

  async function handleComplete() {
    setError('');
    if (!data.diagnoses.length) {
      setError('Add at least one diagnosis before completing the visit.');
      return;
    }
    setLoading(true);
    const result = await completeConsultation(data.encounter.id, queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  async function handleMarkForSurgery() {
    setError('');
    if (!surgeryProcedure.trim()) { setError('Procedure name is required.'); return; }
    setSurgeryLoading(true);
    const result = await markForSurgery(data.entry.visits.patients.id, data.encounter.id, surgeryProcedure, surgeryEye);
    setSurgeryLoading(false);
    if (result.error) { setError(result.error); return; }
    setShowSurgery(false);
    setSurgeryProcedure('');
  }

  async function handleSendOut(kind) {
    setError('');
    setLoading(true);
    const result = kind === 'dilate'
      ? await sendForDilationFromConsultation(queueEntryId)
      : await sendForInvestigationFromConsultation(queueEntryId);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    router.push('/queue');
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '0 auto' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.entry.visits.patients;
  const f = data.findings;

  return (
    <div style={{ maxWidth: 900, margin: '0 auto' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 18, fontWeight: 700 }}><i className="ti ti-stethoscope" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Consultation -- {data.entry.token}</div>
        <div style={{ fontSize: 13, color: 'var(--g500)' }}>
          {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.age} {patient.gender}
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {f && (() => {
        const latestIop = (eye) => {
          const readings = (data.iopReadings || []).filter((r) => r.eye === eye);
          return readings.length ? readings[readings.length - 1].value : null;
        };
        const reIop = latestIop('RE');
        const leIop = latestIop('LE');
        const reSph = f.ref_final_re_sph || f.ref_obj_re_sph;
        const leSph = f.ref_final_le_sph || f.ref_obj_le_sph;
        const reCyl = f.ref_final_re_cyl || f.ref_obj_re_cyl;
        const leCyl = f.ref_final_le_cyl || f.ref_obj_le_cyl;
        return (
          <div className="card" style={{ marginBottom: 16, background: 'var(--g50)' }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 6 }}>
              Optometry Findings <span style={{ fontWeight: 400, color: 'var(--g400)' }}>({f.va_scale})</span>
            </div>
            <div style={{ fontSize: 12, color: 'var(--g600)' }}>
              VA: RE {f.re_dist_unaided || '--'} / LE {f.le_dist_unaided || '--'} &nbsp;&nbsp;
              IOP: RE {reIop ?? '--'} / LE {leIop ?? '--'} &nbsp;&nbsp;
              Sph: RE {reSph || '--'} / LE {leSph || '--'} &nbsp;&nbsp;
              Cyl: RE {reCyl || '--'} / LE {leCyl || '--'}
            </div>
            {f.observations_text && (
              <div style={{ fontSize: 12, color: 'var(--g500)', marginTop: 6 }}>Observations: {f.observations_text}</div>
            )}
          </div>
        );
      })()}

      {/* TABS */}
      <div style={{ display: 'flex', gap: 4, marginBottom: 16, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
        <button type="button" className={`snbtn ${activeTab === 'exam' ? 'active' : ''}`} style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'exam' ? '#fff' : 'transparent', color: activeTab === 'exam' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'exam' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setActiveTab('exam')}>
          <i className="ti ti-microscope"></i> Examination
        </button>
        <button type="button" className={`snbtn ${activeTab === 'plan' ? 'active' : ''}`} style={{ flex: 1, padding: '8px 10px', borderRadius: 6, fontSize: 12, fontWeight: 600, border: 'none', background: activeTab === 'plan' ? '#fff' : 'transparent', color: activeTab === 'plan' ? 'var(--blue)' : 'var(--g500)', cursor: 'pointer', boxShadow: activeTab === 'plan' ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setActiveTab('plan')}>
          <i className="ti ti-clipboard-text"></i> Diagnosis &amp; Plan
        </button>
      </div>

      {activeTab === 'exam' && (
        <ExaminationTab examination={data.examination} onSaved={refresh} />
      )}

      {activeTab === 'plan' && (
      <>
      {/* DIAGNOSIS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Diagnosis</div>
        {data.diagnoses.map((d) => (
          <div key={d.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{d.name}</strong> -- {d.eye} -- <span style={{ color: d.category === 'primary' ? 'var(--blue)' : 'var(--g500)' }}>{d.category}</span>
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeDiagnosis(d.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Diagnosis name" value={dxName} onChange={(e) => setDxName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={dxCategory} onChange={(e) => setDxCategory(e.target.value)} style={{ flex: 1 }}>
            <option value="primary">Primary</option>
            <option value="secondary">Secondary</option>
            <option value="associated">Associated</option>
            <option value="systemic">Systemic</option>
          </select>
          <select className="fi" value={dxEye} onChange={(e) => setDxEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option>
            <option value="OS">OS</option>
            <option value="OU">OU</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddDiagnosis}>Add</button>
        </div>
      </div>

      {/* PRESCRIPTION */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Prescription</div>
        {data.prescriptions.map((r) => (
          <div key={r.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{r.drug_name}</strong> -- {r.dosage} {r.frequency} x {r.duration} -- {r.eye}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removePrescription(r.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10, flexWrap: 'wrap' }}>
          <input className="fi" placeholder="Drug name" value={rxDrug} onChange={(e) => setRxDrug(e.target.value)} style={{ flex: '2 1 160px' }} />
          <select className="fi" value={rxDosage} onChange={(e) => setRxDosage(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>1 drop</option><option>2 drops</option><option>1 tablet</option><option>2 tablets</option>
          </select>
          <select className="fi" value={rxFrequency} onChange={(e) => setRxFrequency(e.target.value)} style={{ flex: '1 1 90px' }}>
            <option>OD</option><option>BD</option><option>TDS</option><option>QID</option><option>HS</option><option>SOS</option>
          </select>
          <select className="fi" value={rxDuration} onChange={(e) => setRxDuration(e.target.value)} style={{ flex: '1 1 100px' }}>
            <option>3 days</option><option>1 week</option><option>2 weeks</option><option>1 month</option><option>Ongoing</option>
          </select>
          <select className="fi" value={rxEye} onChange={(e) => setRxEye(e.target.value)} style={{ width: 70 }}>
            <option value="RE">RE</option><option value="LE">LE</option><option value="BE">BE</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddPrescription}>Add</button>
        </div>
      </div>

      {/* INVESTIGATIONS */}
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Investigations</div>
        {data.investigations.map((i) => (
          <div key={i.id} style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>
              <strong>{i.name}</strong> -- {i.eye} -- {i.priority}
            </span>
            <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={async () => { await removeInvestigation(i.id); refresh(); }}>Remove</button>
          </div>
        ))}
        <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
          <input className="fi" placeholder="Investigation name" value={invName} onChange={(e) => setInvName(e.target.value)} style={{ flex: 2 }} />
          <select className="fi" value={invEye} onChange={(e) => setInvEye(e.target.value)} style={{ width: 70 }}>
            <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
          </select>
          <select className="fi" value={invPriority} onChange={(e) => setInvPriority(e.target.value)} style={{ flex: 1 }}>
            <option>Routine</option><option>Urgent</option>
          </select>
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddInvestigation}>Add</button>
        </div>
      </div>

      {/* SURGERY */}
      <div className="card" style={{ marginBottom: 16 }}>
        {!showSurgery ? (
          <button className="btn" onClick={() => setShowSurgery(true)}>
            <i className="ti ti-scalpel"></i> Mark for Surgery
          </button>
        ) : (
          <div>
            <div style={{ fontSize: 13, fontWeight: 700, marginBottom: 8 }}>Mark for Surgery</div>
            <div style={{ display: 'flex', gap: 6, marginBottom: 8 }}>
              <input className="fi" placeholder="Procedure (e.g. Phacoemulsification + IOL)" value={surgeryProcedure} onChange={(e) => setSurgeryProcedure(e.target.value)} style={{ flex: 2 }} />
              <select className="fi" value={surgeryEye} onChange={(e) => setSurgeryEye(e.target.value)} style={{ width: 80 }}>
                <option value="OD">OD</option><option value="OS">OS</option><option value="OU">OU</option>
              </select>
            </div>
            <div style={{ display: 'flex', gap: 6 }}>
              <button className="btn btn-primary btn-sm" onClick={handleMarkForSurgery} disabled={surgeryLoading}>
                {surgeryLoading ? 'Saving...' : 'Save'}
              </button>
              <button className="btn btn-sm" onClick={() => setShowSurgery(false)}>Cancel</button>
            </div>
          </div>
        )}
      </div>

      </>
      )}

      {/* ACTIONS */}
      <div className="card" style={{ display: 'flex', gap: 8, flexWrap: 'wrap' }}>
        <button className="btn btn-primary" onClick={handleComplete} disabled={loading}>
          {loading ? 'Working...' : 'Complete Visit'}
        </button>
        <button className="btn" onClick={() => handleSendOut('dilate')} disabled={loading}>
          Send for Dilation
        </button>
        <button className="btn" onClick={() => handleSendOut('investigate')} disabled={loading}>
          Send for Investigation
        </button>
      </div>
    </div>
  );
}


EOF

cat > "app/(main)/consultation/[id]/examination-tab.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { saveExamination } from '@/app/(main)/consultation/actions';

const EXT_STRUCTS = ['Lids', 'Adnexa', 'Lacrimal', 'Motility'];
const EXT_TEMPLATES = {
  Lids: ['Normal', 'Blepharitis', 'Ptosis', 'Entropion', 'Ectropion', 'Chalazion', 'Stye'],
  Adnexa: ['Normal', 'Swelling', 'Mass'],
  Lacrimal: ['Patent', 'Watering', 'Blocked', 'Dacryocystitis'],
  Motility: ['Full', 'Restriction', 'Squint', 'Nystagmus'],
};
const ANT_STRUCTS = ['Conjunctiva', 'Cornea', 'Anterior Chamber', 'Iris', 'Pupil', 'Lens'];
const ANT_TEMPLATES = {
  Conjunctiva: ['Normal', 'Congested', 'PCVO', 'Pterygium', 'Subconjunctival haemorrhage'],
  Cornea: ['Clear', 'Scar', 'Ulcer', 'Edema', 'Pterygium', 'Guttata', 'Keratitis'],
  'Anterior Chamber': ['Deep & Quiet', 'Shallow', 'Cells+', 'Hypopyon', 'Hyphema'],
  Iris: ['Normal Pattern', 'Rubeosis', 'Heterochromia', 'Synechiae'],
  Pupil: ['Round & Reactive', 'RAPD', 'Irregular', 'Fixed & Dilated'],
  Lens: ['Clear', 'NS1', 'NS2', 'NS3', 'NS4', 'PSC', 'Cortical', 'Mature', 'Hypermature', 'PCIOL', 'Aphakia'],
};
const POST_STRUCTS = ['Vitreous', 'Disc', 'Macula', 'Vessels', 'Peripheral Retina'];
const POST_TEMPLATES = {
  Vitreous: ['Clear', 'Haze', 'Haemorrhage', 'PVD'],
  Disc: ['Healthy', 'Pale', 'Cupped', 'Swollen', 'Tilted'],
  Macula: ['Normal', 'ARMD', 'CSME', 'Macular Hole', 'Epiretinal Membrane', 'Scar'],
  Vessels: ['Normal', 'Arteriovenous nipping', 'Disc collaterals'],
  'Peripheral Retina': ['Attached', 'Lattice', 'Tear', 'Detachment', 'Laser Marks'],
};
const GONIO_TEMPLATES = ['Open Angle', 'Narrow Angle', 'Closed Angle', 'Synechiae'];

const REGIONS = {
  external: { structs: EXT_STRUCTS, templates: EXT_TEMPLATES, icon: 'ti-user', color: 'var(--g400)', title: 'External Examination', section: '12.9' },
  anterior: { structs: ANT_STRUCTS, templates: ANT_TEMPLATES, icon: 'ti-microscope', color: 'var(--teal)', title: 'Anterior Segment', section: '12.11' },
  posterior: { structs: POST_STRUCTS, templates: POST_TEMPLATES, icon: 'ti-eye', color: 'var(--purple)', title: 'Posterior Segment', section: '12.13' },
};

function emptyRegionState(structs) {
  const state = {};
  structs.forEach((s) => { state[s] = { re: '', le: '', re_custom: '', le_custom: '' }; });
  return state;
}

function StructRow({ struct, templates, eyeState, onSelect, onCustom }) {
  const options = templates[struct] || [];
  return (
    <div style={{ display: 'grid', gridTemplateColumns: '110px 1fr', gap: 8, alignItems: 'center', padding: '6px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ fontSize: 12, fontWeight: 600, color: 'var(--g700)' }}>{struct}</div>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, alignItems: 'center' }}>
        {options.map((opt) => (
          <div
            key={opt}
            onClick={() => onSelect(opt)}
            style={{
              padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer',
              border: `1.5px solid ${eyeState.value === opt ? 'var(--blue)' : 'var(--g200)'}`,
              background: eyeState.value === opt ? 'var(--blue)' : '#fff',
              color: eyeState.value === opt ? '#fff' : 'var(--g600)',
            }}
          >
            {opt}
          </div>
        ))}
        <input
          type="text"
          className="fi fi-sm"
          style={{ width: 100 }}
          placeholder="Custom..."
          value={eyeState.custom}
          onChange={(e) => onCustom(e.target.value)}
        />
      </div>
    </div>
  );
}

function RegionSection({ regionKey, region, open, onToggle, status, state, onSelect, onCustom, onAllNormal }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <i className={`ti ${region.icon}`} style={{ color: region.color }}></i>
          {region.title} <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(Section {region.section})</span>
          <span className={`badge ${status === 'Normal' ? 'b-green' : status === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status}</span>
        </div>
        <div style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <button type="button" className="btn btn-sm" style={{ background: 'var(--green)', color: '#fff', border: 'none' }} onClick={(e) => { e.stopPropagation(); onAllNormal(); }}>
            <i className="ti ti-check"></i> All Normal
          </button>
          <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
      </div>
      {open && (
        <div style={{ padding: 16 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            {['re', 'le'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 11, fontWeight: 700, color: eye === 're' ? 'var(--blue)' : 'var(--teal)', marginBottom: 6, padding: '4px 8px', background: eye === 're' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 6, display: 'inline-block' }}>
                  <i className="ti ti-eye" style={{ fontSize: 11 }}></i> {eye === 're' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {region.structs.map((struct) => (
                  <StructRow
                    key={struct}
                    struct={struct}
                    templates={region.templates}
                    eyeState={{ value: state[struct]?.[eye] || '', custom: state[struct]?.[`${eye}_custom`] || '' }}
                    onSelect={(val) => onSelect(struct, eye, val)}
                    onCustom={(val) => onCustom(struct, eye, val)}
                  />
                ))}
              </div>
            ))}
          </div>
        </div>
      )}
    </div>
  );
}

export default function ExaminationTab({ examination, onSaved }) {
  const [regionState, setRegionState] = useState({
    external: emptyRegionState(EXT_STRUCTS),
    anterior: emptyRegionState(ANT_STRUCTS),
    posterior: emptyRegionState(POST_STRUCTS),
  });
  const [status, setStatus] = useState({ external: 'Not started', anterior: 'Not started', posterior: 'Not started', glaucoma: 'Not started' });
  const [open, setOpen] = useState({ external: true, anterior: false, glaucoma: false, posterior: false, remarks: false });

  const [cdrRe, setCdrRe] = useState('');
  const [cdrLe, setCdrLe] = useState('');
  const [gonioRe, setGonioRe] = useState('');
  const [gonioLe, setGonioLe] = useState('');
  const [discAppearance, setDiscAppearance] = useState('');
  const [remarksRe, setRemarksRe] = useState('');
  const [remarksLe, setRemarksLe] = useState('');

  const [saving, setSaving] = useState(false);
  const [savedMsg, setSavedMsg] = useState('');

  useEffect(() => {
    if (!examination) return;
    setRegionState({
      external: { ...emptyRegionState(EXT_STRUCTS), ...normalizeFindings(examination.external_findings, EXT_STRUCTS) },
      anterior: { ...emptyRegionState(ANT_STRUCTS), ...normalizeFindings(examination.anterior_findings, ANT_STRUCTS) },
      posterior: { ...emptyRegionState(POST_STRUCTS), ...normalizeFindings(examination.posterior_findings, POST_STRUCTS) },
    });
    setStatus({
      external: examination.external_status || 'Not started',
      anterior: examination.anterior_status || 'Not started',
      posterior: examination.posterior_status || 'Not started',
      glaucoma: examination.glaucoma_status || 'Not started',
    });
    setCdrRe(examination.cdr_re || '');
    setCdrLe(examination.cdr_le || '');
    setGonioRe(examination.gonio_re || '');
    setGonioLe(examination.gonio_le || '');
    setDiscAppearance(examination.disc_appearance || '');
    setRemarksRe(examination.remarks_re || '');
    setRemarksLe(examination.remarks_le || '');
  }, [examination]);

  function normalizeFindings(raw, structs) {
    const out = {};
    structs.forEach((s) => {
      const v = raw?.[s] || {};
      out[s] = { re: v.re || '', le: v.le || '', re_custom: v.re_custom || '', le_custom: v.le_custom || '' };
    });
    return out;
  }

  function markDirty(region) {
    setStatus((prev) => (prev[region] === 'Not started' ? { ...prev, [region]: 'In progress' } : prev));
  }

  function handleSelect(region, struct, eye, val) {
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [struct]: { ...prev[region][struct], [eye]: val } },
    }));
    markDirty(region);
  }

  function handleCustom(region, struct, eye, val) {
    setRegionState((prev) => ({
      ...prev,
      [region]: { ...prev[region], [struct]: { ...prev[region][struct], [`${eye}_custom`]: val } },
    }));
    markDirty(region);
  }

  function handleAllNormal(region) {
    const { structs, templates } = REGIONS[region];
    const next = {};
    structs.forEach((s) => {
      const normalVal = templates[s]?.[0] || '';
      next[s] = { re: normalVal, le: normalVal, re_custom: '', le_custom: '' };
    });
    setRegionState((prev) => ({ ...prev, [region]: next }));
    setStatus((prev) => ({ ...prev, [region]: 'Normal' }));
  }

  function applyFavorite(fav) {
    if (fav === 'normal') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); }
    else if (fav === 'cataract') { handleAllNormal('external'); handleAllNormal('anterior'); handleAllNormal('posterior'); setOpen((p) => ({ ...p, anterior: true })); }
    else if (fav === 'glaucoma') { setOpen((p) => ({ ...p, glaucoma: true })); }
    else if (fav === 'postop') { handleAllNormal('anterior'); handleAllNormal('posterior'); }
  }

  async function handleSave() {
    setSaving(true);
    setSavedMsg('');
    const fields = {
      external_findings: regionState.external,
      external_status: status.external,
      anterior_findings: regionState.anterior,
      anterior_status: status.anterior,
      posterior_findings: regionState.posterior,
      posterior_status: status.posterior,
      cdr_re: cdrRe, cdr_le: cdrLe, gonio_re: gonioRe, gonio_le: gonioLe, disc_appearance: discAppearance,
      glaucoma_status: (cdrRe || cdrLe || gonioRe || gonioLe || discAppearance) ? 'Done' : status.glaucoma,
      remarks_re: remarksRe, remarks_le: remarksLe,
    };
    const result = await saveExamination(examination.id, fields);
    setSaving(false);
    if (result.error) { setSavedMsg(''); return; }
    setSavedMsg('Examination saved.');
    if (onSaved) onSaved();
  }

  return (
    <div>
      <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> Exception-based documentation. Click <strong>All Normal</strong> to auto-populate normal findings, then change only what&apos;s abnormal.
      </div>

      <div className="card" style={{ padding: '10px 14px', marginBottom: 12 }}>
        <div style={{ fontSize: 11, fontWeight: 700, color: 'var(--g500)', textTransform: 'uppercase', marginBottom: 6 }}>Favorites</div>
        <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap' }}>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('normal')}><i className="ti ti-star"></i> Normal Routine</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('cataract')}><i className="ti ti-eye"></i> Routine Cataract</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('glaucoma')}><i className="ti ti-activity"></i> Glaucoma Follow-up</button>
          <button type="button" className="btn btn-sm" onClick={() => applyFavorite('postop')}><i className="ti ti-calendar-check"></i> Post-op Review</button>
        </div>
      </div>

      {['external', 'anterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          state={regionState[key]}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
        />
      ))}

      {/* GLAUCOMA -- no "All Normal" (not exception-based) */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.glaucoma ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setOpen((p) => ({ ...p, glaucoma: !p.glaucoma }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-activity" style={{ color: 'var(--amber)' }}></i> Glaucoma Assessment <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(Section 12.12)</span>
            <span className={`badge ${status.glaucoma === 'Done' ? 'b-green' : status.glaucoma === 'In progress' ? 'b-amber' : 'b-gray'}`}>{status.glaucoma}</span>
          </div>
          <i className={`ti ti-chevron-${open.glaucoma ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
        {open.glaucoma && (
          <div style={{ padding: 16 }}>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              <div><label className="flbl">Cup-disc ratio RE</label><input className="fi fi-sm" value={cdrRe} onChange={(e) => { setCdrRe(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
              <div><label className="flbl">Cup-disc ratio LE</label><input className="fi fi-sm" value={cdrLe} onChange={(e) => { setCdrLe(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. 0.4" /></div>
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
              {[['RE', gonioRe, setGonioRe], ['LE', gonioLe, setGonioLe]].map(([eye, val, setVal]) => (
                <div key={eye}>
                  <label className="flbl">Gonioscopy {eye}</label>
                  <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4 }}>
                    {GONIO_TEMPLATES.map((opt) => (
                      <div
                        key={opt}
                        onClick={() => { setVal(opt); markDirty('glaucoma'); }}
                        style={{ padding: '3px 9px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: 'pointer', border: `1.5px solid ${val === opt ? 'var(--blue)' : 'var(--g200)'}`, background: val === opt ? 'var(--blue)' : '#fff', color: val === opt ? '#fff' : 'var(--g600)' }}
                      >
                        {opt}
                      </div>
                    ))}
                  </div>
                </div>
              ))}
            </div>
            <div>
              <label className="flbl">Disc appearance</label>
              <input className="fi fi-sm" value={discAppearance} onChange={(e) => { setDiscAppearance(e.target.value); markDirty('glaucoma'); }} placeholder="e.g. Healthy, Pale, Cupped" />
            </div>
          </div>
        )}
      </div>

      {['posterior'].map((key) => (
        <RegionSection
          key={key}
          regionKey={key}
          region={REGIONS[key]}
          open={open[key]}
          onToggle={() => setOpen((p) => ({ ...p, [key]: !p[key] }))}
          status={status[key]}
          state={regionState[key]}
          onSelect={(struct, eye, val) => handleSelect(key, struct, eye, val)}
          onCustom={(struct, eye, val) => handleCustom(key, struct, eye, val)}
          onAllNormal={() => handleAllNormal(key)}
        />
      ))}

      {/* CLINICAL REMARKS */}
      <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
        <div style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open.remarks ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }} onClick={() => setOpen((p) => ({ ...p, remarks: !p.remarks }))}>
          <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
            <i className="ti ti-notes" style={{ color: 'var(--g500)' }}></i> Clinical Remarks <span style={{ fontWeight: 400, color: 'var(--g400)', fontSize: 11 }}>(Section 12.14)</span>
          </div>
          <i className={`ti ti-chevron-${open.remarks ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
        </div>
        {open.remarks && (
          <div style={{ padding: 16 }}>
            <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
              <i className="ti ti-alert-triangle"></i> Remarks supplement structured findings, they do not replace them (BR-EXM-006).
            </div>
            <div style={{ marginBottom: 12 }}>
              <label className="flbl">Right Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksRe} onChange={(e) => setRemarksRe(e.target.value)} placeholder="Additional observations for RE..." />
            </div>
            <div>
              <label className="flbl">Left Eye</label>
              <textarea className="fi fi-sm" rows={2} value={remarksLe} onChange={(e) => setRemarksLe(e.target.value)} placeholder="Additional observations for LE..." />
            </div>
          </div>
        )}
      </div>

      <div style={{ display: 'flex', alignItems: 'center', gap: 10 }}>
        <button type="button" className="btn btn-primary" onClick={handleSave} disabled={saving}>
          {saving ? 'Saving...' : 'Save Examination'}
        </button>
        {savedMsg && <span style={{ fontSize: 12, color: 'var(--green)' }}><i className="ti ti-check"></i> {savedMsg}</span>}
      </div>
    </div>
  );
}

EOF

echo "Ophthalmologist Section (Doctor Dashboard + Examination tab) created/updated."