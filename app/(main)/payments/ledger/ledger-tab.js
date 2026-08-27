'use client';

import { useState, useEffect } from 'react';
import { formatPatientName } from '@/lib/patientName';
import { searchPatientsForPayment, getPatientUnifiedLedger, getAdvanceBalance, getOutstandingInvoices, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const TYPE_COLOR = {
  Invoice: 'var(--red)', Payment: 'var(--green)', Advance: 'var(--purple)',
  'Advance Adjustment': 'var(--blue)', Refund: 'var(--amber)', 'Credit Note': 'var(--teal)',
};

function fmt(n) {
  return Number(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
}

export default function LedgerTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [entries, setEntries] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [outstandingInvoices, setOutstandingInvoices] = useState([]);
  const [typeFilter, setTypeFilter] = useState('');
  const [visitFilter, setVisitFilter] = useState('');
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => { getTodaysVisits().then(setTodaysVisits); }, []);

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  // Live search as the user types -- no need to press the Search button.
  useEffect(() => {
    const q = searchQuery.trim();
    if (q.length < 2) { setSearchResults([]); return; }
    const t = setTimeout(async () => {
      setSearchResults(await searchPatientsForPayment(q));
    }, 300);
    return () => clearTimeout(t);
  }, [searchQuery]);

  async function pickPatient(p) {
    setLoading(true);
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate('');
    const [ledgerEntries, balance, outstanding] = await Promise.all([
      getPatientUnifiedLedger(p.id), getAdvanceBalance(p.id), getOutstandingInvoices(p.id),
    ]);
    setEntries(ledgerEntries);
    setAdvanceBalance(balance);
    setOutstandingInvoices(outstanding);
    setLoading(false);
  }

  function changePatient() {
    setPatient(null);
    setEntries([]);
  }

  const visits = [...new Set(entries.map((e) => e.visit).filter((v) => v && v !== '--'))];
  const filtered = entries.filter((e) => {
    if (typeFilter && e.type !== typeFilter) return false;
    if (visitFilter && e.visit !== visitFilter) return false;
    if (fromDate && new Date(e.date) < new Date(fromDate)) return false;
    if (toDate && new Date(e.date) > new Date(`${toDate}T23:59:59`)) return false;
    return true;
  });

  const totalInvoiced = entries.filter((e) => e.type === 'Invoice').reduce((s, e) => s + e.debit, 0);
  const totalCollected = entries.filter((e) => e.type !== 'Invoice').reduce((s, e) => s + e.credit - e.debit, 0);
  const currentBalance = entries.length > 0 ? entries[0].balance : 0;

  return (
    <div>
      <div className="card" style={{ marginBottom: 16 }}>
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-wallet" style={{ color: 'var(--purple)' }}></i> Patient Ledger
        </div>
        <div className="msg-info" style={{ background: 'var(--blue-lt)', color: 'var(--blue)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Spans all visits for this patient. Outstanding balance is calculated dynamically from every entry below -- Balance {'>'} 0 means the patient owes the hospital; Balance {'<'} 0 means the hospital owes the patient (unused advance).
        </div>

        {!patient ? (
          <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 20 }}>
            <div>
              <label className="flbl">Search patient (name, UHID, or mobile)</label>
              <div style={{ display: 'flex', gap: 8 }}>
                <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Type to search..." />
                <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i> Search</button>
              </div>
              {searchResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                  {searchResults.map((p) => (
                    <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{formatPatientName(p)}</strong> -- {p.uhid}
                    </div>
                  ))}
                </div>
              )}
            </div>
            <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
          </div>
        ) : (
          <div>
            <div style={{ background: 'linear-gradient(135deg,#4c1d95,#6d28a8)', borderRadius: 12, padding: '14px 18px', color: '#fff', marginBottom: 16 }}>
              <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start' }}>
                <div>
                  <div style={{ fontSize: 16, fontWeight: 700 }}>{formatPatientName(patient)}</div>
                  <div style={{ fontSize: 12, opacity: .8, marginTop: 2 }}>{patient.uhid}</div>
                </div>
                <button className="btn btn-sm" onClick={changePatient} style={{ background: 'rgba(255,255,255,.15)', color: '#fff', border: '1px solid rgba(255,255,255,.3)' }}>
                  <i className="ti ti-arrow-left"></i> Change patient
                </button>
              </div>
              <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 10, marginTop: 14 }}>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Invoiced</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3 }}>Rs.{fmt(totalInvoiced)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Total Collected</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#86efac' }}>Rs.{fmt(totalCollected)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Advance Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: '#c4b5fd' }}>Rs.{fmt(advanceBalance)}</div>
                </div>
                <div style={{ background: 'rgba(255,255,255,.12)', borderRadius: 8, padding: '8px 10px', border: '1px solid rgba(255,255,255,.2)' }}>
                  <div style={{ fontSize: 10, opacity: .75, textTransform: 'uppercase' }}>Current Balance</div>
                  <div style={{ fontSize: 15, fontWeight: 700, marginTop: 3, color: currentBalance > 0 ? '#fca5a5' : '#86efac' }}>Rs.{fmt(currentBalance)}</div>
                </div>
              </div>
            </div>

            {loading ? (
              <div style={{ textAlign: 'center', padding: 30, color: 'var(--g400)' }}>Loading ledger...</div>
            ) : (
              <>
                <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
                  <select className="fi" style={{ width: 'auto' }} value={typeFilter} onChange={(e) => setTypeFilter(e.target.value)}>
                    <option value="">All types</option>
                    {Object.keys(TYPE_COLOR).map((t) => <option key={t} value={t}>{t}</option>)}
                  </select>
                  <select className="fi" style={{ width: 'auto' }} value={visitFilter} onChange={(e) => setVisitFilter(e.target.value)}>
                    <option value="">All visits</option>
                    {visits.map((v) => <option key={v} value={v}>{v}</option>)}
                  </select>
                  <input type="date" className="fi" style={{ width: 'auto' }} value={fromDate} onChange={(e) => setFromDate(e.target.value)} />
                  <input type="date" className="fi" style={{ width: 'auto' }} value={toDate} onChange={(e) => setToDate(e.target.value)} />
                  {(typeFilter || visitFilter || fromDate || toDate) && (
                    <button className="btn btn-sm" onClick={() => { setTypeFilter(''); setVisitFilter(''); setFromDate(''); setToDate(''); }}>
                      <i className="ti ti-x"></i> Clear
                    </button>
                  )}
                </div>

                <div className="card" style={{ padding: 0, overflow: 'hidden', marginBottom: 12 }}>
                  <table className="tbl">
                    <thead>
                      <tr><th>Date/Time</th><th>Type</th><th>Reference</th><th>Visit</th><th>Description</th><th style={{ textAlign: 'right' }}>Debit</th><th style={{ textAlign: 'right' }}>Credit</th><th style={{ textAlign: 'right' }}>Balance</th></tr>
                    </thead>
                    <tbody>
                      {filtered.map((e, i) => (
                        <tr key={i} style={{ borderLeft: `3px solid ${TYPE_COLOR[e.type]}` }}>
                          <td style={{ fontSize: 11, whiteSpace: 'nowrap' }}>{new Date(e.date).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' })}</td>
                          <td>
                            <span style={{ display: 'inline-flex', alignItems: 'center', gap: 5, fontSize: 12, fontWeight: 600 }}>
                              <span style={{ width: 7, height: 7, borderRadius: '50%', background: TYPE_COLOR[e.type], flexShrink: 0 }}></span>
                              {e.type}
                            </span>
                          </td>
                          <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{e.ref}</td>
                          <td style={{ fontSize: 11 }}>{e.visit}</td>
                          <td style={{ fontSize: 12 }}>{e.desc}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.debit > 0 ? <span style={{ color: 'var(--red)', fontWeight: 600 }}>{fmt(e.debit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontSize: 12 }}>{e.credit > 0 ? <span style={{ color: 'var(--green)', fontWeight: 600 }}>{fmt(e.credit)}</span> : '--'}</td>
                          <td style={{ textAlign: 'right', fontWeight: 700, color: e.balance > 0 ? 'var(--red)' : e.balance < 0 ? 'var(--purple)' : 'var(--green)' }}>{fmt(e.balance)}</td>
                        </tr>
                      ))}
                      {filtered.length === 0 && (
                        <tr><td colSpan={8} style={{ padding: 20, textAlign: 'center', color: 'var(--g400)' }}>No entries match these filters.</td></tr>
                      )}
                    </tbody>
                  </table>
                </div>

                <div className="card" style={{ padding: '10px 14px' }}>
                  <div style={{ display: 'flex', gap: 16, flexWrap: 'wrap', fontSize: 12, color: 'var(--g600)' }}>
                    {Object.entries(TYPE_COLOR).map(([type, color]) => (
                      <span key={type}><span style={{ display: 'inline-block', width: 8, height: 8, borderRadius: '50%', background: color, marginRight: 4 }}></span>{type}</span>
                    ))}
                  </div>
                </div>
              </>
            )}
          </div>
        )}
      </div>
    </div>
  );
}


