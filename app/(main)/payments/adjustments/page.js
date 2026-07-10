import PaymentsTabs from '../payments-tabs';

export default function AdjustmentsPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-adjustments" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Adjustments -- coming soon.
      </div>
    </div>
  );
}

