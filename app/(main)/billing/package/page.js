import BillingTabs from '../billing-tabs';

export default function PackageBillingPage() {
  return (
    <div>
      <BillingTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-package" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Package Billing -- coming soon.
      </div>
    </div>
  );
}

