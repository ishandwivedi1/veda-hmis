import LedgerTab from './ledger-tab';
import PaymentsTabs from '../payments-tabs';

export default function LedgerPage() {
  return (
    <div>
      <PaymentsTabs />
      <LedgerTab />
    </div>
  );
}

