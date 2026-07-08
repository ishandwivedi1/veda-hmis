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
    <div style={{ maxWidth: 800, margin: '0 auto' }}>
      <div style={{ fontSize: 18, fontWeight: 700, marginBottom: 16 }}><i className="ti ti-pill" style={{ color: 'var(--blue)', marginRight: 6 }}></i>Pharmacy -- Pending Dispensing</div>
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

