mkdir -p "app/components" "app/(main)/optometry" "app/(main)/optometry/[id]" "app/(main)/optometry-dashboard" "app/(main)/consultation" "app/(main)/consultation/[id]"

# Old flat-findings form is fully replaced by the Assessment Workspace -- remove it.
rm -f "app/(main)/optometry/[id]/optometry-form.js"

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
  { href: '/optometry-dashboard', label: 'Optometry Queue', icon: 'ti-eye-check', section: 'Optometrist' },
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
  { match: /^\/optometry-dashboard/, title: 'Optometry Queue' },
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

cat > "app/(main)/optometry/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

// Fields that live directly on optometry_assessments -- everything
// except IOP readings (own table, timestamped list) and audit entries
// (own table, append-only).
const ASSESSMENT_FIELDS = [
  'va_scale', 're_dist_unaided', 're_dist_glasses', 're_dist_ph', 're_near_unaided',
  'le_dist_unaided', 'le_dist_glasses', 'le_dist_ph', 'le_near_unaided',
  'ref_pd', 'ref_vd',
  'ref_obj_re_sph', 'ref_obj_re_cyl', 'ref_obj_re_axis',
  'ref_obj_le_sph', 'ref_obj_le_cyl', 'ref_obj_le_axis',
  'ref_subj_re_sph', 'ref_subj_re_cyl', 'ref_subj_re_axis',
  'ref_subj_le_sph', 'ref_subj_le_cyl', 'ref_subj_le_axis',
  'ref_final_re_sph', 'ref_final_re_cyl', 'ref_final_re_axis', 'ref_final_re_add',
  'ref_final_le_sph', 'ref_final_le_cyl', 'ref_final_le_axis', 'ref_final_le_add',
  'iop_method', 'iop_time',
  'add_k1', 'add_k2', 'add_axial_length', 'add_pachymetry', 'add_white_to_white', 'add_schirmer',
  'add_color_vision', 'add_ocular_motility', 'add_syringing',
  'observation_chips', 'observations_text',
  'section_va_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done', 'section_obs_done',
];

function pickAssessmentFields(fields) {
  const out = {};
  ASSESSMENT_FIELDS.forEach((key) => {
    if (fields[key] !== undefined) out[key] = fields[key];
  });
  return out;
}

async function addAudit(supabase, assessmentId, message, userId) {
  await supabase.from('optometry_audit_log').insert({ assessment_id: assessmentId, message, created_by: userId || null });
}

// Loads everything the workspace needs: the queue entry + patient, the
// assessment row (creating an empty Draft one on first open -- same
// pattern as encounters auto-creating on first doctor consultation),
// IOP readings, audit log, and lock status.
export async function getAssessmentWorkspaceData(queueEntryId) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { data: entry, error: entryError } = await supabase
    .from('queue_entries')
    .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (entryError) return { error: entryError.message };

  const visitId = entry.visits?.id;

  let { data: assessment } = await supabase
    .from('optometry_assessments')
    .select('*')
    .eq('visit_id', visitId)
    .maybeSingle();

  if (!assessment) {
    const { data: newAssessment, error: createError } = await supabase
      .from('optometry_assessments')
      .insert({ visit_id: visitId, recorded_by: userData?.user?.id || null })
      .select()
      .single();

    if (createError) return { error: createError.message };
    assessment = newAssessment;
    await addAudit(supabase, assessment.id, 'Assessment started', userData?.user?.id);
  }

  const [{ data: iopReadings }, { data: auditLog }] = await Promise.all([
    supabase.from('optometry_iop_readings').select('*').eq('assessment_id', assessment.id).order('recorded_at', { ascending: true }),
    supabase.from('optometry_audit_log').select('*').eq('assessment_id', assessment.id).order('created_at', { ascending: false }),
  ]);

  // Same lock rule as before: once completed, editable until the
  // doctor's queue entry moves to "In Consultation" or "Done".
  let locked = false;
  if (assessment.status === 'Completed') {
    const { data: doctorEntry } = await supabase
      .from('queue_entries')
      .select('status')
      .eq('visit_id', visitId)
      .eq('department', 'Doctor')
      .maybeSingle();

    locked = doctorEntry?.status === 'In Consultation' || doctorEntry?.status === 'Done';
  }

  return { entry, assessment, iopReadings: iopReadings || [], auditLog: auditLog || [], locked };
}

// "Save Draft" -- patient stays in the queue, nothing routed anywhere
// (BR-OPT-003).
export async function saveDraft(assessmentId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  await addAudit(supabase, assessmentId, 'Draft saved -- patient remains in Optometry Queue', userData?.user?.id);
  return { success: true };
}

