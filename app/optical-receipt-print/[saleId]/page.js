import { getOpticalSaleDetail } from '@/app/(main)/billing/optical/actions';
import { getHospitalSettings } from '@/app/print-templates/actions';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

function inr(n) {
  return `Rs. ${Number(n || 0).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
}

function fmtDate(iso) {
  return new Date(iso).toLocaleString('en-IN', { timeZone: 'Asia/Kolkata', day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit' });
}

export default async function OpticalReceiptPrintPage({ params }) {
  const { saleId } = await params;
  const [{ sale, items, payments, error }, settings] = await Promise.all([
    getOpticalSaleDetail(saleId),
    getHospitalSettings(),
  ]);

  if (error || !sale) {
    return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{error || 'Bill not found.'}</div>;
  }

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      <div style={{ maxWidth: 650, margin: '0 auto', padding: 24, fontFamily: 'Arial, Helvetica, sans-serif', color: '#1a1a1a', fontSize: 13 }}>
        <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 6 }}>
          <tbody>
            <tr>
              <td style={{ width: 100, verticalAlign: 'top' }}>
                {settings.logo_data_url && <img src={settings.logo_data_url} alt="" style={{ width: 88, height: 88, objectFit: 'contain' }} />}
              </td>
              <td style={{ verticalAlign: 'top' }}>
                <div style={{ fontSize: 22, fontWeight: 800, letterSpacing: '.3px', textDecoration: 'underline' }}>{settings.name || 'VEDA EYE HOSPITAL'}</div>
                <div style={{ fontSize: 11, fontWeight: 700, marginTop: 2 }}>{settings.unit_line || ''}</div>
                {settings.regn_no && <div style={{ fontSize: 10, fontWeight: 700 }}>REGN NO : {settings.regn_no}</div>}
              </td>
              <td style={{ textAlign: 'right', verticalAlign: 'top', fontSize: 10.5, lineHeight: 1.5 }}>
                {settings.address_line1}<br />
                {settings.address_line2}<br />
                {settings.city_state_pin}<br />
                {settings.phone && <>Tel: {settings.phone}</>}
              </td>
            </tr>
          </tbody>
        </table>

        <div style={{ textAlign: 'center', fontSize: 16, fontWeight: 700, borderTop: '1.5px solid #333', borderBottom: '1.5px solid #333', padding: '8px 0', margin: '10px 0 16px' }}>
          OPTICAL SHOP BILL
        </div>

        <table style={{ width: '100%', border: '1.5px solid #333', borderCollapse: 'collapse', marginBottom: 16 }}>
          <tbody>
            <tr>
              <td style={{ width: '50%', padding: '10px 14px', verticalAlign: 'top', borderRight: '1px solid #999' }}>
                <div style={{ fontSize: 10, color: '#666', textTransform: 'uppercase' }}>Customer</div>
                <div style={{ fontSize: 14, fontWeight: 700 }}>{sale.displayName || 'Walk-in Customer'}</div>
                {sale.patients?.uhid && <div style={{ fontSize: 11.5, color: '#444' }}>{sale.patients.uhid}</div>}
                {sale.displayMobile && <div style={{ fontSize: 11.5, color: '#444' }}>{sale.displayMobile}</div>}
              </td>
              <td style={{ width: '50%', padding: '10px 14px', verticalAlign: 'top' }}>
                <table style={{ width: '100%', fontSize: 12 }}>
                  <tbody>
                    <tr><td style={{ width: 90, color: '#444' }}>Bill No</td><td>: <strong>{sale.sale_number}</strong></td></tr>
                    <tr><td style={{ color: '#444' }}>Date</td><td>: <strong>{fmtDate(sale.created_at)}</strong></td></tr>
                    <tr><td style={{ color: '#444' }}>Status</td><td>: <strong>{sale.status}</strong></td></tr>
                  </tbody>
                </table>
              </td>
            </tr>
          </tbody>
        </table>

        <table style={{ width: '100%', borderCollapse: 'collapse', marginBottom: 4, fontSize: 12 }}>
          <thead>
            <tr style={{ background: '#e9edf2' }}>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'center', width: 50 }}>S.NO</th>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'left' }}>Item</th>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'center', width: 70 }}>QTY</th>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'right', width: 110 }}>RATE</th>
              <th style={{ border: '1px solid #999', padding: 8, textAlign: 'right', width: 120 }}>AMOUNT</th>
            </tr>
          </thead>
          <tbody>
            {items.map((it, i) => (
              <tr key={it.id}>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{i + 1}</td>
                <td style={{ border: '1px solid #999', padding: 7 }}>{it.description}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'center' }}>{it.qty}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>{inr(it.unit_price)}</td>
                <td style={{ border: '1px solid #999', padding: 7, textAlign: 'right' }}>{inr(it.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <table style={{ width: 280, margin: '14px 0 0 auto', borderCollapse: 'collapse', fontSize: 12 }}>
          <tbody>
            <tr>
              <td style={{ border: '1px solid #999', background: '#e9edf2', padding: '6px 10px', fontWeight: 700 }}>GROSS AMOUNT</td>
              <td style={{ border: '1px solid #999', padding: '6px 10px', textAlign: 'right' }}>{inr(sale.gross)}</td>
            </tr>
            <tr>
              <td style={{ border: '1px solid #999', background: '#e9edf2', padding: '6px 10px', fontWeight: 700 }}>DISCOUNT</td>
              <td style={{ border: '1px solid #999', padding: '6px 10px', textAlign: 'right' }}>{inr(sale.discount)}</td>
            </tr>
            <tr>
              <td style={{ border: '1px solid #999', background: '#e9edf2', padding: '6px 10px', fontWeight: 700 }}>NET AMOUNT</td>
              <td style={{ border: '1px solid #999', padding: '6px 10px', textAlign: 'right', fontWeight: 700 }}>{inr(sale.net)}</td>
            </tr>
            <tr>
              <td style={{ border: '1px solid #999', padding: '6px 10px' }}>PAID</td>
              <td style={{ border: '1px solid #999', padding: '6px 10px', textAlign: 'right' }}>{inr(sale.paid)}</td>
            </tr>
            <tr>
              <td style={{ border: '1px solid #999', background: sale.outstanding > 0 ? '#fef2f2' : '#e9edf2', padding: '6px 10px', fontWeight: 700 }}>BALANCE DUE</td>
              <td style={{ border: '1px solid #999', padding: '6px 10px', textAlign: 'right', fontWeight: 700, color: sale.outstanding > 0 ? '#b91c1c' : 'inherit' }}>{inr(sale.outstanding)}</td>
            </tr>
          </tbody>
        </table>

        {payments.length > 0 && (
          <div style={{ marginTop: 16 }}>
            <div style={{ fontSize: 11.5, fontWeight: 700, marginBottom: 6 }}>Payments Received</div>
            <table style={{ width: '100%', borderCollapse: 'collapse', fontSize: 11.5 }}>
              <thead>
                <tr style={{ background: '#e9edf2' }}>
                  <th style={{ border: '1px solid #999', padding: 6, textAlign: 'left' }}>Receipt No</th>
                  <th style={{ border: '1px solid #999', padding: 6, textAlign: 'left' }}>Date</th>
                  <th style={{ border: '1px solid #999', padding: 6, textAlign: 'left' }}>Mode</th>
                  <th style={{ border: '1px solid #999', padding: 6, textAlign: 'right' }}>Amount</th>
                </tr>
              </thead>
              <tbody>
                {payments.map((p) => (
                  <tr key={p.id}>
                    <td style={{ border: '1px solid #999', padding: 6 }}>{p.receipt_number}</td>
                    <td style={{ border: '1px solid #999', padding: 6 }}>{fmtDate(p.collected_at)}</td>
                    <td style={{ border: '1px solid #999', padding: 6 }}>{p.payment_type === 'advance_adjustment' ? 'Advance Applied' : (p.optical_payment_modes || []).map((m) => m.mode).join(', ')}</td>
                    <td style={{ border: '1px solid #999', padding: 6, textAlign: 'right' }}>{inr(p.total_amount)}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}

        {sale.notes && <div style={{ marginTop: 14, fontSize: 11.5, color: '#444' }}>Notes: {sale.notes}</div>}
        {sale.status === 'Cancelled' && (
          <div style={{ marginTop: 14, padding: '8px 12px', background: '#fef2f2', border: '1px solid #b91c1c', borderRadius: 6, color: '#b91c1c', fontSize: 12, fontWeight: 700 }}>
            THIS BILL HAS BEEN CANCELLED{sale.cancellation_reason ? ` -- ${sale.cancellation_reason}` : ''}
          </div>
        )}

        <table style={{ width: '100%', marginTop: 50 }}>
          <tbody>
            <tr>
              <td style={{ fontSize: 12 }}>&nbsp;</td>
              <td style={{ textAlign: 'right', fontSize: 12 }}>
                <div>AUTHORISED SIGNATURE</div>
                <div>FOR {settings.name || 'VEDA EYE HOSPITAL'}</div>
              </td>
            </tr>
          </tbody>
        </table>

        <div style={{ textAlign: 'center', marginTop: 24, fontSize: 10.5, color: '#999' }}>
          This is a computer-generated bill.
        </div>
      </div>
    </div>
  );
}
