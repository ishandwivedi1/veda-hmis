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

