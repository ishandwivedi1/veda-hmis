'use client';

import { useState, useEffect } from 'react';
import { useSearchParams } from 'next/navigation';
import {
  findOpticalSaleByNumber,
  searchOpticalCustomers,
  getOpticalSalesForCustomer,
  getOpticalSaleDetail,
  getOpticalAdvanceBalance,
  collectOpticalPayment,
  applyOpticalAdvanceAdjustment,
  getOutstandingOpticalBills,
} from '../actions';

const PAYMENT_MODES = ['Cash', 'UPI', 'Card', 'Cheque', 'Bank Transfer'];

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

export default function CollectOpticalPaymentTab() {
  const searchParams = useSearchParams();
  const initialSaleId = searchParams.get('saleId');

  const [mode, setMode] = useState('number'); // 'number' | 'customer'
  const [billQuery, setBillQuery] = useState('');
  const [customerQuery, setCustomerQuery] = useState('');
  const [customerResults, setCustomerResults] = useState([]);
  const [saleResults, setSaleResults] = useState([]);

  const [detail, setDetail] = useState(null); // { sale, items, payments }
  const [pendingBills, setPendingBills] = useState([]);
  const [advanceBalance, setAdvanceBalance] = useState(0);
  const [amount, setAmount] = useState('');
  const [modeAmounts, setModeAmounts] = useState({ Cash: '' });
  const [reference, setReference] = useState('');
  const [remarks, setRemarks] = useState('');
  const [applyAdvanceAmt, setApplyAdvanceAmt] = useState('');

  const [error, setError] = useState('');
  const [saving, setSaving] = useState(false);
  const [successMsg, setSuccessMsg] = useState('');

  useEffect(() => {
    if (initialSaleId) loadSale(initialSaleId);
    refreshPendingBills();
  }, [initialSaleId]);

  async function refreshPendingBills() {
    const result = await getOutstandingOpticalBills();
    setPendingBills(result.sales || []);
  }

  useEffect(() => {
    const q = customerQuery.trim();
    if (q.length < 2) { setCustomerResults([]); return; }
    const t = setTimeout(async () => setCustomerResults(await searchOpticalCustomers(q)), 300);
    return () => clearTimeout(t);
  }, [customerQuery]);

  async function loadSale(saleId) {
    setError('');
    const result = await getOpticalSaleDetail(saleId);
    if (result.error) { setError(result.error); return; }
    setDetail(result);
    setSaleResults([]);
    setCustomerResults([]);
    const balance = await getOpticalAdvanceBalance({ patientId: result.sale.patient_id, opticalCustomerId: result.sale.optical_customer_id });
    setAdvanceBalance(balance);
    setAmount(result.sale.outstanding > 0 ? String(result.sale.outstanding) : '');
    setModeAmounts({ Cash: result.sale.outstanding > 0 ? String(result.sale.outstanding) : '' });
  }

  async function handleBillSearch() {
    setError('');
    const result = await findOpticalSaleByNumber(billQuery);
    if (result.error) { setError(result.error); return; }
    setSaleResults(result.sales);
  }

  async function pickCustomer(c) {
    setError('');
    const result = await getOpticalSalesForCustomer({ patientId: c.type === 'patient' ? c.id : null, opticalCustomerId: c.type === 'optical_customer' ? c.id : null });
    setSaleResults(result.sales || []);
    setCustomerResults([]);
    setCustomerQuery('');
  }

  function updateModeAmount(m, val) {
    setModeAmounts((prev) => ({ ...prev, [m]: val }));
  }
  function toggleMode(m) {
    setModeAmounts((prev) => {
      const next = { ...prev };
      if (m in next) delete next[m];
      else next[m] = '';
      return next;
    });
  }

  const modesTotal = Object.values(modeAmounts).reduce((s, v) => s + (Number(v) || 0), 0);

  async function handleCollect() {
    setError('');
    setSuccessMsg('');
    setSaving(true);
    const modes = Object.entries(modeAmounts).filter(([, v]) => Number(v) > 0).map(([m, v]) => ({ mode: m, amount: v }));
    const result = await collectOpticalPayment({ saleId: detail.sale.id, amount, modes, reference, remarks });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg(`Payment recorded -- receipt ${result.payment.receipt_number}`);
    loadSale(detail.sale.id);
    refreshPendingBills();
    setReference('');
    setRemarks('');
  }

  async function handleApplyAdvance() {
    setError('');
    setSuccessMsg('');
    setSaving(true);
    const result = await applyOpticalAdvanceAdjustment({
      patientId: detail.sale.patient_id, opticalCustomerId: detail.sale.optical_customer_id, saleId: detail.sale.id, amount: applyAdvanceAmt,
    });
    setSaving(false);
    if (result.error) { setError(result.error); return; }
    setSuccessMsg('Advance applied against this bill.');
    setApplyAdvanceAmt('');
    loadSale(detail.sale.id);
    refreshPendingBills();
  }

  return (
    <div style={{ display: 'grid', gridTemplateColumns: detail ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      {detail && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 4 }}><i className="ti ti-receipt" style={{ color: 'var(--blue)' }}></i> {detail.sale.sale_number}</div>
          <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 10 }}>{detail.sale.displayName} -- {detail.sale.displayMobile || 'no mobile'}</div>

          {successMsg && <div className="msg-info" style={{ background: 'var(--green-lt, #e3f5ec)', color: 'var(--green, #157a4f)', padding: '8px 12px', borderRadius: 8, fontSize: 13, marginBottom: 10 }}>{successMsg}</div>}

          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>Bill Total</span><span>{fmt(detail.sale.net)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', borderBottom: '1px solid var(--g100)', fontSize: 13 }}>
            <span>Paid So Far</span><span>{fmt(detail.sale.paid)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', marginBottom: 10, fontSize: 14, fontWeight: 700 }}>
            <span>Outstanding</span><span style={{ color: detail.sale.outstanding > 0 ? 'var(--red)' : 'var(--green)' }}>{fmt(detail.sale.outstanding)}</span>
          </div>

          {detail.sale.status === 'Cancelled' && <div className="msg-err">This bill has been cancelled.</div>}

          {detail.sale.outstanding > 0 && detail.sale.status !== 'Cancelled' && (
            <>
              {advanceBalance > 0 && (
                <div style={{ background: 'var(--blue-lt, #eef4fb)', padding: '8px 12px', borderRadius: 8, marginBottom: 12, fontSize: 12.5 }}>
                  <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', flexWrap: 'wrap', gap: 8 }}>
                    <span><i className="ti ti-piggy-bank"></i> Advance balance available: <strong>{fmt(advanceBalance)}</strong></span>
                    <div style={{ display: 'flex', gap: 6 }}>
                      <input className="fi" style={{ width: 100 }} type="number" value={applyAdvanceAmt} onChange={(e) => setApplyAdvanceAmt(e.target.value)} placeholder="Amount" />
                      <button className="btn btn-sm" disabled={saving || !applyAdvanceAmt} onClick={handleApplyAdvance}>Apply</button>
                    </div>
                  </div>
                </div>
              )}

              <label className="flbl">Amount to Collect</label>
              <input className="fi" type="number" value={amount} disabled style={{ background: 'var(--g50, #f7f8fa)', color: 'var(--g600)', fontWeight: 700 }} />
              <div style={{ fontSize: 11, color: 'var(--g500)', marginTop: 4, marginBottom: 4 }}>Locked to the outstanding balance -- split it across modes below.</div>

              <label className="flbl" style={{ marginTop: 10 }}>Payment Mode(s)</label>
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
              <div style={{ fontSize: 11.5, color: modesTotal === Number(amount) ? 'var(--g500)' : 'var(--red)', marginBottom: 10 }}>
                Mode split total: {fmt(modesTotal)} {modesTotal !== Number(amount) && amount ? `(must equal ${fmt(amount)})` : ''}
              </div>

              <div style={{ display: 'flex', gap: 12, marginBottom: 10 }}>
                <input className="fi" value={reference} onChange={(e) => setReference(e.target.value)} placeholder="Reference (optional)" />
                <input className="fi" value={remarks} onChange={(e) => setRemarks(e.target.value)} placeholder="Remarks (optional)" />
              </div>

              <button className="btn btn-primary" disabled={saving} onClick={handleCollect}>
                <i className="ti ti-cash"></i> {saving ? 'Recording...' : 'Collect Payment'}
              </button>
            </>
          )}

          <div style={{ marginTop: 16, paddingTop: 12, borderTop: '1px solid var(--g100)' }}>
            <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Items</div>
            {detail.items.map((it) => (
              <div key={it.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '3px 0', color: 'var(--g600)' }}>
                <span>{it.description} x{it.qty}</span><span>{fmt(it.amount)}</span>
              </div>
            ))}
          </div>

          {detail.payments.length > 0 && (
            <div style={{ marginTop: 12, paddingTop: 12, borderTop: '1px solid var(--g100)' }}>
              <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Payment History</div>
              {detail.payments.map((p) => (
                <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '3px 0', color: 'var(--g600)' }}>
                  <span>{p.receipt_number} -- {p.payment_type === 'advance_adjustment' ? 'Advance Applied' : (p.optical_payment_modes || []).map((m) => m.mode).join('/')}</span>
                  <span>{fmt(p.total_amount)}</span>
                </div>
              ))}
            </div>
          )}

          <a href={`/optical-receipt-print/${detail.sale.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none', marginTop: 12, display: 'inline-block' }}>
            <i className="ti ti-printer"></i> Print Bill
          </a>
        </div>
      )}

      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-search" style={{ color: 'var(--blue)' }}></i> Find Bill</div>
        {error && <div className="msg-err">{error}</div>}

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

        <div style={{ marginTop: 16, paddingTop: 12, borderTop: '1.5px solid var(--g200)' }}>
          <div className="card-title" style={{ marginBottom: 8, fontSize: 13 }}><i className="ti ti-list-details" style={{ color: 'var(--purple)' }}></i> Pending Bills</div>
          {pendingBills.length === 0 ? (
            <div style={{ fontSize: 12, color: 'var(--g400)' }}>Nothing outstanding right now.</div>
          ) : (
            pendingBills.map((s) => (
              <div key={s.id} onClick={() => loadSale(s.id)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12.5, background: detail?.sale.id === s.id ? 'var(--g50, #f7f8fa)' : 'transparent' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{s.sale_number}</strong>
                  <span style={{ color: s.status === 'Partial' ? 'var(--purple)' : 'var(--g500)' }}>{s.status}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}>
                  <span>{s.displayName}</span>
                  <span>Due {fmt(s.outstanding)}</span>
                </div>
              </div>
            ))
          )}
        </div>
      </div>
    </div>
  );
}
