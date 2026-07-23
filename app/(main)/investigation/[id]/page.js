import { Suspense } from 'react';
import InvestigationWorkspace from './workspace';

export default async function InvestigationWorkspacePage({ params }) {
  const { id } = await params;
  return (
    <Suspense fallback={<div style={{ textAlign: 'center', marginTop: 60, color: 'var(--g500)' }}>Loading...</div>}>
      <InvestigationWorkspace orderId={id} />
    </Suspense>
  );
}

