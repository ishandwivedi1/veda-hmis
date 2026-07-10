import { createClient } from '../../../lib/supabase-server';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

const TYPE_LABEL = { invoice_payment: 'Payment', advance: 'Advance Collection', advance_adjustment: 'Advance Adjustment' };

export default async function ReceiptPrintPage({ params }) {
  const { paymentId } = await params;
  const supabase = await createClient();

  const { data: payment, error } = await supabase
    .from('payments')
    .select('*, patients(first_name, last_name, uhid, mobile), profiles(full_name)')
    .eq('id', paymentId)
    .single();

  if (error || !payment) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b91c1c' }}>Receipt not found.</div>;
  }

  const { data: modes } = await supabase.from('payment_modes').select('*').eq('payment_id', paymentId);
  const { data: allocations } = await supabase
    .from('payment_allocations')
    .select('*, invoices(invoice_number)')
    .eq('payment_id', paymentId);

  return (
    <div style={{ maxWidth: 600, margin: '0 auto', padding: 30, fontFamily: 'Arial, sans-serif', color: '#111827' }}>
      <div className="no-print" style={{ textAlign: 'right', marginBottom: 20 }}>
        <PrintButton />
      </div>

      <div style={{ textAlign: 'center', borderBottom: '2px solid #15803d', paddingBottom: 16, marginBottom: 20 }}>
        <div style={{ fontSize: 22, fontWeight: 800, color: '#166534' }}>VEDA EYE HOSPITAL</div>
        <div style={{ fontSize: 12, color: '#6b7280' }}>Haridwar, Uttarakhand</div>
        <div style={{ fontSize: 14, fontWeight: 700, marginTop: 8 }}>PAYMENT RECEIPT</div>
      </div>

      <div style={{ display: 'flex', justifyContent: 'space-between', marginBottom: 20 }}>
        <div>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Received From</div>
          <div style={{ fontWeight: 700, fontSize: 15 }}>{payment.patients?.first_name} {payment.patients?.last_name}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{payment.patients?.uhid}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{payment.patients?.mobile}</div>
        </div>
        <div style={{ textAlign: 'right' }}>
          <div style={{ fontSize: 11, color: '#6b7280', textTransform: 'uppercase' }}>Receipt #</div>
          <div style={{ fontWeight: 700, fontFamily: 'monospace', fontSize: 14 }}>{payment.receipt_number}</div>
          <div style={{ fontSize: 12, color: '#4b5563' }}>{new Date(payment.collected_at).toLocaleString('en-IN', { day: 'numeric', month: 'long', year: 'numeric', hour: '2-digit', minute: '2-digit' })}</div>
          <div style={{ fontSize: 12, marginTop: 4 }}>{TYPE_LABEL[payment.payment_type] || payment.payment_type}</div>
        </div>
      </div>

      <div style={{ background: '#f0fdf4', border: '1px solid #bbf7d0', borderRadius: 8, padding: 16, textAlign: 'center', marginBottom: 20 }}>
        <div style={{ fontSize: 11, color: '#166534', textTransform: 'uppercase' }}>Amount Received</div>
        <div style={{ fontSize: 28, fontWeight: 800, color: '#15803d' }}>Rs.{Number(payment.total_amount).toFixed(2)}</div>
      </div>

      {allocations && allocations.length > 0 && (
        <div style={{ marginBottom: 16 }}>
          <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Applied Against</div>
          {allocations.map((a) => (
            <div key={a.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0', borderBottom: '1px solid #e5e7eb' }}>
              <span>{a.invoices?.invoice_number}</span>
              <span>Rs.{Number(a.amount).toFixed(2)}</span>
            </div>
          ))}
        </div>
      )}

      <div style={{ marginBottom: 16 }}>
        <div style={{ fontSize: 12, fontWeight: 700, marginBottom: 6 }}>Payment Mode(s)</div>
        {(modes || []).map((m) => (
          <div key={m.id} style={{ display: 'flex', justifyContent: 'space-between', fontSize: 13, padding: '4px 0', borderBottom: '1px solid #e5e7eb' }}>
            <span>{m.mode}</span>
            <span>Rs.{Number(m.amount).toFixed(2)}</span>
          </div>
        ))}
      </div>

      {payment.reference && (
        <div style={{ fontSize: 12, color: '#4b5563', marginBottom: 6 }}>Reference: {payment.reference}</div>
      )}
      {payment.remarks && (
        <div style={{ fontSize: 12, color: '#4b5563', marginBottom: 6 }}>Remarks: {payment.remarks}</div>
      )}

      <div style={{ marginTop: 30, fontSize: 12, color: '#4b5563' }}>
        Collected by: {payment.profiles?.full_name || '--'}
      </div>

      <div style={{ marginTop: 40, textAlign: 'center', fontSize: 11, color: '#9ca3af' }}>
        This is a computer-generated receipt.
      </div>
    </div>
  );
}

