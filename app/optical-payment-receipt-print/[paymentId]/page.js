import { getOpticalPaymentDetail } from '@/app/(main)/optical/actions';
import { getHospitalSettings } from '@/app/print-templates/actions';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

const TITLE_BY_TYPE = {
  advance: 'ADVANCE RECEIPT',
  sale_payment: 'PAYMENT RECEIPT',
  advance_adjustment: 'ADVANCE APPLIED',
  credit_note: 'CREDIT NOTE',
  refund: 'REFUND RECEIPT',
};

function inr(n) {
  return `Rs. ${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}
function fmtDate(iso) {
  return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export default async function OpticalPaymentReceiptPrintPage({ params }) {
  const { paymentId } = await params;
  const [{ payment, displayName, displayMobile, error }, settings] = await Promise.all([
    getOpticalPaymentDetail(paymentId),
    getHospitalSettings(),
  ]);

  if (error || !payment) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{error || 'Payment not found.'}</div>;
  }

  const title = TITLE_BY_TYPE[payment.payment_type] || 'RECEIPT';

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      <div style={{ maxWidth: 550, margin: '0 auto', padding: 24, fontFamily: 'Arial, Helvetica, sans-serif', color: '#1a1a1a', fontSize: 13 }}>
        <link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700;800&display=swap" rel="stylesheet" />
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, marginBottom: 6 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            {settings.logo_data_url && (
              <div style={{ width: 56, height: 56, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <img src={settings.logo_data_url} alt="" style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} />
              </div>
            )}
            <div>
              <div style={{ fontFamily: '"Playfair Display", Georgia, serif', fontSize: 26, fontWeight: 800, letterSpacing: '.5px', color: '#1a2b4a', lineHeight: 1 }}>Veda Opticals</div>
              <div style={{ width: 40, height: 2.5, background: '#c9a24b', marginTop: 6 }} />
            </div>
          </div>
          <div style={{ textAlign: 'right', fontSize: 10, lineHeight: 1.5, flexShrink: 0 }}>
            {settings.address_line1}<br />
            {settings.address_line2}<br />
            {settings.city_state_pin}<br />
            {settings.phone && <>Tel: {settings.phone}</>}
          </div>
        </div>

        <div style={{ textAlign: 'center', fontSize: 15, fontWeight: 700, borderTop: '1.5px solid #333', borderBottom: '1.5px solid #333', padding: '8px 0', margin: '10px 0 16px' }}>
          {title}
        </div>

        <table style={{ width: '100%', border: '1.5px solid #333', borderCollapse: 'collapse', marginBottom: 16 }}>
          <tbody>
            <tr>
              <td style={{ width: '50%', padding: '10px 14px', verticalAlign: 'top', borderRight: '1px solid #999' }}>
                <div style={{ fontSize: 10, color: '#666', textTransform: 'uppercase' }}>Received From</div>
                <div style={{ fontSize: 14, fontWeight: 700 }}>{displayName}</div>
                {payment.patients?.uhid && <div style={{ fontSize: 11.5, color: '#444' }}>{payment.patients.uhid}</div>}
                {displayMobile && <div style={{ fontSize: 11.5, color: '#444' }}>{displayMobile}</div>}
              </td>
              <td style={{ width: '50%', padding: '10px 14px', verticalAlign: 'top' }}>
                <table style={{ width: '100%', fontSize: 12 }}>
                  <tbody>
                    <tr><td style={{ width: 90, color: '#444' }}>Receipt No</td><td>: <strong>{payment.receipt_number}</strong></td></tr>
                    <tr><td style={{ color: '#444' }}>Date</td><td>: <strong>{fmtDate(payment.collected_at)}</strong></td></tr>
                    {payment.reference && <tr><td style={{ color: '#444' }}>Reference</td><td>: {payment.reference}</td></tr>}
                  </tbody>
                </table>
              </td>
            </tr>
          </tbody>
        </table>

        {payment.optical_sales && (
          <div style={{ background: '#f4f7fb', border: '1px solid #d5e0ee', borderRadius: 6, padding: '10px 14px', marginBottom: 16, fontSize: 12 }}>
            <strong>Against Order:</strong> {payment.optical_sales.sale_number}
            {' -- '}Order Total {inr(payment.optical_sales.net)}, Paid to Date {inr(payment.optical_sales.paid)}, Balance {inr(payment.optical_sales.net - payment.optical_sales.paid)}
          </div>
        )}
        {!payment.optical_sales && payment.payment_type === 'advance' && (
          <div style={{ background: '#f4f7fb', border: '1px solid #d5e0ee', borderRadius: 6, padding: '10px 14px', marginBottom: 16, fontSize: 12 }}>
            This advance has not yet been applied to any order.
          </div>
        )}

        <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 12, marginBottom: 16 }}>
          <thead>
            <tr style={{ background: '#e9edf2' }}>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'left' }}>Mode</th>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'right' }}>Amount</th>
            </tr>
          </thead>
          <tbody>
            {(payment.optical_payment_modes || []).length > 0 ? (
              payment.optical_payment_modes.map((m, i) => (
                <tr key={i}>
                  <td style={{ border: '1px solid #999', padding: 7 }}>{m.mode}</td>
                  <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>{inr(m.amount)}</td>
                </tr>
              ))
            ) : (
              <tr>
                <td style={{ border: '1px solid #999', padding: 7 }} colSpan={2}>No cash movement (adjustment entry)</td>
              </tr>
            )}
            <tr>
              <td style={{ border: '1px solid #999', background: '#e9edf2', padding: 8, fontWeight: 700 }}>TOTAL</td>
              <td style={{ border: '1px solid #999', padding: 8, textAlign: 'right', fontWeight: 700 }}>{inr(payment.total_amount)}</td>
            </tr>
          </tbody>
        </table>

        {payment.remarks && <div style={{ fontSize: 11.5, color: '#444', marginBottom: 14 }}>Remarks: {payment.remarks}</div>}

        <table style={{ width: '100%', marginTop: 40 }}>
          <tbody>
            <tr>
              <td style={{ fontSize: 12 }}>&nbsp;</td>
              <td style={{ textAlign: 'right', fontSize: 12 }}>
                <div>AUTHORISED SIGNATURE</div>
                <div>FOR VEDA OPTICALS</div>
              </td>
            </tr>
          </tbody>
        </table>

        <div style={{ textAlign: 'center', marginTop: 20, fontSize: 10, color: '#999' }}>
          This is a computer-generated receipt.
        </div>
      </div>
    </div>
  );
}
