import { Suspense } from 'react';
import WhatsAppInbox from './inbox-screen';

// WhatsApp Inbox -- patient replies to the hospital's WhatsApp messages
// (which go out through Meta's Cloud API on the hospital number, so they
// can't be seen in any WhatsApp app). Conversations on the left, the chat
// on the right, reply box at the bottom.
export default function WhatsAppPage() {
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 40, color: 'var(--g500)' }}>Loading...</div>}>
      <WhatsAppInbox />
    </Suspense>
  );
}
