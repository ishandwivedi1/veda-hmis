mkdir -p "app/components" "app/(main)/optometry" "app/(main)/optometry/[id]" "app/(main)/optometry-dashboard"

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
  { href: '/optometry-dashboard', label: 'Optometrist Dashboard', icon: 'ti-eye-check', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
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
  { match: /^\/optometry-dashboard/, title: 'Optometrist Dashboard' },
  { match: /^\/optometry/, title: 'Optometry' },
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

export async function getQueueEntryForOptometry(queueEntryId) {
  const supabase = await createClient();

  const { data: entry, error } = await supabase
    .from('queue_entries')
    .select('*, visits(id, patients(first_name, last_name, uhid, age, gender))')
    .eq('id', queueEntryId)
    .single();

  if (error) return { error: error.message };

  const visitId = entry.visits?.id;

  // Pull the most recent findings row for this visit, if any -- used to
  // prefill the form when the optometrist is revisiting an already-completed
  // entry (edit mode), or when re-opening a "Calling" entry that already has
  // a draft saved.
  const { data: findings } = await supabase
    .from('optometry_findings')
    .select('*')
    .eq('visit_id', visitId)
    .order('recorded_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  // Findings stay editable until the doctor actually opens the consultation
  // for this visit. Once the linked Doctor queue entry moves to
  // "In Consultation" or "Done", we lock the form.
  let locked = false;
  if (entry.status === 'Done') {
    const { data: doctorEntry } = await supabase
      .from('queue_entries')
      .select('status')
      .eq('visit_id', visitId)
      .eq('department', 'Doctor')
      .maybeSingle();

    locked = doctorEntry?.status === 'In Consultation' || doctorEntry?.status === 'Done';
  }

  return { entry, findings: findings || null, locked };
}

// First-time entry: called while the optometry queue entry is still
// "Calling". Inserts a new findings row and completes the queue entry,
// which in turn issues the Doctor token for this visit.
export async function saveFindingsAndComplete(queueEntryId, visitId, findings) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error: findingsError } = await supabase.from('optometry_findings').insert({
    visit_id: visitId,
    re_va: findings.reVa || null,
    le_va: findings.leVa || null,
    re_iop: findings.reIop ? parseFloat(findings.reIop) : null,
    le_iop: findings.leIop ? parseFloat(findings.leIop) : null,
    re_sph: findings.reSph || null,
    le_sph: findings.leSph || null,
    re_cyl: findings.reCyl || null,
    le_cyl: findings.leCyl || null,
    recorded_by: userData?.user?.id || null,
  });

  if (findingsError) {
    return { error: findingsError.message };
  }

  const { error: completeError } = await supabase.rpc('optometry_complete', {
    p_queue_entry_id: queueEntryId,
  });

  if (completeError) {
    return { error: completeError.message };
  }

  return { success: true };
}

// Edit path: the optometry entry is already "Done" (readings already
// posted) and not yet locked. Updates the existing findings row in place --
// does NOT touch queue status or issue any new token, since that already
// happened the first time this entry was completed.
export async function updateFindings(findingsId, findings) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('optometry_findings')
    .update({
      re_va: findings.reVa || null,
      le_va: findings.leVa || null,
      re_iop: findings.reIop ? parseFloat(findings.reIop) : null,
      le_iop: findings.leIop ? parseFloat(findings.leIop) : null,
      re_sph: findings.reSph || null,
      le_sph: findings.leSph || null,
      re_cyl: findings.reCyl || null,
      le_cyl: findings.leCyl || null,
      recorded_by: userData?.user?.id || null,
      recorded_at: new Date().toISOString(),
    })
    .eq('id', findingsId);

  if (error) {
    return { error: error.message };
  }

  return { success: true };
}

EOF

cat > "app/(main)/optometry/[id]/optometry-form.js" << 'EOF'
'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getQueueEntryForOptometry, saveFindingsAndComplete, updateFindings } from '@/app/(main)/optometry/actions';

