'use client';

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  findOpticalSaleByNumber,
  searchOpticalCustomers,
  getOpticalSalesForCustomer,
  getOpticalSaleDetail,
  getApprovers,
  createOpticalCreditNote,
  getOpticalCreditNoteRegister,
} from '../actions';

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDateTime(iso) {
  return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' });
}

export default function OpticalCreditNoteTab() {
  const searchParams = useSearchParams();
  const initialSaleId = searchParams.get('saleId');

  const [mode, setMode] = useState('number');
  const [billQuery, setBillQuery] = useState('');
  const [customerQuery, setCustomerQuery] = useState('');
  const [customerResults, setCustomerResults] = useState([]);
  const [saleResults, setSaleResults] = useState([]);
  const [detail, setDetail] = useState(null);

  const [approvers, setApprovers] = useState([]);
  const [amount, setAmount] = useState('');
  const [reason, setReason] = useState('');
  const [approvedBy, setApprovedBy] = useState('');
  const [remarks, setRemarks] = useState('');

  const [register, setRegister] = useState([]);
  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  useEffect(() => {
    getApprovers().then(setApprovers);
    refreshRegister();
    if (initialSaleId) loadSale(initialSaleId);
  }, [initialSaleId]);

  async function refreshRegister() {
    try {
      setRegister(await getOpticalCreditNoteRegister());
    } catch (e) {
      // Non-critical background refresh -- leave the existing list showing.
    }
  }

  async function loadSale(saleId) {
    setError('');
    try {
      const result = await getOpticalSaleDetail(saleId);
      if (result.error) { setError(result.error); return; }
      setDetail(result);
      setSaleResults([]);
      setCustomerResults([]);
      setAmount(result.sale.outstanding > 0 ? String(result.sale.outstanding) : '');
    } catch (e) {
      setError('Could not load this bill -- check your connection and try again.');
    }
  }

  async function handleBillSearch() {
    setError('');
    try {
      const result = await findOpticalSaleByNumber(billQuery);
      if (result.error) { setError(result.error); return; }
      setSaleResults(result.sales);
    } catch (e) {
      setError('Could not search -- check your connection and try again.');
    }
  }

  useEffect(() => {
    const q = customerQuery.trim();
    if (q.length < 2) { setCustomerResults([]); return; }
    const t = setTimeout(async () => setCustomerResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [customerQuery]);

  async function pickCustomer(c) {
    setError('');
    try {
      const result = await getOpticalSalesForCustomer({ patientId: c.type === 'patient' ? c.id : null, opticalCustomerId: c.type === 'optical_customer' ? c.id : null });
      setSaleResults(result.sales || []);
      setCustomerResults([]);
      setCustomerQuery('');
    } catch (e) {
      setError('Could not load bills for this customer -- check your connection and try again.');
    }
  }

  async function handleSubmit() {
    setError('');
    setSuccessMsg('');
    setSaving(true);
    try {
      const result = await createOpticalCreditNote({ saleId: detail.sale.id, amount, reason, approvedBy, remarks });
      if (result.error) { setError(result.error); return; }
      setSuccessMsg(`Credit note ${result.creditNote.credit_note_number} issued.`);
      setReason('');
      setRemarks('');
      setApprovedBy('');
      loadSale(detail.sale.id);
      refreshRegister();
    } catch (e) {
      setError('Something went wrong issuing the credit note -- check your connection and try again.');
    } finally {
      setSaving(false);
    }
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: detail ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      {detail && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-file-minus" style={{ color: 'var(--purple)' }}></i> {detail.sale.sale_number}</div>
          <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 10 }}>{detail.sale.displayName} -- {detail.sale.displayMobile || 'no mobile'}</div>

          {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}
          {error && <div className="msg-err">{error}</div>}

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>Bill Total</span><span>{fmt(detail.sale.net)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', marginBottom: 10, fontSize: 14, fontWeight: 700 }}>
            <span>Outstanding</span><span style={{ color: detail.sale.outstanding > 0 ? 'var(--red)' : 'var(--green)' }}>{fmt(detail.sale.outstanding)}</span>
          </div>

          {detail.sale.outstanding <= 0 ? (
            <div style={{ fontSize: 12.5, color: 'var(--g400)' }}>Nothing outstanding on this bill -- there's no balance left to write off.</div>
          ) : (
            <>
              <label className="flbl">Credit Amount</label>
              <input className="fi" type="number" min="0" max={detail.sale.outstanding} value={amount} onChange={(e) => setAmount(e.target.value)} />
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4, marginBottom: 10 }}>Up to the outstanding balance -- no cash moves, this only reduces what's owed.</div>

              <label className="flbl">Reason</label>
              <input className="fi" value={reason} onChange={(e) => setReason(e.target.value)} placeholder="Why is this being written off?" />

              <label className="flbl" style={{ marginTop: 10 }}>Approved By</label>
              <select className="fi" value={approvedBy} onChange={(e) => setApprovedBy(e.target.value)}>
                <option value="">Select approver...</option>
                {approvers.map((a) => <option key={a.id} value={a.id}>{a.full_name}{a.designation ? ` (${a.designation})` : ''}</option>)}
              </select>

              <label className="flbl" style={{ marginTop: 10 }}>Remarks (optional)</label>
              <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Any additional notes" />

              <button className="btn btn-primary" style={{ marginTop: 14 }} disabled={saving} onClick={handleSubmit}>
                <i className="ti ti-file-minus"></i> {saving ? 'Issuing...' : 'Issue Credit Note'}
              </button>
            </>
          )}
        </div>
      )}

      <div>
        <div className="card" style={{ marginBottom: 20 }}>
          <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Find Bill</div>
          {!detail && error && <div className="msg-err">{error}</div>}
          <div style={{ display: 'flex', gap: 6, marginBottom: 10 }}>
            <button className={mode === 'number' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode('number')}>By Bill Number</button>
            <button className={mode === 'customer' ? 'btn btn-sm btn-primary' : 'btn btn-sm'} onClick={() => setMode('customer')}>By Customer</button>
          </div>
          {mode === 'number' ? (
            <div style={{ display: 'flex', gap: 8 }}>
              <input className="fi" value={billQuery} onChange={(e) => setBillQuery(e.target.value)} placeholder="OPT26-000001" />
              <button className="btn btn-primary" onClick={handleBillSearch}><i className="ti ti-search"></i></button>
            </div>
          ) : (
            <div>
              <input className="fi" value={customerQuery} onChange={(e) => setCustomerQuery(e.target.value)} placeholder="Search patient or optical customer..." />
              {customerResults.length > 0 && (
                <div style={{ border: '1px solid var(--g200)', borderRadius: 8, marginTop: 8 }}>
                  {customerResults.map((c) => (
                    <div key={`${c.type}-${c.id}`} onClick={() => pickCustomer(c)} style={{ padding: '8px 12px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
                      <strong>{c.name}</strong> -- {c.type === 'patient' ? c.uhid : 'Optical Customer'} -- {c.mobile || 'no mobile'}
                    </div>
                  ))}
                </div>
              )}
            </div>
          )}
          {saleResults.length > 0 && (
            <div style={{ marginTop: 12 }}>
              {saleResults.map((s) => (
                <div key={s.id} onClick={() => loadSale(s.id)} style={{ padding: '8px 12px', cursor: 'pointer', border: '1px solid var(--g200)', borderRadius: 8, marginBottom: 6, fontSize: 12.5, display: 'flex', justifyContent: 'space-between' }}>
                  <span><strong>{s.sale_number}</strong> -- {s.displayName}</span>
                  <span>{s.status} -- Due {fmt(s.outstanding)}</span>
                </div>
              ))}
            </div>
          )}
        </div>

        <div className="card">
          <div className="card-title" style={{ marginBottom: 8 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> Recent Credit Notes</div>
          {register.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>No credit notes issued yet.</div>
          ) : (
            register.map((cn) => (
              <div key={cn.id} style={{ padding: '8px 4px', borderBottom: '1px solid var(--g100)', fontSize: 12.5 }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{cn.credit_note_number}</strong><span>{fmt(cn.amount)}</span>
                </div>
                <div style={{ color: 'var(--g500)' }}>{cn.customerName} -- {cn.optical_sales?.sale_number} -- {fmtDateTime(cn.created_at)}</div>
                <div style={{ color: 'var(--g400)', fontSize: 11 }}>{cn.reason}</div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
