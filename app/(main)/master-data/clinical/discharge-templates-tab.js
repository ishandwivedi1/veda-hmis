'use client';

// Clinical Masters > Discharge Templates
// The quick-pick buttons above "Discharge Instructions" in Recovery &
// Discharge. Clicking one there fills its text into the instructions box,
// which staff can still edit before saving. Editing a template here never
// changes instructions already saved on a past discharge.
//
// Requests: opening this tab = ONE request (getDischargeTemplates).
// Every click = ONE request (saveDischargeTemplate), which returns the
// refreshed list itself -- no follow-up reload.

import { useState, useEffect } from 'react';
import { saveDischargeTemplate } from '../actions';
import { getDischargeTemplates } from '@/lib/rpc-reads/master-data__actions'; // parallel reads (tools/parallel-reads)

export default function DischargeTemplatesTab() {
  const [rows, setRows] = useState([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState('');
  const [showAdd, setShowAdd] = useState(false);
  const [newLabel, setNewLabel] = useState('');
  const [newBody, setNewBody] = useState('');
  const [editingId, setEditingId] = useState(null);
  const [editLabel, setEditLabel] = useState('');
  const [editBody, setEditBody] = useState('');

  useEffect(() => {
    let alive = true;
    getDischargeTemplates()
      .then((data) => { if (alive) setRows(data || []); })
      .catch((e) => { if (alive) setError(e.message); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, []);

  // One click -> one request. Buttons are disabled while busy so a slow
  // connection can't fire the same change twice.
  async function run(action, id, label, body) {
    if (busy) return null;
    setBusy(true); setError('');
    try {
      const result = await saveDischargeTemplate(action, id, label, body);
      if (result?.error) { setError(result.error); return result; }
      setRows(result.rows);
      return result;
    } catch (e) {
      setError(e.message || 'Could not save -- check your connection and try again.');
      return { error: true };
    } finally {
      setBusy(false);
    }
  }

  async function handleAdd() {
    if (!newLabel.trim()) { setError('Type the button label first.'); return; }
    if (!newBody.trim()) { setError('Type the template text first.'); return; }
    const result = await run('add', null, newLabel, newBody);
    if (result && !result.error) { setNewLabel(''); setNewBody(''); setShowAdd(false); }
  }
  async function handleSaveEdit(row) {
    const result = await run('edit', row.id, editLabel, editBody);
    if (result && !result.error) setEditingId(null);
  }
  async function handleDelete(row) {
    if (!confirm(`Delete the template "${row.label}"?\n\nDischarges already saved keep their instructions. To hide it without deleting, set it to Inactive instead.`)) return;
    await run('delete', row.id);
  }

  return (
    <>
      <div className="msg-info" style={{ background: 'var(--purple-lt)', color: 'var(--purple)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
        <i className="ti ti-info-circle"></i> The quick-pick buttons above <strong>Discharge Instructions</strong> in Recovery &amp; Discharge. Clicking a button there fills in its text, which staff can still edit before saving. Only <strong>Active</strong> templates are shown, in the order below. Editing a template doesn&apos;t change instructions already saved on a past discharge.
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div style={{ marginBottom: 12 }}>
        {!showAdd ? (
          <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={() => { setShowAdd(true); setEditingId(null); setError(''); }}>
            <i className="ti ti-plus"></i> Add Template
          </button>
        ) : (
          <div style={{ border: '1.5px solid var(--blue-lt)', borderRadius: 8, padding: 12 }}>
            <input className="fi" placeholder="Button label (e.g. Retina surgery template)" value={newLabel} onChange={(e) => setNewLabel(e.target.value)} style={{ marginBottom: 8 }} />
            <textarea className="fi" rows={6} placeholder="Full discharge instruction text to fill in..." value={newBody} onChange={(e) => setNewBody(e.target.value)} />
            <div style={{ display: 'flex', gap: 6, marginTop: 10 }}>
              <button type="button" className="btn btn-primary btn-sm" disabled={busy} onClick={handleAdd}>{busy ? 'Saving...' : 'Save'}</button>
              <button type="button" className="btn btn-sm" disabled={busy} onClick={() => { setShowAdd(false); setNewLabel(''); setNewBody(''); setError(''); }}>Cancel</button>
            </div>
          </div>
        )}
      </div>

      <table className="tbl">
        <thead><tr><th style={{ width: 70 }}>Order</th><th>Code</th><th style={{ width: 200 }}>Button Label</th><th>Template Text</th><th>Status</th><th></th></tr></thead>
        <tbody>
          {loading && <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>Loading...</td></tr>}
          {!loading && rows.map((row, i) => (
            editingId === row.id ? (
              <tr key={row.id} style={{ background: 'var(--g50)' }}>
                <td></td>
                <td style={{ fontFamily: 'monospace' }}>{row.code}</td>
                <td><input className="fi fi-sm" value={editLabel} autoFocus onChange={(e) => setEditLabel(e.target.value)} /></td>
                <td><textarea className="fi fi-sm" rows={6} value={editBody} onChange={(e) => setEditBody(e.target.value)} style={{ width: '100%' }} /></td>
                <td><span className={`badge ${row.status === 'Active' ? 'b-green' : 'b-gray'}`}>{row.status}</span></td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <button type="button" className="btn btn-sm btn-primary" disabled={busy} onClick={() => handleSaveEdit(row)}>{busy ? 'Saving...' : 'Save'}</button>
                    <button type="button" className="btn btn-sm" disabled={busy} onClick={() => { setEditingId(null); setError(''); }}>Cancel</button>
                  </div>
                </td>
              </tr>
            ) : (
              <tr key={row.id} style={row.status !== 'Active' ? { opacity: 0.55 } : undefined}>
                <td>
                  <div style={{ display: 'flex', gap: 2 }}>
                    <button type="button" className="btn btn-sm" title="Move up" disabled={busy || i === 0} onClick={() => run('up', row.id)}><i className="ti ti-arrow-up"></i></button>
                    <button type="button" className="btn btn-sm" title="Move down" disabled={busy || i === rows.length - 1} onClick={() => run('down', row.id)}><i className="ti ti-arrow-down"></i></button>
                  </div>
                </td>
                <td style={{ fontFamily: 'monospace' }}>{row.code}</td>
                <td style={{ fontWeight: 600 }}>{row.label}</td>
                <td style={{ fontSize: 12, color: 'var(--g600)', whiteSpace: 'pre-line', maxWidth: 460 }}>{row.body}</td>
                <td>
                  <button type="button" className={`badge ${row.status === 'Active' ? 'b-green' : 'b-gray'}`} style={{ border: 'none', cursor: 'pointer' }} disabled={busy} onClick={() => run('toggle', row.id)}>
                    {row.status}
                  </button>
                </td>
                <td>
                  <div style={{ display: 'flex', gap: 4 }}>
                    <button type="button" className="btn btn-sm" title="Edit" disabled={busy} onClick={() => { setEditingId(row.id); setEditLabel(row.label); setEditBody(row.body); setShowAdd(false); setError(''); }}><i className="ti ti-edit"></i></button>
                    <button type="button" className="btn btn-sm" title="Delete" disabled={busy} onClick={() => handleDelete(row)}><i className="ti ti-trash" style={{ color: 'var(--red)' }}></i></button>
                  </div>
                </td>
              </tr>
            )
          ))}
          {!loading && rows.length === 0 && (
            <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No discharge templates yet -- add one above.</td></tr>
          )}
        </tbody>
      </table>
    </>
  );
}
