'use client';

import { useState, useEffect, useCallback } from 'react';
import { useRouter } from 'next/navigation';
import { getInvoiceForVisit, getServiceCatalog, addLineItem, removeLineItem, recordPayment } from '../actions';

export default function BillingForm({ visitId }) {
  const [data, setData] = useState(null);
  const [catalog, setCatalog] = useState([]);
  const [loadError, setLoadError] = useState('');
  const [error, setError] = useState('');

  const [selectedService, setSelectedService] = useState('');
  const [qty, setQty] = useState(1);
  const [paymentAmount, setPaymentAmount] = useState('');
  const [loading, setLoading] = useState(false);
  const router = useRouter();

  const refresh = useCallback(async () => {
    const result = await getInvoiceForVisit(visitId);
    if (result.error) {
      setLoadError(result.error);
    } else {
      setData(result);
    }
  }, [visitId]);

  useEffect(() => {
    refresh();
    getServiceCatalog().then(setCatalog);
  }, [refresh]);

  async function handleAddLineItem() {
    setError('');
    if (!selectedService) { setError('Select a service.'); return; }
    const result = await addLineItem(data.invoice.id, selectedService, parseInt(qty, 10) || 1);
    if (result.error) { setError(result.error); return; }
    setSelectedService('');
    setQty(1);
    refresh();
  }

  async function handleRemoveLineItem(id) {
    await removeLineItem(id);
    refresh();
  }

  async function handleRecordPayment() {
    setError('');
    const amt = parseFloat(paymentAmount);
    if (!amt || amt <= 0) { setError('Enter a valid payment amount.'); return; }
    setLoading(true);
    const result = await recordPayment(data.invoice.id, amt);
    setLoading(false);
    if (result.error) { setError(result.error); return; }
    setPaymentAmount('');
    refresh();
  }

  if (loadError) {
    return <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}><div className="msg-err">{loadError}</div></div>;
  }
  if (!data) {
    return <div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>;
  }

  const patient = data.visit.patients;
  const inv = data.invoice;
  const balanceDue = inv.net - inv.paid;

  return (
    <div style={{ maxWidth: 700, margin: '40px auto', padding: '0 20px' }}>
      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>Billing</div>
            <div style={{ fontSize: 13, color: 'var(--g500)' }}>
              {patient.first_name} {patient.last_name} -- {patient.uhid} -- {patient.mobile}
            </div>
          </div>
          <span
            style={{
              fontSize: 12,
              fontWeight: 700,
              padding: '4px 10px',
              borderRadius: 12,
              background: inv.status === 'Paid' ? 'var(--green-lt)' : inv.status === 'Partial' ? '#fef3c7' : 'var(--red-lt)',
              color: inv.status === 'Paid' ? 'var(--green)' : inv.status === 'Partial' ? '#b45309' : 'var(--red)',
            }}
          >
            {inv.status}
          </span>
        </div>
      </div>

      {error && <div className="msg-err">{error}</div>}

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Line Items</div>
        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '6px' }}>Service</th>
              <th style={{ padding: '6px' }}>Qty</th>
              <th style={{ padding: '6px' }}>Rate</th>
              <th style={{ padding: '6px' }}>GST%</th>
              <th style={{ padding: '6px' }}>Net</th>
              <th style={{ padding: '6px' }}></th>
            </tr>
          </thead>
          <tbody>
            {data.lineItems.map((li) => (
              <tr key={li.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '6px' }}>{li.service_name}</td>
                <td style={{ padding: '6px' }}>{li.qty}</td>
                <td style={{ padding: '6px' }}>Rs.{li.rate}</td>
                <td style={{ padding: '6px' }}>{li.gst_pct}%</td>
                <td style={{ padding: '6px' }}>Rs.{li.net}</td>
                <td style={{ padding: '6px' }}>
                  <button className="btn" style={{ padding: '2px 8px', fontSize: 11 }} onClick={() => handleRemoveLineItem(li.id)}>
                    Remove
                  </button>
                </td>
              </tr>
            ))}
            {data.lineItems.length === 0 && (
              <tr>
                <td colSpan={6} style={{ padding: 16, textAlign: 'center', color: 'var(--g400)' }}>No line items yet.</td>
              </tr>
            )}
          </tbody>
        </table>

        <div style={{ display: 'flex', gap: 6, marginTop: 12 }}>
          <select className="fi" value={selectedService} onChange={(e) => setSelectedService(e.target.value)} style={{ flex: 2 }}>
            <option value="">-- Select service to add --</option>
            {catalog.map((s) => (
              <option key={s.code} value={s.code}>
                {s.name} -- Rs.{s.rate} ({s.gst_pct}% GST)
              </option>
            ))}
          </select>
          <input type="number" className="fi" value={qty} onChange={(e) => setQty(e.target.value)} style={{ width: 70 }} min={1} />
          <button className="btn btn-primary" style={{ fontSize: 12 }} onClick={handleAddLineItem}>
            Add
          </button>
        </div>
      </div>

      <div className="card" style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 13, lineHeight: 1.9 }}>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span>Gross</span><span>Rs.{inv.gross}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between' }}>
            <span>GST</span><span>Rs.{inv.gst}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700 }}>
            <span>Net Total</span><span>Rs.{inv.net}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', color: 'var(--green)' }}>
            <span>Paid</span><span>Rs.{inv.paid}</span>
          </div>
          <div style={{ display: 'flex', justifyContent: 'space-between', fontWeight: 700, color: balanceDue > 0 ? 'var(--red)' : 'var(--green)' }}>
            <span>Balance Due</span><span>Rs.{balanceDue}</span>
          </div>
        </div>
      </div>

      {balanceDue > 0 && (
        <div className="card">
          <div style={{ fontSize: 14, fontWeight: 700, marginBottom: 10 }}>Collect Payment</div>
          <div style={{ display: 'flex', gap: 8 }}>
            <input
              type="number"
              className="fi"
              placeholder={`Up to Rs.${balanceDue}`}
              value={paymentAmount}
              onChange={(e) => setPaymentAmount(e.target.value)}
            />
            <button className="btn btn-primary" onClick={handleRecordPayment} disabled={loading}>
              {loading ? 'Recording...' : 'Record Payment'}
            </button>
          </div>
        </div>
      )}
    </div>
  );
}

