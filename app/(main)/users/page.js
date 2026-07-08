'use client';

import { useState, useEffect, useCallback } from 'react';
import { getUsers, createUser, toggleUserStatus, resetUserPassword } from './actions';

function ResetPasswordButton({ userId }) {
  const [open, setOpen] = useState(false);
  const [password, setPassword] = useState('');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleReset() {
    setError('');
    setLoading(true);
    const result = await resetUserPassword(userId, password);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setOpen(false);
    setPassword('');
  }

  if (!open) {
    return <button className="btn btn-sm" onClick={() => setOpen(true)}>Reset Password</button>;
  }
  return (
    <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
      <input className="fi" type="password" placeholder="New password" value={password} onChange={(e) => setPassword(e.target.value)} style={{ width: 130 }} />
      <button className="btn btn-primary btn-sm" onClick={handleReset} disabled={loading}>Save</button>
      <button className="btn btn-sm" onClick={() => setOpen(false)}>x</button>
      {error && <span style={{ fontSize: 11, color: 'var(--red)' }}>{error}</span>}
    </div>
  );
}

export default function UsersPage() {
  const [users, setUsers] = useState([]);
  const [showAdd, setShowAdd] = useState(false);
  const [form, setForm] = useState({ email: '', password: '', fullName: '', designation: '', department: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setUsers(await getUsers());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleCreate() {
    setError('');
    setLoading(true);
    const result = await createUser(form);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setForm({ email: '', password: '', fullName: '', designation: '', department: '' });
    setShowAdd(false);
    refresh();
  }

  async function handleToggle(userId, status) {
    await toggleUserStatus(userId, status);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-head">
        <div className="card-title">
          <i className="ti ti-users-group" style={{ color: 'var(--blue)' }}></i> Staff Accounts
          <span className="badge b-gray">{users.length}</span>
        </div>
        <button className="btn btn-primary btn-sm" onClick={() => setShowAdd(!showAdd)}>
          <i className="ti ti-plus"></i> New Staff Login
        </button>
      </div>

      {error && <div className="msg-err">{error}</div>}

      {showAdd && (
        <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <input className="fi" placeholder="Full name" value={form.fullName} onChange={update('fullName')} />
            <input className="fi" placeholder="Email (login)" value={form.email} onChange={update('email')} />
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <input className="fi" placeholder="Designation (e.g. Optometrist)" value={form.designation} onChange={update('designation')} />
            <input className="fi" placeholder="Department" value={form.department} onChange={update('department')} />
          </div>
          <input className="fi" type="password" placeholder="Temporary password (min 6 chars)" value={form.password} onChange={update('password')} style={{ marginBottom: 8 }} />
          <button className="btn btn-primary btn-sm" onClick={handleCreate} disabled={loading}>
            {loading ? 'Creating...' : 'Create Account'}
          </button>
        </div>
      )}

      <table className="tbl">
        <thead>
          <tr><th>Name</th><th>Designation</th><th>Department</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {users.map((u) => (
            <tr key={u.id}>
              <td style={{ fontWeight: 600 }}>{u.full_name}</td>
              <td>{u.designation}</td>
              <td>{u.department}</td>
              <td>
                <button
                  className={`badge ${u.status === 'Active' ? 'b-green' : 'b-gray'}`}
                  style={{ border: 'none', cursor: 'pointer' }}
                  onClick={() => handleToggle(u.id, u.status)}
                >
                  {u.status}
                </button>
              </td>
              <td><ResetPasswordButton userId={u.id} /></td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

