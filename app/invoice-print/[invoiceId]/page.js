import { createClient } from '../../../lib/supabase-server';
import PrintButton from './print-button';

export default async function InvoicePrintPage({ params }) {
  const { invoiceId } = await params;
  const supabase = await createClient();

  const { data: invoice, error } = await supabase
    .from('invoices')
    .select('*, patients(first_name, last_name, uhid, mobile, address, city, state, pin_code)')
    .eq('id', invoiceId)
    .single();

  if (error || !invoice) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Invoice not found.</div>;
  }

  const { data: lineItems } = await supabase
    .from('invoice_line_items')
    .select('*')
    .eq('invoice_id', invoiceId)
    .order('id');

  const balanceDue = Number(invoice.net) - Number(invoice.paid);
  const totalDisc = (lineItems || []).reduce((s, li) => s + Number(li.disc), 0);

  return (
    <div style={{ maxWidth: 750, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #1d4ed8', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#1e3a8a' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Bill To</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{invoice.patients?.first_name} {invoice.patients?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients?.uhid}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients?.mobile}</div>
          {invoice.patients?.address && <div style={{ fontSize: 12, color: '#4b5563' }}>{invoice.patients.address}</div>}
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Invoice</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{invoice.invoice_number}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{new Date(invoice.created_at).toLocaleDateString('en-IN', { day: 'numeric', month: 'long', year: 'numeric' })}</div>
          <div style={{ fontSize: 12, fontWeight: 700, marginTop: 4, color: invoice.status === 'Cancelled' ? '#b91c1c' : '#15803d' }}>{invoice.status}</div>
        </div>
      </div>

      <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 20, fontSize: 13 }}>
        <thead>
          <tr style={{ borderBottom: '2px solid #1f2937' }}>
            <th style={{ textAlign: 'left', padding: '8px 4px' }}>Service</th>
            <th style={{ textAlign: 'center', padding: '8px 4px' }}>Qty</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Rate</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Disc</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>GST</th>
            <th style={{ textAlign: 'right', padding: '8px 4px' }}>Net</th>
          </tr>
        </thead>
        <tbody>
          {(lineItems || []).map((li) => (
            <tr key={li.id} style={{ borderBottom: '1px solid #e5e7eb' }}>
              <td style={{ padding: '8px 4px' }}>{li.service_name}</td>
              <td style={{ textAlign: 'center', padding: '8px 4px' }}>{li.qty}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{Number(li.rate).toFixed(2)}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{li.disc > 0 ? Number(li.disc).toFixed(2) : '--'}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px' }}>{Number(li.gst_amount).toFixed(2)}</td>
              <td style={{ textAlign: 'right', padding: '8px 4px', fontWeight: 600 }}>{Number(li.net).toFixed(2)}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <div style={{ marginLeft: 'auto', width: 260, fontSize: 13 }}>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>Gross</span><span>Rs.{Number(invoice.gross).toFixed(2)}</span></div>
        {totalDisc > 0 && <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>Discount</span><span>-Rs.{totalDisc.toFixed(2)}</span></div>}
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0' }}><span>GST</span><span>Rs.{Number(invoice.gst).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '6px 0', borderTop: '1px solid #1f2937', fontWeight: 700, fontSize: 14 }}><span>Net Total</span><span>Rs.{Number(invoice.net).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', color: '#15803d' }}><span>Paid</span><span>Rs.{Number(invoice.paid).toFixed(2)}</span></div>
        <div style={{ display: 'flex', justifyContent: 'space-between', padding: '3px 0', fontWeight: 700, color: balanceDue > 0 ? '#b91c1c' : '#15803d' }}><span>Balance Due</span><span>Rs.{balanceDue.toFixed(2)}</span></div>
      </div>

      {invoice.status === 'Cancelled' && (
        <div style={{ marginTop: 20, padding: 12, background: '#fee2e2', color: '#b91c1c', borderRadius: 6, fontSize: 12 }}>
          Cancelled -- Reason: {invoice.cancellation_reason}
        </div>
      )}

      <div style={{ marginTop: 40, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated invoice.
      </div>
    </div>
  );
}

