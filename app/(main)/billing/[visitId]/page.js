import BillingForm from './billing-form';

export default async function BillingPage({ params }) {
  const { visitId } = await params;
  return <BillingForm visitId={visitId} />;
}

