import { getOpticalSaleDetail } from '@/app/(main)/optical/actions';
import { getLatestGlassesPrescription } from '@/app/(main)/optometry/actions';
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

  // Walk-in optical customers (no patient_id) have no optometry record
  // to pull a prescription from -- prescriptionRx stays null for them,
  // same as it would for a patient with no completed refraction on
  // file. Fetched after confirming the sale exists so an invalid
  // saleId doesn't cost an extra query.
  const prescriptionRx = sale.patient_id ? await getLatestGlassesPrescription(sale.patient_id) : null;

  // A booking isn't a bill until the customer has actually settled it
  // in full -- billing happens at final payment, not at the moment of
  // booking. Same underlying record and reference number throughout;
  // only the document's framing changes once it's Paid.
  const isSettled = sale.status === 'Paid';
  const docTitle = isSettled ? 'OPTICAL SHOP BILL' : 'BOOKING RECEIPT';
  const refLabel = isSettled ? 'Bill No' : 'Booking No';

  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}>
        <PrintButton />
      </div>
      <div style={{ maxWidth: 650, margin: '0 auto', padding: 24, fontFamily: 'Arial, Helvetica, sans-serif', color: '#1a1a1a', fontSize: 13 }}>
        <link href="https://fonts.googleapis.com/css2?family=Playfair+Display:wght@700;800&display=swap" rel="stylesheet" />
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 16, marginBottom: 6 }}>
          <div style={{ display: 'flex', alignItems: 'center', gap: 14 }}>
            {settings.logo_data_url && (
              <div style={{ width: 62, height: 62, flexShrink: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
                <img src={settings.logo_data_url} alt="" style={{ maxWidth: '100%', maxHeight: '100%', objectFit: 'contain' }} />
              </div>
            )}
            <div>
              <div style={{ fontFamily: '"Playfair Display", Georgia, serif', fontSize: 30, fontWeight: 800, letterSpacing: '.5px', color: '#1a2b4a', lineHeight: 1 }}>Veda Opticals</div>
              <div style={{ width: 46, height: 2.5, background: '#c9a24b', marginTop: 6 }} />
            </div>
          </div>
          <div style={{ textAlign: 'right', fontSize: 10.5, lineHeight: 1.5, flexShrink: 0 }}>
            {settings.address_line1}<br />
            {settings.address_line2}<br />
            {settings.city_state_pin}<br />
            {settings.phone && <>Tel: {settings.phone}</>}
          </div>
        </div>

        <div style={{ textAlign: 'center', fontSize: 16, fontWeight: 700, borderTop: '1.5px solid #333', borderBottom: '1.5px solid #333', padding: '8px 0', margin: '10px 0 16px' }}>
          {docTitle}
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
                    <tr><td style={{ width: 90, color: '#444' }}>{refLabel}</td><td>: <strong>{sale.sale_number}</strong></td></tr>
                    <tr><td style={{ color: '#444' }}>Date</td><td>: <strong>{fmtDate(sale.created_at)}</strong></td></tr>
                    <tr><td style={{ color: '#444' }}>Status</td><td>: <strong>{sale.status}</strong></td></tr>
                  </tbody>
                </table>
              </td>
            </tr>
          </tbody>
        </table>

        {prescriptionRx && (
          <table style={{ width: '100%', border: '1.5px solid #333', borderCollapse: 'collapse', marginBottom: 16 }}>
            <tbody>
              <tr>
                <td colSpan={8} style={{ background: '#e9edf2', padding: '5px 10px', fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.3px', borderBottom: '1px solid #999' }}>
                  Prescription (Final Refraction -- {fmtDate(prescriptionRx.completed_at)})
                </td>
              </tr>
              <tr style={{ fontSize: 10, color: '#444' }}>
                <td style={{ padding: '4px 10px' }}></td>
                <td colSpan={3} style={{ padding: '4px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>DISTANCE</td>
                <td colSpan={3} style={{ padding: '4px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>NEAR</td>
                <td style={{ padding: '4px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>ADD</td>
              </tr>
              <tr style={{ fontSize: 10, color: '#444', borderBottom: '1px solid #999' }}>
                <td style={{ padding: '2px 10px' }}></td>
                <td style={{ padding: '2px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>SPH</td><td style={{ padding: '2px 10px', textAlign: 'center' }}>CYL</td><td style={{ padding: '2px 10px', textAlign: 'center' }}>AXIS</td>
                <td style={{ padding: '2px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>SPH</td><td style={{ padding: '2px 10px', textAlign: 'center' }}>CYL</td><td style={{ padding: '2px 10px', textAlign: 'center' }}>AXIS</td>
                <td style={{ padding: '2px 10px', borderLeft: '1px solid #ccc' }}></td>
              </tr>
              <tr style={{ fontSize: 12 }}>
                <td style={{ padding: '5px 10px', fontWeight: 700 }}>RE</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_re_dist_sph || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_re_dist_cyl || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_re_dist_axis || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_re_near_sph || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_re_near_cyl || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_re_near_axis || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_re_add || '--'}</td>
              </tr>
              <tr style={{ fontSize: 12, borderTop: '1px solid #ccc' }}>
                <td style={{ padding: '5px 10px', fontWeight: 700 }}>LE</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_le_dist_sph || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_le_dist_cyl || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_le_dist_axis || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_le_near_sph || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_le_near_cyl || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center' }}>{prescriptionRx.ref_final_le_near_axis || '--'}</td>
                <td style={{ padding: '5px 10px', textAlign: 'center', borderLeft: '1px solid #ccc' }}>{prescriptionRx.ref_final_le_add || '--'}</td>
              </tr>
              {prescriptionRx.glasses_remarks && (
                <tr>
                  <td colSpan={8} style={{ padding: '5px 10px', fontSize: 10.5, color: '#444', borderTop: '1px solid #999' }}>
                    <strong>Remarks:</strong> {prescriptionRx.glasses_remarks}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        )}

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

        <div style={{ marginTop: 20, paddingTop: 10, borderTop: '1px dashed #ccc' }}>
          <div style={{ fontSize: 10.5, fontWeight: 700, textTransform: 'uppercase', letterSpacing: '.3px', color: '#555', marginBottom: 4 }}>Terms &amp; Conditions</div>
          <ol style={{ fontSize: 9.5, color: '#555', lineHeight: 1.6, margin: 0, paddingLeft: 16 }}>
            <li>Goods once sold will not be taken back or refunded; exchange only within 7 days with this original bill and in unused, original condition.</li>
            <li>Frames and lenses carry the manufacturer&apos;s warranty only, where applicable -- no warranty against physical damage, scratches, or misuse.</li>
            <li>Please verify power, fitting, and frame details at the time of delivery. No claims will be entertained once the eyewear has been used.</li>
            <li>This bill must be produced for any exchange, warranty, or service claim.</li>
          </ol>
        </div>

        <table style={{ width: '100%', marginTop: 30 }}>
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

        <div style={{ textAlign: 'center', marginTop: 24, fontSize: 10.5, color: '#999' }}>
          This is a computer-generated bill.
        </div>
      </div>
    </div>
  );
}
