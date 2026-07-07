mkdir -p app/pharmacy app/dashboard

cat > 'app/pharmacy/actions.js' << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function getPendingPrescriptions() {
  const supabase = await createClient();

  const { data, error } = await supabase
    .from('prescriptions')
    .select('*, encounters(id, visit_id, visits(id, patients(first_name, last_name, uhid)))')
    .eq('status', 'Pending')
    .order('created_at', { ascending: true });

  if (error) return [];

  // Group flat prescription rows by visit, since a pharmacist hands over
  // everything for one patient's visit together, not drug by drug.
  const groups = {};
  data.forEach((rx) => {
    const visitId = rx.encounters?.visit_id;
    if (!visitId) return;
    if (!groups[visitId]) {
      groups[visitId] = {
        visitId,
        patient: rx.encounters.visits.patients,
        items: [],
      };
    }
    groups[visitId].items.push(rx);
  });

  return Object.values(groups);
}

export async function dispensePrescription(id) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').update({ status: 'Dispensed' }).eq('id', id);
  if (error) return { error: error.message };
  return { success: true };
}

export async function dispenseAllForVisit(prescriptionIds) {
  const supabase = await createClient();
  const { error } = await supabase.from('prescriptions').update({ status: 'Dispensed' }).in('id', prescriptionIds);
  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/pharmacy/page.js' << 'EOF'
'use client';

import { useState, useEffect, useCallback } from 'react';
import { getPendingPrescriptions, dispensePrescription, dispenseAllForVisit } from './actions';

export default function PharmacyPage() {
  const [groups, setGroups] = useState([]);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const data = await getPendingPrescriptions();
    setGroups(data);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function handleDispenseOne(id) {
    setError('');
    const result = await dispensePrescription(id);
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  async function handleDispenseAll(items) {
    setError('');
    const result = await dispenseAllForVisit(items.map((i) => i.id));
    if (result.error) { setError(result.error); return; }
    refresh();
  }

  return (
    <div style={{ maxWidth: 800, margin: '40px auto', padding: '0 20px' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}>Pharmacy -- Pending Dispensing</div>
      {error && <div className="msg-err">{error}</div>}

      {groups.map((g) => (
        <div key={g.visitId} className="card" style={{ marginBottom: 16 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 10 }}>
            <div style={{ fontSize: 15, fontWeight: 700 }}>
              {g.patient?.first_name} {g.patient?.last_name} -- {g.patient?.uhid}
            </div>
            <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={() => handleDispenseAll(g.items)}>
              Dispense All ({g.items.length})
            </button>
          </div>
          {g.items.map((rx) => (
            <div
              key={rx.id}
              style={{
                display: 'flex',
                justifyContent: 'space-between',
                alignItems: 'center',
                padding: '8px 0',
                borderBottom: '1px solid var(--g100)',
                fontSize: 13,
              }}
            >
              <span>
                <strong>{rx.drug_name}</strong> -- {rx.dosage} {rx.frequency} x {rx.duration} -- {rx.eye}
              </span>
              <button className="btn" style={{ padding: '3px 10px', fontSize: 11 }} onClick={() => handleDispenseOne(rx.id)}>
                Dispense
              </button>
            </div>
          ))}
        </div>
      ))}

      {groups.length === 0 && (
        <div className="card" style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>
          Nothing pending -- all caught up.
        </div>
      )}
    </div>
  );
}

EOF

cat > 'app/dashboard/page.js' << 'EOF'
import { createClient } from '../../lib/supabase-server';
import SignOutButton from './sign-out-button';
import Link from 'next/link';

export default async function DashboardPage() {
  const supabase = await createClient();

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const { data: profile } = await supabase
    .from('profiles')
    .select('*')
    .eq('id', user.id)
    .single();

  return (
    <div style={{ maxWidth: 640, margin: '60px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>VEDA HMIS</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Real login, real database -- Phase 1 proof of concept
            </div>
          </div>
          <SignOutButton />
        </div>

        <div
          style={{
            background: 'var(--green-lt)',
            color: 'var(--green)',
            padding: '10px 14px',
            borderRadius: 8,
            fontSize: 13,
            marginBottom: 20,
          }}
        >
          You are genuinely logged in via Supabase Auth, and this page just
          read your staff profile from the real <code>profiles</code> table.
        </div>

        <div style={{ fontSize: 13, lineHeight: 1.8 }}>
          <div>
            <strong>Name:</strong> {profile?.full_name || '(not set yet)'}
          </div>
          <div>
            <strong>Designation:</strong> {profile?.designation || '(not set yet)'}
          </div>
          <div>
            <strong>Department:</strong> {profile?.department || '(not set yet)'}
          </div>
          <div>
            <strong>Status:</strong> {profile?.status}
          </div>
          <div>
            <strong>Email:</strong> {user.email}
          </div>
        </div>

        <div style={{ display: 'flex', gap: 8, marginTop: 20, paddingTop: 20, borderTop: '1px solid var(--g200)' }}>
          <Link href="/patients/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Register New Patient
          </Link>
          <Link href="/patients" className="btn" style={{ textDecoration: 'none' }}>
            View All Patients
          </Link>
          <Link href="/appointments/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Book Appointment
          </Link>
          <Link href="/appointments" className="btn" style={{ textDecoration: 'none' }}>
            View Appointments
          </Link>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
          <Link href="/visits" className="btn" style={{ textDecoration: 'none' }}>
            View Open Visits
          </Link>
          <Link href="/queue" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            Queue Management
          </Link>
          <Link href="/pharmacy" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            Pharmacy
          </Link>
        </div>
      </div>
    </div>
  );
}

EOF

echo "Pharmacy module created."
