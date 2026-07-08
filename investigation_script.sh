mkdir -p 'app/(main)/investigation' app/components

cat > 'app/(main)/investigation/actions.js' << 'EOF'
'use server';

import { createClient } from '@/lib/supabase-server';

export async function getInvestigationQueue() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('investigation_orders')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .in('status', ['Ordered', 'In Progress'])
    .order('priority', { ascending: true })
    .order('created_at', { ascending: true });

  if (error) return [];

  const groups = {};
  data.forEach((io) => {
    const visitId = io.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: io.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(io);
  });

  return Object.values(groups);
}

export async function startInvestigation(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('investigation_orders').update({ status: 'In Progress' }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function completeInvestigation(id, notes) {
  const supabase = await createClient();

  const { data: userData } = await supabase.auth.getUser();

  const { error } = await supabase
    .from('investigation_orders')
    .update({
      status: 'Completed',
      result_notes: notes || null,
      completed_at: new Date().toISOString(),
      completed_by: userData?.user?.id || null,
    })
    .eq('id', id);

  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/(main)/investigation/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getInvestigationQueue, startInvestigation, completeInvestigation } from './actions';

const PRIORITY_BADGE = { Urgent: 'b-red', Routine: 'b-gray' };

function InvestigationItem({ item, onUpdate }) {
  const [notes, setNotes] = useState('');
  const [showComplete, setShowComplete] = useState(false);
  const [loading, setLoading] = useState(false);

  async function handleStart() {
    setLoading(true);
    await startInvestigation(item.id);
    setLoading(false);
    onUpdate();
  }

  async function handleComplete() {
    setLoading(true);
    await completeInvestigation(item.id, notes);
    setLoading(false);
    onUpdate();
  }

  return (
    <div style={{ padding: '10px 0', borderBottom: '1px solid var(--g100)' }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
        <div>
          <span style={{ fontWeight: 600, fontSize: 13 }}>{item.name}</span>
          <span style={{ fontSize: 12, color: 'var(--g500)', marginLeft: 8 }}>{item.eye}</span>
          <span className={`badge ${PRIORITY_BADGE[item.priority] || 'b-gray'}`} style={{ marginLeft: 8 }}>{item.priority}</span>
          <span className={`badge ${item.status === 'In Progress' ? 'b-blue' : 'b-amber'}`} style={{ marginLeft: 6 }}>{item.status}</span>
        </div>
        {item.status === 'Ordered' && (
          <button className="btn btn-sm" onClick={handleStart} disabled={loading}>
            <i className="ti ti-player-play"></i> Start
          </button>
        )}
        {item.status === 'In Progress' && !showComplete && (
          <button className="btn btn-primary btn-sm" onClick={() => setShowComplete(true)}>
            <i className="ti ti-check"></i> Complete
          </button>
        )}
      </div>
      {showComplete && (
        <div style={{ marginTop: 8, display: 'flex', gap: 6 }}>
          <input
            className="fi"
            placeholder="Findings / result notes (optional)"
            value={notes}
            onChange={(e) => setNotes(e.target.value)}
            style={{ flex: 1 }}
          />
          <button className="btn btn-primary btn-sm" onClick={handleComplete} disabled={loading}>
            {loading ? 'Saving...' : 'Save & Complete'}
          </button>
        </div>
      )}
    </div>
  );
}

export default function InvestigationPage() {
  const [groups, setGroups] = useState([]);

  const refresh = useCallback(async () => {
    const data = await getInvestigationQueue();
    setGroups(data);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  return (
    <div>
      {groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 16 }}>
          <div className="card-title" style={{ marginBottom: 10 }}>
            <i className="ti ti-flask" style={{ color: 'var(--purple)' }}></i>
            {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
          </div>
          {g.items.map((item) => (
            <InvestigationItem key={item.id} item={item} onUpdate={refresh} />
          ))}
        </div>
      ))}

      {groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          <i className="ti ti-circle-check" style={{ fontSize: 22, display: 'block', marginBottom: 6 }}></i>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/components/AppShell.js' << 'EOF'
'use client';

import { usePathname, useRouter } from 'next/navigation';
import Link from 'next/link';
import { useEffect, useState } from 'react';
import { createClient } from '@/lib/supabase-browser';

const NAV_ITEMS = [
  { href: '/dashboard', label: 'Dashboard', icon: 'ti-layout-dashboard', section: 'Overview' },
  { href: '/patients', label: 'Patients', icon: 'ti-users', section: 'Front Office' },
  { href: '/appointments', label: 'Appointments', icon: 'ti-calendar-event', section: 'Front Office' },
  { href: '/visits', label: 'Open Visits', icon: 'ti-door-enter', section: 'Front Office' },
  { href: '/queue', label: 'Queue Management', icon: 'ti-list-numbers', section: 'Clinical' },
  { href: '/investigation', label: 'Investigation', icon: 'ti-flask', section: 'Clinical' },
  { href: '/pharmacy', label: 'Pharmacy', icon: 'ti-pill', section: 'Clinical' },
];

const PAGE_TITLES = [
  { match: /^\/dashboard/, title: 'Dashboard' },
  { match: /^\/patients\/new/, title: 'Register New Patient' },
  { match: /^\/patients/, title: 'Patients' },
  { match: /^\/appointments\/new/, title: 'Book Appointment' },
  { match: /^\/appointments/, title: 'Appointments' },
  { match: /^\/visits\/new/, title: 'Create Walk-in Visit' },
  { match: /^\/visits/, title: 'Open Visits' },
  { match: /^\/queue/, title: 'Queue Management' },
  { match: /^\/optometry/, title: 'Optometry' },
  { match: /^\/consultation/, title: 'Doctor Consultation' },
  { match: /^\/investigation/, title: 'Investigation' },
  { match: /^\/billing/, title: 'Billing' },
  { match: /^\/pharmacy/, title: 'Pharmacy' },
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

echo "Investigation module created."
