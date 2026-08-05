'use client';

import { useState, useEffect, useCallback } from 'react';
import { getUsers, createUser, toggleUserStatus, resetUserPassword, updateUserProfile, updateStaffIdentity, getMyDesignation } from './actions';

const DESIGNATIONS = ['Doctor', 'Optometrist', 'Front Executive', 'Administrator', 'Nurse / OT Staff', 'Counsellor'];

// Heartbeat updates every ~60s while the app is open (see AppShell.js).
// A few minutes' grace covers normal timing/network gaps without
// flip-flopping between Online/Away on every tick.
function onlineStatus(lastActiveAt) {
  if (!lastActiveAt) return { label: 'Never logged in', color: 'var(--g400)' };
  const minutesAgo = (Date.now() - new Date(lastActiveAt).getTime()) / 60000;
  if (minutesAgo < 3) return { label: 'Online', color: 'var(--green)' };
  if (minutesAgo < 30) return { label: `Away (${Math.round(minutesAgo)}m)`, color: 'var(--amber)' };
  const d = new Date(lastActiveAt);
  const label = d.toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }) === new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' })
    ? `Last seen ${d.toLocaleTimeString('en-IN', { timeZone: 'Asia/Kolkata', hour: '2-digit', minute: '2-digit' })}`
    : `Last seen ${d.toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short' })}`;
  return { label, color: 'var(--g400)' };
}

