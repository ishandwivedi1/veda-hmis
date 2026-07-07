import { createClient } from '../../lib/supabase-server';
import SignOutButton from './sign-out-button';

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
          <div><strong>Name:</strong> {profile?.full_name || '(not set yet)'}</div>
          <div><strong>Designation:</strong> {profile?.designation || '(not set yet)'}</div>
          <div><strong>Department:</strong> {profile?.department || '(not set yet)'}</div>
          <div><strong>Status:</strong> {profile?.status}</div>
          <div><strong>Email:</strong> {user.email}</div>
        </div>
      </div>
    </div>
  );
}
