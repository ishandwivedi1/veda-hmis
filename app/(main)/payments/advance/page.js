import PaymentsTabs from '../payments-tabs';

export default function AdvancePage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-wallet" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Advance -- coming soon.
      </div>
    </div>
  );
}

