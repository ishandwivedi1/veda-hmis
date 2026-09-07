'use client';

import { useState, useEffect } from 'react';
import { useRouter } from 'next/navigation';
import { searchOpticalSaleHistory, getOpticalSaleDetail, cancelOpticalSale } from '../actions';

const STATUSES = ['', 'Pending', 'Partial', 'Paid', 'Cancelled'];
const STATUS_COLORS = { Pending: 'var(--g500)', Partial: 'var(--purple)', Paid: 'var(--green)', Cancelled: 'var(--red)' };

function fmt(n) {
  return `\u20b9${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(d) {
  return new Date(d).toLocaleDateString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric' });
}

export default function OpticalHistoryTab() {
  const router = useRouter();
  const [fromDate, setFromDate] = useState('');
  const [toDate, setToDate] = useState('');
  const [status, setStatus] = useState('');
  const [query, setQuery] = useState('');
  const [sales, setSales] = useState([]);
  const [loading, setLoading] = useState(true);
  const [selectedId, setSelectedId] = useState(null);
  const [detail, setDetail] = useState(null);
  const [cancelReason, setCancelReason] = useState('');
  const [showCancel, setShowCancel] = useState(false);
  const [error, setError] = useState('');

  useEffect(() => { runSearch(); }, []);

  async function runSearch() {
    setLoading(true);
    const result = await searchOpticalSaleHistory({ fromDate, toDate, status, query });
    setSales(result.sales || []);
    setLoading(false);
  }

  async function openDetail(id) {
    setSelectedId(id);
    setShowCancel(false);
    setError('');
    const result = await getOpticalSaleDetail(id);
    if (result.error) { setError(result.error); return; }
    setDetail(result);
  }

  async function handleCancel() {
    const result = await cancelOpticalSale(selectedId, cancelReason);
    if (result.error) { setError(result.error); return; }
    setShowCancel(false);
    setCancelReason('');
    openDetail(selectedId);
    runSearch();
  }

  const totalNet = sales.filter((s) => s.status !== 'Cancelled').reduce((s, x) => s + Number(x.net), 0);
  const totalOutstanding = sales.filter((s) => s.status !== 'Cancelled').reduce((s, x) => s + Number(x.outstanding), 0);

  return (
    <div style={{ display: 'grid', gridTemplateColumns: detail ? '1.3fr 1fr' : '1fr', gap: 20 }}>
      <div className="card">
        <div className="card-title" style={{ marginBottom: 10 }}><i className="ti ti-history" style={{ color: 'var(--blue)' }}></i> Optical Sales History</div>

        <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 12 }}>
          <input className="fi" type="date" value={fromDate} onChange={(e) => setFromDate(e.target.value)} style={{ flex: 1 }} />
          <input className="fi" type="date" value={toDate} onChange={(e) => setToDate(e.target.value)} style={{ flex: 1 }} />
          <select className="fi" value={status} onChange={(e) => setStatus(e.target.value)} style={{ flex: 1 }}>
            {STATUSES.map((s) => <option key={s} value={s}>{s || 'All Statuses'}</option>)}
          </select>
          <input className="fi" value={query} onChange={(e) => setQuery(e.target.value)} placeholder="Bill no. / name / mobile" style={{ flex: 2 }} />
          <button className="btn btn-primary" onClick={runSearch}><i className="ti ti-search"></i></button>
        </div>

        {loading ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>Loading...</div>
        ) : sales.length === 0 ? (
          <div style={{ fontSize: 12, color: 'var(--g400)' }}>No bills match these filters.</div>
        ) : (
          <>
            <div style={{ display: 'flex', justifyContent: 'space-between', padding: '4px 0 10px', fontSize: 12, color: 'var(--g500)', borderBottom: '1px solid var(--g100)', marginBottom: 6 }}>
              <span>{sales.length} bill{sales.length > 1 ? 's' : ''}</span>
              <span>Total: {fmt(totalNet)} -- Outstanding: {fmt(totalOutstanding)}</span>
            </div>
            {sales.map((s) => (
              <div key={s.id} onClick={() => openDetail(s.id)} style={{ padding: '8px 4px', cursor: 'pointer', borderBottom: '1px solid var(--g100)', fontSize: 12.5, background: selectedId === s.id ? 'var(--g50, #f7f8fa)' : 'transparent' }}>
                <div style={{ display: 'flex', justifyContent: 'space-between' }}>
                  <strong>{s.sale_number}</strong>
                  <span style={{ color: STATUS_COLORS[s.status], fontWeight: 700 }}>{s.status}</span>
                </div>
                <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--g500)' }}>
                  <span>{s.displayName} -- {fmtDate(s.sale_date)}</span>
                  <span>{fmt(s.net)}{s.outstanding > 0 && s.status !== 'Cancelled' ? ` (due ${fmt(s.outstanding)})` : ''}</span>
                </div>
              </div>
            ))}
          </>
        )}
      </div>

      {detail && (
        <div className="card">
          <div className="card-title" style={{ marginBottom: 4, display: 'flex', justifyContent: 'space-between' }}>
            <span><i className="ti ti-receipt"></i> {detail.sale.sale_number}</span>
            <span style={{ color: STATUS_COLORS[detail.sale.status] }}>{detail.sale.status}</span>
          </div>
          {error && <div className="msg-err">{error}</div>}
          <div style={{ fontSize: 12.5, color: 'var(--g500)', marginBottom: 10 }}>{detail.sale.displayName} -- {detail.sale.displayMobile || 'no mobile'} -- {fmtDate(detail.sale.sale_date)}</div>

          <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Items</div>
          {detail.items.map((it) => (
            <div key={it.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '3px 0', color: 'var(--g600)' }}>
              <span>{it.description} x{it.qty}</span><span>{fmt(it.amount)}</span>
            </div>
          ))}
          <div style={{ display: 'flex', justifyContent: 'space-between', padding: '8px 0', marginTop: 6, borderTop: '1px solid var(--g100)', fontSize: 13, fontWeight: 700 }}>
            <span>Net</span><span>{fmt(detail.sale.net)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, color: 'var(--g500)' }}>
            <span>Paid</span><span>{fmt(detail.sale.paid)}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12.5, color: detail.sale.outstanding > 0 ? 'var(--red)' : 'var(--green)' }}>
            <span>Outstanding</span><span>{fmt(detail.sale.outstanding)}</span>
          </div>

          {detail.payments.length > 0 && (
            <div style={{ marginTop: 12, paddingTop: 10, borderTop: '1px solid var(--g100)' }}>
              <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Payments</div>
              {detail.payments.map((p) => (
                <div key={p.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 12, padding: '3px 0', color: 'var(--g600)' }}>
                  <span>{p.receipt_number} -- {p.payment_type === 'advance_adjustment' ? 'Advance Applied' : (p.optical_payment_modes || []).map((m) => m.mode).join('/')}</span>
                  <span>{fmt(p.total_amount)}</span>
                </div>
              ))}
            </div>
          )}

          {detail.sale.status === 'Cancelled' && detail.sale.cancellation_reason && (
            <div className="msg-err" style={{ marginTop: 12, fontSize: 12 }}>Cancelled: {detail.sale.cancellation_reason}</div>
          )}

          <div style={{ display: 'flex', gap: 8, marginTop: 16, flexWrap: 'wrap' }}>
            <a href={`/optical-receipt-print/${detail.sale.id}`} target="_blank" rel="noopener noreferrer" className="btn btn-sm" style={{ textDecoration: 'none' }}>
              <i className="ti ti-printer"></i> Print
            </a>
            {detail.sale.outstanding > 0 && detail.sale.status !== 'Cancelled' && (
              <button className="btn btn-sm btn-primary" onClick={() => router.push(`/optical/collect?saleId=${detail.sale.id}`)}>
                <i className="ti ti-cash"></i> Collect Payment
              </button>
            )}
            {detail.sale.status === 'Pending' && detail.sale.paid === 0 && !showCancel && (
              <button className="btn btn-sm" style={{ color: 'var(--red)' }} onClick={() => setShowCancel(true)}><i className="ti ti-x"></i> Cancel Bill</button>
            )}
          </div>

          {showCancel && (
            <div style={{ marginTop: 10, padding: 10, border: '1px solid var(--g200)', borderRadius: 8 }}>
              <label className="flbl">Cancellation reason</label>
              <input className="fi" value={cancelReason} onChange={(e) => setCancelReason(e.target.value)} placeholder="Reason" />
              <div style={{ display: 'flex', gap: 8, marginTop: 8 }}>
                <button className="btn btn-sm" onClick={() => setShowCancel(false)}>Back</button>
                <button className="btn btn-sm btn-primary" style={{ background: 'var(--red)', borderColor: 'var(--red)' }} onClick={handleCancel}>Confirm Cancel</button>
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
