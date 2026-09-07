'use client';

import { useState, useEffect } from 'react';
import {
  searchOpticalCustomers,
  createWalkInOpticalCustomer,
  getOpticalAdvanceBalance,
  collectOpticalAdvance,
  getRecentOpticalAdvances,
} from '../actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function OpticalAdvanceTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [selected, setSelected] = useState(null);
  const [useNewWalkIn, setUseNewWalkIn] = useState(false);
  const [newName, setNewName] = useState('');
  const [newMobile, setNewMobile] = useState('');

  const [balance, setBalance] = useState(0);
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');
  const [recentAdvances, setRecentAdvances] = useState([]);

  useEffect(() => { refreshRecentAdvances(); }, []);

  async function refreshRecentAdvances() {
    const result = await getRecentOpticalAdvances();
    setRecentAdvances(result.advances || []);
  }

  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => setSearchResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pick(r) {
    setSelected(r);
    setSearchResults([]);
    setSearchQuery('');
    setUseNewWalkIn(false);
    const bal = await getOpticalAdvanceBalance({ patientId: r.type === 'patient' ? r.id : null, opticalCustomerId: r.type === 'optical_customer' ? r.id : null });
    setBalance(bal);
  }

  function clearCustomer() {
    setSelected(null);
    setUseNewWalkIn(false);
    setNewName('');
    setNewMobile('');
    setBalance(0);
  }

  async function handleCreateWalkIn() {
    setError('');
    const result = await createWalkInOpticalCustomer(newName, newMobile);
    if (result.error) { setError(result.error); return; }
    pick({ type: 'optical_customer', id: result.customer.id, name: result.customer.name, mobile: result.customer.mobile });
  }

  function updateModeAmount(m, val) { setModeAmounts((prev) => ({ ...prev, [m]: val })); }
  function toggleMode(m) {
    setModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m]; else next[m] = '';
      return next;
    });
  }
  const modesTotal = Object.values(modeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  async function handleCollect() {
    setError('');
    setSuccessMsg('');
    setSaving(true);
    const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
    const result = await collectOpticalAdvance({
      patientId: selected?.type === 'patient' ? selected.id : null,
      opticalCustomerId: selected?.type === 'optical_customer' ? selected.id : null,
      amount: modesTotal, modes, reference, remarks,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Advance recorded -- receipt ${result.payment.receipt_number}`);
    const bal = await getOpticalAdvanceBalance({ patientId: selected?.type === 'patient' ? selected.id : null, opticalCustomerId: selected?.type === 'optical_customer' ? selected.id : null });
    setBalance(bal);
    setModeAmounts({ Cash: '' });
    setReference('');
    setRemarks('');
    refreshRecentAdvances();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-piggy-bank" style={{ color: 'var(--blue)' }}></i> Collect Advance</div>
        {error && <div className="msg-err">{error}</div>}
        {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

        <label className="flbl">Customer</label>
        {!selected && !useNewWalkIn && (
          <div>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Search patient or existing optical customer..." />
              <button className="btn" onClick={() => setUseNewWalkIn(true)}><i className="ti ti-user-plus"></i> New Walk-in</button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((r) => (
                  <div key={`${r.type}-${r.id}`} onClick={() => pick(r)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{r.name}</strong> -- {r.type === 'patient' ? r.uhid : 'Optical Customer'} -- {r.mobile || 'no mobile'}
                  </div>
                ))}
              </div>
            )}
          </div>
        )}
        {selected && (
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', padding: '8px 12px', border: '1px solid var(--g200)', borderRadius: 8 }}>
            <span><strong>{selected.name}</strong> -- {selected.type === 'patient' ? selected.uhid : 'Optical Customer'} -- {selected.mobile || 'no mobile'} -- Current balance: <strong>{fmt(balance)}</strong></span>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i> Change</button>
          </div>
        )}
        {useNewWalkIn && !selected && (
          <div style={{ display: 'flex', gap: 8, alignItems: 'flex-end' }}>
            <div style={{ flex: 1 }}>
              <label className="flbl">Name</label>
              <input className="fi" value={newName} onChange={(e) => setNewName(e.target.value)} placeholder="Customer name" />
            </div>
            <div style={{ flex: 1 }}>
              <label className="flbl">Mobile</label>
              <input className="fi" value={newMobile} onChange={(e) => setNewMobile(e.target.value)} placeholder="10-digit mobile (recommended)" />
            </div>
            <button className="btn btn-sm btn-primary" onClick={handleCreateWalkIn}>Add</button>
            <button className="btn btn-sm" onClick={clearCustomer}><i className="ti ti-x"></i></button>
          </div>
        )}

        {selected && (
          <>
            <label className="flbl" style={{ marginTop: 16 }}>Payment Mode(s)</label>
            <div style={{ display: 'flex', gap: 6, flexWrap: 'wrap', marginBottom: 8 }}>
              {PAYMENT_MODES.map((m) => (
                <button key={m} className={m in modeAmounts ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => toggleMode(m)}>{m}</button>
              ))}
            </div>
            {Object.keys(modeAmounts).map((m) => (
              <div key={m} style={{ display: 'flex', gap: 8, alignItems: 'center', marginBottom: 6 }}>
                <span style={{ width: 100, fontSize: 12.5 }}>{m}</span>
                <input className="fi" type="number" value={modeAmounts[m]} onChange={(e) => updateModeAmount(m, e.target.value)} />
              </div>
            ))}

            <label className="flbl" style={{ marginTop: 10 }}>Amount</label>
            <input className="fi" type="number" value={modesTotal} disabled style={{ background: 'var(--g50, #f7f8fa)', color: 'var(--g600)', fontWeight: 700 }} />
            <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4, marginBottom: 10 }}>Auto-calculated from the payment mode(s) above.</div>

            <div style={{ display: 'flex', gap: 12, marginBottom: 10 }}>
              <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" />
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="What's this advance for? (optional)" />
            </div>

            <button className="btn btn-primary" disabled={saving || modesTotal <= 0} onClick={handleCollect}>
              <i className="ti ti-piggy-bank"></i> {saving ? 'Recording...' : 'Collect Advance'}
            </button>
          </>
        )}
      </div>

      <div>
        <div className="card" style={{ marginBottom: 20 }}>
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-info-circle"></i> How this works</div>
          <ul style={{ fontSize: 12.5, color: 'var(--g500)', paddingLeft: 18, lineHeight: 1.7 }}>
            <li>Use this when a customer pays before a bill exists yet -- e.g. a booking advance for made-to-order lenses.</li>
            <li>The balance is held against this customer and can be applied to any of their bills later, from the Collect Payment tab.</li>
            <li>A walk-in with a mobile number is matched automatically on future visits -- adding one is strongly recommended so the balance can be found again.</li>
          </ul>
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> Advances Collected</div>
          {recentAdvances.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No advances collected yet.</div>
          ) : (
            recentAdvances.map((a) => (
              <div key={a.id} onClick={() => pick(a.customer)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{a.customer.name}</strong><span>{fmt(a.amount)}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}>
                  <span>{a.receiptNumber}</span>
                  <span>{new Date(a.collectedAt).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short' })}</span>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
