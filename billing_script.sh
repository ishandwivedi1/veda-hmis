mkdir -p 'app/billing/[visitId]' app/visits

cat > 'app/billing/actions.js' << 'EOF'
'use server';

import { createClient } from '../../lib/supabase-server';

export async function getInvoiceForVisit(visitId) {
  const supabase = await createClient();

  const { data: visit, error: visitError } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile)')
    .eq('id', visitId)
    .single();

  if (visitError) return { error: visitError.message };

  const { data: invoice, error: invError } = await supabase.rpc('get_or_create_invoice_for_visit', {
    p_visit_id: visitId,
  });

  if (invError) return { error: invError.message };

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoice.id)
    .order('id');

  return { visit, invoice, lineItems: lineItems || [] };
}

export async function getServiceCatalog() {
  const supabase = await createClient();
  const { data } = await supabase.from('master_services').select('*').eq('status', 'Active').order('name');
  return data || [];
}

export async function addLineItem(invoiceId, serviceCode, qty) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('add_invoice_line_item', {
    p_invoice_id: invoiceId,
    p_service_code: serviceCode,
    p_qty: qty,
  });
  if (error) return { error: error.message };
  return { success: true };
}

export async function removeLineItem(lineItemId) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('remove_invoice_line_item', { p_line_item_id: lineItemId });
  if (error) return { error: error.message };
  return { success: true };
}

export async function recordPayment(invoiceId, amount) {
  const supabase = await createClient();
  const { error } = await supabase.rpc('record_payment', { p_invoice_id: invoiceId, p_amount: amount });
  if (error) return { error: error.message };
  return { success: true };
}

EOF

cat > 'app/billing/[visitId]/page.js' << 'EOF'
import BillingForm from './billing-form';

export default async function BillingPage({ params }) {
  const { visitId } = await params;
  return <BillingForm visitId={visitId} />;
}

EOF

cat > 'app/billing/[visitId]/billing-form.js' << 'EOF'
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

EOF

cat > 'app/visits/page.js' << 'EOF'
import Link from 'next/link';
import { createClient } from '../../lib/supabase-server';

export default async function VisitsPage({ searchParams }) {
  const params = await searchParams;
  const justCreated = params?.created;

  const supabase = await createClient();
  const { data: visits, error } = await supabase
    .from('visits')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('status', 'Open')
    .order('created_at', { ascending: false });

  return (
    <div style={{ maxWidth: 900, margin: '40px auto', padding: '0 20px' }}>
      <div className="card">
        <div
          style={{
            display: 'flex',
            justifyContent: 'space-between',
            alignItems: 'center',
            marginBottom: 20,
          }}
        >
          <div>
            <div style={{ fontSize: 18, fontWeight: 700 }}>Open Visits</div>
            <div style={{ fontSize: 12, color: 'var(--g500)' }}>
              Patients currently in the hospital, visit not yet closed.
            </div>
          </div>
          <Link href="/visits/new" className="btn btn-primary" style={{ textDecoration: 'none' }}>
            + Walk-in Visit
          </Link>
        </div>

        {justCreated && (
          <div
            style={{
              background: 'var(--green-lt)',
              color: 'var(--green)',
              padding: '10px 14px',
              borderRadius: 8,
              fontSize: 13,
              marginBottom: 16,
            }}
          >
            Visit created successfully.
          </div>
        )}

        {error && <div className="msg-err">{error.message}</div>}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 13 }}>
          <thead>
            <tr style={{ textAlign: 'left', borderBottom: '1.5px solid var(--g200)' }}>
              <th style={{ padding: '8px 6px' }}>Patient</th>
              <th style={{ padding: '8px 6px' }}>UHID</th>
              <th style={{ padding: '8px 6px' }}>Mobile</th>
              <th style={{ padding: '8px 6px' }}>Type</th>
              <th style={{ padding: '8px 6px' }}>Doctor</th>
              <th style={{ padding: '8px 6px' }}>Since</th>
              <th style={{ padding: '8px 6px' }}></th>
            </tr>
          </thead>
          <tbody>
            {(visits || []).map((v) => (
              <tr key={v.id} style={{ borderBottom: '1px solid var(--g100)' }}>
                <td style={{ padding: '8px 6px' }}>
                  {v.patients?.first_name} {v.patients?.last_name}
                </td>
                <td style={{ padding: '8px 6px', fontFamily: 'monospace' }}>{v.patients?.uhid}</td>
                <td style={{ padding: '8px 6px' }}>{v.patients?.mobile}</td>
                <td style={{ padding: '8px 6px' }}>{v.visit_type}</td>
                <td style={{ padding: '8px 6px' }}>{v.profiles?.full_name || '--'}</td>
                <td style={{ padding: '8px 6px', color: 'var(--g500)' }}>
                  {new Date(v.created_at).toLocaleTimeString('en-IN', { hour: '2-digit', minute: '2-digit' })}
                </td>
                <td style={{ padding: '8px 6px' }}>
                  <Link href={`/billing/${v.id}`} className="btn btn-primary" style={{ padding: '3px 10px', fontSize: 11, textDecoration: 'none' }}>
                    Bill
                  </Link>
                </td>
              </tr>
            ))}
            {(!visits || visits.length === 0) && (
              <tr>
                <td colSpan={7} style={{ padding: '20px 6px', textAlign: 'center', color: 'var(--g400)' }}>
                  No open visits right now.
                </td>
              </tr>
            )}
          </tbody>
        </table>
      </div>
    </div>
  );
}

EOF

echo "Billing module created."