// "Complete Assessment" -- first-time completion. Requires at least
// one VA measurement (VAL-OPT-002). Locks the queue entry forward by
// calling the existing optometry_complete RPC, which issues the
// Doctor token (BR-OPT-004) -- same mechanism the rest of the app
// already relies on.
export async function completeAssessment(assessmentId, queueEntryId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const vaFields = ['re_dist_unaided', 're_dist_glasses', 're_dist_ph', 're_near_unaided', 'le_dist_unaided', 'le_dist_glasses', 'le_dist_ph', 'le_near_unaided'];
  const hasVa = vaFields.some((k) => fields[k]);
  if (!hasVa) {
    return { error: 'At least one Visual Acuity measurement must be recorded before completion (VAL-OPT-002).' };
  }

  const { error: updateError } = await supabase
    .from('optometry_assessments')
    .update({
      ...pickAssessmentFields(fields),
      status: 'Completed',
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
      recorded_by: userData?.user?.id || null,
      updated_at: new Date().toISOString(),
    })
    .eq('id', assessmentId);

  if (updateError) return { error: updateError.message };

  const { error: completeError } = await supabase.rpc('optometry_complete', { p_queue_entry_id: queueEntryId });
  if (completeError) return { error: completeError.message };

  await addAudit(supabase, assessmentId, 'Assessment COMPLETED -- routed to Doctor Queue (AUTO-OPT-001)', userData?.user?.id);
  return { success: true };
}

// Edit path -- assessment already Completed and not yet locked (doctor
// hasn't opened the consultation). Updates fields only; queue status
// and doctor token were already handled the first time.
export async function updateCompletedAssessment(assessmentId, fields) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('optometry_assessments')
    .update({ ...pickAssessmentFields(fields), recorded_by: userData?.user?.id || null, updated_at: new Date().toISOString() })
    .eq('id', assessmentId);

  if (error) return { error: error.message };

  await addAudit(supabase, assessmentId, 'Assessment updated post-completion -- not yet seen by doctor', userData?.user?.id);
  return { success: true };
}

// Add a single IOP reading -- applied immediately (not batched with
// the rest of the form), same as the prototype's "Add reading" flow.
// Out-of-range values still get recorded but flagged (VAL-OPT-003).
export async function addIopReading(assessmentId, eye, value) {
  const supabase = await createClient();
  const { data: userData } = await supabase.auth.getUser();

  const numericValue = parseFloat(value);
  if (!numericValue || numericValue <= 0 || numericValue > 80) {
    return { error: 'Enter a valid IOP value (1-80 mmHg).' };
  }

  const { data: reading, error } = await supabase
    .from('optometry_iop_readings')
    .insert({ assessment_id: assessmentId, eye, value: numericValue, recorded_by: userData?.user?.id || null })
    .select()
    .single();

  if (error) return { error: error.message };

  const isHigh = numericValue > 21;
  await addAudit(
    supabase,
    assessmentId,
    `IOP ${eye} = ${numericValue} mmHg${isHigh ? ' -- ELEVATED (VAL-OPT-003)' : ''}`,
    userData?.user?.id
  );

  return { reading };
}

EOF

cat > "app/(main)/optometry/[id]/page.js" << 'EOF'
import OptometryWorkspace from './optometry-workspace';

export default async function OptometryEntryPage({ params }) {
  const { id } = await params;
  return <OptometryWorkspace queueEntryId={id} />;
}

EOF

cat > "app/(main)/optometry/[id]/optometry-workspace.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import {
  getAssessmentWorkspaceData,
  saveDraft,
  completeAssessment,
  updateCompletedAssessment,
  addIopReading,
} from '@/app/(main)/optometry/actions';

const VA_SNELLEN = ['6/6', '6/9', '6/12', '6/18', '6/24', '6/36', '6/60', '3/60', '2/60', '1/60'];
const VA_SPECIAL = ['CF', 'HM', 'PL', 'NPL'];
const VA_LOGMAR = ['0.0', '0.1', '0.2', '0.3', '0.4', '0.5', '0.6', '0.8', '1.0', '1.3'];
const VA_ETDRS = ['85', '80', '75', '70', '65', '60', '55', '50', '45', '40'];

const VA_FIELDS = [
  { key: 're_dist_unaided', label: 'Distance -- Unaided', eye: 'RE' },
  { key: 're_dist_glasses', label: 'Distance -- With glasses', eye: 'RE' },
  { key: 're_dist_ph', label: 'Distance -- Pinhole', eye: 'RE' },
  { key: 're_near_unaided', label: 'Near -- Unaided', eye: 'RE' },
  { key: 'le_dist_unaided', label: 'Distance -- Unaided', eye: 'LE' },
  { key: 'le_dist_glasses', label: 'Distance -- With glasses', eye: 'LE' },
  { key: 'le_dist_ph', label: 'Distance -- Pinhole', eye: 'LE' },
  { key: 'le_near_unaided', label: 'Near -- Unaided', eye: 'LE' },
];

const OBS_CHIPS = ['Poor fixation', 'Excessive blinking', 'Difficulty cooperating', 'Media opacity limiting measurement', 'Nystagmus noted', 'Patient anxious'];

function vaValuesForScale(scale) {
  return scale === 'LogMAR' ? VA_LOGMAR : scale === 'ETDRS' ? VA_ETDRS : VA_SNELLEN;
}

