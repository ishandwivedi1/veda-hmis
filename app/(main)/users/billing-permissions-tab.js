'use client';

// "Billing Permissions" tab of User Management (Administrator only).
// Decides which designations may edit / void / delete invoices and
// payments. Every change is recorded permanently in billing_audit_log.

import { useState, useEffect, useCallback } from 'react';
import { getBillingPermissionMatrix, setBillingPermission } from './billing-permission-actions';
import { BILLING_PERMISSIONS } from '@/lib/billingPermissionDefs';

const ACTION_LABEL = { permission_granted: 'Allowed', permission_revoked: 'Removed' };

export default function BillingPermissionsTab({ designations }) {
  const others = designations.filter((d) => d !== 'Administrator');
  const [matrix, setMatrix] = useState({});
  const [history, setHistory] = useState([]);
  const [loading, setLoading] = useState(true);
  const [saving, setSaving] = useState(null); // "designation|permission"
  const [error, setError] = useState('');

  const load = useCallback(async () => {
    const res = await getBillingPermissionMatrix();
    if (res.error) setError(res.error);
    else { setMatrix(res.matrix); setHistory(res.history); }
    setLoading(false);
  }, []);

  useEffect(() => { load(); }, [load]);

  async function toggle(designation, permission, allowed) {
    const key = `${designation}|${permission}`;
    setError('');
    setSaving(key);
    // optimistic, reverted on failure
    setMatrix((m) => ({ ...m, [designation]: { ...(m[designation] || {}), [permission]: allowed } }));
    const res = await setBillingPermission(designation, permission, allowed);
    setSaving(null);
    if (res.error) {
      setError(res.error);
      setMatrix((m) => ({ ...m, [designation]: { ...(m[designation] || {}), [permission]: !allowed } }));
      return;
    }
    load();
  }

  if (loading) return <div style={{ textAlign: 'center', color: 'var(--g400)', padding: 30 }}>Loading...</div>;

  let lastGroup = null;

  return (
    <div>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 6 }}>
          <i className="ti ti-shield-lock" style={{ color: 'var(--blue)' }}></i> Billing Permissions
        </div>
        <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 12, lineHeight: 1.5 }}>
          Choose who may change invoices and payments after they are created. Every change needs a reason and is kept
          permanently in the billing history. A <strong>closed day</strong> stays locked for everyone until an
          Administrator reopens it in Cash Management. Administrators always have every permission.
        </div>

        {error && <div className="msg-err">{error}</div>}

        <div style={{ overflowX: 'auto' }}>
          <table className="tbl">
            <thead>
              <tr>
                <th style={{ minWidth: 220 }}>Permission</th>
                <th style={{ textAlign: 'center' }}>Administrator</th>
                {others.map((d) => <th key={d} style={{ textAlign: 'center' }}>{d}</th>)}
              </tr>
            </thead>
            <tbody>
              {BILLING_PERMISSIONS.map((p) => {
                const showGroup = p.group !== lastGroup;
                lastGroup = p.group;
                return [
                  showGroup && (
                    <tr key={`g-${p.group}`}>
                      <td colSpan={2 + others.length} style={{ background: 'var(--g50, #f8fafc)', fontWeight: 700, fontSize: 11, textTransform: 'uppercase', letterSpacing: 0.4, color: 'var(--g500)' }}>
                        {p.group}
                      </td>
                    </tr>
                  ),
                  <tr key={p.key}>
                    <td>
                      <div style={{ fontWeight: 600 }}>{p.label}</div>
                      <div style={{ fontSize: 11, color: 'var(--g400)' }}>{p.help}</div>
                    </td>
                    <td style={{ textAlign: 'center' }}>
                      <i className="ti ti-lock" title="Always allowed" style={{ color: 'var(--green)' }}></i>
                    </td>
                    {others.map((d) => {
                      const key = `${d}|${p.key}`;
                      const checked = !!matrix[d]?.[p.key];
                      return (
                        <td key={key} style={{ textAlign: 'center' }}>
                          <input
                            type="checkbox"
                            checked={checked}
                            disabled={saving !== null}
                            onChange={(e) => toggle(d, p.key, e.target.checked)}
                            style={{ width: 16, height: 16, cursor: saving ? 'wait' : 'pointer' }}
                            aria-label={`${p.label} for ${d}`}
                          />
                        </td>
                      );
                    })}
                  </tr>,
                ];
              })}
            </tbody>
          </table>
        </div>
      </div>

      <div className="card" style={{ marginTop: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--blue)' }}></i> Recent permission changes
        </div>
        {history.length === 0 ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>No changes yet. The defaults are in place.</div>
        ) : (
          <table className="tbl">
            <thead><tr><th>When</th><th>Change</th><th>By</th></tr></thead>
            <tbody>
              {history.map((h) => {
                const [designation, perm] = (h.entity_ref || '').split(':');
                const label = BILLING_PERMISSIONS.find((p) => p.key === perm)?.label || perm;
                return (
                  <tr key={h.id}>
                    <td style={{ fontSize: 12 }}>
                      {new Date(h.changed_at).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}
                    </td>
                    <td style={{ fontSize: 12 }}>
                      <span className={`badge ${h.action === 'permission_granted' ? 'b-green' : 'b-gray'}`}>{ACTION_LABEL[h.action] || h.action}</span>{' '}
                      {label} — <strong>{designation}</strong>
                    </td>
                    <td style={{ fontSize: 12 }}>{h.changed_by_name}</td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </div>
    </div>
  );
}
