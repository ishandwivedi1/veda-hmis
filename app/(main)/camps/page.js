'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { listCampEvents, createCampEvent } from './actions';

function fmtDate(d) {
  if (!d) return '--';
  return new Date(`${d}T00:00:00`).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', year: 'numeric' });
}

function NewCampModal({ onClose, onCreated }) {
  const [name, setName] = useState('');
  const [location, setLocation] = useState('');
  const [campDate, setCampDate] = useState(new Date().toLocaleDateString('en-CA', { timeZone: 'Asia/Kolkata' }));
  const [conductedBy, setConductedBy] = useState('');
  const [notes, setNotes] = useState('');
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState('');

  async function handleSave() {
    setError('');
    setSaving(true);
    const result = await createCampEvent({ name, location, campDate, conductedBy, notes });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    onCreated(result.camp);
  }

  return (
    <div style={{ position: 'fixed', inset: 0, background: 'rgba(0,0,0,.4)', display: 'flex', alignItems: 'center', justifyContent: 'center', zIndex: 100 }}>
      <div className="card" style={{ width: 440, maxWidth: '90vw' }}>
        <div className="card-title" style={{ marginBottom: 14 }}><i className="ti ti-map-pin" style={{ color: 'var(--amber)' }}></i> New Camp</div>

        <label className="flbl">Camp / Company name<sup style={{ color: 'var(--red)' }}>*</sup></label>
        <input className="fi" style={{ marginBottom: 10 }} value={name} onChange={(e) => setName(e.target.value)} placeholder="e.g. TCS Corporate Eye Camp" />

        <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 10 }}>
          <div>
            <label className="flbl">Date<sup style={{ color: 'var(--red)' }}>*</sup></label>
            <input type="date" className="fi" value={campDate} onChange={(e) => setCampDate(e.target.value)} />
          </div>
          <div>
            <label className="flbl">Location</label>
            <input className="fi" value={location} onChange={(e) => setLocation(e.target.value)} placeholder="e.g. Haridwar" />
          </div>
        </div>

        <label className="flbl">Conducted by</label>
        <input className="fi" style={{ marginBottom: 10 }} value={conductedBy} onChange={(e) => setConductedBy(e.target.value)} placeholder="Doctor / team" />

        <label className="flbl">Notes</label>
        <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={notes} onChange={(e) => setNotes(e.target.value)} placeholder="Optional" />

        {error && <div className="msg-err" style={{ marginBottom: 10 }}>{error}</div>}

        <div style={{ display: 'flex', gap: 8, justifyContent: 'flex-end' }}>
          <button className="btn" onClick={onClose} disabled={saving}>Cancel</button>
          <button className="btn btn-primary" onClick={handleSave} disabled={saving}>
            <i className="ti ti-check"></i> {saving ? 'Creating...' : 'Create Camp'}
          </button>
        </div>
      </div>
    </div>
  );
}

export default function CampsPage() {
  const router = useRouter();
  const [camps, setCamps] = useState([]);
  const [loading, setLoading] = useState(true);
  const [showNew, setShowNew] = useState(false);
  const [error, setError] = useState('');

  const refresh = useCallback(async () => {
    const result = await listCampEvents();
    if (result.error) { setError(result.error); setLoading(false); return; }
    setCamps(result.rows);
    setLoading(false);
  }, []);

  useEffect(() => { refresh(); }, [refresh]);

  return (
    <div>
      <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 4 }}>
        <div style={{ fontSize: 20, fontWeight: 700 }}>Camps</div>
        <button className="btn btn-primary" onClick={() => setShowNew(true)}><i className="ti ti-plus"></i> New Camp</button>
      </div>
      <div style={{ fontSize: 12, color: 'var(--g500)', marginBottom: 16 }}>
        Corporate and community eye-screening camps -- fast on-site entry, kept separate from Patients until someone actually converts.
      </div>

      {error && <div className="msg-err" style={{ marginBottom: 16 }}>{error}</div>}

      {loading ? (
        <div style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>Loading...</div>
      ) : camps.length === 0 ? (
        <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
          <i className="ti ti-map-pin" style={{ fontSize: 28, marginBottom: 8, display: 'block' }}></i>
          No camps yet. Create one to start logging screenings.
        </div>
      ) : (
        <table className="tbl">
          <thead><tr><th>Camp</th><th>Date</th><th>Location</th><th>Screened</th><th>Converted</th><th></th></tr></thead>
          <tbody>
            {camps.map((c) => (
              <tr key={c.id} onClick={() => router.push(`/camps/${c.id}`)} style={{ cursor: 'pointer' }}>
                <td><strong>{c.name}</strong>{c.conducted_by && <div style={{ fontSize: 11, color: 'var(--g400)' }}>{c.conducted_by}</div>}</td>
                <td style={{ fontSize: 12 }}>{fmtDate(c.camp_date)}</td>
                <td style={{ fontSize: 12 }}>{c.location || '--'}</td>
                <td><span className="badge b-gray">{c.screenedCount}</span></td>
                <td><span className="badge b-green">{c.convertedCount}</span></td>
                <td><i className="ti ti-chevron-right" style={{ color: 'var(--g400)' }}></i></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {showNew && (
        <NewCampModal
          onClose={() => setShowNew(false)}
          onCreated={(camp) => { setShowNew(false); router.push(`/camps/${camp.id}`); }}
        />
      )}
    </div>
  );
}
