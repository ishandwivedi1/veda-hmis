import { redirect } from 'next/navigation';

// Collect Payment now happens on the bill itself (Bills screen -> open a
// bill -> Record Payment). Old links with ?saleId= open that bill.
export default async function CollectOpticalPaymentPage({ searchParams }) {
  const params = await searchParams;
  redirect(params?.saleId ? `/optical?saleId=${encodeURIComponent(params.saleId)}` : '/optical');
}
