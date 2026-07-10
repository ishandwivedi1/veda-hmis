import PaymentsTabs from './payments-tabs';

export default function PaymentsDashboardPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-layout-dashboard" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Payments Dashboard -- coming soon.
      </div>
    </div>
  );
}

