'use client';

import { useState, useEffect } from 'react';
import { searchPatientsForPayment, getOutstandingInvoices, getApprovers, createCreditNote, getCreditNoteRegister, getTodaysVisits } from '../actions';
import TodaysVisitsWidget from '../todays-visits-widget';

const REASONS = ['Billing correction', 'Service cancellation', 'Approved financial adjustment', 'Goodwill gesture', 'Insurance adjustment', 'Other'];

export default function CreditNoteTab() {
  const [searchQuery, setSearchQuery] = useState('');
  const [searchResults, setSearchResults] = useState([]);
  const [patient, setPatient] = useState(null);
  const [invoices, setInvoices] = useState([]);
  const [approvers, setApprovers] = useState([]);
  const [register, setRegister] = useState([]);

  const [invoiceId, setInvoiceId] = useState('');
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [error, setError] = useState('');
  const [success, setSuccess] = useState('');
  const [loading, setLoading] = useState(false);
  const [todaysVisits, setTodaysVisits] = useState([]);

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    getTodaysVisits().then(setTodaysVisits);
  }, []);

  async function refreshRegister() {
    setRegister(await getCreditNoteRegister());
  }

  async function handleSearch() {
    if (!searchQuery.trim()) return;
    setSearchResults(await searchPatientsForPayment(searchQuery.trim()));
  }

  async function pickPatient(p) {
    setError(''); setSuccess('');
    setPatient(p);
    setSearchResults([]);
    setSearchQuery('');
    setInvoices(await getOutstandingInvoices(p.id));
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
  }

  function changePatient() {
    setPatient(null);
    setInvoices([]);
  }

  const selectedInvoice = invoices.find((i) => i.id === invoiceId);
  const outstandingOnSelected = selectedInvoice ? Number(selectedInvoice.net) - Number(selectedInvoice.paid) : 0;

  async function handleSubmit() {
    setError(''); setSuccess('');
    if (!invoiceId) { setError('Select an invoice to credit.'); return; }
    const amt = parseFloat(amount);
    if (!amt || amt <= 0) { setError('Enter a valid credit amount.'); return; }
    if (amt > outstandingOnSelected) { setError(`Credit amount cannot exceed this invoice's outstanding balance (Rs.${outstandingOnSelected.toFixed(2)}).`); return; }
    if (!reason) { setError('Select a reason.'); return; }
    if (!approvedBy) { setError('Select an approver.'); return; }

    setLoading(true);
    const result = await createCreditNote(patient.id, invoiceId, amt, reason, approvedBy, remarks);
    setLoading(false);

    if (result.error) { setError(result.error); return; }
    setSuccess(`Credit note ${result.creditNote.credit_note_number} created for Rs.${amt.toFixed(2)}.`);
    setInvoiceId(''); setAmount(''); setReason(''); setApprovedBy(''); setRemarks('');
    setInvoices(await getOutstandingInvoices(patient.id));
    refreshRegister();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 4 }}>
          <i className="ti ti-file-minus" style={{ color: 'var(--teal)' }}></i> Credit Note
        </div>
        <div className="msg-info" style={{ background: 'var(--teal-lt)', color: 'var(--teal)', padding: '8px 12px', borderRadius: 8, fontSize: 12, marginBottom: 12 }}>
          <i className="ti ti-info-circle"></i> Reduces what a patient owes on an invoice without reversing any payment -- for billing corrections, service cancellations, goodwill, or insurance adjustments. Different from a refund, which returns money already collected.
        </div>

        {error && <div className="msg-err">{error}</div>}
        {success && <div className="msg-success"><i className="ti ti-circle-check"></i> {success}</div>}

        {!patient ? (
          <div>
            <label className="flbl">Patient</label>
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} placeholder="Name, UHID, or mobile..." />
              <button className="btn btn-primary" onClick={handleSearch}><i className="ti ti-search"></i></button>
            </div>
            {searchResults.length > 0 && (
              <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                {searchResults.map((p) => (
                  <div key={p.id} onClick={() => pickPatient(p)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                    <strong>{p.first_name} {p.last_name}</strong> -- {p.uhid}
                  </div>
                ))}
              </div>
            )}
            <div style={{ marginTop: 16 }}>
              <TodaysVisitsWidget visits={todaysVisits} onSelect={pickPatient} />
            </div>
          </div>
        ) : (
          <div>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', background: 'var(--teal-lt)', padding: '8px 12px', borderRadius: 8, marginBottom: 14 }}>
              <span><strong>{patient.first_name} {patient.last_name}</strong> -- {patient.uhid}</span>
              <button className="btn btn-sm" onClick={changePatient}>Change</button>
            </div>

            <label className="flbl">Invoice to credit *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={invoiceId} onChange={(e) => setInvoiceId(e.target.value)}>
              <option value="">-- Select invoice --</option>
              {invoices.map((inv) => <option key={inv.id} value={inv.id}>{inv.invoice_number} -- Rs.{(inv.net - inv.paid).toFixed(2)} outstanding</option>)}
            </select>
            {invoices.length === 0 && <div style={{ fontSize: 12, color: 'var(--g400)', marginBottom: 12 }}>No outstanding invoices for this patient.</div>}

            <div style={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 10, marginBottom: 12 }}>
              <div>
                <label className="flbl">Reason *</label>
                <select className="fi" value={reason} onChange={(e) => setReason(e.target.value)}>
                  <option value="">-- Select reason --</option>
                  {REASONS.map((r) => <option key={r} value={r}>{r}</option>)}
                </select>
              </div>
              <div>
                <label className="flbl">Credit amount (Rs.) *</label>
                <input type="number" className="fi" value={amount} onChange={(e) => setAmount(e.target.value)} placeholder={selectedInvoice ? `Up to Rs.${outstandingOnSelected.toFixed(2)}` : '0.00'} />
              </div>
            </div>

            <label className="flbl">Approved by *</label>
            <select className="fi" style={{ marginBottom: 12 }} value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
              <option value="">-- Select approver --</option>
              {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` -- ${a.designation}` : ''}</option>)}
            </select>

            <label className="flbl">Remarks</label>
            <textarea className="fi" rows={2} style={{ marginBottom: 14 }} value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Supporting details for this credit note..." />

            <button className="btn" style={{ background: 'var(--teal)', color: '#fff', border: 'none' }} onClick={handleSubmit} disabled={loading || invoices.length === 0}>
              <i className="ti ti-file-minus"></i> {loading ? 'Creating...' : 'Create Credit Note'}
            </button>
          </div>
        )}
      </div>

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}>
          <i className="ti ti-history" style={{ color: 'var(--teal)' }}></i> Credit Note Register
        </div>
        <div style={{ maxHeight: 500, overflowY: 'auto' }}>
          <table className="tbl">
            <thead><tr><th>CN #</th><th>Patient</th><th>Invoice</th><th>Amount</th><th>Reason</th><th>Approved By</th></tr></thead>
            <tbody>
              {register.map((cn) => (
                <tr key={cn.id}>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.credit_note_number}</td>
                  <td style={{ fontSize: 12 }}>{cn.patients?.first_name} {cn.patients?.last_name}</td>
                  <td style={{ fontFamily: 'monospace', fontSize: 11 }}>{cn.invoices?.invoice_number || '--'}</td>
                  <td style={{ fontSize: 12, fontWeight: 600 }}>Rs.{Number(cn.amount).toFixed(2)}</td>
                  <td style={{ fontSize: 11 }}>{cn.reason}</td>
                  <td style={{ fontSize: 11 }}>{cn.profiles?.full_name || '--'}</td>
                </tr>
              ))}
              {register.length === 0 && (
                <tr><td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No credit notes issued yet.</td></tr>
              )}
            </tbody>
          </table>
        </div>
      </div>
    </div>
  );
}

