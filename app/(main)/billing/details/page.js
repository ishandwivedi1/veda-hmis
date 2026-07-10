import BillingTabs from '../billing-tabs';

export default function InvoiceDetailsPage() {
  return (
    <div>
      <BillingTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-search" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Invoice Details -- coming soon.
      </div>
    </div>
  );
}

