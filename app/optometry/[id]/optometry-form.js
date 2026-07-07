'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { getQueueEntryForOptometry, saveFindingsAndComplete } from '../actions';

export default function OptometryForm({ queueEntryId }) {
  const [entry, setEntry] = useState(null);
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
      } else {
        setEntry(result.entry);
      }
    });
  }, [queueEntryId]);

  async function handleSubmit(e) {
    e.preventDefault();
    setError('');
    setLoading(true);

    const result = await saveFindingsAndComplete(queueEntryId, entry.visits.id, {
      reVa, leVa, reIop, leIop, reSph, leSph, reCyl, leCyl,
    });

    setLoading(false);

    if (result.error) {
      setError(result.error);
      return;
    }

    router.push('/queue');
  }

  if (loadError) {
    return (
      <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
        <div className="msg-err">{loadError}</div>
      </div>
    );
  }

  if (!entry) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = entry.visits?.patients;

  return (
    <div style={{ maxWidth: 560, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 4 }}>
          Optometry -- {entry.token}
        </div>
        <div style={{ fontSize: 13, color: 'var(--g500)', marginBottom: 20 }}>
          {patient?.first_name} {patient?.last_name} -- {patient?.uhid} -- {patient?.age} {patient?.gender}
        </div>

        {error && <div className="msg-err">{error}</div>}

        <form onSubmit={handleSubmit}>
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

          <div style={{ display: 'flex', gap: 8 }}>
            <button type="submit" className="btn btn-primary" disabled={loading}>
              {loading ? 'Saving...' : 'Save & Complete -- Send to Doctor'}
            </button>
            <button type="button" className="btn" onClick={() => router.push('/queue')}>
              Cancel
            </button>
          </div>
        </form>
      </div>
    </div>
  );
}