function emptyForm() {
  const f = {
    va_scale: 'Snellen',
    ref_pd: '', ref_vd: '',
    iop_method: 'Non-Contact Tonometer (NCT)', iop_time: '',
    add_k1: '', add_k2: '', add_axial_length: '', add_pachymetry: '', add_white_to_white: '', add_schirmer: '',
    add_color_vision: '', add_ocular_motility: '', add_syringing: '',
    observation_chips: [], observations_text: '',
    section_va_done: false, section_refraction_done: false, section_iop_done: false, section_additional_done: false, section_obs_done: false,
  };
  VA_FIELDS.forEach((f2) => { f[f2.key] = ''; });
  ['obj', 'subj', 'final'].forEach((type) => {
    ['re', 'le'].forEach((eye) => {
      ['sph', 'cyl', 'axis'].forEach((p) => { f[`ref_${type}_${eye}_${p}`] = ''; });
      if (type === 'final') f[`ref_${type}_${eye}_add`] = '';
    });
  });
  return f;
}

function AsmtSection({ id, num, color, title, badge, badgeCls, open, onToggle, children }) {
  return (
    <div className="card" style={{ padding: 0, overflow: 'hidden' }}>
      <div
        style={{ padding: '12px 16px', background: 'var(--g50)', borderBottom: open ? '1px solid var(--g200)' : 'none', display: 'flex', alignItems: 'center', justifyContent: 'space-between', cursor: 'pointer' }}
        onClick={onToggle}
      >
        <div style={{ fontSize: 13, fontWeight: 700, color: 'var(--g800)', display: 'flex', alignItems: 'center', gap: 8 }}>
          <span style={{ width: 22, height: 22, borderRadius: '50%', background: color, color: '#fff', display: 'inline-flex', alignItems: 'center', justifyContent: 'center', fontSize: 11, fontWeight: 700, flexShrink: 0 }}>{num}</span>
          {title}
          <span className={`badge ${badgeCls}`}>{badge}</span>
        </div>
        <i className={`ti ti-chevron-${open ? 'up' : 'down'}`} style={{ color: 'var(--g400)' }}></i>
      </div>
      {open && <div style={{ padding: 16 }}>{children}</div>}
    </div>
  );
}

