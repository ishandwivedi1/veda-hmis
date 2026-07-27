'use client';

import { useState, useEffect, useCallback } from 'react';
import { getCurrentBalancesByPatient, getAdvanceBalance, getOutstandingInvoices, getPatientLedgerAudit, applyAdjustment, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

export default function AdjustmentsTab() {
  const [patientsWithBalance, setPatientsWithBalance] = useState([]);
  const [selected, setSelected] = useState(null);
  const [balance, setBalance] = useState(0);
  const [invoices, setInvoices] = useState([]);
  const [audit, setAudit] = useState([]);
  const [todaysVisits, setTodaysVisits] = useState([]);

  const [amount, setAmount] = useState('');
  const [invoiceId, setInvoiceId] = useState('');
  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);

  const refresh = useCallback(async () => {
    setPatientsWithBalance(await getCurrentBalancesByPatient());
  }, []);

  useEffect(() => { refresh(); }, [refresh]);
  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function loadPatientData(patient) {
    setBalance(await getAdvanceBalance(patient.id));
    setInvoices(await getOutstandingInvoices(patient.id));
    setAudit(await getPatientLedgerAudit(patient.id));
  }

  async function selectPatient(patient) {
    setError(''); setSuccess('');
    setSelected(patient);
    await loadPatientData(patient);
    setAmount('');
    setInvoiceId('');
  }

  async function pickPatient(entry) {
    await selectPatient(entry.patient);
  }

  async function handleRefresh() {
    if (!selected) return;
    setError(''); setSuccess('');
    await loadPatientData(selected);
    refresh();
  }

  async function handleApply() {
    setError(''); setSuccess('');
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid adjustment amount.'); return; }
    if (!invoiceId) { setError('Select an invoice to adjust against.'); return; }

    setLoading(true);
    const result = await applyAdjustment(selected.id, invoiceId, amt);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Rs.${amt} adjusted against invoice successfully.`);
    setAmount('');
    setInvoiceId('');
    await loadPatientData(selected);
    refresh();
  }

  return (
    <div className="card">
      <div className="card-title" style={{ marginBottom: 4 }}>
        <i className="ti ti-arrows-exchange" style={{ color: 'var(--blue)' }}></i> Advance Adjustment
      </div>
      <div className="msg-info">
        <i className="ti ti-info-circle"></i> Adjusting an advance never edits or deletes the original collection entry -- it creates a new, linked adjustment entry instead, so the full history stays intact and auditable.
      </div>

      <div style={{ display: 'grid', gridTemplateColumns: '1fr 1.4fr', gap: 20 }}>
        <div>
          <TodaysVisitsWidget visits={todaysVisits} onSelect={selectPatient} />

          <label className="flbl" style={{ marginBottom: 8 }}>Patients with advance balance</label>
          {patientsWithBalance.map((entry, i) => (
            <div
              key={i}
              onClick={() => pickPatient(entry)}
              style={{
                padding: '10px 12px', cursor: 'pointer', borderRadius: 8, marginBottom: 6, fontSize: 13,
                background: selected?.id === entry.patient.id ? 'var(--purple-lt)' : 'var(--g50)',
                border: selected?.id === entry.patient.id ? '1.5px solid var(--purple)' : '1px solid var(--g200)',
              }}
            >
              <div style={{ fontWeight: 600 }}>{entry.patient.first_name} {entry.patient.last_name}</div>
              <div style={{ color: 'var(--purple)', fontWeight: 700 }}>Rs.{entry.balance.toFixed(2)}</div>
            </div>
          ))}
          {patientsWithBalance.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)' }}>No patients currently hold an advance balance.</div>}
        </div>

        {selected && (
          <div>
            <div style={{ background: 'var(--purple-lt)', border: '1px solid var(--purple)', borderRadius: 8, padding: 12, marginBottom: 12 }}>
              <div style={{ fontWeight: 700, fontSize: 14 }}>{selected.first_name} {selected.last_name}</div>
              <div style={{ fontSize: 13, marginTop: 4 }}>Advance available: <strong style={{ color: 'var(--purple)', fontSize: 16 }}>Rs.{balance}</strong></div>
            </div>

            {error && <div className="msg-err">{error}</div>}
            {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: 8 }}>
              <label className="flbl" style={{ marginBottom: 0 }}>Outstanding invoices</label>
              <button className="btn btn-sm" onClick={handleRefresh}><i className="ti ti-refresh"></i> Refresh</button>
            </div>
            <table className="tbl" style={{ marginBottom: 12 }}>
              <thead><tr><th>Invoice</th><th>Outstanding</th></tr></thead>
              <tbody>
                {invoices.map((inv) => (
                  <tr key={inv.id}><td style={{ fontFamily: 'monospace' }}>{inv.invoice_number}</td><td>Rs.{(inv.net - inv.paid).toFixed(2)}</td></tr>
                ))}
                {invoices.length === 0 && <tr><td colSpan={2} style={{ padding: 10, textAlign: 'center', color: 'var(--g400)' }}>No outstanding invoices.</td></tr>}
              </tbody>
            </table>

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Adjust amount (Rs.)</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder="0.00" />
              </div>
              <div>
                <label className="flbl">Against invoice</label>
                <select className="fi" value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
                  <option value="">-- Select --</option>
                  {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)}</option>)}
                </select>
              </div>
            </div>

            <button className="btn btn-primary" onClick={handleApply} disabled={loading || invoices.length === 0}>
              <i className="ti ti-arrows-exchange"></i> {loading ? 'Applying...' : 'Apply adjustment'}
            </button>

            <div style={{ marginTop: 16 }}>
              <label className="flbl" style={{ marginBottom: 8 }}>Audit trail -- this patient</label>
              {audit.map((a) => (
                <div key={a.id} style={{ fontSize: 11, color: 'var(--g500)', padding: '4px 0', borderBottom: '1px solid var(--g100)' }}>
                  {new Date(a.recorded_at).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata' })} -- {a.entry_type} -- Rs.{Math.abs(a.amount).toFixed(2)}
                </div>
              ))}
            </div>
          </div>
        )}
      </div>
    </div>
  );
}


