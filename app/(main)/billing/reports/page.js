import BillingTabs from '../billing-tabs';

export default function BillingReportsPage() {
  return (
    <div>
      <BillingTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-file-report" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Reports -- coming soon.
      </div>
    </div>
  );
}