function EditProfileRow({ user, isAdmin, onDone }) {
  const [fullName, setFullName] = useState(user.full_name || '');
  const [username, setUsername] = useState(user.username || '');
  const [designation, setDesignation] = useState(user.designation || '');
  const [department, setDepartment] = useState(user.department || '');
  const [registrationNo, setRegistrationNo] = useState(user.registration_no || '');
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  async function handleSave() {
    setError('');
    setLoading(true);

    if (isAdmin && (fullName !== user.full_name || username !== user.username)) {
      const identityResult = await updateStaffIdentity(user.id, { fullName, username });
      if (identityResult.error) {
        setLoading(false);
        setError(identityResult.error);
        return;
      }
    }

    const result = await updateUserProfile(user.id, { designation, department, registrationNo });
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    onDone(true);
  }

  return (
    <>
      <td>
        {isAdmin ? (
          <input className="fi" value={fullName} onChange={(e) => setFullName(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        ) : (
          <span style={{ fontWeight: 600 }}>{user.full_name}</span>
        )}
      </td>
      <td>
        {isAdmin ? (
          <input className="fi" value={username} onChange={(e) => setUsername(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        ) : (
          <span>{user.username}</span>
        )}
      </td>
      <td>
        <select className="fi" value={designation} onChange={(e) => setDesignation(e.target.value)} style={{ fontSize: 12, padding: '4px 6px', marginBottom: designation === 'Doctor' ? 4 : 0 }}>
          <option value="">-- Select --</option>
          {DESIGNATIONS.map((d) => <option key={d} value={d}>{d}</option>)}
        </select>
        {designation === 'Doctor' && (
          <input className="fi" placeholder="Regn. No." value={registrationNo} onChange={(e) => setRegistrationNo(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
        )}
      </td>
      <td>
        <input className="fi" value={department} onChange={(e) => setDepartment(e.target.value)} style={{ fontSize: 12, padding: '4px 6px' }} />
      </td>
      <td></td>
      <td colSpan={2}>
        <div style={{ display: 'flex', gap: 4, alignItems: 'center' }}>
          <button className="btn btn-primary btn-sm" onClick={handleSave} disabled={loading}>{loading ? 'Saving...' : 'Save'}</button>
          <button className="btn btn-sm" onClick={() => onDone(false)} disabled={loading}>Cancel</button>
          {error && <span style={{ fontSize: 11, color: 'var(--red)' }}>{error}</span>}
        </div>
      </td>
    </>
  );
}

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
  const [myDesignation, setMyDesignation] = useState(null);
  const [showAdd, setShowAdd] = useState(false);
  const [editingId, setEditingId] = useState(null);
  const [form, setForm] = useState({ username: '', password: '', fullName: '', designation: '', department: '', registrationNo: '' });
  const [error, setError] = useState('');
  const [loading, setLoading] = useState(false);

  const isAdmin = myDesignation === 'Administrator';

  const refresh = useCallback(async () => {
    setUsers(await getUsers());
  }, []);

  useEffect(() => {
    refresh();
    getMyDesignation().then(setMyDesignation);
  }, [refresh]);

  function update(field) {
    return (e) => setForm((f) => ({ ...f, [field]: e.target.value }));
  }

  async function handleCreate() {
    setError('');
    setLoading(true);
    const result = await createUser(form);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setForm({ username: '', password: '', fullName: '', designation: '', department: '', registrationNo: '' });
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

      {!isAdmin && myDesignation && (
        <div className="msg-info" style={{ marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Only an Administrator can rename staff or change their login username. Designation and department can still be updated here.
        </div>
      )}

      {showAdd && (
        <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12, marginBottom: 16 }}>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <input className="fi" placeholder="Full name" value={form.fullName} onChange={update('fullName')} />
            <input className="fi" placeholder="Username (email, mobile, or anything)" value={form.username} onChange={update('username')} />
          </div>
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 8, marginBottom: 8 }}>
            <select className="fi" value={form.designation} onChange={update('designation')}>
              <option value="">-- Select designation --</option>
              {DESIGNATIONS.map((d) => <option key={d} value={d}>{d}</option>)}
            </select>
            <input className="fi" placeholder="Department" value={form.department} onChange={update('department')} />
          </div>
          {form.designation === 'Doctor' && (
            <input className="fi" placeholder="Doctor Registration No. (appears on printouts)" value={form.registrationNo} onChange={update('registrationNo')} style={{ marginBottom: 8 }} />
          )}
          <input className="fi" type="password" placeholder="Temporary password (min 6 chars)" value={form.password} onChange={update('password')} style={{ marginBottom: 8 }} />
          <button className="btn btn-primary btn-sm" onClick={handleCreate} disabled={loading}>
            {loading ? 'Creating...' : 'Create Account'}
          </button>
        </div>
      )}

      <table className="tbl">
        <thead>
          <tr><th>Name</th><th>Username</th><th>Designation</th><th>Department</th><th>Online</th><th>Status</th><th></th></tr>
        </thead>
        <tbody>
          {users.map((u) => (
            <tr key={u.id}>
              {editingId === u.id ? (
                <EditProfileRow
                  user={u}
                  isAdmin={isAdmin}
                  onDone={(saved) => { setEditingId(null); if (saved) refresh(); }}
                />
              ) : (
                <>
                  <td style={{ fontWeight: 600 }}>{u.full_name}</td>
                  <td>{u.username}</td>
                  <td>
                    {u.designation}
                    {u.designation === 'Doctor' && u.registration_no && (
                      <div style={{ fontSize: 10, color: 'var(--g500)', marginTop: 2 }}>Regn: {u.registration_no}</div>
                    )}
                  </td>
                  <td>{u.department}</td>
                  <td>
                    {(() => {
                      const s = onlineStatus(u.last_active_at);
                      return (
                        <span style={{ fontSize: 12, color: s.color, display: 'flex', alignItems: 'center', gap: 5 }}>
                          <span style={{ width: 7, height: 7, borderRadius: '50%', background: s.color, display: 'inline-block' }}></span>
                          {s.label}
                        </span>
                      );
                    })()}
                  </td>
                  <td>
                    <button
                      className={`badge ${u.status === 'Active' ? 'b-green' : 'b-gray'}`}
                      style={{ border: 'none', cursor: 'pointer' }}
                      onClick={() => handleToggle(u.id, u.status)}
                    >
                      {u.status}
                    </button>
                  </td>
                  <td style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                    <button className="btn btn-sm" onClick={() => setEditingId(u.id)}>
                      <i className="ti ti-edit"></i> Edit
                    </button>
                    <ResetPasswordButton userId={u.id} />
                  </td>
                </>
              )}
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}

