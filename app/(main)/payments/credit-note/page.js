import CreditNoteTab from './credit-note-tab';
import PaymentsTabs from '../payments-tabs';

export default function CreditNotePage() {
  return (
    <div>
      <PaymentsTabs />
      <CreditNoteTab />
    </div>
  );
}

