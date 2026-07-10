import PaymentsTabs from '../payments-tabs';

export default function ReceiptPage() {
  return (
    <div>
      <PaymentsTabs />
      <div className="card" style={{ textAlign: 'center', padding: 40, color: 'var(--g400)' }}>
        <i className="ti ti-receipt-2" style={{ fontSize: 28, display: 'block', marginBottom: 10 }}></i>
        Receipt -- coming soon.
      </div>
    </div>
  );
}