function VaOptPills({ values, selected, onSelect, disabled }) {
  return (
    <div style={{ display: 'flex', flexWrap: 'wrap', gap: 4, marginBottom: 6 }}>
      {values.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px solid ${selected === v ? 'var(--teal)' : 'var(--g200)'}`,
            background: selected === v ? 'var(--teal)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
      {VA_SPECIAL.map((v) => (
        <div
          key={v}
          onClick={() => !disabled && onSelect(v)}
          style={{
            padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: disabled ? 'default' : 'pointer',
            border: `1.5px dashed ${selected === v ? 'var(--amber)' : 'var(--g200)'}`,
            borderStyle: selected === v ? 'solid' : 'dashed',
            background: selected === v ? 'var(--amber)' : '#fff',
            color: selected === v ? '#fff' : 'var(--g600)',
          }}
        >
          {v}
        </div>
      ))}
    </div>
  );
}

export default function OptometryWorkspace({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [assessment, setAssessment] = useState(null);
  const [iopReadings, setIopReadings] = useState([]);
  const [auditLog, setAuditLog] = useState([]);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [form, setForm] = useState(emptyForm());
  const [openSections, setOpenSections] = useState({ va: true, refraction: false, iop: false, additional: false, obs: false });
  const [refTab, setRefTab] = useState('obj');
  const [reIopInput, setReIopInput] = useState('');
  const [leIopInput, setLeIopInput] = useState('');

  const [error, setError] = useState('');
  const [okMsg, setOkMsg] = useState('');
  const [saving, setSaving] = useState(false);
  const router = useRouter();

  function load() {
    getAssessmentWorkspaceData(queueEntryId).then((result) => {
      if (result.error) { setLoadError(result.error); return; }
      setEntry(result.entry);
      setAssessment(result.assessment);
      setIopReadings(result.iopReadings);
      setAuditLog(result.auditLog);
      setLocked(result.locked);

      const f = emptyForm();
      Object.keys(f).forEach((key) => {
        if (result.assessment[key] !== null && result.assessment[key] !== undefined) f[key] = result.assessment[key];
      });
      setForm(f);
    });
  }

  useEffect(() => { load(); }, [queueEntryId]);

  const isEdit = assessment?.status === 'Completed';

  function setField(key, value) {
    setForm((prev) => ({ ...prev, [key]: value }));
  }

  function setVa(key, value) {
    setForm((prev) => ({ ...prev, [key]: value, section_va_done: true }));
  }

  function setRef(type, eye, part, value) {
    setForm((prev) => ({ ...prev, [`ref_${type}_${eye}_${part}`]: value, section_refraction_done: true }));
  }

  function toggleObsChip(chip) {
    setForm((prev) => {
      const has = prev.observation_chips.includes(chip);
      return {
        ...prev,
        observation_chips: has ? prev.observation_chips.filter((c) => c !== chip) : [...prev.observation_chips, chip],
        section_obs_done: true,
      };
    });
  }

  function toggleSection(key) {
    setOpenSections((prev) => ({ ...prev, [key]: !prev[key] }));
  }

  async function handleAddIop(eye) {
    const value = eye === 'RE' ? reIopInput : leIopInput;
    if (!value) return;
    const result = await addIopReading(assessment.id, eye, value);
    if (result.error) { setError(result.error); return; }
    setError('');
    if (eye === 'RE') setReIopInput(''); else setLeIopInput('');
    setForm((prev) => ({ ...prev, section_iop_done: true }));
    load();
  }

  async function handleSaveDraft() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await saveDraft(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Draft saved -- patient stays in Optometry Queue.');
    load();
  }

  async function handleComplete() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await completeAssessment(assessment.id, queueEntryId, form);
    setSaving(false);
    if (result.error) {
      setError(result.error);
      if (!openSections.va) toggleSection('va');
      return;
    }
    setOkMsg('Assessment completed -- routed to Doctor Queue.');
    setTimeout(() => router.push('/optometry-dashboard'), 1200);
  }

  async function handleUpdate() {
    setSaving(true);
    setError('');
    setOkMsg('');
    const result = await updateCompletedAssessment(assessment.id, form);
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setOkMsg('Changes saved.');
    load();
  }

  if (loadError) return <div className="msg-err">{loadError}</div>;
  if (!entry || !assessment) return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;

  const patient = entry.visits?.patients;
  const doneCount = ['section_va_done', 'section_refraction_done', 'section_iop_done', 'section_additional_done', 'section_obs_done'].filter((k) => form[k]).length;
  const vaScaleValues = vaValuesForScale(form.va_scale);

  const reIopSorted = iopReadings.filter((r) => r.eye === 'RE');
  const leIopSorted = iopReadings.filter((r) => r.eye === 'LE');

  function iopReadingRow(r, list, i) {
    const isHigh = r.value > 21;
    const isWarn = r.value > 18 && r.value <= 21;
    const isLatest = i === list.length - 1;
    const time = new Date(r.recorded_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' });
    return (
      <div key={r.id} style={{ display: 'flex', alignItems: 'center', gap: 8, padding: '6px 10px', borderRadius: 8, background: isHigh ? 'var(--red-lt)' : isWarn ? 'var(--amber-lt)' : 'var(--g50)', marginBottom: 6, fontSize: 12 }}>
        <i className={`ti ti-${isHigh ? 'alert-circle' : 'circle-check'}`} style={{ color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--green)', fontSize: 14 }}></i>
        <span style={{ fontWeight: isLatest ? 700 : 400, color: isHigh ? 'var(--red)' : isWarn ? 'var(--amber)' : 'var(--g800)' }}>{r.value} mmHg</span>
        <span style={{ fontSize: 11, color: 'var(--g500)' }}>{time}</span>
        <span style={{ marginLeft: 'auto' }} className={`badge ${isLatest ? 'b-teal' : 'b-gray'}`}>{isLatest ? 'Latest' : 'Historical'}</span>
      </div>
    );
  }

  return (
    <div>
      {/* PATIENT STRIP */}
      <div style={{ background: 'linear-gradient(135deg,#0f766e,#0d9488)', borderRadius: 12, padding: '12px 16px', color: '#fff', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 14 }}>
        <div style={{ width: 40, height: 40, borderRadius: '50%', background: 'rgba(255,255,255,.2)', display: 'flex', alignItems: 'center', justifyContent: 'center', fontSize: 17, fontWeight: 700, flexShrink: 0, border: '2px solid rgba(255,255,255,.3)' }}>
          {patient?.first_name?.charAt(0) || '?'}
        </div>
        <div>
          <div style={{ fontSize: 15, fontWeight: 700 }}>{patient?.first_name} {patient?.last_name}</div>
          <div style={{ fontSize: 11, opacity: .8, marginTop: 2 }}>{patient?.age} -- {patient?.gender} -- {patient?.uhid}</div>
          <div style={{ display: 'flex', gap: 5, marginTop: 5, flexWrap: 'wrap' }}>
            <span style={{ padding: '2px 8px', borderRadius: 20, fontSize: 10, fontWeight: 600, background: 'rgba(255,255,255,.15)', border: '1px solid rgba(255,255,255,.25)' }}>Token {entry.token}</span>
          </div>
        </div>
      </div>

      {/* WORKFLOW PANEL */}
      <div style={{ background: '#0f172a', borderRadius: 12, padding: '12px 14px', marginBottom: 14, display: 'flex', alignItems: 'center', gap: 10, flexWrap: 'wrap' }}>
        <div style={{ width: 8, height: 8, borderRadius: '50%', background: '#5eead4', boxShadow: '0 0 6px #5eead4', flexShrink: 0 }}></div>
        <div style={{ fontSize: 12, fontWeight: 700, color: '#5eead4' }}>
          {locked ? 'Locked -- Doctor Reviewing' : isEdit ? 'Assessment Completed -- Editable' : 'Optometry -- In Progress'}
        </div>
        <div style={{ marginLeft: 'auto', display: 'flex', alignItems: 'center', gap: 10 }}>
          <div style={{ textAlign: 'right' }}>
            <div style={{ fontSize: 10, color: '#94a3b8', textTransform: 'uppercase', letterSpacing: '.4px' }}>Assessment progress</div>
            <div style={{ fontSize: 13, fontWeight: 700, color: '#e2e8f0' }}>{doneCount} / 5 sections</div>
            <div style={{ height: 6, borderRadius: 3, background: 'var(--g200)', width: 160, marginTop: 4, overflow: 'hidden' }}>
              <div style={{ height: '100%', borderRadius: 3, background: 'var(--teal)', width: `${(doneCount / 5) * 100}%`, transition: 'width .3s' }}></div>
            </div>
          </div>
          {!locked && (
            <div style={{ display: 'flex', gap: 6 }}>
              {!isEdit && (
                <>
                  <button className="btn btn-sm" style={{ background: 'rgba(255,255,255,.1)', color: '#e2e8f0', borderColor: 'rgba(255,255,255,.2)' }} onClick={handleSaveDraft} disabled={saving}>
                    <i className="ti ti-device-floppy"></i> Save Draft
                  </button>
                  <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleComplete} disabled={saving}>
                    <i className="ti ti-circle-check"></i> Complete Assessment
                  </button>
                </>
              )}
              {isEdit && (
                <button className="btn btn-sm" style={{ background: 'rgba(94,234,212,.2)', color: '#5eead4', borderColor: 'rgba(94,234,212,.3)', fontWeight: 700 }} onClick={handleUpdate} disabled={saving}>
                  <i className="ti ti-device-floppy"></i> Save Changes
                </button>
              )}
            </div>
          )}
        </div>
      </div>

      {locked && (
        <div className="msg-err" style={{ marginBottom: 12 }}>
          <i className="ti ti-lock"></i> The doctor has already started this consultation. Shown here for reference only -- no further edits.
        </div>
      )}
      {error && <div className="msg-err">{error}</div>}
      {okMsg && <div className="msg-success">{okMsg}</div>}

      {/* SECTION 1: VISUAL ACUITY */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={1} color="var(--teal)" title="Visual Acuity" badge={form.section_va_done ? 'Done' : 'Not started'} badgeCls={form.section_va_done ? 'b-green' : 'b-gray'}
          open={openSections.va} onToggle={() => toggleSection('va')}
        >
          <div style={{ display: 'flex', alignItems: 'center', gap: 10, marginBottom: 14, padding: '8px 12px', background: 'var(--g50)', borderRadius: 8, flexWrap: 'wrap' }}>
            <span style={{ fontSize: 11, fontWeight: 700, color: 'var(--g600)', textTransform: 'uppercase' }}>Scale:</span>
            {['Snellen', 'LogMAR', 'ETDRS'].map((s) => (
              <div
                key={s}
                onClick={() => !locked && setField('va_scale', s)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.va_scale === s ? 'var(--teal)' : 'var(--g200)'}`, background: form.va_scale === s ? 'var(--teal)' : '#fff', color: form.va_scale === s ? '#fff' : 'var(--g600)' }}
              >
                {s}
              </div>
            ))}
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {['RE', 'LE'].map((eye) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '6px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {VA_FIELDS.filter((f) => f.eye === eye).map((f) => (
                  <div key={f.key} style={{ marginBottom: 12 }}>
                    <label className="flbl">{f.label}</label>
                    <VaOptPills values={vaScaleValues} selected={form[f.key]} onSelect={(v) => setVa(f.key, v)} disabled={locked} />
                  </div>
                ))}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 2: REFRACTION */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={2} color="var(--blue)" title="Refraction" badge={form.section_refraction_done ? 'Done' : 'Not started'} badgeCls={form.section_refraction_done ? 'b-green' : 'b-gray'}
          open={openSections.refraction} onToggle={() => toggleSection('refraction')}
        >
          <div style={{ display: 'flex', gap: 4, marginBottom: 14, background: 'var(--g100)', borderRadius: 8, padding: 4 }}>
            {[['obj', 'Objective (Auto-Rx)'], ['subj', 'Subjective'], ['final', 'Final Rx']].map(([key, label]) => (
              <button key={key} type="button" className={`snbtn ${refTab === key ? 'active' : ''}`} style={{ flex: 1, padding: '7px 8px', borderRadius: 6, fontSize: 11, fontWeight: 600, border: 'none', background: refTab === key ? '#fff' : 'transparent', color: refTab === key ? 'var(--teal)' : 'var(--g500)', cursor: 'pointer', boxShadow: refTab === key ? '0 1px 4px rgba(0,0,0,.08)' : 'none' }} onClick={() => setRefTab(key)}>
                {label}
              </button>
            ))}
          </div>

          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 10 }}>
            {refTab === 'obj' ? 'Auto-refractometer values. Review before finalizing.' : refTab === 'subj' ? 'Values obtained during subjective refraction with trial lenses.' : 'Final accepted refraction used for prescription / optical order.'}
          </div>

          <table className="tbl" style={{ marginBottom: 10 }}>
            <thead>
              <tr>
                <th></th><th>SPH</th><th>CYL</th><th>AXIS</th>{refTab === 'final' && <th>ADD (near)</th>}
              </tr>
            </thead>
            <tbody>
              {['re', 'le'].map((eye) => (
                <tr key={eye}>
                  <td style={{ fontWeight: 700, fontSize: 12 }}>{eye.toUpperCase()}</td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_sph`]} onChange={(e) => setRef(refTab, eye, 'sph', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_cyl`]} onChange={(e) => setRef(refTab, eye, 'cyl', e.target.value)} placeholder="--" /></td>
                  <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_axis`]} onChange={(e) => setRef(refTab, eye, 'axis', e.target.value)} placeholder="--" /></td>
                  {refTab === 'final' && (
                    <td><input className="fi fi-sm" disabled={locked} style={{ textAlign: 'center' }} value={form[`ref_${refTab}_${eye}_add`]} onChange={(e) => setRef(refTab, eye, 'add', e.target.value)} placeholder="--" /></td>
                  )}
                </tr>
              ))}
            </tbody>
          </table>

          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Pupillary Distance (PD)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_pd} onChange={(e) => setField('ref_pd', e.target.value)} placeholder="e.g. 62mm" />
            </div>
            <div>
              <label className="flbl">Vertex Distance (optional)</label>
              <input className="fi fi-sm" disabled={locked} value={form.ref_vd} onChange={(e) => setField('ref_vd', e.target.value)} placeholder="e.g. 12mm" />
            </div>
          </div>

          <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12 }}>
            <i className="ti ti-info-circle"></i> Device-imported values should be reviewed before finalizing. All 3 refraction types are recorded independently.
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 3: IOP */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={3} color="var(--purple)" title="Intraocular Pressure" badge={form.section_iop_done ? 'Done' : 'Not started'} badgeCls={form.section_iop_done ? 'b-green' : 'b-gray'}
          open={openSections.iop} onToggle={() => toggleSection('iop')}
        >
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 12 }}>
            <div>
              <label className="flbl">Method</label>
              <select className="fi fi-sm" disabled={locked} value={form.iop_method} onChange={(e) => setField('iop_method', e.target.value)}>
                {['Non-Contact Tonometer (NCT)', 'Goldmann Applanation', 'Perkins', 'Tono-Pen', 'iCare'].map((m) => <option key={m}>{m}</option>)}
              </select>
            </div>
            <div>
              <label className="flbl">Measurement time</label>
              <input className="fi fi-sm" disabled={locked} value={form.iop_time} onChange={(e) => setField('iop_time', e.target.value)} placeholder="e.g. 10:30 AM" />
            </div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 16 }}>
            {[['RE', reIopSorted, reIopInput, setReIopInput], ['LE', leIopSorted, leIopInput, setLeIopInput]].map(([eye, list, val, setVal]) => (
              <div key={eye}>
                <div style={{ fontSize: 12, fontWeight: 700, color: eye === 'RE' ? 'var(--blue)' : 'var(--teal)', marginBottom: 8, padding: '5px 10px', background: eye === 'RE' ? 'var(--blue-lt)' : 'var(--teal-lt)', borderRadius: 8 }}>
                  <i className="ti ti-eye"></i> {eye === 'RE' ? 'Right Eye (OD)' : 'Left Eye (OS)'}
                </div>
                {list.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', padding: '6px 0' }}>No readings yet</div>}
                {list.map((r, i) => iopReadingRow(r, list, i))}
                {!locked && (
                  <div style={{ display: 'flex', gap: 6, marginTop: 6 }}>
                    <input type="number" className="fi fi-sm" style={{ flex: 1 }} placeholder="mmHg" min="1" max="80" value={val} onChange={(e) => setVal(e.target.value)} />
                    <button type="button" className="btn btn-sm btn-primary" onClick={() => handleAddIop(eye)}><i className="ti ti-plus"></i> Add reading</button>
                  </div>
                )}
              </div>
            ))}
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 4: ADDITIONAL MEASUREMENTS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={4} color="var(--amber)" title="Additional Measurements" badge={form.section_additional_done ? 'Done' : 'Not started'} badgeCls={form.section_additional_done ? 'b-green' : 'b-gray'}
          open={openSections.additional} onToggle={() => toggleSection('additional')}
        >
          <div style={{ fontSize: 11, color: 'var(--g500)', marginBottom: 12 }}>Complete only the measurements relevant to this visit.</div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Keratometry K1</label><input className="fi fi-sm" disabled={locked} value={form.add_k1} onChange={(e) => setField('add_k1', e.target.value)} placeholder="e.g. 43.50 D" /></div>
            <div><label className="flbl">Keratometry K2</label><input className="fi fi-sm" disabled={locked} value={form.add_k2} onChange={(e) => setField('add_k2', e.target.value)} placeholder="e.g. 44.25 D" /></div>
            <div><label className="flbl">Axial Length</label><input className="fi fi-sm" disabled={locked} value={form.add_axial_length} onChange={(e) => setField('add_axial_length', e.target.value)} placeholder="e.g. 23.2 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10, marginBottom: 12 }}>
            <div><label className="flbl">Pachymetry (CCT)</label><input className="fi fi-sm" disabled={locked} value={form.add_pachymetry} onChange={(e) => setField('add_pachymetry', e.target.value)} placeholder="e.g. 542 microns" /></div>
            <div><label className="flbl">White-to-White</label><input className="fi fi-sm" disabled={locked} value={form.add_white_to_white} onChange={(e) => setField('add_white_to_white', e.target.value)} placeholder="e.g. 11.8 mm" /></div>
            <div><label className="flbl">Schirmer test (RE/LE)</label><input className="fi fi-sm" disabled={locked} value={form.add_schirmer} onChange={(e) => setField('add_schirmer', e.target.value)} placeholder="e.g. 8/6 mm" /></div>
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr', gap: 10 }}>
            <div>
              <label className="flbl">Color vision</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_color_vision} onChange={(e) => setField('add_color_vision', e.target.value)}>
                <option value="">Not tested</option><option>Normal</option><option>Deficient</option><option>Unable to test</option>
              </select>
            </div>
            <div>
              <label className="flbl">Ocular motility</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_ocular_motility} onChange={(e) => setField('add_ocular_motility', e.target.value)}>
                <option value="">Not tested</option><option>Full in all directions</option><option>Restricted</option><option>Nystagmus present</option>
              </select>
            </div>
            <div>
              <label className="flbl">Syringing</label>
              <select className="fi fi-sm" disabled={locked} value={form.add_syringing} onChange={(e) => setField('add_syringing', e.target.value)}>
                <option value="">Not done</option><option>Patent RE</option><option>Patent LE</option><option>Patent bilateral</option><option>Block RE</option><option>Block LE</option>
              </select>
            </div>
          </div>
        </AsmtSection>
      </div>

      {/* SECTION 5: CLINICAL OBSERVATIONS */}
      <div style={{ marginBottom: 12 }}>
        <AsmtSection
          num={5} color="var(--g500)" title="Clinical Observations" badge={form.section_obs_done ? 'Done' : 'Not started'} badgeCls={form.section_obs_done ? 'b-green' : 'b-gray'}
          open={openSections.obs} onToggle={() => toggleSection('obs')}
        >
          <div className="msg-warn" style={{ background: 'var(--amber-lt)', color: 'var(--amber)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
            <i className="ti ti-alert-triangle"></i> Observations shall be descriptive only. No diagnoses or interpretations permitted here.
          </div>
          <div style={{ display: 'flex', flexWrap: 'wrap', gap: 5, marginBottom: 10 }}>
            {OBS_CHIPS.map((chip) => (
              <div
                key={chip}
                onClick={() => !locked && toggleObsChip(chip)}
                style={{ padding: '4px 10px', borderRadius: 20, fontSize: 11, fontWeight: 600, cursor: locked ? 'default' : 'pointer', border: `1.5px solid ${form.observation_chips.includes(chip) ? 'var(--teal)' : 'var(--g200)'}`, background: form.observation_chips.includes(chip) ? 'var(--teal)' : '#fff', color: form.observation_chips.includes(chip) ? '#fff' : 'var(--g600)' }}
              >
                {chip}
              </div>
            ))}
          </div>
          <label className="flbl">Additional observations (descriptive -- no diagnoses)</label>
          <textarea className="fi" disabled={locked} rows={2} value={form.observations_text} onChange={(e) => setField('observations_text', e.target.value)} placeholder="e.g. Patient had difficulty with right eye assessment due to glare sensitivity..." />
        </AsmtSection>
      </div>

      {/* AUDIT LOG */}
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-clock" style={{ color: 'var(--g400)' }}></i> Audit Log</div>
        {auditLog.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No activity yet.</div>}
        {auditLog.map((a) => (
          <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)', display: 'flex', gap: 8 }}>
            <span style={{ color: 'var(--g400)' }}>{new Date(a.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit', second: '2-digit' })}</span>
            <span>{a.message}</span>
          </div>
        ))}
      </div>

      <div style={{ marginTop: 16 }}>
        <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
          <i className="ti ti-arrow-left"></i> Back to Queue
        </button>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/optometry-dashboard/page.js" << 'EOF'
'use client';

import Link from 'next/link';
import { useState, useEffect, useCallback } from 'react';
import { getOptometryDashboardData } from './actions';
import { optometryCallNext, optometryCallSpecific } from '@/app/(main)/queue/actions';

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

function TokenBadge({ token }) {
  return (
    <span style={{
      fontFamily: 'monospace', fontWeight: 800, fontSize: 13, background: 'var(--g900)', color: '#fff',
      padding: '3px 9px', borderRadius: 6, marginRight: 8,
    }}>
      {token}
    </span>
  );
}

export default function OptometryDashboardPage() {
  const [active, setActive] = useState([]);
  const [completed, setCompleted] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const { active, completed } = await getOptometryDashboardData();
    setActive(active);
    setCompleted(completed);
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

  const waitingCount = active.filter((e) => e.status === 'Waiting').length;
  const callingCount = active.filter((e) => e.status === 'Calling').length;
  const editableCount = completed.filter((e) => !e.locked).length;
  const lockedCount = completed.filter((e) => e.locked).length;

  return (
    <div>
      {error && <div className="msg-err">{error}</div>}

      {/* STAT CARDS */}
      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Waiting</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{waitingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>In Progress</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{callingCount}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Editable Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{editableCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Posted, not yet seen by doctor</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--g400)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Locked Today</div>
          <div style={{ fontSize: 26, fontWeight: 800, marginTop: 6 }}>{lockedCount}</div>
          <div style={{ fontSize: 11, color: 'var(--g400)', marginTop: 2 }}>Doctor has opened these</div>
        </div>
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
        {/* ACTIVE QUEUE */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-eye-check" style={{ color: 'var(--teal)' }}></i> Optometry Queue
              <span className="badge b-gray">{active.length}</span>
            </div>
          </div>
          <button className="btn btn-primary" style={{ width: '100%', marginBottom: 12 }} onClick={() => runAction(optometryCallNext)}>
            <i className="ti ti-bell-ringing"></i> Call Next
          </button>
          {active.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
                background: e.status === 'Calling' ? 'var(--blue-lt)' : 'transparent',
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.status === 'Calling' ? 'b-blue' : 'b-gray'}`}>{e.status}</span>
                  <span className={`badge ${waitBadgeClass(elapsedMin(e.issued_at))}`}>
                    <i className="ti ti-clock"></i> {elapsedMin(e.issued_at)}m
                  </span>
                </div>
              </div>
              {e.status === 'Waiting' && (
                <button className="btn btn-sm" onClick={() => runAction(optometryCallSpecific, e.id)}>Call</button>
              )}
              {e.status === 'Calling' && (
                <Link href={`/optometry/${e.id}`} className="btn btn-primary btn-sm" style={{ textDecoration: 'none' }}>
                  Start Assessment
                </Link>
              )}
            </div>
          ))}
          {active.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
              Queue is empty
            </div>
          )}
        </div>

        {/* COMPLETED TODAY -- view / edit already-posted readings */}
        <div className="card">
          <div className="card-head">
            <div className="card-title">
              <i className="ti ti-clipboard-check" style={{ color: 'var(--purple)' }}></i> Completed Today
              <span className="badge b-gray">{completed.length}</span>
            </div>
          </div>
          {completed.map((e) => (
            <div
              key={e.id}
              style={{
                display: 'flex', justifyContent: 'space-between', alignItems: 'center',
                padding: '10px 8px', borderBottom: '1px solid var(--g100)', borderRadius: 6,
              }}
            >
              <div>
                <div style={{ display: 'flex', alignItems: 'center', marginBottom: 3 }}>
                  <TokenBadge token={e.token} />
                  <span style={{ fontWeight: 600, fontSize: 13 }}>{patientName(e)}</span>
                </div>
                <div style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                  <span className={`badge ${e.locked ? 'b-gray' : 'b-green'}`}>
                    {e.locked ? 'Locked -- doctor viewing' : 'Editable'}
                  </span>
                </div>
              </div>
              <Link href={`/optometry/${e.id}`} className="btn btn-sm" style={{ textDecoration: 'none' }}>
                {e.locked ? 'View' : 'Edit'}
              </Link>
            </div>
          ))}
          {completed.length === 0 && (
            <div style={{ textAlign: 'center', color: 'var(--g400)', fontSize: 13, padding: 24 }}>
              Nothing completed yet today
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

EOF

cat > "app/(main)/optometry-dashboard/actions.js" << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getOptometryDashboardData() {
  const supabase = await createClient();
  const today = new Date().toISOString().slice(0, 10);

  const [{ data: activeEntries }, { data: doneEntries }] = await Promise.all([
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Optometry')
      .in('status', ['Waiting', 'Calling'])
      .gte('issued_at', today)
      .order('issued_at', { ascending: true }),
    supabase
      .from('queue_entries')
      .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
      .eq('department', 'Optometry')
      .eq('status', 'Done')
      .gte('issued_at', today)
      .order('completed_at', { ascending: false }),
  ]);

  const done = doneEntries || [];
  const visitIds = done.map((e) => e.visits?.id).filter(Boolean);

  // Batch-fetch the Doctor queue status for every completed visit today, so
  // we can tell which posted readings are still editable vs. already locked
  // because the doctor has opened (or finished) the consultation.
  let doctorStatusByVisit = {};
  if (visitIds.length > 0) {
    const { data: doctorEntries } = await supabase
      .from('queue_entries')
      .select('visit_id, status')
      .eq('department', 'Doctor')
      .in('visit_id', visitIds);

    (doctorEntries || []).forEach((d) => {
      doctorStatusByVisit[d.visit_id] = d.status;
    });
  }

  const completed = done.map((e) => {
    const doctorStatus = doctorStatusByVisit[e.visits?.id] || null;
    const locked = doctorStatus === 'In Consultation' || doctorStatus === 'Done';
    return { ...e, doctorStatus, locked };
  });

  return { active: activeEntries || [], completed };
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

  const [{ data: diagnoses }, { data: prescriptions }, { data: investigations }] = await Promise.all([
    supabase.from('diagnoses').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('prescriptions').select('*').eq('encounter_id', encounter.id).order('created_at'),
    supabase.from('investigation_orders').select('*').eq('encounter_id', encounter.id).order('created_at'),
  ]);

  return { entry, findings, iopReadings, encounter, diagnoses: diagnoses || [], prescriptions: prescriptions || [], investigations: investigations || [] };
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

export default function ConsultationForm({ queueEntryId }) {
  const [data, setData] = useState(null);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const [showSurgery, setShowSurgery] = useState(false);
  const [surgeryProcedure, setSurgeryProcedure] = useState('');
  const [surgeryEye, setSurgeryEye] = useState('OU');
  const [surgeryLoading, setSurgeryLoading] = useState(false);
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
    <div style={{ maxWidth: 700, margin: '0 auto' }}>
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

echo "Optometry Assessment Workspace (Phase 1) created/updated."