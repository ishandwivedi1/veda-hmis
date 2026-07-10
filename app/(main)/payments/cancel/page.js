import PaymentsTabs from '../payments-tabs';

export default function PaymentCancellationPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-x-circle" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Cancellation -- coming soon.
      </div>
    </div>
  );
}

