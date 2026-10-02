import { Suspense } from 'react';
import { OpticalHeader } from '../../optical-ui';
import { getOutstandingOpticalBills } from '../../actions';
import NewOpticalPayment from './new-optical-payment';

export const dynamic = 'force-dynamic';

// "+ New Payment" on Optical Payments (like hospital Payments -> New
// Payment): pick a customer, choose one of their unpaid bills -- or none,
// and it is saved as an advance. The unpaid-bills list arrives with the
// page (ONE request); Save is one request and opens the new receipt.
export default async function NewOpticalPaymentPage() {
  const res = await getOutstandingOpticalBills().catch(() => ({ sales: [] }));
  const unpaid = (res?.sales || []).map((b) => ({
    id: b.id, sale_number: b.sale_number, status: b.status, due: b.outstanding, net: b.net, paid: b.paid, sale_date: b.sale_date,
    customer: b.patient_id
      ? { type: 'patient', id: b.patient_id, name: b.displayName, uhid: b.patients?.uhid, mobile: b.displayMobile }
      : { type: 'optical_customer', id: b.optical_customer_id, name: b.displayName, mobile: b.displayMobile },
  })).filter((b) => b.customer.id);
  return (
    <div>
      <OpticalHeader title="New Payment" back={{ href: '/optical/payments', label: 'Optical Payments' }} />
      <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
        <NewOpticalPayment unpaid={unpaid} />
      </Suspense>
    </div>
  );
}
