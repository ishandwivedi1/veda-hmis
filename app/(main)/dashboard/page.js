import { createClient } from '@/lib/supabase-server';

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

  const today = new Date().toISOString().slice(0, 10);

  const [{ count: patientCount }, { count: apptCount }, { count: visitCount }, { count: rxCount }] = await Promise.all([
    supabase.from('patients').select('*', { count: 'exact', head: true }),
    supabase.from('appointments').select('*', { count: 'exact', head: true }).eq('appointment_date', today),
    supabase.from('visits').select('*', { count: 'exact', head: true }).eq('status', 'Open'),
    supabase.from('prescriptions').select('*', { count: 'exact', head: true }).eq('status', 'Pending'),
  ]);

  return (
    <div>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>Dashboard</div>
      <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 20 }}>
        Welcome back, {profile?.full_name || user.email}
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 16, marginBottom: 20 }}>
        <div className="card" style={{ borderTop: '3px solid var(--blue)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Total Patients</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{patientCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--amber)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Today&apos;s Appointments</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{apptCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--green)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Open Visits</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{visitCount ?? 0}</div>
        </div>
        <div className="card" style={{ borderTop: '3px solid var(--purple)' }}>
          <div style={{ fontSize: 11, color: 'var(--g500)', fontWeight: 600, textTransform: 'uppercase' }}>Pending Prescriptions</div>
          <div style={{ fontSize: 28, fontWeight: 800, marginTop: 6 }}>{rxCount ?? 0}</div>
        </div>
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-user-circle" style={{ color: 'var(--blue)' }}></i> Your Profile
        </div>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div><strong>Name:</strong> {profile?.full_name || '(not set yet)'}</div>
          <div><strong>Designation:</strong> {profile?.designation || '(not set yet)'}</div>
          <div><strong>Department:</strong> {profile?.department || '(not set yet)'}</div>
          <div><strong>Status:</strong> <span className="badge b-green">{profile?.status}</span></div>
          <div><strong>Email:</strong> {user.email}</div>
        </div>
      </div>
    </div>
  );
}