export default function OptometryForm({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
  const [findings, setFindings] = useState(null);
  const [locked, setLocked] = useState(false);
  const [loadError, setLoadError] = useState('');

  const [reVa, setReVa] = useState('');
  const [leVa, setLeVa] = useState('');
  const [reIop, setReIop] = useState('');
  const [leIop, setLeIop] = useState('');
  const [reSph, setReSph] = useState('');
  const [leSph, setLeSph] = useState('');
  const [reCyl, setReCyl] = useState('');
  const [leCyl, setLeCyl] = useState('');

  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  useEffect(() => {
    getQueueEntryForOptometry(queueEntryId).then((result) => {
      if (result.error) {
        setLoadError(result.error);
        return;
      }

      setEntry(result.entry);
      setFindings(result.findings);
      setLocked(result.locked);

      if (result.findings) {
        setReVa(result.findings.re_va || '');
        setLeVa(result.findings.le_va || '');
        setReIop(result.findings.re_iop ?? '');
        setLeIop(result.findings.le_iop ?? '');
        setReSph(result.findings.re_sph || '');
        setLeSph(result.findings.le_sph || '');
        setReCyl(result.findings.re_cyl || '');
        setLeCyl(result.findings.le_cyl || '');
      }
    });
  }, [queueEntryId]);

  const isEdit = entry?.status === 'Done' && !!findings;

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const values = { reVa, leVa, reIop, leIop, reSph, leSph, reCyl, leCyl };

    const result = isEdit
      ? await updateFindings(findings.id, values)
      : await saveFindingsAndComplete(queueEntryId, entry.visits.id, values);

    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/optometry-dashboard');
  }

  if (loadError) {
    return (
      <div style={{ maxWidth: 560, margin: '0 auto' }}>
        <div className="msg-err">{loadError}</div>
      </div>
    );
  }

  if (!entry) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = entry.visits?.patients;

  return (
    <div style={{ maxWidth: 560, margin: '0 auto' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          <i className="ti ti-eye-check" style={{ color: 'var(--teal)', marginRight: 6 }}></i>
          Optometry -- {entry.token}
        </div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 16 }}>
          {patient?.first_name} {patient?.last_name} -- {patient?.uhid} -- {patient?.age} {patient?.gender}
        </div>

        {isEdit && !locked && (
          <div className="msg-success" style={{ marginBottom: 16 }}>
            <i className="ti ti-pencil"></i> Editing readings already posted for this visit -- the doctor hasn&apos;t started the consultation yet.
          </div>
        )}

        {locked && (
          <div className="msg-err" style={{ marginBottom: 16 }}>
            <i className="ti ti-lock"></i> The doctor has already started this consultation. Readings are locked and shown here for reference only.
          </div>
        )}

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
          <fieldset disabled={locked} style={{ border: 'none', padding: 0, margin: 0 }}>
            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
              Visual Acuity
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
              <div>
                <label className="flbl">RE VA</label>
                <input className="fi" value={reVa} onChange={(e) => setReVa(e.target.value)} placeholder="e.g. 6/9" />
              </div>
              <div>
                <label className="flbl">LE VA</label>
                <input className="fi" value={leVa} onChange={(e) => setLeVa(e.target.value)} placeholder="e.g. 6/12" />
              </div>
            </div>

            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
              IOP (mmHg)
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 12, marginBottom: 16 }}>
              <div>
                <label className="flbl">RE IOP</label>
                <input type="number" className="fi" value={reIop} onChange={(e) => setReIop(e.target.value)} />
              </div>
              <div>
                <label className="flbl">LE IOP</label>
                <input type="number" className="fi" value={leIop} onChange={(e) => setLeIop(e.target.value)} />
              </div>
            </div>

            <div style={{ fontSize: 12, fontWeight: 700, color: 'var(--g600)', marginBottom: 8 }}>
              Refraction
            </div>
            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr 1fr 1fr', gap: 8, marginBottom: 20 }}>
              <div>
                <label className="flbl">RE Sph</label>
                <input className="fi" value={reSph} onChange={(e) => setReSph(e.target.value)} placeholder="-2.00" />
              </div>
              <div>
                <label className="flbl">RE Cyl</label>
                <input className="fi" value={reCyl} onChange={(e) => setReCyl(e.target.value)} placeholder="-0.50" />
              </div>
              <div>
                <label className="flbl">LE Sph</label>
                <input className="fi" value={leSph} onChange={(e) => setLeSph(e.target.value)} placeholder="-1.50" />
              </div>
              <div>
                <label className="flbl">LE Cyl</label>
                <input className="fi" value={leCyl} onChange={(e) => setLeCyl(e.target.value)} placeholder="-0.25" />
              </div>
            </div>
          </fieldset>

          <div style={{ display: 'flex', gap: 8 }}>
            {!locked && (
              <button type="submit" className="btn btn-primary" disabled={loading}>
                {loading ? 'Saving...' : isEdit ? 'Save Changes' : 'Save & Complete -- Send to Doctor'}
              </button>
            )}
            <button type="button" className="btn" onClick={() => router.push('/optometry-dashboard')}>
              {locked ? 'Back' : 'Cancel'}
            </button>
          </div>
        </form>
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
                  Enter Findings
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

echo "Optometrist Dashboard module created/updated."