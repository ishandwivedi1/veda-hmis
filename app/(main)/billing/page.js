import BillingTabs from './billing-tabs';

export default function BillingDashboardPage() {
  return (
    <div>
      <BillingTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-layout-dashboard" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Billing Dashboard -- coming soon (built last, once the other tabs are in place).
      </div>
    </div>
  );
}

