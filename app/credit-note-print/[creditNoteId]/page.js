import { getHospitalSettings } from '@/app/print-templates/actions';
import { getCreditNote } from '@/app/(main)/credit-notes/actions';
import { formatPatientName } from '@/lib/patientName';
import PrintButton from '../../invoice-print/[invoiceId]/print-button';

const r2 = (n) => Math.round((Number(n) || 0) * 100) / 100;
const money = (n) => `₹${r2(n).toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
const dateIST = (d) => new Date(d).toLocaleDateString('en-GB', { timeZone: 'Asia/Kolkata', day: '2-digit', month: '2-digit', year: 'numeric' });

// Printable credit note (Zoho-style document): letterhead, patient, items,
// total, credits used / remaining, invoices credited.
export default async function CreditNotePrintPage({ params }) {
  const { creditNoteId } = await params;
  const [hs, data] = await Promise.all([getHospitalSettings(), getCreditNote(creditNoteId)]);
  if (data?.error) return <div style={{ padding: 40, textAlign: 'center', color: '#b3261e' }}>{data.error}</div>;
  const cn = data.creditNote;

  const cell = { border: '1px solid #999', padding: '6px 8px', fontSize: 12.5 };
  return (
    <div>
      <div className="no-print" style={{ textAlign: 'right', padding: '16px 24px 0' }}><PrintButton /></div>
      <div style={{ maxWidth: 800, margin: '0 auto', padding: 24, fontFamily: 'Georgia, serif', color: '#111' }}>
        {cn.status === 'Void' && (
          <div style={{ textAlign: 'center', color: '#b3261e', fontWeight: 700, fontSize: 18, marginBottom: 8 }}>VOID</div>
        )}
        <div style={{ display: 'flex', gap: 16, alignItems: 'flex-start', borderBottom: '2px solid #111', paddingBottom: 10 }}>
          {hs.logo_data_url && <img src={hs.logo_data_url} alt="" style={{ height: 70 }} />}
          <div style={{ flex: 1 }}>
            <div style={{ fontSize: 18, fontWeight: 700 }}>{hs.name || 'Veda Eye Hospital'}</div>
            {hs.unit_line && <div style={{ fontSize: 12 }}>{hs.unit_line}</div>}
            <div style={{ fontSize: 12 }}>{[hs.address_line1, hs.address_line2, hs.city_state_pin].filter(Boolean).join(', ')}</div>
            <div style={{ fontSize: 12 }}>{[hs.phone && `Phone: ${hs.phone}`, hs.email && `Email: ${hs.email}`].filter(Boolean).join(' · ')}</div>
          </div>
          <div style={{ fontSize: 22, fontWeight: 700, alignSelf: 'flex-end' }}>CREDIT NOTE</div>
        </div>

        <div style={{ display: 'flex', justifyContent: 'space-between', margin: '12px 0', fontSize: 13 }}>
          <div>
            <div style={{ fontSize: 11, fontWeight: 700, color: '#555' }}>PATIENT</div>
            <div style={{ fontWeight: 700 }}>{formatPatientName(cn.patients)}</div>
            <div>{cn.patients?.uhid}{cn.patients?.mobile ? ` · ${cn.patients.mobile}` : ''}</div>
          </div>
          <div style={{ textAlign: 'right' }}>
            <div>Credit Note No: <strong>{cn.credit_note_number}</strong></div>
            <div>Date: <strong>{dateIST(cn.created_at)}</strong></div>
            {cn.invoices?.invoice_number && <div>Against invoice: <strong>{cn.invoices.invoice_number}</strong></div>}
            <div>Reason: {cn.reason}</div>
          </div>
        </div>

        <table style={{ width: '100%', borderCollapse: 'collapse' }}>
          <thead>
            <tr style={{ background: '#eee' }}>
              <th style={{ ...cell, width: 30 }}>#</th>
              <th style={{ ...cell, textAlign: 'left' }}>Description</th>
              <th style={{ ...cell, textAlign: 'right' }}>Qty</th>
              <th style={{ ...cell, textAlign: 'right' }}>Rate</th>
              <th style={{ ...cell, textAlign: 'right' }}>Amount</th>
            </tr>
          </thead>
          <tbody>
            {cn.credit_note_items.map((it, i) => (
              <tr key={it.id}>
                <td style={cell}>{i + 1}</td>
                <td style={cell}>{it.description}</td>
                <td style={{ ...cell, textAlign: 'right' }}>{Number(it.qty)}</td>
                <td style={{ ...cell, textAlign: 'right' }}>{money(it.rate)}</td>
                <td style={{ ...cell, textAlign: 'right' }}>{money(it.amount)}</td>
              </tr>
            ))}
          </tbody>
        </table>

        <div style={{ display: 'flex', justifyContent: 'flex-end', marginTop: 10 }}>
          <table style={{ borderCollapse: 'collapse', minWidth: 280 }}>
            <tbody>
              <tr><td style={{ ...cell, fontWeight: 700 }}>Total credit</td><td style={{ ...cell, textAlign: 'right', fontWeight: 700 }}>{money(cn.amount)}</td></tr>
              <tr><td style={cell}>Credits used</td><td style={{ ...cell, textAlign: 'right' }}>{money(cn.applied)}</td></tr>
              <tr><td style={{ ...cell, fontWeight: 700 }}>Credits remaining</td><td style={{ ...cell, textAlign: 'right', fontWeight: 700 }}>{money(cn.balance)}</td></tr>
            </tbody>
          </table>
        </div>

        {cn.credit_note_applications.length > 0 && (
          <div style={{ marginTop: 16, fontSize: 12.5 }}>
            <div style={{ fontWeight: 700, marginBottom: 4 }}>Credited to</div>
            {cn.credit_note_applications.map((a) => (
              <div key={a.id}>{a.invoices?.invoice_number} -- {money(a.amount)} on {dateIST(a.applied_at)}</div>
            ))}
          </div>
        )}

        <div style={{ marginTop: 40, display: 'flex', justifyContent: 'space-between', fontSize: 12 }}>
          <div>{data.approvedByName ? `Approved by: ${data.approvedByName}` : ''}</div>
          <div style={{ borderTop: '1px solid #111', paddingTop: 4, minWidth: 180, textAlign: 'center' }}>Authorised signatory</div>
        </div>
      </div>
    </div>
  );
}
